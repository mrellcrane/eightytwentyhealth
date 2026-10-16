import XCTest
@testable import EightyTwentyCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func decodeFixture<T: Decodable>(_ name: String, as: T.Type) throws -> [T] {
    try OuraJSON.decoder().decode(OuraPage<T>.self, from: fixture(name)).data
}

func fixtureBundle() throws -> OuraBundle {
    var bundle = OuraBundle()
    bundle.readiness = try decodeFixture("daily_readiness", as: OuraDailyReadiness.self)
    bundle.dailySleep = try decodeFixture("daily_sleep", as: OuraDailySleep.self)
    bundle.sleepPeriods = try decodeFixture("sleep", as: OuraSleepPeriod.self)
    bundle.activity = try decodeFixture("daily_activity", as: OuraDailyActivity.self)
    bundle.stress = try decodeFixture("daily_stress", as: OuraDailyStress.self)
    bundle.resilience = try decodeFixture("daily_resilience", as: OuraDailyResilience.self)
    bundle.spo2 = try decodeFixture("daily_spo2", as: OuraDailySpO2.self)
    bundle.vo2Max = try decodeFixture("vo2_max", as: OuraVO2Max.self)
    bundle.workouts = try decodeFixture("workout", as: OuraWorkout.self)
    bundle.sessions = try decodeFixture("session", as: OuraSession.self)
    bundle.tags = try decodeFixture("enhanced_tag", as: OuraEnhancedTag.self)
    return bundle
}

final class OuraParsingTests: XCTestCase {
    func testAssemblesYourOct11() throws {
        let days = OuraDayAssembler.assemble(try fixtureBundle())
        let oct11 = try XCTUnwrap(days[DayKey("2026-10-11")!])
        XCTAssertEqual(oct11.readinessScore, 65)
        XCTAssertEqual(oct11.sleepScore, 71)
        XCTAssertEqual(oct11.averageHRV, 35, "Uses the long_sleep period, not the short one or the deleted one")
        XCTAssertEqual(oct11.lowestHeartRate, 57)
        XCTAssertEqual(oct11.sleepHours!, 6.98, accuracy: 0.01)
        XCTAssertEqual(oct11.temperatureDeviation, 0.28)
        XCTAssertEqual(oct11.ouraSteps, 5967)
        XCTAssertEqual(oct11.stressHighMinutes, 120, "Oura reports seconds; we store minutes")
        XCTAssertNil(oct11.recoveryHighMinutes)
        XCTAssertNil(oct11.spo2Average)

        // Bedtime 01:02 local (PDT) is 08:02 UTC.
        let bedtime = try XCTUnwrap(oct11.bedtimeStart)
        XCTAssertEqual(bedtime.timeIntervalSince1970, 1_791_705_720)
    }

    func testNapDoesNotReplaceTheNight() throws {
        let days = OuraDayAssembler.assemble(try fixtureBundle())
        XCTAssertEqual(days[DayKey("2026-10-10")!]?.averageHRV, 73)
        XCTAssertEqual(days[DayKey("2026-10-10")!]?.lowestHeartRate, 48)
    }

    func testOptionalExtras() throws {
        let days = OuraDayAssembler.assemble(try fixtureBundle())
        let oct10 = try XCTUnwrap(days[DayKey("2026-10-10")!])
        XCTAssertEqual(oct10.resilienceLevel, "solid")
        XCTAssertEqual(oct10.spo2Average, 96.8)
        XCTAssertEqual(oct10.vo2Max, 44)
        XCTAssertEqual(oct10.stressSummary, "normal")
        XCTAssertEqual(days[DayKey("2026-10-03")!]?.workoutMinutes, 80, "66 min yardwork + 14 min walk")
    }

    func testFractionalTimestamps() {
        XCTAssertNotNil(OuraJSON.date("2026-10-09T00:00:00.000-07:00"))
        XCTAssertNotNil(OuraJSON.date("2026-10-09T07:17:30-07:00"))
        XCTAssertNil(OuraJSON.date("not a date"))
        XCTAssertEqual(OuraJSON.localHour("2026-10-10T15:30:00-07:00"), 15)
    }
}

final class OuraActivityMapperTests: XCTestCase {
    func testSessionsBecomePractices() throws {
        let sessions = try decodeFixture("session", as: OuraSession.self)
        let activities = OuraActivityMapper.activities(from: sessions)
        XCTAssertEqual(activities.map(\.kind), [.meditation, .breathwork], "Naps aren't a practice")
        XCTAssertEqual(activities[0].minutes!, 12, accuracy: 0.001)
        XCTAssertEqual(activities[0].externalID, "oura-session:s1")
        XCTAssertEqual(activities[0].source, .ouraSession)
    }

