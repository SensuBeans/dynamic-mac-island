import SwiftUI
import EventKit
import AVFoundation

// MARK: - Notes

struct NotesTab: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var notesSync: NotesSyncModel
    @EnvironmentObject var settings: SettingsStore
    var focus: FocusState<Bool>.Binding
    @State private var notesIndex = 0
    /// Confirm-before-clear: the trash button is "armed" for 2s after the
    /// first click when the setting is on; a second click within the window
    /// actually clears.
    @State private var clearArmed = false
    @State private var clearGen = 0

    private var isNotesMode: Bool { notesSync.mode == .notes }

    var body: some View {
        VStack(spacing: 8) {
            TextEditor(text: editorText)
                .focused(focus)
                .font(.system(size: settings.notesFontSize,
                              design: settings.notesMonospaced ? .monospaced : .default))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.07))
                )

            HStack {
                if isNotesMode { notesChips } else { pageTabs }
                statusLabel
                Spacer()
                modeToggle
                if !isNotesMode {
                    Button { clearCurrentPage() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(clearArmed ? Color.red : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(clearArmed ? "Click again to clear" : "Clear this page")
                }
            }
        }
        .onAppear { if isNotesMode { notesSync.refresh() } }
        .onChange(of: notesSync.pages.count) { count in
            if notesIndex >= count { notesIndex = max(0, count - 1) }
        }
    }

    /// The hidden (collapsed) editor must never write through to the store —
    /// an AppKit-backed TextEditor can push its initial empty text back
    /// through the binding during setup, which once wiped saved notes. The
    /// same guard protects Apple Notes mode (a push there would set the note's
    /// body to empty).
    private var editorText: Binding<String> {
        if isNotesMode {
            return Binding(
                get: {
                    notesSync.pages.indices.contains(notesIndex)
                        ? notesSync.pages[notesIndex].body : ""
                },
                set: { newValue in
                    guard state.isExpanded,
                          notesSync.pages.indices.contains(notesIndex) else { return }
                    notesSync.edit(id: notesSync.pages[notesIndex].id, text: newValue)
                })
        }
        return Binding(
            get: { state.pages[state.currentPage] },
            set: { newValue in
                guard state.isExpanded else { return }
                state.pages[state.currentPage] = newValue
            })
    }

    private var statusLabel: some View {
        Text(isNotesMode
             ? (notesSync.syncing ? "syncing…" : "Apple Notes")
             : "\(state.pages[state.currentPage].count) chars · autosaved")
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.leading, 6)
    }

    /// Cloud toggle: Local pages ↔ Apple Notes. (The settings page binds the
    /// same `notesSync.mode`; this in-tab control keeps the feature usable
    /// regardless.)
    private var modeToggle: some View {
        Button {
            notesSync.setMode(isNotesMode ? .local : .notes)
            notesIndex = 0
        } label: {
            Image(systemName: isNotesMode ? "cloud.fill" : "cloud")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(isNotesMode ? 0.9 : 0.5))
        }
        .buttonStyle(.plain)
        .help(isNotesMode ? "Syncing with Apple Notes" : "Sync with Apple Notes")
    }

    /// Clear the current page, honoring the confirm-before-clear setting: the
    /// first click arms for 2s (trash turns red), a second click clears.
    private func clearCurrentPage() {
        if settings.notesConfirmClear && !clearArmed {
            clearArmed = true
            clearGen += 1
            let gen = clearGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if clearGen == gen { clearArmed = false }
            }
        } else {
            state.pages[state.currentPage] = ""
            clearArmed = false
        }
    }

    private var pageTabs: some View {
        HStack(spacing: 3) {
            ForEach(state.pages.indices, id: \.self) { i in
                let isCurrent = i == state.currentPage
                let isEmpty = state.pages[i].isEmpty
                Button { state.currentPage = i } label: {
                    Text("\(i + 1)")
                        .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                        .foregroundStyle(isCurrent ? .black : .white.opacity(isEmpty ? 0.45 : 0.8))
                        .frame(width: 18, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(isCurrent ? 0.85 : 0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(isEmpty ? "Page \(i + 1) (empty)" : "Page \(i + 1)")
            }
        }
    }

    /// Apple Notes mode: one chip per note (title, ~10 chars) + a create chip.
    private var notesChips: some View {
        HStack(spacing: 3) {
            ForEach(Array(notesSync.pages.enumerated()), id: \.element.id) { idx, page in
                let isCurrent = idx == notesIndex
                Button { notesIndex = idx } label: {
                    Text(chipTitle(page.title))
                        .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                        .foregroundStyle(isCurrent ? .black : .white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.white.opacity(isCurrent ? 0.85 : 0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            Button { notesSync.createNote { notesIndex = 0 } } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 18, height: 16)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("New note in the sync folder")
        }
    }

    private func chipTitle(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = s.isEmpty ? "Untitled" : s
        return name.count > 10 ? String(name.prefix(10)) + "…" : name
    }
}

// MARK: - Media

struct MediaTab: View {
    @EnvironmentObject var media: MediaWatcher
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var toggles: TogglesModel
    @EnvironmentObject var spectrum: AudioSpectrum
    @EnvironmentObject var lyrics: LyricsModel
    @EnvironmentObject var audioOutput: AudioOutputModel
    @State private var volume: Double = 50
    @State private var showLyrics = false
    @State private var artHovered = false
    /// While scrubbing the progress bar: the dragged fraction (0…1); nil when
    /// not scrubbing. Shown live; the actual seek fires on release.
    @State private var scrubFraction: Double?
    @State private var progressHover = false

    var body: some View {
        if let np = media.nowPlaying {
            mediaCard(np)
                .onAppear {
                    media.readPlayerVolumeAsync { volume = $0 }
                    // Music's AirPlay list needs network discovery — warm it
                    // here so the output menu is populated at click time.
                    audioOutput.prefetchAirPlay()
                }
                .onChange(of: np.source) { _ in media.readPlayerVolumeAsync { volume = $0 } }
                .onChange(of: np.title) { _ in
                    if showLyrics {
                        let q = lyricsQuery(np)
                        // duration: 0 — the 1 Hz poll still holds the PREVIOUS
                        // track's duration, so ranking against it is wrong. The
                        // duration onChange re-fetches once the real value lands.
                        lyrics.fetch(title: q.title, artist: q.artist, duration: 0)
                    }
                }
                .onChange(of: media.duration) { _ in
                    // Real duration arrived — let the model re-rank candidates by
                    // it (its key/durationKnown guard dedupes; no-op if unchanged).
                    if showLyrics {
                        let q = lyricsQuery(np)
                        lyrics.fetch(title: q.title, artist: q.artist,
                                     duration: media.duration)
                    }
                }
        } else {
            placeholder
        }
    }

    /// Exactly the progress bar's 4 pt capsule, in the same column width.
    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.4))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                        .frame(height: 4)
                    Capsule().fill(media.accent)
                        .frame(width: max(4, geo.size.width * volume / 100), height: 4)
                    // Knob so the slider reads as a slider.
                    Circle().fill(.white)
                        .frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                        .offset(x: max(0, geo.size.width * volume / 100 - 5))
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            volume = min(100, max(0, v.location.x / geo.size.width * 100))
                        }
                        .onEnded { _ in media.setPlayerVolume(volume) }
                )
            }
            .frame(height: 10)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func mediaCard(_ np: MediaWatcher.NowPlaying) -> some View {
            // Mirrors Apple's mini-player: artwork left at full card height;
            // title block with a small live waveform beside it, transport
            // centered, progress bar with elapsed/remaining at the bottom.
            HStack(alignment: .center, spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(np.source.displayName.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4))
                                .kerning(0.8)
                            Text(np.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(np.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Button { media.playPause() } label: {
                            // Fill whatever width the title leaves over with
                            // waveform bars — the count adapts to the gap.
                            GeometryReader { geo in
                                EqualizerBars(barCount: max(4, Int(geo.size.width / 5)),
                                              barWidth: 2.5, maxHeight: 26,
                                              color: media.accent,
                                              animating: np.isPlaying && state.isExpanded,
                                              levels: np.isPlaying && !spectrum.levels.isEmpty
                                                  ? spectrum.levels : nil)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(height: 36)
                        .padding(.leading, 6)
                        .help(np.isPlaying ? "Pause" : "Play")
                        Button {
                            showLyrics.toggle()
                            if showLyrics {
                                let q = lyricsQuery(np)
                                lyrics.fetch(title: q.title, artist: q.artist,
                                             duration: media.duration)
                            }
                        } label: {
                            Image(systemName: showLyrics
                                  ? "quote.bubble.fill" : "quote.bubble")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(showLyrics ? 0.9 : 0.4))
                        }
                        .buttonStyle(.plain)
                        .frame(height: 36)
                        .padding(.leading, 2)
                        .help("Lyrics")
                    }
                    if showLyrics {
                        LyricsTicker(accent: media.accent)
                    } else {
                    Spacer(minLength: 2)
                    HStack(spacing: 24) {
                        if np.source != .youtube {
                            Button { media.toggleShuffle() } label: {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(media.shuffleOn ? 0.95 : 0.35))
                            }
                            .help("Shuffle")
                        }
                        Button { media.previousTrack() } label: {
                            Image(systemName: "backward.fill").font(.system(size: 12))
                        }
                        Button { media.playPause() } label: {
                            Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18))
                                .frame(width: 22)
                        }
                        Button { media.nextTrack() } label: {
                            Image(systemName: "forward.fill").font(.system(size: 12))
                        }
                        if np.source != .youtube {
                            Button { media.cycleRepeat() } label: {
                                Image(systemName: media.repeatMode == "one" ? "repeat.1" : "repeat")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(media.repeatMode == "off" ? 0.35 : 0.95))
                            }
                            .help("Repeat: off → all → one")
                        }
                        Button {
                            // popUp blocks until the menu closes; the flag
                            // keeps the mouse-away watcher from collapsing
                            // the island while it's tracking.
                            state.menuHoldsOpen = true
                            audioOutput.presentMenu()
                            state.menuHoldsOpen = false
                        } label: {
                            Image(systemName: "airplay.audio")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(
                                    audioOutput.isRoutedExternally ? 0.95 : 0.35))
                        }
                        .help("Sound output"
                              + (audioOutput.current.map { " — \($0.name)" } ?? ""))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 2)
                    if np.source == .youtube {
                        Text(media.youtubeJSBlocked
                             ? "For volume: Chrome ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events"
                             : "YouTube · Google Chrome")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.white.opacity(media.youtubeJSBlocked ? 0.55 : 0.35))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    } else {
                        progressBar
                    }
                    Spacer(minLength: 3)
                    volumeRow
                    }
                }
                .frame(height: 102)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.25))
            Text("Nothing Playing")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 10) {
                LaunchButton(icon: "music.note", label: "Music") {
                    media.launchAndPlay(.music)
                }
                if FileManager.default.fileExists(atPath: "/Applications/Spotify.app") {
                    LaunchButton(icon: "waveform", label: "Spotify") {
                        media.launchAndPlay(.spotify)
                    }
                }
                LaunchButton(icon: "play.rectangle.fill", label: "YouTube") {
                    if let url = URL(string: "https://www.youtube.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var artwork: some View {
        Group {
            if let art = media.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: 102, height: 102)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Hovering the cover dims it and offers a jump into the Music library.
        // Apple Music only — the shortcut is meaningless over a Spotify or
        // YouTube session.
        .overlay {
            if artHovered, media.nowPlaying?.source == .music {
                VStack(spacing: 6) {
                    libraryButton(.albums, icon: "square.stack",
                                  help: "Show this song's album in your Apple Music library")
                    libraryButton(.songs, icon: "music.note.list",
                                  help: "Show this song in your Apple Music library")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.opacity)
            } else if artHovered, media.nowPlaying?.source == .youtube {
                // YouTube: jump to the video's Chrome tab.
                Button { media.openYouTubeTab() } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Open Tab")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.opacity)
                .help("Show this video's tab in Chrome")
            }
        }
        .onHover { artHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: artHovered)
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    /// One row of the artwork hover overlay: a jump into a Library sub-tab.
    /// Sized for the 102pt cover, so icon + label sit on a single line.
    private func libraryButton(_ section: MediaWatcher.LibrarySection,
                               icon: String, help: String) -> some View {
        Button { media.openMusicLibrary(section) } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(section.rawValue)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 84, height: 26)
            .background(Capsule().fill(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var progressBar: some View {
        // While scrubbing, the bar + time labels follow the drag; the real seek
        // fires on release so we don't spam the player with position sets.
        let shown = scrubFraction ?? Double(fraction)
        let shownElapsed = scrubFraction != nil ? shown * media.duration : media.position
        let knobVisible = progressHover || scrubFraction != nil
        return HStack(spacing: 8) {
            Text(timeString(shownElapsed))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: max(4, geo.size.width * CGFloat(shown)), height: 4)
                    // Knob appears on hover / while scrubbing so the bar reads as
                    // draggable without cluttering the resting look.
                    Circle().fill(.white)
                        .frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                        .offset(x: max(0, geo.size.width * CGFloat(shown) - 5))
                        .opacity(knobVisible ? 1 : 0)
                }
                .frame(height: geo.size.height)
                // Bigger hit area than the 4pt line so it's easy to grab.
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            scrubFraction = min(1, max(0, v.location.x / geo.size.width))
                        }
                        .onEnded { _ in
                            if let f = scrubFraction, media.duration > 0 {
                                media.seek(to: f * media.duration)
                            }
                            scrubFraction = nil
                        }
                )
                .onHover { progressHover = $0 }
            }
            .frame(height: 10)
            Text("-" + timeString(max(0, media.duration - shownElapsed)))
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.45))
        .animation(.easeOut(duration: 0.12), value: knobVisible)
    }

    private var fraction: CGFloat {
        media.duration > 0 ? min(1, media.position / media.duration) : 0
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Title/artist to search LRCLIB with. For YouTube the "artist" is junk
    /// ("YouTube · Chrome"), so parse "Artist - Title" out of the video title
    /// when present, else search the title with an empty artist.
    private func lyricsQuery(_ np: MediaWatcher.NowPlaying) -> (title: String, artist: String) {
        guard np.source == .youtube else { return (np.title, np.artist) }
        let raw = np.title
        for sep in [" - ", " – ", " — "] {
            if let r = raw.range(of: sep) {
                let artist = raw[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = raw[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty { return (title, artist) }
            }
        }
        return (raw, "")
    }
}

/// Apple Music-style synced lyrics: bold rounded lines, the current one
/// bright, the next ones dimmed and softly blurred, springing upward as the
/// song advances. Tap any line to seek there.
private struct LyricsTicker: View {
    @EnvironmentObject var media: MediaWatcher
    @EnvironmentObject var lyrics: LyricsModel
    let accent: Color

    /// Monotonic display position: the max interpolated position reached while
    /// playing. Small backward poll corrections are ignored so a just-promoted
    /// line never demotes and bounces; a real seek (≥ threshold) is accepted.
    @State private var displayPos: Double = 0
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private let seekThreshold: Double = 1.5

    var body: some View {
        Group {
            switch lyrics.status {
            case .loading:  message("Finding lyrics…")
            case .idle, .unavailable: message("No lyrics for this song")
            case .loaded:
                if lyrics.lines.isEmpty { plainSheet } else { ticker }
            }
        }
        .onReceive(timer) { _ in tick() }
        // New track: drop the latch so the new song starts from its real time.
        .onChange(of: media.nowPlaying?.title) { _ in displayPos = 0 }
    }

    private func message(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Advance the monotonic clock. Interpolates between the 1 Hz polls; ignores
    /// backward corrections < threshold (Spotify quantizes to integer seconds
    /// and the osascript round-trip is stale), accepts a real backward seek.
    private func tick() {
        let base = media.position
        let playing = media.nowPlaying?.isPlaying == true
        let raw = playing ? base + Date().timeIntervalSince(media.positionStamp) : base
        if raw >= displayPos || displayPos - raw >= seekThreshold {
            displayPos = raw
        }
    }

    /// Tap-to-seek: seek AND reset the latch so a backward tap lands immediately.
    private func seek(to t: Double) {
        media.seek(to: t)
        displayPos = t
    }

    /// Unsynced lyrics: a quietly scrollable sheet, Apple-style.
    private var plainSheet: some View {
        ScrollView(showsIndicators: false) {
            Text(lyrics.plainText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    private var currentIndex: Int {
        var idx = -1
        for (i, line) in lyrics.lines.enumerated() where line.time <= displayPos { idx = i }
        return idx
    }

    private var ticker: some View {
        let i = currentIndex
        let count = lyrics.lines.count
        // Gap (s) from now to the next line — drives the instrumental dots.
        let gap = (i + 1 < count) ? lyrics.lines[i + 1].time - displayPos : nil
        // The window: current + up to 2 upcoming (the lane only fits ~3 rows;
        // more would force the card's fixed height and clip the title above).
        let start = max(0, i)
        let end = min(count - 1, max(0, i) + 2)
        let window: [Int] = i < 0
            ? Array(0..<min(2, count))
            : (start <= end ? Array(start...end) : [])
        return VStack(alignment: .leading, spacing: 6) {
            if i < 0 { InstrumentalDots() }               // intro
            ForEach(window, id: \.self) { idx in
                lyricLine(idx, distance: idx - i)
            }
            if i >= 0, (gap ?? 0) > 5 { InstrumentalDots() }   // mid-song break
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .animation(.spring(response: 0.55, dampingFraction: 0.9), value: i)
        // Fade the lane's bottom edge so the last upcoming line dissolves instead
        // of hard-clipping at the card edge (Apple fades, never cuts).
        .mask(
            LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.72),
                .init(color: .clear, location: 1.0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    /// One lyric line. `distance` 0 = current (bright), 1 = next, 2+ = further —
    /// SAME font size for all (Apple never shrinks upcoming lines); depth is only
    /// opacity + a touch of blur. Identity is the line, so on advance the same
    /// view springs upward rather than hard-swapping.
    @ViewBuilder
    private func lyricLine(_ idx: Int, distance: Int) -> some View {
        if idx >= 0, idx < lyrics.lines.count {
            let line = lyrics.lines[idx]
            let opacity: Double = distance <= 0 ? 1 : distance == 1 ? 0.35
                                : distance == 2 ? 0.22 : 0.15
            let blur: CGFloat = distance <= 0 ? 0 : distance == 1 ? 0.5 : 1
            Text(line.text)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(opacity))
                .blur(radius: blur)
                .lineLimit(distance <= 0 ? 3 : 2)
                .minimumScaleFactor(0.75)
                // NO fixedSize: the lines stay compressible so the lyrics lane
                // can shrink to its allotted space instead of forcing the card's
                // fixed height (which would clip the title/source label above).
                // The current line gets priority so it keeps its rows.
                .layoutPriority(distance <= 0 ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { seek(to: line.time) }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .move(edge: .top))))
                .id(line.id)
        }
    }
}

/// Apple's instrumental-break indicator: three dots gently breathing.
private struct InstrumentalDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(.white).frame(width: 7, height: 7)
            }
        }
        .opacity(on ? 0.9 : 0.35)
        .scaleEffect(on ? 1 : 0.85, anchor: .leading)
        .padding(.vertical, 5)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                on = true
            }
        }
    }
}

