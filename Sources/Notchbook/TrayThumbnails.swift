import AppKit
import QuickLookThumbnailing
import SwiftUI

/// QuickLook thumbnails for tray tiles, cached so scrolling never re-renders.
final class TrayThumbnails {
    static let shared = TrayThumbnails()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: Set<URL> = []
    private let lock = NSLock()

    /// Calls back on the main queue with a thumbnail, or nil if QuickLook
    /// can't render one (the caller falls back to the Finder icon).
    func load(_ url: URL, side: CGFloat = 64, completion: @escaping (NSImage?) -> Void) {
        if let hit = cache.object(forKey: url as NSURL) {
            completion(hit)
            return
        }
        lock.lock()
        let alreadyLoading = inFlight.contains(url)
        if !alreadyLoading { inFlight.insert(url) }
        lock.unlock()
        if alreadyLoading { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let self else { return }
            self.lock.lock()
            self.inFlight.remove(url)
            self.lock.unlock()
            let image = rep?.nsImage
            if let image { self.cache.setObject(image, forKey: url as NSURL) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}

/// Transparent AppKit overlay that starts a native multi-file drag session —
/// SwiftUI's .onDrag can only vend a single item, but dragging the whole
/// shelf out at once (the Droppy move) needs one session with every file.
struct MultiFileDragOverlay: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> MultiFileDragView { MultiFileDragView() }

    func updateNSView(_ view: MultiFileDragView, context: Context) {
        view.urls = urls
    }
}

final class MultiFileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty else { return }
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
}
