import AppKit
import Combine
import SwiftUI

/// Tracks Apple Music and Spotify via the public distributed notifications
/// they post on every play/pause/track change, fetches album artwork, and
/// controls playback. Requires the Automation permission (one-time prompt).
final class MediaWatcher: ObservableObject {
    enum Source: String, Equatable {
        case music = "Music"
        case spotify = "Spotify"
        case youtube = "YouTube"

        var bundleID: String {
            switch self {
            case .music: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            case .youtube: return "com.google.Chrome"
            }
        }
        var displayName: String {
            switch self {
            case .music: return "Apple Music"
            case .spotify: return "Spotify"
            case .youtube: return "YouTube"
            }
        }
    }

    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var source: Source
    }

    @Published var nowPlaying: NowPlaying?
    @Published var artwork: NSImage? {
        didSet {
            accent = artwork.map(Self.dominantColor) ?? .orange
        }
    }
    /// Waveform/indicator tint pulled from the album art (orange fallback).
    @Published var accent: Color = .orange
    @Published var position: Double = 0
    @Published var duration: Double = 0
    /// Chrome refused JS-over-AppleEvents — YouTube volume needs the user to
    /// enable View ▸ Developer ▸ Allow JavaScript from Apple Events.
    @Published var youtubeJSBlocked = false
    /// 90 seconds after pausing, the island ear hides (session stays alive).
    @Published var earHidden = false
    @Published var shuffleOn = false
    /// Wall-clock stamp of the last position poll — lets views interpolate
    /// a smooth position between the 1 Hz polls.
    private(set) var positionStamp = Date.distantPast
    /// "off" | "all" | "one" (Spotify only knows off/all)
    @Published var repeatMode = "off"

    private var earHideWork: DispatchWorkItem?
    private var earCancellable: AnyCancellable?

    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var artworkKey: String?
    private var progressTimer: Timer?
    private var youtubeTimer: Timer?
    private var youtubeVideoID: String?

    init() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] in self?.handle($0, source: .music) })
        observers.append(dnc.addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] in self?.handle($0, source: .spotify) })
        // Players don't reliably post a "stopped" event when QUIT — watch the
        // process terminate so the island clears immediately.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                      as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  let np = self.nowPlaying, np.source.bundleID == bundleID
            else { return }
            self.nowPlaying = nil
            self.artwork = nil
            self.artworkKey = nil
        }
        refresh()

        // YouTube-in-Chrome has no notifications — poll lightly, and only
        // when no real player owns the session.
        youtubeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.pollYouTube()
        }
        youtubeTimer?.tolerance = 1

        earCancellable = $nowPlaying.sink { [weak self] np in
            guard let self else { return }
            self.earHideWork?.cancel()
            if let np, !np.isPlaying {
                let work = DispatchWorkItem { [weak self] in self?.earHidden = true }
                self.earHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
            } else {
                self.earHidden = false
            }
        }
    }

    private func pollYouTube() {
        if let np = nowPlaying, np.source != .youtube { return }  // players win
        guard !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
        else {
            clearYouTube()
            return
        }
        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "youtube.com/watch" then
                        return (URL of t) & linefeed & (title of t)
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
        guard let out = runAppleScript(script)?.stringValue, !out.isEmpty else {
            clearYouTube()
            return
        }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 2 else { return }
        let url = parts[0]
        var title = parts[1...].joined(separator: " ")
        if title.hasSuffix(" - YouTube") { title = String(title.dropLast(10)) }

        // With JS allowed we know the real paused state; otherwise assume playing.
        var playing = nowPlaying?.source == .youtube ? (nowPlaying?.isPlaying ?? true) : true
        if !youtubeJSBlocked,
           let paused = runAppleScript(
               youtubeJS("document.querySelector('video').paused"))?.stringValue {
            playing = (paused != "true")
        }
        let np = NowPlaying(title: title, artist: "YouTube · Chrome",
                            isPlaying: playing, source: .youtube)
        if np.title != nowPlaying?.title { position = 0 }
        nowPlaying = np

        // Video thumbnail as artwork.
        if let range = url.range(of: "v=") {
            let id = String(url[range.upperBound...].prefix(while: {
                $0 != "&" && $0 != "#"
            }))
            if id != youtubeVideoID, !id.isEmpty,
               let thumbURL = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") {
                youtubeVideoID = id
                URLSession.shared.dataTask(with: thumbURL) { [weak self] data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        guard self?.youtubeVideoID == id,
                              self?.nowPlaying?.source == .youtube else { return }
                        self?.artwork = image
                    }
                }.resume()
            }
        }
    }

    private func clearYouTube() {
        guard nowPlaying?.source == .youtube else { return }
        nowPlaying = nil
        artwork = nil
        artworkKey = nil
        youtubeVideoID = nil
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    private func handle(_ note: Notification, source: Source) {
        let info = note.userInfo ?? [:]
        let playerState = info["Player State"] as? String ?? "Stopped"
        guard playerState != "Stopped" else {
            if nowPlaying == nil || nowPlaying?.source == source {
                nowPlaying = nil
                artwork = nil
                artworkKey = nil
            }
            return
        }
        let np = NowPlaying(title: info["Name"] as? String ?? "Unknown",
                            artist: info["Artist"] as? String ?? "",
                            isPlaying: playerState == "Playing",
                            source: source)
        if np.title != nowPlaying?.title { position = 0 }
        nowPlaying = np
        fetchArtworkIfNeeded(for: np)
    }

    // MARK: - Progress

    /// Poll player position while the media tab is visible (1 Hz, AppleScript).
    func setProgressPolling(_ active: Bool) {
        if active {
            guard progressTimer == nil else { return }
            pollProgress()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.pollProgress()
            }
        } else {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func pollProgress() {
        guard let np = nowPlaying, np.source != .youtube, isRunning(np.source) else { return }
        let modeExpr = np.source == .music
            ? "(shuffle enabled as text) & \"|\" & (song repeat as text)"
            : "(shuffling as text) & \"|\" & (repeating as text)"
        let script = """
        tell application "\(np.source.rawValue)"
            try
                return (player position as text) & "|" & ((duration of current track) as text) & "|" & \(modeExpr)
            on error
                return ""
            end try
        end tell
        """
        guard let out = runAppleScript(script)?.stringValue, !out.isEmpty else { return }
        let parts = out.components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: ",", with: ".") }
        guard parts.count >= 2,
              let pos = Double(parts[0]), var dur = Double(parts[1]) else { return }
        if np.source == .spotify { dur /= 1000 }  // Spotify reports ms
        position = pos
        positionStamp = Date()
        duration = dur
        if parts.count == 4 {
            shuffleOn = parts[2] == "true"
            repeatMode = np.source == .music
                ? parts[3]
                : (parts[3] == "true" ? "all" : "off")
        }
    }

    private func isRunning(_ source: Source) -> Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    /// One-shot sync so a track already playing at launch shows up without
    /// waiting for the next player event. Never launches the players.
    func refresh() {
        for source in [Source.music, .spotify] where isRunning(source) {
            let script = """
            tell application "\(source.rawValue)"
                if player state is stopped then return ""
                set t to name of current track
                set a to artist of current track
                set s to (player state is playing) as text
                return t & linefeed & a & linefeed & s
            end tell
            """
            guard let out = runAppleScript(script)?.stringValue, !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 3 else { continue }
            let np = NowPlaying(title: parts[0], artist: parts[1],
                                isPlaying: parts[2] == "true", source: source)
            nowPlaying = np
            fetchArtworkIfNeeded(for: np)
            if np.isPlaying { break }
        }
    }

    // MARK: - Artwork

    private func fetchArtworkIfNeeded(for np: NowPlaying) {
        let key = "\(np.source.rawValue)|\(np.title)|\(np.artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        // Never let an artwork query launch the player app itself.
        guard isRunning(np.source) else {
            artwork = nil
            return
        }

        switch np.source {
        case .music:
            let script = """
            tell application "Music"
                try
                    return data of artwork 1 of current track
                on error
                    return ""
                end try
            end tell
            """
            if let desc = runAppleScript(script), desc.data.count > 32,
               let image = NSImage(data: desc.data) {
                artwork = image
            } else {
                artwork = nil
            }
        case .spotify:
            let script = "tell application \"Spotify\" to get artwork url of current track"
            guard let urlString = runAppleScript(script)?.stringValue,
                  let url = URL(string: urlString) else {
                artwork = nil
                return
            }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard self?.artworkKey == key else { return }
                    self?.artwork = image
                }
            }.resume()
        case .youtube:
            break  // thumbnail fetched in pollYouTube()
        }
    }

    /// Saturation-weighted average color of the artwork, punched up so it
    /// stays visible as a tint on the dark island.
    private static func dominantColor(_ image: NSImage) -> Color {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return .orange }
        var rSum = 0.0, gSum = 0.0, bSum = 0.0, weightSum = 0.0
        let steps = 24
        for iy in 0..<steps {
            for ix in 0..<steps {
                guard let c = rep.colorAt(x: ix * rep.pixelsWide / steps,
                                          y: iy * rep.pixelsHigh / steps)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let r = Double(c.redComponent)
                let g = Double(c.greenComponent)
                let b = Double(c.blueComponent)
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx == 0 ? 0 : (mx - mn) / mx
                let weight = 0.05 + sat * mx  // favor saturated, bright pixels
                rSum += r * weight
                gSum += g * weight
                bSum += b * weight
                weightSum += weight
            }
        }
        guard weightSum > 0 else { return .orange }
        let avg = NSColor(red: rSum / weightSum, green: gSum / weightSum,
                          blue: bSum / weightSum, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        return Color(nsColor: NSColor(hue: h, saturation: min(max(s, 0.45), 0.9),
                                      brightness: max(br, 0.92), alpha: 1))
    }

    // MARK: - Controls

    func playPause() {
        // Optimistic flip for instant UI feedback; the player's own
        // notification confirms (or corrects) right after.
        if var np = nowPlaying {
            np.isPlaying.toggle()
            nowPlaying = np
        }
        control("playpause")
    }

    /// Jump the player to an absolute position (lyrics tap-to-seek).
    func seek(to seconds: Double) {
        guard let np = nowPlaying, np.source != .youtube else { return }
        fireScript("tell application \"\(np.source.rawValue)\" to set player position to \(Int(seconds))")
        position = seconds
        positionStamp = Date()
    }

    func nextTrack() { control("next track") }
    func previousTrack() { control("previous track") }

    func toggleShuffle() {
        guard let np = nowPlaying, np.source != .youtube else { return }
        shuffleOn.toggle()  // optimistic; the 1 Hz poll confirms
        let script = np.source == .music
            ? "tell application \"Music\" to set shuffle enabled to \(shuffleOn)"
            : "tell application \"Spotify\" to set shuffling to \(shuffleOn)"
        fireScript(script)
    }

    /// off → all → one → off on Music; off ↔ all on Spotify.
    func cycleRepeat() {
        guard let np = nowPlaying, np.source != .youtube else { return }
        if np.source == .music {
            repeatMode = ["off": "all", "all": "one"][repeatMode] ?? "off"
            fireScript("tell application \"Music\" to set song repeat to \(repeatMode)")
        } else {
            repeatMode = repeatMode == "off" ? "all" : "off"
            fireScript("tell application \"Spotify\" to set repeating to \(repeatMode == "all")")
        }
    }

    private func fireScript(_ script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// Players get AppleScript; YouTube gets the system media keys (the
    /// same events the hardware F7/F8/F9 keys send, which its player obeys).
    private func control(_ cmd: String) {
        guard nowPlaying?.source != .youtube else {
            switch cmd {
            case "playpause":
                runYouTubeJS("(function(){var v=document.querySelector('video');if(v.paused){v.play()}else{v.pause()}})()")
            case "next track":
                runYouTubeJS("(function(){var b=document.querySelector('.ytp-next-button');if(b){b.click()}})()")
            case "previous track":
                runYouTubeJS("(function(){document.querySelector('video').currentTime=0})()")
            default: break
            }
            return
        }
        let app = nowPlaying?.source.rawValue ?? "Music"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"\(app)\" to \(cmd)"]
        try? p.run()
    }

    // MARK: - Player volume (independent of the Mac's output volume)

    func readPlayerVolume() -> Double {
        guard let np = nowPlaying else { return 50 }
        switch np.source {
        case .music, .spotify:
            guard isRunning(np.source) else { return 50 }
            if let out = runAppleScript(
                "tell application \"\(np.source.rawValue)\" to get sound volume") {
                return Double(out.int32Value)
            }
            return 50
        case .youtube:
            // Needs Chrome: View → Developer → Allow JavaScript from Apple Events.
            var error: NSDictionary?
            let result = NSAppleScript(source:
                youtubeJS("document.querySelector('video').volume * 100"))?
                .executeAndReturnError(&error)
            if let msg = error?["NSAppleScriptErrorMessage"] as? String,
               msg.contains("turned off") {
                youtubeJSBlocked = true
            } else if result != nil {
                youtubeJSBlocked = false
            }
            if let out = result?.stringValue,
               let v = Double(out.replacingOccurrences(of: ",", with: ".")) {
                return v
            }
            return 100
        }
    }

    /// Non-blocking volume read for live gestures — osascript runs on a
    /// background queue so a slow player can never hitch the island.
    func readPlayerVolumeAsync(_ completion: @escaping (Double) -> Void) {
        guard let np = nowPlaying else { completion(50); return }
        let script: String
        switch np.source {
        case .music, .spotify:
            guard isRunning(np.source) else { completion(50); return }
            script = "tell application \"\(np.source.rawValue)\" to get sound volume"
        case .youtube:
            script = youtubeJS("document.querySelector('video').volume * 100")
        }
        DispatchQueue.global(qos: .userInteractive).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let v = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 50
            DispatchQueue.main.async { completion(min(max(v, 0), 100)) }
        }
    }

    func setPlayerVolume(_ value: Double) {
        guard let np = nowPlaying else { return }
        let v = Int(min(max(value, 0), 100))
        let script: String
        switch np.source {
        case .music, .spotify:
            script = "tell application \"\(np.source.rawValue)\" to set sound volume to \(v)"
        case .youtube:
            script = youtubeJS("document.querySelector('video').volume = \(Double(v) / 100.0)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// Fire-and-forget JS in the YouTube tab (single quotes only!).
    private func runYouTubeJS(_ js: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", youtubeJS(js)]
        try? p.run()
    }

    /// Runs JS (single quotes only!) in the first YouTube tab.
    private func youtubeJS(_ js: String) -> String {
        """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "youtube.com/watch" then
                        tell t to return execute javascript "\(js)"
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    /// Launches a fully closed player and starts playback (resumes its last
    /// queue) — "tell … to play" both opens the app and plays.
    func launchAndPlay(_ source: Source) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"\(source.rawValue)\" to play"]
        try? p.run()
    }

    private func tapMediaKey(_ key: Int32) {
        for down in [true, false] {
            let data1 = Int((Int(key) << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
