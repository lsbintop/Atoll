import Foundation
import AppKit
import Combine
import MediaPlayer
import ImageIO

@MainActor
final class DaoliYuManager: ObservableObject {
    static let shared = DaoliYuManager()

    let apiClient = DaoliYuAPIClient.shared
    let audioEngine = DaoliYuAudioEngine()
    let playQueue = DaoliYuPlayQueue()
    let lyricsManager = DaoliYuLyricsManager()
    let favoritesManager = DaoliYuFavoritesManager.shared

    @Published var albumArtImage: NSImage?
    @Published var dominantColor: NSColor = .black
    @Published var isLoadingArt = false
    @Published var crossfadeEnabled = false { didSet { schedulePersist() } }
    @Published var crossfadeDuration: TimeInterval = 5 { didSet { audioEngine.crossfadeDuration = crossfadeDuration; schedulePersist() } }

    enum RightPanelMode: CaseIterable {
        case calendar
        case queue
        case lyrics

        var next: Self {
            switch self {
            case .calendar: return .queue
            case .queue: return .lyrics
            case .lyrics: return .calendar
            }
        }

        var iconName: String {
            switch self {
            case .calendar: return "calendar"
            case .queue: return "list.bullet"
            case .lyrics: return "text.quote"
            }
        }
    }

    @Published var rightPanelMode: RightPanelMode = .calendar

    func cycleRightPanel() {
        rightPanelMode = rightPanelMode.next
    }

    private let artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var dominantColorCache: [String: NSColor] = [:]
    private let imageSession = URLSession(configuration: .default)
    private var lastPositionReport: TimeInterval = 0
    private var positionReportTimer: Timer?
    private var persistDebounceTask: Task<Void, Never>?

    private init() {
        setupCallbacks()
        setupRemoteCommands()
        restoreState()
        if apiClient.isAuthenticated {
            Task { await favoritesManager.loadAll() }
        }
    }

    var isActive: Bool {
        apiClient.isAuthenticated && (audioEngine.isPlaying || playQueue.currentTrack != nil)
    }

    // MARK: - Playback Control

    func play(track: DaoliYuTrack) {
        playQueue.playNow(track)
        startPlayback(track: track)
    }

    func play(tracks: [DaoliYuTrack], startAt index: Int = 0) {
        playQueue.load(tracks, startAt: index)
        if let track = playQueue.currentTrack {
            startPlayback(track: track)
        }
    }

    func togglePlayPause() {
        if audioEngine.isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard playQueue.currentTrack != nil else { return }
        audioEngine.resume()
        updateNowPlayingPlaybackState()
        schedulePersist()
    }

    func pausePlayback() {
        guard playQueue.currentTrack != nil else { return }
        audioEngine.pause()
        updateNowPlayingPlaybackState()
        schedulePersist()
    }

    func playNext() {
        if let next = playQueue.next(manual: true) {
            startPlayback(track: next)
        } else {
            audioEngine.stop()
            updateNowPlayingPlaybackState()
            if playQueue.autoPlayEnabled {
                Task { await fetchAndPlayRandom() }
            }
        }
    }

    func playPrevious() {
        if audioEngine.currentTime > 3 {
            audioEngine.seek(to: 0)
        } else if let prev = playQueue.previous() {
            startPlayback(track: prev)
        }
    }

    func seek(to time: Double) {
        if time < audioEngine.timeOffset {
            handleBufferInvalidated(at: time)
        } else {
            audioEngine.seek(to: time)
        }
        updateNowPlayingElapsedTime()
        schedulePersist()
    }

    func addToQueue(track: DaoliYuTrack) {
        playQueue.addToQueue(track)
    }

    func addToQueue(tracks: [DaoliYuTrack]) {
        playQueue.addToQueue(tracks)
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        audioEngine.onTrackFinished = { [weak self] in
            self?.handleTrackFinished()
        }
        audioEngine.onTimeUpdate = { [weak self] in
            self?.handleTimeUpdate()
        }
        audioEngine.onCrossfadeTrigger = { [weak self] in
            self?.handleCrossfadeTrigger()
        }
        audioEngine.onBufferInvalidated = { [weak self] position in
            self?.handleBufferInvalidated(at: position)
        }
    }

    private func handleTrackFinished() {
        if let next = playQueue.next() {
            startPlayback(track: next)
        } else if playQueue.autoPlayEnabled {
            Task { await fetchAndPlayRandom() }
        } else {
            audioEngine.stop()
            updateNowPlayingPlaybackState()
        }
    }

    private func handleTimeUpdate() {
        let lyricChanged = lyricsManager.updateActiveLine(for: audioEngine.currentTime)
        if lyricChanged { updateNowPlayingLyrics() }
        reportPositionIfNeeded()
        checkAndFillAutoPlay()
    }

