import AppKit
import DigUpKit
import SwiftUI

/// Root-search answers (math, conversions, currency, time zones, dates, number bases, colors, word definitions) and the
/// Calculator History command.
final class CalculatorProvider: LauncherProvider {
    let id = "calc"
    static let historyID = "calc:history"

    private var model: CalculatorModel { .shared }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        var items: [LauncherItem] = []
        if let score = query.match("Calculator History", keywords: ["Calc History", "Calculations"]) {
            items.append(Self.historyCommand(score: score))
        }
        if let term = CalcDefine.term(in: query.text) {
            let definition = await Task.detached(priority: .userInitiated) {
                CalculatorDictionary.definition(of: term)
            }.value
            guard !Task.isCancelled else { return [] }
            items.append(Self.definitionItem(term, definition: definition))
        } else if let answer = CalcEngine.answer(query.text, env: model.environment()) {
            items.append(Self.answerItem(answer, question: query.text))
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        id == Self.historyID ? Self.historyCommand(score: 1) : nil
    }

    // MARK: Items

    static func historyCommand(score: Double) -> LauncherItem {
        LauncherItem(
            id: historyID, title: "Calculator History", subtitle: "Answers you copied or pasted",
            icon: .symbol("clock.arrow.circlepath", .orange), accessory: "Command", section: .results, score: score,
            actions: [
                LauncherAction(id: "open", title: "Open Calculator History", symbol: "clock.arrow.circlepath",
                               keepsPanelOpen: true) { context in
                    context.push(CalculatorHistoryMode())
                },
            ])
    }

    static func answerItem(_ answer: CalcAnswer, question: String) -> LauncherItem {
        let detail: LauncherDetail
        let metadata: [(label: String, value: String)]
        if let color = answer.color {
            detail = .custom(AnyView(CalculatorColorDetail(color: color, answer: answer)))
            let shown: Set<String> = ["RGBA", "HSL (CSS4)", "Oklch"]
            metadata = answer.alternatives.filter { shown.contains($0.label) }.map { ($0.label, $0.value) }
        } else {
            detail = .answer(answer.result, caption: answer.caption ?? answer.expression)
            metadata = answer.alternatives.prefix(6).map { ($0.label, $0.value) }
        }
        return LauncherItem(
            id: "calc:answer", title: answer.result, subtitle: answer.expression, icon: icon(answer),
            accessory: answer.kind.label, section: .answer, score: 1,
            actions: actions(answer, question: question), detail: detail, metadata: metadata, tracksUsage: false)
    }

    static func icon(_ answer: CalcAnswer) -> LauncherIcon {
        switch answer.kind {
        case .math: .glyph("=")
        case .unit: .symbol("ruler", .teal)
        case .currency: .symbol("dollarsign.circle.fill", .green)
        case .timeZone: .symbol("globe", .blue)
        case .date: .symbol("calendar", .red)
        case .base: .symbol("number.square", .purple)
        case .color: answer.color.map { .color(Color(calcColor: $0)) } ?? .symbol("paintpalette")
        }
    }

