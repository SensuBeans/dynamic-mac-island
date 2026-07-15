import SwiftUI
import AVFoundation

// MARK: - Router

/// Renders the settings section for the current route. The panel is sized to
/// the standard expanded content, so anything taller scrolls inside the page.
struct SettingsContainer: View {
    let route: SettingsRoute

    var body: some View {
        Group {
            switch route {
            case .root:            SettingsRootPage()
            case .general:         SettingsGeneralPage()
            case .page(let tab):   SettingsDetailPage(tab: tab)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Reusable chrome

/// A settings page: a fixed header (with optional back chevron) above a
/// vertically scrolling column of rows.
struct SettingsPage<Content: View>: View {
    let title: String
    var back: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsHeader(title: title, back: back)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    content()
                }
                .padding(.bottom, 2)
            }
        }
    }
}

struct SettingsHeader: View {
    let title: String
    var back: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Back")
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }
}

/// The standard row shell: an optional leading icon, a label, then a trailing
/// control. Matches the existing white-opacity capsule (radius 8, ~28pt tall).
struct SettingRow<Trailing: View>: View {
    let label: String
    var icon: String?
    var help: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 16)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        .help(help ?? "")
    }
}

struct SettingSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.orange)
    }
}

/// A compact segmented picker. `options` are (label, value) pairs; the value
/// type just needs to be `Hashable` (Double / Int / String here).
struct SettingSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(String, T)]
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.1) { opt in
                Text(opt.0).tag(opt.1)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
        .fixedSize()
    }
}

