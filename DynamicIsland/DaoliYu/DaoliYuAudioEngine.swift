import AVFoundation
import Combine

@MainActor
final class DaoliYuAudioEngine: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isBuffering = false
    @Published var bufferProgress: Double = 0

    var crossfadeDuration: TimeInterval = 5 {
        didSet { crossfadeDuration = min(max(crossfadeDuration, 3), 10) }
    }

    var onTrackFinished: (() -> Void)?
    var onTimeUpdate: (() -> Void)?
    var onCrossfadeTrigger: (() -> Void)?
    var onBufferInvalidated: ((TimeInterval) -> Void)?

    var timeOffset: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var endTimeObserver: NSObjectProtocol?
    private var audioRouteObserver: NSObjectProtocol?

    private var stallTimer: Task<Void, Never>?
    private var pauseTimestamp: Date?
    private var lastReportedTime: TimeInterval = 0
    private var isSeeking = false
    private var crossfadeTriggerFired = false

    /// Crossfade: 淡出中的旧 player
    private var fadingOutPlayer: AVPlayer?
    private var fadingOutEndObserver: NSObjectProtocol?
    private weak var fadeInAppliedItem: AVPlayerItem?

    // MARK: - Playback

    func play(url: URL, headers: [String: String] = [:], offset: TimeInterval = 0) {
        stop()
        timeOffset = offset
        crossfadeTriggerFired = false
        currentTime = offset
        duration = 0
        lastReportedTime = offset

        let avPlayer = makePlayer(url: url, headers: headers)
        self.player = avPlayer
        setupObservers(player: avPlayer)
        setupAudioRouteDetection()
        avPlayer.play()
        isPlaying = true
        isBuffering = true
    }

    func crossfadePlay(url: URL, headers: [String: String] = [:], offset: TimeInterval = 0) {
        guard let oldPlayer = player else {
            play(url: url, headers: headers, offset: offset)
            return
        }

        // 1. 旧 player 移入 fadingOut 槽位并立即应用淡出 audioMix。
        cleanupFadingOutPlayer()
        fadingOutPlayer = oldPlayer
        applyFadeOutAudioMix()

        // 监听旧曲目自然结束后释放
        if let fadingItem = oldPlayer.currentItem {
            fadingOutEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: fadingItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.cleanupFadingOutPlayer()
                }
            }
        }

        // 清除旧 player 的 observers（但不 pause，让它继续播放并淡出）
        teardownObservers()
        player = nil

        // 2. 创建新 player 并淡入
        timeOffset = offset
        crossfadeTriggerFired = false
        currentTime = offset
        duration = 0
        lastReportedTime = offset

        let newPlayer = makePlayer(url: url, headers: headers)
        self.player = newPlayer
        setupObservers(player: newPlayer, applyFadeInOnReady: true)
        setupAudioRouteDetection()
        newPlayer.playImmediately(atRate: 1.0)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        pauseTimestamp = Date()
        cancelStallTimer()
    }

    func resume() {
        if let item = player?.currentItem, currentTime > 5 {
            let rawTime = currentTime - timeOffset
            let currentCMTime = CMTime(
                seconds: rawTime,
                preferredTimescale: 600
            )
            let positionBuffered = item.loadedTimeRanges.contains { range in
                CMTimeRangeContainsTime(
                    range.timeRangeValue,
                    time: currentCMTime
                )
            }
            let pausedTooLong = pauseTimestamp.map {
                Date().timeIntervalSince($0) > 30
            } ?? false

            if item.isPlaybackBufferEmpty
                || !positionBuffered
                || pausedTooLong {
                let reloadPosition = currentTime
                pauseTimestamp = nil
                onBufferInvalidated?(reloadPosition)
                return
            }
        }
        pauseTimestamp = nil
        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        isSeeking = true
        lastReportedTime = time
        let targetTime = CMTime(seconds: time - timeOffset, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
            }
        }
        currentTime = time
    }

    func seekToProgress(_ progress: Double) {
        guard duration > 0 else { return }
        seek(to: duration * progress)
    }

    func stop() {
        teardownObservers()
        removeAudioRouteDetection()
        cancelStallTimer()
        cleanupFadingOutPlayer()
        player?.pause()
        player = nil
        isPlaying = false
        isBuffering = false
        bufferProgress = 0
        pauseTimestamp = nil
    }

    // MARK: - Player Construction

    private func makePlayer(url: URL, headers: [String: String]) -> AVPlayer {
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 600
        return AVPlayer(playerItem: item)
    }

    // MARK: - AVMutableAudioMix Crossfade

    private func applyFadeOutAudioMix() {
        guard let item = fadingOutPlayer?.currentItem else {
            return
        }
        guard let audioTrack = item.tracks.first(where: {
            $0.assetTrack?.mediaType == .audio
        })?.assetTrack else {
            return
        }

        let currentTime = fadingOutPlayer?.currentTime() ?? .zero
        let endTime = item.duration
        guard endTime.isValid && !endTime.isIndefinite else {
            return
        }

        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.setVolumeRamp(
            fromStartVolume: 1,
            toEndVolume: 0,
            timeRange: CMTimeRange(
                start: currentTime,
                duration: CMTimeSubtract(endTime, currentTime)
            )
        )
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func applyFadeInAudioMix(to item: AVPlayerItem) {
        guard fadeInAppliedItem !== item else { return }
        guard player?.currentItem === item else {
            return
        }
        guard let audioTrack = item.tracks.first(where: {
            $0.assetTrack?.mediaType == .audio
        })?.assetTrack else {
            return
        }

        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.setVolumeRamp(
            fromStartVolume: 0,
            toEndVolume: 1,
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(
                    seconds: crossfadeDuration,
                    preferredTimescale: 600
                )
            )
        )
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        fadeInAppliedItem = item
    }

    private func cleanupFadingOutPlayer() {
        if let observer = fadingOutEndObserver {
            NotificationCenter.default.removeObserver(observer)
            fadingOutEndObserver = nil
        }
        fadingOutPlayer?.pause()
        fadingOutPlayer = nil
    }

    // MARK: - Observers

    private func setupObservers(
        player: AVPlayer,
        applyFadeInOnReady: Bool = false
    ) {
        guard let item = player.currentItem else { return }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.handleTimeUpdate(player: player, time: time)
            }
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.isBuffering = false
                    let itemDuration = observedItem.duration.seconds
                    if itemDuration.isFinite && itemDuration > 0 {
                        let adjustedDuration = itemDuration + self.timeOffset
                        if self.duration <= 0 || adjustedDuration > self.duration {
                            self.duration = adjustedDuration
                        }
                    }
                    if applyFadeInOnReady {
                        self.applyFadeInAudioMix(to: observedItem)
                    }
                case .failed:
                    self.isBuffering = false
                default:
                    break
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isBuffering = false
                    self.isPlaying = true
                    self.cancelStallTimer()
                    if applyFadeInOnReady, let item = player.currentItem {
                        self.applyFadeInAudioMix(to: item)
                    }
                case .waitingToPlayAtSpecifiedRate:
                    self.isBuffering = true
                    self.startStallTimer()
                case .paused:
                    self.isPlaying = false
                    self.cancelStallTimer()
                @unknown default:
                    break
                }
            }
        }

        bufferObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateBufferProgress(item: item)
            }
        }

        endTimeObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.onTrackFinished?()
            }
        }
    }

    private func teardownObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        bufferObservation?.invalidate()
        bufferObservation = nil
        if let observer = endTimeObserver {
            NotificationCenter.default.removeObserver(observer)
            endTimeObserver = nil
        }
    }

    // MARK: - Time Handling

    private func handleTimeUpdate(player: AVPlayer, time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }

        let actualTime = seconds + timeOffset

        if !isSeeking,
           isPlaying,
           lastReportedTime > 5,
           actualTime < lastReportedTime - 5 {
            let expectedPosition = lastReportedTime
            lastReportedTime = 0
            onBufferInvalidated?(expectedPosition)
            return
        }
        lastReportedTime = actualTime
        currentTime = actualTime

        if let d = player.currentItem?.duration.seconds, d.isFinite && d > 0 {
            let adjustedDur = d + timeOffset
            if duration <= 0 || adjustedDur > duration {
                duration = adjustedDur
            }
        }

        // Crossfade trigger
        if !crossfadeTriggerFired
            && duration > crossfadeDuration
            && actualTime >= duration - crossfadeDuration {
            crossfadeTriggerFired = true
            onCrossfadeTrigger?()
        }

        onTimeUpdate?()
    }

    // MARK: - Buffer Progress

    private func updateBufferProgress(item: AVPlayerItem) {
        guard let timeRange = item.loadedTimeRanges.first?.timeRangeValue else {
            bufferProgress = 0
            return
        }
        let bufferedEnd = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))
        let itemDuration = CMTimeGetSeconds(item.duration)
        guard itemDuration.isFinite && itemDuration > 0 else {
            bufferProgress = 0
            return
        }
        bufferProgress = min(max(bufferedEnd / itemDuration, 0), 1)

        if isPlaying && timeRange.duration == .zero {
            onBufferInvalidated?(currentTime)
        }
    }

    // MARK: - Stall Recovery

    private func startStallTimer() {
        cancelStallTimer()
        stallTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                self.onBufferInvalidated?(self.currentTime)
            }
        }
    }

    private func cancelStallTimer() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    // MARK: - Audio Route Change

    private func setupAudioRouteDetection() {
        removeAudioRouteDetection()
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AVAudioEngineConfigurationChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
        }
    }

    private func removeAudioRouteDetection() {
        if let observer = audioRouteObserver {
            NotificationCenter.default.removeObserver(observer)
            audioRouteObserver = nil
        }
    }
}