    private func handleCrossfadeTrigger() {
        guard crossfadeEnabled else {
            return
        }
        guard let next = playQueue.next() else {
            return
        }
        let quality = currentQuality
        guard let url = apiClient.streamURL(trackId: next.id, quality: quality) else {
            return
        }
        let headers = apiClient.authHeaders()
        audioEngine.crossfadePlay(url: url, headers: headers)
        if let seconds = next.durationSeconds, seconds > 0 {
            audioEngine.duration = TimeInterval(seconds)
        }
        playQueue.currentTrack = next
        lastPositionReport = 0
        loadAlbumArt(for: next)
        Task { await lyricsManager.load(trackId: next.id) }
        updateNowPlayingInfo(for: next)
        Task { await apiClient.reportPlay(trackId: next.id) }
        schedulePersist()
    }

    private func handleBufferInvalidated(at position: TimeInterval) {
        guard let track = playQueue.currentTrack else { return }
        let quality = currentQuality
        let offset = TimeInterval(max(0, Int(position)))
        guard let url = apiClient.streamURL(
            trackId: track.id,
            quality: quality,
            offset: offset
        ) else {
            return
        }
        let headers = apiClient.authHeaders()
        let savedDuration = audioEngine.duration
        audioEngine.play(url: url, headers: headers, offset: offset)
        audioEngine.duration = savedDuration > 0
            ? savedDuration
            : TimeInterval(track.durationSeconds ?? 0)
        audioEngine.currentTime = position
        lastPositionReport = position
        updateNowPlayingElapsedTime()
    }

    // MARK: - Position Reporting

    private func reportPositionIfNeeded() {
        guard audioEngine.isPlaying,
              let track = playQueue.currentTrack else { return }
        let now = audioEngine.currentTime
        if abs(now - lastPositionReport) >= 15 {
            lastPositionReport = now
            Task { await apiClient.reportPosition(trackId: track.id, positionSeconds: Int(now)) }
        }
    }

    // MARK: - Auto-Play

    private func checkAndFillAutoPlay() {
        guard playQueue.autoPlayEnabled, playQueue.remainingCount < 5 else { return }
        Task { await loadAutoPlayTracks() }
    }

    private func loadAutoPlayTracks() async {
        guard let response = try? await apiClient.fetchRandomTracks(count: 10) else { return }
        playQueue.appendAutoPlayTracks(response.items)
    }

    private func fetchAndPlayRandom() async {
        guard let response = try? await apiClient.fetchRandomTracks(count: 20) else { return }
        playQueue.appendAutoPlayTracks(response.items)
        if let next = playQueue.next() {
            startPlayback(track: next)
        }
    }

    // MARK: - Playback

    private var currentQuality: DaoliYuAudioQuality {
        DaoliYuAudioQuality(rawValue: UserDefaults.standard.integer(forKey: "daoliYuStreamQuality")) ?? .original
    }

    private func startPlayback(track: DaoliYuTrack) {
        let quality = currentQuality
        guard let url = apiClient.streamURL(trackId: track.id, quality: quality) else { return }
        let headers = apiClient.authHeaders()
        audioEngine.play(url: url, headers: headers)
        if let sec = track.durationSeconds, sec > 0 {
            audioEngine.duration = TimeInterval(sec)
        }
        lastPositionReport = 0
        loadAlbumArt(for: track)
        Task { await lyricsManager.load(trackId: track.id) }
        updateNowPlayingInfo(for: track)
        Task { await apiClient.reportPlay(trackId: track.id) }
        schedulePersist()
    }

    // MARK: - Album Art + Dominant Color

    private func loadAlbumArt(for track: DaoliYuTrack) {
        let coverPath = track.coverArt ?? track.album?.coverArt
        guard let url = apiClient.coverArtURL(path: coverPath) else {
            albumArtImage = nil
            return
        }

        let keyString = url.absoluteString
        let key = keyString as NSString
        if let cached = artworkCache.object(forKey: key) {
            albumArtImage = cached
            dominantColor = dominantColorCache[keyString] ?? .black
            updateNowPlayingInfo(for: track)
            return
        }

        isLoadingArt = true
        Task {
            var request = URLRequest(url: url)
            for (k, v) in apiClient.authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
            if let (data, _) = try? await imageSession.data(for: request),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(
                   source,
                   0,
                   [
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 600
                   ] as CFDictionary
               ) {
                let image = NSImage(cgImage: cgImage, size: .zero)
                artworkCache.setObject(
                    image,
                    forKey: key,
                    cost: cgImage.bytesPerRow * cgImage.height
                )
                albumArtImage = image
                let color = extractDominantColor(from: image)
                dominantColorCache[keyString] = color
                dominantColor = color
            }
            isLoadingArt = false
            if let current = playQueue.currentTrack {
                updateNowPlayingInfo(for: current)
            }
        }
    }

    private func extractDominantColor(from image: NSImage) -> NSColor {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return .black }
        let size = 20
        let resized = NSImage(size: NSSize(width: size, height: size))
        resized.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        resized.unlockFocus()

