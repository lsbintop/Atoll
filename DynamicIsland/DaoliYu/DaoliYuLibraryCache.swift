import Foundation

struct DaoliYuLibraryCacheContext: Codable, Equatable, Sendable {
    let serverURL: String
    let username: String
    let songsSort: String
    let songsSortOrder: String
    let artistsSort: String
    let artistsSortOrder: String
    let albumsSort: String
    let albumsSortOrder: String
}

struct DaoliYuLibraryCacheSnapshot: Codable, Sendable {
    let context: DaoliYuLibraryCacheContext
    let playlists: [DaoliYuPlaylist]
    let artists: [DaoliYuArtist]
    let albums: [DaoliYuAlbum]
    let tracks: [DaoliYuTrack]
    let trackTotal: Int
}

enum DaoliYuLibraryCache {
    private static let pageSize = 50

    private static var cacheURL: URL {
        FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("atoll_daoliyu_library_cache.json")
    }

    static func load(
        matching context: DaoliYuLibraryCacheContext
    ) -> DaoliYuLibraryCacheSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(
                  DaoliYuLibraryCacheSnapshot.self,
                  from: data
              ),
              snapshot.context == context else {
            return nil
        }
        return snapshot
    }

    static func save(
        context: DaoliYuLibraryCacheContext,
        playlists: [DaoliYuPlaylist],
        artists: [DaoliYuArtist],
        albums: [DaoliYuAlbum],
        tracks: [DaoliYuTrack],
        trackTotal: Int
    ) {
        let snapshot = DaoliYuLibraryCacheSnapshot(
            context: context,
            playlists: playlists,
            artists: Array(artists.prefix(pageSize)),
            albums: Array(albums.prefix(pageSize)),
            tracks: Array(tracks.prefix(pageSize)),
            trackTotal: trackTotal
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
