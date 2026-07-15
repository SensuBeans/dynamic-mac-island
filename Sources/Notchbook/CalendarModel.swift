import EventKit
import Combine

/// Upcoming events from the native macOS calendar via EventKit.
final class CalendarModel: ObservableObject {
    @Published var events: [EKEvent] = []
    /// Events in the currently-loaded month grid, keyed by `startOfDay` — drives
    /// the mini-month dots and the selected day's list.
    @Published var monthEvents: [Date: [EKEvent]] = [:]
    @Published var status = EKEventStore.authorizationStatus(for: .event)

    // Settings-driven (set from AppDelegate). Changing any of these should be
    // followed by a `load()` / `loadMonth` refresh.
    var lookAheadDays = 7
    var includeAllDay = true
    var excludedCalendarIDs: Set<String> = []

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    /// Calendars to query — `nil` (= all) when nothing is excluded, so a newly
    /// added calendar defaults to shown.
    private func activeCalendars() -> [EKCalendar]? {
        guard !excludedCalendarIDs.isEmpty else { return nil }
        return store.calendars(for: .event)
            .filter { !excludedCalendarIDs.contains($0.calendarIdentifier) }
    }

    /// Every event calendar (for the settings include/exclude list).
    func allCalendars() -> [EKCalendar] {
        hasAccess ? store.calendars(for: .event) : []
    }
    /// First-of-month of the grid last loaded via `loadMonth`, so store changes
    /// can refresh it too.
    private var currentMonthAnchor: Date?

    init() {
        // The calendar can change under us (add/edit/delete, sync); reload so
        // whichever view is live never goes stale.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.load()
            if let anchor = self.currentMonthAnchor { self.loadMonth(containing: anchor) }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

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
        let days = max(1, lookAheadDays)
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return }
        let calendars = activeCalendars()
        let allDay = includeAllDay
        // `events(matching:)` blocks across all calendars — fetch off the main
        // thread, publish on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let predicate = self.store.predicateForEvents(withStart: start, end: end,
                                                          calendars: calendars)
            let fetched = Array(self.store.events(matching: predicate)
                .filter { allDay || !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(10))
            DispatchQueue.main.async { self.events = fetched }
        }
    }

    /// Load every event in the visible month grid (week-aligned, so leading and
    /// trailing days show their dots too), keyed by `startOfDay`. No 10-event
    /// cap — this only drives dots plus one selected day's list.
    func loadMonth(containing date: Date) {
        guard hasAccess else { return }
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))
        else { return }
        currentMonthAnchor = monthStart
        // Back up to the start of the week containing the 1st, respecting the
        // system's first weekday; a fixed 6-week (42-day) grid always covers
        // the whole month.
        let weekday = cal.component(.weekday, from: monthStart)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -lead, to: monthStart),
              let gridEnd = cal.date(byAdding: .day, value: 42, to: gridStart) else { return }
        let calendars = activeCalendars()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let predicate = self.store.predicateForEvents(withStart: gridStart, end: gridEnd,
                                                          calendars: calendars)
            var byDay: [Date: [EKEvent]] = [:]
            for e in self.store.events(matching: predicate) {
                guard let s = e.startDate else { continue }
                byDay[cal.startOfDay(for: s), default: []].append(e)
            }
            for (k, v) in byDay {
                byDay[k] = v.sorted { a, b in
                    if a.isAllDay != b.isAllDay { return a.isAllDay && !b.isAllDay }
                    return (a.startDate ?? .distantPast) < (b.startDate ?? .distantPast)
                }
            }
            DispatchQueue.main.async { self.monthEvents = byDay }
        }
    }
}
