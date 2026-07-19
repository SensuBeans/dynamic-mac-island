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
    /// "Auto-switch to YouTube": ON = symmetric arbitration (only a PLAYING
    /// source may take the island); OFF = native players always win (the old
    /// behavior). settings: Media page toggle, default ON.
    @Published var autoSwitchYouTube: Bool =
        (UserDefaults.standard.object(forKey: "autoSwitchYouTube") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoSwitchYouTube, forKey: "autoSwitchYouTube") }
    }

    private var earHideWork: DispatchWorkItem?
    private var earCancellable: AnyCancellable?

    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var artworkKey: String?
    /// The Accessibility prompt is shown at most once per app run; further
    /// Songs/Albums clicks while untrusted route through `onNeedsAccessibility`
    /// (a toast + the Privacy pane) instead of stacking system dialogs.
    private var didPromptAccessibility = false
    /// Set by the app delegate: called on the main thread when a Music-library
    /// jump needs Accessibility but the one-time prompt has already fired.
    var onNeedsAccessibility: (() -> Void)?
    private var progressTimer: Timer?
    private var youtubeTimer: Timer?
    private var youtubeVideoID: String?
    /// Settings-driven: whether YouTube-in-Chrome detection runs at all.
    private var youtubeEnabled = true
    /// Seconds before the paused media ear hides; < 0 means never hide.
    var pausedEarHideDelay: Double = 90
    /// Full watch URL of the current YouTube session — used to jump to the tab.
    private(set) var youtubeURL: String?
    /// Every hot-path AppleScript runs through here as a spawned `osascript`
    /// process. NSAppleScript is main-thread-only and blocks the UI, so it's
    /// reserved for the rare one-shot on the main thread (`launchAndPlay`).
    private let scriptQueue = DispatchQueue(label: "com.sensubeans.notchbook.applescript",
                                            qos: .userInitiated)

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
        startYouTubeTimer()

        earCancellable = $nowPlaying.sink { [weak self] np in
            guard let self else { return }
            self.earHideWork?.cancel()
            // A negative delay means "never hide the paused ear".
            if let np, !np.isPlaying, self.pausedEarHideDelay >= 0 {
                let work = DispatchWorkItem { [weak self] in self?.earHidden = true }
                self.earHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + self.pausedEarHideDelay,
                                              execute: work)
            } else {
                self.earHidden = false
            }
        }
    }

    private func startYouTubeTimer() {
        guard youtubeTimer == nil else { return }
        youtubeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.pollYouTube()
        }
        youtubeTimer?.tolerance = 1
    }

    /// Turn YouTube detection on/off from settings. Off: stop polling and drop
    /// any active YouTube session (and never touch Chrome again until re-enabled).
    func setYouTubeEnabled(_ enabled: Bool) {
        youtubeEnabled = enabled
        if enabled {
            startYouTubeTimer()
        } else {
            youtubeTimer?.invalidate()
            youtubeTimer = nil
            clearYouTube()
        }
    }

    private func pollYouTube() {
        guard youtubeEnabled else { return }
        let current = nowPlaying
        if autoSwitchYouTube {
            // Never poll-steal from a native player that is actively playing.
            if let current, current.source != .youtube, current.isPlaying { return }
        } else if let current, current.source != .youtube {
            return  // auto-switch off: native players always win
        }
        guard !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
        else {
            clearYouTube()
            return
        }
        // A *paused* native player currently owns the island: YouTube may take
        // it only when verifiably playing (JS), or — JS blocked — when the
        // watch tab is the active tab of the front Chrome window (user intent).
        let nativePausedOwns = (current?.source ?? .youtube) != .youtube

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
        runScriptAsync(script) { [weak self] out in
            guard let self else { return }
            guard let out, !out.isEmpty else {
                self.clearYouTube()
                return
            }
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 2 else { return }
            let url = parts[0]
            var title = parts[1...].joined(separator: " ")
            if title.hasSuffix(" - YouTube") { title = String(title.dropLast(10)) }

            // Commit a YouTube now-playing, publishing only on an actual change
            // (republishing an unchanged paused video every 3 s would reschedule
            // the ear-hide timer forever). Taking over from a native player
            // resets position/duration/artwork so a later takeback refetches.
            let commit: (Bool) -> Void = { playing in
                let takingOver = self.nowPlaying?.source != .youtube
                let np = NowPlaying(title: title, artist: "YouTube · Chrome",
                                    isPlaying: playing, source: .youtube)
                self.youtubeURL = url
                if np != self.nowPlaying {
                    if takingOver {
                        self.position = 0
                        self.duration = 0
                        self.artworkKey = nil
                    } else if np.title != self.nowPlaying?.title {
                        self.position = 0
                    }
                    self.nowPlaying = np
                }
                self.updateYouTubeArtwork(url: url)
            }

            if self.youtubeJSBlocked {
                if nativePausedOwns {
                    // No JS: gate takeover on the watch tab being the front
                    // window's active tab.
                    let vid = Self.youtubeID(from: url)
                    self.runScriptAsync(
                        "tell application \"Google Chrome\" to return URL of active tab of front window"
                    ) { activeURL in
                        if let vid, activeURL.flatMap(Self.youtubeID(from:)) == vid {
                            commit(true)
                        }
                    }
                } else {
                    // YouTube already owns or island empty — assume playing for
                    // a fresh tab, keep prior state for an existing session.
                    let assumed = self.nowPlaying?.source == .youtube
                        ? (self.nowPlaying?.isPlaying ?? true) : true
                    commit(assumed)
                }
            } else {
                self.runScriptAsync(self.youtubeJS("document.querySelector('video').paused")) { paused in
                    let definitePlaying = paused.map { $0 != "true" }  // Bool?
                    if nativePausedOwns {
                        if definitePlaying == true { commit(true) }  // only a clear "playing" takes over
                    } else {
                        let assumed = self.nowPlaying?.source == .youtube
                            ? (self.nowPlaying?.isPlaying ?? true) : true
                        commit(definitePlaying ?? assumed)
                    }
                }
            }
        }
    }

    /// The `v=` video id from a YouTube watch URL (nil if none).
    static func youtubeID(from url: String) -> String? {
        guard let range = url.range(of: "v=") else { return nil }
        let id = String(url[range.upperBound...].prefix(while: { $0 != "&" && $0 != "#" }))
        return id.isEmpty ? nil : id
    }

    /// YouTube video thumbnail as artwork; skips the fetch when the id is
    /// unchanged so a steady video doesn't re-download every poll.
    private func updateYouTubeArtwork(url: String) {
        guard let id = Self.youtubeID(from: url), id != youtubeVideoID,
              let thumbURL = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        else { return }
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

    /// Bring the current YouTube video's Chrome tab forward and select it.
    /// Matches by video id (the URL mutates with timestamps/playlist params);
    /// if the tab is gone this no-ops and the next poll clears the session.
    func openYouTubeTab() {
        guard let vid = youtubeVideoID else { return }
        let script = """
        tell application "Google Chrome"
            set done to false
            repeat with w in windows
                set idx to 0
                repeat with t in tabs of w
                    set idx to idx + 1
                    if URL of t contains "v=\(vid)" then
                        set active tab index of w to idx
                        set index of w to 1
                        set done to true
                        exit repeat
                    end if
                end repeat
                if done then exit repeat
            end repeat
            if done then activate
        end tell
        """
        runScriptAsync(script) { _ in }
    }

    private func clearYouTube() {
        guard nowPlaying?.source == .youtube else { return }
        nowPlaying = nil
        artwork = nil
        artworkKey = nil
        youtubeVideoID = nil
        youtubeURL = nil
        // Restore a paused-in-background native player instead of going blank.
        refresh()
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
        // Symmetric arbitration: a paused update from a DIFFERENT source can't
        // steal the island from whoever currently owns it — only a PLAYING
        // source takes over. A playing event always wins (last action wins).
        if autoSwitchYouTube, !np.isPlaying,
           let current = nowPlaying, current.source != source {
            return
        }
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
        runScriptAsync(script) { [weak self] out in
            guard let self, let out, !out.isEmpty else { return }
            let parts = out.components(separatedBy: "|")
                .map { $0.replacingOccurrences(of: ",", with: ".") }
            guard parts.count >= 2,
                  let pos = Double(parts[0]), var dur = Double(parts[1]) else { return }
            if np.source == .spotify { dur /= 1000 }  // Spotify reports ms
            self.position = pos
            self.positionStamp = Date()
            self.duration = dur
            if parts.count == 4 {
                self.shuffleOn = parts[2] == "true"
                self.repeatMode = np.source == .music
                    ? parts[3]
                    : (parts[3] == "true" ? "all" : "off")
            }
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
            fetchMusicArtworkAsync(key: key, title: np.title)
        case .spotify:
            // Read the artwork URL OFF the main thread. NSAppleScript is a
            // synchronous main-thread Apple-Event round-trip to Spotify (see the
            // note on runScriptAsync) and was blocking the UI on every Spotify
            // track flip — precisely while the ear/pill choreography animates, so
            // a slow/busy Spotify dropped animation frames. Use the same
            // osascript-off-main path the Music artwork fetch already uses; hop
            // back to main (runScriptAsync delivers there) only to assign.
            let script = "tell application \"Spotify\" to get artwork url of current track"
            runScriptAsync(script) { [weak self] urlString in
                guard let self, self.artworkKey == key else { return }  // superseded
                guard let urlString, let url = URL(string: urlString) else {
                    // No URL: don't leave the previous track's art stranded under
                    // the new key — clear the key so the next event refetches.
                    self.artwork = nil
                    self.artworkKey = nil
                    return
                }
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    let image = data.flatMap { NSImage(data: $0) }
                    DispatchQueue.main.async {
                        guard let self, self.artworkKey == key else { return }
                        if let image {
                            self.artwork = image
                        } else {
                            // Failed download → don't cache stale art under this
                            // key; reset so a later player event tries again.
                            self.artwork = nil
                            self.artworkKey = nil
                        }
                    }
                }.resume()
            }
        case .youtube:
            break  // thumbnail fetched in pollYouTube()
        }
    }

    /// Music artwork is binary, so we have `osascript` write the raw bytes to a
    /// temp file off the main thread, then decode it there — no full-image
    /// Apple Event blocking the UI on every track change.
    ///
    /// The script returns the current track's NAME alongside writing the art, in
    /// one round trip. Clicking a new song in Music posts `playerInfo` before its
    /// scripting interface catches up, so `artwork 1 of current track` can still
    /// serve the PREVIOUS track's art (or error while streamed art downloads). We
    /// accept the bytes only when the returned name matches `title`; on a
    /// mismatch/empty/error we retry a few times, and if it never resolves we
    /// clear the key so the next player event starts fresh instead of caching
    /// stale art forever.
    private func fetchMusicArtworkAsync(key: String, title: String, attempt: Int = 0) {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("notchbook-art-\(UUID().uuidString)")
        let escaped = tmp.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
            try
                set n to name of current track
                set d to data of artwork 1 of current track
                set f to open for access POSIX file "\(escaped)" with write permission
                set eof f to 0
                write d to f
                close access f
                return "OK" & linefeed & n
            on error
                try
                    close access POSIX file "\(escaped)"
                end try
                return ""
            end try
        end tell
        """
        scriptQueue.async { [weak self] in
            let raw = Self.runOsascript(script)
            var image: NSImage?
            var returnedName: String?
            if let raw, raw.hasPrefix("OK") {
                let lines = raw.components(separatedBy: "\n")
                returnedName = lines.count > 1
                    ? lines[1...].joined(separator: "\n") : ""
                image = NSImage(contentsOfFile: tmp)
            }
            try? FileManager.default.removeItem(atPath: tmp)
            DispatchQueue.main.async {
                guard let self, self.artworkKey == key else { return }
                if let image, returnedName == title {
                    self.artwork = image
                } else if attempt < 3 {
                    // Streamed art needs a beat to arrive; give it up to
                    // ~4 tries. Re-check the key on the main thread before
                    // each retry so a track change cancels the chain.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self, self.artworkKey == key else { return }
                        self.fetchMusicArtworkAsync(key: key, title: title,
                                                    attempt: attempt + 1)
                    }
                } else {
                    // Gave up: don't poison the key with stale/failed art —
                    // reset so the next player event refetches.
                    self.artwork = nil
                    self.artworkKey = nil
                }
            }
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

    /// A Library sub-tab in Music's sidebar.
    enum LibrarySection: String {
        case songs = "Songs"
        case albums = "Albums"
    }

    /// Jump into Music from the playing track. Each button does exactly ONE
    /// deterministic thing — combining a sidebar select with `reveal` was the
    /// bug: `reveal` navigates the content view to the track's own context,
    /// hijacking whatever tab was selected half a second earlier.
    ///
    ///   - Songs → select the "Songs" sidebar row and STOP: the full library
    ///     song list. No reveal — it would immediately yank the view away.
    ///   - Albums → select the "Albums" sidebar row FIRST, then `reveal` the
    ///     playing track. The reveal drill-in is hosted inside whichever tab
    ///     is selected, so anchoring it to Albums keeps the Songs page clean.
    ///     A streamed catalog track has no library row for reveal to act on
    ///     (the database-ID lookup matches zero tracks), so that case opens
    ///     the album straight from the catalog by URL.
    func openMusicLibrary(_ section: LibrarySection = .songs) {
        guard nowPlaying?.source == .music else { return }

        // UI scripting (the sidebar `select`) needs Accessibility. Check
        // WITHOUT prompting first — a granted app just proceeds. While
        // untrusted, show the system prompt exactly once; every click after
        // that routes to a toast + the Privacy pane instead of another dialog.
        // We still fall through and run the script: the Albums `reveal` lands
        // (just in the wrong tab) even without Accessibility.
        if !AXIsProcessTrusted() {
            if !didPromptAccessibility {
                didPromptAccessibility = true
                let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
            } else {
                onNeedsAccessibility?()
            }
        }

        scriptQueue.async { [weak self] in
            guard let self else { return }
            switch section {
            case .songs:
                self.selectLibraryTab("Songs")
            case .albums:
                if self.revealInAlbumsPage() { return }
                self.openInCatalog(section)
            }
        }
    }

    /// Select a Library sub-tab in Music's sidebar and leave the view there.
    ///
    /// System Events is the only way: `set view` is refused (-10006) and there
    /// is no View-menu item. It must be `select`, not `click` — a synthesized
    /// click resolves against stale coordinates and picks the wrong row.
    private func selectLibraryTab(_ rowName: String) {
        let script = """
        -- `reopen` first: with its window closed Music still runs, System Events
        -- sees zero windows, and the sidebar lookup dies with -1719.
        tell application "Music"
            reopen
            activate
        end tell
        delay 0.4
        tell application "System Events" to tell process "Music"
            set targetRow to missing value
            set bounceRow to missing value
            repeat with r in (rows of outline 1 of scroll area 1 ¬
                              of splitter group 1 of window 1)
                try
                    set rn to (name of static text 1 of UI element 1 of r)
                    if rn is "\(rowName)" then
                        set targetRow to r
                    else if rn is "Recently Added" then
                        set bounceRow to r
                    end if
                end try
            end repeat
            if targetRow is missing value then return "NO_ROW"
            -- ALWAYS bounce through another row first. Selecting a row that
            -- Music considers already selected is a no-op (it keeps showing
            -- an album drill-in that reveal left behind), and the row's
            -- AX "selected" state can't be trusted after a reveal — so an
            -- unconditional reset is the only deterministic path to the list.
            if bounceRow is not missing value then
                select bounceRow
                delay 0.35
            end if
            select targetRow
            return "OK"
        end tell
        """
        let out = runScriptSync(script)
        if out != "OK" {
            NSLog("notchbook selectLibraryTab(%@) result=%@", rowName, out ?? "nil")
        }
    }

    /// Land on the playing track's album INSIDE the Albums page: bounce-select
    /// the Albums sidebar row, then `reveal` the track — the drill-in opens
    /// anchored to whichever tab is selected. Returns `false` — without having
    /// moved Music at all — when the track has no library row (streamed
    /// catalog track). The track is matched on database ID (an Int) rather
    /// than by name, so no track metadata is ever interpolated into
    /// AppleScript source, where a title containing a quote could inject code.
    /// Without Accessibility the tab select fails silently and the reveal
    /// still lands on the album, just hosted in the current tab.
    private func revealInAlbumsPage() -> Bool {
        let script = """
        set target to missing value
        tell application "Music"
            try
                set dbid to database ID of current track
                set target to (some track of library playlist 1 ¬
                               whose database ID is dbid)
            end try
        end tell
        if target is missing value then return "NO_TARGET"
        tell application "Music"
            reopen
            activate
        end tell
        delay 0.4
        try
            tell application "System Events" to tell process "Music"
                set targetRow to missing value
                set bounceRow to missing value
                repeat with r in (rows of outline 1 of scroll area 1 ¬
                                  of splitter group 1 of window 1)
                    try
                        set rn to (name of static text 1 of UI element 1 of r)
                        if rn is "Albums" then
                            set targetRow to r
                        else if rn is "Recently Added" then
                            set bounceRow to r
                        end if
                    end try
                end repeat
                if targetRow is missing value then error "no Albums row"
                if bounceRow is not missing value then
                    select bounceRow
                    delay 0.35
                end if
                select targetRow
            end tell
            delay 0.5
        end try
        tell application "Music"
            try
                reveal target
            end try
        end tell
        return "OK"
        """
        // OK → handled (stop); NO_TARGET or a script failure (nil) → fall
        // through to the catalog lookup.
        return runScriptSync(script) == "OK"
    }

    /// Open the playing track's album in the Apple Music catalog — for the Songs
    /// tab, the song highlighted inside it.
    ///
    /// Only reached when the track isn't in the library, where AppleScript has no
    /// handle on it whatsoever. The catalog is looked up by name, so this is the
    /// one path that needs the network; if it finds nothing we do nothing.
    private func openInCatalog(_ section: LibrarySection) {
        guard let meta = currentTrackMeta() else { return }
        let wantSong = (section == .songs)

        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: "\(meta.artist) \(wantSong ? meta.title : meta.album)"),
            .init(name: "entity", value: wantSong ? "song" : "album"),
            .init(name: "limit", value: "10"),
        ]
        guard let url = comps.url else { return }

        // Synchronous is fine — we are already off the main thread.
        let sem = DispatchSemaphore(value: 0)
        var payload: Data?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            payload = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 8)

        guard let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              !results.isEmpty
        else {
            NSLog("notchbook: no catalog match for %@ — %@", meta.artist, meta.album)
            return
        }

        // Prefer an exact album match. A search for a popular song cheerfully
        // returns the "Deluxe"/"Exclusive Edition" first, which is a different
        // album page than the one actually playing.
        let wanted = meta.album.lowercased()
        let hit = results.first { ($0["collectionName"] as? String)?.lowercased() == wanted }
            ?? results[0]

        // trackViewUrl lands on the song INSIDE its album; collectionViewUrl on the
        // album itself. Both carry the right storefront — hardcoding "us" would not.
        let link = (wantSong ? hit["trackViewUrl"] as? String : nil)
            ?? hit["collectionViewUrl"] as? String
        guard let link, let musicURL = Self.musicScheme(link) else { return }
        NSWorkspace.shared.open(musicURL)
    }

    /// `https://music.apple.com/…` → `music://music.apple.com/…`, so the link opens
    /// in Music rather than bouncing through the browser.
    private static func musicScheme(_ web: String) -> URL? {
        guard var comps = URLComponents(string: web) else { return nil }
        comps.scheme = "music"
        comps.queryItems = comps.queryItems?.filter { $0.name != "uo" }  // analytics
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        return comps.url
    }

    /// Title / artist / album of whatever Music is playing right now. `nowPlaying`
    /// only carries title and artist, and the catalog lookup needs the album too.
    private func currentTrackMeta() -> (title: String, artist: String, album: String)? {
        let script = """
        tell application "Music"
            set ct to current track
            return (name of ct) & "\\n" & (artist of ct) & "\\n" & (album of ct)
        end tell
        """
        guard let out = runScriptSync(script) else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }
        return (parts[0], parts[1], parts[2])
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
    /// queue). Opening the app via NSWorkspace needs no permission and reliably
    /// launches it even when fully quit; the follow-up "play" is sent
    /// in-process (not via a spawned osascript) so macOS attributes the
    /// one-time Automation prompt to this app and actually shows it.
    func launchAndPlay(_ source: Source) {
        let play = "tell application \"\(source.rawValue)\" to play"
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: source.bundleID) else {
            // App not found — try the direct tell as a last resort.
            _ = runAppleScript(play)
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { [weak self] _, _ in
            // Give a freshly launched player a moment to be scriptable, then
            // resume playback on the main thread (NSAppleScript is main-only).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                _ = self?.runAppleScript(play)
                // A cold "play" no-ops if nothing is queued (or the app wasn't
                // scriptable yet). Shortly after, if it still isn't playing,
                // start the whole library so the button always produces sound.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    _ = self?.runAppleScript(Self.resumeFallback(source))
                }
            }
        }
    }

    /// Second attempt for `launchAndPlay`: if the player still isn't playing,
    /// kick off a default queue so something actually starts.
    private static func resumeFallback(_ source: Source) -> String {
        switch source {
        case .music:
            return """
            tell application "Music"
                try
                    if player state is not playing then play library playlist 1
                end try
            end tell
            """
        case .spotify:
            return "tell application \"Spotify\" to play"
        case .youtube:
            return ""
        }
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

    /// The single mechanism for hot-path script execution: run `source` via a
    /// spawned `osascript` off the main thread, delivering trimmed stdout back
    /// on the main thread (nil if empty or the process failed).
    private func runScriptAsync(_ source: String, completion: @escaping (String?) -> Void) {
        scriptQueue.async {
            let text = Self.runOsascript(source)
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Synchronous osascript — ONLY call off the main thread (e.g. already
    /// inside `scriptQueue` or another background queue).
    private func runScriptSync(_ source: String) -> String? {
        Self.runOsascript(source)
    }

    private static func runOsascript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
