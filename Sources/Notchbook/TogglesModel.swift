import AppKit
import Combine

/// Absolute keyboard-backlight control via the private CoreBrightness
/// framework (what Control Center uses). Resolved at runtime; callers fall
/// back to step key-events if this fails on a future macOS.
/// Absolute display-brightness control via the private DisplayServices
/// framework (what the brightness keys drive). Runtime-resolved; callers
/// fall back to step key-events if unavailable.
final class DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getFn: GetFn
    private let setFn: SetFn

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY),
            let get = dlsym(handle, "DisplayServicesGetBrightness"),
            let set = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        getFn = unsafeBitCast(get, to: GetFn.self)
        setFn = unsafeBitCast(set, to: SetFn.self)
    }

    var brightness: Float {
        get {
            var value: Float = 0
            _ = getFn(CGMainDisplayID(), &value)
            return value
        }
        set {
            _ = setFn(CGMainDisplayID(), min(max(newValue, 0), 1))
        }
    }
}

final class KeyboardBacklight {
    private let client: NSObject
    private let kbID: UInt64

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else { return nil }
        let c = cls.init()
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard c.responds(to: sel),
              let ids = c.perform(sel)?.takeRetainedValue() as? [NSNumber],
              let first = ids.first
        else { return nil }
        client = c
        kbID = first.uint64Value
    }

    var brightness: Float {
        get {
            let sel = NSSelectorFromString("brightnessForKeyboard:")
            guard let imp = client.method(for: sel) else { return 0 }
            typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
            return unsafeBitCast(imp, to: Fn.self)(client, sel, kbID)
        }
        set {
            let sel = NSSelectorFromString("setBrightness:forKeyboard:")
            guard let imp = client.method(for: sel) else { return }
            typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
            _ = unsafeBitCast(imp, to: Fn.self)(client, sel, newValue, kbID)
        }
    }
}

/// Quick system controls: dark mode, keep-awake, desktop icons, volume.
final class TogglesModel: ObservableObject {
    private var pollTimer: Timer?

