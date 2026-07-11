import SwiftUI
import EventKit
import AVFoundation

// MARK: - Notes

struct NotesTab: View {
    @EnvironmentObject var state: NotchState
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 8) {
            TextEditor(text: editorText)
                .focused(focus)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.07))
                )

            HStack {
                pageTabs
                Text("\(state.pages[state.currentPage].count) chars · autosaved")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 6)
                Spacer()
                Button { state.pages[state.currentPage] = "" } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Clear this page")
            }
        }
    }

    /// The hidden (collapsed) editor must never write through to the store —
    /// an AppKit-backed TextEditor can push its initial empty text back
    /// through the binding during setup, which once wiped saved notes.
    private var editorText: Binding<String> {
        Binding(
            get: { state.pages[state.currentPage] },
            set: { newValue in
                guard state.isExpanded else { return }
                state.pages[state.currentPage] = newValue
            })
    }

    private var pageTabs: some View {
        HStack(spacing: 3) {
            ForEach(0..<NotchState.pageCount, id: \.self) { i in
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

    var body: some View {
        if let np = media.nowPlaying {
            mediaCard(np)
                .onAppear {
                    volume = media.readPlayerVolume()
                    // Music's AirPlay list needs network discovery — warm it
                    // here so the output menu is populated at click time.
                    audioOutput.prefetchAirPlay()
                }
                .onChange(of: np.source) { _ in volume = media.readPlayerVolume() }
                .onChange(of: np.title) { _ in
                    if showLyrics {
                        lyrics.fetch(title: np.title, artist: np.artist,
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
                                lyrics.fetch(title: np.title, artist: np.artist,
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
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            Text(timeString(media.position))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
            Text("-" + timeString(max(0, media.duration - media.position)))
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.45))
    }

    private var fraction: CGFloat {
        media.duration > 0 ? min(1, media.position / media.duration) : 0
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Apple Music-style synced lyrics: bold rounded lines, the current one
/// bright, the next ones dimmed and softly blurred, springing upward as the
/// song advances. Tap any line to seek there.
private struct LyricsTicker: View {
    @EnvironmentObject var media: MediaWatcher
    @EnvironmentObject var lyrics: LyricsModel
    let accent: Color

    @State private var now = Date()
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch lyrics.status {
            case .loading:
                Text("Finding lyrics…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle, .unavailable:
                Text("No lyrics for this song")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if lyrics.lines.isEmpty {
                    plainSheet
                } else {
                    ticker
                }
            }
        }
        .onReceive(timer) { now = $0 }
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

    /// Player position, interpolated between the 1 Hz polls. Reads the
    /// clock directly: the cached timer date starves under the media tab's
    /// re-render churn, which froze the computed position (the growing
    /// stale-now offset cancelled the advancing poll exactly).
    private var position: Double {
        let base = media.position
        guard media.nowPlaying?.isPlaying == true else { return base }
        return base + Date().timeIntervalSince(media.positionStamp)
    }

    private var currentIndex: Int {
        let p = position
        var idx = -1
        for (i, line) in lyrics.lines.enumerated() where line.time <= p { idx = i }
        return idx
    }

    private var ticker: some View {
        let i = currentIndex
        return VStack(alignment: .leading, spacing: 7) {
            lyricLine(i, current: true)
            lyricLine(i + 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .animation(.spring(response: 0.55, dampingFraction: 0.9), value: i)
    }

    @ViewBuilder
    private func lyricLine(_ idx: Int, current: Bool = false) -> some View {
        if idx >= 0, idx < lyrics.lines.count {
            let line = lyrics.lines[idx]
            // Never truncate a lyric: the active line wraps as far as it
            // needs, the upcoming one gets two lines. Identity is the LINE
            // (not line+role), so promotion from "next" to "current" is one
            // view smoothly animating scale/opacity/position — a fade-up —
            // rather than a hard swap of two copies.
            Text(line.text)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(current ? 1 : 0.25))
                .blur(radius: current ? 0 : 0.7)
                .scaleEffect(current ? 1 : 0.86, anchor: .topLeading)
                .lineLimit(current ? 3 : 2)
                .minimumScaleFactor(current ? 0.8 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { media.seek(to: line.time) }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .move(edge: .top))))
                .id(line.id)
        } else if idx == -1, current {
            // Intro before the first line: show what's coming, dimmed.
            Text("…")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

private struct LaunchButton: View {
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

    private let columns = [GridItem(.adaptive(minimum: 62), spacing: 8)]

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
                        .overlay { MultiFileDragOverlay(urls: tray.items) }
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
    let url: URL

    @State private var thumbnail: NSImage?
    @State private var hovered = false

    private static let side: CGFloat = 54

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
                .frame(width: Self.side, height: Self.side)
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
                .frame(width: Self.side + 8)
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
            TrayThumbnails.shared.load(url, side: Self.side) { thumbnail = $0 }
        }
    }
}

// MARK: - Calendar

struct CalendarTab: View {
    @EnvironmentObject var calendarModel: CalendarModel

    var body: some View {
        Group {
            if !calendarModel.hasAccess {
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
            } else if calendarModel.events.isEmpty {
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
                        ForEach(calendarModel.events, id: \.eventIdentifier) { event in
                            eventRow(event)
                        }
                    }
                }
            }
        }
        .onAppear { calendarModel.load() }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(cgColor: event.calendar.cgColor))
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

    var body: some View {
        // Plain HStack, not a grid: every tile stretches equally in both
        // axes so the six cards are always identical and fill the panel.
        HStack(spacing: 6) {
            StatTile(title: "CPU",
                     center: pct(stats.cpu),
                     detail: nil,
                     fraction: stats.cpu)
            StatTile(title: "Memory",
                     center: pct(stats.memUsed / stats.memTotal),
                     detail: "\(gb(stats.memUsed)) / \(gb(stats.memTotal)) GB",
                     fraction: stats.memUsed / stats.memTotal)
            StatTile(title: "GPU",
                     center: stats.gpu < 0 ? "—" : pct(stats.gpu),
                     detail: nil,
                     fraction: max(stats.gpu, 0))
            StatTile(title: "Disk",
                     center: stats.diskTotal > 0
                        ? pct(1 - stats.diskFree / stats.diskTotal) : "—",
                     detail: "\(gb(stats.diskFree)) GB free",
                     fraction: stats.diskTotal > 0
                        ? 1 - stats.diskFree / stats.diskTotal : 0)
            StatTile(title: "Fan",
                     center: stats.fanRPM < 0 ? "—"
                        : (stats.fanRPM < 1 ? "off" : "\(Int(stats.fanRPM))"),
                     detail: stats.fanRPM >= 1 ? "rpm" : nil,
                     fraction: stats.fanRPM < 0 ? 0 : min(stats.fanRPM / 6000, 1))
            StatTile(title: "Battery",
                     center: stats.batteryLevel < 0 ? "—" : pct(stats.batteryLevel),
                     detail: stats.batteryCharging ? "charging ⚡" : nil,
                     fraction: max(stats.batteryLevel, 0),
                     invertSeverity: true)
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

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ToggleCard(icon: "moon.fill", label: "Dark Mode", active: false) {
                    toggles.toggleDarkMode()
                }
                ToggleCard(icon: "cup.and.saucer.fill", label: "Keep Awake",
                           active: toggles.keepAwake) {
                    toggles.keepAwake.toggle()
                }
                ToggleCard(icon: "eye.slash.fill", label: "Hide Desktop",
                           active: toggles.desktopIconsHidden) {
                    toggles.toggleDesktopIcons()
                }
            }
            HStack(spacing: 6) {
                if toggles.displaySliderAvailable {
                    BrightnessCard(icon: "sun.min.fill", endIcon: "sun.max.fill",
                                   read: { toggles.readDisplayBrightness() },
                                   set: { toggles.setDisplayBrightness($0) })
                } else {
                    StepperCard(icon: "sun.max.fill", label: "Display",
                                minus: { toggles.displayBrightnessDown() },
                                plus: { toggles.displayBrightnessUp() })
                }
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
            HStack(spacing: 6) {
                ToggleCard(icon: "speaker.slash.fill", label: "Mute", active: false) {
                    toggles.toggleMute()
                }
                ToggleCard(icon: "lock.fill", label: "Lock Screen", active: false) {
                    toggles.lockScreen()
                }
                ToggleCard(icon: "camera.viewfinder", label: "Screenshot", active: false) {
                    toggles.screenshot()
                }
            }
            Spacer(minLength: 0)
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
        HStack(spacing: barWidth) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: height(i))
                    .frame(height: maxHeight, alignment: .center)
            }
        }
        .onReceive(timer) { _ in
            if animating, levels == nil { t += 1.0 / 20.0 }
        }
        .animation(.linear(duration: 0.09), value: levels)
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
