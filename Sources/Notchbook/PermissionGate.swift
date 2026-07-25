import AppKit
import SwiftUI

/// The states a TCC-gated feature can actually be in.
///
/// The bug this exists to kill: collapsing all of these into one Bool, so a
/// denial renders identically to "we never asked" — and the only button on
/// screen is a request that the system answers instantly and silently once a
/// denial is on record. Every gated feature in the app had that shape.
enum PermissionState: Equatable {
    /// Never asked. A request here still shows the system prompt.
    case notDetermined
    /// The user said no. Requesting again does nothing; only Settings helps.
    case denied
    /// Blocked by MDM/parental controls — the user cannot grant it themselves.
    case restricted
    /// Granted, but not at the level the feature needs (e.g. EventKit write-only).
    case insufficient(String)
    /// Nothing to grant — no camera, no supported OS.
    case unavailable(String)
    case granted
}

/// The System Settings panes this app can send someone to.
enum PrivacyPane: String {
    case calendars = "Privacy_Calendars"
    case camera = "Privacy_Camera"
    case microphone = "Privacy_Microphone"
    case audioCapture = "Privacy_AudioCapture"
    case automation = "Privacy_Automation"
    case accessibility = "Privacy_Accessibility"

    func open() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A tab's empty state when a permission — not a lack of data — is why it is
/// empty. Always offers the action that can actually resolve the state:
/// a request when one would still prompt, a Settings deep-link when it would
/// not, and a retry for transient unavailability.
struct PermissionGate: View {
    let icon: String
    /// What the feature is, in the user's words: "Calendar", "the mirror".
    let feature: String
    let state: PermissionState
    let pane: PrivacyPane
    /// Fires when the state is `.notDetermined` and a request would still prompt.
    var request: (() -> Void)?
    /// Re-evaluates the underlying source (camera list, authorization status).
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text(headline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if case .notDetermined = state, let request {
                    capsule("Allow Access", filled: true, action: request)
                } else if needsSettings {
                    capsule("Open Settings", filled: true) { pane.open() }
                }
                if let retry, state != .granted {
                    capsule("Try Again", filled: false, action: retry)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var needsSettings: Bool {
        switch state {
        case .denied, .restricted, .insufficient: return true
        default: return false
        }
    }

    private var headline: String {
        switch state {
        case .notDetermined:      return "Connect your \(feature)"
        case .denied:             return "\(feature) access is turned off"
        case .restricted:         return "\(feature) access is restricted"
        case .insufficient:       return "\(feature) needs full access"
        case .unavailable:        return "\(feature) is unavailable"
        case .granted:            return feature
        }
    }

    private var detail: String? {
        switch state {
        case .notDetermined:
            return nil
        case .denied:
            return "Turn it back on in Privacy & Security, then come back."
        case .restricted:
            return "Your organization's settings control this."
        case .insufficient(let what), .unavailable(let what):
            return what
        case .granted:
            return nil
        }
    }

    private func capsule(_ title: String, filled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(filled ? AnyShapeStyle(.orange)
                                                  : AnyShapeStyle(.white.opacity(0.12))))
                .foregroundStyle(filled ? AnyShapeStyle(.black)
                                        : AnyShapeStyle(.white.opacity(0.8)))
        }
        .buttonStyle(.plain)
    }
}
