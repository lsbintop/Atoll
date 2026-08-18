import AppKit
import Foundation
import Security

protocol DaoliYuHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionDaoliYuHTTPClient: DaoliYuHTTPClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DaoliYuError.invalidResponse
        }
        return (data, httpResponse)
    }
}

@MainActor
final class DaoliYuAPIClient: ObservableObject {
    static let shared = DaoliYuAPIClient()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var currentUser: DaoliYuUserInfo?

    private var token: String?
    private var baseURL: URL?
    private var username: String?
    private var password: String?

    private let httpClient: any DaoliYuHTTPClient
    private let credentialStore: any DaoliYuCredentialStoring
    private let defaults: UserDefaults

    private enum DefaultsKey {
        static let serverURL = "daoliYuServerURL"
        static let username = "daoliYuUsername"
        static let legacyPassword = "daoliYuPassword"
        static let legacyToken = "daoliYuToken"
    }

    private init() {
        httpClient = URLSessionDaoliYuHTTPClient()
        credentialStore = KeychainDaoliYuCredentialStore()
        defaults = .standard
        loadCredentials()
    }

    init(
        httpClient: any DaoliYuHTTPClient,
        credentialStore: any DaoliYuCredentialStoring,
        defaults: UserDefaults
    ) {
        self.httpClient = httpClient
        self.credentialStore = credentialStore
        self.defaults = defaults
        loadCredentials()
    }

    var serverURL: String {
        get { defaults.string(forKey: DefaultsKey.serverURL) ?? "" }
        set {
            defaults.set(newValue, forKey: DefaultsKey.serverURL)
            baseURL = try? Self.validatedServerURL(newValue)
        }
    }

    // MARK: - Auth

