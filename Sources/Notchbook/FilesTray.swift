import AppKit
import Combine

/// A drop shelf: drag files onto the notch to hold them, drag them out to
/// move them somewhere, or AirDrop them. Persists across launches.
final class FilesTray: ObservableObject {
    @Published private(set) var items: [URL] = [] {
        didSet { save() }
    }

    private static var storeURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchbook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tray.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            // Keep every saved entry — do NOT prune by existence here. Files on
            // a not-yet-mounted external/network volume look "missing" at launch;
            // filtering them out (then persisting via the `items` didSet) would
            // permanently drop them the moment the volume was offline. The UI
            // marks unreachable items instead (see `isAvailable`).
            items = paths.map(URL.init(fileURLWithPath:))
        }
    }

    /// Whether a tray item's file is currently reachable (mounted). Unreachable
    /// items are kept and shown dimmed rather than removed.
    func isAvailable(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) {
            items.append(url)
        }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
    }

    func clear() {
        items.removeAll()
    }

    func airDrop(_ urls: [URL]? = nil) {
        let payload = urls ?? items
        guard !payload.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: payload)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items.map(\.path)) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}
