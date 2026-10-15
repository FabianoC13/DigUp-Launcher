import AppKit
import DigUpKit
import Foundation

/// The calculator's state: its settings, the exchange rates (downloaded daily from the ECB by way of Frankfurter, cached
/// so currency works offline) and Calculator History. Everything lives in Launcher.directory/Calculator/.
@Observable
final class CalculatorModel {
    static let shared = CalculatorModel()

    enum RateStatus: Equatable {
        case idle, loading
        case failed(String)
    }

    private(set) var rates: CalcRates?
    private(set) var rateStatus = RateStatus.idle
    private(set) var history = CalcHistory()

    /// Degrees or radians when a number doesn't say.
    var angleMode: CalcAngleMode {
        didSet { UserDefaults.standard.set(angleMode.rawValue, forKey: Keys.angleMode) }
    }

    /// The ISO code "100 eur" converts to; nil follows the system's region.
    var defaultCurrency: String? {
        didSet { UserDefaults.standard.set(defaultCurrency, forKey: Keys.currency) }
    }

    /// Pixels per rem and em.
    var remBase: Double {
        didSet { UserDefaults.standard.set(remBase, forKey: Keys.remBase) }
    }

    /// Whether colors typed in root search ("#ff8800", "rgb(…)") get an answer.
    var colorsEnabled: Bool {
        didSet { UserDefaults.standard.set(colorsEnabled, forKey: Keys.colors) }
    }

    private enum Keys {
        static let angleMode = "calculatorAngleMode"
        static let currency = "calculatorCurrency"
        static let remBase = "calculatorRemBase"
        static let colors = "calculatorColors"
    }

    private static let sources = [
        URL(string: "https://api.frankfurter.dev/v1/latest?base=EUR")!,
        URL(string: "https://api.frankfurter.app/latest?base=EUR")!,
    ]

    /// Rates older than this are downloaded again (the ECB publishes once each working day).
    private static let rateLifetime: TimeInterval = 12 * 3600

    private var started = false

    private init() {
        let defaults = UserDefaults.standard
        angleMode = defaults.string(forKey: Keys.angleMode).flatMap(CalcAngleMode.init(rawValue:)) ?? .degrees
        defaultCurrency = defaults.string(forKey: Keys.currency)
        let base = defaults.double(forKey: Keys.remBase)
        remBase = base > 0 ? base : 16
        colorsEnabled = defaults.object(forKey: Keys.colors) as? Bool ?? true
    }

    private static var directory: URL { Launcher.directory.appendingPathComponent("Calculator", isDirectory: true) }
    private static var ratesFile: URL { directory.appendingPathComponent("rates.json") }
    private static var historyFile: URL { directory.appendingPathComponent("history.json") }

    /// The currency answers convert to when none is named.
    var effectiveCurrency: String {
        defaultCurrency ?? Locale.current.currency?.identifier ?? "USD"
    }

    /// What the engine needs, as of now.
    func environment() -> CalcEnvironment {
        CalcEnvironment(now: Date(), timeZone: .current, locale: .autoupdatingCurrent, angleMode: angleMode,
                        rates: rates, defaultCurrency: effectiveCurrency, remBase: remBase,
                        colorsEnabled: colorsEnabled)
    }

    // MARK: Starting

    /// Reads the cached rates and history, then keeps the rates fresh: now if they're stale, and every few hours.
    func start() {
        guard !started else { return }
        started = true
        let ratesFile = Self.ratesFile, historyFile = Self.historyFile
        Task {
            let (rates, history) = await Task.detached(priority: .utility) {
                let rates = (try? Data(contentsOf: ratesFile)).flatMap {
                    try? JSONDecoder().decode(CalcRates.self, from: $0)
                }
                let history = (try? Data(contentsOf: historyFile)).flatMap {
                    try? JSONDecoder().decode(CalcHistory.self, from: $0)
                }
                return (rates, history)
            }.value
            if self.rates == nil { self.rates = rates }
            if let history, self.history.entries.isEmpty { self.history = history }
            if let rates { log("calculator: cached rates of \(rates.date) (\(rates.rates.count) currencies)") }
            while !Task.isCancelled {
                await refreshRatesIfStale()
                try? await Task.sleep(for: .seconds(3 * 3600))
            }
        }
    }

    private func refreshRatesIfStale() async {
        let fetched = rates?.fetched ?? .distantPast
        guard Date().timeIntervalSince(fetched) > Self.rateLifetime else { return }
        await refreshRates()
    }

    // MARK: Rates

    /// Downloads today's rates (trying the second address if the first fails) and caches them.
    func refreshRates() async {
        guard rateStatus != .loading else { return }
        rateStatus = .loading
        var lastError = "No answer from the rates service"
        for url in Self.sources {
            do {
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    lastError = "The rates service answered \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    continue
                }
                guard let fresh = CalcRates.frankfurter(data) else {
                    lastError = "The rates service sent something unexpected"
                    continue
                }
                rates = fresh
                rateStatus = .idle
                log("calculator: rates of \(fresh.date) from \(url.host() ?? "?") (\(fresh.rates.count) currencies)")
                let file = Self.ratesFile
                await Task.detached(priority: .utility) {
                    Self.write(fresh, to: file)
                }.value
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        rateStatus = .failed(lastError)
        log("calculator: couldn't refresh rates: \(lastError)")
    }

    /// "Rates of Oct 14, 2026", "Updating…", "Couldn't update: …".
    var rateSummary: String {
        switch rateStatus {
        case .loading: return "Updating…"
        case .failed(let message):
            let cached = rates.map { " Using the rates of \($0.displayDate())." } ?? ""
            return "Couldn't update: \(message).\(cached)"
        case .idle:
            guard let rates else { return "Not downloaded yet" }
            return "ECB rates of \(rates.displayDate()), \(rates.rates.count) currencies"
        }
    }

    // MARK: History

    /// Saves a copied or pasted answer to Calculator History.
    func record(question: String, answer: String, kind: CalcAnswerKind) {
        history.add(question: question, answer: answer, kind: kind)
        saveHistory()
    }

    func removeHistory(_ id: UUID) {
        history.remove(id)
        saveHistory()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        history.setPinned(id, pinned)
        saveHistory()
    }

    func clearHistory(keepingPinned: Bool) {
        history.clear(keepingPinned: keepingPinned)
        saveHistory()
    }

    private func saveHistory() {
        let snapshot = history
        let file = Self.historyFile
        Task.detached(priority: .utility) {
            Self.write(snapshot, to: file)
        }
    }

    nonisolated private static func write(_ value: some Encodable, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        } catch {
            log("calculator: couldn't save \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
