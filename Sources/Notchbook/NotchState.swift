import Foundation
import Combine
import SwiftUI

/// A transient notification shown in the collapsed island.
struct NotchToast: Equatable {
    var icon: String
    var title: String
    var subtitle: String?
    var useArtwork = false
    var color: Color = .white
}

/// Where the settings section is currently pointed. `nil` (on `NotchState`)
/// means settings is closed.
enum SettingsRoute: Equatable {
    case root
    case general
    case page(NotchTab)
}

enum NotchTab: String, CaseIterable {
    case media, notes, timer, tray, terminal, agents, calendar, mirror, stats, toggles

    var icon: String {
        switch self {
        case .notes: return "note.text"
        case .media: return "music.note"
        case .timer: return "timer"
        case .tray: return "tray.full"
        case .terminal: return "terminal"
        case .agents: return "sparkles"
        case .calendar: return "calendar"
        case .mirror: return "web.camera"
        case .stats: return "gauge.with.needle"
        case .toggles: return "switch.2"
        }
    }

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .media: return "Media"
        case .timer: return "Timer"
        case .tray: return "Tray"
        case .terminal: return "Terminal"
        case .agents: return "Agents"
        case .calendar: return "Calendar"
        case .mirror: return "Mirror"
        case .stats: return "Stats"
        case .toggles: return "Controls"
        }
    }
}

final class NotchState: ObservableObject {
    /// Fallback page count for a first launch with no saved preference. The
    /// live count is `pages.count`, driven by the notes page-count setting.
    static let defaultPageCount = 3

    @Published var isExpanded = false
    /// Pinned: the panel ignores mouse-leave and stays expanded until the
    /// user unpins it (or presses Esc).
    @Published var pinned = false
    /// Cursor is over the nav dock's strip below the panel (drives its
    /// show/hide — the dock stays hidden until summoned).
    @Published var navHovered = false
    @Published var currentPage = 0
    @Published var currentTab: NotchTab = .media
    /// Which settings page (if any) is showing in the content island. `nil` =
    /// settings closed; `.root` = the section list; `.general`/`.page(tab)` =
    /// a dedicated detail page. Opened from the gear in the nav dock.
    @Published var settingsRoute: SettingsRoute?
    /// Convenience for the many call sites that only care whether settings is
    /// open at all (not which page).
    var showingSettings: Bool { settingsRoute != nil }
    /// Tabs the user has hidden from the nav dock and tab-swipe cycle.
    @Published var hiddenTabs: Set<NotchTab> {
        didSet {
            UserDefaults.standard.set(hiddenTabs.map(\.rawValue),
                                      forKey: "hiddenTabs")
        }
    }
    /// User-defined order of ALL tabs, drives the nav dock and the swipe cycle.
    /// Persisted; new tabs added in a later build are appended in canonical
    /// order on load. Reorder it by dragging a chip in the nav dock.
    @Published var tabOrder: [NotchTab] {
        didSet {
            UserDefaults.standard.set(tabOrder.map(\.rawValue), forKey: "tabOrder")
        }
    }
    /// Mirror at double size ("twice as big") — toggled from the mirror
    /// overlay, reset whenever the mirror is left.
    @Published var mirrorBig = false
    /// Calendar tab view mode: false = 7-day list (default), true = mini month
    /// grid. Lives here (not just view-local) because AppDelegate.islandRect and
    /// NotchView must read it to size the island in lockstep. Persisted.
    @Published var calendarMonthMode = UserDefaults.standard.bool(forKey: "calendarMonthMode") {
        didSet { UserDefaults.standard.set(calendarMonthMode, forKey: "calendarMonthMode") }
    }
    /// Cursor is over the collapsed island's sound-wave ear — it morphs
    /// into mini transport controls.
    @Published var earHovered = false
    /// Transient notification shown beside the notch while collapsed.
    @Published var toast: NotchToast?
    /// Live progress of a horizontal two-finger swipe over the expanded
    /// panel, -1…1 (negative = toward the next tab). The content nudges
    /// with the fingers and the tab bar previews where the swipe lands.
    @Published var tabSwipeProgress: CGFloat = 0
    /// Hidden entirely while the user swipes between Spaces.
    @Published var spaceTransitioning = false
    /// A popped-up NSMenu (sound output picker) is tracking — the mouse-away
    /// watcher must not collapse the panel out from under it. Not @Published:
    /// only the AppKit watcher reads it.
    var menuHoldsOpen = false

