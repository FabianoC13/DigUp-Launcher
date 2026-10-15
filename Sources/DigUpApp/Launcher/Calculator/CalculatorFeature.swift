import AppKit
import DigUpKit
import SwiftUI

/// Calculator answers: math, percentages, units, currency, time zones, dates, bases, and word definitions.
enum CalculatorFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [CalculatorProvider()]
    }

    /// Reads the cached rates and history and starts keeping the exchange rates fresh.
    static func start(_ launcher: Launcher) {
        CalculatorModel.shared.start()
    }

    static var settingsTitle: String? { "Calculator" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(CalculatorSettingsView(model: .shared))
    }
}

/// Settings → Launcher → Calculator.
struct CalculatorSettingsView: View {
    @Bindable var model: CalculatorModel

    var body: some View {
        LabeledContent("Exchange rates") {
            HStack {
                Text(model.rateSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                Button("Refresh Rates") {
                    Task { await model.refreshRates() }
                }
                .disabled(model.rateStatus == .loading)
            }
        }
        Picker("Default currency", selection: $model.defaultCurrency) {
            Text("Automatic (\(Locale.current.currency?.identifier ?? "USD"))").tag(String?.none)
            ForEach(currencies, id: \.self) { code in
                Text("\(code) – \(CalcCurrency.names[code] ?? code)").tag(String?.some(code))
            }
        }
        Picker("Trigonometry", selection: $model.angleMode) {
            Text("Degrees").tag(CalcAngleMode.degrees)
            Text("Radians").tag(CalcAngleMode.radians)
        }
        .pickerStyle(.segmented)
        LabeledContent("Pixels per rem") {
            TextField("", value: $model.remBase, format: .number)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .onSubmit { if model.remBase <= 0 { model.remBase = 16 } }
        }
        Toggle("Answer colors (#ff8800, rgb(…), oklch(…))", isOn: $model.colorsEnabled)
        LabeledContent("History") {
            HStack {
                Text("\(model.history.entries.count) calculations")
                    .foregroundStyle(.secondary)
                Button("Clear…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear Calculator History?"
                    alert.informativeText = "Pinned calculations are kept."
                    alert.addButton(withTitle: "Clear").hasDestructiveAction = true
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { model.clearHistory(keepingPinned: true) }
                }
                .disabled(model.history.entries.allSatisfy(\.pinned))
            }
        }
    }

    /// The codes the current rates know, plus the chosen one if the rates don't have it.
    private var currencies: [String] {
        var codes = Set(model.rates?.rates.keys.map { $0 } ?? Array(CalcCurrency.names.keys))
        if let chosen = model.defaultCurrency { codes.insert(chosen) }
        return codes.sorted()
    }
}