struct LaunchButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timer (Pomodoro)

struct TimerTab: View {
    @EnvironmentObject var pomodoro: PomodoroModel
    @State private var customTime = ""

    private func applyCustomTime() {
        let parts = customTime.split(separator: ":")
        var seconds = 0
        if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) {
            seconds = m * 60 + s
        } else if let m = Double(customTime.replacingOccurrences(of: ",", with: ".")) {
            seconds = Int(m * 60)
        }
        if seconds > 0 {
            pomodoro.setCustomFocus(seconds: min(seconds, 12 * 3600))
        }
        customTime = ""
    }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.003, pomodoro.progress))
                    .stroke(pomodoro.phase == .focus ? Color.orange : .green,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: pomodoro.progress)
                VStack(spacing: 1) {
                    Text(pomodoro.timeString)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(pomodoro.phase == .focus ? "FOCUS" : "BREAK")
                        .font(.system(size: 8, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 98, height: 98)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(i < pomodoro.sessions % 4 || (pomodoro.sessions > 0 && pomodoro.sessions % 4 == 0)
                                  ? AnyShapeStyle(.orange) : AnyShapeStyle(.white.opacity(0.2)))
                            .frame(width: 6, height: 6)
                    }
                    Text("\(pomodoro.sessions) done")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 4)
                }

                HStack(spacing: 12) {
                    Button { pomodoro.startPause() } label: {
                        Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 16))
                            .frame(width: 20)
                    }
                    Button { pomodoro.reset() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                    }
                    .help("Reset")
                    Button { pomodoro.skip() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 11))
                    }
                    .help("Skip phase")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                HStack(spacing: 6) {
                    ForEach([15, 25, 45], id: \.self) { m in
                        Button {
                            pomodoro.focusMinutes = m
                        } label: {
                            Text("\(m)m")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(pomodoro.focusMinutes == m
                                        ? .white.opacity(0.85) : .white.opacity(0.08))
                                )
                                .foregroundStyle(pomodoro.focusMinutes == m
                                    ? .black : .white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("+ 5m break")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }

                HStack(spacing: 6) {
                    TextField("custom · 90 or 12:30", text: $customTime)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(width: 120)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08)))
                        .onSubmit { applyCustomTime() }
                    Text("min")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Files tray

