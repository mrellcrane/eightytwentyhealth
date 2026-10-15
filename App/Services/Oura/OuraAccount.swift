import Foundation
import AuthenticationServices
import SwiftUI
import EightyTwentyCore

struct URLSessionTransport: HTTPTransport {
    var session: URLSession = .shared

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Holds the Oura tokens and serializes refreshes. Oura refresh tokens are
/// single-use, so two overlapping refreshes would burn the token and force a
/// re-login. The actor makes sure only one ever runs at a time.
actor OuraTokenStore {
    private static let account = "tokens"
    private let credentials: OuraOAuth.Credentials
    private let transport: HTTPTransport
    private var refreshTask: Task<OuraTokens, Error>?

    init(credentials: OuraOAuth.Credentials, transport: HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    nonisolated var hasTokens: Bool {
        Keychain.data(for: Self.account) != nil
    }

    func save(_ tokens: OuraTokens) {
        if let data = try? JSONEncoder().encode(tokens) {
            Keychain.set(data, for: Self.account)
        }
    }

    func clear() {
        Keychain.delete(Self.account)
    }

    private func load() -> OuraTokens? {
        Keychain.data(for: Self.account).flatMap { try? JSONDecoder().decode(OuraTokens.self, from: $0) }
    }

    func exchange(code: String) async throws {
        let request = OuraOAuth.tokenRequest(.authorizationCode(code), credentials: credentials)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OuraError.http(status: response.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        save(try OuraOAuth.decodeTokens(data))
    }

    /// A valid access token, refreshing first if it's about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = load() else { throw OuraError.notConnected }
        if !forceRefresh && !tokens.needsRefresh() { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ tokens: OuraTokens) async throws -> OuraTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = tokens.refreshToken else { throw OuraError.unauthorized }

        let task = Task { [credentials, transport] () throws -> OuraTokens in
            let request = OuraOAuth.tokenRequest(.refreshToken(refreshToken), credentials: credentials)
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                // 400/401 here means the refresh token is dead: you need to reconnect.
                throw response.statusCode < 500 ? OuraError.unauthorized
                    : OuraError.http(status: response.statusCode, body: "")
            }
            return try OuraOAuth.decodeTokens(data)
        }
        refreshTask = task
        defer { refreshTask = nil }

        let fresh = try await task.value
        // Persist immediately: the old refresh token is already spent.
        save(fresh)
        return fresh
    }
}

/// The app's view of the Oura connection.
@MainActor
@Observable
final class OuraAccount {
    static let callbackScheme = "eightytwenty"
    static let redirectURI = "eightytwenty://oauth-callback"

    let credentials: OuraOAuth.Credentials
    let tokens: OuraTokenStore
    private(set) var isConnected: Bool

    init(bundle: Bundle = .main) {
        let credentials = OuraOAuth.Credentials(
            clientID: (bundle.object(forInfoDictionaryKey: "OuraClientID") as? String) ?? "",
            clientSecret: (bundle.object(forInfoDictionaryKey: "OuraClientSecret") as? String) ?? "",
            redirectURI: Self.redirectURI
        )
        let store = OuraTokenStore(credentials: credentials)
        self.credentials = credentials
        self.tokens = store
        self.isConnected = store.hasTokens
    }

    var isConfigured: Bool { credentials.isConfigured }

    /// Runs the Oura login in an in-app browser sheet and stores the tokens.
    func connect(using session: WebAuthenticationSession) async throws {
        let state = UUID().uuidString
        let url = OuraOAuth.authorizationURL(credentials: credentials, state: state)
        let callback = try await session.authenticate(using: url, callbackURLScheme: Self.callbackScheme)
        let code = try OuraOAuth.code(fromCallback: callback, expectedState: state)
        try await tokens.exchange(code: code)
        isConnected = true
    }

    func disconnect() async {
        await tokens.clear()
        isConnected = false
    }

    func markDisconnected() {
        isConnected = false
    }

    /// An API client that refreshes tokens on demand.
    func client() -> OuraClient {
        let tokens = self.tokens
        return OuraClient(transport: URLSessionTransport()) {
            try await tokens.accessToken()
        }
    }
}
