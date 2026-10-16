import Foundation
import Testing
@testable import DigUpKit

/// A fixed world for the calculator: Thursday, October 15, 2026, 12:00 UTC (9:00 in São Paulo), US English, and
/// made-up euro rates.
private enum World {
    static let now = Date(timeIntervalSince1970: 1_792_065_600)
    static let rates = CalcRates(base: "EUR", date: "2026-10-14",
                                 rates: ["USD": 1.1, "GBP": 0.85, "JPY": 160, "BRL": 5.5])
    static let env = CalcEnvironment(now: now, timeZone: TimeZone(identifier: "America/Sao_Paulo")!,
                                     locale: Locale(identifier: "en_US"), angleMode: .degrees, rates: rates,
                                     defaultCurrency: "BRL")

    /// The answer's title with the narrow spaces some locales put before AM/PM made plain.
    static func ask(_ question: String, env: CalcEnvironment = env) -> String? {
        CalcEngine.answer(question, env: env).map(plain)
    }

    static func answer(_ question: String) -> CalcAnswer? { CalcEngine.answer(question, env: env) }

    static func plain(_ answer: CalcAnswer) -> String { plain(answer.result) }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

@Suite struct LauncherCalculatorMathTests {
    @Test(arguments: [
        ("2+3*4", "14"), ("(2+3)*4", "20"), ("2^3^2", "512"), ("-2^2", "-4"), ("2**10", "1,024"), ("10/4", "2.5"),
        ("0.1+0.2", "0.3"), ("1/3", "0.3333333333"), ("2/3", "0.6666666667"), ("10 mod 3", "1"), ("10 % 3", "1"),
        ("5!", "120"), ("3! + 1", "7"), ("2pi", "6.2831853072"), ("2(3+4)", "14"), ("(1+2)(3+4)", "21"),
        ("2 sqrt 9", "6"), ("pi", "3.1415926536"), ("2e", "5.4365636569"), ("1,000 + 1", "1,001"),
        ("1,234,567.5 * 2", "2,469,135"), ("1e3 + 1", "1,001"), ("2.5e-3 * 1000", "2.5"), ("10K * 3", "30,000"),
        ("2M / 4", "500,000"), ("0xff + 1", "256"), ("2+2=", "4"), ("7 × 6", "42"), ("84 ÷ 2", "42"),
        ("10 − 3", "7"), ("2²", "4"), ("[1+2]*3", "9"), ("sqrt(16", "4"), ("what is 2+2?", "4"),
        ("calculate 3 * 4", "12"),
    ])
    func arithmetic(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: [
        ("sqrt 16", "4"), ("sqrt(2)", "1.4142135624"), ("√16", "4"), ("cbrt(27)", "3"), ("abs(-5)", "5"),
        ("round(3.14159, 2)", "3.14"), ("round(2.5)", "3"), ("floor(2.7)", "2"), ("ceil(2.1)", "3"), ("ln(e)", "1"),
        ("log 1000", "3"), ("log10(100)", "2"), ("log2(8)", "3"), ("log(8, 2)", "3"), ("exp(0)", "1"),
        ("max(1, 5, 3)", "5"), ("min(4, 2, 8)", "2"), ("gcd(12, 18)", "6"), ("lcm(4, 6)", "12"),
        ("sin 30", "0.5"), ("cos(90)", "0"), ("tan 45", "1"), ("sin(180)", "0"), ("sin(pi/2)", "1"),
        ("cos(pi rad)", "-1"), ("sin 90°", "1"), ("asin(1)", "90"), ("acos(0.5)", "60"), ("atan(1)", "45"),
        ("cot 45", "1"), ("sec 60", "2"), ("csc 30", "2"), ("sinh(0)", "0"), ("cosh(0)", "1"), ("tanh(0)", "0"),
        ("ncr(5, 2)", "10"), ("avg(2, 4, 6)", "4"), ("hypot(3, 4)", "5"), ("tau / 2", "3.1415926536"),
        ("phi * 2", "3.2360679775"),
    ])
    func functionsAndConstants(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test func radiansMode() {
        var env = World.env
        env.angleMode = .radians
        #expect(World.ask("sin(pi/2)", env: env) == "1")
        #expect(World.ask("cos 0", env: env) == "1")
        #expect(World.ask("sin 90 deg", env: env) == "1")
        #expect(World.ask("asin(1)", env: env) == "1.5707963268")
    }

    @Test(arguments: [
        ("5 plus 3", "8"), ("10 minus 4", "6"), ("3 times 4", "12"), ("2 x 3", "6"), ("10 divided by 4", "2.5"),
        ("12 over 4", "3"), ("2 to the power of 10", "1,024"), ("2 power 10", "1,024"), ("9 squared", "81"),
        ("2 cubed", "8"), ("square root of 625", "25"), ("cube root of 8", "2"), ("5 factorial", "120"),
        ("10 modulo 4", "2"), ("multiply 2", nil), ("3 multiplied by 5", "15"),
    ] as [(String, String?)])
    func words(_ question: String, _ expected: String?) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: [
        ("20% of 50", "10"), ("52% of 900", "468"), ("50 + 10%", "55"), ("50 - 10%", "45"), ("10% off 80", "72"),
        ("20% on 50", "60"), ("5 is what % of 20", "25%"), ("what % of 20 is 5", "25%"), ("5 as a % of 20", "25%"),
        ("5 is 25% of what", "20"), ("% change from 50 to 75", "50%"), ("percent change from 80 to 60", "-25%"),
        ("10% + 5%", "15%"), ("50 * 10%", "5"), ("200 + 20% of 50", "210"), ("15 percent of 200", "30"),
    ])
    func percentages(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: [
        "1/0", "sqrt(-1)", "log(0)", "safari", "42", "-5", "(42)", "e", "phi", "2 3", "max", "10K", "1e400",
        "171!", "((((", "2 +", "tan 90", "x", "", "   ", "hello world", "20%", "asin(2)", "5 mod 0", "(-1)!",
        "pizza", "2..3", "1,5 + 1", "what is love", "=", "0x",
    ])
    func noAnswer(_ question: String) {
        #expect(World.ask(question) == nil, "\(question)")
    }

