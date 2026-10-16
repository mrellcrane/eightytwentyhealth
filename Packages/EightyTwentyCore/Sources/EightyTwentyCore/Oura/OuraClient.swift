import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so the client can be tested without a network.
/// The app conforms `URLSession` to this.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum OuraError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    /// The token is fine but wasn't granted the scope this endpoint needs.
    /// Oura answers these with 401 too, so they must not be read as a dead sign-in.
    case missingScope(endpoint: String)
    case rateLimited(retryAfterSeconds: Double?)
    case http(status: Int, body: String)
    case decoding(endpoint: String, message: String)
}

public enum OuraEndpoint: String, CaseIterable, Sendable {
    case dailyReadiness = "daily_readiness"
    case dailySleep = "daily_sleep"
    case sleep = "sleep"
    case dailyActivity = "daily_activity"
    case dailyStress = "daily_stress"
    case dailyResilience = "daily_resilience"
    case dailySpO2 = "daily_spo2"
    case vo2Max = "vO2_max"
    case workout = "workout"
    case session = "session"
    case enhancedTag = "enhanced_tag"
}

/// Reads the Oura API v2. Token management lives in the app (Keychain);
/// this type just asks for a valid access token when it needs one.
public struct OuraClient: Sendable {
    public static let baseURL = URL(string: "https://api.ouraring.com")!

    private let transport: HTTPTransport
    private let accessToken: @Sendable () async throws -> String

    public init(transport: HTTPTransport, accessToken: @escaping @Sendable () async throws -> String) {
        self.transport = transport
        self.accessToken = accessToken
    }

    /// Fetches every document for `endpoint` with a `day` in `start...end`, following pagination.
    public func documents<Item: Decodable>(
        _ endpoint: OuraEndpoint,
        start: DayKey,
        end: DayKey,
        as type: Item.Type = Item.self
    ) async throws -> [Item] {
        var items: [Item] = []
        var nextToken: String?
        repeat {
            var components = URLComponents(
                url: Self.baseURL.appendingPathComponent("v2/usercollection/\(endpoint.rawValue)"),
                resolvingAgainstBaseURL: false
            )!
            // Oura treats end_date as exclusive on some endpoints; ask for one extra day
            // and let the day keys sort it out downstream.
            var query = [
                URLQueryItem(name: "start_date", value: start.rawValue),
                URLQueryItem(name: "end_date", value: end.adding(days: 1).rawValue),
            ]
            if let nextToken {
                query.append(URLQueryItem(name: "next_token", value: nextToken))
            }
            components.queryItems = query

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await transport.send(request)
            try Self.check(response, data: data)

            do {
                let page = try OuraJSON.decoder().decode(OuraPage<Item>.self, from: data)
                items.append(contentsOf: page.data)
                nextToken = page.nextToken
            } catch {
                throw OuraError.decoding(endpoint: endpoint.rawValue, message: String(describing: error))
            }
        } while nextToken != nil
        return items
    }

    /// Pulls everything the app uses for a date range. Endpoints that fail because a scope
    /// wasn't granted (or the ring doesn't support them) are skipped rather than failing the sync.
    public func bundle(start: DayKey, end: DayKey) async throws -> OuraBundle {
        var bundle = OuraBundle()
        bundle.readiness = try await documents(.dailyReadiness, start: start, end: end)
        bundle.dailySleep = try await documents(.dailySleep, start: start, end: end)
        bundle.sleepPeriods = try await documents(.sleep, start: start, end: end)
        bundle.activity = try await documents(.dailyActivity, start: start, end: end)
        bundle.stress = try await optional { try await documents(.dailyStress, start: start, end: end) }
        bundle.resilience = try await optional { try await documents(.dailyResilience, start: start, end: end) }
        bundle.spo2 = try await optional { try await documents(.dailySpO2, start: start, end: end) }
        bundle.vo2Max = try await optional { try await documents(.vo2Max, start: start, end: end) }
        bundle.workouts = try await optional { try await documents(.workout, start: start, end: end) }
        bundle.sessions = try await optional { try await documents(.session, start: start, end: end) }
        bundle.tags = try await optional { try await documents(.enhancedTag, start: start, end: end) }
        return bundle
    }

    private func optional<T>(_ fetch: () async throws -> [T]) async throws -> [T] {
        do {
            return try await fetch()
        } catch OuraError.http(let status, _) where status == 403 || status == 404 {
            return []
        } catch OuraError.missingScope {
            return []
        } catch OuraError.decoding {
            return []
        }
    }

    static func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            // e.g. {"detail":"Token is not authorized access spo2 scope."}
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            if body.localizedCaseInsensitiveContains("scope") {
                throw OuraError.missingScope(endpoint: response.url?.lastPathComponent ?? "")
            }
            throw OuraError.unauthorized
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw OuraError.rateLimited(retryAfterSeconds: retry)
        default:
            throw OuraError.http(status: response.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
    }
}
