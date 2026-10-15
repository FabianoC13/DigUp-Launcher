import AppKit
import DigUpKit
import EventKit
import Observation
import SwiftUI

/// One event as the launcher shows it, copied out of EventKit (off the main thread).
nonisolated struct ScheduleEvent: Identifiable, Equatable, Sendable {
    /// The event's identifier and its start: occurrences of a repeating event share the identifier.
    let id: String
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let recurring: Bool
    let calendarTitle: String
    let color: ScheduleColor
    let location: String?
    let notes: String?
    let url: URL?
    let organizer: String?
    let attendees: [String]
    let meeting: MeetingLink?
}

/// A calendar's color as sRGB components (Sendable, unlike NSColor).
nonisolated struct ScheduleColor: Sendable, Equatable {
    var red = 0.5, green = 0.5, blue = 0.5

    init(_ color: NSColor?) {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return }
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// A calendar you can show or hide in My Schedule.
struct ScheduleCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    let account: String
    let color: ScheduleColor
}

/// My Schedule's events: today's and the next 7 days', from the calendars you chose, read again when the calendar
/// database changes. Calendar access is asked for the first time My Schedule opens.
@Observable
final class ScheduleStore {
    static let shared = ScheduleStore()

    struct Settings: Codable, Equatable {
        /// Calendar identifiers left out of My Schedule.
        var hiddenCalendars: Set<String> = []
    }

    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    private(set) var events: [ScheduleEvent] = []
    private(set) var calendars: [ScheduleCalendar] = []
    private(set) var settings = Settings()
    private(set) var loaded = false
    weak var launcher: Launcher?

    @ObservationIgnored private var eventStore = EKEventStore()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var lastAccessCheck = Date.distantPast
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var requesting = false

    private static var settingsFile: URL { ProductivityFiles.folder("Schedule").appendingPathComponent("settings.json") }
    nonisolated static let days = 7

    var hasAccess: Bool { access == .fullAccess }

    func start() {
        settings = ProductivityFiles.load(Settings.self, from: Self.settingsFile) ?? Settings()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        if hasAccess { reload() }
    }

    /// Asks macOS for full calendar access (its dialog shows once; afterwards only System Settings can change it).
    func requestAccess() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        nonisolated(unsafe) let store = eventStore
        do {
            let granted = try await store.requestFullAccessToEvents()
            log("schedule: calendar access \(granted ? "granted" : "denied")")
        } catch {
            log("schedule: calendar access request failed (\(error.localizedDescription))")
        }
        access = EKEventStore.authorizationStatus(for: .event)
        if hasAccess {
            eventStore = EKEventStore()   // a store made before access was granted can stay empty
            reload()
        }
        if let context = launcher?.panel?.context, context.isPanelVisible { context.refresh() }
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    /// Reads the events again when the last read is older than `seconds` (times move on: "In 5 min", "Now").
    func reloadIfStale(after seconds: TimeInterval = 60) {
        // Asking for the authorization status is a round trip to macOS's privacy service (~40 ms): at most every 30 s,
        // never on every keystroke. Reading the events waits for the keystroke's results to show.
        if Date().timeIntervalSince(lastAccessCheck) > 30 {
            lastAccessCheck = Date()
            Task { [weak self] in
                let status = await Task.detached { EKEventStore.authorizationStatus(for: .event) }.value
                guard let self, status != access else { return }
                access = status
                if hasAccess { reload() }
            }
        }
        if hasAccess, Date().timeIntervalSince(lastLoad) > seconds {
            lastLoad = Date()
            Task { [weak self] in self?.reload() }
        }
    }

    func reload() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            events = []
            calendars = []
            return
        }
        lastLoad = Date()
        calendars = eventStore.calendars(for: .event).map {
            ScheduleCalendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Other",
                             color: ScheduleColor($0.color))
        }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        nonisolated(unsafe) let store = eventStore
        let hidden = settings.hiddenCalendars
        loadTask?.cancel()
        loadTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.fetch(store, hidden: hidden, now: Date())
            }.value
            guard !Task.isCancelled else { return }
            let changed = found != events || !loaded
            events = found
            loaded = true
            // A list on screen (My Schedule, "Join …") shows the new events.
            if changed, let context = launcher?.panel?.context, context.isPanelVisible { context.refresh() }
        }
    }

    nonisolated private static func fetch(_ store: EKEventStore, hidden: Set<String>, now: Date) -> [ScheduleEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: days + 1, to: start) else { return [] }
        let shown = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }
            .map { event in
                let eventID = event.eventIdentifier ?? event.calendarItemIdentifier
                let attendees = (event.attendees ?? []).compactMap { participant -> String? in
                    if let name = participant.name, !name.isEmpty { return name }
                    let address = participant.url.absoluteString
                    return address.hasPrefix("mailto:") ? String(address.dropFirst(7)) : nil
                }
                return ScheduleEvent(
                    id: "\(eventID)|\(Int(event.startDate.timeIntervalSince1970))", eventID: eventID,
                    title: (event.title as String?)?.nilIfBlank ?? "Untitled Event",
                    start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                    recurring: event.hasRecurrenceRules, calendarTitle: event.calendar?.title ?? "",
                    color: ScheduleColor(event.calendar?.color), location: event.location?.nilIfBlank,
                    notes: event.notes?.nilIfBlank, url: event.url, organizer: event.organizer?.name,
                    attendees: attendees,
                    meeting: MeetingLinks.find(url: event.url?.absoluteString, location: event.location,
                                               notes: event.notes))
            }
    }

    func event(_ id: String) -> ScheduleEvent? {
        events.first { $0.id == id }
    }

    func isShown(_ calendarID: String) -> Bool { !settings.hiddenCalendars.contains(calendarID) }

    func setShown(_ calendarID: String, _ shown: Bool) {
        if shown { settings.hiddenCalendars.remove(calendarID) } else { settings.hiddenCalendars.insert(calendarID) }
        ProductivityFiles.save(settings, to: Self.settingsFile)
        reload()
    }
}

nonisolated private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