    @Test func hugeAndTinyNumbers() {
        #expect(World.ask("1e20 * 3") == "3e+20")
        #expect(World.ask("2^64") == "1.8446744074e+19")
        #expect(World.ask("1/3e9") == "3.3333333333e-10")
        #expect(World.ask("20!") == "2.4329020082e+18")
        #expect(World.ask(String(repeating: "(", count: 80) + "1") == nil)
        #expect(World.ask(String(repeating: "(", count: 20) + "1+1") == "2")
    }

    @Test func decimalCommaLocale() {
        var env = World.env
        env.locale = Locale(identifier: "pt_BR")
        #expect(World.ask("1,5 + 1", env: env) == "2,5")
        #expect(World.ask("1.500 + 1", env: env) == "1.501")
        #expect(World.ask("1.5 * 2", env: env) == "3")
        #expect(World.ask("max(1; 2)", env: env) == "2")
        #expect(World.ask("1.234,5 * 2", env: env) == "2.469")
    }

    @Test func formatting() {
        let format = CalcFormat(locale: Locale(identifier: "en_US"))
        #expect(format.number(1_234_567.891) == "1,234,567.891")
        #expect(format.number(-0.0) == "0")
        #expect(format.number(0.1 + 0.2) == "0.3")
        #expect(format.raw(1234.5) == "1234.5")
        #expect(format.quantity(6.213711922) == "6.21371")
        #expect(format.quantity(0.0283495231) == "0.0283495")
        #expect(format.quantity(1609.344) == "1,609.34")
        #expect(CalcFormat(locale: Locale(identifier: "de_DE")).number(1234.5) == "1.234,5")
    }

