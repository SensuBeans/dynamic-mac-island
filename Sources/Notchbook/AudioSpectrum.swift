import AudioToolbox
import Combine
import Foundation
import QuartzCore
import os

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

    /// Rolling amplitude history as a fixed-size ring buffer (newest just
    /// before `writeIndex`). Sized generously; the view samples it down to
    /// however many bars fit. A ring buffer means the RT audio thread never
    /// reallocates or shifts the array.
    private let historyCount = 60
    private var history = [Float](repeating: 0, count: 60)
    private var writeIndex = 0
    /// Loudness accumulates across IO callbacks and lands in the history as
    /// one sample per this interval — the wave scrolls calmly instead of
    /// jittering at callback rate (60 × 60 ms ≈ a 3.6 s window on screen).
    private let sampleInterval: CFTimeInterval = 0.06
    private var accumSumSquares: Float = 0
    private var accumCount = 0
    private var lastAppend: CFTimeInterval = 0
    /// Serializes the mutable ring/accumulator state, which the CoreAudio
    /// real-time IO thread (`ingest`) and the main thread (`stop`) both touch.
    /// Without this, `stop()` reassigning state under an in-flight callback
    /// could corrupt the heap.
    private var stateLock = os_unfair_lock_s()

    func setActive(_ on: Bool) {
        guard on != active else { return }
        // Don't mark active until start() has FULLY succeeded (it sets the flag
        // itself on the last line). Setting it up-front meant any early-return
        // in start() — tap-create or aggregate-create failing — left active ==
        // true doing nothing, and the `on != active` guard then no-op'd every
        // later setActive(true), so the live waveform could never retry and
        // stayed on the synthetic fallback until the tab hid.
        if on { start() } else { active = false; stop() }
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
        guard AudioDeviceStart(agg, ioProcID) == noErr else {
            stop()
            return
        }
        // Every step succeeded — only now is the tap truly live. Marking active
        // HERE (not before start()) guarantees every failure path above leaves
        // active == false, so a later setActive(true) retries cleanly.
        active = true
    }

    /// Destroys the process tap and the "Notchbook Audio Tap" aggregate device.
    /// Called from both `stop()` and `deinit` so nothing is left registered if
    /// the object is dropped while active.
    private func teardownAudio() {
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
    }

    deinit {
        teardownAudio()
    }

    private func stop() {
        guard #available(macOS 14.2, *) else { return }
        teardownAudio()
        // Reset state under the lock so a still-in-flight `ingest` callback on
        // the RT thread can't race with the reset. The array is zeroed in place
        // (never reassigned) so its buffer address stays valid.
        os_unfair_lock_lock(&stateLock)
        for i in 0..<historyCount { history[i] = 0 }
        writeIndex = 0
        accumSumSquares = 0
        accumCount = 0
        lastAppend = 0
        os_unfair_lock_unlock(&stateLock)
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

        os_unfair_lock_lock(&stateLock)
        accumSumSquares += sumSquares
        accumCount += count

        let now = CACurrentMediaTime()
        guard now - lastAppend >= sampleInterval else {
            os_unfair_lock_unlock(&stateLock)
            return
        }
        lastAppend = now
        let rms = (accumSumSquares / Float(accumCount)).squareRoot()
        accumSumSquares = 0
        accumCount = 0
        // Perceptual-ish scaling: quiet passages still visible, loud ones cap.
        let level = min(1, pow(rms * 5, 0.6))

        // Ring write, then an ordered oldest→newest snapshot for the view.
        history[writeIndex] = level
        writeIndex = (writeIndex + 1) % historyCount
        var snapshot = [Float](repeating: 0, count: historyCount)
        for i in 0..<historyCount {
            snapshot[i] = history[(writeIndex + i) % historyCount]
        }
        os_unfair_lock_unlock(&stateLock)
        DispatchQueue.main.async { self.levels = snapshot }
    }
}
