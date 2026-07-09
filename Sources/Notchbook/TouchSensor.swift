import Foundation

/// Raw trackpad finger-contact sensing via MultitouchSupport (private but
/// stable for a decade, no TCC permission). Lets the island hide the moment
/// a multi-finger gesture STARTS, instead of waiting for the Space change.
final class TouchSensor {
    static var onFingerCount: ((Int) -> Void)?
    private static var started = false
    private static var lastCount: Int32 = -1

    static func start() {
        guard !started else { return }
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY),
            let createSym = dlsym(handle, "MTDeviceCreateDefault"),
            let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
            let startSym = dlsym(handle, "MTDeviceStart")
        else { return }

        typealias CreateFn = @convention(c) () -> UnsafeMutableRawPointer?
        typealias Callback = @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
            Int32, Double, Int32) -> Int32
        typealias RegFn = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
        typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

        guard let device = unsafeBitCast(createSym, to: CreateFn.self)() else { return }
        let register = unsafeBitCast(regSym, to: RegFn.self)
        register(device) { _, _, numTouches, _, _ in
            // Fires every frame while touching — only forward count changes.
            if numTouches != TouchSensor.lastCount {
                TouchSensor.lastCount = numTouches
                let n = Int(numTouches)
                DispatchQueue.main.async { TouchSensor.onFingerCount?(n) }
            }
            return 0
        }
        unsafeBitCast(startSym, to: StartFn.self)(device, 0)
        started = true
    }
}
