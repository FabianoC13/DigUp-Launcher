import AppKit
import DigUpKit
import Observation
import SwiftUI

/// What's left of the API credit, for the bar in Quick AI and Settings: read from the provider (DeepSeek's balance,
/// OpenRouter's credits) when Quick AI opens and after answers, at most every 30 s.
@Observable
final class QuickAICredits {
    static let shared = QuickAICredits()

    enum State: Equatable {
        case unknown
        /// The provider doesn't say (OpenAI, Anthropic…).
        case unsupported
        case loaded(AICredits, Date)
        case failed(String)
    }

    private(set) var state = State.unknown
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults = AppSettings.defaults

    /// The amount you topped up, when you set it (Settings); nil to follow the guess.
    func budget(for providerID: String) -> Double? {
        let value = defaults.double(forKey: "quickAI.creditBudget.\(providerID)")
        return value > 0 ? value : nil
    }

    func setBudget(_ value: Double?, for providerID: String) {
        defaults.set(value ?? 0, forKey: "quickAI.creditBudget.\(providerID)")
        refresh(force: true)
    }

    /// Reads the balance if it isn't known yet and waits for it, up to `seconds` (a search for "credits" shows the number,
    /// not "Checking…").
    func loaded(within seconds: Double = 2) async {
        if case .unknown = state { refresh() }
        guard let task else { return }
        let timeout = Task { try? await Task.sleep(for: .seconds(seconds)) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { await timeout.value }
            await group.next()
            group.cancelAll()
        }
        timeout.cancel()
    }

    /// Reads the balance again unless it was read in the last 30 s (`force`: now).
    func refresh(force: Bool = false) {
        let preferences = QuickAIPreferences.shared
        let preset = preferences.provider
        guard let url = AICredits.balanceURL(providerID: preset.id, baseURL: preferences.baseURL(for: preset)) else {
            state = .unsupported
            return
        }
        guard force || Date().timeIntervalSince(lastFetch) > 30, task == nil else { return }
        lastFetch = Date()
        task = Task { [weak self] in
            let result = await Self.fetch(url, preset: preset)
            guard let self else { return }
            task = nil
            switch result {
            case .success(let data):
                state = credits(from: data, providerID: preset.id).map { .loaded($0, Date()) }
                    ?? .failed("The balance couldn't be read")
            case .failure(let message):
                state = .failed(message)
            }
            if case .loaded(let value, _) = state {
                log("quick ai: credits \(value.percentText) left (\(value.amountText))")
            } else if case .failed(let message) = state {
                log("quick ai: credits: \(message)")
            }
        }
    }

    private func credits(from data: Data, providerID: String) -> AICredits? {
        if providerID == "openrouter" { return AICredits.openRouter(data) }
        guard let (balance, currency) = AICredits.deepSeekBalance(data) else { return nil }
        let key = "quickAI.creditReference.\(providerID)"
        let previous = defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
        let total = AICredits.reference(balance: balance, previous: previous, set: budget(for: providerID))
        defaults.set(total, forKey: key)
        return AICredits(remaining: balance, total: total, currency: currency)
    }

    private enum Fetched { case success(Data), failure(String) }

    private static func fetch(_ url: URL, preset: AIProviderPreset) async -> Fetched {
        let key: String? = await Task.detached {
            if case .success(let key) = QuickAIKeys.shared.load(preset.id) { return key }
            return nil
        }.value
        guard let key else { return .failure("No API key saved") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (field, value) in preset.requestHeaders(key: key) { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return .failure(status == 401 ? "The API key was refused" : "The provider answered \(status)")
            }
            return .success(data)
        } catch {
            return .failure("Offline")
        }
    }
}

/// "Credits ▓▓▓▓▓░ 99% · $1.99 of $2.00": what's left, as a bar that turns amber below 30% and red below 10%.
struct QuickAICreditsBar: View {
    var credits = QuickAICredits.shared
    var compact = false

    var body: some View {
        switch credits.state {
        case .loaded(let value, _):
            HStack(spacing: 8) {
                Text("Credits").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(color(value.fraction))
                            .frame(width: max(4, geometry.size.width * value.fraction))
                    }
                }
                .frame(width: compact ? 90 : 160, height: 6)
                Text(value.percentText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                if !compact {
                    Text(value.amountText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .help("\(value.amountText) left")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("API credits \(value.percentText) left, \(value.amountText)")
        case .failed(let message):
            Text("Credits: \(message)").font(.system(size: 11)).foregroundStyle(.secondary)
        case .unknown:
            Text("Credits: checking…").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .unsupported:
            EmptyView()
        }
    }

    private func color(_ fraction: Double) -> Color {
        fraction < 0.1 ? .red : fraction < 0.3 ? .orange : Brand.amber
    }
}
