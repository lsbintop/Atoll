import Foundation

struct DaoliYuLyricLine: Identifiable {
    let id: Int
    let time: TimeInterval?
    let text: String
}

@MainActor
final class DaoliYuLyricsManager: ObservableObject {
    @Published var lines: [DaoliYuLyricLine] = []
    @Published var activeLineIndex: Int = -1
    @Published var isLoading = false

    private var requestedTrackId: String?
    private let client = DaoliYuAPIClient.shared

    var currentLyricText: String? {
        guard activeLineIndex >= 0, activeLineIndex < lines.count else { return nil }
        return lines[activeLineIndex].text
    }

    func load(trackId: String) async {
        guard requestedTrackId != trackId else { return }
        requestedTrackId = trackId
        isLoading = true
        lines = []
        activeLineIndex = -1

        do {
            let detail = try await fetchTrackDetail(trackId: trackId)
            if let lrc = detail.lyrics {
                lines = Self.parseLRC(lrc)
            }
        } catch {
            try? await Task.sleep(nanoseconds: 400_000_000)
            do {
                let detail = try await fetchTrackDetail(trackId: trackId)
                if let lrc = detail.lyrics {
                    lines = Self.parseLRC(lrc)
                }
            } catch {}
        }

        isLoading = false
    }

    @discardableResult
    func updateActiveLine(for time: TimeInterval) -> Bool {
        let timedLines = lines.enumerated().filter { $0.element.time != nil }
        var newIndex = -1

        for (i, line) in timedLines {
            if let t = line.time, t <= time {
                newIndex = i
            } else {
                break
            }
        }

        if newIndex != activeLineIndex {
            activeLineIndex = newIndex
            return true
        }
        return false
    }

    // MARK: - LRC Parser

    private static let metadataTags: Set<String> = ["ti", "ar", "al", "by", "offset"]

    static func parseLRC(_ lrc: String) -> [DaoliYuLyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var result: [(time: TimeInterval, text: String)] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if isMetadataLine(line) { continue }

            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }

            var lastMatchEnd = 0
            var timestamps: [TimeInterval] = []

            for match in matches {
                let minuteRange = match.range(at: 1)
                let secondRange = match.range(at: 2)
                let fracRange = match.range(at: 3)

                let minutes = Double(nsLine.substring(with: minuteRange)) ?? 0
                let seconds = Double(nsLine.substring(with: secondRange)) ?? 0
                var fraction: Double = 0

                if fracRange.location != NSNotFound {
                    let fracStr = nsLine.substring(with: fracRange)
                    if fracStr.count == 2 {
                        fraction = (Double(fracStr) ?? 0) / 100.0
                    } else if fracStr.count == 3 {
                        fraction = (Double(fracStr) ?? 0) / 1000.0
                    } else {
                        fraction = (Double(fracStr) ?? 0) / pow(10, Double(fracStr.count))
                    }
                }

                timestamps.append(minutes * 60 + seconds + fraction)
                lastMatchEnd = match.range.location + match.range.length
            }

            let text = nsLine.substring(from: lastMatchEnd).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            for ts in timestamps {
                result.append((time: ts, text: text))
            }
        }

        result.sort { $0.time < $1.time }

        return result.enumerated().map { index, item in
            DaoliYuLyricLine(id: index, time: item.time, text: item.text)
        }
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        for tag in metadataTags {
            if line.hasPrefix("[\(tag):") { return true }
        }
        return false
    }

    // MARK: - Network

    private func fetchTrackDetail(trackId: String) async throws -> DaoliYuTrackDetailDTO {
        let serverURL = client.serverURL
        guard !serverURL.isEmpty, let base = URL(string: serverURL) else {
            throw DaoliYuError.notConfigured
        }
        let url = base.appendingPathComponent("api/tracks/\(trackId)")
        var request = URLRequest(url: url)
        for (key, value) in client.authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(DaoliYuTrackDetailDTO.self, from: data)
    }
}

private struct DaoliYuTrackDetailDTO: Decodable {
    let id: String
    let lyrics: String?
}