    @Test func answerFields() throws {
        let answer = try #require(World.answer("20% of 50"))
        #expect(answer.kind == .math)
        #expect(answer.expression == "20% of 50")
        #expect(answer.number == "10")
        #expect(answer.copyText == "10")
        let hex = try #require(World.answer("0xff + 1"))
        #expect(hex.alternatives.contains(CalcAlternative("Hex", "0x100")))
    }
}

@Suite struct LauncherCalculatorUnitTests {
    @Test(arguments: [
        ("10 km in miles", "6.21371 mi"), ("5ft to cm", "152.4 cm"), ("5'11\" in cm", "180.34 cm"),
        ("5 ft 11 in in cm", "180.34 cm"), ("100 f to c", "37.7778°C"), ("37c in f", "98.6°F"),
        ("-40 c in f", "-40°F"), ("300K in C", "26.85°C"), ("3 cups in ml", "709.765 mL"), ("1 gb in mb", "1,000 MB"),
        ("1 GiB in MiB", "1,024 MiB"), ("8 Mb in MB", "1 MB"), ("60 mph in km/h", "96.5606 km/h"),
        ("100 km/h in mph", "62.1371 mph"), ("2 hours in minutes", "120 min"), ("500 sqft in m2", "46.4515 m²"),
        ("1 acre in hectares", "0.404686 ha"), ("2 lb 3 oz in kg", "0.992233 kg"), ("1 l in gal", "0.264172 gal"),
        ("1/2 cup in ml", "118.294 mL"), ("1 1/2 cups in ml", "354.882 mL"), ("10 km + 500 m in mi", "6.5244 mi"),
        ("1h 30m in min", "90 min"), ("100 pounds in kg", "45.3592 kg"), ("1 atm in psi", "14.6959 psi"),
        ("1 kwh in kj", "3,600 kJ"), ("90 deg in rad", "1.5708 rad"), ("3 teaspoons in ml", "14.7868 mL"),
        ("1 mile to feet", "5,280 ft"), ("1 light year in km", "9.46073e+12 km"), ("2rem in px", "32 px"),
        ("32px in rem", "2 rem"), ("2 inches in px at 72 ppi", "144 px"), ("96 px in in", "1 in"),
        ("10 KM IN MILES", "6.21371 mi"),
    ])
    func conversions(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: [
        ("10 km", "6.21371 mi"), ("37c", "98.6°F"), ("19m + 47%", "27.93 m"), ("10 km + 500 m", "6.5244 mi"),
        ("5 ft 11 in", "1.8034 m"), ("2 kg", "4.40925 lb"),
    ])
    func bareQuantities(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: [
        ("145 mins to timespan", "2 hours, 25 minutes"), ("55h in workdays", "6.875 workdays"),
        ("90000 seconds in timespan", "1 day, 1 hour"), ("180 cm in ft in", "5 ft 10.87 in"),
        ("2 kg in lb oz", "4 lb 6.55 oz"),
    ])
    func specialTargets(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: ["safari in km", "10 km in kg", "5 s", "3 days", "10 c + 5 c in f", "km in mi", "10K", "4k"])
    func noConversion(_ question: String) {
        #expect(World.ask(question) == nil, "\(question)")
    }

