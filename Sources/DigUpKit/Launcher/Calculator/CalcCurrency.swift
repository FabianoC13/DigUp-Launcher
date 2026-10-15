import Foundation

/// Exchange rates: how many of each currency one `base` buys, on `date` (the ECB's reference rates, by way of
/// Frankfurter).
public struct CalcRates: Codable, Sendable, Equatable {
    public var base: String
    /// "2026-10-14", as published.
    public var date: String
    public var rates: [String: Double]
    /// When DigUp downloaded them.
    public var fetched: Date?

    public init(base: String, date: String, rates: [String: Double], fetched: Date? = nil) {
        self.base = base.uppercased()
        self.date = date
        var rates = rates
        rates[self.base] = 1
        self.rates = rates
        self.fetched = fetched
    }

    /// Reads Frankfurter's answer: `{"amount":1.0,"base":"EUR","date":"2026-10-14","rates":{"USD":1.1195,…}}`.
    public static func frankfurter(_ data: Data, fetched: Date = Date()) -> CalcRates? {
        struct Response: Decodable {
            let base: String
            let date: String
            let rates: [String: Double]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.rates.isEmpty,
              response.rates.values.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        return CalcRates(base: response.base, date: response.date, rates: response.rates, fetched: fetched)
    }

    public func has(_ code: String) -> Bool { rates[code.uppercased()] != nil }

    /// `amount` of `from` in `to`, nil if either is unknown.
    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let a = rates[from.uppercased()], let b = rates[to.uppercased()], a > 0 else { return nil }
        return amount / a * b
    }

    /// The publication date in the locale's medium style ("Oct 14, 2026").
    public func displayDate(locale: Locale = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return date }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

/// Currency names and symbols you can type ("$", "dollars", "€", "euro", "R$", "reais", "yen"…), resolved to ISO codes.
public enum CalcCurrency {
    /// ISO code → English name.
    public static let names: [String: String] = [
        "AUD": "Australian Dollar", "BGN": "Bulgarian Lev", "BRL": "Brazilian Real", "CAD": "Canadian Dollar",
        "CHF": "Swiss Franc", "CNY": "Chinese Yuan", "CZK": "Czech Koruna", "DKK": "Danish Krone", "EUR": "Euro",
        "GBP": "British Pound", "HKD": "Hong Kong Dollar", "HUF": "Hungarian Forint", "IDR": "Indonesian Rupiah",
        "ILS": "Israeli New Shekel", "INR": "Indian Rupee", "ISK": "Icelandic Króna", "JPY": "Japanese Yen",
        "KRW": "South Korean Won", "MXN": "Mexican Peso", "MYR": "Malaysian Ringgit", "NOK": "Norwegian Krone",
        "NZD": "New Zealand Dollar", "PHP": "Philippine Peso", "PLN": "Polish Złoty", "RON": "Romanian Leu",
        "SEK": "Swedish Krona", "SGD": "Singapore Dollar", "THB": "Thai Baht", "TRY": "Turkish Lira",
        "USD": "US Dollar", "ZAR": "South African Rand", "RUB": "Russian Ruble", "HRK": "Croatian Kuna",
    ]

    /// Lowercased alias → ISO code. ISO codes themselves (any case) work too.
    static let aliases: [String: String] = {
        let table: [String: String] = [
            "USD": "$|us$|us dollar|us dollars|dollar|dollars|bucks|buck|usd$",
            "EUR": "€|euro|euros|eur€",
            "GBP": "£|pound sterling|pounds sterling|sterling|quid|british pound|british pounds|gbp£",
            "JPY": "¥|円|yen|japanese yen",
            "CNY": "元|yuan|renminbi|rmb|cn¥|chinese yuan",
            "BRL": "r$|real|reais|brazilian real|brazilian reais",
            "MXN": "mx$|mexican peso|mexican pesos|peso|pesos",
            "INR": "₹|rupee|rupees|indian rupee|indian rupees|rs",
            "KRW": "₩|won|korean won",
            "CHF": "swiss franc|swiss francs|franc|francs",
            "CAD": "c$|ca$|canadian dollar|canadian dollars",
            "AUD": "a$|au$|aussie dollar|australian dollar|australian dollars",
            "NZD": "nz$|kiwi dollar|new zealand dollar|new zealand dollars",
            "HKD": "hk$|hong kong dollar|hong kong dollars",
            "SGD": "s$|singapore dollar|singapore dollars",
            "SEK": "swedish krona|swedish kronor|krona|kronor",
            "NOK": "norwegian krone|norwegian kroner",
            "DKK": "danish krone|danish kroner|krone|kroner",
            "ISK": "icelandic krona|icelandic kronur",
            "PLN": "zł|zloty|zlotys|zlotych|polish zloty",
            "CZK": "kč|koruna|korunas|czech koruna|czech crown|czech crowns",
            "HUF": "forint|forints|hungarian forint",
            "RON": "lei|leu|romanian leu",
            "BGN": "лв|lev|leva|bulgarian lev",
            "TRY": "₺|lira|liras|turkish lira",
            "ILS": "₪|shekel|shekels|sheqel|new shekel",
            "ZAR": "rand|rands|south african rand",
            "THB": "฿|baht|thai baht",
            "MYR": "rm|ringgit|malaysian ringgit",
            "IDR": "rp|rupiah|indonesian rupiah",
            "PHP": "₱|philippine peso|philippine pesos",
            "RUB": "₽|ruble|rubles|rouble|roubles",
        ]
        var aliases: [String: String] = [:]
        for (code, names) in table {
            for name in names.split(separator: "|") { aliases[String(name)] = code }
        }
        return aliases
    }()

    /// Ambiguous names that are also other units ("pound" is a weight): the conversion's other side decides.
    static let shared: [String: String] = ["pound": "GBP", "pounds": "GBP"]

    /// The ISO code for `text` ("usd", "$", "euros"), if `rates` know it.
    public static func code(_ text: String, rates: CalcRates?) -> String? {
        guard let rates else { return nil }
        let lower = text.lowercased()
        let code = aliases[lower] ?? shared[lower] ?? (lower.count == 3 ? lower.uppercased() : nil)
        guard let code, rates.has(code) else { return nil }
        return code
    }

    /// Every alias (and ISO code in `rates`) longest first, for scanning a quantity like "$100" or "100 usd".
    static func scanAliases(rates: CalcRates) -> [(String, String)] {
        var all = aliases.filter { rates.has($0.value) }.map { ($0.key, $0.value) }
        all += shared.filter { rates.has($0.value) }.map { ($0.key, $0.value) }
        all += rates.rates.keys.map { ($0.lowercased(), $0) }
        return all.sorted { $0.0.count > $1.0.count }
    }

    /// A unit for `code`: its factor turns an amount into the rates' base currency.
    static func unit(_ code: String, rates: CalcRates) -> CalcUnit? {
        guard let rate = rates.rates[code], rate > 0 else { return nil }
        return CalcUnit(id: code, category: .currency, factor: 1 / rate, offset: 0, symbol: code, pluralSymbol: nil,
                        name: names[code] ?? code)
    }
}
