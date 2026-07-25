import AppKit
import Combine

/// Single owner of the collapsed media ear's visibility.
///
/// Ground-up redesign (Jul 18) after a day of stacked patches from two
/// parallel sessions: the ear used to animate off a boolean DERIVED from
/// volatile inputs (`nowPlaying`, `earHidden`), with debounces bolted onto the
/// view layer one symptom at a time. Track starts/changes churn now-playing
/// through nil and reset artwork mid-flight, so the morph kept getting
/// restarted — the user's "it activates and animates twice".
///
/// The contract, in one place:
/// - REVEAL fires only from a settled, complete bundle: media continuously
///   present for `stability`, AND artwork loaded — or an `artBudget` from
///   settledness lapsed (some sources have no art). One reveal; the album and
///   the sound wave activate together.
/// - HIDE fires only after media has been continuously absent for `absence`.
/// - Flickers inside those windows cancel the pending transition and the
///   current state simply continues. Nothing restarts an in-flight morph.
/// - Content churn while visible (track switch with the ear up) emits nothing.
///
/// `earVisible` is the ONLY signal the view animates on; the view maps its
/// edges 1:1 onto the LiquidEar morph and owns no timing of its own.
final class EarRevealModel: ObservableObject {
    @Published private(set) var earVisible = false

    /// Media must be continuously present this long before a reveal arms.
    private let stability: TimeInterval = 0.35
    /// Media must be continuously absent this long before the ear hides.
    private let absence: TimeInterval = 0.55
    /// How long past settledness the reveal will wait for artwork.
    private let artBudget: TimeInterval = 1.8

    private var present = false
    private var artReady = false
    private var artDeadline: Double = 0
    private var pending: DispatchWorkItem?
    private var cancellable: AnyCancellable?

    func bind(to media: MediaWatcher) {
        cancellable = media.$nowPlaying
            .combineLatest(media.$earHidden, media.$artwork)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] np, hidden, art in
                self?.reduce(present: np != nil && !hidden, artReady: art != nil)
            }
    }

    private func reduce(present: Bool, artReady: Bool) {
        self.artReady = artReady
        guard present != self.present else { return }   // content churn: no edge
        self.present = present
        pending?.cancel()
        if present {
            // Became present: arm a reveal once the state has proven stable.
            // The tick then waits (0.2s polls) for artwork within the budget.
            artDeadline = ProcessInfo.processInfo.systemUptime + stability + artBudget
            scheduleRevealTick(after: stability)
        } else if earVisible {
            // Became absent while shown: hide only if it STAYS absent.
            scheduleHide(after: absence)
        }
        // Became absent while arming: the cancel above already disarmed it.
    }

    private func scheduleRevealTick(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.present else { return }
            if !self.artReady,
               ProcessInfo.processInfo.systemUptime < self.artDeadline {
                self.scheduleRevealTick(after: 0.2)
                return
            }
            if !self.earVisible { self.earVisible = true }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.present else { return }
            if self.earVisible { self.earVisible = false }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
