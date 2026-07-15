import AppKit
import Combine

/// Pomodoro timer: focus sessions with short breaks, auto-advancing.
final class PomodoroModel: ObservableObject {
    enum Phase { case focus, rest }

    @Published var phase: Phase = .focus
    @Published var remaining: TimeInterval = 25 * 60
    @Published var isRunning = false
    @Published var sessions = 0
    @Published var focusDuration: TimeInterval = 25 * 60
    /// Break length in minutes (settings-driven). Updating it while idle in a
    /// rest phase refreshes the shown countdown.
    @Published var restMinutes = 5 {
        didSet {
            if !isRunning, phase == .rest { remaining = TimeInterval(restMinutes * 60) }
        }
    }
    /// When false, the timer stops at each phase boundary instead of rolling
    /// straight into the next phase.
    var autoStart = true

    var focusMinutes: Int {
        get { Int(focusDuration) / 60 }
        set {
            focusDuration = TimeInterval(newValue * 60)
            if !isRunning, phase == .focus { remaining = focusDuration }
        }
    }

    /// Manual entry: any duration in seconds becomes the focus length.
    func setCustomFocus(seconds: Int) {
        pause()
        phase = .focus
        focusDuration = TimeInterval(seconds)
        remaining = focusDuration
    }

    /// Called when a phase completes (the ENDED phase is passed).
    var onPhaseEnd: ((Phase) -> Void)?

    private var timer: Timer?
    /// Wall-clock target the countdown is derived from while running. Ticks
    /// only sample it, so run-loop stalls (NSMenu tracking) and system sleep
    /// can't silently stretch a session the way decrementing per-tick did.
    private var endDate: Date?

    var timeString: String {
        let s = Int(max(0, remaining))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var progress: Double {
        let total = phase == .focus ? focusDuration : TimeInterval(restMinutes * 60)
        return total > 0 ? 1 - remaining / total : 0
    }

    func startPause() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        endDate = Date().addingTimeInterval(max(0, remaining))
        // Scheduled in `.common` modes so the countdown keeps ticking while an
        // NSMenu (the sound-output picker) is tracking the run loop.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        isRunning = false
        // Freeze the remaining time from the wall clock before dropping the target.
        if let endDate { remaining = max(0, endDate.timeIntervalSinceNow) }
        endDate = nil
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        pause()
        phase = .focus
        remaining = focusDuration
    }

    func skip() { advance() }

    private func tick() {
        guard let endDate else { return }
        remaining = endDate.timeIntervalSinceNow
        if remaining <= 0 {
            remaining = 0
            advance()
        }
    }

    private func advance() {
        let ended = phase
        if phase == .focus {
            sessions += 1
            phase = .rest
            remaining = TimeInterval(restMinutes * 60)
        } else {
            phase = .focus
            remaining = focusDuration
        }
        if isRunning {
            if autoStart {
                // Re-anchor the target so the next phase also tracks the wall clock.
                endDate = Date().addingTimeInterval(remaining)
            } else {
                // Stop at the phase boundary; the user restarts manually.
                isRunning = false
                endDate = nil
                timer?.invalidate()
                timer = nil
            }
        }
        onPhaseEnd?(ended)
    }
}