    @Test func feetCaption() throws {
        let answer = try #require(World.answer("180 cm in ft"))
        #expect(answer.result == "5.90551 ft")
        #expect(answer.alternatives.first?.value == "5 ft 10.87 in")
        #expect(answer.expression == "180 cm → ft")
        #expect(answer.number == "5.905511811023622" || answer.number?.hasPrefix("5.90551") == true)
    }
}

@Suite struct LauncherCalculatorCurrencyTests {
    @Test(arguments: [
        ("100 usd in eur", "€90.91"), ("$100 to €", "€90.91"), ("50 € in yen", "¥8,000"), ("100 eur", "R$550.00"),
        ("100 brl", "$20.00"), ("8 dollars/hour in gbp", "£6.18/h"), ("USD1K in eur", "€909.09"),
        ("10k usd in eur", "€9,090.91"), ("100 pounds in eur", "€117.65"), ("100 usd + 50 eur in gbp", "£119.77"),
        ("15 usd per hour in eur per day", "€327.27/day"), ("1 jpy in eur", "€0.00625"), ("100 reais in dollars", "$20.00"),
        ("90eur usd", "$99.00"), ("28usd eur", "€25.45"), ("100 usd gbp", "£77.27"), ("10 km miles", "6.21371 mi"),
    ])
    func conversions(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test func withoutRatesThereIsNoAnswer() {
        var env = World.env
        env.rates = nil
        #expect(World.ask("100 usd in eur", env: env) == nil)
        #expect(World.ask("10 km in miles", env: env) == "6.21371 mi")
    }

    @Test func captionNamesTheRate() throws {
        let answer = try #require(World.answer("100 usd in eur"))
        #expect(answer.kind == .currency)
        #expect(answer.caption?.contains("1 USD = 0.90909 EUR") == true)
        #expect(answer.caption?.contains("Oct 14, 2026") == true)
    }

    @Test func frankfurterResponse() throws {
        let json = #"{"amount":1.0,"base":"EUR","date":"2026-10-14","rates":{"USD":1.1195,"GBP":0.84385}}"#
        let rates = try #require(CalcRates.frankfurter(Data(json.utf8)))
        #expect(rates.base == "EUR")
        #expect(rates.date == "2026-10-14")
        #expect(rates.rates["EUR"] == 1)
        #expect(rates.convert(1.1195, from: "USD", to: "EUR") == 1)
        #expect(CalcRates.frankfurter(Data("{}".utf8)) == nil)
        #expect(CalcRates.frankfurter(Data(#"{"base":"EUR","date":"x","rates":{"USD":0}}"#.utf8)) == nil)
    }
}

@Suite struct LauncherCalculatorTimeZoneTests {
    @Test(arguments: [
        ("time in tokyo", "9:00 PM · +12h"), ("tokyo time", "9:00 PM · +12h"), ("Time in Tokyo?", "9:00 PM · +12h"),
        ("what time is it in london", "1:00 PM · +4h"), ("5pm london in new york", "12:00 PM · -5h"),
        ("5pm ldn in sf", "9:00 AM · -8h"), ("3pm EST to CET", "9:00 PM · +6h"),
        ("noon in sydney", "Tomorrow 2:00 AM · +14h"), ("now in PST", "4:00 AM · -5h"),
        ("14:30 in tokyo", "Tomorrow 2:30 AM · +12h"), ("london 9am in tokyo", "5:00 PM · +8h"),
        ("time in utc+5:30", "5:30 PM · +8h 30m"), ("time in são paulo", "9:00 AM"), ("time in JFK", "8:00 AM · -1h"),
        ("time in 4 hours", "1:00 PM"), ("time in 4 hours in san francisco", "9:00 AM · -4h"),
        ("time in brisbane + 4 hours", "Tomorrow 2:00 AM · +13h"), ("3:45pm + 5", "8:45 PM"),
        ("9am + 90 min", "10:30 AM"), ("11pm + 2 hours", "Tomorrow 1:00 AM"),
        ("time diff paris", "5 hours ahead"), ("diff los angeles", "4 hours behind"),
        ("time difference between tokyo and london", "8 hours behind"), ("time in kolkata", "5:30 PM · +8h 30m"),
    ])
    func answers(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: ["time in atlantis", "time", "5 in tokyo", "tokyo", "25:00 in tokyo", "time in"])
    func noAnswer(_ question: String) {
        #expect(World.ask(question) == nil, "\(question)")
    }

    @Test func copyAndCaption() throws {
        let answer = try #require(World.answer("noon in sydney"))
        #expect(answer.kind == .timeZone)
        #expect(World.plain(answer.copyText) == "2:00 AM")
        #expect(World.plain(answer.caption ?? "").contains("Friday, October 16, 2026"))
        #expect(World.plain(answer.caption ?? "").contains("Sydney (GMT+11)"))
        #expect(World.plain(answer.expression) == "12:00 PM → Sydney")
    }

    @Test func places() {
        #expect(CalcPlaces.place("NYC")?.zone.identifier == "America/New_York")
        #expect(CalcPlaces.place("Zürich")?.zone.identifier == "Europe/Zurich")
        #expect(CalcPlaces.place("zurich")?.name == "Zurich")
        #expect(CalcPlaces.place("lhr")?.name == "London")
        #expect(CalcPlaces.place("Ulaanbaatar")?.zone.identifier == "Asia/Ulaanbaatar")
        #expect(CalcPlaces.place("Kathmandu")?.zone.secondsFromGMT(for: World.now) == 20700)
        #expect(CalcPlaces.place("EST")?.zone.secondsFromGMT(for: World.now) == -18000)
        #expect(CalcPlaces.place("gmt-3")?.name == "UTC-3")
        #expect(CalcPlaces.place("Yakutsk") != nil)
        #expect(CalcPlaces.place("pizza") == nil)
    }

