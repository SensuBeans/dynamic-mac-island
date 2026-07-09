import EventKit
import Combine

/// Upcoming events from the native macOS calendar via EventKit.
final class CalendarModel: ObservableObject {
    @Published var events: [EKEvent] = []
    @Published var status = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()

    var hasAccess: Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    func connect() {
        let done: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                self?.status = EKEventStore.authorizationStatus(for: .event)
                if granted { self?.load() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in done(granted) }
        }
    }

    func load() {
        guard hasAccess else { return }
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = Array(store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(10))
    }
}
