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
        p.arguments = ["-dis"]
        try? p.run()
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

    func lockScreen() {
        shell("/usr/bin/pmset", "displaysleepnow")
    }

    func screenshot() {
        shell("/usr/sbin/screencapture", "-ic")
    }

    private func shell(_ launchPath: String, _ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try? p.run()
    }
}