struct TrayTab: View {
    @EnvironmentObject var tray: FilesTray
    @EnvironmentObject var settings: SettingsStore

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: settings.trayTileSize), spacing: 8)]
    }

    var body: some View {
        if tray.items.isEmpty {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.2),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Drop Files Here")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("Drag onto the notch anytime · drag out to move · AirDrop below")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                )
        } else {
            VStack(spacing: 6) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(tray.items, id: \.self) { url in
                            TrayTile(url: url)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Label("Drag all", systemImage: "square.stack")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .overlay {
                            MultiFileDragOverlay(urls: tray.items) { dropped in
                                if settings.trayRemoveAfterDragOut {
                                    dropped.forEach { tray.remove($0) }
                                }
                            }
                        }
                        .help("Drag every file out as one stack")
                    Button { tray.airDrop() } label: {
                        Label("AirDrop", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    Button { tray.clear() } label: {
                        Text("Clear")
                            .font(.system(size: 10))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.07)))
                    }
                    Spacer()
                    Text("\(tray.items.count) item\(tray.items.count == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

private struct TrayTile: View {
    @EnvironmentObject var tray: FilesTray
    @EnvironmentObject var settings: SettingsStore
    let url: URL

    @State private var thumbnail: NSImage?
    @State private var hovered = false

    /// Visual tile edge = the grid cell (tile-size setting) minus the 8pt of
    /// surrounding spacing the grid reserves.
    private var side: CGFloat { settings.trayTileSize - 8 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                    }
                }
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(hovered ? 0.3 : 0.1), lineWidth: 1)
                )
                .scaleEffect(hovered ? 1.04 : 1)

                if hovered {
                    Button { tray.remove(url) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove from tray")
                    .transition(.opacity)
                }
            }
            Text(url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side + 8)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onDrag { NSItemProvider(object: url as NSURL) }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("AirDrop") { tray.airDrop([url]) }
            Divider()
            Button("Remove") { tray.remove(url) }
        }
        .onAppear {
            TrayThumbnails.shared.load(url, side: side) { thumbnail = $0 }
        }
    }
}

