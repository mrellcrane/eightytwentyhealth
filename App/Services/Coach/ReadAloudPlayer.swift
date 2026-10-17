import AVFoundation
import Foundation
import MediaPlayer
import EightyTwentyCore

/// Your ElevenLabs API key, in this phone's Keychain. Never in the app binary (the
/// repo is public).
enum ElevenLabsKey {
    static let service = "eightytwenty.elevenlabs"
    private static let account = "apiKey"

    static func load() -> String {
        Keychain.data(for: account, service: service).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func save(_ key: String) -> Bool {
        Keychain.set(Data(key.utf8), for: account, service: service)
    }

    static func remove() {
        Keychain.delete(account, service: service)
    }
}

/// Reads coach answers out loud with an ElevenLabs voice, at 1×, 1.5× or 2×.
///
/// An answer is split into pieces (`ReadAloud`); the first starts playing as soon
/// as it arrives while the rest are fetched behind it. Audio is made once at normal
/// speed and kept in Caches for 30 days, so replays and speed changes are free.
/// The "audio" background mode keeps it going with the screen locked, and the
/// Lock Screen and headphones can pause it.
///
/// Logs carry piece counts, sizes, timings and status codes, never the text.
@MainActor
@Observable
final class ReadAloudPlayer {
    enum Status: Equatable {
        case idle, loading, playing, paused
    }

    private(set) var status: Status = .idle
    /// `ReadAloud.id` of the answer being read.
    private(set) var current: String?
    /// The answer that last failed, and why.
    private(set) var failedID: String?
    private(set) var errorMessage: String?

    var speed: PlaybackSpeed {
        didSet {
            UserDefaults.standard.set(speed.rawValue, forKey: PrefKey.readAloudSpeed)
            player.defaultRate = Float(speed.rawValue)
            if player.timeControlStatus != .paused { player.rate = Float(speed.rawValue) }
            updateNowPlaying()
        }
    }

    var voiceID: String {
        didSet { UserDefaults.standard.set(voiceID, forKey: PrefKey.readAloudVoice) }
    }

    /// Read from the Keychain each time; `keyVersion` redraws views after a save or remove.
    var hasKey: Bool {
        _ = keyVersion
        return !ElevenLabsKey.load().isEmpty
    }
    private var keyVersion = 0

    private let client: ElevenLabsClient
    private let player = AVQueuePlayer()
    private var fetch: Task<Void, Never>?
    /// Still fetching pieces of the current answer.
    private var fetching = false
    /// Pieces queued and not yet finished, in order.
    private var queued: [AVPlayerItem] = []
    private var statusObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []

    nonisolated private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ReadAloud", isDirectory: true)

