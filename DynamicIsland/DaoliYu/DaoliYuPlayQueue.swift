import Foundation

@MainActor
final class DaoliYuPlayQueue: ObservableObject {
    @Published var currentTrack: DaoliYuTrack?
    @Published var queue: [DaoliYuTrack] = []
    @Published var history: [DaoliYuTrack] = []
    @Published var autoPlayTracks: [DaoliYuTrack] = []
    @Published var shuffleEnabled = false
    @Published var repeatMode: DaoliYuRepeatMode = .off
    @Published var autoPlayEnabled = true

    private var source: [DaoliYuTrack] = []
    private let maxHistoryCount = 50

    enum DaoliYuRepeatMode: Int, Codable { case off, all, one }

    func load(_ tracks: [DaoliYuTrack], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        source = tracks
        currentTrack = tracks[index]
        queue = Array(tracks.suffix(from: index + 1))
        history = index > 0 ? Array(tracks.prefix(index)) : []
        if shuffleEnabled { queue.shuffle() }
    }

    func next(manual: Bool = false) -> DaoliYuTrack? {
        if repeatMode == .one && !manual, let current = currentTrack {
            return current
        }
        if let current = currentTrack {
            history.append(current)
            if history.count > maxHistoryCount { history.removeFirst() }
        }
        if let next = queue.first {
            queue.removeFirst()
            currentTrack = next
            return next
        }
        if repeatMode == .all, !source.isEmpty {
            queue = shuffleEnabled ? source.shuffled() : source
            let next = queue.removeFirst()
            currentTrack = next
            return next
        }
        if let next = autoPlayTracks.first {
            autoPlayTracks.removeFirst()
            currentTrack = next
            return next
        }
        currentTrack = nil
        return nil
    }

    func previous() -> DaoliYuTrack? {
        guard let prev = history.popLast() else { return nil }
        if let current = currentTrack {
            queue.insert(current, at: 0)
        }
        currentTrack = prev
        return prev
    }

    func playNow(_ track: DaoliYuTrack) {
        if let current = currentTrack {
            history.append(current)
            if history.count > maxHistoryCount { history.removeFirst() }
        }
        currentTrack = track
    }

    func playFromQueue(trackId: String) {
        guard let index = queue.firstIndex(where: { $0.id == trackId }) else { return }
        let track = queue.remove(at: index)
        playNow(track)
    }

    func playFromHistory(trackId: String) {
        guard let index = history.firstIndex(where: { $0.id == trackId }) else { return }
        let track = history.remove(at: index)
        if let current = currentTrack {
            queue.insert(current, at: 0)
        }
        currentTrack = track
    }

    func playFromAutoPlay(trackId: String) {
        guard let index = autoPlayTracks.firstIndex(where: { $0.id == trackId }) else { return }
        let track = autoPlayTracks.remove(at: index)
        playNow(track)
    }

    func addToQueue(_ track: DaoliYuTrack) {
        guard !existingIds().contains(track.id) else { return }
        if shuffleEnabled {
            let pos = queue.isEmpty ? 0 : Int.random(in: 0...queue.count)
            queue.insert(track, at: pos)
        } else {
            queue.append(track)
        }
    }

    func addToQueue(_ tracks: [DaoliYuTrack]) {
        let existing = existingIds()
        let newTracks = tracks.filter { !existing.contains($0.id) }
        queue.append(contentsOf: newTracks)
    }

    func appendAutoPlayTracks(_ tracks: [DaoliYuTrack]) {
        let existing = existingIds()
        let newTracks = tracks.filter { !existing.contains($0.id) }
        autoPlayTracks.append(contentsOf: newTracks)
    }

    func clearAutoPlayTracks() {
        autoPlayTracks.removeAll()
    }

    func removeFromQueue(id: String) {
        queue.removeAll { $0.id == id }
    }

    func moveInQueue(from: IndexSet, to: Int) {
        queue.move(fromOffsets: from, toOffset: to)
    }

    func clearHistory() {
        history.removeAll()
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        if shuffleEnabled { queue.shuffle() }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func existingIds() -> Set<String> {
        var ids = Set(queue.map(\.id))
        ids.formUnion(autoPlayTracks.map(\.id))
        if let current = currentTrack { ids.insert(current.id) }
        return ids
    }

    var remainingCount: Int {
        queue.count + autoPlayTracks.count
    }

    func clear() {
        currentTrack = nil
        queue.removeAll()
        history.removeAll()
        autoPlayTracks.removeAll()
        source.removeAll()
    }

    // MARK: - Persistence

    struct PersistedState: Codable {
        let currentTrack: DaoliYuTrack?
        let queue: [DaoliYuTrack]
        let source: [DaoliYuTrack]
        let autoPlayTracks: [DaoliYuTrack]
        let shuffleEnabled: Bool
        let repeatMode: Int
        let autoPlayEnabled: Bool
    }

    func persist() -> PersistedState {
        PersistedState(
            currentTrack: currentTrack,
            queue: queue,
            source: source,
            autoPlayTracks: autoPlayTracks,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode.rawValue,
            autoPlayEnabled: autoPlayEnabled
        )
    }

    func restore(from state: PersistedState) {
        currentTrack = state.currentTrack
        queue = state.queue
        source = state.source
        autoPlayTracks = state.autoPlayTracks
        shuffleEnabled = state.shuffleEnabled
        repeatMode = DaoliYuRepeatMode(rawValue: state.repeatMode) ?? .off
        autoPlayEnabled = state.autoPlayEnabled
    }
}
