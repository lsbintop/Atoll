import SwiftUI
import AppKit
import Combine
import ImageIO

private let libraryScale: CGFloat = 1.5

private func libraryFontSize(_ size: CGFloat) -> CGFloat {
    max(1, (size * libraryScale).rounded(.down) - 1)
}

// MARK: - Main View

struct DaoliYuLibraryView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var apiClient = DaoliYuAPIClient.shared
    @State private var suppressionToken = UUID()
    @State private var isSuppressing = false

    var body: some View {
        VStack(spacing: 0) {
            if !apiClient.isAuthenticated {
                notLoggedInView
            } else {
                LibraryTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering in
            updateSuppression(for: hovering)
        }
        .onDisappear {
            updateSuppression(for: false)
        }
    }

    private func updateSuppression(for hovering: Bool) {
        guard hovering != isSuppressing else { return }
        isSuppressing = hovering
        vm.setScrollGestureSuppression(hovering, token: suppressionToken)
    }

    private var notLoggedInView: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.house")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("道理鱼未连接")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("请在设置 → 道理鱼中配置")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Library Tab

private struct LibraryTabView: View {
    @ObservedObject private var manager = DaoliYuManager.shared
    @ObservedObject private var apiClient = DaoliYuAPIClient.shared
    @ObservedObject private var favorites = DaoliYuFavoritesManager.shared
    @AppStorage("daoliyu.library.selectedSection")
    private var selectedSection: LibrarySection = .songs
    @State private var playlists: [DaoliYuPlaylist] = []
    @State private var artists: [DaoliYuArtist] = []
    @State private var albums: [DaoliYuAlbum] = []
    @State private var tracks: [DaoliYuTrack] = []
    @State private var trackSearchResults: [DaoliYuTrack] = []
    @State private var artistSearchResults: [DaoliYuArtist] = []
    @State private var albumSearchResults: [DaoliYuAlbum] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var detailContext: DetailContext?
    @State private var parentDetailContext: DetailContext?
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("daoliyu.library.songs.sort") private var songsSort: String = "recent"
    @AppStorage("daoliyu.library.songs.sortOrder") private var songsSortOrder: String = "desc"
    @AppStorage("daoliyu.library.artists.sort") private var artistsSort: String = "recent"
    @AppStorage("daoliyu.library.artists.sortOrder") private var artistsSortOrder: String = "desc"
    @AppStorage("daoliyu.library.albums.sort") private var albumsSort: String = "recent"
    @AppStorage("daoliyu.library.albums.sortOrder") private var albumsSortOrder: String = "desc"
    @State private var hasMore = true
    @State private var total: Int = 0
    @State private var showAddToPlaylist: DaoliYuTrack?

    enum LibrarySection: String, CaseIterable {
        case playlists = "歌单"
        case artists = "艺术家"
        case albums = "专辑"
        case songs = "曲目"

        var icon: String {
            switch self {
            case .playlists: return "music.note.list"
            case .artists: return "music.mic"
            case .albums: return "square.stack"
            case .songs: return "music.note"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let detail = detailContext {
                detailView(for: detail)
            } else {
                libraryContent
            }
        }
        .task { await loadInitialData() }
        .sheet(item: $showAddToPlaylist) { track in
            AddToPlaylistSheet(track: track, playlists: playlists)
        }
    }

    // MARK: - Library Content

    private var libraryContent: some View {
        VStack(spacing: 4 * libraryScale) {
            sectionPicker
            searchBar
            actionBar
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2 * libraryScale) {
                    if normalizedSearchText.count >= 2 {
                        switch selectedSection {
                        case .playlists:
                            ForEach(filteredPlaylists) { playlist in
                                playlistRow(playlist)
                            }
                        case .artists:
                            ForEach(artistSearchResults) { artist in
                                artistRow(artist)
                            }
                        case .albums:
                            ForEach(albumSearchResults) { album in
                                albumRow(album)
                            }
                        case .songs:
                            ForEach(trackSearchResults) { track in
                                trackRow(track)
                            }
                        }
                    } else {
                        switch selectedSection {
                        case .playlists:
                            ForEach(filteredPlaylists) { playlist in
                                playlistRow(playlist)
                            }
                        case .artists:
                            ForEach(filteredArtists) { artist in
                                artistRow(artist)
                            }
                        case .albums:
                            ForEach(filteredAlbums) { album in
                                albumRow(album)
                            }
                        case .songs:
                            ForEach(filteredTracks) { track in
                                trackRow(track)
                            }
                            if hasMore && !filteredTracks.isEmpty {
                                loadMoreIndicator
                            }
                        }
                    }
                }
                .padding(.horizontal, 8 * libraryScale)
            }
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4 * libraryScale) {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedSection = section
                    }
                    handleSearchChange(searchText)
                } label: {
                    HStack(spacing: 3 * libraryScale) {
                        Image(systemName: section.icon)
                            .font(.system(size: libraryFontSize(9)))
                        Text(section.rawValue)
                            .font(.system(size: libraryFontSize(9), weight: .medium))
                    }
                    .padding(.horizontal, 6 * libraryScale)
                    .padding(.vertical, 4 * libraryScale)
                    .background(selectedSection == section ? Color.white.opacity(0.15) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12 * libraryScale)
        .padding(.top, 6 * libraryScale)
    }

    private var searchBar: some View {
        HStack(spacing: 4 * libraryScale) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: libraryFontSize(10)))
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: libraryFontSize(11)))
                .onChange(of: searchText) { newValue in
                    handleSearchChange(newValue)
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    clearRemoteSearchResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: libraryFontSize(9)))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8 * libraryScale)
        .padding(.vertical, 4 * libraryScale)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6 * libraryScale))
        .padding(.horizontal, 12 * libraryScale)
    }

    private var actionBar: some View {
        HStack(spacing: 8 * libraryScale) {
            if selectedSection == .songs {
                // Play All
                Button {
                    playAll(shuffle: false)
                } label: {
                    HStack(spacing: 3 * libraryScale) {
                        Image(systemName: "play.fill")
                            .font(.system(size: libraryFontSize(8)))
                        Text("播放")
                            .font(.system(size: libraryFontSize(9), weight: .medium))
                    }
                    .padding(.horizontal, 8 * libraryScale)
                    .padding(.vertical, 3 * libraryScale)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                // Shuffle
                Button {
                    playAll(shuffle: true)
                } label: {
                    HStack(spacing: 3 * libraryScale) {
                        Image(systemName: "shuffle")
                            .font(.system(size: libraryFontSize(8)))
                        Text("随机播放")
                            .font(.system(size: libraryFontSize(9), weight: .medium))
                    }
                    .padding(.horizontal, 8 * libraryScale)
                    .padding(.vertical, 3 * libraryScale)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Sort
            if selectedSection != .playlists {
                Menu {
                    Button { resort("recent", "desc") } label: { Text("添加时间") }
                    Button { resort("name", "asc") } label: { Text("名称") }
                    Button { resort("playCount", "desc") } label: { Text("最多播放") }
                    if selectedSection == .albums {
                        Button { resort("releaseDate", "desc") } label: { Text("发行时间") }
                    }
                } label: {
                    HStack(spacing: 3 * libraryScale) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: libraryFontSize(8)))
                        Text(sortLabel)
                            .font(.system(size: libraryFontSize(9)))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12 * libraryScale)
        .padding(.vertical, 3 * libraryScale)
    }

    private var sortLabel: String {
        switch currentSort {
        case "name": return "名称"
        case "playCount": return "最多播放"
        case "releaseDate": return "发行时间"
        default: return "添加时间"
        }
    }

    private func resort(_ by: String, _ order: String) {
        switch selectedSection {
        case .songs:
            songsSort = by
            songsSortOrder = order
        case .artists:
            artistsSort = by
            artistsSortOrder = order
        case .albums:
            albumsSort = by
            albumsSortOrder = order
        case .playlists:
            return
        }
        Task { await reloadCurrentSection() }
    }

    private var currentSort: String {
        switch selectedSection {
        case .songs: return songsSort
        case .artists: return artistsSort
        case .albums: return albumsSort
        case .playlists: return "recent"
        }
    }

    private var currentSortOrder: String {
        switch selectedSection {
        case .songs: return songsSortOrder
        case .artists: return artistsSortOrder
        case .albums: return albumsSortOrder
        case .playlists: return "desc"
        }
    }

    private func playAll(shuffle: Bool) {
        var tracksToPlay: [DaoliYuTrack] = []
        switch selectedSection {
        case .songs: tracksToPlay = filteredTracks
        default: return
        }
        guard !tracksToPlay.isEmpty else { return }
        if shuffle {
            manager.play(tracks: tracksToPlay.shuffled())
        } else {
            manager.play(tracks: tracksToPlay)
        }
    }

    private var loadMoreIndicator: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text("加载更多 (\(tracks.count)/\(total))")
                        .font(.system(size: libraryFontSize(9)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6 * libraryScale)
        }
        .buttonStyle(.plain)
        .onAppear { Task { await loadMore() } }
    }

    private func handleSearchChange(_ query: String) {
        searchTask?.cancel()
        clearRemoteSearchResults()

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2 else {
            return
        }

        let section = selectedSection
        guard section != .playlists else { return }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            switch section {
            case .songs:
                guard let result = try? await apiClient.fetchTracks(
                    take: 50,
                    search: normalizedQuery
                ) else { return }
                guard !Task.isCancelled,
                      searchIsCurrent(normalizedQuery, section: section) else { return }
                trackSearchResults = result.items
            case .artists:
                guard let result = try? await apiClient.fetchArtists(
                    take: 100,
                    search: normalizedQuery
                ) else { return }
                guard !Task.isCancelled,
                      searchIsCurrent(normalizedQuery, section: section) else { return }
                artistSearchResults = result.items
            case .albums:
                guard let result = try? await apiClient.fetchAlbums(
                    take: 100,
                    search: normalizedQuery
                ) else { return }
                guard !Task.isCancelled,
                      searchIsCurrent(normalizedQuery, section: section) else { return }
                albumSearchResults = result.items
            case .playlists:
                break
            }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchIsCurrent(
        _ query: String,
        section: LibrarySection
    ) -> Bool {
        selectedSection == section
            && normalizedSearchText == query
    }

    private func clearRemoteSearchResults() {
        trackSearchResults = []
        artistSearchResults = []
        albumSearchResults = []
    }

    // MARK: - Rows

    private func trackRow(_ track: DaoliYuTrack) -> some View {
        HStack(spacing: 8 * libraryScale) {
            Button {
                manager.play(track: track)
            } label: {
                HStack(spacing: 8 * libraryScale) {
                    DaoliYuCoverImage(path: track.coverArt ?? track.album?.coverArt, size: 28 * libraryScale)
                    VStack(alignment: .leading, spacing: 1 * libraryScale) {
                        Text(track.title)
                            .font(.system(size: libraryFontSize(11), weight: .medium))
                            .lineLimit(1)
                        Text(track.artistName ?? "")
                            .font(.system(size: libraryFontSize(9)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let duration = track.durationSeconds {
                Text(formatDuration(duration))
                    .font(.system(size: libraryFontSize(9)))
                    .foregroundStyle(.tertiary)
            }

            Button {
                favorites.toggleTrack(id: track.id)
            } label: {
                Image(systemName: favorites.favoriteTrackIds.contains(track.id) ? "heart.fill" : "heart")
                    .font(.system(size: libraryFontSize(10)))
                    .foregroundStyle(favorites.favoriteTrackIds.contains(track.id) ? Color.pink : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4 * libraryScale)
        .padding(.horizontal, 6 * libraryScale)
        .contextMenu { trackContextMenu(track) }
    }

    private func albumRow(_ album: DaoliYuAlbum) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { detailContext = .album(album) }
        } label: {
            HStack(spacing: 8 * libraryScale) {
                DaoliYuCoverImage(path: album.coverArt, size: 32 * libraryScale)
                VStack(alignment: .leading, spacing: 1 * libraryScale) {
                    Text(album.title)
                        .font(.system(size: libraryFontSize(11), weight: .medium))
                        .lineLimit(1)
                    Text(album.albumArtist ?? "")
                        .font(.system(size: libraryFontSize(9)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let count = album.trackCount {
                    Text("\(count) 首")
                        .font(.system(size: libraryFontSize(9)))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4 * libraryScale)
            .padding(.horizontal, 6 * libraryScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ artist: DaoliYuArtist) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { detailContext = .artist(artist) }
        } label: {
            HStack(spacing: 8 * libraryScale) {
                DaoliYuCoverImage(path: artist.coverArt, size: 28 * libraryScale, isCircle: true)
                Text(artist.name)
                    .font(.system(size: libraryFontSize(11), weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let count = artist.trackCount {
                    Text("\(count) 首")
                        .font(.system(size: libraryFontSize(9)))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4 * libraryScale)
            .padding(.horizontal, 6 * libraryScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: DaoliYuPlaylist) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { detailContext = .playlist(playlist) }
        } label: {
            HStack(spacing: 8 * libraryScale) {
                DaoliYuCoverImage(path: playlist.coverArt, size: 32 * libraryScale)
                VStack(alignment: .leading, spacing: 1 * libraryScale) {
                    Text(playlist.name)
                        .font(.system(size: libraryFontSize(11), weight: .medium))
                        .lineLimit(1)
                    Text("\(playlist.trackCount) 首")
                        .font(.system(size: libraryFontSize(9)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4 * libraryScale)
            .padding(.horizontal, 6 * libraryScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail View

    @ViewBuilder
    private func detailView(for context: DetailContext) -> some View {
        VStack(spacing: 6 * libraryScale) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        detailContext = parentDetailContext
                        parentDetailContext = nil
                    }
                } label: {
                    HStack(spacing: 4 * libraryScale) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: libraryFontSize(10)))
                        Text("返回")
                            .font(.system(size: libraryFontSize(10)))
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12 * libraryScale)
            .padding(.top, 6 * libraryScale)

            switch context {
            case .album(let album):
                AlbumDetailSubview(album: album, manager: manager)
            case .artist(let artist):
                ArtistDetailSubview(
                    artist: artist,
                    manager: manager
                ) { album in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        parentDetailContext = .artist(artist)
                        detailContext = .album(album)
                    }
                }
            case .playlist(let playlist):
                PlaylistDetailSubview(playlist: playlist, manager: manager)
            }
        }
    }

    // MARK: - Data Loading

    private func loadInitialData() async {
        guard apiClient.isAuthenticated else { return }

        if let cached = DaoliYuLibraryCache.load(matching: cacheContext) {
            playlists = cached.playlists
            artists = cached.artists
            albums = cached.albums
            tracks = cached.tracks
            total = cached.trackTotal
            hasMore = tracks.count < total
        }

        isLoading = true
        await favorites.loadAll()
        async let p = try? apiClient.fetchPlaylists()
        async let ar = try? apiClient.fetchArtists(take: 50, sort: artistsSort, sortOrder: artistsSortOrder)
        async let al = try? apiClient.fetchAlbums(take: 50, sort: albumsSort, sortOrder: albumsSortOrder)
        async let t = try? apiClient.fetchTracks(take: 50, sortBy: songsSort, sortOrder: songsSortOrder)

        let (playlistsResult, artistsResult, albumsResult, tracksResult) = await (p, ar, al, t)
        if let playlistsResult {
            playlists = orderedPlaylists(playlistsResult)
        }
        if let artistsResult {
            artists = artistsResult.items
        }
        if let albumsResult {
            albums = albumsResult.items
        }
        if let tracksResult {
            tracks = tracksResult.items
            total = tracksResult.total
        }
        hasMore = tracks.count < total
        if playlistsResult != nil
            || artistsResult != nil
            || albumsResult != nil
            || tracksResult != nil {
            saveLibraryCache()
        }
        isLoading = false
    }

    private func reloadCurrentSection() async {
        isLoading = true
        var didReload = false
        switch selectedSection {
        case .songs:
            if let result = try? await apiClient.fetchTracks(take: 50, sortBy: currentSort, sortOrder: currentSortOrder) {
                tracks = result.items
                total = result.total
                hasMore = tracks.count < total
                didReload = true
            }
        case .albums:
            if let result = try? await apiClient.fetchAlbums(take: 50, sort: currentSort, sortOrder: currentSortOrder) {
                albums = result.items
                didReload = true
            }
        case .artists:
            if let result = try? await apiClient.fetchArtists(take: 50, sort: currentSort, sortOrder: currentSortOrder) {
                artists = result.items
                didReload = true
            }
        case .playlists:
            break
        }
        if didReload {
            saveLibraryCache()
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, hasMore, selectedSection == .songs else { return }
        isLoading = true
        if let result = try? await apiClient.fetchTracks(skip: tracks.count, take: 50, sortBy: songsSort, sortOrder: songsSortOrder) {
            tracks.append(contentsOf: result.items)
            total = result.total
            hasMore = tracks.count < total
        }
        isLoading = false
    }

    // MARK: - Filtering

    private var cacheContext: DaoliYuLibraryCacheContext {
        DaoliYuLibraryCacheContext(
            serverURL: UserDefaults.standard.string(
                forKey: "daoliYuServerURL"
            ) ?? "",
            username: UserDefaults.standard.string(
                forKey: "daoliYuUsername"
            ) ?? "",
            songsSort: songsSort,
            songsSortOrder: songsSortOrder,
            artistsSort: artistsSort,
            artistsSortOrder: artistsSortOrder,
            albumsSort: albumsSort,
            albumsSortOrder: albumsSortOrder
        )
    }

    private func saveLibraryCache() {
        DaoliYuLibraryCache.save(
            context: cacheContext,
            playlists: playlists,
            artists: artists,
            albums: albums,
            tracks: tracks,
            trackTotal: total
        )
    }

    private var filteredPlaylists: [DaoliYuPlaylist] {
        guard normalizedSearchText.count >= 2 else { return playlists }
        return playlists.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedSearchText)
        }
    }

    private func orderedPlaylists(_ source: [DaoliYuPlaylist]) -> [DaoliYuPlaylist] {
        let systemFavorites = source.filter {
            $0.description == "__system_default_favorites__"
        }
        let favorited = source.filter {
            $0.description != "__system_default_favorites__"
                && favorites.favoritePlaylistIds.contains($0.id)
        }
        let others = source.filter {
            $0.description != "__system_default_favorites__"
                && !favorites.favoritePlaylistIds.contains($0.id)
        }
        return systemFavorites + favorited + others
    }

    private var filteredArtists: [DaoliYuArtist] {
        artists
    }

    private var filteredAlbums: [DaoliYuAlbum] {
        albums
    }

    private var filteredTracks: [DaoliYuTrack] {
        tracks
    }
}

// MARK: - Now Playing Tab

private struct NowPlayingTabView: View {
    @ObservedObject private var manager = DaoliYuManager.shared
    @ObservedObject private var audioEngine = DaoliYuManager.shared.audioEngine
    @ObservedObject private var playQueue = DaoliYuManager.shared.playQueue
    @ObservedObject private var lyricsManager = DaoliYuManager.shared.lyricsManager
    @ObservedObject private var favorites = DaoliYuFavoritesManager.shared
    @State private var subMode: SubMode = .cover

    enum SubMode: String, CaseIterable {
        case cover = "Cover"
        case lyrics = "Lyrics"
        case queue = "Queue"

        var icon: String {
            switch self {
            case .cover: return "photo"
            case .lyrics: return "text.quote"
            case .queue: return "list.bullet"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if playQueue.currentTrack == nil {
                emptyState
            } else {
                subModePicker
                switch subMode {
                case .cover:
                    coverMode
                case .lyrics:
                    lyricsMode
                case .queue:
                    queueMode
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("暂无播放")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("播放一首歌曲开始")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subModePicker: some View {
        HStack(spacing: 4) {
            ForEach(SubMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { subMode = mode }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 9))
                        Text(mode.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(subMode == mode ? Color.white.opacity(0.15) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Cover Mode

    private var coverMode: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 4)

            ZStack {
                if let image = manager.albumArtImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: Color(nsColor: manager.dominantColor).opacity(0.5), radius: 20, x: 0, y: 8)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 160, height: 160)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .scaleEffect(audioEngine.isPlaying ? 1.0 : 0.85)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: audioEngine.isPlaying)

            if let track = playQueue.currentTrack {
                VStack(spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artistName ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
            }

            progressBar
            playbackControls
            secondaryControls

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color(nsColor: manager.dominantColor).opacity(0.3), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var progressBar: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 3)

                    // Playback progress
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: max(0, geo.size.width * progress), height: 3)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pct = max(0, min(1, value.location.x / geo.size.width))
                            manager.seek(to: audioEngine.duration * pct)
                        }
                )
            }
            .frame(height: 3)

            HStack {
                Text(formatTime(audioEngine.currentTime))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("-" + formatTime(max(0, audioEngine.duration - audioEngine.currentTime)))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
    }

    private var progress: Double {
        guard audioEngine.duration > 0 else { return 0 }
        return audioEngine.currentTime / audioEngine.duration
    }

    private var playbackControls: some View {
        HStack(spacing: 24) {
            Button { manager.playPrevious() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Button { manager.togglePlayPause() } label: {
                Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)

            Button { manager.playNext() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 12) {
            Button { playQueue.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 10))
                    .foregroundStyle(playQueue.shuffleEnabled ? Color.white : Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)

            Button { playQueue.cycleRepeat() } label: {
                Image(systemName: repeatIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(playQueue.repeatMode != .off ? Color.white : Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)

            Button { manager.crossfadeEnabled.toggle() } label: {
                Image(systemName: "circle.dotted.and.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(manager.crossfadeEnabled ? Color.white : Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)

            if let track = playQueue.currentTrack {
                Button { favorites.toggleTrack(id: track.id) } label: {
                    Image(systemName: favorites.favoriteTrackIds.contains(track.id) ? "heart.fill" : "heart")
                        .font(.system(size: 10))
                        .foregroundStyle(favorites.favoriteTrackIds.contains(track.id) ? Color.pink : Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            Button { manager.addToQueue(track: playQueue.currentTrack!) } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .opacity(playQueue.currentTrack != nil ? 1 : 0)
        }
    }

    private var repeatIcon: String {
        switch playQueue.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    // MARK: - Lyrics Mode

    private var lyricsMode: some View {
        VStack(spacing: 0) {
            if lyricsManager.lines.isEmpty {
                Spacer()
                if lyricsManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("加载歌词中...")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "text.quote")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("暂无歌词")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                Spacer()
            } else {
                lyricsScrollView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    Spacer(minLength: 40)
                    ForEach(lyricsManager.lines) { line in
                        Button {
                            if let time = line.time {
                                manager.seek(to: time)
                            }
                        } label: {
                            Text(line.text)
                                .font(.system(size: line.id == lyricsManager.activeLineIndex ? 12 : 11, weight: line.id == lyricsManager.activeLineIndex ? .semibold : .regular))
                                .foregroundStyle(Color.white.opacity(line.id == lyricsManager.activeLineIndex ? 1.0 : 0.35))
                                .scaleEffect(line.id == lyricsManager.activeLineIndex ? 1.05 : 1.0)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                                .id(line.id)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 16)
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: 30)
                    Color.white
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 30)
                }
            )
            .onChange(of: lyricsManager.activeLineIndex) { newIndex in
                guard newIndex >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Queue Mode

    private var queueMode: some View {
        VStack(spacing: 0) {
            queueModeControls
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !playQueue.history.isEmpty {
                            Section {
                                ForEach(playQueue.history.suffix(10)) { track in
                                    queueTrackRow(track, style: .history) {
                                        manager.play(track: track)
                                    }
                                }
                            } header: {
                                queueSectionHeader("播放历史") {
                                    Button {
                                        playQueue.clearHistory()
                                    } label: {
                                        Text("清除")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if let current = playQueue.currentTrack {
                            Section {
                                nowPlayingCard(current)
                                    .id("now_playing")
                            } header: {
                                queueSectionHeader("正在播放")
                            }
                        }

                        if !playQueue.queue.isEmpty {
                            Section {
                                ForEach(playQueue.queue) { track in
                                    queueTrackRow(track, style: .upNext) {
                                        manager.play(track: track)
                                    } onDelete: {
                                        playQueue.removeFromQueue(id: track.id)
                                    }
                                }
                            } header: {
                                queueSectionHeader("即将播放 · \(playQueue.queue.count)")
                            }
                        }

                        if !playQueue.autoPlayTracks.isEmpty {
                            Section {
                                ForEach(playQueue.autoPlayTracks.prefix(10)) { track in
                                    queueTrackRow(track, style: .autoPlay) {
                                        manager.play(track: track)
                                    }
                                }
                            } header: {
                                queueSectionHeader("自动播放 · \(playQueue.autoPlayTracks.count)")
                            }
                        }

                        if playQueue.queue.isEmpty && playQueue.autoPlayTracks.isEmpty && playQueue.currentTrack == nil {
                            VStack(spacing: 6) {
                                Spacer(minLength: 30)
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.tertiary)
                                Text("队列为空")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 30)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 8)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("now_playing", anchor: .top)
                    }
                }
                .onChange(of: playQueue.currentTrack?.id) { _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo("now_playing", anchor: .top)
                    }
                }
            }
        }
    }

    private var queueModeControls: some View {
        HStack(spacing: 10) {
            Button { playQueue.toggleShuffle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 9))
                    Text("随机播放")
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(playQueue.shuffleEnabled ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
                .foregroundStyle(playQueue.shuffleEnabled ? Color.white : Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button { playQueue.cycleRepeat() } label: {
                HStack(spacing: 3) {
                    Image(systemName: repeatIcon)
                        .font(.system(size: 9))
                    Text(repeatLabel)
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(playQueue.repeatMode != .off ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
                .foregroundStyle(playQueue.repeatMode != .off ? Color.white : Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button {
                playQueue.autoPlayEnabled.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "infinity")
                        .font(.system(size: 9))
                    Text("自动")
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(playQueue.autoPlayEnabled ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
                .foregroundStyle(playQueue.autoPlayEnabled ? Color.white : Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button { manager.crossfadeEnabled.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "circle.dotted.and.circle")
                        .font(.system(size: 9))
                    Text("淡入淡出")
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(manager.crossfadeEnabled ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(Capsule())
                .foregroundStyle(manager.crossfadeEnabled ? Color.white : Color.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var repeatLabel: String {
        switch playQueue.repeatMode {
        case .off: return "Repeat"
        case .all: return "All"
        case .one: return "One"
        }
    }

    private func queueSectionHeader(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.black.opacity(0.85))
    }

    private func nowPlayingCard(_ track: DaoliYuTrack) -> some View {
        HStack(spacing: 8) {
            DaoliYuCoverImage(path: track.coverArt ?? track.album?.coverArt, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(track.artistName ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                DaoliYuFavoritesManager.shared.toggleTrack(id: track.id)
            } label: {
                Image(systemName: DaoliYuFavoritesManager.shared.favoriteTrackIds.contains(track.id) ? "heart.fill" : "heart")
                    .font(.system(size: 10))
                    .foregroundStyle(DaoliYuFavoritesManager.shared.favoriteTrackIds.contains(track.id) ? .red : .white.opacity(0.6))
            }
            .buttonStyle(.plain)
            Image(systemName: "waveform")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.6))
                .symbolEffect(.variableColor.iterative, isActive: audioEngine.isPlaying)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 2)
        .contextMenu { trackContextMenu(track) }
    }

    enum QueueRowStyle { case history, upNext, autoPlay }

    private func queueTrackRow(_ track: DaoliYuTrack, style: QueueRowStyle, onTap: @escaping () -> Void, onDelete: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Button { onTap() } label: {
                HStack(spacing: 6) {
                    DaoliYuCoverImage(path: track.coverArt ?? track.album?.coverArt, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Text(track.artistName ?? "")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(style == .history ? 0.5 : (style == .autoPlay ? 0.7 : 1.0))

            if let onDelete {
                Button { onDelete() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
    }
}

// MARK: - Add to Playlist Sheet

private struct AddToPlaylistSheet: View {
    let track: DaoliYuTrack
    let playlists: [DaoliYuPlaylist]
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 8 * libraryScale) {
            HStack {
                Text("添加到歌单")
                    .font(.system(size: libraryFontSize(11), weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: libraryFontSize(12)))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12 * libraryScale)
            .padding(.top, 8 * libraryScale)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4 * libraryScale) {
                    ForEach(playlists) { playlist in
                        Button {
                            Task {
                                isAdding = true
                                try? await DaoliYuAPIClient.shared.addTrackToPlaylist(playlistId: playlist.id, trackId: track.id)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 8 * libraryScale) {
                                DaoliYuCoverImage(path: playlist.coverArt, size: 24 * libraryScale)
                                Text(playlist.name)
                                    .font(.system(size: libraryFontSize(10)))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(playlist.trackCount)")
                                    .font(.system(size: libraryFontSize(9)))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4 * libraryScale)
                            .padding(.horizontal, 8 * libraryScale)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAdding)
                    }
                }
            }
            .frame(maxHeight: 200 * libraryScale)
        }
        .padding(.bottom, 8 * libraryScale)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Sub-Detail Views

private struct AlbumDetailSubview: View {
    let album: DaoliYuAlbum
    let manager: DaoliYuManager
    @ObservedObject private var favorites = DaoliYuFavoritesManager.shared
    @State private var tracks: [DaoliYuTrack] = []

    var body: some View {
        VStack(spacing: 4 * libraryScale) {
            HStack(spacing: 8 * libraryScale) {
                DaoliYuCoverImage(path: album.coverArt, size: 40 * libraryScale)
                VStack(alignment: .leading, spacing: 2 * libraryScale) {
                    Text(album.title)
                        .font(.system(size: libraryFontSize(11), weight: .semibold))
                        .lineLimit(1)
                    Text(album.albumArtist ?? "")
                        .font(.system(size: libraryFontSize(9)))
                        .foregroundStyle(.secondary)
                    if let year = album.releaseYear {
                        Text("\(year)")
                            .font(.system(size: libraryFontSize(8)))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button {
                    if !tracks.isEmpty { manager.play(tracks: tracks.shuffled()) }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: libraryFontSize(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    if !tracks.isEmpty { manager.play(tracks: tracks) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: libraryFontSize(12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12 * libraryScale)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2 * libraryScale) {
                    ForEach(tracks) { track in
                        HStack(spacing: 6 * libraryScale) {
                            Button { manager.play(track: track) } label: {
                                HStack(spacing: 6 * libraryScale) {
                                    if let num = track.trackNumber {
                                        Text("\(num)")
                                            .font(.system(size: libraryFontSize(9)))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 16 * libraryScale)
                                    }
                                    Text(track.title)
                                        .font(.system(size: libraryFontSize(10)))
                                        .lineLimit(1)
                                    Spacer()
                                    if let d = track.durationSeconds {
                                        Text(formatDuration(d))
                                            .font(.system(size: libraryFontSize(8)))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button { favorites.toggleTrack(id: track.id) } label: {
                                Image(systemName: favorites.favoriteTrackIds.contains(track.id) ? "heart.fill" : "heart")
                                    .font(.system(size: libraryFontSize(9)))
                                    .foregroundStyle(favorites.favoriteTrackIds.contains(track.id) ? Color.pink : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3 * libraryScale)
                        .padding(.horizontal, 6 * libraryScale)
                        .contextMenu { trackContextMenu(track) }
                    }
                }
                .padding(.horizontal, 8 * libraryScale)
            }
        }
        .task {
            if let detail = try? await DaoliYuAPIClient.shared.fetchAlbumDetail(id: album.id) {
                tracks = detail.tracks ?? []
            }
        }
    }
}

private struct ArtistDetailSubview: View {
    let artist: DaoliYuArtist
    let manager: DaoliYuManager
    let onSelectAlbum: (DaoliYuAlbum) -> Void
    @ObservedObject private var favorites = DaoliYuFavoritesManager.shared
    @State private var tracks: [DaoliYuTrack] = []
    @State private var albums: [DaoliYuAlbum] = []

    var body: some View {
        VStack(spacing: 4 * libraryScale) {
            HStack(spacing: 8 * libraryScale) {
                DaoliYuCoverImage(path: artist.coverArt, size: 36 * libraryScale, isCircle: true)
                VStack(alignment: .leading, spacing: 2 * libraryScale) {
                    Text(artist.name)
                        .font(.system(size: libraryFontSize(11), weight: .semibold))
                        .lineLimit(1)
                    if let count = artist.trackCount {
                        Text("\(count) 首")
                            .font(.system(size: libraryFontSize(9)))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { favorites.toggleArtist(id: artist.id) } label: {
                    Image(systemName: favorites.favoriteArtistIds.contains(artist.id) ? "heart.fill" : "heart")
                        .font(.system(size: libraryFontSize(11)))
                        .foregroundStyle(favorites.favoriteArtistIds.contains(artist.id) ? Color.pink : Color.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    if !tracks.isEmpty { manager.play(tracks: tracks.shuffled()) }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: libraryFontSize(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    if !tracks.isEmpty { manager.play(tracks: tracks) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: libraryFontSize(12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12 * libraryScale)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2 * libraryScale) {
                    if !albums.isEmpty {
                        Text("专辑")
                            .font(.system(size: libraryFontSize(9), weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6 * libraryScale)
                            .padding(.top, 4 * libraryScale)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8 * libraryScale) {
                                ForEach(albums) { album in
                                    Button {
                                        onSelectAlbum(album)
                                    } label: {
                                        VStack(spacing: 3 * libraryScale) {
                                            DaoliYuCoverImage(path: album.coverArt, size: 48 * libraryScale)
                                            Text(album.title)
                                                .font(.system(size: libraryFontSize(8)))
                                                .lineLimit(1)
                                                .frame(width: 48 * libraryScale)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 6 * libraryScale)
                        }
                        .frame(height: 68 * libraryScale)
                    }

                    Text("曲目")
                        .font(.system(size: libraryFontSize(9), weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6 * libraryScale)
                        .padding(.top, 4 * libraryScale)

                    ForEach(tracks) { track in
                        Button { manager.play(track: track) } label: {
                            HStack(spacing: 6 * libraryScale) {
                                Text(track.title)
                                    .font(.system(size: libraryFontSize(10)))
                                    .lineLimit(1)
                                Spacer()
                                Text(track.album?.title ?? "")
                                    .font(.system(size: libraryFontSize(9)))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 3 * libraryScale)
                            .padding(.horizontal, 6 * libraryScale)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { trackContextMenu(track) }
                    }
                }
                .padding(.horizontal, 8 * libraryScale)
            }
        }
        .task {
            if let detail = try? await DaoliYuAPIClient.shared.fetchArtistDetail(id: artist.id) {
                tracks = detail.tracks ?? []
                albums = detail.albums ?? []
            }
            if albums.isEmpty,
               let result = try? await DaoliYuAPIClient.shared.fetchAlbums(
                   take: 100,
                   search: artist.name
               ) {
                albums = result.items.filter {
                    $0.albumArtist?.localizedCaseInsensitiveContains(artist.name) == true
                }
            }
        }
    }
}

// MARK: - Playlist Detail

private struct PlaylistDetailSubview: View {
    let playlist: DaoliYuPlaylist
    let manager: DaoliYuManager
    @ObservedObject private var favorites = DaoliYuFavoritesManager.shared
    @State private var tracks: [DaoliYuTrack] = []
    @State private var totalTracks: Int = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isFavoritesPlaylist = false

    private let pageSize = 50

    var body: some View {
        VStack(spacing: 4 * libraryScale) {
            HStack(spacing: 8 * libraryScale) {
                DaoliYuCoverImage(path: playlist.coverArt, size: 40 * libraryScale)
                VStack(alignment: .leading, spacing: 2 * libraryScale) {
                    Text(playlist.name)
                        .font(.system(size: libraryFontSize(11), weight: .semibold))
                        .lineLimit(1)
                    if let desc = playlist.description, desc != "__system_default_favorites__" {
                        Text(desc)
                            .font(.system(size: libraryFontSize(9)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("\(totalTracks) 首")
                        .font(.system(size: libraryFontSize(8)))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    if !tracks.isEmpty { manager.play(tracks: tracks.shuffled()) }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: libraryFontSize(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button {
                    if !tracks.isEmpty { manager.play(tracks: tracks) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: libraryFontSize(12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12 * libraryScale)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2 * libraryScale) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 6 * libraryScale) {
                            Button { manager.play(track: track) } label: {
                                HStack(spacing: 6 * libraryScale) {
                                    DaoliYuCoverImage(path: track.coverArt ?? track.album?.coverArt, size: 24 * libraryScale)
                                    VStack(alignment: .leading, spacing: 1 * libraryScale) {
                                        Text(track.title)
                                            .font(.system(size: libraryFontSize(10)))
                                            .lineLimit(1)
                                        Text(track.artistName ?? "")
                                            .font(.system(size: libraryFontSize(8)))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button { favorites.toggleTrack(id: track.id) } label: {
                                Image(systemName: favorites.favoriteTrackIds.contains(track.id) ? "heart.fill" : "heart")
                                    .font(.system(size: libraryFontSize(9)))
                                    .foregroundStyle(favorites.favoriteTrackIds.contains(track.id) ? Color.pink : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2 * libraryScale)
                        .padding(.horizontal, 6 * libraryScale)
                        .contextMenu { trackContextMenu(track) }
                        .onAppear {
                            if index >= tracks.count - 5 {
                                Task { await loadMore() }
                            }
                        }
                    }

                    if hasMore {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("加载更多 (\(tracks.count)/\(totalTracks))")
                                    .font(.system(size: libraryFontSize(9)))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6 * libraryScale)
                    }
                }
                .padding(.horizontal, 8 * libraryScale)
            }
        }
        .task { await loadInitial() }
    }

    private func loadInitial() async {
        isLoading = true
        isFavoritesPlaylist = playlist.description == "__system_default_favorites__"

        do {
            let result = try await DaoliYuAPIClient.shared.fetchPlaylistTracks(id: playlist.id, skip: 0, take: pageSize)
            totalTracks = result.total

            if isFavoritesPlaylist && result.total > pageSize {
                // For favorites playlist, load from the last page and reverse (newest first)
                let skip = max(0, result.total - pageSize)
                let lastPageResult = try await DaoliYuAPIClient.shared.fetchPlaylistTracks(id: playlist.id, skip: skip, take: pageSize)
                tracks = lastPageResult.items.compactMap { $0.track }.reversed()
                hasMore = skip > 0
            } else {
                tracks = result.items.compactMap { $0.track }
                if isFavoritesPlaylist {
                    tracks = tracks.reversed()
                }
                hasMore = tracks.count < result.total
            }
        } catch {
            // Fallback silently
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true

        do {
            if isFavoritesPlaylist {
                // For favorites, load earlier pages (going backwards)
                let alreadyLoaded = tracks.count
                let remainingFromStart = max(0, totalTracks - alreadyLoaded)
                let skip = max(0, remainingFromStart - pageSize)
                let take = min(pageSize, remainingFromStart)
                guard take > 0 else {
                    hasMore = false
                    isLoading = false
                    return
                }
                let result = try await DaoliYuAPIClient.shared.fetchPlaylistTracks(id: playlist.id, skip: skip, take: take)
                let newTracks = result.items.compactMap { $0.track }.reversed()
                tracks.append(contentsOf: newTracks)
                hasMore = skip > 0
            } else {
                let result = try await DaoliYuAPIClient.shared.fetchPlaylistTracks(id: playlist.id, skip: tracks.count, take: pageSize)
                let newTracks = result.items.compactMap { $0.track }
                tracks.append(contentsOf: newTracks)
                totalTracks = result.total
                hasMore = tracks.count < totalTracks
            }
        } catch {
            // Fallback silently
        }
        isLoading = false
    }
}

// MARK: - Shared Detail Context

private enum DetailContext: Identifiable {
    case album(DaoliYuAlbum)
    case artist(DaoliYuArtist)
    case playlist(DaoliYuPlaylist)

    var id: String {
        switch self {
        case .album(let a): return "album-\(a.id)"
        case .artist(let a): return "artist-\(a.id)"
        case .playlist(let p): return "playlist-\(p.id)"
        }
    }
}

// MARK: - Track Context Menu

@ViewBuilder
private func trackContextMenu(_ track: DaoliYuTrack) -> some View {
    Button {
        DaoliYuManager.shared.play(track: track)
    } label: {
        Label("Play Now", systemImage: "play.fill")
    }

    Button {
        DaoliYuManager.shared.addToQueue(track: track)
    } label: {
        Label("Add to Queue", systemImage: "text.badge.plus")
    }

    Divider()

    Button {
        DaoliYuFavoritesManager.shared.toggleTrack(id: track.id)
    } label: {
        if DaoliYuFavoritesManager.shared.favoriteTrackIds.contains(track.id) {
            Label("Remove from Favorites", systemImage: "heart.slash")
        } else {
            Label("Add to Favorites", systemImage: "heart")
        }
    }
}

// MARK: - Cover Image with Auth

struct DaoliYuCoverImage: View {
    let path: String?
    let size: CGFloat
    var isCircle: Bool = false

    @StateObject private var loader = CoverImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.15)))
        .task(id: "\(path ?? "")-\(size)") {
            await loader.load(path: path, displaySize: size)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.15)
            .fill(Color.white.opacity(0.08))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.tertiary)
            }
    }
}

@MainActor
private class CoverImageLoader: ObservableObject {
    @Published var image: NSImage?

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func load(path: String?, displaySize: CGFloat) async {
        guard let url = DaoliYuAPIClient.shared.coverArtURL(path: path) else {
            image = nil
            return
        }

        let pixelSize = max(64, Int((displaySize * 2).rounded(.up)))
        let key = "\(url.absoluteString)#\(pixelSize)" as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }

        var request = URLRequest(url: url)
        for (k, v) in DaoliYuAPIClient.shared.authHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize
                ] as CFDictionary
              ) else { return }

        let loaded = NSImage(cgImage: cgImage, size: .zero)
        Self.cache.setObject(
            loaded,
            forKey: key,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        image = loaded
    }
}

// MARK: - Utilities

private func formatDuration(_ seconds: Int) -> String {
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%d:%02d", m, s)
}

private func formatTime(_ time: TimeInterval) -> String {
    guard time.isFinite && time >= 0 else { return "0:00" }
    let total = Int(time)
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}