    private var toastWork: DispatchWorkItem?
    /// Default on-screen seconds for toasts whose caller doesn't specify one.
    /// Kept in sync with `SettingsStore.toastDuration` by the app delegate.
    var defaultToastDuration: Double = 3

    func showToast(_ t: NotchToast, duration: Double? = nil) {
        toast = t
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? defaultToastDuration),
                                      execute: work)
    }
    @Published var pages: [String]

    var onQuit: (() -> Void)?
    /// Asks the app delegate to expand the panel immediately (used when
    /// files are dragged onto the collapsed island).
    var onExpandRequest: (() -> Void)?
    /// Reports cursor hover over the island; the delegate expands after a
    /// short dwell so drive-by cursor passes don't open the panel.
    var onHoverChange: ((Bool) -> Void)?

    private var saveWork: DispatchWorkItem?
    private var cancellable: AnyCancellable?

    private static var storeURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchbook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }

    private var lastSaved: [String]?

    /// Tabs shown in the nav dock and reachable by swipe, in canonical order.
    /// Never empty — if every tab were hidden, media stays as a floor.
    var visibleTabs: [NotchTab] {
        let visible = tabOrder.filter { !hiddenTabs.contains($0) }
        return visible.isEmpty ? [.media] : visible
    }

    /// Commit a new order for the visible tabs (from a nav-dock drag). Hidden
    /// tabs keep their relative order and trail behind, out of sight.
    func setVisibleOrder(_ newVisible: [NotchTab]) {
        let hidden = tabOrder.filter { hiddenTabs.contains($0) }
        let merged = newVisible + hidden
        // Guard against a malformed input dropping/duplicating tabs.
        guard Set(merged) == Set(NotchTab.allCases), merged.count == NotchTab.allCases.count
        else { return }
        tabOrder = merged
    }

    /// Canonical order with any tabs missing from `saved` appended (handles new
    /// tabs shipped after the user last saved an order), de-duplicated.
    private static func normalizedOrder(_ saved: [NotchTab]) -> [NotchTab] {
        var seen = Set<NotchTab>()
        var order = saved.filter { seen.insert($0).inserted }
        for t in NotchTab.allCases where !seen.contains(t) { order.append(t) }
        return order
    }

    /// Hide/show a tab. The last visible tab can't be hidden; hiding the
    /// current tab hops to the nearest one still visible.
    func setTabHidden(_ tab: NotchTab, _ hidden: Bool) {
        if hidden {
            guard visibleTabs.count > 1 else { return }
            hiddenTabs.insert(tab)
            if currentTab == tab { currentTab = visibleTabs[0] }
        } else {
            hiddenTabs.remove(tab)
        }
    }

    init() {
        hiddenTabs = Set(
            (UserDefaults.standard.stringArray(forKey: "hiddenTabs") ?? [])
                .compactMap(NotchTab.init(rawValue:)))
        tabOrder = Self.normalizedOrder(
            (UserDefaults.standard.stringArray(forKey: "tabOrder") ?? [])
                .compactMap(NotchTab.init(rawValue:)))
        // Desired page count from the setting (read straight from UserDefaults
        // — NotchState is built before SettingsStore). Load tolerantly: pad or
        // truncate saved pages to that count, but NEVER truncate away a page
        // that still holds text (grow the count to keep it). The old code
        // discarded ALL notes on any count mismatch — this must not.
        let desired = min(9, max(1,
            UserDefaults.standard.object(forKey: "notes.pageCount") as? Int
                ?? Self.defaultPageCount))
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            let lastNonEmpty = (saved.lastIndex { !$0.isEmpty }).map { $0 + 1 } ?? 0
            let target = max(desired, lastNonEmpty)
            var p = saved
            if p.count < target {
                p.append(contentsOf: Array(repeating: "", count: target - p.count))
            } else if p.count > target {
                p = Array(p.prefix(target))
            }
            pages = p
            lastSaved = (p == saved) ? saved : nil  // nil forces a resave at the new count
        } else {
            pages = Array(repeating: "", count: desired)
        }
        if hiddenTabs.contains(currentTab) { currentTab = visibleTabs[0] }
        cancellable = $pages
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSave() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        guard pages != lastSaved else { return }
        // Keep a one-step backup so a bad write can never destroy notes.
        if let existing = try? Data(contentsOf: Self.storeURL) {
            try? existing.write(to: Self.storeURL.appendingPathExtension("bak"),
                                options: .atomic)
        }
        if let data = try? JSONEncoder().encode(pages) {
            try? data.write(to: Self.storeURL, options: .atomic)
            lastSaved = pages
        }
    }
}