    func testTagMapping() throws {
        let tags = try decodeFixture("enhanced_tag", as: OuraEnhancedTag.self)
        let activities = OuraActivityMapper.activities(from: tags)
        let byID = Dictionary(uniqueKeysWithValues: activities.map { ($0.externalID, $0) })

        XCTAssertEqual(byID["oura-tag:t1"]?.kind, .alcohol)
        XCTAssertEqual(byID["oura-tag:t1"]?.note, "2 glasses wine")
        XCTAssertNil(byID["oura-tag:t2"], "Morning coffee is skipped")
        XCTAssertEqual(byID["oura-tag:t3"]?.kind, .lateCaffeine)
        XCTAssertEqual(byID["oura-tag:t4"]?.kind, .coldExposure)
        XCTAssertEqual(byID["oura-tag:t4"]!.minutes!, 4, accuracy: 0.001)
        XCTAssertNil(byID["oura-tag:t5"], "A head cold is not cold exposure")
        XCTAssertEqual(byID["oura-tag:t6"]?.kind, .meditation, "Tags without a time still import, at midday")
        XCTAssertEqual(activities.count, 4)
    }
}

// MARK: - Client

final class MockTransport: HTTPTransport, @unchecked Sendable {
    var handler: (URLRequest) throws -> (Int, String, [String: String])
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping (URLRequest) throws -> (Int, String, [String: String])) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body, headers) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