/// −/+ stepper with a formatted value in the middle. `set` receives the
/// proposed value already clamped to `range`; it may refuse (e.g. notes won't
/// drop a non-empty page) by simply not applying it.
struct SettingStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    var format: (Int) -> String = { "\($0)" }
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            stepButton("minus", enabled: value > range.lowerBound) {
                set(max(range.lowerBound, value - 1))
            }
            Text(format(value))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 44)
            stepButton("plus", enabled: value < range.upperBound) {
                set(min(range.upperBound, value + 1))
            }
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.25))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A borderless dropdown menu with a checkmark on the current value.
struct SettingMenu<T: Hashable>: View {
    let current: T
    let options: [(String, T)]
    let onSelect: (T) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.1) { opt in
                Button { onSelect(opt.1) } label: {
                    HStack {
                        Text(opt.0)
                        if opt.1 == current { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(options.first { $0.1 == current }?.0 ?? "—")
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Root

struct SettingsRootPage: View {
    @EnvironmentObject var state: NotchState

    var body: some View {
        SettingsPage(title: "Settings") {
            Button { state.settingsRoute = .general } label: {
                navRow(icon: "gearshape", title: "General")
            }
            .buttonStyle(.plain)

            Text("Tabs")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .kerning(0.6)
                .padding(.top, 4)
                .padding(.leading, 2)

            ForEach(NotchTab.allCases, id: \.self) { tab in
                tabRow(tab)
            }
        }
    }

    /// A plain "label + chevron" navigation row (used for General).
    private func navRow(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        .contentShape(Rectangle())
    }

    /// A per-tab row: hide switch (with the last-visible lock) + a chevron that
    /// opens the tab's settings page.
    private func tabRow(_ tab: NotchTab) -> some View {
        let visible = !state.hiddenTabs.contains(tab)
        let locked = visible && state.visibleTabs.count == 1
        return HStack(spacing: 8) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(visible ? 0.8 : 0.35))
                .frame(width: 16)
            Text(tab.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(visible ? 0.9 : 0.4))
            Spacer()
            Toggle("", isOn: Binding(get: { visible },
                                     set: { state.setTabHidden(tab, !$0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.orange)
                .disabled(locked)
                .help(locked ? "The last visible tab can't be hidden"
                             : visible ? "Hide \(tab.title)" : "Show \(tab.title)")
            Button { state.settingsRoute = .page(tab) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(tab.title) settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
    }
}

// MARK: - General page

struct SettingsGeneralPage: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        SettingsPage(title: "General", back: { state.settingsRoute = .root }) {
            SettingRow(label: "Hover to expand",
                       help: "Off: click the notch to open") {
                SettingSwitch(isOn: $settings.hoverToExpand)
            }
            SettingRow(label: "Expand delay") {
                SettingSegmented(selection: $settings.expandDelay,
                                 options: [("Instant", 0.0), ("0.2s", 0.2), ("0.5s", 0.5)])
            }
            SettingRow(label: "Haptics") {
                SettingSwitch(isOn: $settings.haptics)
            }
            SettingRow(label: "Toast duration") {
                SettingSegmented(selection: $settings.toastDuration,
                                 options: [("Short", 1.5), ("Normal", 3.0), ("Long", 5.0)])
            }
            SettingRow(label: "Battery alerts") {
                SettingSwitch(isOn: $settings.batteryAlerts)
            }
            SettingRow(label: "Track-change toast") {
                SettingSwitch(isOn: $settings.trackChangeToast)
            }
            SettingRow(label: "Launch at login") {
                SettingSwitch(isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { LoginItem.set($0, store: settings) }))
            }
        }
        .onAppear { settings.launchAtLogin = LoginItem.isEnabled }
    }
}

// MARK: - Per-tab detail pages

struct SettingsDetailPage: View {
    @EnvironmentObject var state: NotchState
    let tab: NotchTab

    var body: some View {
        SettingsPage(title: tab.title, back: { state.settingsRoute = .root }) {
            switch tab {
            case .media:    MediaSettings()
            case .notes:    NotesSettings()
            case .timer:    TimerSettings()
            case .tray:     TraySettings()
            case .terminal: TerminalSettings()
            case .agents:   AgentsSettings()
            case .servers:  ServersSettings()
            case .calendar: CalendarSettings()
            case .mirror:   MirrorSettings()
            case .stats:    StatsSettings()
            case .toggles:  ControlsSettings()
            }
        }
    }
}

// MARK: Servers settings

private struct ServersSettings: View {
    // Shared with ServersModel (UserDefaults.standard); overriding the URL lets
    // you point the tab at a dead port to exercise the "isn't running" state.
    @AppStorage("servers.baseURL") private var baseURL = "http://localhost:7780"
    var body: some View {
        SettingRow(label: "Local Starter URL") {
            TextField("http://localhost:7780", text: $baseURL)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .frame(width: 190)
        }
        SettingRow(label: "Reset to default") {
            Button("localhost:7780") { baseURL = "http://localhost:7780" }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: Media settings

private struct MediaSettings: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        SettingRow(label: "YouTube detection") { SettingSwitch(isOn: $settings.youtubeEnabled) }
        SettingRow(label: "Hide paused ear") {
            SettingSegmented(selection: $settings.pausedEarHide,
                             options: [("30s", 30.0), ("90s", 90.0), ("Never", -1.0)])
        }
        SettingRow(label: "Swipe to skip tracks") { SettingSwitch(isOn: $settings.swipeToSkip) }
        SettingRow(label: "Swipe volume") { SettingSwitch(isOn: $settings.swipeVolume) }
        SettingRow(label: "Volume sensitivity") {
            SettingSegmented(selection: $settings.volumeSensitivity,
                             options: [("Low", 0.25), ("Normal", 0.4), ("High", 0.6)])
        }
        SettingRow(label: "Ambient album glow") { SettingSwitch(isOn: $settings.ambientGlow) }
        SettingRow(label: "Glow intensity") {
            SettingSegmented(selection: $settings.glowIntensity,
                             options: [("Subtle", 0.6), ("Normal", 1.0), ("Vivid", 1.5)])
        }
        SettingRow(label: "Live audio waveform") { SettingSwitch(isOn: $settings.liveWaveform) }
    }
}

// MARK: Notes settings

private struct NotesSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: NotchState
    var body: some View {
        SettingRow(label: "Number of pages",
                   help: "Won't drop a page that still has text") {
            SettingStepper(value: settings.notesPageCount, range: 1...9) { proposed in
                NotesPages.setCount(proposed, settings: settings, state: state)
            }
        }
        SettingRow(label: "Editor font size") {
            SettingSegmented(selection: $settings.notesFontSize,
                             options: [("S", 11.0), ("M", 13.0), ("L", 15.0)])
        }
        SettingRow(label: "Monospaced font") { SettingSwitch(isOn: $settings.notesMonospaced) }
        SettingRow(label: "Confirm before clear") { SettingSwitch(isOn: $settings.notesConfirmClear) }
    }
}

// MARK: Timer settings

private struct TimerSettings: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        SettingRow(label: "Focus length") {
            SettingStepper(value: settings.focusMinutes, range: 5...90,
                           format: { "\($0) min" }) { settings.focusMinutes = $0 }
        }
        SettingRow(label: "Break length") {
            SettingStepper(value: settings.breakMinutes, range: 1...30,
                           format: { "\($0) min" }) { settings.breakMinutes = $0 }
        }
        SettingRow(label: "End-of-phase sound") {
            SettingMenu(current: settings.timerEndSound,
                        options: [("Glass", "Glass"), ("Ping", "Ping"),
                                  ("Funk", "Funk"), ("None", "none")]) {
                settings.timerEndSound = $0
            }
        }
        SettingRow(label: "End-of-phase toast") { SettingSwitch(isOn: $settings.timerEndToast) }
        SettingRow(label: "Countdown in island ear") { SettingSwitch(isOn: $settings.timerCountdownEar) }
        SettingRow(label: "Auto-start next phase") { SettingSwitch(isOn: $settings.timerAutoStart) }
    }
}

// MARK: Tray settings

private struct TraySettings: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        SettingRow(label: "Open tray on file drag") { SettingSwitch(isOn: $settings.trayOpenOnDrag) }
        SettingRow(label: "Remove after drag out") { SettingSwitch(isOn: $settings.trayRemoveAfterDragOut) }
        SettingRow(label: "Clear tray on quit") { SettingSwitch(isOn: $settings.trayClearOnQuit) }
        SettingRow(label: "Tile size") {
            SettingSegmented(selection: $settings.trayTileSize,
                             options: [("Compact", 54.0), ("Normal", 62.0)])
        }
    }
}

