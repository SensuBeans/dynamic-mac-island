import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Launch at login" setting.
/// The store value mirrors the real system status.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func set(_ on: Bool, store: SettingsStore) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("notchbook login item: %@", error.localizedDescription)
            }
        }
        store.launchAtLogin = isEnabled
    }
}

/// Notes page-count migration. Growing pads with empty pages; shrinking never
/// drops a page that still has text — the request is clamped to the last
/// non-empty page. Keeps `state.pages`, `settings.notesPageCount`, and
/// `state.currentPage` consistent.
enum NotesPages {
    static func setCount(_ proposed: Int, settings: SettingsStore, state: NotchState) {
        let current = settings.notesPageCount
        var target = max(1, min(9, proposed))
        if target < current {
            // Refuse to drop any non-empty page.
            let lastNonEmpty = (state.pages.lastIndex { !$0.isEmpty }).map { $0 + 1 } ?? 1
            target = max(target, lastNonEmpty)
        }
        guard target != current else { return }

        if target > state.pages.count {
            state.pages.append(contentsOf: Array(repeating: "",
                                                 count: target - state.pages.count))
        } else if target < state.pages.count {
            state.pages = Array(state.pages.prefix(target))
        }
        if state.currentPage >= target { state.currentPage = target - 1 }
        settings.notesPageCount = target
    }
}
