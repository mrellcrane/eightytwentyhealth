import AVFoundation
import Foundation

/// Reads distance updates and "Running", "Walking", "Stopped" out loud while you record,
/// over your music (it dips, then comes back) and through headphones if they're in. The "audio" background mode
/// lets it speak with the screen locked.
@MainActor
final class CueAnnouncer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var release: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        release?.cancel()
        release = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
        } catch {
            Log.app.warning("Couldn't start audio for a distance update: \(error.localizedDescription)")
        }
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseAudio() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseAudio() }
    }

    /// Lets the music come back up. The synthesizer reports "finished" while its audio is
    /// still winding down, and deactivating then fails as busy, which left the music
    /// ducked for the rest of the run. So wait a beat, and try again until it lets go.
    private func releaseAudio() {
        release?.cancel()
        release = Task { @MainActor [weak self] in
            for attempt in 1...8 {
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 300 : 500))
                guard let self, !Task.isCancelled else { return }
                // Another update started meanwhile; its own finish will release.
                if self.synthesizer.isSpeaking { return }
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    if attempt > 1 { Log.app.info("Distance update audio released on try \(attempt)") }
                    return
                } catch {
                    if attempt == 8 {
                        Log.app.warning("Couldn't release audio after a distance update: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
