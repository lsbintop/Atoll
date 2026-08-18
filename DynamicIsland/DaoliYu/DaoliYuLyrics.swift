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

    private var loadedTrackId: String?
    private var requestedTrackId: String?
    private let client = DaoliYuAPIClient.shared

    var currentLyricText: String? {
        guard activeLineIndex >= 0, activeLineIndex < lines.count else { return nil }
        return lines[activeLineIndex].text
    }

    func load(trackId: String) async {
        guard loadedTrackId != trackId, requestedTrackId != trackId else { return }
        requestedTrackId = trackId
        isLoading = true
        lines = []
        activeLineIndex = -1

        for attempt in 0..<2 {
            do {
                let detail = try await fetchTrackDetail(trackId: trackId)
                guard requestedTrackId == trackId, !Task.isCancelled else { return }

                if let lyrics = detail.lyrics, !lyrics.isEmpty {
                    lines = Self.parseLRC(lyrics)
                }

                loadedTrackId = trackId
                requestedTrackId = nil
                isLoading = false
                return
            } catch is CancellationError {
                if requestedTrackId == trackId {
                    requestedTrackId = nil
                    isLoading = false
                }
                return
            } catch {
                guard requestedTrackId == trackId else { return }

                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else {
                        requestedTrackId = nil
                        isLoading = false
                        return
                    }
                    continue
                }

                requestedTrackId = nil
                isLoading = false
                return
            }
        }
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

        var result: [(time: TimeInterval?, text: String, order: Int)] = []
        var hasTimestamp = false
        var order = 0

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else {
                if !isMetadataLine(line) {
                    result.append((time: nil, text: line, order: order))
                    order += 1
                }
                continue
            }

            hasTimestamp = true
            let firstMatch = matches[0]
            let minutes = Double(nsLine.substring(with: firstMatch.range(at: 1))) ?? 0
            let seconds = Double(nsLine.substring(with: firstMatch.range(at: 2))) ?? 0
            let fracRange = firstMatch.range(at: 3)
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

            let text = regex.stringByReplacingMatches(
                in: line,
                range: NSRange(location: 0, length: nsLine.length),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            result.append((
                time: minutes * 60 + seconds + fraction,
                text: text,
                order: order
            ))
            order += 1
        }

        if hasTimestamp {
            result.sort {
                let lhsTime = $0.time ?? 0
                let rhsTime = $1.time ?? 0
                if lhsTime == rhsTime {
                    return $0.order < $1.order
                }
                return lhsTime < rhsTime
            }
        }

        return result.enumerated().map { index, item in
            DaoliYuLyricLine(id: index, time: item.time, text: item.text)
        }
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        for tag in metadataTags where lowercased.hasPrefix("[\(tag):") {
            return true
        }

        if lowercased.hasPrefix("["),
           let closingBracket = lowercased.firstIndex(of: "]"),
           lowercased[..<closingBracket].contains(":") {
            return true
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
