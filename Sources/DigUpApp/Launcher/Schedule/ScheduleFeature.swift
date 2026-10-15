import AppKit
import DigUpKit
import SwiftUI

/// My Schedule: today's and upcoming events, join meetings.
enum ScheduleFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [ScheduleProvider()]
    }

    static func start(_ launcher: Launcher) {
        ScheduleStore.shared.launcher = launcher
        ScheduleStore.shared.start()
    }

    static var settingsTitle: String? { "My Schedule" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(ScheduleSettingsView(store: .shared))
    }
}

/// Root search: My Schedule, Copy Availability, and "Join <meeting>" for a call that starts within 15 minutes or is on.
final class ScheduleProvider: LauncherProvider {
    let id = "cal"

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        let store = ScheduleStore.shared
        store.reloadIfStale()
        var items: [LauncherItem] = []
        if let score = query.match("My Schedule", keywords: ["calendar", "events", "agenda", "today", "meetings"]) {
            var item = Self.scheduleCommand()
            item.score = score
            items.append(item)
        }
        if store.hasAccess,
           let score = query.match("Copy Availability", keywords: ["free time", "calendar", "when am i free"]) {
            var item = Self.availabilityCommand()
            item.score = score
            items.append(item)
        }
        let now = Date()
        for event in store.events where event.meeting != nil && !event.allDay
            && ScheduleDay.isJoinable(start: event.start, end: event.end, now: now) {
            let byTitle = query.match("Join " + event.title, keywords: ["join", "meeting", "call", event.title])
            guard let score = byTitle else { continue }
            var item = ScheduleItems.joinItem(event, now: now)
            item.score = max(score, 0.9)
            items.append(item)
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        switch id {
        case "cal:schedule": return Self.scheduleCommand()
        case "cal:availability": return Self.availabilityCommand()
        default:
            let store = ScheduleStore.shared
            for prefix in ["cal:join:", "cal:event:"] where id.hasPrefix(prefix) {
                guard let event = store.event(String(id.dropFirst(prefix.count))) else { return nil }
                return prefix == "cal:join:" ? ScheduleItems.joinItem(event, now: Date())
                                             : ScheduleItems.eventItem(event, now: Date())
            }
            return nil
        }
    }

    static func scheduleCommand() -> LauncherItem {
        let store = ScheduleStore.shared
        let now = Date()
        var subtitle = "Today's and the next 7 days' events"
        if !store.hasAccess {
            subtitle = "Needs access to your calendars"
        } else if let next = store.events.first(where: { !$0.allDay && $0.end > now }) {
            let when = ScheduleDay.countdown(start: next.start, end: next.end, now: now, within: 12 * 3600)
                ?? ScheduleText.timeRange(start: next.start, end: next.end, allDay: false)
            subtitle = "Next: \(next.title) · \(when)"
        }
        return LauncherItem(id: "cal:schedule", title: "My Schedule", subtitle: subtitle,
                            icon: .symbol("calendar", .red), accessory: "Command", actions: [
                                LauncherAction(id: "open", title: "Open My Schedule", symbol: "calendar",
                                               keepsPanelOpen: true) { context in
                                    context.push(ScheduleMode())
                                },
                            ])
    }

    static func availabilityCommand() -> LauncherItem {
        LauncherItem(id: "cal:availability", title: "Copy Availability",
                     subtitle: "Your free time in working hours (9–18) on the next 3 working days",
                     icon: .symbol("calendar.badge.clock", .red), accessory: "Command", actions: [
                         LauncherAction(id: "copy", title: "Copy Availability", symbol: "doc.on.doc",
                                        keepsPanelOpen: true) { context in
                             let busy = ScheduleStore.shared.events.filter { !$0.allDay }
                                 .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
                             let slots = ScheduleAvailability.freeSlots(busy: busy, from: Date(), days: 3,
                                                                        workStartHour: 9, workEndHour: 18)
                             context.copy(ScheduleText.availability(slots), flash: "Copied your free time")
                         },
                     ])
    }
}

/// My Schedule: the events by day ("Today", "Tomorrow", weekdays), searchable by title, place or calendar.
final class ScheduleMode: LauncherMode {
    let title = "My Schedule"
    let placeholder = "Search events…"
    let icon = LauncherIcon.symbol("calendar", .red)
    var keysHint: String? { "↩ Join or Open  ⌘↩ Open in Calendar" }

    init() {
        let store = ScheduleStore.shared
        if store.access == .notDetermined {
            Task { await store.requestAccess() }
        } else {
            store.reload()
        }
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let store = ScheduleStore.shared
        switch store.access {
        case .fullAccess:
            break
        case .notDetermined:
            return [ScheduleItems.message("Allow DigUp to read your calendars", subtitle: "macOS asks once",
                                          symbol: "lock", action: LauncherAction(
                                              id: "allow", title: "Allow Access", symbol: "lock.open",
                                              keepsPanelOpen: true) { _ in
                                                  await store.requestAccess()
                                              })]
        default:
            return [ScheduleItems.message("Calendar access is off",
                                          subtitle: "Turn on DigUp in Privacy & Security → Calendars (Full Access)",
                                          symbol: "lock", action: LauncherAction(
                                              id: "settings", title: "Open Privacy Settings", symbol: "gearshape") { _ in
                                                  ScheduleStore.openPrivacySettings()
                                              })]
        }
        guard store.loaded else {
            return [ScheduleItems.message("Reading your calendars…", subtitle: nil, symbol: "hourglass", action: nil)]
        }
        let now = Date()
        var items: [LauncherItem] = []
        for (index, event) in store.events.enumerated() {
            if !query.isEmpty {
                let keywords = [event.location, event.calendarTitle, event.organizer].compactMap { $0 }
                guard query.match(event.title, keywords: keywords) != nil else { continue }
            }
            var item = ScheduleItems.eventItem(event, now: now)
            item.score = 1 - Double(index) / Double(store.events.count + 1)   // in time order within a day
            items.append(item)
        }
        if items.isEmpty {
            let text = query.isEmpty ? "No events in the next \(ScheduleStore.days) days" : "No matching events"
            let calendars = store.calendars.filter { store.isShown($0.id) }.count
            return [ScheduleItems.message(text, subtitle: "From \(calendars == 1 ? "1 calendar" : "\(calendars) calendars")",
                                          symbol: "calendar", action: nil)]
        }
        return items
    }
}
