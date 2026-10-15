import Foundation

/// What a unit measures; only units of one category convert into each other (plus pixels ↔ lengths at a density).
public enum CalcUnitCategory: String, Sendable {
    case length, area, volume, mass, temperature, duration, speed, data, pressure, energy, power, angle, frequency
    case screen, currency
}

/// A unit: how many of the category's base unit one of it is (meters, m², liters, kilograms, kelvin, seconds, m/s,
/// bytes, pascals, joules, watts, degrees, hertz, pixels), plus an offset for temperatures.
public struct CalcUnit: Sendable, Hashable {
    public let id: String
    public let category: CalcUnitCategory
    public let factor: Double
    public let offset: Double
    /// Written after numbers ("km", "°F", "fl oz").
    public let symbol: String
    /// Used instead of `symbol` for anything but exactly 1, for units written as words ("cups").
    public let pluralSymbol: String?
    /// The plural name, for captions ("kilometers").
    public let name: String

    public func symbol(for value: Double) -> String {
        value == 1 ? symbol : (pluralSymbol ?? symbol)
    }
}

/// Every unit and the names you can type for it.
enum CalcUnitTable {
    /// (id, category, factor, symbol, plural symbol, name, aliases). Aliases are matched ignoring case, except the
    /// ones written "=Mb" (case-sensitive, so "Mb" is a megabit while "MB" and "mb" are megabytes).
    private typealias Row = (String, CalcUnitCategory, Double, String, String?, String, String)

