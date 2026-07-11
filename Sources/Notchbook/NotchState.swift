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

enum NotchTab: String, CaseIterable {
    case media, notes, timer, tray, calendar, mirror, stats, toggles

    var icon: String {
        switch self {
        case .notes: return "note.text"
        case .media: return "music.note"
        case .timer: return "timer"
        case .tray: return "tray.full"
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
        case .calendar: return "Calendar"
        case .mirror: return "Mirror"
        case .stats: return "Stats"
        case .toggles: return "Controls"
        }
    }
}

final class NotchState: ObservableObject {
    static let pageCount = 3

    @Published var isExpanded = false
    /// Pinned: the panel ignores mouse-leave and stays expanded until the
    /// user unpins it (or presses Esc).
    @Published var pinned = false
    /// Cursor is over the nav dock's strip below the panel (drives its
    /// show/hide — the dock stays hidden until summoned).
    @Published var navHovered = false
    @Published var currentPage = 0
    @Published var currentTab: NotchTab = .media
    /// Mirror at double size ("twice as big") — toggled from the mirror
    /// overlay, reset whenever the mirror is left.
    @Published var mirrorBig = false
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

    func showToast(_ t: NotchToast, duration: Double = 3) {
        toast = t
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
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

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode([String].self, from: data),
           saved.count == Self.pageCount {
            pages = saved
            lastSaved = saved
        } else {
            pages = Array(repeating: "", count: Self.pageCount)
        }
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
