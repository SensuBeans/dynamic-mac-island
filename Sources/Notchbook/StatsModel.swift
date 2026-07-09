import Foundation
import IOKit
import IOKit.ps
import Combine

/// System stats like the Stats menu-bar app: CPU, memory, GPU, disk, fan,
/// battery. Polled every 2 s, only while the Stats tab is visible.
final class StatsModel: ObservableObject {
    @Published var cpu: Double = 0                 // 0…1
    @Published var memUsed: Double = 0             // bytes
    let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var gpu: Double = -1                // 0…1, -1 = unavailable
    @Published var diskFree: Double = 0
    @Published var diskTotal: Double = 0
    @Published var fanRPM: Double = -1             // -1 = unavailable
    @Published var batteryLevel: Double = -1       // 0…1
    @Published var batteryCharging = false

    private var timer: Timer?
    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let smc = SMC()

    func setPolling(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            poll()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.poll()
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func poll() {
        pollCPU()
        pollMemory()
        pollDisk()
        pollGPU()
        pollBattery()
        fanRPM = smc?.fanRPM() ?? -1
    }

    private func pollCPU() {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
            / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = (user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                 idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        if let p = prevTicks {
            let busy = (t.user - p.user) + (t.system - p.system) + (t.nice - p.nice)
            let total = busy + (t.idle - p.idle)
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
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        memUsed = (Double(vm.active_count) + Double(vm.wire_count)
            + Double(vm.compressor_page_count)) * page
    }

    private func pollDisk() {
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys:
            [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        else { return }
        diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        diskTotal = Double(v.volumeTotalCapacity ?? 0)
    }

    private func pollGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0)
                == kIOReturnSuccess,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let util = perf["Device Utilization %"] as? Int {
                gpu = Double(util) / 100
                IOObjectRelease(entry)
                return
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    private func pollBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                .takeUnretainedValue() as? [String: Any],
                let current = desc[kIOPSCurrentCapacityKey] as? Int,
                let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            batteryLevel = Double(current) / Double(max)
            batteryCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
        }
    }
}

// MARK: - SMC (fan speed)

/// Minimal AppleSMC client, just enough to read fan 0's actual RPM ("F0Ac").
final class SMC {
    private var conn: io_connect_t = 0

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
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

    func fanRPM() -> Double? {
        guard let data = read(fourCC("F0Ac")) else { return nil }
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
        guard var info = call(query), info.result == 0 else { return nil }
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