    private static let rows: [Row] = [
        // Length (meters)
        ("nm", .length, 1e-9, "nm", nil, "nanometers", "nm|nanometer|nanometers|nanometre|nanometres"),
        ("um", .length, 1e-6, "µm", nil, "micrometers",
         "µm|μm|um|micron|microns|micrometer|micrometers|micrometre|micrometres"),
        ("mm", .length, 1e-3, "mm", nil, "millimeters", "mm|millimeter|millimeters|millimetre|millimetres"),
        ("cm", .length, 0.01, "cm", nil, "centimeters", "cm|centimeter|centimeters|centimetre|centimetres"),
        ("dm", .length, 0.1, "dm", nil, "decimeters", "dm|decimeter|decimeters|decimetre|decimetres"),
        ("m", .length, 1, "m", nil, "meters", "m|meter|meters|metre|metres"),
        ("km", .length, 1000, "km", nil, "kilometers", "km|kms|kilometer|kilometers|kilometre|kilometres|klicks"),
        ("in", .length, 0.0254, "in", nil, "inches", "in|inch|inches|\"|″|''"),
        ("ft", .length, 0.3048, "ft", nil, "feet", "ft|foot|feet|'|′"),
        ("yd", .length, 0.9144, "yd", nil, "yards", "yd|yds|yard|yards"),
        ("mi", .length, 1609.344, "mi", nil, "miles", "mi|mile|miles"),
        ("nmi", .length, 1852, "nmi", nil, "nautical miles", "nmi|nautical mile|nautical miles"),
        ("au", .length, 1.495978707e11, "au", nil, "astronomical units", "au|astronomical unit|astronomical units"),
        ("ly", .length, 9.4607304725808e15, "ly", nil, "light-years",
         "ly|light year|light years|light-year|light-years|lightyear|lightyears"),
        ("pt", .length, 0.0254 / 72, "pt", nil, "points", "pt|pts|point|points"),
        // Area (square meters)
        ("mm2", .area, 1e-6, "mm²", nil, "square millimeters",
         "mm2|mm²|sq mm|square millimeter|square millimeters|square millimetre|square millimetres"),
        ("cm2", .area, 1e-4, "cm²", nil, "square centimeters",
         "cm2|cm²|sq cm|square centimeter|square centimeters|square centimetre|square centimetres"),
        ("m2", .area, 1, "m²", nil, "square meters",
         "m2|m²|sqm|sq m|square meter|square meters|square metre|square metres"),
        ("km2", .area, 1e6, "km²", nil, "square kilometers",
         "km2|km²|sq km|square kilometer|square kilometers|square kilometre|square kilometres"),
        ("in2", .area, 0.00064516, "in²", nil, "square inches", "in2|in²|sq in|sqin|square inch|square inches"),
        ("ft2", .area, 0.09290304, "ft²", nil, "square feet", "ft2|ft²|sq ft|sqft|sq feet|square foot|square feet"),
        ("yd2", .area, 0.83612736, "yd²", nil, "square yards", "yd2|yd²|sq yd|square yard|square yards"),
        ("mi2", .area, 2_589_988.110336, "mi²", nil, "square miles", "mi2|mi²|sq mi|square mile|square miles"),
        ("acre", .area, 4046.8564224, "acre", "acres", "acres", "ac|acre|acres"),
        ("ha", .area, 10000, "ha", nil, "hectares", "ha|hectare|hectares"),
        // Volume (liters)
        ("ml", .volume, 0.001, "mL", nil, "milliliters",
         "ml|milliliter|milliliters|millilitre|millilitres|cc|cm3|cm³"),
        ("cl", .volume, 0.01, "cL", nil, "centiliters", "cl|centiliter|centiliters|centilitre|centilitres"),
        ("dl", .volume, 0.1, "dL", nil, "deciliters", "dl|deciliter|deciliters|decilitre|decilitres"),
        ("l", .volume, 1, "L", nil, "liters", "l|liter|liters|litre|litres|ltr"),
        ("m3", .volume, 1000, "m³", nil, "cubic meters", "m3|m³|cubic meter|cubic meters|cubic metre|cubic metres"),
        ("tsp", .volume, 0.00492892159375, "tsp", nil, "teaspoons", "tsp|tsps|teaspoon|teaspoons"),
        ("tbsp", .volume, 0.01478676478125, "tbsp", nil, "tablespoons", "tbsp|tbsps|tbs|tablespoon|tablespoons"),
        ("floz", .volume, 0.0295735295625, "fl oz", nil, "fluid ounces",
         "fl oz|floz|fl. oz|fl.oz|fluid ounce|fluid ounces"),
        ("cup", .volume, 0.2365882365, "cup", "cups", "cups", "cup|cups"),
        ("pint", .volume, 0.473176473, "pint", "pints", "pints", "pint|pints|us pint|us pints"),
        ("qt", .volume, 0.946352946, "qt", nil, "quarts", "qt|qts|quart|quarts"),
        ("gal", .volume, 3.785411784, "gal", nil, "gallons", "gal|gals|gallon|gallons|us gal|us gallon|us gallons"),
        ("ukpint", .volume, 0.56826125, "UK pint", "UK pints", "imperial pints",
         "uk pint|uk pints|imperial pint|imperial pints"),
        ("ukgal", .volume, 4.54609, "imp gal", nil, "imperial gallons",
         "imp gal|uk gal|uk gallon|uk gallons|imperial gallon|imperial gallons"),
        ("in3", .volume, 0.016387064, "in³", nil, "cubic inches", "in3|in³|cu in|cubic inch|cubic inches"),
        ("ft3", .volume, 28.316846592, "ft³", nil, "cubic feet", "ft3|ft³|cu ft|cubic foot|cubic feet"),
        ("bbl", .volume, 158.987294928, "bbl", nil, "barrels", "bbl|barrel|barrels"),
        // Mass (kilograms)
        ("ug", .mass, 1e-9, "µg", nil, "micrograms", "µg|μg|ug|mcg|microgram|micrograms"),
        ("mg", .mass, 1e-6, "mg", nil, "milligrams", "mg|milligram|milligrams|milligramme|milligrammes"),
        ("g", .mass, 0.001, "g", nil, "grams", "g|gr|gram|grams|gramme|grammes"),
        ("kg", .mass, 1, "kg", nil, "kilograms", "kg|kgs|kilo|kilos|kilogram|kilograms|kilogramme|kilogrammes"),
        ("t", .mass, 1000, "t", nil, "metric tons", "t|tonne|tonnes|metric ton|metric tons"),
        ("oz", .mass, 0.028349523125, "oz", nil, "ounces", "oz|ounce|ounces"),
        ("lb", .mass, 0.45359237, "lb", nil, "pounds", "lb|lbs|pound|pounds"),
        ("st", .mass, 6.35029318, "st", nil, "stone", "st|stone|stones"),
        ("ton", .mass, 907.18474, "ton", "tons", "short tons", "ton|tons|short ton|short tons|us ton|us tons"),
        ("longton", .mass, 1016.0469088, "long ton", "long tons", "long tons",
         "long ton|long tons|uk ton|uk tons|imperial ton|imperial tons"),
        ("ct", .mass, 0.0002, "ct", nil, "carats", "ct|carat|carats"),
        // Temperature (kelvin)
        ("c", .temperature, 1, "°C", nil, "degrees Celsius",
         "c|°c|ºc|celsius|centigrade|degc|deg c|degree c|degrees c|degree celsius|degrees celsius"),
        ("f", .temperature, 5.0 / 9, "°F", nil, "degrees Fahrenheit",
         "f|°f|ºf|fahrenheit|degf|deg f|degree f|degrees f|degree fahrenheit|degrees fahrenheit"),
        ("k", .temperature, 1, "K", nil, "kelvins", "k|°k|kelvin|kelvins"),
        // Duration (seconds)
        ("ns", .duration, 1e-9, "ns", nil, "nanoseconds", "ns|nanosecond|nanoseconds"),
        ("us", .duration, 1e-6, "µs", nil, "microseconds", "µs|μs|us|microsecond|microseconds"),
        ("ms", .duration, 0.001, "ms", nil, "milliseconds", "ms|msec|msecs|millisecond|milliseconds"),
        ("s", .duration, 1, "s", nil, "seconds", "s|sec|secs|second|seconds"),
        ("min", .duration, 60, "min", nil, "minutes", "min|mins|minute|minutes"),
        ("h", .duration, 3600, "h", nil, "hours", "h|hr|hrs|hour|hours"),
        ("d", .duration, 86400, "day", "days", "days", "d|day|days"),
        ("wk", .duration, 604_800, "wk", nil, "weeks", "wk|wks|week|weeks"),
        ("mo", .duration, 2_629_746, "mo", nil, "months", "mo|mos|month|months"),
        ("yr", .duration, 31_556_952, "yr", nil, "years", "y|yr|yrs|year|years"),
        ("decade", .duration, 315_569_520, "decade", "decades", "decades", "decade|decades"),
        ("century", .duration, 3_155_695_200, "century", "centuries", "centuries", "century|centuries"),
        // Speed (meters per second)
        ("mps", .speed, 1, "m/s", nil, "meters per second",
         "m/s|mps|meter per second|meters per second|metre per second|metres per second"),
        ("kmh", .speed, 1 / 3.6, "km/h", nil, "kilometers per hour",
         "km/h|kmh|kph|kmph|km/hr|km per hour|kilometer per hour|kilometers per hour|kilometres per hour"),
        ("mph", .speed, 0.44704, "mph", nil, "miles per hour", "mph|mi/h|mile per hour|miles per hour"),
        ("kn", .speed, 1852.0 / 3600, "kn", nil, "knots", "kn|kt|kts|knot|knots"),
        ("fps", .speed, 0.3048, "ft/s", nil, "feet per second", "ft/s|fps|foot per second|feet per second"),
        // Data (bytes)
        ("bit", .data, 0.125, "bit", "bits", "bits", "bit|bits|=b"),
        ("byte", .data, 1, "B", nil, "bytes", "byte|bytes|=B"),
        ("kb", .data, 1e3, "kB", nil, "kilobytes", "kb|kilobyte|kilobytes"),
        ("mb", .data, 1e6, "MB", nil, "megabytes", "mb|megabyte|megabytes"),
        ("gb", .data, 1e9, "GB", nil, "gigabytes", "gb|gigabyte|gigabytes"),
        ("tb", .data, 1e12, "TB", nil, "terabytes", "tb|terabyte|terabytes"),
        ("pb", .data, 1e15, "PB", nil, "petabytes", "pb|petabyte|petabytes"),
        ("kib", .data, 1024, "KiB", nil, "kibibytes", "kib|kibibyte|kibibytes"),
        ("mib", .data, 1_048_576, "MiB", nil, "mebibytes", "mib|mebibyte|mebibytes"),
        ("gib", .data, 1_073_741_824, "GiB", nil, "gibibytes", "gib|gibibyte|gibibytes"),
        ("tib", .data, 1_099_511_627_776, "TiB", nil, "tebibytes", "tib|tebibyte|tebibytes"),
        ("kbit", .data, 125, "kbit", nil, "kilobits", "kbit|kbits|kilobit|kilobits|=Kb"),
        ("mbit", .data, 125_000, "Mbit", nil, "megabits", "mbit|mbits|megabit|megabits|=Mb"),
        ("gbit", .data, 125_000_000, "Gbit", nil, "gigabits", "gbit|gbits|gigabit|gigabits|=Gb"),
        ("tbit", .data, 125_000_000_000, "Tbit", nil, "terabits", "tbit|tbits|terabit|terabits|=Tb"),
        // Pressure (pascals)
        ("pa", .pressure, 1, "Pa", nil, "pascals", "pa|pascal|pascals"),
        ("hpa", .pressure, 100, "hPa", nil, "hectopascals", "hpa|hectopascal|hectopascals"),
        ("kpa", .pressure, 1000, "kPa", nil, "kilopascals", "kpa|kilopascal|kilopascals"),
        ("mpa", .pressure, 1e6, "MPa", nil, "megapascals", "mpa|megapascal|megapascals"),
        ("bar", .pressure, 1e5, "bar", nil, "bar", "bar|bars"),
        ("mbar", .pressure, 100, "mbar", nil, "millibars", "mbar|millibar|millibars"),
        ("atm", .pressure, 101_325, "atm", nil, "atmospheres", "atm|atmosphere|atmospheres"),
        ("psi", .pressure, 6894.757293168, "psi", nil, "pounds per square inch", "psi|pounds per square inch"),
        ("mmhg", .pressure, 133.322387415, "mmHg", nil, "millimeters of mercury", "mmhg|millimeters of mercury"),
        ("inhg", .pressure, 3386.389, "inHg", nil, "inches of mercury", "inhg|inches of mercury"),
        ("torr", .pressure, 101_325.0 / 760, "Torr", nil, "torr", "torr"),
        // Energy (joules)
        ("j", .energy, 1, "J", nil, "joules", "j|joule|joules"),
        ("kj", .energy, 1000, "kJ", nil, "kilojoules", "kj|kilojoule|kilojoules"),
        ("mj", .energy, 1e6, "MJ", nil, "megajoules", "mj|megajoule|megajoules"),
        ("cal", .energy, 4.184, "cal", nil, "calories", "cal|calorie|calories"),
        ("kcal", .energy, 4184, "kcal", nil, "kilocalories", "kcal|kilocalorie|kilocalories|=Cal"),
        ("wh", .energy, 3600, "Wh", nil, "watt-hours", "wh|watt hour|watt hours|watt-hour|watt-hours"),
        ("kwh", .energy, 3.6e6, "kWh", nil, "kilowatt-hours",
         "kwh|kilowatt hour|kilowatt hours|kilowatt-hour|kilowatt-hours"),
        ("btu", .energy, 1055.05585262, "BTU", nil, "British thermal units", "btu|btus|british thermal unit"),
        ("ev", .energy, 1.602176634e-19, "eV", nil, "electronvolts", "ev|electronvolt|electronvolts"),
        // Power (watts)
        ("mw", .power, 0.001, "mW", nil, "milliwatts", "mw|milliwatt|milliwatts"),
        ("w", .power, 1, "W", nil, "watts", "w|watt|watts"),
        ("kw", .power, 1000, "kW", nil, "kilowatts", "kw|kilowatt|kilowatts"),
        ("megaw", .power, 1e6, "MW", nil, "megawatts", "megawatt|megawatts|=MW"),
        ("gw", .power, 1e9, "GW", nil, "gigawatts", "gw|gigawatt|gigawatts"),
        ("hp", .power, 745.69987158227022, "hp", nil, "horsepower", "hp|horsepower|bhp"),
        // Angle (degrees)
        ("deg", .angle, 1, "°", nil, "degrees", "°|deg|degs|degree|degrees"),
        ("rad", .angle, 180 / Double.pi, "rad", nil, "radians", "rad|rads|radian|radians"),
        ("grad", .angle, 0.9, "grad", nil, "gradians", "grad|grads|gon|gradian|gradians"),
        ("turn", .angle, 360, "turn", "turns", "turns", "turn|turns|rev|revs|revolution|revolutions"),
        ("arcmin", .angle, 1.0 / 60, "arcmin", nil, "arcminutes", "arcmin|arcminute|arcminutes"),
        ("arcsec", .angle, 1.0 / 3600, "arcsec", nil, "arcseconds", "arcsec|arcsecond|arcseconds"),
        // Frequency (hertz)
        ("hz", .frequency, 1, "Hz", nil, "hertz", "hz|hertz"),
        ("khz", .frequency, 1e3, "kHz", nil, "kilohertz", "khz|kilohertz"),
        ("mhz", .frequency, 1e6, "MHz", nil, "megahertz", "mhz|megahertz"),
        ("ghz", .frequency, 1e9, "GHz", nil, "gigahertz", "ghz|gigahertz"),
        ("thz", .frequency, 1e12, "THz", nil, "terahertz", "thz|terahertz"),
        ("rpm", .frequency, 1.0 / 60, "rpm", nil, "revolutions per minute", "rpm|revolutions per minute"),
        // Screen (pixels; rem and em scale with the configured base)
        ("px", .screen, 1, "px", nil, "pixels", "px|pixel|pixels"),
        ("rem", .screen, 16, "rem", nil, "rem", "rem|rems"),
        ("em", .screen, 16, "em", nil, "em", "em|ems"),
    ]

