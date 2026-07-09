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
    let restMinutes = 5

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
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func pause() {
        isRunning = false
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
        remaining -= 1
        if remaining <= 0 { advance() }
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
        onPhaseEnd?(ended)
    }
}