        guard let resizedTiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: resizedTiff) else { return .black }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        var count: CGFloat = 0
        for x in 0..<size {
            for y in 0..<size {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    r += color.redComponent
                    g += color.greenComponent
                    b += color.blueComponent
                    count += 1
                }
            }
        }
        guard count > 0 else { return .black }
        return NSColor(red: (r / count) * 0.7, green: (g / count) * 0.7, blue: (b / count) * 0.7, alpha: 1)
    }

    // MARK: - System Media Integration

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.playQueue.currentTrack != nil else {
                return .noSuchContent
            }
            Task { @MainActor in
                self.resumePlayback()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.playQueue.currentTrack != nil else {
                return .noSuchContent
            }
            Task { @MainActor in
                self.pausePlayback()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.playQueue.currentTrack != nil else {
                return .noSuchContent
            }
            Task { @MainActor in self.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.playQueue.currentTrack != nil else {
                return .noSuchContent
            }
            Task { @MainActor in self.playNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.playQueue.currentTrack != nil else {
                return .noSuchContent
            }
            Task { @MainActor in self.playPrevious() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.playQueue.currentTrack != nil else {
                return .noSuchContent
            }
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self.seek(to: e.positionTime) }
            return .success
        }
        syncRemoteCommandState()
    }

    private func syncRemoteCommandState() {
        let center = MPRemoteCommandCenter.shared()
        let hasTrack = playQueue.currentTrack != nil
        let isPlaying = audioEngine.isPlaying

        center.playCommand.isEnabled = hasTrack && !isPlaying
        center.pauseCommand.isEnabled = hasTrack && isPlaying
        center.togglePlayPauseCommand.isEnabled = hasTrack
        center.changePlaybackPositionCommand.isEnabled = hasTrack
        center.previousTrackCommand.isEnabled = hasTrack
            && (audioEngine.currentTime > 3 || !playQueue.history.isEmpty)
        center.nextTrackCommand.isEnabled = hasTrack
            && (playQueue.remainingCount > 0
                || playQueue.repeatMode != .off
                || playQueue.autoPlayEnabled)

        if isPlaying {
            MPNowPlayingInfoCenter.default().playbackState = .playing
        } else if hasTrack {
            MPNowPlayingInfoCenter.default().playbackState = .paused
        } else {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    private func updateNowPlayingInfo(for track: DaoliYuTrack) {
        let currentLyric = lyricsManager.currentLyricText
        let title = currentLyric.flatMap { $0.isEmpty ? nil : $0 } ?? track.title
        let artist: String
        if currentLyric?.isEmpty == false {
            artist = "\(track.artistName ?? "") · \(track.title)"
        } else {
            artist = track.artistName ?? track.artists?.compactMap(\.name).joined(separator: ", ") ?? ""
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: track.album?.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audioEngine.currentTime,
            MPMediaItemPropertyPlaybackDuration: audioEngine.duration > 0 ? audioEngine.duration : Double(track.durationSeconds ?? 0),
            MPNowPlayingInfoPropertyPlaybackRate: audioEngine.isPlaying ? 1.0 : 0.0
        ]
        if let image = albumArtImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        syncRemoteCommandState()
    }

    private func updateNowPlayingElapsedTime() {
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioEngine.currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = audioEngine.isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        syncRemoteCommandState()
    }

    private func updateNowPlayingPlaybackState() {
        if let track = playQueue.currentTrack {
            updateNowPlayingInfo(for: track)
        } else {
            syncRemoteCommandState()
        }
    }

    private func updateNowPlayingLyrics() {
        guard let track = playQueue.currentTrack,
              let lyric = lyricsManager.currentLyricText,
              !lyric.isEmpty else { return }
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPMediaItemPropertyTitle] = lyric
        info[MPMediaItemPropertyArtist] = "\(track.artistName ?? "") · \(track.title)"
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - State Persistence

    private static let stateKey = "com.atoll.daoliyu.playbackState"

    struct PersistedPlaybackState: Codable {
        let queueState: DaoliYuPlayQueue.PersistedState
        let progress: Double
        let crossfadeEnabled: Bool
        let crossfadeDuration: TimeInterval
    }

    private func schedulePersist() {
        persistDebounceTask?.cancel()
        persistDebounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            persistState()
        }
    }

    private func persistState() {
        let progress = audioEngine.duration > 0 ? audioEngine.currentTime / audioEngine.duration : 0
        let state = PersistedPlaybackState(
            queueState: playQueue.persist(),
            progress: progress,
            crossfadeEnabled: crossfadeEnabled,
            crossfadeDuration: crossfadeDuration
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func restoreState() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data) else { return }

        playQueue.restore(from: state.queueState)
        crossfadeEnabled = state.crossfadeEnabled
        crossfadeDuration = state.crossfadeDuration

        guard let track = playQueue.currentTrack else { return }
        loadAlbumArt(for: track)
        Task { await lyricsManager.load(trackId: track.id) }
        updateNowPlayingInfo(for: track)

        let quality = currentQuality
        guard let url = apiClient.streamURL(trackId: track.id, quality: quality) else { return }
        let headers = apiClient.authHeaders()
        audioEngine.play(url: url, headers: headers)
        audioEngine.pause()

        let duration = Double(track.durationSeconds ?? 0)
        if duration > 0 && state.progress > 0 {
            let seekTime = duration * state.progress
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                audioEngine.seek(to: seekTime)
            }
        }
    }
}
