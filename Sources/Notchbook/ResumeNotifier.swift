import Foundation
import UserNotifications

/// Auto-resume verdicts, delivered where they can wait for you.
///
/// Every other surface this feature has is a surface you must be present for: a
/// toast that lives three seconds, a row you only see with the notch open. But
/// auto-resume exists precisely to act at the moment you are NOT at the machine
/// — that is the entire premise — so its outcome has to survive being missed.
/// Notification Center is the only channel on the Mac that does that by default.
///
/// Failures notify as loudly as successes. The observed cost of not doing so was
/// two sessions armed at the same cap, one resumed, one silently abandoned, and
/// no way to tell that apart from having armed only one.
enum ResumeNotifier {

    /// `UNUserNotificationCenter.current()` traps in an unbundled process, and
    /// the island is run straight out of `.build` during development — so every
    /// entry point checks this first rather than crashing the app that is meant
    /// to be reporting reliability.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private static var authorized = false

    /// Ask once, at launch, so the system prompt lands at a moment the user is
    /// looking at the app — not five hours later, in the same instant as the
    /// notification it would have gated.
    static func prepare() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                authorized = granted
            }
    }

    /// Post one verdict. Silent for `.armed` — arming is not news, and a
    /// notification for something that has not happened yet trains you to
    /// dismiss the ones that have.
    static func post(_ r: ResumeReport) {
        guard isAvailable, authorized, r.isSettled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(r.headline) — \(r.project)"
        // The session name is the discriminator when several share a directory,
        // which is exactly the case where "one of them didn't resume" happens.
        content.subtitle = r.name ?? ""
        content.body = r.detail
        // A failure is the one the user has to act on, so it makes a sound; the
        // rest arrive quietly and wait.
        content.sound = r.outcome == .failed ? .default : nil
        // The report id already encodes session + window + outcome, so a retry
        // that settles the way it settled before replaces rather than repeats.
        let req = UNNotificationRequest(identifier: r.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
