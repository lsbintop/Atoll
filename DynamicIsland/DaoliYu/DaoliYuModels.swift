import Foundation

enum DaoliYuAudioQuality: Int, Codable, CaseIterable, Sendable {
    case kbps128 = 128
    case kbps192 = 192
    case kbps256 = 256
    case kbps320 = 320
    case original = 0

    var displayName: String {
        switch self {
        case .original: return "Original"
        default: return "\(rawValue) kbps"
        }
    }
}

struct DaoliYuPaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let total: Int
    let skip: Int
    let take: Int
}

struct DaoliYuLoginRequest: Encodable, Sendable {
    let username: String
    let password: String
}

struct DaoliYuLoginResponse: Decodable, Sendable {
    let token: String
    let user: DaoliYuUserInfo
}

struct DaoliYuUserInfo: Codable, Sendable, Identifiable {
    let id: String
    let email: String?
    let username: String
    let displayName: String?
    let role: String?
    let avatarUrl: String?
}

struct DaoliYuTrack: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let artistName: String?
    let artistId: String?
    let artists: [DaoliYuTrackArtistInfo]?
    let album: DaoliYuTrackAlbumInfo?
    let durationSeconds: Int?
    let trackNumber: Int?
    let discNumber: Int?
    let coverArt: String?
    let playCount: Int?
    let fileFormat: String?
    let fileSize: Int?
    let bitrate: Int?
    let isFavorite: Bool?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct DaoliYuTrackArtistInfo: Codable, Sendable, Identifiable {
    let id: String?
    let artistId: String?
    let name: String?
}

struct DaoliYuTrackAlbumInfo: Codable, Sendable {
    let id: String?
    let title: String?
    let coverArt: String?
}

struct DaoliYuAlbum: Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let albumArtist: String?
    let releaseYear: Int?
    let trackCount: Int?
    let coverArt: String?
    let isFavorite: Bool?
    let createdAt: String?
}

struct DaoliYuArtist: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let albumCount: Int?
    let trackCount: Int?
    let coverArt: String?
    let coverArtUrl: String?
    let bio: String?
    let isFavorite: Bool?
}

struct DaoliYuPlaylist: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let coverArt: String?
    let isPublic: Bool?
    let tracks: [DaoliYuPlaylistTrackEntry]?

    var trackCount: Int { tracks?.count ?? 0 }
}

struct DaoliYuPlaylistTrackEntry: Codable, Sendable {
    let id: String
    let track: DaoliYuTrack?
}

struct DaoliYuAlbumDetail: Decodable, Sendable {
    let id: String
    let title: String
    let albumArtist: String?
    let releaseYear: Int?
    let coverArt: String?
    let tracks: [DaoliYuTrack]?
}

struct DaoliYuArtistDetail: Decodable, Sendable {
    let id: String
    let name: String
    let coverArt: String?
    let bio: String?
    let albums: [DaoliYuAlbum]?
    let tracks: [DaoliYuTrack]?
}

struct DaoliYuRandomTracksResponse: Codable, Sendable {
    let count: Int
    let items: [DaoliYuTrack]
}

// MARK: - Track Detail

struct DaoliYuTrackDetail: Decodable, Sendable {
    let id: String
    let title: String
    let lyrics: String?
}

// MARK: - Home / Discover

struct DaoliYuHeartPlaylistsResponse: Decodable, Sendable {
    let playlists: [DaoliYuHeartPlaylist]?
}

struct DaoliYuHeartPlaylist: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let tracks: [DaoliYuTrack]?
    let tags: [String]?
}

struct DaoliYuDailyRecommendationsResponse: Decodable, Sendable {
    let tracks: [DaoliYuTrack]?
    let source: String?
    let generatedAt: String?
}

struct DaoliYuTopPlayedResponse: Decodable, Sendable {
    let items: [DaoliYuTopPlayedEntry]?
}

struct DaoliYuTopPlayedEntry: Decodable, Sendable, Identifiable {
    let track: DaoliYuTrack?
    let playCount: Int?

    private let rawId: String?

    var id: String { rawId ?? track?.id ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case rawId = "id"
        case track
        case playCount
    }
}

// MARK: - Favorites

struct DaoliYuFavoriteTrackItem: Decodable, Sendable {
    let id: String
    let trackId: String?
}

struct DaoliYuFavoriteAlbumItem: Decodable, Sendable {
    let id: String
    let albumId: String?
}

struct DaoliYuFavoriteArtistItem: Decodable, Sendable {
    let id: String
    let artistId: String?
}

struct DaoliYuFavoritePlaylistItem: Decodable, Sendable {
    let id: String
    let playlistId: String?
    let playlist: DaoliYuPlaylist?
}
