import AppKit
import DigUpKit
import SwiftUI

/// Rows and actions for events: join the call, open in Calendar, copy the details or the link.
enum ScheduleItems {
    static func eventItem(_ event: ScheduleEvent, now: Date) -> LauncherItem {
        let time = ScheduleText.timeRange(start: event.start, end: event.end, allDay: event.allDay)
        let subtitle = [time, event.calendarTitle, event.location].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
        let day = ScheduleDay.offset(of: max(event.start, Calendar.current.startOfDay(for: now)), from: now)
        let heading = ScheduleDay.title(for: max(event.start, Calendar.current.startOfDay(for: now)), now: now)
        let countdown = event.allDay ? nil : ScheduleDay.countdown(start: event.start, end: event.end, now: now)
        let ended = !event.allDay && event.end <= now
        return LauncherItem(id: "cal:event:" + event.id, title: event.title, subtitle: subtitle, icon: icon(event),
                            accessory: countdown ?? (ended ? "Ended" : nil), section: .named(heading, order: day),
                            actions: actions(event), metadata: metadata(event, time: time), tracksUsage: false)
    }

    /// "Join Standup" in the root search, while the call is on or about to start.
    static func joinItem(_ event: ScheduleEvent, now: Date) -> LauncherItem {
        let countdown = ScheduleDay.countdown(start: event.start, end: event.end, now: now)
        let service = event.meeting?.service.name ?? "Meeting"
        let time = ScheduleText.timeRange(start: event.start, end: event.end, allDay: false)
        return LauncherItem(id: "cal:join:" + event.id, title: "Join \(event.title)", subtitle: "\(service) · \(time)",
                            icon: .symbol("video.fill", event.color.color), accessory: countdown ?? "Now",
                            actions: actions(event), metadata: metadata(event, time: time), tracksUsage: false)
    }

    /// A row that explains something (no access yet, nothing on), with what to do about it.
    static func message(_ title: String, subtitle: String?, symbol: String, action: LauncherAction?) -> LauncherItem {
        LauncherItem(id: "cal:message", title: title, subtitle: subtitle, icon: .symbol(symbol, .secondary),
                     actions: action.map { [$0] } ?? [], tracksUsage: false)
    }

    private static func icon(_ event: ScheduleEvent) -> LauncherIcon {
        event.meeting != nil ? .symbol("video.fill", event.color.color) : .color(event.color.color)
    }