// MARK: - Calendar

struct CalendarTab: View {
    @EnvironmentObject var calendarModel: CalendarModel
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var settings: SettingsStore
    @State private var visibleMonth = Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    var body: some View {
        Group {
            if !calendarModel.hasAccess {
                connectPrompt
            } else {
                VStack(spacing: 6) {
                    header
                    if state.calendarMonthMode {
                        monthView
                    } else {
                        listView
                    }
                }
            }
        }
        .onAppear {
            calendarModel.load()
            if state.calendarMonthMode { calendarModel.loadMonth(containing: visibleMonth) }
        }
    }

    private var connectPrompt: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "calendar")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("Connect your Calendar")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Button { calendarModel.connect() } label: {
                Text("Allow Access")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.orange))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: List / month toggle

    private var header: some View {
        HStack {
            Spacer()
            HStack(spacing: 2) {
                segButton(icon: "list.bullet", active: !state.calendarMonthMode) {
                    state.calendarMonthMode = false
                }
                segButton(icon: "calendar", active: state.calendarMonthMode) {
                    state.calendarMonthMode = true
                    calendarModel.loadMonth(containing: visibleMonth)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
        }
        .frame(height: 22)
    }

    private func segButton(icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? .black : .white.opacity(0.55))
                .frame(width: 26, height: 16)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(active ? .white.opacity(0.85) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: List mode (unchanged from before)

    private var listView: some View {
        Group {
            if calendarModel.events.isEmpty {
                VStack {
                    Spacer()
                    Text("No events in the next 7 days")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(calendarModel.events, id: \.rowID) { event in
                            eventRow(event)
                        }
                    }
                }
            }
        }
    }

    // MARK: Month mode

    private var monthView: some View {
        HStack(alignment: .top, spacing: 12) {
            miniMonth.frame(width: 170)
            dayEvents
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var miniMonth: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return VStack(spacing: 3) {
            HStack {
                Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Button { jumpToToday() } label: {
                    Text(visibleMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i])
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                      spacing: 2) {
                ForEach(gridDays, id: \.self) { day in
                    dayCell(day, today: today, cal: cal)
                }
            }
            // Pin the grid to the top of the column; any extra height falls below.
            Spacer(minLength: 0)
        }
    }

    private func dayCell(_ day: Date, today: Date, cal: Calendar) -> some View {
        let inMonth = cal.isDate(day, equalTo: visibleMonth, toGranularity: .month)
        let isToday = day == today
        let isSelected = day == selectedDay
        let hasEvents = !(calendarModel.monthEvents[day]?.isEmpty ?? true)
        return Button { selectedDay = day } label: {
            VStack(spacing: 1) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 9, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? .black : .white.opacity(inMonth ? 0.85 : 0.25))
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(isToday ? Color.orange : .clear))
                    .overlay(Circle().stroke(.white,
                                             lineWidth: (isSelected && !isToday) ? 1 : 0))
                Circle()
                    .fill(hasEvents ? Color.orange : .clear)
                    .frame(width: 2.5, height: 2.5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dayEvents: some View {
        let events = calendarModel.monthEvents[selectedDay] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            Text(selectedDay.formatted(.dateTime.weekday(.abbreviated)
                    .month(.abbreviated).day()))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            if events.isEmpty {
                Spacer()
                Text("No events")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(events, id: \.rowID) { dayEventRow($0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayEventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor(event))
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(event.isAllDay ? "All day"
                     : event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
    }

    // MARK: Month helpers

    private var gridDays: [Date] {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month],
                                                                 from: visibleMonth))
        else { return [] }
        let weekday = cal.component(.weekday, from: monthStart)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -lead, to: monthStart)
        else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// Weekday initials rotated to the system's first weekday.
    private var weekdaySymbols: [String] {
        let cal = Calendar.current
        let syms = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(syms[first...] + syms[..<first])
    }

    private func stepMonth(_ delta: Int) {
        let cal = Calendar.current
        if let m = cal.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = m
            calendarModel.loadMonth(containing: m)
        }
    }

    private func jumpToToday() {
        visibleMonth = Date()
        selectedDay = Calendar.current.startOfDay(for: Date())
        calendarModel.loadMonth(containing: visibleMonth)
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor(event))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(timeLabel(event))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
    }

    /// `EKEvent.calendar` is implicitly-unwrapped and becomes nil if the
    /// calendar was deleted between fetch and render; fall back to gray.
    private func eventColor(_ event: EKEvent) -> Color {
        guard settings.calendarColorCode else { return Color(white: 0.85) }
        if let cg = event.calendar?.cgColor { return Color(cgColor: cg) }
        return Color(white: 0.5)
    }

    private func timeLabel(_ event: EKEvent) -> String {
        if event.isAllDay {
            return event.startDate.formatted(.dateTime.weekday(.wide).month().day()) + " · All day"
        }
        return event.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            + " · " + event.startDate.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Mirror

struct MirrorTab: View {
    @EnvironmentObject var mirror: MirrorController
    @EnvironmentObject var state: NotchState

    var body: some View {
        content
            .onAppear {
                // Once permission is granted, opening the tab IS the intent —
                // no extra click needed each time.
                mirror.resumeIfAuthorized()
            }
    }

    @ViewBuilder
    private var content: some View {
        if mirror.isRunning {
            CameraPreview(layer: mirror.previewLayer)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 6) {
                        Button { state.mirrorBig.toggle() } label: {
                            Image(systemName: state.mirrorBig
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(Circle().fill(.black.opacity(0.55)))
                        }
                        .help(state.mirrorBig ? "Shrink mirror" : "Double the mirror")
                        Button { mirror.stop() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(Circle().fill(.black.opacity(0.55)))
                        }
                        .help("Stop camera")
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "web.camera")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.3))
                if mirror.denied {
                    Text("Camera access denied — enable it in\nSystem Settings → Privacy → Camera")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                } else if mirror.unavailable {
                    Text("No camera available")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                } else {
                    Text("Check yourself before a call")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                    Button { mirror.start() } label: {
                        Text("Show Mirror")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.orange))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Stats

struct StatsTab: View {
    @EnvironmentObject var stats: StatsModel
    @EnvironmentObject var settings: SettingsStore

    private func vis(_ key: String) -> Bool { settings.isStatsTileVisible(key) }

    var body: some View {
        // Plain HStack, not a grid: every tile stretches equally in both
        // axes so the visible cards are always identical and fill the panel.
        HStack(spacing: 6) {
            if vis("cpu") {
                StatTile(title: "CPU",
                         center: pct(stats.cpu),
                         detail: nil,
                         fraction: stats.cpu)
            }
            if vis("memory") {
                StatTile(title: "Memory",
                         center: pct(stats.memUsed / stats.memTotal),
                         detail: "\(gb(stats.memUsed)) / \(gb(stats.memTotal)) GB",
                         fraction: stats.memUsed / stats.memTotal)
            }
            if vis("gpu") {
                StatTile(title: "GPU",
                         center: stats.gpu < 0 ? "—" : pct(stats.gpu),
                         detail: nil,
                         fraction: max(stats.gpu, 0))
            }
            if vis("disk") {
                StatTile(title: "Disk",
                         center: stats.diskTotal > 0
                            ? pct(1 - stats.diskFree / stats.diskTotal) : "—",
                         detail: "\(gb(stats.diskFree)) GB free",
                         fraction: stats.diskTotal > 0
                            ? 1 - stats.diskFree / stats.diskTotal : 0)
            }
            if vis("fan") {
                StatTile(title: "Fan",
                         center: stats.fanRPM < 0 ? "—"
                            : (stats.fanRPM < 1 ? "off" : "\(Int(stats.fanRPM))"),
                         detail: stats.fanRPM >= 1 ? "rpm" : nil,
                         fraction: stats.fanRPM < 0 ? 0 : min(stats.fanRPM / 6000, 1))
            }
            if vis("battery") {
                StatTile(title: "Battery",
                         center: stats.batteryLevel < 0 ? "—" : pct(stats.batteryLevel),
                         detail: stats.batteryCharging ? "charging ⚡" : nil,
                         fraction: max(stats.batteryLevel, 0),
                         invertSeverity: true)
            }
        }
        .padding(.top, 4)
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func gb(_ bytes: Double) -> String {
        String(format: "%.0f", bytes / 1_073_741_824)
    }
}

private struct StatTile: View {
    let title: String
    let center: String
    let detail: String?
    let fraction: Double
    var invertSeverity = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(fraction, 1)))
                    .stroke(ringColor,
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(center)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 5)
            }
            .frame(width: 38, height: 38)
            .animation(.easeOut(duration: 0.5), value: fraction)
            VStack(spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(0.4)
                // Always laid out (blank when absent) so tiles with a
                // sublabel are exactly as tall as tiles without one.
                Text(detail ?? " ")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
    }

    private var ringColor: Color {
        let severity = invertSeverity ? 1 - fraction : fraction
        if severity > 0.85 { return .red }
        if severity > 0.6 { return .yellow }
        return .green
    }
}

// MARK: - Toggles

struct TogglesTab: View {
    @EnvironmentObject var toggles: TogglesModel
    @EnvironmentObject var settings: SettingsStore

    private func vis(_ key: String) -> Bool { settings.isControlVisible(key) }

    var body: some View {
        VStack(spacing: 6) {
            if vis("darkMode") || vis("keepAwake") || vis("hideDesktop") {
                HStack(spacing: 6) {
                    if vis("darkMode") {
                        ToggleCard(icon: "moon.fill", label: "Dark Mode", active: false) {
                            toggles.toggleDarkMode()
                        }
                    }
                    if vis("keepAwake") {
                        ToggleCard(icon: "cup.and.saucer.fill", label: "Keep Awake",
                                   active: toggles.keepAwake) {
                            toggles.keepAwake.toggle()
                        }
                    }
                    if vis("hideDesktop") {
                        ToggleCard(icon: "eye.slash.fill", label: "Hide Desktop",
                                   active: toggles.desktopIconsHidden) {
                            toggles.toggleDesktopIcons()
                        }
                    }
                }
            }
            if vis("display") || vis("keyboard") {
                HStack(spacing: 6) {
                    if vis("display") { displayCard }
                    if vis("keyboard") { keyboardCard }
                }
            }
            if vis("mute") || vis("lock") || vis("screenshot") {
                HStack(spacing: 6) {
                    if vis("mute") {
                        ToggleCard(icon: "speaker.slash.fill", label: "Mute", active: false) {
                            toggles.toggleMute()
                        }
                    }
                    if vis("lock") {
                        ToggleCard(icon: "lock.fill", label: "Lock Screen", active: false) {
                            toggles.lockScreen()
                        }
                    }
                    if vis("screenshot") {
                        ToggleCard(icon: "camera.viewfinder", label: "Screenshot", active: false) {
                            toggles.screenshot()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var displayCard: some View {
        if toggles.displaySliderAvailable {
            BrightnessCard(icon: "sun.min.fill", endIcon: "sun.max.fill",
                           read: { toggles.readDisplayBrightness() },
                           set: { toggles.setDisplayBrightness($0) })
        } else {
            StepperCard(icon: "sun.max.fill", label: "Display",
                        minus: { toggles.displayBrightnessDown() },
                        plus: { toggles.displayBrightnessUp() })
        }
    }

    @ViewBuilder private var keyboardCard: some View {
        if toggles.keyboardSliderAvailable {
            BrightnessCard(icon: "keyboard", endIcon: "light.max",
                           read: { toggles.readKeyboardBrightness() },
                           set: { toggles.setKeyboardBrightness($0) })
        } else {
            StepperCard(icon: "keyboard", label: "Keyboard",
                        minus: { toggles.keyboardBacklightDown() },
                        plus: { toggles.keyboardBacklightUp() })
        }
    }
}

/// A scrubbable brightness capsule (applies live while dragging).
private struct BrightnessCard: View {
    let icon: String
    let endIcon: String
    let read: () -> Double
    let set: (Double) -> Void

    @State private var level: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                        .frame(height: 4)
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: max(4, geo.size.width * level), height: 4)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle().inset(by: -10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            level = min(1, max(0, v.location.x / geo.size.width))
                            set(level)
                        }
                )
            }
            .frame(height: 4)
            Image(systemName: endIcon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
        .onAppear { level = read() }
    }
}

private struct StepperCard: View {
    let icon: String
    let label: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button(action: minus) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button(action: plus) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
    }
}

private struct ToggleCard: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .foregroundStyle(active ? .black : .white.opacity(0.8))
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? AnyShapeStyle(.orange) : AnyShapeStyle(.white.opacity(0.08)))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

/// Panel-wide settings, opened from the gear in the nav dock. One row per
/// page with a switch that hides it from the tab bar and the swipe cycle.
struct SettingsTab: View {
    @EnvironmentObject var state: NotchState

    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pages")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .kerning(0.6)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(NotchTab.allCases, id: \.self) { tab in
                    settingRow(tab)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func settingRow(_ tab: NotchTab) -> some View {
        let visible = !state.hiddenTabs.contains(tab)
        // The last visible page can't be hidden — the dock is never empty.
        let locked = visible && state.visibleTabs.count == 1
        return HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(visible ? 0.8 : 0.35))
                .frame(width: 16)
            Text(tab.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(visible ? 0.9 : 0.4))
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { visible },
                set: { state.setTabHidden(tab, !$0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.orange)
                .disabled(locked)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        .help(locked ? "The last visible page can't be hidden"
                     : visible ? "Hide \(tab.title) from the dock"
                               : "Show \(tab.title) in the dock")
        .animation(.easeOut(duration: 0.15), value: visible)
    }
}

// MARK: - Equalizer

/// Bouncing bars used on the island's ear and as the media tab's waveform.
/// Driven by a run-loop timer — TimelineView's display-link pauses inside
/// non-key overlay panels, which froze the bars; a Timer never does.
struct EqualizerBars: View {
    var barCount = 3
    var barWidth: CGFloat = 2
    var maxHeight: CGFloat = 12
    var color: Color = .orange
    var animating = true
    /// Real audio levels (0…1, newest last). When present, the bars render
    /// this history instead of the synthetic sine animation.
    var levels: [Float]? = nil

    @State private var t: Double = 0
    private let timer = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let gap = barWidth
        let w = CGFloat(barCount) * barWidth + CGFloat(max(0, barCount - 1)) * gap
        // Draw the bars in a Canvas with a FIXED frame. Only the pixels inside
        // redraw on each 20fps tick — the view's geometry never changes — so the
        // refresh can't yank the bars out of the island's own move animation.
        // (The old HStack rebuilt a row of Capsule views every tick and carried
        // its own `.animation`, so the bars escaped the parent transaction and
        // arrived early or lagged as the panel slid.) Canvas redraws off the
        // Timer-fed `t`/`levels` state — no display link, so it keeps ticking
        // inside the non-key overlay panel.
        return Canvas { ctx, size in
            _ = t  // touch state so the closure re-runs each tick
            for i in 0..<barCount {
                let h = max(barWidth, height(i))
                let x = CGFloat(i) * (barWidth + gap)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
        .frame(width: w, height: maxHeight)
        .onReceive(timer) { _ in
            if animating, levels == nil { t += 1.0 / 20.0 }
        }
    }

    private func height(_ i: Int) -> CGFloat {
        if let levels, !levels.isEmpty {
            // Map bars onto the history, newest sample on the right.
            let idx = levels.count - 1 - ((barCount - 1 - i) * levels.count) / barCount
            let level = levels[max(0, min(levels.count - 1, idx))]
            return max(barWidth, maxHeight * CGFloat(level))
        }
        guard animating else { return maxHeight * 0.25 }
        let speed = 2.2 + Double(i % 4) * 0.35
        let phase = Double(i) * 0.9
        let v = (sin(t * speed + phase) + 1) / 2
        return maxHeight * (0.25 + 0.75 * v)
    }
}

extension EKEvent {
    /// Stable per-occurrence identity for `ForEach`. Recurring occurrences
    /// share one `eventIdentifier`, so combine it with the occurrence start
    /// date to avoid duplicate SwiftUI IDs.
    var rowID: String {
        let id = eventIdentifier ?? "nil"
        let start = startDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(id)@\(start)"
    }
}
