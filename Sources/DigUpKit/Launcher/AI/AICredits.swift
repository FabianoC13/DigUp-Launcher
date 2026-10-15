import Foundation

/// How much API credit is left, as a share of what you had: DeepSeek's balance against the amount you topped up, or
/// OpenRouter's credits against their usage.
public struct AICredits: Equatable, Sendable {
    /// What's left, in the account's currency.
    public var remaining: Double
    /// What 100% is: the top-up (DeepSeek, guessed or set) or the credits bought (OpenRouter).
    public var total: Double
    public var currency: String

    public init(remaining: Double, total: Double, currency: String) {
        self.remaining = remaining
        self.total = total
        self.currency = currency
    }

    /// 0…1.
    public var fraction: Double { total > 0 ? min(1, max(0, remaining / total)) : 0 }
    /// "73%".
    public var percentText: String { "\(Int((fraction * 100).rounded(.down)))%" }   // never 100% once some is spent
    /// "$1.99 of $2.00".
    public var amountText: String { "\(Self.money(remaining, currency)) of \(Self.money(total, currency))" }

    static func money(_ value: Double, _ currency: String) -> String {
        let symbol = ["USD": "$", "CNY": "¥", "EUR": "€"][currency.uppercased()]
        return symbol.map { $0 + String(format: "%.2f", value) } ?? String(format: "%.2f %@", value, currency)
    }

    // MARK: Endpoints

    /// Which providers say what's left, and where (relative to the API's base URL, or a full URL).
    public static func balanceURL(providerID: String, baseURL: String) -> URL? {
        switch providerID {
        case "deepseek":
            // The balance is beside the API, not under /v1.
            guard var components = URLComponents(string: baseURL) else { return nil }
            components.path = "/user/balance"
            return components.url
        case "openrouter":
            return AIEndpoint.url(base: baseURL, path: "credits")
        default:
            return nil
        }
    }

    // MARK: Parsing

    /// DeepSeek's `GET /user/balance`: the USD balance (else the first one) and its currency.
    public static func deepSeekBalance(_ data: Data) -> (balance: Double, currency: String)? {
        struct Info: Decodable {
            let currency: String
            let total_balance: String
        }
        struct Response: Decodable {
            let balance_infos: [Info]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let info = response.balance_infos.first(where: { $0.currency == "USD" }) ?? response.balance_infos.first,
              let balance = Double(info.total_balance) else { return nil }
        return (balance, info.currency)
    }

    /// OpenRouter's `GET /credits`: credits bought and used.
    public static func openRouter(_ data: Data) -> AICredits? {
        struct Response: Decodable {
            struct Body: Decodable {
                let total_credits: Double
                let total_usage: Double
            }
            let data: Body
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return AICredits(remaining: max(0, response.data.total_credits - response.data.total_usage),
                         total: response.data.total_credits, currency: "USD")
    }

    // MARK: DeepSeek's 100%

    /// What 100% is when only the balance is known: what you set, else the top-up it's been since (the last reference,
    /// or a round amount above the balance when it went up: a new top-up).
    public static func reference(balance: Double, previous: Double?, set: Double?) -> Double {
        if let set, set > 0 { return max(set, balance) }
        if let previous, previous >= balance { return previous }
        return roundUp(balance)
    }

    /// The round amount at or above `value` that a top-up would be: 1, 2, 5, 10, 20, 50, 100… ($1.99 → $2).
    public static func roundUp(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        var scale = 1.0
        while scale * 10 <= value { scale *= 10 }
        while scale > value { scale /= 10 }
        for step in [1.0, 2, 5, 10] where step * scale >= value - 0.000_1 {
            return step * scale
        }
        return 10 * scale
    }
}