// MARK: Placeholder for tabs with no settings of their own

private struct NoOptionsSettings: View {
    let note: String
    var body: some View {
        SettingRow(label: "No options", help: note) {
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
    }
}

private struct TerminalSettings: View {
    var body: some View { NoOptionsSettings(note: "Managed by the Terminal tab") }
}

// MARK: Agents settings

private struct AgentsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        SettingRow(label: "Auto-resume when limits reset",
                   help: "If a session is cut off mid-task by the usage limit, "
                       + "the notch types “continue” into its terminal the moment "
                       + "the window reopens.") {
            SettingSwitch(isOn: $settings.agentsAutoResume)
        }
    }
}

// MARK: Calendar settings

private struct CalendarSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var calendarModel: CalendarModel
    var body: some View {
        SettingRow(label: "Look ahead") {
            SettingSegmented(selection: $settings.calendarLookAhead,
                             options: [("Today", 1), ("3d", 3), ("Week", 7), ("2wk", 14)])
        }
        SettingRow(label: "Calendars") {
            let cals = calendarModel.allCalendars()
            Menu {
                ForEach(cals, id: \.calendarIdentifier) { cal in
                    Button {
                        let id = cal.calendarIdentifier
                        settings.setCalendarExcluded(id, excluded: settings.isCalendarIncluded(id))
                    } label: {
                        HStack {
                            Text(cal.title)
                            if settings.isCalendarIncluded(cal.calendarIdentifier) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                let shown = cals.filter { settings.isCalendarIncluded($0.calendarIdentifier) }.count
                HStack(spacing: 3) {
                    Text(settings.calendarExcludedIDs.isEmpty ? "All" : "\(shown)/\(cals.count)")
                        .font(.system(size: 10.5))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        SettingRow(label: "All-day events") { SettingSwitch(isOn: $settings.calendarAllDay) }
        SettingRow(label: "Color-code by calendar") { SettingSwitch(isOn: $settings.calendarColorCode) }
    }
}

// MARK: Mirror settings

private struct MirrorSettings: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        SettingRow(label: "Camera") {
            SettingMenu(current: settings.mirrorCameraID,
                        options: MirrorSettings.cameraOptions()) {
                settings.mirrorCameraID = $0
            }
        }
        SettingRow(label: "Flip horizontally") { SettingSwitch(isOn: $settings.mirrorFlip) }
        SettingRow(label: "Remember doubled size") { SettingSwitch(isOn: $settings.mirrorRememberBig) }
    }

    /// System default plus every discoverable camera, keyed by `uniqueID`.
    static func cameraOptions() -> [(String, String)] {
        var opts: [(String, String)] = [("System default", "")]
        // `.external`/`.continuityCamera` are macOS 14+; guard so this compiles
        // on the .v13 target.
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(contentsOf: [.external, .continuityCamera]) }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                       mediaType: .video,
                                                       position: .unspecified)
        for d in session.devices { opts.append((d.localizedName, d.uniqueID)) }
        return opts
    }
}

// MARK: Stats settings

private struct StatsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    private let tiles = [("CPU", "cpu"), ("Memory", "memory"), ("GPU", "gpu"),
                         ("Disk", "disk"), ("Fan", "fan"), ("Battery", "battery")]
    var body: some View {
        SettingRow(label: "Refresh rate") {
            SettingSegmented(selection: $settings.statsRefreshRate,
                             options: [("1s", 1.0), ("2s", 2.0), ("5s", 5.0)])
        }
        Text("Visible tiles")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase).kerning(0.6)
            .padding(.top, 4).padding(.leading, 2)
        ForEach(tiles, id: \.1) { tile in
            SettingRow(label: tile.0) {
                SettingSwitch(isOn: Binding(
                    get: { settings.isStatsTileVisible(tile.1) },
                    set: { settings.setStatsTile(tile.1, visible: $0) }))
            }
        }
    }
}

// MARK: Controls settings

private struct ControlsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    private let controls = [("Dark Mode", "darkMode"), ("Keep Awake", "keepAwake"),
                            ("Hide Desktop", "hideDesktop"), ("Display", "display"),
                            ("Keyboard", "keyboard"), ("Mute", "mute"),
                            ("Lock Screen", "lock"), ("Screenshot", "screenshot")]
    var body: some View {
        SettingRow(label: "Screenshot mode") {
            SettingSegmented(selection: $settings.screenshotMode,
                             options: [("Selection", "selection"), ("Window", "window"), ("Full", "full")])
        }
        Text("Visible controls")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase).kerning(0.6)
            .padding(.top, 4).padding(.leading, 2)
        ForEach(controls, id: \.1) { ctl in
            SettingRow(label: ctl.0) {
                SettingSwitch(isOn: Binding(
                    get: { settings.isControlVisible(ctl.1) },
                    set: { settings.setControlVisible(ctl.1, visible: $0) }))
            }
        }
    }
}