    init(transport: HTTPTransport = URLSessionTransport()) {
        client = ElevenLabsClient(transport: transport, apiKey: { ElevenLabsKey.load() })
        let defaults = UserDefaults.standard
        speed = PlaybackSpeed(rawValue: defaults.double(forKey: PrefKey.readAloudSpeed)) ?? .normal
        voiceID = defaults.string(forKey: PrefKey.readAloudVoice) ?? ElevenLabsRequest.defaultVoiceID
        player.defaultRate = Float(speed.rawValue)
        player.actionAtItemEnd = .advance

        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in self?.itemEnded(item) }
        })
        setUpRemoteCommands()
        Task.detached(priority: .background) { Self.pruneCache() }
    }

    func state(of id: String) -> Status {
        current == id ? status : .idle
    }

    // MARK: Key

    @discardableResult
    func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ElevenLabsKey.save(trimmed) else { return false }
        keyVersion += 1
        Log.coach.info("ElevenLabs key saved")
        return true
    }

    func removeKey() {
        stop()
        ElevenLabsKey.remove()
        keyVersion += 1
        Log.coach.info("ElevenLabs key removed")
    }

    func voices() async throws -> [ElevenLabsVoice] {
        try await client.voices()
    }

    // MARK: Playing

    /// The play button: plays, pauses or resumes this answer. Loading taps stop it.
    func toggle(_ pieces: [String]) {
        let id = ReadAloud.id(pieces)
        guard current == id else { return play(pieces, id: id) }
        switch status {
        case .playing: player.pause()
        case .paused: resume()
        case .loading, .idle: stop()
        }
    }

    func stop() {
        fetch?.cancel()
        fetch = nil
        fetching = false
        player.pause()
        player.removeAllItems()
        queued = []
        current = nil
        status = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play(_ pieces: [String], id: String) {
        stop()
        guard !pieces.isEmpty else { return }
        current = id
        status = .loading
        failedID = nil
        errorMessage = nil
        do {
            // Spoken audio: pauses music or a podcast, which comes back when it ends.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            Log.coach.warning("Couldn't start audio for read aloud: \(error.localizedDescription)")
        }
        updateNowPlaying()

        fetching = true
        let voice = voiceID
        fetch = Task {
            let started = Date()
            for (index, piece) in pieces.enumerated() {
                do {
                    let (url, cached) = try await audioFile(piece, voiceID: voice)
                    guard !Task.isCancelled, current == id else { return }
                    if index == 0 {
                        Log.coach.info("Read aloud: first of \(pieces.count) pieces ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s\(cached ? ", cached" : "")")
                    }
                    enqueue(url)
                } catch {
                    guard !Task.isCancelled, current == id else { return }
                    fail(error, id: id, piece: index, of: pieces.count)
                    return
                }
            }
            fetching = false
            refresh()
        }
    }

    private func enqueue(_ url: URL) {
        let item = AVPlayerItem(url: url)
        // Keeps the voice's pitch when sped up; the time-domain algorithm is the one meant for speech.
        item.audioTimePitchAlgorithm = .timeDomain
        player.insert(item, after: nil)
        queued.append(item)
        if status != .paused {
            player.defaultRate = Float(speed.rawValue)
            player.play()
        }
    }

    private func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard current != nil, let index = queued.firstIndex(where: { $0 === item }) else { return }
        queued.removeSubrange(...index)
        guard queued.isEmpty else { return }
        // The last piece queued so far just ended: done, or wait for the next one.
        if fetching {
            status = .loading
        } else {
            Log.coach.info("Read aloud finished")
            stop()
        }
    }

    private func refresh() {
        guard current != nil else { return }
        switch player.timeControlStatus {
        case .playing:
            status = .playing
        case .waitingToPlayAtSpecifiedRate:
            status = .loading
        case .paused:
            // An empty queue while fetching is waiting on the next piece; otherwise you
            // (or a call, or unplugged headphones) paused it.
            if queued.isEmpty {
                if fetching { status = .loading } else { stop() }
            } else {
                status = .paused
            }
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    private func fail(_ error: Error, id: String, piece: Int, of count: Int) {
        let message = (error as? ElevenLabsError)?.userMessage ?? error.localizedDescription
        switch error {
        case ElevenLabsError.http(let status, let code, _):
            Log.coach.warning("Read aloud failed on piece \(piece + 1) of \(count): HTTP \(status) \(code ?? "")")
        default:
            Log.coach.warning("Read aloud failed on piece \(piece + 1) of \(count): \(error.localizedDescription)")
        }
        fetching = false
        failedID = id
        errorMessage = message
        // Whatever already arrived keeps playing; with nothing queued, stop.
        if queued.isEmpty { stop() }
    }

    // MARK: Audio files

    /// Cached audio for this piece and voice, or a fresh one from ElevenLabs.
    private func audioFile(_ text: String, voiceID: String) async throws -> (URL, cached: Bool) {
        let url = Self.folder.appendingPathComponent(ReadAloud.cacheKey(text, voiceID: voiceID) + ".mp3")
        if FileManager.default.fileExists(atPath: url.path) { return (url, true) }
        let started = Date()
        let data = try await client.speech(text, voiceID: voiceID)
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        Log.coach.info("Read aloud: \(text.count) characters, \(data.count / 1024) KB in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        return (url, false)
    }

    nonisolated private static func pruneCache() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: file) }
        }
    }

    // MARK: Lock Screen and headphones

    private enum RemoteAction { case play, pause, toggle }

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        // iOS calls these on the main thread.
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.remote(.play) ?? .noActionableNowPlayingItem }
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.remote(.pause) ?? .noActionableNowPlayingItem }
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.remote(.toggle) ?? .noActionableNowPlayingItem }
        }
    }

    private func remote(_ action: RemoteAction) -> MPRemoteCommandHandlerStatus {
        guard current != nil else { return .noActionableNowPlayingItem }
        switch action {
        case .play: resume()
        case .pause: player.pause()
        case .toggle: if status == .paused { resume() } else { player.pause() }
        }
        return .success
    }

    private func updateNowPlaying() {
        guard current != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Coach answer",
            MPMediaItemPropertyArtist: "80/20 Health",
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? speed.rawValue : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed.rawValue,
        ]
    }
}
