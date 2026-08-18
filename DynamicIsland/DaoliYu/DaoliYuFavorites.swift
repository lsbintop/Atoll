import Foundation

@MainActor
final class DaoliYuFavoritesManager: ObservableObject {
    static let shared = DaoliYuFavoritesManager()

    @Published var favoriteTrackIds: Set<String> = []
    @Published var favoriteAlbumIds: Set<String> = []
    @Published var favoriteArtistIds: Set<String> = []
    @Published var favoritePlaylistIds: Set<String> = []

    private let client = DaoliYuAPIClient.shared

    private init() {}

    // MARK: - Load

    func loadAll() async {
        async let tracks = fetchFavoriteTracks()
        async let albums = fetchFavoriteAlbums()
        async let artists = fetchFavoriteArtists()
        async let playlists = fetchFavoritePlaylists()

        let (t, al, ar, p) = await (tracks, albums, artists, playlists)
        favoriteTrackIds = t
        favoriteAlbumIds = al
        favoriteArtistIds = ar
        favoritePlaylistIds = p
    }

    // MARK: - Toggle

    func toggleTrack(id: String) {
        let wasFavorite = favoriteTrackIds.contains(id)
        if wasFavorite {
            favoriteTrackIds.remove(id)
        } else {
            favoriteTrackIds.insert(id)
        }

        Task {
            do {
                if wasFavorite {
                    try await delete(path: "api/favorites/tracks/\(id)")
                } else {
                    try await post(path: "api/favorites/tracks", body: ["trackId": id])
                }
            } catch {
                if wasFavorite {
                    favoriteTrackIds.insert(id)
                } else {
                    favoriteTrackIds.remove(id)
                }
            }
        }
    }

    func toggleAlbum(id: String) {
        let wasFavorite = favoriteAlbumIds.contains(id)
        if wasFavorite {
            favoriteAlbumIds.remove(id)
        } else {
            favoriteAlbumIds.insert(id)
        }

        Task {
            do {
                if wasFavorite {
                    try await delete(path: "api/favorites/albums/\(id)")
                } else {
                    try await post(path: "api/favorites/albums", body: ["albumId": id])
                }
            } catch {
                if wasFavorite {
                    favoriteAlbumIds.insert(id)
                } else {
                    favoriteAlbumIds.remove(id)
                }
            }
        }
    }

    func toggleArtist(id: String) {
        let wasFavorite = favoriteArtistIds.contains(id)
        if wasFavorite {
            favoriteArtistIds.remove(id)
        } else {
            favoriteArtistIds.insert(id)
        }

        Task {
            do {
                if wasFavorite {
                    try await delete(path: "api/favorites/artists/\(id)")
                } else {
                    try await post(path: "api/favorites/artists", body: ["artistId": id])
                }
            } catch {
                if wasFavorite {
                    favoriteArtistIds.insert(id)
                } else {
                    favoriteArtistIds.remove(id)
                }
            }
        }
    }

    // MARK: - Network

    private func fetchFavoriteTracks() async -> Set<String> {
        guard let items: [DaoliYuFavoriteTrackItem] = try? await get(path: "api/favorites/tracks") else { return [] }
        return Set(items.compactMap(\.trackId))
    }

    private func fetchFavoriteAlbums() async -> Set<String> {
        guard let items: [DaoliYuFavoriteAlbumItem] = try? await get(path: "api/favorites/albums") else { return [] }
        return Set(items.compactMap(\.albumId))
    }

    private func fetchFavoriteArtists() async -> Set<String> {
        guard let items: [DaoliYuFavoriteArtistItem] = try? await get(path: "api/favorites/artists") else { return [] }
        return Set(items.compactMap(\.artistId))
    }

    private func fetchFavoritePlaylists() async -> Set<String> {
        guard let items: [DaoliYuFavoritePlaylistItem] = try? await get(path: "api/favorites/playlists") else { return [] }
        return Set(items.compactMap(\.playlistId))
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let request = try buildRequest(path: path, method: "GET")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(path: String, body: [String: String]) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DaoliYuError.networkError(URLError(.badServerResponse))
        }
    }

    private func delete(path: String) async throws {
        let request = try buildRequest(path: path, method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DaoliYuError.networkError(URLError(.badServerResponse))
        }
    }

    private func buildRequest(path: String, method: String) throws -> URLRequest {
        let serverURL = client.serverURL
        guard !serverURL.isEmpty, let base = URL(string: serverURL) else {
            throw DaoliYuError.notConfigured
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        for (key, value) in client.authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