    static let units: [String: CalcUnit] = {
        var units: [String: CalcUnit] = [:]
        for row in rows {
            let offset: Double = switch row.0 {
            case "c": 273.15
            case "f": 459.67 * 5 / 9
            default: 0
            }
            units[row.0] = CalcUnit(id: row.0, category: row.1, factor: row.2, offset: offset, symbol: row.3,
                                    pluralSymbol: row.4, name: row.5)
        }
        return units
    }()

    /// Lowercased alias → unit ids (an alias like "pound" can name more than one thing; the other side decides).
    static let aliases: [String: [String]] = {
        var aliases: [String: [String]] = [:]
        for row in rows {
            for alias in row.6.split(separator: "|").map(String.init) where !alias.hasPrefix("=") {
                aliases[alias, default: []].append(row.0)
            }
        }
        return aliases
    }()

    /// Case-sensitive aliases, checked before the others.
    static let exactAliases: [String: String] = {
        var aliases: [String: String] = [:]
        for row in rows {
            for alias in row.6.split(separator: "|") where alias.hasPrefix("=") {
                aliases[String(alias.dropFirst())] = row.0
            }
        }
        return aliases
    }()

    /// Each category's usual counterpart, for a bare "10 km" (→ mi) or "37c" (→ °F).
    static let counterparts: [String: String] = [
        "km": "mi", "mi": "km", "m": "ft", "ft": "m", "cm": "in", "in": "cm", "mm": "in", "yd": "m",
        "kg": "lb", "lb": "kg", "g": "oz", "oz": "g", "st": "kg",
        "c": "f", "f": "c", "k": "c",
        "l": "gal", "gal": "l", "ml": "floz", "floz": "ml", "cup": "ml", "tbsp": "ml", "tsp": "ml", "pint": "ml",
        "qt": "l",
        "kmh": "mph", "mph": "kmh", "kn": "kmh", "mps": "kmh",
        "m2": "ft2", "ft2": "m2", "acre": "ha", "ha": "acre", "km2": "mi2", "mi2": "km2",
        "kb": "kib", "mb": "mib", "gb": "gib", "tb": "tib", "kib": "kb", "mib": "mb", "gib": "gb", "tib": "tb",
        "kcal": "kj", "kj": "kcal", "kwh": "mj", "hp": "kw", "kw": "hp", "psi": "bar", "bar": "psi",
        "rad": "deg", "rem": "px", "px": "rem",
    ]
}