    func login(server: String, username: String, password: String) async throws {
        let validatedBaseURL = try Self.validatedServerURL(server)
        let url = try Self.endpointURL(baseURL: validatedBaseURL, path: "api/auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DaoliYuLoginRequest(username: username, password: password))

        let data = try await sendValidated(request, retryAfterUnauthorized: false)
        let loginResponse: DaoliYuLoginResponse
        do {
            loginResponse = try JSONDecoder().decode(DaoliYuLoginResponse.self, from: data)
        } catch {
            throw DaoliYuError.decodingFailed(error)
        }

        try persistCredentials(
            server: validatedBaseURL.absoluteString,
            username: username,
            password: password,
            token: loginResponse.token
        )

        baseURL = validatedBaseURL
        self.username = username
        self.password = password
        token = loginResponse.token
        currentUser = loginResponse.user
        isAuthenticated = true
    }

    func logout() {
        token = nil
        username = nil
        password = nil
        currentUser = nil
        isAuthenticated = false
        clearCredentials()
    }

    // MARK: - Library

    func fetchArtists(skip: Int = 0, take: Int = 50, sort: String? = nil, sortOrder: String? = nil, search: String? = nil) async throws -> DaoliYuPaginatedResponse<DaoliYuArtist> {
        var query = [("skip", "\(skip)"), ("take", "\(take)")]
        if let sort { query.append(("sort", sort)) }
        if let sortOrder { query.append(("sortOrder", sortOrder)) }
        if let search { query.append(("search", search)) }
        return try await get("api/library/artists", query: query)
    }

    func fetchAlbums(skip: Int = 0, take: Int = 50, sort: String? = nil, sortOrder: String? = nil, search: String? = nil) async throws -> DaoliYuPaginatedResponse<DaoliYuAlbum> {
        var query = [("skip", "\(skip)"), ("take", "\(take)")]
        if let sort { query.append(("sort", sort)) }
        if let sortOrder { query.append(("sortOrder", sortOrder)) }
        if let search { query.append(("search", search)) }
        return try await get("api/library/albums", query: query)
    }

    func fetchTracks(skip: Int = 0, take: Int = 50, sortBy: String? = nil, sortOrder: String? = nil, search: String? = nil) async throws -> DaoliYuPaginatedResponse<DaoliYuTrack> {
        var query = [("skip", "\(skip)"), ("take", "\(take)")]
        if let sortBy { query.append(("sortBy", sortBy)) }
        if let sortOrder { query.append(("sortOrder", sortOrder)) }
        if let search { query.append(("search", search)) }
        return try await get("api/tracks", query: query)
    }

    func fetchPlaylists() async throws -> [DaoliYuPlaylist] { try await get("api/playlists/mine") }
    func fetchAlbumDetail(id: String) async throws -> DaoliYuAlbumDetail { try await get("api/library/albums/\(id)") }
    func fetchArtistDetail(id: String) async throws -> DaoliYuArtistDetail { try await get("api/library/artists/\(id)") }
    func fetchPlaylistDetail(id: String) async throws -> DaoliYuPlaylist { try await get("api/playlists/\(id)") }

    func fetchPlaylistTracks(id: String, skip: Int = 0, take: Int = 50) async throws -> DaoliYuPaginatedResponse<DaoliYuPlaylistTrackEntry> {
        try await get("api/playlists/\(id)/tracks", query: [("skip", "\(skip)"), ("take", "\(take)")])
    }

    func addTrackToPlaylist(playlistId: String, trackId: String) async throws {
        try await postJSON("api/playlists/\(playlistId)/tracks", body: ["trackId": trackId])
    }

    func createPlaylist(name: String, description: String? = nil) async throws -> DaoliYuPlaylist {
        var body = ["name": name]
        if let description { body["description"] = description }
        return try await postAndDecode("api/playlists", body: body)
    }

    func fetchRandomTracks(count: Int = 20) async throws -> DaoliYuRandomTracksResponse {
        try await get("api/tracks/random", query: [("count", "\(count)")])
    }

    func search(query: String, skip: Int = 0, take: Int = 30) async throws -> DaoliYuPaginatedResponse<DaoliYuTrack> {
        try await get("api/tracks", query: [("search", query), ("skip", "\(skip)"), ("take", "\(take)")])
    }

    func fetchTrackDetail(id: String) async throws -> DaoliYuTrackDetail { try await get("api/tracks/\(id)") }
    func fetchHeartPlaylists() async throws -> DaoliYuHeartPlaylistsResponse { try await get("api/library/heart-playlists") }
    func fetchHeartPlaylistDetail(id: String) async throws -> DaoliYuHeartPlaylist { try await get("api/library/heart-playlists/\(id)") }
    func fetchDailyRecommendations() async throws -> DaoliYuDailyRecommendationsResponse { try await get("api/library/recommendations/daily") }

    func fetchTopPlayed(period: String = "week", limit: Int = 20) async throws -> DaoliYuTopPlayedResponse {
        try await get("api/library/playback/top", query: [("period", period), ("limit", "\(limit)")])
    }

    func fetchRecentAlbums(take: Int = 20) async throws -> DaoliYuPaginatedResponse<DaoliYuAlbum> {
        try await get("api/library/albums", query: [("take", "\(take)"), ("sort", "recent"), ("sortOrder", "desc")])
    }

    func fetchRecentArtists(take: Int = 20) async throws -> DaoliYuPaginatedResponse<DaoliYuArtist> {
        try await get("api/library/artists", query: [("take", "\(take)"), ("sort", "recent"), ("sortOrder", "desc")])
    }

    // MARK: - Streaming URLs

    func streamURL(trackId: String, quality: DaoliYuAudioQuality = .original, offset: TimeInterval = 0) -> URL? {
        guard let baseURL,
              let endpoint = try? Self.endpointURL(
                baseURL: baseURL,
                path: quality == .original ? "api/tracks/\(trackId)/stream" : "api/tracks/\(trackId)/transcode"
              ),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        var items: [URLQueryItem] = []
        if quality != .original {
            items.append(URLQueryItem(name: "format", value: "aac"))
            items.append(URLQueryItem(name: "bitrate", value: "\(quality.rawValue)"))
        }
        if offset > 0 {
            items.append(URLQueryItem(name: "offset", value: "\(Int(offset))"))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    func coverArtURL(path: String?) -> URL? {
        guard let path, !path.isEmpty, let baseURL else { return nil }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        // Some DaoliYu servers return protocol-relative artwork URLs (//host/path).
        // Resolve them with the configured server's scheme instead of treating the
        // host as a path component.
        if trimmedPath.hasPrefix("//"),
           let scheme = baseURL.scheme,
           let absoluteURL = URL(string: "\(scheme):\(trimmedPath)") {
            return Self.validatedArtworkURL(absoluteURL, relativeTo: baseURL)
        }

        if let absoluteURL = URL(string: trimmedPath), absoluteURL.scheme != nil {
            return Self.validatedArtworkURL(absoluteURL, relativeTo: baseURL)
        }

        return URL(string: trimmedPath, relativeTo: baseURL)?.absoluteURL
    }

    func authHeaders() -> [String: String] {
        token.map { ["Authorization": "Bearer \($0)"] } ?? [:]
    }

    // MARK: - Playback Reporting

    func reportPlay(trackId: String) async {
        try? await post("api/player/play", body: ["trackId": trackId])
    }

    func reportPosition(trackId: String, positionSeconds: Int) async {
        try? await postJSONObject("api/player/seek", body: [
            "trackId": trackId,
            "positionSeconds": positionSeconds
        ])
    }

    // MARK: - Favorites

    func favoriteTrack(id: String) async throws { try await postJSON("api/favorites/tracks", body: ["trackId": id]) }
    func unfavoriteTrack(id: String) async throws { try await delete("api/favorites/tracks/\(id)") }
    func favoriteAlbum(id: String) async throws { try await postJSON("api/favorites/albums", body: ["albumId": id]) }
    func unfavoriteAlbum(id: String) async throws { try await delete("api/favorites/albums/\(id)") }
    func favoriteArtist(id: String) async throws { try await postJSON("api/favorites/artists", body: ["artistId": id]) }
    func unfavoriteArtist(id: String) async throws { try await delete("api/favorites/artists/\(id)") }
    func fetchFavoriteTracks() async throws -> [DaoliYuFavoriteTrackItem] { try await get("api/favorites/tracks") }
    func fetchFavoriteAlbums() async throws -> [DaoliYuFavoriteAlbumItem] { try await get("api/favorites/albums") }
    func fetchFavoriteArtists() async throws -> [DaoliYuFavoriteArtistItem] { try await get("api/favorites/artists") }
    func fetchFavoritePlaylists() async throws -> [DaoliYuFavoritePlaylistItem] { try await get("api/favorites/playlists") }

    // MARK: - Request Execution

    private func get<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> T {
        let request = try makeRequest(path: path, query: query)
        return try await sendAndDecode(request)
    }

    private func post(_ path: String, body: [String: String]) async throws {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await sendValidated(request)
    }

    private func postJSON(_ path: String, body: [String: String]) async throws {
        try await post(path, body: body)
    }

    private func postJSONObject(_ path: String, body: [String: Any]) async throws {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await sendValidated(request)
    }

    private func postAndDecode<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await sendAndDecode(request)
    }

    private func delete(_ path: String) async throws {
        let request = try makeRequest(path: path, method: "DELETE")
        _ = try await sendValidated(request)
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        query: [(String, String)] = []
    ) throws -> URLRequest {
        guard let baseURL else { throw DaoliYuError.notConfigured }
        let endpoint = try Self.endpointURL(baseURL: baseURL, path: path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw DaoliYuError.invalidServerURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw DaoliYuError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyAuth(&request)
        return request
    }

    private func sendAndDecode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await sendValidated(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DaoliYuError.decodingFailed(error)
        }
    }

    private func sendValidated(
        _ request: URLRequest,
        retryAfterUnauthorized: Bool = true
    ) async throws -> Data {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch let error as DaoliYuError {
            throw error
        } catch {
            throw DaoliYuError.networkError(error)
        }

        if response.statusCode == 401, retryAfterUnauthorized {
            try await refreshToken()
            var retriedRequest = request
            applyAuth(&retriedRequest)
            return try await sendValidated(retriedRequest, retryAfterUnauthorized: false)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw DaoliYuError.serverError(
                statusCode: response.statusCode,
                message: Self.serverErrorMessage(from: data)
            )
        }
        return data
    }

    private func applyAuth(_ request: inout URLRequest) {
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func refreshToken() async throws {
        guard let username, let password, let baseURL else {
            expireAuthentication()
            throw DaoliYuError.authenticationExpired
        }

        do {
            try await login(server: baseURL.absoluteString, username: username, password: password)
        } catch {
            expireAuthentication()
            throw error
        }
    }

    private func expireAuthentication() {
        token = nil
        currentUser = nil
        isAuthenticated = false
        _ = credentialStore.delete(.accessToken)
    }

    // MARK: - URL Validation

    private static func validatedServerURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw DaoliYuError.invalidServerURL
        }

        components.scheme = scheme
        guard scheme == "https" || (scheme == "http" && isLoopbackHost(host)) else {
            throw DaoliYuError.insecureTransport
        }
        guard let url = components.url else { throw DaoliYuError.invalidServerURL }
        return url
    }

    private static func endpointURL(baseURL: URL, path: String) throws -> URL {
        let cleanComponents = path.split(separator: "/").map(String.init)
        guard !cleanComponents.isEmpty else { throw DaoliYuError.invalidServerURL }
        return cleanComponents.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
    }

    private static func isLoopbackHTTP(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.host.map(isLoopbackHost) == true
    }

    private static func validatedArtworkURL(_ url: URL, relativeTo baseURL: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" || isLoopbackHTTP(url) {
            return url
        }

        // Preserve compatibility with self-hosted DaoliYu instances that are
        // configured over HTTPS but still emit absolute HTTP artwork URLs for
        // the same host. Upgrade those URLs rather than dropping the artwork.
        if scheme == "http",
           baseURL.scheme?.lowercased() == "https",
           url.host?.lowercased() == baseURL.host?.lowercased(),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if components.port == 80, baseURL.port == nil {
                components.port = nil
            }
            return components.url
        }

