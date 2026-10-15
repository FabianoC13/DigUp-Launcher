import AppKit
import DigUpKit
import SwiftUI

/// Calculator History: the answers you copied or pasted, searchable. Pinned entries come first and show a live answer
/// (today's rate, the current countdown) instead of the saved one.
final class CalculatorHistoryMode: LauncherMode {
    let title = "Calculator History"
    let placeholder = "Search calculations…"
    let icon = LauncherIcon.symbol("clock.arrow.circlepath", .orange)

    private var model: CalculatorModel { .shared }

    var statusHint: String? {
        model.history.entries.isEmpty ? "Copy or paste a calculator answer to keep it here" : nil
    }

    var keysHint: String? {
        model.history.entries.isEmpty ? nil : "↩ Copy   ⌘↩ Paste   ⇧⌘P Pin   ⌃X Delete   ⌘K Actions"
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let env = model.environment()
        return model.history.search(query.text).map { entry in
            let live = entry.pinned ? CalcEngine.answer(entry.question, env: env) : nil
            return item(entry, live: live, env: env)
        }
    }

    private func item(_ entry: CalcHistoryEntry, live: CalcAnswer?, env: CalcEnvironment) -> LauncherItem {
        let answer = live?.copyText ?? entry.answer
        let when = Self.relative(entry.date)
        let model = model
        var actions = [
            LauncherAction(id: "copy", title: "Copy Answer", symbol: "doc.on.doc") { context in
                model.record(question: entry.question, answer: answer, kind: entry.kind)
                context.copy(answer)
            },
            LauncherAction(id: "paste", title: "Paste Answer", symbol: "doc.on.clipboard") { context in
                model.record(question: entry.question, answer: answer, kind: entry.kind)
                context.paste(answer)
            },
            LauncherAction(id: "copy-question", title: "Copy Question", symbol: "text.quote", shortcut: .copyShift) {
                context in
                context.copy(entry.question)
            },
            LauncherAction(id: "ask-again", title: "Put Question in Search Bar", symbol: "arrow.up.square",
                           shortcut: LauncherShortcut("return", [.command, .shift]), keepsPanelOpen: true) { context in
                context.popToRoot()
                context.query = entry.question
            },
            LauncherAction(id: "pin", title: entry.pinned ? "Unpin" : "Pin", symbol: entry.pinned ? "pin.slash" : "pin",
                           shortcut: LauncherShortcut("p", [.command, .shift]), keepsPanelOpen: true) { context in
                model.setPinned(entry.id, !entry.pinned)
                context.refresh()
            },
            LauncherAction(id: "delete", title: "Delete Entry", symbol: "trash", shortcut: .deleteItem,
                           style: .destructive, keepsPanelOpen: true) { context in
                model.removeHistory(entry.id)
                context.refresh()
            },
        ]
        actions.append(LauncherAction(id: "clear", title: "Clear History…", symbol: "trash.slash",
                                      shortcut: LauncherShortcut("x", [.control, .shift]), style: .destructive,
                                      keepsPanelOpen: true) { context in
            let pinned = model.history.entries.contains(where: \.pinned)
            guard context.confirm("Clear Calculator History?",
                                  message: pinned ? "Pinned calculations are kept." : "This can't be undone.",
                                  button: "Clear", destructive: true) else { return }
            model.clearHistory(keepingPinned: true)
            context.refresh()
        })
        var caption = "\(entry.question)\n\(entry.kind.label) · \(when)"
        if let live, live.copyText != entry.answer { caption += " · was \(entry.answer)" }
        return LauncherItem(
            id: "calc-history:\(entry.id.uuidString)", title: answer, subtitle: entry.question,
            icon: entry.pinned ? .symbol("pin.fill", .orange) : Self.icon(entry.kind), accessory: when,
            section: entry.pinned ? .named("Pinned", order: 0) : .named("Recent", order: 1), score: 1,
            actions: actions, detail: .answer(answer, caption: caption), tracksUsage: false)
    }

    static func icon(_ kind: CalcAnswerKind) -> LauncherIcon {
        switch kind {
        case .math: .glyph("=")
        case .unit: .symbol("ruler", .teal)
        case .currency: .symbol("dollarsign.circle.fill", .green)
        case .timeZone: .symbol("globe", .blue)
        case .date: .symbol("calendar", .red)
        case .base: .symbol("number.square", .purple)
        case .color: .symbol("paintpalette", .pink)
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Copy Color as…: the color in every notation, each one copyable or pasteable.
final class CalculatorColorMode: LauncherMode {
    let title = "Copy Color as…"
    let placeholder = "Search formats…"
    let icon: LauncherIcon
    private let color: CalcColor
    private let question: String

    init(color: CalcColor, question: String) {
        self.color = color
        self.question = question
        icon = .color(Color(calcColor: color))
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let model = CalculatorModel.shared
        let question = question
        return color.formats.compactMap { format -> LauncherItem? in
            var score = 1.0
            if !query.isEmpty {
                guard let match = query.match(format.label, keywords: [format.value]) else { return nil }
                score = match
            }
            return LauncherItem(
                id: "calc-color:\(format.label)", title: format.value, subtitle: format.label, icon: icon,
                accessory: format.label, section: .named("Formats", order: 0), score: score,
                actions: [
                    LauncherAction(id: "copy", title: "Copy \(format.label)", symbol: "doc.on.doc") { context in
                        model.record(question: question, answer: format.value, kind: .color)
                        context.copy(format.value)
                    },
                    LauncherAction(id: "paste", title: "Paste \(format.label)", symbol: "doc.on.clipboard") { context in
                        model.record(question: question, answer: format.value, kind: .color)
                        context.paste(format.value)
                    },
                ],
                detail: .custom(AnyView(CalculatorColorDetail(
                    color: color, answer: CalcAnswer(kind: .color, result: format.value, expression: question,
                                                     caption: format.label)))),
                tracksUsage: false)
        }
    }
}