final class OuraClientTests: XCTestCase {
    func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func testFollowsPaginationAndSendsToken() async throws {
        let transport = MockTransport { request in
            if request.url!.query?.contains("next_token=page2") == true {
                return (200, #"{"data":[{"id":"b","day":"2026-10-11","score":65}],"next_token":null}"#, [:])
            }
            return (200, #"{"data":[{"id":"a","day":"2026-10-10","score":87}],"next_token":"page2"}"#, [:])
        }
        let client = OuraClient(transport: transport, accessToken: { "tok" })
        let items: [OuraDailyReadiness] = try await client.documents(.dailyReadiness, start: DayKey("2026-10-10")!, end: DayKey("2026-10-11")!)

        XCTAssertEqual(items.map(\.id), ["a", "b"])
        XCTAssertEqual(transport.requests.count, 2)
        let first = transport.requests[0]
        XCTAssertEqual(first.url?.path, "/v2/usercollection/daily_readiness")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(query(first, "start_date"), "2026-10-10")
        XCTAssertEqual(query(first, "end_date"), "2026-10-12", "Asks one day past the end")
    }

    func testUnauthorizedAndRateLimit() async {
        let client401 = OuraClient(transport: MockTransport { _ in (401, "{}", [:]) }, accessToken: { "x" })
        do {
            let _: [OuraDailySleep] = try await client401.documents(.dailySleep, start: DayKey("2026-10-10")!, end: DayKey("2026-10-10")!)
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? OuraError, .unauthorized)
        }

        let clientScope = OuraClient(
            transport: MockTransport { _ in (401, #"{"detail":"Token is not authorized access daily scope."}"#, [:]) },
            accessToken: { "x" }
        )
        do {
            let _: [OuraDailySleep] = try await clientScope.documents(.dailySleep, start: DayKey("2026-10-10")!, end: DayKey("2026-10-10")!)
            XCTFail("Expected missing scope")
        } catch {
            XCTAssertEqual(error as? OuraError, .missingScope(endpoint: "daily_sleep"), "A scope 401 is not a dead sign-in")
        }

        let client429 = OuraClient(transport: MockTransport { _ in (429, "{}", ["Retry-After": "30"]) }, accessToken: { "x" })
        do {
            let _: [OuraDailySleep] = try await client429.documents(.dailySleep, start: DayKey("2026-10-10")!, end: DayKey("2026-10-10")!)
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(error as? OuraError, .rateLimited(retryAfterSeconds: 30))
        }
    }

    func testBundleSkipsEndpointsWithoutScope() async throws {
        let transport = MockTransport { request in
            let path = request.url!.path
            if path.hasSuffix("vO2_max") { return (403, "missing scope", [:]) }
            // What Oura actually sends when a scope wasn't granted.
            if path.hasSuffix("daily_spo2") { return (401, #"{"detail":"Token is not authorized access spo2 scope."}"#, [:]) }
            if path.hasSuffix("daily_readiness") {
                return (200, #"{"data":[{"id":"a","day":"2026-10-10","score":87}],"next_token":null}"#, [:])
            }
            return (200, #"{"data":[],"next_token":null}"#, [:])
        }
        let client = OuraClient(transport: transport, accessToken: { "x" })
        let bundle = try await client.bundle(start: DayKey("2026-10-10")!, end: DayKey("2026-10-10")!)
        XCTAssertEqual(bundle.readiness.count, 1)
        XCTAssertTrue(bundle.spo2.isEmpty)
        XCTAssertTrue(bundle.vo2Max.isEmpty)
        XCTAssertEqual(transport.requests.count, OuraEndpoint.allCases.count)
    }

    func testCoreEndpointFailureFailsTheSync() async {
        let client = OuraClient(transport: MockTransport { _ in (500, "boom", [:]) }, accessToken: { "x" })
        do {
            _ = try await client.bundle(start: DayKey("2026-10-10")!, end: DayKey("2026-10-10")!)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? OuraError, .http(status: 500, body: "boom"))
        }
    }
}

final class OuraOAuthTests: XCTestCase {
    let credentials = OuraOAuth.Credentials(clientID: "abc", clientSecret: "s3cr3t+/=", redirectURI: "eightytwenty://oauth-callback")

    func testAuthorizationURL() {
        let url = OuraOAuth.authorizationURL(credentials: credentials, state: "xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "cloud.ouraring.com")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "abc")
        XCTAssertEqual(value("redirect_uri"), "eightytwenty://oauth-callback")
        XCTAssertEqual(value("state"), "xyz")
        XCTAssertEqual(value("scope"), "email personal daily heartrate workout tag session spo2 stress heart_health")
    }

    func testCallbackParsing() throws {
        let good = URL(string: "eightytwenty://oauth-callback?iss=https%3A%2F%2Fmoi.ouraring.com&code=CODE1&state=xyz")!
        XCTAssertEqual(try OuraOAuth.code(fromCallback: good, expectedState: "xyz"), "CODE1")

        let forged = URL(string: "eightytwenty://oauth-callback?code=CODE1&state=evil")!
        XCTAssertThrowsError(try OuraOAuth.code(fromCallback: forged, expectedState: "xyz")) {
            XCTAssertEqual($0 as? OuraOAuth.CallbackError, .stateMismatch)
        }

        let denied = URL(string: "eightytwenty://oauth-callback?error=access_denied&state=xyz")!
        XCTAssertThrowsError(try OuraOAuth.code(fromCallback: denied, expectedState: "xyz")) {
            XCTAssertEqual($0 as? OuraOAuth.CallbackError, .denied("access_denied"))
        }
    }

    func testTokenRequestIsFormEncoded() {
        let request = OuraOAuth.tokenRequest(.authorizationCode("C D"), credentials: credentials)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, OuraOAuth.tokenURL)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertEqual(body, "grant_type=authorization_code&code=C%20D&redirect_uri=eightytwenty%3A%2F%2Foauth-callback&client_id=abc&client_secret=s3cr3t%2B%2F%3D")

        let refresh = OuraOAuth.tokenRequest(.refreshToken("R1"), credentials: credentials)
        XCTAssertTrue(String(decoding: refresh.httpBody!, as: UTF8.self).hasPrefix("grant_type=refresh_token&refresh_token=R1&"))
    }

    func testDecodeTokens() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"token_type":"bearer","access_token":"A","expires_in":2591999,"refresh_token":"R","scope":"extapi:daily","id_token":null}"#
        let tokens = try OuraOAuth.decodeTokens(Data(json.utf8), now: now)
        XCTAssertEqual(tokens.accessToken, "A")
        XCTAssertEqual(tokens.refreshToken, "R")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(2_591_999))
        XCTAssertFalse(tokens.needsRefresh(now: now))
        XCTAssertTrue(tokens.needsRefresh(now: now.addingTimeInterval(2_591_999 - 60)))
    }

    func testPlaceholderCredentialsAreNotConfigured() {
        XCTAssertFalse(OuraOAuth.Credentials(clientID: "$(OURA_CLIENT_ID)", clientSecret: "x", redirectURI: "y").isConfigured)
        XCTAssertFalse(OuraOAuth.Credentials(clientID: "", clientSecret: "", redirectURI: "y").isConfigured)
        XCTAssertTrue(credentials.isConfigured)
    }
}
