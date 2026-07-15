import AppKit
import CoreAudio
import SwiftUI

/// Sound-output switching in the spirit of Control Center's sound widget.
///
/// Two routing worlds live in one menu:
/// - "Mac Output": CoreAudio devices (speakers, wired, paired Bluetooth) —
///   switching flips the system default output, so everything moves.
/// - "AirPlay": Music.app's own AirPlay targets (HomePod, Apple TV, AirPlay
///   TVs). These are NOT CoreAudio devices until connected, and macOS offers
///   no public system-wide AirPlay routing — but Music is scriptable, so
///   selecting one tells Music to play there, which is what actually
///   carries the song to a HomePod.
final class AudioOutputModel: NSObject, ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        let transport: UInt32
    }

    struct AirPlayTarget: Equatable {
        let name: String
        let kind: String   // Music's kind, lowercased ("homepod", "apple tv", "computer"…)
        let selected: Bool
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var currentID = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var airPlayTargets: [AirPlayTarget] = []

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    override init() {
        super.init()
        refresh()
        // Track hot-plug and default-output changes (AirPods connecting,
        // cable pulled) so the button state is right before the menu opens.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main, block)
        }
    }

    var current: Device? { devices.first { $0.id == currentID } }

    /// Routed anywhere beyond the built-in speakers (system device or Music
    /// AirPlaying away from the computer) — drives the button's bright tint.
    var isRoutedExternally: Bool {
        if let current, current.transport != kAudioDeviceTransportTypeBuiltIn {
            return true
        }
        return airPlayTargets.contains { $0.selected && $0.kind != "computer" }
    }

    func refresh() {
        currentID = readDefaultOutput()
        devices = readOutputDevices()
    }

    // MARK: - Menu

    /// Present both sections at the cursor. Synchronous — returns when the
    /// menu closes, so the caller can bracket collapse suppression.
    func presentMenu() {
        refresh()
        let menu = NSMenu()
        menu.autoenablesItems = false
        if musicIsRunning, !airPlayTargets.isEmpty {
            menu.addItem(header("AirPlay — Music"))
            for target in airPlayTargets {
                let item = NSMenuItem(title: target.name,
                                      action: #selector(pickAirPlay(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = target.name
                item.state = target.selected ? .on : .off
                item.image = symbol(airPlayIcon(for: target))
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(header("Mac Output"))
        for device in devices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(pickDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == currentID ? .on : .off
            item.image = symbol(deviceIcon(for: device))
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        prefetchAirPlay()   // targets/selection may be stale after the pick
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard var id = sender.representedObject as? AudioObjectID else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(systemObject, &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
        refresh()
    }

    @objc private func pickAirPlay(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // Escape backslashes FIRST, then quotes — otherwise a name ending in
        // `\` (or containing one) would produce a broken/`\"`-mangled script.
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        runOSAScript(
            "tell application \"Music\" to set current AirPlay devices" +
            " to {AirPlay device \"\(escaped)\"}", wait: false)
        // Connecting takes a beat; re-read so the checkmark and tint follow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.prefetchAirPlay()
        }
    }

    // MARK: - Music AirPlay targets

    /// Cheap cache fill, called when the media tab appears — enumerating
    /// AirPlay devices can take Music a second of network discovery, too
    /// slow to do synchronously at click time.
    func prefetchAirPlay() {
        guard musicIsRunning else {
            if !airPlayTargets.isEmpty { airPlayTargets = [] }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let targets = self.fetchAirPlayTargets()
            DispatchQueue.main.async { self.airPlayTargets = targets }
        }
    }

    /// Never script Music unless it's already running — AppleScript would
    /// launch it just to answer the question.
    private var musicIsRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private func fetchAirPlayTargets() -> [AirPlayTarget] {
        let script = """
        tell application "Music"
            set out to ""
            repeat with d in AirPlay devices
                set k to "unknown"
                try
                    set k to (kind of d) as text
                end try
                set out to out & (name of d) & tab & k & tab & \
        (selected of d as text) & linefeed
            end repeat
            return out
        end tell
        """
        guard let output = runOSAScript(script, wait: true) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3 else { return nil }
            return AirPlayTarget(name: parts[0],
                                 kind: parts[1].lowercased(),
                                 selected: parts[2] == "true")
        }
    }

    @discardableResult
    private func runOSAScript(_ script: String, wait: Bool) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        guard wait else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Icons

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func airPlayIcon(for target: AirPlayTarget) -> String {
        let key = target.kind + " " + target.name.lowercased()
        if key.contains("homepod") { return "homepod.fill" }
        if key.contains("apple tv") { return "appletv.fill" }
        if key.contains("tv") { return "tv" }
        if key.contains("computer") { return "laptopcomputer" }
        if key.contains("bluetooth") { return "headphones" }
        return "hifispeaker.fill"
    }

    private func deviceIcon(for device: Device) -> String {
        let name = device.name.lowercased()
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        default:
            return "hifispeaker.fill"
        }
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - CoreAudio reads

    private func readDefaultOutput() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        return id
    }

    private func readOutputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id) else { return nil }
            let transport = readTransport(id)
            // Skip aggregates and virtual loopbacks — including our own
            // AudioSpectrum tap device — the way Control Center does.
            if transport == kAudioDeviceTransportTypeAggregate
                || transport == kAudioDeviceTransportTypeVirtual { return nil }
            guard let name = readName(id) else { return nil }
            return Device(id: id, name: name, transport: transport)
        }
    }

    private func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private func readTransport(_ id: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        return transport
    }

    private func readName(_ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