    private static func metadata(_ event: ScheduleEvent, time: String) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("When", event.start.formatted(date: .abbreviated, time: .omitted) + ", " + time),
            ("Calendar", event.calendarTitle),
        ]
        if let location = event.location { rows.append(("Location", location)) }
        if let meeting = event.meeting { rows.append((meeting.service.name, meeting.url.absoluteString)) }
        if let organizer = event.organizer { rows.append(("Organizer", organizer)) }
        if !event.attendees.isEmpty {
            let shown = event.attendees.prefix(8).joined(separator: ", ")
            rows.append(("Attendees", event.attendees.count > 8 ? shown + " +\(event.attendees.count - 8)" : shown))
        }
        if let url = event.url, url != event.meeting?.url { rows.append(("URL", url.absoluteString)) }
        if let notes = event.notes {
            rows.append(("Notes", notes.count > 400 ? String(notes.prefix(400)) + "…" : notes))
        }
        return rows
    }

    private static func actions(_ event: ScheduleEvent) -> [LauncherAction] {
        var actions: [LauncherAction] = []
        if let meeting = event.meeting {
            actions.append(LauncherAction(id: "join", title: "Join Meeting", symbol: "video") { _ in
                join(meeting)
            })
        }
        actions.append(LauncherAction(id: "calendar", title: "Open in Calendar", symbol: "calendar") { _ in
            await openInCalendar(event)
        })
        actions.append(LauncherAction(id: "copy-details", title: "Copy Event Details", symbol: "doc.on.doc",
                                      shortcut: .copyShift, keepsPanelOpen: true) { context in
            context.copy(ScheduleText.details(title: event.title, start: event.start, end: event.end,
                                              allDay: event.allDay, location: event.location,
                                              link: event.meeting?.url, url: event.url, attendees: event.attendees,
                                              notes: event.notes))
        })
        if let meeting = event.meeting {
            actions.append(LauncherAction(id: "copy-link", title: "Copy Meeting Link", symbol: "link",
                                          shortcut: LauncherShortcut("c", [.command, .option]),
                                          keepsPanelOpen: true) { context in
                context.copy(meeting.url.absoluteString)
            })
        }
        if let url = event.url, url != event.meeting?.url {
            actions.append(LauncherAction(id: "open-url", title: "Open URL", symbol: "safari") { context in
                context.open(url)
            })
        }
        return actions
    }

    /// Opens the call in its app (Zoom, Teams) when that's installed, else in the browser.
    static func join(_ link: MeetingLink) {
        let workspace = NSWorkspace.shared
        if let native = link.nativeURL,
           link.service.appBundleIDs.contains(where: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }),
           workspace.open(native) {
            return
        }
        workspace.open(link.url)
    }

    /// Shows the event in Calendar: its own page for a one-off event (`ical://ekevent/…`), else the day it's on
    /// (through AppleScript; without Automation permission Calendar just opens).
    static func openInCalendar(_ event: ScheduleEvent) async {
        let workspace = NSWorkspace.shared
        if !event.recurring, let path = event.eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(path)?method=show&options=more"), workspace.open(url) {
            return
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: event.start)
        let script = """
        on run argv
            set theDate to current date
            set day of theDate to 1
            set year of theDate to (item 1 of argv) as integer
            set month of theDate to (item 2 of argv) as integer
            set day of theDate to (item 3 of argv) as integer
            set hours of theDate to (item 4 of argv) as integer
            tell application id "com.apple.iCal"
                activate
                switch view to day view
                view calendar at theDate
            end tell
        end run
        """
        let arguments = [parts.year, parts.month, parts.day, parts.hour].map { String($0 ?? 0) }
        let reply = await ProductivityAppleScript.run(script, arguments: arguments, timeout: 10)
        guard reply.value == nil else { return }
        if reply.errorNumber == ProductivityAppleScript.notAllowed {
            ProductivityHUD.show("Allow DigUp to control Calendar in Privacy & Security → Automation to open the day",
                                 symbol: "lock", seconds: 4)
        }
        if let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            _ = try? await workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Settings → Launcher → My Schedule: calendar access and which calendars to show.
struct ScheduleSettingsView: View {
    @Bindable var store: ScheduleStore

    var body: some View {
        LabeledContent("Calendar access") {
            HStack {
                switch store.access {
                case .fullAccess:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .notDetermined:
                    Text("Not asked yet").foregroundStyle(.secondary)
                    Button("Allow Access…") { Task { await store.requestAccess() } }
                default:
                    Text("Off").foregroundStyle(.secondary)
                    Button("Open Privacy Settings") { ScheduleStore.openPrivacySettings() }
                }
            }
        }
        .onAppear { store.reloadIfStale(after: 0) }
        if store.hasAccess {
            LabeledContent("Calendars") {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(store.calendars) { calendar in
                        Toggle(isOn: Binding(get: { store.isShown(calendar.id) },
                                             set: { store.setShown(calendar.id, $0) })) {
                            HStack(spacing: 6) {
                                Circle().fill(calendar.color.color).frame(width: 8, height: 8)
                                Text(calendar.title)
                                Text(calendar.account).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        Text("My Schedule lists today's and the next 7 days' events. A call (Zoom, Meet, Teams, Webex, FaceTime, "
             + "Whereby, Around…) that starts within 15 minutes shows up as “Join …” when you type “join”.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
