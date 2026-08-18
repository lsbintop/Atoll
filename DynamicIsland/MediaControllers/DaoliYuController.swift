import Foundation
import Combine
import AppKit

@MainActor
class DaoliYuController: ObservableObject, MediaControllerProtocol {
    private let manager = DaoliYuManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let stateSubject = PassthroughSubject<PlaybackState, Never>()
    private var updateTimer: Timer?

    nonisolated var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    @Published var isWorking: Bool = false

    init() {
        startPolling()
    }

    deinit {
        updateTimer?.invalidate()
    }

    func play() async {
        manager.resumePlayback()
    }

    func pause() async {
        manager.pausePlayback()
    }

    func seek(to time: Double) async {
        manager.seek(to: time)
    }

    func nextTrack() async {
        manager.playNext()
    }

    func previousTrack() async {
        manager.playPrevious()
    }

    func togglePlay() async {
        manager.togglePlayPause()
    }

    func toggleShuffle() async {
        manager.playQueue.toggleShuffle()
    }

    func toggleRepeat() async {
        manager.playQueue.cycleRepeat()
    }

    nonisolated func isActive() -> Bool {
        MainActor.assumeIsolated { manager.isActive }
    }

    func updatePlaybackInfo() async {
        publishState()
    }

    // MARK: - Private

    private func startPolling() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.publishState()
            }
        }
    }

    private func publishState() {
        let engine = manager.audioEngine
        let queue = manager.playQueue

        guard let track = queue.currentTrack else { return }

        let repeatMode: RepeatMode = {
            switch queue.repeatMode {
            case .off: return .off
            case .all: return .all
            case .one: return .one
            }
        }()

        var state = PlaybackState(bundleIdentifier: "com.lsbin.daoliyu")
        state.isPlaying = engine.isPlaying
        state.title = track.title
        state.artist = track.artistName ?? track.artists?.compactMap(\.name).joined(separator: ", ") ?? ""
        state.album = track.album?.title ?? ""
        state.currentTime = engine.currentTime
        state.duration = engine.duration > 0 ? engine.duration : Double(track.durationSeconds ?? 0)
        state.isShuffled = queue.shuffleEnabled
        state.repeatMode = repeatMode
        state.lastUpdated = Date()

        if let artData = manager.albumArtImage?.tiffRepresentation {
            state.artwork = artData
        }

        stateSubject.send(state)
    }
}