    /// Called when the Controls tab becomes visible. Volume and desktop-icon
    /// state were read once in init and never again, so the sliders showed
    /// launch-time values for the rest of the session — and dragging one from
    /// a stale position jumped the system to a value the user never chose.
    /// The brightness sliders had the same problem via onAppear, which cannot
    /// re-fire because the expanded panel is never unmounted.
    func setPolling(_ active: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard active else { return }
        refreshAll()
        // Only the cheap reads run on the tick. They are C calls and plist
        // lookups (microseconds), so pressing F1/F2 or toggling dark mode moves
        // the UI live. readVolume() is deliberately NOT here: it is a ~100 ms
        // synchronous NSAppleScript on the main thread, and running that twice
        // a second would trade a staleness bug for a stutter.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshCheap()
        }
        pollTimer?.tolerance = 0.1
    }

    /// Everything this tab displays, including the expensive volume read. Runs
    /// on the visibility edge only.
    func refreshAll() {
        refreshCheap()
        readVolume()
    }

    private func refreshCheap() {
        let finder = UserDefaults(suiteName: "com.apple.finder")
        desktopIconsHidden = (finder?.object(forKey: "CreateDesktop") as? Bool) == false
        darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        displayLevel = readDisplayBrightness()
        keyboardLevel = readKeyboardBrightness()
    }

    /// Live values the Controls sliders bind to, so they show the system's
    /// state rather than an echo of this app's last write.
    @Published var displayLevel: Double = 0
    @Published var keyboardLevel: Double = 0
    /// Dark Mode and Mute were hardcoded `active: false` in the view — two of
    /// the six tiles were permanently stateless while the others lit up.
    @Published var darkMode = false

    /// Why the last Controls action failed, or nil if it worked. Every action
    /// here shells out to a helper that can be missing or TCC-blocked, and
    /// until this existed all of those failures were invisible.
    @Published var lastActionFailed: String?

    @Published var keepAwake = false {
        didSet {
            guard keepAwake != oldValue else { return }
            keepAwake ? startCaffeinate() : stopCaffeinate()
        }
    }
    @Published var volume: Double = 50
    @Published var desktopIconsHidden = false

    private var caffeinate: Process?

    init() {
        // Read the real Finder setting (missing key means icons are shown).
        let finder = UserDefaults(suiteName: "com.apple.finder")
        desktopIconsHidden = (finder?.object(forKey: "CreateDesktop") as? Bool) == false
        // Seed the appearance too, so the Dark Mode glyph is already correct on
        // the very first render rather than after the first refresh tick.
        darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        readVolume()
    }

    func readVolume() {
        var error: NSDictionary?
        if let result = NSAppleScript(source: "output volume of (get volume settings)")?
            .executeAndReturnError(&error), error == nil {
            volume = Double(result.int32Value)
        }
    }

    func setVolume(_ value: Double) {
        volume = value
        shell("/usr/bin/osascript", "-e", "set volume output volume \(Int(value))")
    }

    func toggleDarkMode() {
        shell("/usr/bin/osascript", "-e",
              "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
    }

    func toggleDesktopIcons() {
        desktopIconsHidden.toggle()
        shell("/usr/bin/defaults", "write", "com.apple.finder", "CreateDesktop",
              "-bool", desktopIconsHidden ? "false" : "true")
        shell("/usr/bin/killall", "Finder")
    }

    private func startCaffeinate() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w ties the assertion to our PID: on a crash or force-quit the
        // spawned caffeinate exits with us instead of keeping the Mac awake
        // until reboot.
        p.arguments = ["-dis", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        // This one stays a long-lived Process rather than going through
        // Subprocess: it is meant to outlive the call and is terminated by
        // stopCaffeinate(). What it was missing is failure handling — if the
        // spawn threw, the toggle still lit up and the Mac still slept.
        do {
            try p.run()
        } catch {
            lastActionFailed = "caffeinate failed to start"
            caffeinate = nil
            keepAwake = false          // don't claim an assertion we don't hold
            return
        }
        // Same lie if caffeinate dies later (killed, or the assertion refused).
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.keepAwake, self.caffeinate === p else { return }
                self.lastActionFailed = "keep awake stopped unexpectedly"
                self.caffeinate = nil
                self.keepAwake = false
            }
        }
        lastActionFailed = nil
        caffeinate = p
    }

    private func stopCaffeinate() {
        caffeinate?.terminate()
        caffeinate = nil
    }

    /// Call on app quit so a keep-awake never outlives the app.
    func shutdown() {
        stopCaffeinate()
    }

    // MARK: - System keys (same events the hardware F-keys send)

    private func tapSystemKey(_ key: Int32) {
        for down in [true, false] {
            let data1 = Int((Int(key) << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    func displayBrightnessUp() { tapSystemKey(2) }      // NX_KEYTYPE_BRIGHTNESS_UP
    func displayBrightnessDown() { tapSystemKey(3) }    // NX_KEYTYPE_BRIGHTNESS_DOWN
    func keyboardBacklightUp() { tapSystemKey(21) }     // NX_KEYTYPE_ILLUMINATION_UP
    func keyboardBacklightDown() { tapSystemKey(22) }   // NX_KEYTYPE_ILLUMINATION_DOWN

    // MARK: - Absolute brightness (for the sliders)

    private let keyboardBacklight = KeyboardBacklight()
    private let displayBacklight = DisplayBrightness()

    var keyboardSliderAvailable: Bool { keyboardBacklight != nil }
    var displaySliderAvailable: Bool { displayBacklight != nil }

    func readKeyboardBrightness() -> Double {
        Double(keyboardBacklight?.brightness ?? 0)
    }

    func setKeyboardBrightness(_ value: Double) {
        keyboardBacklight?.brightness = Float(min(max(value, 0), 1))
    }

    func readDisplayBrightness() -> Double {
        Double(displayBacklight?.brightness ?? 0)
    }

    func setDisplayBrightness(_ value: Double) {
        displayBacklight?.brightness = Float(min(max(value, 0), 1))
    }

    func toggleMute() {
        shell("/usr/bin/osascript", "-e",
              "set volume output muted not (output muted of (get volume settings))")
    }

    /// Locks to the login window.
    ///
    /// This used to spawn `CGSession -suspend`, but macOS 26 ships no
    /// `User.menu` at all, so the binary does not exist and the spawn failure
    /// went into a `try?` — the button had been a silent no-op for the whole
    /// life of that OS. `SACLockScreenImmediate` is what the Apple-menu item
    /// itself calls; the key-event path is the fallback if that ever goes too.
    func lockScreen() {
        typealias LockFn = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
                               RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            let rc = unsafeBitCast(sym, to: LockFn.self)()
            if rc == 0 { lastActionFailed = nil; return }
            lastActionFailed = "lock screen failed (\(rc))"
        }
        if postLockHotkey() { lastActionFailed = nil; return }
        lastActionFailed = "Lock Screen is unavailable on this macOS"
    }

    /// Control-Command-Q, the system lock shortcut. Needs Accessibility.
    private func postLockHotkey() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let q: CGKeyCode = 0x0C
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: false)
        else { return false }
        down.flags = [.maskCommand, .maskControl]
        up.flags = [.maskCommand, .maskControl]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Screenshot capture mode (settings-driven).
    /// selection★ → interactive selection; window → interactive window-only;
    /// full → whole screen immediately. All land on the clipboard.
    var screenshotMode = "selection"

    func screenshot() {
        switch screenshotMode {
        case "window": shell("/usr/sbin/screencapture", "-icw")
        case "full":   shell("/usr/sbin/screencapture", "-c")
        default:       shell("/usr/sbin/screencapture", "-ic")
        }
    }

    /// Runs a helper tool and reports whether it actually worked. The old
    /// version was `try? p.run()` with no wait and no status, so a missing
    /// binary or a denied Automation grant produced a button that did nothing,
    /// forever, looking exactly like the buttons that work.
    @discardableResult
    private func shell(_ launchPath: String, _ args: String...) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            lastActionFailed = "\(URL(fileURLWithPath: launchPath).lastPathComponent) is not available on this macOS"
            return false
        }
        let r = Subprocess.run(launchPath, args, timeout: 10)
        if !r.ok { lastActionFailed = r.failureReason }
        return r.ok
    }
}