    @Test func clocks() {
        #expect(CalcClock.parse("5pm") == CalcClock(hour: 17, minute: 0))
        #expect(CalcClock.parse("5:30 a.m.") == CalcClock(hour: 5, minute: 30))
        #expect(CalcClock.parse("12am") == CalcClock(hour: 0, minute: 0))
        #expect(CalcClock.parse("12pm") == CalcClock(hour: 12, minute: 0))
        #expect(CalcClock.parse("17:45") == CalcClock(hour: 17, minute: 45))
        #expect(CalcClock.parse("midnight") == CalcClock(hour: 0, minute: 0))
        #expect(CalcClock.parse("5") == nil)
        #expect(CalcClock.parse("13pm") == nil)
        #expect(CalcClock.parse("10:75") == nil)
    }
}

@Suite struct LauncherCalculatorDateTests {
    @Test(arguments: [
        ("days until christmas", "71 days"), ("days until dec 25", "71 days"), ("how many days until 25 december", "71 days"),
        ("days till xmas", "71 days"), ("until christmas", "71 days"), ("weeks until christmas", "10.14 weeks"),
        ("hours until christmas", "1,695 hours"), ("days until easter", "164 days"), ("days left in the year", "77 days"),
        ("days since jan 1 2020", "2,479 days"), ("days since 2020-01-01", "2,479 days"),
        ("days until jan 1 2020", "2,479 days ago"), ("days between march 1 2026 and june 30 2026", "121 days"),
        ("workdays until friday", "1 workday"), ("months until christmas", "2 months, 10 days"),
    ])
    func spans(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: [
        ("today + 3 weeks", "Thursday, November 5, 2026"), ("monday in 2 weeks", "Monday, November 2, 2026"),
        ("date in 30 days", "Saturday, November 14, 2026"), ("in 2 days", "Saturday, October 17, 2026"),
        ("35 days ago", "Thursday, September 10, 2026"), ("3 months from today", "Friday, January 15, 2027"),
        ("2 weeks after christmas", "Friday, January 8, 2027"), ("August 5 + 5", "Monday, August 10, 2026"),
        ("christmas - 10 days", "Tuesday, December 15, 2026"), ("tomorrow + 1 week", "Friday, October 23, 2026"),
        ("next friday + 1 day", "Saturday, October 17, 2026"), ("today + 10 workdays", "Thursday, October 29, 2026"),
        ("now + 3 hours", "Thursday, October 15, 2026 at 12:00 PM"),
    ])
    func movedDates(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: [
        ("unix 1700000000", "Tuesday, November 14, 2023 at 7:13 PM"), ("1700000000 unix", "Tuesday, November 14, 2023 at 7:13 PM"),
        ("unix 1700000000000", "Tuesday, November 14, 2023 at 7:13 PM"), ("now in unix", "1792065600"),
        ("christmas in unix", "1798167600"), ("week number", "Week 42"), ("week number of 2027-01-01", "Week 53"),
        ("what day is 2027-03-14", "Sunday"), ("what day is christmas", "Friday"), ("day of week 14.03.2027", "Sunday"),
        ("what day is 3/14/2027", "Sunday"), ("workhours in 2023", "2,080 hours"), ("workdays in 2023", "260 workdays"),
        ("work hours in february 2026", "160 hours"), ("2024-03-15T14:30:00Z", "Friday, March 15, 2024 at 11:30 AM"),
        ("2024-03-15T14:30:00+02:00", "Friday, March 15, 2024 at 9:30 AM"),
    ])
    func otherAnswers(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: ["dec 25", "tomorrow", "christmas", "monday", "2027-03-14", "today", "now", "14.03.2027",
                      "3/14/2027", "days until someday", "what day is soon", "unix"])
    func loneDatesHaveNoAnswer(_ question: String) {
        #expect(World.ask(question) == nil, "\(question)")
    }

