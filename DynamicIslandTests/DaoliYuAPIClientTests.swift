import Foundation
import Security
import XCTest
@testable import Atoll

@MainActor
final class DaoliYuAPIClientTests: XCTestCase {
    private final class FakeCredentialStore: DaoliYuCredentialStoring, @unchecked Sendable {
        var values: [DaoliYuCredentialAccount: String] = [:]
        var writeStatus: OSStatus = errSecSuccess

        func read(_ account: DaoliYuCredentialAccount) -> String? { values[account] }

        @discardableResult
        func write(_ value: String, account: DaoliYuCredentialAccount) -> OSStatus {
            guard writeStatus == errSecSuccess else { return writeStatus }
            values[account] = value
            return errSecSuccess
        }

        @discardableResult
        func delete(_ account: DaoliYuCredentialAccount) -> OSStatus {
            values[account] = nil
            return errSecSuccess
        }
    }

    private final class FakeHTTPClient: DaoliYuHTTPClient, @unchecked Sendable {
        var responses: [(Data, HTTPURLResponse)] = []
        var requests: [URLRequest] = []
        private var index = 0

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard index < responses.count else { throw URLError(.badServerResponse) }
            defer { index += 1 }
            return responses[index]
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DaoliYuAPIClientTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func response(_ status: Int, url: String = "https://music.example.com/api/tracks") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func loginData(token: String = "access-token") -> Data {
        Data(#"{"token":"\#(token)","user":{"id":"1","email":null,"username":"tester","displayName":null,"role":null,"avatarUrl":null}}"#.utf8)
    }

    func testLegacyCredentialsMigrateOnlyAfterSuccessfulKeychainWrites() {
        defaults.set("https://music.example.com", forKey: "daoliYuServerURL")
        defaults.set("tester", forKey: "daoliYuUsername")
        defaults.set("legacy-password", forKey: "daoliYuPassword")
        defaults.set("legacy-token", forKey: "daoliYuToken")
        let store = FakeCredentialStore()

        let client = DaoliYuAPIClient(httpClient: FakeHTTPClient(), credentialStore: store, defaults: defaults)

        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(store.values[.password], "legacy-password")
        XCTAssertEqual(store.values[.accessToken], "legacy-token")
        XCTAssertNil(defaults.string(forKey: "daoliYuPassword"))
        XCTAssertNil(defaults.string(forKey: "daoliYuToken"))
    }

    func testFailedMigrationKeepsLegacyDefaults() {
        defaults.set("https://music.example.com", forKey: "daoliYuServerURL")
        defaults.set("tester", forKey: "daoliYuUsername")
        defaults.set("legacy-password", forKey: "daoliYuPassword")
        defaults.set("legacy-token", forKey: "daoliYuToken")
        let store = FakeCredentialStore()
        store.writeStatus = errSecIO

        let client = DaoliYuAPIClient(httpClient: FakeHTTPClient(), credentialStore: store, defaults: defaults)

        XCTAssertFalse(client.isAuthenticated)
        XCTAssertEqual(defaults.string(forKey: "daoliYuPassword"), "legacy-password")
        XCTAssertEqual(defaults.string(forKey: "daoliYuToken"), "legacy-token")
    }

    func testLoginRejectsRemotePlainHTTPWithoutSendingRequest() async {
        let http = FakeHTTPClient()
        let client = DaoliYuAPIClient(httpClient: http, credentialStore: FakeCredentialStore(), defaults: defaults)

        do {
            try await client.login(server: "http://music.example.com", username: "tester", password: "secret")
            XCTFail("Expected insecure transport to be rejected")
        } catch DaoliYuError.insecureTransport {
            XCTAssertTrue(http.requests.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoginAllowsLoopbackHTTPAndStoresSecretsOutsideDefaults() async throws {
        let http = FakeHTTPClient()
        http.responses = [(loginData(), response(200, url: "http://localhost:8080/api/auth/login"))]
        let store = FakeCredentialStore()
        let client = DaoliYuAPIClient(httpClient: http, credentialStore: store, defaults: defaults)

        try await client.login(server: "http://localhost:8080", username: "tester", password: "secret")

        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(store.values[.password], "secret")
        XCTAssertEqual(store.values[.accessToken], "access-token")
        XCTAssertNil(defaults.string(forKey: "daoliYuPassword"))
        XCTAssertNil(defaults.string(forKey: "daoliYuToken"))
    }

    func testArtworkURLPreservesLeadingSlashAndBasePath() async throws {
        let http = FakeHTTPClient()
        http.responses = [(loginData(), response(200, url: "https://music.example.com/daoliyu/api/auth/login"))]
        let client = DaoliYuAPIClient(httpClient: http, credentialStore: FakeCredentialStore(), defaults: defaults)
        try await client.login(server: "https://music.example.com/daoliyu/", username: "tester", password: "secret")

        XCTAssertEqual(
            client.coverArtURL(path: "/api/artwork/cover.jpg")?.absoluteString,
            "https://music.example.com/api/artwork/cover.jpg"
        )
        XCTAssertEqual(
            client.coverArtURL(path: "api/artwork/cover.jpg")?.absoluteString,
            "https://music.example.com/daoliyu/api/artwork/cover.jpg"
        )
    }

    func testArtworkURLUpgradesSameHostHTTPReference() async throws {
        let http = FakeHTTPClient()
        http.responses = [(loginData(), response(200, url: "https://music.example.com/api/auth/login"))]
        let client = DaoliYuAPIClient(httpClient: http, credentialStore: FakeCredentialStore(), defaults: defaults)
        try await client.login(server: "https://music.example.com", username: "tester", password: "secret")

        XCTAssertEqual(
            client.coverArtURL(path: "http://music.example.com/api/artwork/cover.jpg")?.absoluteString,
            "https://music.example.com/api/artwork/cover.jpg"
        )
        XCTAssertNil(client.coverArtURL(path: "http://untrusted.example.net/cover.jpg"))
    }

    func testNonSuccessStatusProducesServerErrorBeforeDecoding() async throws {
        let http = FakeHTTPClient()
        http.responses = [
            (loginData(), response(200, url: "https://music.example.com/api/auth/login")),
            (Data(#"{"message":"temporarily unavailable"}"#.utf8), response(503))
        ]
        let client = DaoliYuAPIClient(httpClient: http, credentialStore: FakeCredentialStore(), defaults: defaults)
        try await client.login(server: "https://music.example.com", username: "tester", password: "secret")

        do {
            let _: DaoliYuPaginatedResponse<DaoliYuTrack> = try await client.fetchTracks()
            XCTFail("Expected a server error")
        } catch DaoliYuError.serverError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(message, "temporarily unavailable")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnauthorizedRequestRefreshesAndRetriesExactlyOnce() async throws {
        let tracks = Data(#"{"items":[],"total":0,"skip":0,"take":50}"#.utf8)
        let http = FakeHTTPClient()
        http.responses = [
            (loginData(token: "old-token"), response(200, url: "https://music.example.com/api/auth/login")),
            (Data(), response(401)),
            (loginData(token: "new-token"), response(200, url: "https://music.example.com/api/auth/login")),
            (tracks, response(200))
        ]
        let client = DaoliYuAPIClient(httpClient: http, credentialStore: FakeCredentialStore(), defaults: defaults)
        try await client.login(server: "https://music.example.com", username: "tester", password: "secret")

        let result: DaoliYuPaginatedResponse<DaoliYuTrack> = try await client.fetchTracks()

        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(http.requests.count, 4)
        XCTAssertEqual(http.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer old-token")
        XCTAssertEqual(http.requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
    }

    func testLyricsParserPreservesPlainTextLyrics() {
        let lyrics = """
        First line
        Second line
        Third line
        """

        let parsed = DaoliYuLyricsManager.parseLRC(lyrics)

        XCTAssertEqual(parsed.map(\.text), ["First line", "Second line", "Third line"])
        XCTAssertTrue(parsed.allSatisfy { $0.time == nil })
    }

    func testLyricsParserPreservesUntimedLinesInMixedLyrics() {
        let lyrics = """
        [ti:Example]
        [00:02.00]Second timed line
        Untimed translation
        [00:01.00]First timed line
        """

        let parsed = DaoliYuLyricsManager.parseLRC(lyrics)

        XCTAssertEqual(
            parsed.map(\.text),
            ["Untimed translation", "First timed line", "Second timed line"]
        )
        XCTAssertNil(parsed[0].time)
        XCTAssertEqual(parsed[1].time ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(parsed[2].time ?? -1, 2, accuracy: 0.001)
    }

    func testLyricsParserUsesFirstTimestampAndRemovesTrailingEndTimestamp() {
        let parsed = DaoliYuLyricsManager.parseLRC("[00:01.50]Complete lyric line[00:03.250]")

        XCTAssertEqual(parsed.map(\.text), ["Complete lyric line"])
        XCTAssertEqual(parsed[0].time ?? -1, 1.5, accuracy: 0.001)
    }
}
