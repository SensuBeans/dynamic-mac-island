import Foundation
import IOKit
import IOKit.ps
import Combine

/// System stats like the Stats menu-bar app: CPU, memory, GPU, disk, fan,
/// battery. Polled every 2 s, only while the Stats tab is visible.
final class StatsModel: ObservableObject {
    @Published var cpu: Double = -1                // 0…1, -1 = no sample yet
    @Published var memUsed: Double = 0             // bytes
    let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var gpu: Double = -1                // 0…1, -1 = unavailable
    @Published var diskFree: Double = 0
    @Published var diskTotal: Double = 0
    @Published var fanRPM: Double = -1             // -1 = unavailable, 0 = stopped
    /// Fan 0's rated range, read once from SMC. nil until the first successful
    /// read; the gauge falls back to a plain 0…max scale while it is nil.
    @Published var fanMin: Double = 0
    @Published var fanMax: Double = 0
    @Published var batteryLevel: Double = -1       // 0…1
    @Published var batteryCharging = false
    /// Per-tile reason a metric is missing, keyed by tile id. Every poll below
    /// used to `return` silently on failure and leave the last good value in
    /// place, so a source that died mid-session looked exactly like one that
    /// was updating to a stable number.
    @Published var unavailable: [String: String] = [:]

    /// Settings-driven poll interval (seconds). Changing it while polling
    /// restarts the timer at the new cadence.
    var refreshInterval: Double = 2 {
        didSet {
            guard timer != nil, oldValue != refreshInterval else { return }
            timer?.invalidate(); timer = nil
            setPolling(true)
        }
    }
    /// Tiles the user hid — their poll work is skipped entirely.
    var hiddenTiles: Set<String> = []

    private var timer: Timer?
    /// Serial queue for the slow IOKit / filesystem probes, so they never run on
    /// the main run loop alongside the island's animations.
    private let probeQueue = DispatchQueue(label: "com.sensubeans.notchbook.stats",
                                           qos: .utility)
    private var prevTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private let smc = SMC()
    /// `mach_host_self()` returns a send right that must be released; cache it
    /// once instead of leaking a fresh one on every 2 s poll.
    private let hostPort = mach_host_self()

    deinit {
        mach_port_deallocate(mach_task_self_, hostPort)
    }