    @Test func phrases() throws {
        let phrase = CalcDatePhrase(env: World.env)
        let calendar = World.env.calendar
        func ymd(_ text: String, _ direction: CalcDatePhrase.Direction = .next) -> [Int]? {
            phrase.parse(text, direction: direction).map {
                let c = calendar.dateComponents([.year, .month, .day], from: $0.date)
                return [c.year!, c.month!, c.day!]
            }
        }
        #expect(ymd("jan 1") == [2027, 1, 1])
        #expect(ymd("jan 1", .past) == [2026, 1, 1])
        #expect(ymd("25th of december") == [2026, 12, 25])
        #expect(ymd("next thursday") == [2026, 10, 22])
        #expect(ymd("thursday") == [2026, 10, 15])
        #expect(ymd("last thursday") == [2026, 10, 8])
        #expect(ymd("thanksgiving") == [2026, 11, 26])
        #expect(ymd("easter") == [2027, 3, 28])
        #expect(ymd("end of quarter") == [2026, 12, 31])
        #expect(ymd("end of month") == [2026, 10, 31])
        #expect(ymd("feb 30 2026") == nil)
        #expect(ymd("march 2027") == [2027, 3, 1])
    }
}

@Suite struct LauncherCalculatorBaseTests {
    @Test(arguments: [
        ("0xff", "255"), ("0XFF", "255"), ("255 in hex", "0xFF"), ("0b1010 in dec", "10"), ("255 to binary", "0b11111111"),
        ("0o17", "15"), ("hex ff", "255"), ("ff hex", "255"), ("binary 1010", "10"), ("255 in base 36", "73"),
        ("255 in octal", "0o377"), ("0xff + 1 in hex", "0x100"), ("-10 in hex", "-0xA"), ("2024 in roman", "MMXXIV"),
        ("mmxxiv in decimal", "2,024"), ("roman xiv", "14"), ("roman 1999", "MCMXCIX"), ("0x1f to binary", "0b11111"),
    ])
    func answers(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: ["42 in decimal", "oct 17", "ff in decimal", "iiii in decimal", "5000 in roman", "2.5 in hex",
                      "0xfg", "roman"])
    func noAnswer(_ question: String) {
        #expect(World.ask(question) == nil, "\(question)")
    }

    @Test func roman() {
        #expect(CalcBases.roman(3999) == "MMMCMXCIX")
        #expect(CalcBases.roman(0) == nil)
        #expect(CalcBases.romanValue("MCMXC") == 1990)
        #expect(CalcBases.romanValue("VX") == nil)
        #expect(CalcBases.romanValue("mix") == 1009)
    }

    @Test func alternatives() throws {
        let answer = try #require(World.answer("255 in hex"))
        #expect(answer.alternatives.map(\.value) == ["0b11111111", "0o377", "255"])
        #expect(answer.number == "255")
    }
}

@Suite struct LauncherCalculatorColorTests {
    @Test(arguments: [
        ("#ff8800", "#FF8800"), ("#f80", "#FF8800"), ("#FF880080", "#FF880080"), ("rgb(255, 0, 0)", "#FF0000"),
        ("rgba(255 0 0 / 50%)", "#FF000080"), ("rgb(100%, 50%, 0%)", "#FF8000"), ("hsl(120, 100%, 50%)", "#00FF00"),
        ("hsl(240deg 100% 50%)", "#0000FF"), ("hwb(0 0% 0%)", "#FF0000"), ("hwb(0 100% 0%)", "#FFFFFF"),
        ("oklch(0.628 0.2577 29.23)", "#FF0000"), ("oklab(1 0 0)", "#FFFFFF"), ("lab(54.29 80.8 69.89)", "#FF0000"),
        ("lch(100 0 0)", "#FFFFFF"),
    ])
    func parsing(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }

    @Test(arguments: ["#ggg", "#12345", "rgb(1,2)", "hsl(abc, 1, 2)", "rgb(1 2 3 4 5)", "(1"])
    func noColor(_ question: String) {
        #expect(CalcColor.parse(question) == nil, "\(question)")
    }

    @Test func spaces() throws {
        let red = CalcColor(red: 1, green: 0, blue: 0)
        let ok = red.oklabComponents
        #expect(abs(ok.l - 0.62796) < 0.001 && abs(ok.a - 0.22486) < 0.001 && abs(ok.b - 0.12585) < 0.001)
        let lab = red.labComponents
        #expect(abs(lab.l - 54.29) < 0.05 && abs(lab.a - 80.8) < 0.1 && abs(lab.b - 69.9) < 0.1)
        let white = CalcColor(red: 1, green: 1, blue: 1).labComponents
        #expect(abs(white.l - 100) < 0.01 && abs(white.a) < 0.01 && abs(white.b) < 0.01)
        let (h, s, l) = CalcColor(red: 1, green: 0.5333, blue: 0).hslComponents
        #expect(abs(h - 32) < 0.1 && abs(s - 1) < 0.001 && abs(l - 0.5) < 0.001)
    }

