import Foundation
import Combine

/// Single source of truth for every user-configurable setting. Each property is
/// `@Published` and writes itself straight back to `UserDefaults` on change
/// under a namespaced key. Every default is registered so a virgin defaults
/// domain reproduces today's hard-coded behavior exactly (the ★ defaults in
/// `opus-settings-plan.md`) — existing users see zero change until they touch
/// something.
///
/// NOTE (deviation from the spec, deliberate): `hiddenTabs` stays owned by
/// `NotchState` rather than migrating here. It already persists correctly and
/// is read on hot paths (`visibleTabs`, `stepTab`); moving it would ripple
/// through many call sites for no functional gain. The store owns every *new*
/// setting; the settings root page still drives `NotchState.setTabHidden` for
/// the per-tab hide switches.
final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    // MARK: General
    @Published var hoverToExpand: Bool { didSet { set(hoverToExpand, "general.hoverToExpand") } }
    /// Nav bar docks under the notch (false★) or hangs below the panel (true).
    /// The liquid morph runs mirrored in bottom mode — same choreography.
    @Published var navAtBottom: Bool { didSet { set(navAtBottom, "general.navAtBottom") } }
    /// Dwell before a hover opens the panel, seconds. instant★ / 0.2 / 0.5.
    @Published var expandDelay: Double { didSet { set(expandDelay, "general.expandDelay") } }
    @Published var haptics: Bool { didSet { set(haptics, "general.haptics") } }
    /// Default toast on-screen seconds. short 1.5 / normal 3★ / long 5.
    @Published var toastDuration: Double { didSet { set(toastDuration, "general.toastDuration") } }
    @Published var batteryAlerts: Bool { didSet { set(batteryAlerts, "general.batteryAlerts") } }
    @Published var trackChangeToast: Bool { didSet { set(trackChangeToast, "general.trackChangeToast") } }
    /// Mirror of the real `SMAppService` login-item state; the toggle registers/
    /// unregisters and this reflects the resulting status.
    @Published var launchAtLogin: Bool { didSet { set(launchAtLogin, "general.launchAtLogin") } }

    // MARK: Media
    @Published var youtubeEnabled: Bool { didSet { set(youtubeEnabled, "media.youtubeEnabled") } }
    /// Seconds before the paused media ear hides. 30 / 90★ / `never` (= -1).
    @Published var pausedEarHide: Double { didSet { set(pausedEarHide, "media.pausedEarHide") } }
    @Published var swipeToSkip: Bool { didSet { set(swipeToSkip, "media.swipeToSkip") } }
    @Published var swipeVolume: Bool { didSet { set(swipeVolume, "media.swipeVolume") } }
    /// Volume percent per point of vertical swipe. low 0.25 / normal 0.4★ / high 0.6.
    @Published var volumeSensitivity: Double { didSet { set(volumeSensitivity, "media.volumeSensitivity") } }
    @Published var ambientGlow: Bool { didSet { set(ambientGlow, "media.ambientGlow") } }
    /// Ambient glow strength multiplier. subtle 0.6 / normal 1★ / vivid 1.5.
    @Published var glowIntensity: Double { didSet { set(glowIntensity, "media.glowIntensity") } }
    @Published var liveWaveform: Bool { didSet { set(liveWaveform, "media.liveWaveform") } }

    // MARK: Notes
    @Published var notesPageCount: Int { didSet { set(notesPageCount, "notes.pageCount") } }
    /// Editor point size. small 11 / normal 13★ / large 15.
    @Published var notesFontSize: Double { didSet { set(notesFontSize, "notes.fontSize") } }
    @Published var notesMonospaced: Bool { didSet { set(notesMonospaced, "notes.monospaced") } }
    @Published var notesConfirmClear: Bool { didSet { set(notesConfirmClear, "notes.confirmClear") } }

    // MARK: Timer
    @Published var focusMinutes: Int { didSet { set(focusMinutes, "timer.focusMinutes") } }
    @Published var breakMinutes: Int { didSet { set(breakMinutes, "timer.breakMinutes") } }
    /// End-of-phase sound name, or "none". Glass★ / Ping / Funk / none.
    @Published var timerEndSound: String { didSet { set(timerEndSound, "timer.endSound") } }
    @Published var timerEndToast: Bool { didSet { set(timerEndToast, "timer.endToast") } }
    @Published var timerCountdownEar: Bool { didSet { set(timerCountdownEar, "timer.countdownEar") } }
    @Published var timerAutoStart: Bool { didSet { set(timerAutoStart, "timer.autoStart") } }

    // MARK: Tray
    @Published var trayOpenOnDrag: Bool { didSet { set(trayOpenOnDrag, "tray.openOnDrag") } }
    @Published var trayRemoveAfterDragOut: Bool { didSet { set(trayRemoveAfterDragOut, "tray.removeAfterDragOut") } }
    @Published var trayClearOnQuit: Bool { didSet { set(trayClearOnQuit, "tray.clearOnQuit") } }
    /// Tile edge. compact 54 / normal 62★.
    @Published var trayTileSize: Double { didSet { set(trayTileSize, "tray.tileSize") } }

    // MARK: Calendar
    /// Days of events to show. today 1 / 3 / week 7★ / 2 weeks 14.
    @Published var calendarLookAhead: Int { didSet { set(calendarLookAhead, "calendar.lookAhead") } }
    /// Excluded calendar identifiers (excluded-set, so new calendars default to shown).
    @Published var calendarExcludedIDs: [String] { didSet { set(calendarExcludedIDs, "calendar.excludedIDs") } }
    @Published var calendarAllDay: Bool { didSet { set(calendarAllDay, "calendar.allDay") } }
    @Published var calendarColorCode: Bool { didSet { set(calendarColorCode, "calendar.colorCode") } }

    // MARK: Mirror
    /// Selected camera `uniqueID`; empty = system default.
    @Published var mirrorCameraID: String { didSet { set(mirrorCameraID, "mirror.cameraID") } }
    @Published var mirrorFlip: Bool { didSet { set(mirrorFlip, "mirror.flip") } }
    @Published var mirrorRememberBig: Bool { didSet { set(mirrorRememberBig, "mirror.rememberBig") } }

    // MARK: Stats
    /// Poll interval seconds. 1 / 2★ / 5.
    @Published var statsRefreshRate: Double { didSet { set(statsRefreshRate, "stats.refreshRate") } }
    /// Hidden tile keys (cpu, memory, gpu, disk, fan, battery).
    @Published var statsHiddenTiles: [String] { didSet { set(statsHiddenTiles, "stats.hiddenTiles") } }

    // MARK: Agents
    /// Auto-resume a session cut off mid-turn by the usage limit: at the limit's
    /// reset the notch types `continue` into that session's terminal by itself.
    @Published var agentsAutoResume: Bool { didSet { set(agentsAutoResume, "agents.autoResume") } }

    // MARK: Controls
    /// Hidden control keys (darkMode, keepAwake, hideDesktop, display, keyboard, mute, lock, screenshot).
    @Published var togglesHiddenControls: [String] { didSet { set(togglesHiddenControls, "toggles.hiddenControls") } }
    /// screencapture interactive mode. selection★ / window / full.
    @Published var screenshotMode: String { didSet { set(screenshotMode, "toggles.screenshotMode") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Register ★ defaults so the very first launch (empty domain) behaves
        // exactly like today. `object(forKey:)` below then always resolves.
        defaults.register(defaults: [
            "general.hoverToExpand": true,
            "general.navAtBottom": false,
            "general.expandDelay": 0.0,
            "general.haptics": true,
            "general.toastDuration": 3.0,
            "general.batteryAlerts": true,
            "general.trackChangeToast": true,
            "general.launchAtLogin": false,
            "media.youtubeEnabled": true,
            "media.pausedEarHide": 90.0,
            "media.swipeToSkip": true,
            "media.swipeVolume": true,
            "media.volumeSensitivity": 0.4,
            "media.ambientGlow": true,
            "media.glowIntensity": 1.0,
            "media.liveWaveform": true,
            "notes.pageCount": 3,
            "notes.fontSize": 13.0,
            "notes.monospaced": false,
            "notes.confirmClear": false,
            "timer.focusMinutes": 25,
            "timer.breakMinutes": 5,
            "timer.endSound": "Glass",
            "timer.endToast": true,
            "timer.countdownEar": true,
            // ★ = today's behavior. The pomodoro model auto-advances to the
            // next phase today, so the default is ON to keep that unchanged
            // (the spec table's "off" would silently change existing behavior).
            "timer.autoStart": true,
            "tray.openOnDrag": true,
            "tray.removeAfterDragOut": false,
            "tray.clearOnQuit": false,
            "tray.tileSize": 62.0,
            "calendar.lookAhead": 7,
            "calendar.allDay": true,
            "calendar.colorCode": true,
            "mirror.cameraID": "",
            "mirror.flip": true,
            "mirror.rememberBig": false,
            "stats.refreshRate": 2.0,
            "agents.autoResume": true,
            "toggles.screenshotMode": "selection",
        ])

        hoverToExpand = defaults.bool(forKey: "general.hoverToExpand")
        navAtBottom = defaults.bool(forKey: "general.navAtBottom")
        expandDelay = defaults.double(forKey: "general.expandDelay")
        haptics = defaults.bool(forKey: "general.haptics")
        toastDuration = defaults.double(forKey: "general.toastDuration")
        batteryAlerts = defaults.bool(forKey: "general.batteryAlerts")
        trackChangeToast = defaults.bool(forKey: "general.trackChangeToast")
        launchAtLogin = defaults.bool(forKey: "general.launchAtLogin")

        youtubeEnabled = defaults.bool(forKey: "media.youtubeEnabled")
        pausedEarHide = defaults.double(forKey: "media.pausedEarHide")
        swipeToSkip = defaults.bool(forKey: "media.swipeToSkip")
        swipeVolume = defaults.bool(forKey: "media.swipeVolume")
        volumeSensitivity = defaults.double(forKey: "media.volumeSensitivity")
        ambientGlow = defaults.bool(forKey: "media.ambientGlow")
        glowIntensity = defaults.double(forKey: "media.glowIntensity")
        liveWaveform = defaults.bool(forKey: "media.liveWaveform")

        notesPageCount = defaults.integer(forKey: "notes.pageCount")
        notesFontSize = defaults.double(forKey: "notes.fontSize")
        notesMonospaced = defaults.bool(forKey: "notes.monospaced")
        notesConfirmClear = defaults.bool(forKey: "notes.confirmClear")

        focusMinutes = defaults.integer(forKey: "timer.focusMinutes")
        breakMinutes = defaults.integer(forKey: "timer.breakMinutes")
        timerEndSound = defaults.string(forKey: "timer.endSound") ?? "Glass"
        timerEndToast = defaults.bool(forKey: "timer.endToast")
        timerCountdownEar = defaults.bool(forKey: "timer.countdownEar")
        timerAutoStart = defaults.bool(forKey: "timer.autoStart")

        trayOpenOnDrag = defaults.bool(forKey: "tray.openOnDrag")
        trayRemoveAfterDragOut = defaults.bool(forKey: "tray.removeAfterDragOut")
        trayClearOnQuit = defaults.bool(forKey: "tray.clearOnQuit")
        trayTileSize = defaults.double(forKey: "tray.tileSize")

        calendarLookAhead = defaults.integer(forKey: "calendar.lookAhead")
        calendarExcludedIDs = defaults.stringArray(forKey: "calendar.excludedIDs") ?? []
        calendarAllDay = defaults.bool(forKey: "calendar.allDay")
        calendarColorCode = defaults.bool(forKey: "calendar.colorCode")

        mirrorCameraID = defaults.string(forKey: "mirror.cameraID") ?? ""
        mirrorFlip = defaults.bool(forKey: "mirror.flip")
        mirrorRememberBig = defaults.bool(forKey: "mirror.rememberBig")

        statsRefreshRate = defaults.double(forKey: "stats.refreshRate")
        statsHiddenTiles = defaults.stringArray(forKey: "stats.hiddenTiles") ?? []

        agentsAutoResume = defaults.bool(forKey: "agents.autoResume")

        togglesHiddenControls = defaults.stringArray(forKey: "toggles.hiddenControls") ?? []
        screenshotMode = defaults.string(forKey: "toggles.screenshotMode") ?? "selection"
    }

    private func set(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    // MARK: Set helpers for the multi-select settings

    func setStatsTile(_ key: String, visible: Bool) {
        var s = Set(statsHiddenTiles)
        if visible { s.remove(key) } else { s.insert(key) }
        statsHiddenTiles = Array(s)
    }
    func isStatsTileVisible(_ key: String) -> Bool { !statsHiddenTiles.contains(key) }

    func setControlVisible(_ key: String, visible: Bool) {
        var s = Set(togglesHiddenControls)
        if visible { s.remove(key) } else { s.insert(key) }
        togglesHiddenControls = Array(s)
    }
    func isControlVisible(_ key: String) -> Bool { !togglesHiddenControls.contains(key) }

    func setCalendarExcluded(_ id: String, excluded: Bool) {
        var s = Set(calendarExcludedIDs)
        if excluded { s.insert(id) } else { s.remove(id) }
        calendarExcludedIDs = Array(s)
    }
    func isCalendarIncluded(_ id: String) -> Bool { !calendarExcludedIDs.contains(id) }
}
