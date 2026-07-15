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
    /// Whether the fetch that set `fetchedKey` knew the track duration. A fetch
    /// racing in before the duration is known can't rank candidates by it, so
    /// once the duration arrives we allow exactly one re-fetch to re-rank.
    private var fetchedDurationKnown = false
    private var task: URLSessionDataTask?

    func fetch(title: String, artist: String, duration: Double) {
        guard !title.isEmpty else { return }
        let key = "\(title)|\(artist)"
        let durationKnown = duration > 0
        // Skip only if we already fetched this track AND nothing improved —
        // i.e. we already had the duration, or we still don't.
        if key == fetchedKey, fetchedDurationKnown || !durationKnown { return }
        fetchedKey = key
        fetchedDurationKnown = durationKnown
        task?.cancel()
        lines = []
        plainText = ""
        status = .loading

        // Try the exact title first; if it yields no synced lyrics, retry once
        // with a normalized title (strip "(feat. …)", "[…]", "- Remastered", …).
        search(title: title, artist: artist, expected: duration, key: key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .network:   // transient — allow the same track to be retried
                DispatchQueue.main.async {
                    guard self.fetchedKey == key else { return }
                    self.fetchedKey = ""
                    self.fetchedDurationKnown = false
                    self.status = .unavailable
                }
            case let .found(lines, plain):
                if !lines.isEmpty || !plain.isEmpty {
                    self.deliver(key: key, lines: lines, plain: plain)
                    return
                }
                let norm = Self.normalizeTitle(title)
                guard norm != title else {
                    self.deliver(key: key, lines: [], plain: "")
                    return
                }
                self.search(title: norm, artist: artist, expected: duration, key: key) { r2 in
                    switch r2 {
                    case .network:
                        DispatchQueue.main.async {
                            guard self.fetchedKey == key else { return }
                            self.fetchedKey = ""
                            self.fetchedDurationKnown = false
                            self.status = .unavailable
                        }
                    case let .found(l2, p2):
                        self.deliver(key: key, lines: l2, plain: p2)
                    }
                }
            }
        }
    }

    private enum SearchResult { case network, found([Line], String) }

    /// One LRCLIB search. Ranks synced candidates by how close their duration is
    /// to the track's. Completion runs on the URLSession queue.
    private func search(title: String, artist: String, expected: Double,
                        key: String, completion: @escaping (SearchResult) -> Void) {
        // Manual percent-encoding: URLQueryItem leaves "&" unescaped inside
        // values, so an artist like "JAY-Z & Kanye West" silently splits the
        // query parameter.
        func enc(_ v: String) -> String {
            v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
        }
        var comps = "https://lrclib.net/api/search?track_name=" + enc(title)
        if !artist.isEmpty { comps += "&artist_name=" + enc(artist) }
        guard let url = URL(string: comps) else {
            completion(.found([], "")); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("DynamicIsland/1.0 (github.com/SensuBeans/dynamic-mac-island)",
                         forHTTPHeaderField: "User-Agent")
        task = URLSession.shared.dataTask(with: request) { data, _, error in
            if error != nil || data == nil { completion(.network); return }
            var best: [Line] = []
            var plain = ""
            if let data,
               let hits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let ranked: [(Int, String)] = hits.compactMap { hit in
                    guard let lrc = hit["syncedLyrics"] as? String, !lrc.isEmpty else { return nil }
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
            completion(.found(best, plain))
        }
        task?.resume()
    }

    private func deliver(key: String, lines: [Line], plain: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.fetchedKey == key else { return }
            self.lines = lines
            self.plainText = plain
            self.status = (lines.isEmpty && plain.isEmpty) ? .unavailable : .loaded
        }
    }

    /// Strip qualifiers that keep an exact-title search from matching:
    /// "(feat. …)"/"(with …)", any "[…]", and trailing "- Remastered / Live /
    /// Single Version …". Used only for the one-shot fallback retry.
    static func normalizeTitle(_ title: String) -> String {
        var t = title
        // Parenthetical feat/with.
        t = t.replacingOccurrences(of: #"\s*\((?:feat\.?|ft\.?|with)[^)]*\)"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        // YouTube-style video/audio/lyric qualifiers in ( ) or [ ] — these keep
        // an exact search from matching the real track ("HUMBLE. (Official Music
        // Video)" → "HUMBLE.").
        t = t.replacingOccurrences(
            of: #"\s*[\(\[](?:official\s*)?(?:music\s*)?(?:lyric\s*)?(?:video|audio|lyrics|visuali[sz]er|hd|hq|4k|mv|official)[^\)\]]*[\)\]]"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        // Any remaining bracketed segment […].
        t = t.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "",
                                   options: .regularExpression)
        // Trailing "- <qualifier>" (Remastered 2011, Live, Single Version, …).
        t = t.replacingOccurrences(
            of: #"\s*-\s*(?:remaster(?:ed)?|live|mono|stereo|single version|album version|radio edit|deluxe|bonus track|explicit)\b.*$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
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
