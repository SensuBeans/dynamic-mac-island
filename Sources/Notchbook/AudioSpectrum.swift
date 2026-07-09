import AudioToolbox
import Combine
import Foundation
import QuartzCore

/// Live loudness of whatever the Mac is playing, as a rolling history the
/// media tab renders as its waveform — so the bars move with the actual song.
///
/// Uses a Core Audio process tap (macOS 14.2+). The first activation shows
/// the system's "record system audio" prompt; if the user declines, `levels`
/// stays empty and the waveform falls back to its synthetic animation.
final class AudioSpectrum: ObservableObject {
    @Published private(set) var levels: [Float] = []

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var active = false

    /// Rolling amplitude history, newest at the end. Sized generously; the
    /// view samples it down to however many bars fit.
    private let historyCount = 60
    private var history = [Float](repeating: 0, count: 60)
    private var lastPublish: CFTimeInterval = 0

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { start() } else { stop() }
    }

    private func start() {
        guard #available(macOS 14.2, *) else { return }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return }
        tapID = tap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Notchbook Audio Tap",
            kAudioAggregateDeviceUIDKey as String: "com.sensubeans.notchbook.tap",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: desc.uuid.uuidString],
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else {
            destroyTap()
            return
        }
        aggregateID = agg

        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, agg, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.ingest(inInputData)
        }
        guard err == noErr, ioProcID != nil else {
            stop()
            return
        }
        AudioDeviceStart(agg, ioProcID)
    }

    private func stop() {
        guard #available(macOS 14.2, *) else { return }
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
        }
        destroyTap()
        history = [Float](repeating: 0, count: historyCount)
        DispatchQueue.main.async { self.levels = [] }
    }

    private func destroyTap() {
        guard #available(macOS 14.2, *) else { return }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Audio-thread side: RMS of the buffer → one new history sample,
    /// published to the main thread at ~25 Hz.
    private func ingest(_ bufferList: UnsafePointer<AudioBufferList>) {
        var sumSquares: Float = 0
        var count = 0
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<n {
                let s = samples[i]
                sumSquares += s * s
            }
            count += n
        }
        guard count > 0 else { return }
        let rms = (sumSquares / Float(count)).squareRoot()
        // Perceptual-ish scaling: quiet passages still visible, loud ones cap.
        let level = min(1, pow(rms * 5, 0.6))

        history.removeFirst()
        history.append(level)

        let now = CACurrentMediaTime()
        guard now - lastPublish > 0.04 else { return }
        lastPublish = now
        let snapshot = history
        DispatchQueue.main.async { self.levels = snapshot }
    }
}
