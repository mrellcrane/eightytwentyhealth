import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Oura OAuth2 (authorization code flow). Personal access tokens are gone,
/// so even a personal app registers an OAuth client at cloud.ouraring.com.
public enum OuraOAuth {
    public static let authorizeURL = URL(string: "https://cloud.ouraring.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://api.ouraring.com/oauth/token")!
    public static let scopes = ["email", "personal", "daily", "heartrate", "workout", "tag", "session", "spo2Daily"]

    public struct Credentials: Sendable {
        public let clientID: String
        public let clientSecret: String
        public let redirectURI: String

        public init(clientID: String, clientSecret: String, redirectURI: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.redirectURI = redirectURI
        }

        public var isConfigured: Bool {
            !clientID.isEmpty && !clientSecret.isEmpty && !clientID.hasPrefix("$(")
        }
    }

    public static func authorizationURL(credentials: Credentials, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: credentials.redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public enum CallbackError: Error, Equatable {
        case stateMismatch
        case denied(String)
        case missingCode
    }

    /// Pulls the authorization code out of the redirect, checking the CSRF state.
    public static func code(fromCallback url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw CallbackError.denied(error) }
        guard value("state") == expectedState else { throw CallbackError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw CallbackError.missingCode }
        return code
    }

    public enum Grant: Sendable {
        case authorizationCode(String)
        /// Oura refresh tokens are single-use: always store the new one you get back.
        case refreshToken(String)
    }

    public static func tokenRequest(_ grant: Grant, credentials: Credentials) -> URLRequest {
        var fields: [(String, String)]
        switch grant {
        case .authorizationCode(let code):
            fields = [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", credentials.redirectURI),
            ]
        case .refreshToken(let token):
            fields = [
                ("grant_type", "refresh_token"),
                ("refresh_token", token),
            ]
        }
        fields += [("client_id", credentials.clientID), ("client_secret", credentials.clientSecret)]

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)
        return request
    }

    public static func decodeTokens(_ data: Data, now: Date = Date()) throws -> OuraTokens {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double?
        }
        let response = try OuraJSON.decoder().decode(Response.self, from: data)
        return OuraTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: now.addingTimeInterval(response.expiresIn ?? 24 * 3600)
        )
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        // RFC 3986 unreserved characters only; everything else is escaped.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

public struct OuraTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Refresh a little early so a request never races the expiry.
    public func needsRefresh(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 10 * 60
    }
}