        return nil
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        for key in ["message", "error", "detail"] {
            if let value = object[key] as? String, !value.isEmpty {
                return String(value.prefix(500))
            }
        }
        return nil
    }

    // MARK: - Credentials Persistence

    private func persistCredentials(server: String, username: String, password: String, token: String) throws {
        let passwordStatus = credentialStore.write(password, account: .password)
        guard passwordStatus == errSecSuccess else {
            throw DaoliYuError.credentialStorageFailed(passwordStatus)
        }

        let tokenStatus = credentialStore.write(token, account: .accessToken)
        guard tokenStatus == errSecSuccess else {
            _ = credentialStore.delete(.password)
            throw DaoliYuError.credentialStorageFailed(tokenStatus)
        }

        defaults.set(server, forKey: DefaultsKey.serverURL)
        defaults.set(username, forKey: DefaultsKey.username)
        defaults.removeObject(forKey: DefaultsKey.legacyPassword)
        defaults.removeObject(forKey: DefaultsKey.legacyToken)
    }

    private func loadCredentials() {
        migrateLegacyCredentialsIfNeeded()

        let server = defaults.string(forKey: DefaultsKey.serverURL) ?? ""
        let savedUsername = defaults.string(forKey: DefaultsKey.username)
        let savedPassword = credentialStore.read(.password)
        let savedToken = credentialStore.read(.accessToken)

        guard let validatedBaseURL = try? Self.validatedServerURL(server),
              let savedUsername,
              let savedPassword,
              let savedToken,
              !savedToken.isEmpty
        else {
            isAuthenticated = false
            return
        }

        baseURL = validatedBaseURL
        username = savedUsername
        password = savedPassword
        token = savedToken
        isAuthenticated = true
    }

    private func migrateLegacyCredentialsIfNeeded() {
        migrateLegacyValue(defaultsKey: DefaultsKey.legacyPassword, account: .password)
        migrateLegacyValue(defaultsKey: DefaultsKey.legacyToken, account: .accessToken)
    }

    private func migrateLegacyValue(defaultsKey: String, account: DaoliYuCredentialAccount) {
        guard credentialStore.read(account) == nil,
              let legacyValue = defaults.string(forKey: defaultsKey),
              !legacyValue.isEmpty
        else {
            if credentialStore.read(account) != nil {
                defaults.removeObject(forKey: defaultsKey)
            }
            return
        }

        if credentialStore.write(legacyValue, account: account) == errSecSuccess {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    private func clearCredentials() {
        defaults.removeObject(forKey: DefaultsKey.serverURL)
        defaults.removeObject(forKey: DefaultsKey.username)
        defaults.removeObject(forKey: DefaultsKey.legacyPassword)
        defaults.removeObject(forKey: DefaultsKey.legacyToken)
        for account in DaoliYuCredentialAccount.allCases {
            _ = credentialStore.delete(account)
        }
    }
}

enum DaoliYuError: LocalizedError {
    case notConfigured
    case invalidServerURL
    case insecureTransport
    case invalidResponse
    case authenticationExpired
    case credentialStorageFailed(OSStatus)
    case serverError(statusCode: Int, message: String?)
    case decodingFailed(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "DaoliYu server is not configured."
        case .invalidServerURL:
            return "Enter a valid DaoliYu server URL."
        case .insecureTransport:
            return "DaoliYu requires HTTPS. Plain HTTP is only allowed for localhost."
        case .invalidResponse:
            return "The DaoliYu server returned an invalid response."
        case .authenticationExpired:
            return "Your DaoliYu session has expired. Please sign in again."
        case .credentialStorageFailed:
            return "DaoliYu credentials could not be stored securely in Keychain."
        case .serverError(let statusCode, let message):
            if let message { return "DaoliYu server error (\(statusCode)): \(message)" }
            return "DaoliYu server error (\(statusCode))."
        case .decodingFailed:
            return "The DaoliYu server response could not be read."
        case .networkError(let error):
            return error.localizedDescription
        }
    }
}
