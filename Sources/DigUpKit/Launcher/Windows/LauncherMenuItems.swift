import Foundation

/// A menu item's keyboard shortcut as the Accessibility API describes it (`AXMenuItemCmdChar`,
/// `AXMenuItemCmdModifiers`, `AXMenuItemCmdGlyph`), shown the way menus show it: "⇧⌘S", "⌥⌘←", "F11".
public enum LauncherMenuShortcut {
    /// `AXMenuItemCmdModifiers` bits. With none of them set, the shortcut is ⌘ plus the key.
    public static let shift = 1 << 0
    public static let option = 1 << 1
    public static let control = 1 << 2
    /// Not even ⌘: the key alone (F11, Delete).
    public static let noCommand = 1 << 3

    /// "⌃⌥⇧⌘K" for a key character (or, when there's none, a menu glyph code) and the modifier bits; nil when the item
    /// has no shortcut.
    public static func display(character: String?, modifiers: Int?, glyph: Int?) -> String? {
        let key: String
        if let character, !character.isEmpty, let name = keyName(character) {
            key = name
        } else if let glyph, let name = glyphName(glyph) {
            key = name
        } else {
            return nil
        }
        let bits = modifiers ?? 0
        var text = ""
        if bits & control != 0 { text += "⌃" }
        if bits & option != 0 { text += "⌥" }
        if bits & shift != 0 { text += "⇧" }
        if bits & noCommand == 0 { text += "⌘" }
        return text + key
    }

    /// How a key character reads in a menu: letters uppercased, AppKit's function-key characters (U+F700…) and control
    /// characters as their symbols. Nil for characters that don't name a key.
    static func keyName(_ character: String) -> String? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x03, 0x0D: return "↩"
        case 0x08, 0x7F: return "⌫"
        case 0x09: return "⇥"
        case 0x19: return "⇤"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF726: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0xF739: return "⌧"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil
        default: return character.uppercased()
        }
    }

    /// The Menu Manager's glyph codes (kMenuReturnGlyph and friends), for keys without a character.
    static func glyphName(_ glyph: Int) -> String? {
        switch glyph {
        case 0x02: return "⇥"
        case 0x03: return "⇤"
        case 0x04: return "⌤"
        case 0x09: return "Space"
        case 0x0A: return "⌦"
        case 0x0B, 0x0D: return "↩"
        case 0x10, 0x6A: return "↓"
        case 0x17: return "⌫"
        case 0x18, 0x64: return "←"
        case 0x19, 0x68: return "↑"
        case 0x1A, 0x65: return "→"
        case 0x1B: return "⎋"
        case 0x1C: return "⌧"
        case 0x62: return "⇞"
        case 0x63: return "⇪"
        case 0x66: return "↖"
        case 0x67: return "Help"
        case 0x69: return "↘"
        case 0x6B: return "⇟"
        case 0x6E: return "⌽"
        case 0x6F...0x7A: return "F\(glyph - 0x6F + 1)"
        case 0x87...0x89: return "F\(glyph - 0x87 + 13)"
        case 0x8C: return "⏏"
        case 0x8F...0x92: return "F\(glyph - 0x8F + 16)"
        default: return nil
        }
    }
}

/// The menus of the app in front, flattened into one searchable list ("File › Export as PDF…").
public enum LauncherMenuPath {
    /// The separator between a menu and its submenus, as shown.
    public static let separator = " › "

    /// "File › Export" for the menus above an item.
    public static func display(_ path: [String]) -> String {
        path.joined(separator: separator)
    }

    /// Whether a menu bar walk should step into this menu: not the Apple menu (always the first), and not past
    /// `maxDepth` levels of submenus.
    public static func shouldWalk(menuIndex: Int, depth: Int, maxDepth: Int = 4) -> Bool {
        !(depth == 0 && menuIndex == 0) && depth <= maxDepth
    }
}