    func setPolling(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            poll()
            timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
                self?.poll()
            }
        } else {
            timer?.invalidate()
            timer = nil
            // Drop the tick baseline. Keeping it means the first poll after the
            // next expand diffs against a snapshot from however long the notch
            // was closed and paints that average as the current CPU load.
            prevTicks = nil
        }
    }

    /// CPU and memory are `host_statistics` calls costing microseconds, so they
    /// stay inline. Disk, GPU and fan do not: an APFS capacity computation walks
    /// snapshots, `IORegistryEntryCreateCFProperties` serialises the accelerator's
    /// ENTIRE property dictionary out of the kernel, and the SMC read is up to six
    /// IOKit round trips. Together they ran on the main run loop every 2 s — the
    /// same run loop driving the panel's spring animations — so they move to a
    /// background queue and publish their results back in one hop.
    private func poll() {
        if !hiddenTiles.contains("cpu") { pollCPU() }
        if !hiddenTiles.contains("memory") { pollMemory() }

        let wantDisk = !hiddenTiles.contains("disk")
        let wantGPU = !hiddenTiles.contains("gpu")
        let wantBattery = !hiddenTiles.contains("battery")
        let wantFan = !hiddenTiles.contains("fan")
        let needRange = fanMax == 0
        guard wantDisk || wantGPU || wantBattery || wantFan else { return }

        probeQueue.async { [weak self] in
            guard let self else { return }
            let disk = wantDisk ? Self.probeDisk() : nil
            let gpu = wantGPU ? Self.probeGPU() : nil
            let battery = wantBattery ? Self.probeBattery() : nil
            let rpm = wantFan ? (self.smc?.fanRPM() ?? -1) : nil
            let range = (wantFan && needRange) ? self.smc?.fanRange() : nil
            let noSMC = self.smc == nil

            DispatchQueue.main.async {
                if let disk {
                    self.diskFree = disk.free
                    self.diskTotal = disk.total
                    self.unavailable["disk"] = disk.error
                }
                if let gpu {
                    self.gpu = gpu.value
                    self.unavailable["gpu"] = gpu.error
                }
                if let battery {
                    self.batteryLevel = battery.level
                    self.batteryCharging = battery.charging
                    self.unavailable["battery"] = battery.error
                }
                if let rpm {
                    self.fanRPM = rpm
                    self.unavailable["fan"] = noSMC ? "No AppleSMC service on this Mac"
                        : (rpm < 0 ? "SMC has no F0Ac key (no fan?)" : nil)
                }
                if let range { self.fanMin = range.min; self.fanMax = range.max }
            }
        }
    }

    /// Probes below are `static` and return plain values on purpose: they run on
    /// `probeQueue`, so they must not touch any `@Published` state.
    private static func probeDisk() -> (free: Double, total: Double, error: String?) {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys:
            [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        else { return (0, 0, "Couldn't read the boot volume") }
        return (Double(v.volumeAvailableCapacityForImportantUsage ?? 0),
                Double(v.volumeTotalCapacity ?? 0), nil)
    }

    private static func probeGPU() -> (value: Double, error: String?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else {
            return (-1, "No IOAccelerator service")
        }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
                == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let util = perf["Device Utilization %"] as? Int {
                IOObjectRelease(entry)
                return (Double(util) / 100, nil)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        // Fell through every node without finding the key — say so instead of
        // leaving the last reading frozen on screen.
        return (-1, "IOAccelerator reports no Device Utilization %")
    }

    private func pollCPU() {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
            / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else {
            cpu = -1; unavailable["cpu"] = "host_statistics failed (\(kr))"; return
        }
        unavailable["cpu"] = nil
        // cpu_ticks are natural_t (UInt32) and wrap; subtract with wrapping `&-`
        // in UInt32 *before* widening, else the underflow traps after long uptimes.
        let t = (user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                 idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        if let p = prevTicks {
            let busy = UInt64(t.user &- p.user) + UInt64(t.system &- p.system)
                + UInt64(t.nice &- p.nice)
            let total = busy + UInt64(t.idle &- p.idle)
            if total > 0 { cpu = Double(busy) / Double(total) }
        }
        prevTicks = t
    }

    private func pollMemory() {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
            / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else {
            unavailable["memory"] = "host_statistics64 failed (\(kr))"; return
        }
        unavailable["memory"] = nil
        let page = Double(vm_kernel_page_size)
        memUsed = (Double(vm.active_count) + Double(vm.wire_count)
            + Double(vm.compressor_page_count)) * page
    }



    private static func probeBattery() -> (level: Double, charging: Bool, error: String?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (-1, false, "No power-source data") }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                .takeUnretainedValue() as? [String: Any],
                // Take the internal battery specifically. The loop used to run
                // to the end without breaking, so with a UPS attached the last
                // source in the list won and the tile showed the UPS's charge.
                (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                let current = desc[kIOPSCurrentCapacityKey] as? Int,
                let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (Double(current) / Double(max),
                    (desc[kIOPSIsChargingKey] as? Bool) ?? false, nil)
        }
        return (-1, false, "No internal battery")
    }
}

// MARK: - SMC (fan speed)

/// Minimal AppleSMC client, just enough to read fan 0's actual RPM ("F0Ac").
final class SMC {
    private var conn: io_connect_t = 0

    /// Mirrors AppleSMC's `SMCKeyData_keyInfo_t`. C pads this to 12 bytes after
    /// the trailing `UInt8`; Swift would lay it out as 9 and shrink `KeyData`
    /// to 76, which makes every `IOConnectCallStructMethod` fail with
    /// `kIOReturnBadArgument`. The explicit tail padding restores the ABI.
    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        private var pad: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    init?() {
        // The struct passed to AppleSMC is ABI-fixed at 80 bytes. If a future
        // edit drops the KeyInfo padding this trips immediately in debug rather
        // than silently returning nil from every read for the app's lifetime.
        assert(MemoryLayout<KeyData>.size == 80,
               "AppleSMC SMCKeyData_t ABI is 80 bytes, got \(MemoryLayout<KeyData>.size)")
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(conn)
    }

    func fanRPM() -> Double? { value("F0Ac") }

    /// Fan 0's min/max rated RPM. Static per machine, so the caller reads it
    /// once and uses it to normalize the gauge instead of a hardcoded ceiling.
    func fanRange() -> (min: Double, max: Double)? {
        guard let lo = value("F0Mn"), let hi = value("F0Mx"), hi > lo else { return nil }
        return (lo, hi)
    }

    private func value(_ key: String) -> Double? {
        guard let data = read(fourCC(key)) else { return nil }
        switch data.keyInfo.dataType {
        case fourCC("flt "):
            let raw = withUnsafeBytes(of: data.bytes) { $0.load(as: UInt32.self) }
            return Double(Float(bitPattern: UInt32(littleEndian: raw)))
        case fourCC("fpe2"):
            let hi = UInt16(data.bytes.0), lo = UInt16(data.bytes.1)
            return Double((hi << 8 | lo) >> 2)
        default:
            return nil
        }
    }

    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func read(_ key: UInt32) -> KeyData? {
        // First fetch the key's type/size, then the value itself.
        var query = KeyData()
        query.key = key
        query.data8 = 9  // kSMCGetKeyInfo
        guard let info = call(query), info.result == 0 else { return nil }
        var readReq = KeyData()
        readReq.key = key
        readReq.keyInfo = info.keyInfo
        readReq.data8 = 5  // kSMCReadKey
        guard var out = call(readReq), out.result == 0 else { return nil }
        out.keyInfo = info.keyInfo
        return out
    }

    private func call(_ input: KeyData) -> KeyData? {
        var input = input
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.size
        let kr = IOConnectCallStructMethod(conn, 2 /* kSMCHandleYPCEvent */,
                                           &input, MemoryLayout<KeyData>.size,
                                           &output, &outSize)
        return kr == kIOReturnSuccess ? output : nil
    }
}
