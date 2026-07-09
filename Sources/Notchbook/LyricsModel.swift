import Combine
import Foundation

/// Time-synced lyrics from LRCLIB (lrclib.net — free, keyless). Fetched per
/// track; the media tab highlights the line matching the player position,
/// Apple Music-style, and seeks on tap.
final class LyricsModel: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let time: Double
        let text: String
    }

    enum Status { case idle, loading, loaded, unavailable }

    @Published private(set) var lines: [Line] = []
    /// Fallback when only unsynced lyrics exist — shown as a static sheet.
    @Published private(set) var plainText: String = ""
    @Published private(set) var status: Status = .idle

    private var fetchedKey = ""
    private var task: URLSessionDataTask?

    func fetch(title: String, artist: String, duration: Double) {
        let key = "\(title)|\(artist)"
        guard !title.isEmpty, key != fetchedKey else { return }
        fetchedKey = key
        task?.cancel()
        lines = []
        plainText = ""
        status = .loading

        // Manual percent-encoding: URLQueryItem leaves "&" unescaped inside
        // values, so an artist like "JAY-Z & Kanye West" silently splits the
        // query parameter.
        func enc(_ v: String) -> String {
            v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
        }
        guard let url = URL(string: "https://lrclib.net/api/search?track_name="
                            + enc(title) + "&artist_name=" + enc(artist)) else {
            status = .unavailable
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("DynamicIsland/1.0 (github.com/SensuBeans/dynamic-mac-island)",
                         forHTTPHeaderField: "User-Agent")
        let expected = duration
        task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            var best: [Line] = []
            var plain = ""
            if let data,
               let hits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // Prefer synced lyrics whose duration matches the track.
                let ranked: [(Int, String)] = hits.compactMap { hit in
                    guard let lrc = hit["syncedLyrics"] as? String, !lrc.isEmpty else {
                        return nil
                    }
                    let d = (hit["duration"] as? Double) ?? 0
                    let penalty = expected > 0 ? Int(abs(d - expected)) : 0
                    return (penalty, lrc)
                }.sorted { $0.0 < $1.0 }
                if let lrc = ranked.first?.1 { best = Self.parseLRC(lrc) }
                if best.isEmpty {
                    plain = hits.compactMap { $0["plainLyrics"] as? String }
                        .first { !$0.isEmpty } ?? ""
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fetchedKey == key else { return }
                self.lines = best
                self.plainText = plain
                self.status = (best.isEmpty && plain.isEmpty) ? .unavailable : .loaded
            }
        }
        task?.resume()
    }

    /// "[mm:ss.xx] words" → (seconds, words); untimed/empty lines dropped.
    static func parseLRC(_ lrc: String) -> [Line] {
        var out: [Line] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"\[(\d+):(\d+(?:\.\d+)?)\](.*)"#) else { return out }
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let m = regex.firstMatch(
                in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let text = ns.substring(with: m.range(at: 3))
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            out.append(Line(id: out.count, time: minutes * 60 + seconds, text: text))
        }
        return out
    }
}
