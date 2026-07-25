import AppKit
import QuickLookThumbnailing
import SwiftUI

/// What happened when we tried to render a tile's preview. The caller used to
/// get a bare `nil` for all of these, so "still loading", "no preview for this
/// type", "the file is gone" and "the volume is unmounted" were pixel-identical
/// — a permanently dead shelf entry looked exactly like a working one.
enum ThumbState: Equatable {
    case image(NSImage)
    /// QuickLook has no generator for this type; the Finder icon is correct.
    case noPreview
    /// The file no longer exists at that path.
    case missing
    /// It exists but we were not allowed to read it.
    case denied
}

/// QuickLook thumbnails for tray tiles, cached so scrolling never re-renders.
final class TrayThumbnails {
    static let shared = TrayThumbnails()

    private let cache = NSCache<NSURL, NSImage>()
    /// Completions waiting on an in-flight generation, keyed by URL. A tile
    /// recreated by LazyVGrid scroll while the first request is still running
    /// rides along here instead of being dropped (which left it on the generic
    /// icon forever).
    private var pending: [URL: [(ThumbState) -> Void]] = [:]
    /// URLs QuickLook could not render — cached so re-appearing tiles fall back
    /// to the Finder icon permanently instead of re-firing the XPC every time.
    /// Only files that actually exist are recorded, so a merely-unmounted file
    /// isn't blocked forever once its volume returns.
    private var failed: [URL: ThumbState] = [:]
    private let lock = NSLock()

    /// Calls back on the main queue with a thumbnail, or nil if QuickLook
    /// can't render one (the caller falls back to the Finder icon).
    func load(_ url: URL, side: CGFloat = 64, completion: @escaping (ThumbState) -> Void) {
        if let hit = cache.object(forKey: url as NSURL) {
            completion(.image(hit))
            return
        }
        lock.lock()
        if let known = failed[url] {
            lock.unlock()
            completion(known)
            return
        }
        if pending[url] != nil {
            pending[url]?.append(completion)  // ride the existing request
            lock.unlock()
            return
        }
        pending[url] = [completion]
        lock.unlock()

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail)
        // QuickLook hands back the exact reason it failed; this used to
        // discard it one line later with `_`.
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, error in
            guard let self else { return }
            let state: ThumbState
            if let image = rep?.nsImage {
                state = .image(image)
            } else {
                state = Self.classify(error, url: url)
            }
            self.lock.lock()
            let waiters = self.pending.removeValue(forKey: url) ?? []
            if case .image(let img) = state {
                self.cache.setObject(img, forKey: url as NSURL)
            } else if state == .noPreview {
                // Only cache a permanent verdict. A missing/denied file may come
                // back when its volume remounts or the download finishes.
                self.failed[url] = state
            }
            self.lock.unlock()
            DispatchQueue.main.async { waiters.forEach { $0(state) } }
        }
    }

    private static func classify(_ error: Error?, url: URL) -> ThumbState {
        let ns = error as NSError?
        if ns?.domain == NSCocoaErrorDomain {
            switch ns?.code {
            case 4, 260: return .missing        // no such file / no such directory
            case 257:    return .denied         // not permitted to read
            default:     break
            }
        }
        if !FileManager.default.fileExists(atPath: url.path) { return .missing }
        return .noPreview
    }
}

/// Transparent AppKit overlay that starts a native multi-file drag session —
/// SwiftUI's .onDrag can only vend a single item, but dragging the whole
/// shelf out at once (the Droppy move) needs one session with every file.
struct MultiFileDragOverlay: NSViewRepresentable {
    let urls: [URL]
    /// Called with the dragged URLs when they were dropped OUTSIDE the app
    /// (a real move/copy landed) — used by "remove after drag out".
    var onDroppedOut: (([URL]) -> Void)?

    func makeNSView(context: Context) -> MultiFileDragView { MultiFileDragView() }

    func updateNSView(_ view: MultiFileDragView, context: Context) {
        view.urls = urls
        view.onDroppedOut = onDroppedOut
    }
}

final class MultiFileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onDroppedOut: (([URL]) -> Void)?
    /// URLs in flight for the current session, resolved in `endedAt`.
    private var draggingURLs: [URL] = []

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty else { return }
        draggingURLs = urls
        let origin = convert(event.locationInWindow, from: nil)
        // Fan the icons out slightly so the drag reads as a stack of files.
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(index, 4)) * 3
            item.setDraggingFrame(
                NSRect(x: origin.x - 16 + offset, y: origin.y - 16 - offset,
                       width: 32, height: 32),
                contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A non-empty operation means the files actually landed somewhere
        // outside the app — report them so the tray can drop them if the
        // "remove after drag out" setting is on.
        let dropped = draggingURLs
        draggingURLs = []
        guard operation != [], !dropped.isEmpty else { return }
        onDroppedOut?(dropped)
    }
}