    @Test func formats() throws {
        let color = try #require(CalcColor.parse("#FF8800"))
        let formats = Dictionary(uniqueKeysWithValues: color.formats.map { ($0.label, $0.value) })
        #expect(color.formats.count == 16)
        #expect(formats["RGBA"] == "rgba(255, 136, 0, 1)")
        #expect(formats["HEX with Alpha"] == "#FF8800FF")
        #expect(formats["HSL (CSS4)"] == "hsl(32 100% 50% / 100%)")
        #expect(formats["NSColor"] == "NSColor(srgbRed: 1, green: 0.533, blue: 0, alpha: 1)")
        #expect(World.ask("#ff8800", env: { var env = World.env; env.colorsEnabled = false; return env }()) == nil)
    }
}

@Suite struct LauncherCalculatorDefineAndHistoryTests {
    @Test(arguments: [
        ("define serendipity", "serendipity"), ("def cat", "cat"), ("serendipity meaning", "serendipity"),
        ("meaning of life", "life"), ("definition of ephemeral", "ephemeral"), ("what does ephemeral mean", "ephemeral"),
        ("Define \"Ennui\"", "ennui"), ("define ice cream", "ice cream"),
    ])
    func defineTerms(_ question: String, _ expected: String) {
        #expect(CalcDefine.term(in: question) == expected)
    }

    @Test(arguments: ["define", "safari", "definitely", "define 42", "what does", "meaning"])
    func notDefinitions(_ question: String) {
        #expect(CalcDefine.term(in: question) == nil)
    }

    @Test func historyKeepsNewestFirstWithoutDuplicates() {
        var history = CalcHistory()
        history.add(question: "2+2", answer: "4", kind: .math)
        history.add(question: "10 km in mi", answer: "6.21371 mi", kind: .unit)
        history.add(question: "2+2", answer: "4", kind: .math)
        #expect(history.entries.map(\.question) == ["2+2", "10 km in mi"])
        history.add(question: "  ", answer: "x", kind: .math)
        #expect(history.entries.count == 2)
    }

    @Test func historyLimitSparesPinned() throws {
        var history = CalcHistory()
        history.add(question: "pinned", answer: "1", kind: .math)
        let pinned = try #require(history.entries.first)
        history.setPinned(pinned.id, true)
        for n in 0..<(CalcHistory.limit + 20) {
            history.add(question: "\(n)+1", answer: "\(n + 1)", kind: .math)
        }
        #expect(history.entries.count == CalcHistory.limit + 1)
        #expect(history.sorted.first?.question == "pinned")
        #expect(history.entries.contains { $0.question == "\(CalcHistory.limit + 19)+1" })
        #expect(!history.entries.contains { $0.question == "0+1" })
        history.clear(keepingPinned: true)
        #expect(history.entries.map(\.question) == ["pinned"])
        history.clear(keepingPinned: false)
        #expect(history.entries.isEmpty)
    }

    @Test func historySearchAndCoding() throws {
        var history = CalcHistory()
        history.add(question: "100 usd in eur", answer: "€90.91", kind: .currency)
        history.add(question: "20% of 50", answer: "10", kind: .math)
        #expect(history.search("usd").map(\.answer) == ["€90.91"])
        #expect(history.search("").count == 2)
        let first = try #require(history.entries.first)
        history.remove(first.id)
        #expect(history.entries.count == 1)
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(CalcHistory.self, from: data) == history)
    }
}

@Suite struct LauncherCalculatorWorkTimeTests {
    @Test(arguments: [
        ("workdays this month", "22 workdays"), ("workdays in this month", "22 workdays"),
        ("business days in march 2027", "23 workdays"), ("work hours next year", "2,088 hours"),
    ])
    func periods(_ question: String, _ expected: String) {
        #expect(World.ask(question) == expected, "\(question)")
    }
}