    static func actions(_ answer: CalcAnswer, question: String) -> [LauncherAction] {
        let model = CalculatorModel.shared
        var actions = [
            LauncherAction(id: "copy", title: answer.kind == .color ? "Copy HEX" : "Copy Answer",
                           symbol: "doc.on.doc") { context in
                model.record(question: question, answer: answer.copyText, kind: answer.kind)
                context.copy(answer.copyText)
            },
            LauncherAction(id: "paste", title: "Paste Answer", symbol: "doc.on.clipboard") { context in
                model.record(question: question, answer: answer.copyText, kind: answer.kind)
                context.paste(answer.copyText)
            },
        ]
        if let color = answer.color {
            actions.append(LauncherAction(id: "copy-as", title: "Copy Color as…", symbol: "paintpalette",
                                          shortcut: LauncherShortcut("return", [.command, .shift]),
                                          keepsPanelOpen: true) { context in
                context.push(CalculatorColorMode(color: color, question: question))
            })
        }
        actions.append(LauncherAction(id: "copy-question", title: "Copy Question", symbol: "text.quote",
                                      shortcut: .copyShift) { context in
            context.copy(question)
        })
        if let number = answer.number, number != answer.copyText {
            actions.append(LauncherAction(id: "copy-number", title: "Copy Number", symbol: "number",
                                          shortcut: LauncherShortcut("c", [.command, .option])) { context in
                model.record(question: question, answer: number, kind: answer.kind)
                context.copy(number)
            })
        }
        actions.append(LauncherAction(id: "copy-both", title: "Copy Question and Answer", symbol: "equal.square") {
            context in
            context.copy("\(question) = \(answer.copyText)")
        })
        if answer.kind != .color {
            actions.append(LauncherAction(id: "replace", title: "Put Answer in Search Bar", symbol: "arrow.up.square",
                                          shortcut: LauncherShortcut("return", [.command, .shift]),
                                          keepsPanelOpen: true) { context in
                // Numbers go back bare; quantities keep their unit or currency ("€89.33") to convert further.
                let plain = answer.kind == .math || answer.kind == .base
                context.query = plain ? answer.number ?? answer.copyText : answer.copyText
            })
            for alternative in answer.alternatives.prefix(4) {
                actions.append(LauncherAction(id: "copy-\(alternative.label)", title: "Copy \(alternative.label)",
                                              symbol: "doc.on.doc") { context in
                    model.record(question: question, answer: alternative.value, kind: answer.kind)
                    context.copy(alternative.value)
                })
            }
        }
        if answer.kind == .currency {
            actions.append(LauncherAction(id: "refresh-rates", title: "Refresh Exchange Rates",
                                          symbol: "arrow.clockwise", keepsPanelOpen: true) { context in
                context.flash("Updating exchange rates…")
                await model.refreshRates()
                context.flash(model.rateSummary)
                context.refresh()
            })
        }
        actions.append(LauncherAction(id: "history", title: "Open Calculator History", symbol: "clock.arrow.circlepath",
                                      shortcut: LauncherShortcut("y", .command), keepsPanelOpen: true) { context in
            context.push(CalculatorHistoryMode())
        })
        return actions
    }

    static func definitionItem(_ term: String, definition: String?) -> LauncherItem {
        let open = LauncherAction(id: "dictionary", title: "Open in Dictionary", symbol: "character.book.closed") {
            context in
            if let url = CalculatorDictionary.url(for: term) { context.open(url) }
        }
        guard let definition else {
            return LauncherItem(
                id: "calc:define", title: "No definition for “\(term)”",
                subtitle: "Not in the dictionaries enabled in the Dictionary app", icon: .symbol("character.book.closed"),
                accessory: "Dictionary", section: .answer, score: 1, actions: [open], tracksUsage: false)
        }
        return LauncherItem(
            id: "calc:define", title: term, subtitle: CalculatorDictionary.summary(definition, term: term),
            icon: .symbol("character.book.closed", .brown), accessory: "Dictionary", section: .answer, score: 1,
            actions: [
                open,
                LauncherAction(id: "copy", title: "Copy Definition", symbol: "doc.on.doc") { context in
                    context.copy(definition)
                },
                LauncherAction(id: "copy-word", title: "Copy Word", symbol: "textformat", shortcut: .copyShift) {
                    context in
                    context.copy(term)
                },
            ],
            detail: .text(definition), tracksUsage: false)
    }
}

extension Color {
    init(calcColor color: CalcColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

/// The preview of a color answer: a swatch, its HEX and other notations.
struct CalculatorColorDetail: View {
    let color: CalcColor
    let answer: CalcAnswer

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 20)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(calcColor: color))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
                .frame(width: 120, height: 120)
            Text(answer.result)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .textSelection(.enabled)
            if let caption = answer.caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
