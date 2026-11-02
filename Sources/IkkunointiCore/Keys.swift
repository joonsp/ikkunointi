import Foundation

/// Abstract modifier set. `superKey` is Hyprland's SUPER; which physical key produces it
/// is decided by `input:super_key` (Caps Lock, right Command, ...).
public struct Modifiers: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let superKey = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let ctrl = Modifiers(rawValue: 1 << 2)
    public static let alt = Modifiers(rawValue: 1 << 3)
    public static let cmd = Modifiers(rawValue: 1 << 4)

    private static let names: [(String, Modifiers)] = [
        ("CONTROL", .ctrl), ("COMMAND", .cmd), ("OPTION", .alt), ("SUPER", .superKey), ("SHIFT", .shift),
        ("MOD4", .superKey), ("MOD1", .alt), ("LOGO", .superKey), ("META", .superKey), ("CTRL", .ctrl),
        ("CMD", .cmd), ("ALT", .alt), ("OPT", .alt), ("WIN", .superKey),
    ]

    /// Parses Hyprland modifier strings: "SUPER SHIFT", "SUPER_SHIFT", "SUPERSHIFT", "$mod CTRL".
    public static func parse(_ raw: String) -> Modifiers? {
        var result: Modifiers = []
        let chunks = raw.uppercased().split(whereSeparator: { " _+&|\t".contains($0) })
        for chunk in chunks {
            var rest = Substring(chunk)
            while !rest.isEmpty {
                guard let (name, mod) = names.first(where: { rest.hasPrefix($0.0) }) else { return nil }
                result.insert(mod)
                rest = rest.dropFirst(name.count)
            }
        }
        return result
    }

    public var description: String {
        var parts: [String] = []
        if contains(.superKey) { parts.append("SUPER") }
        if contains(.ctrl) { parts.append("CTRL") }
        if contains(.alt) { parts.append("ALT") }
        if contains(.cmd) { parts.append("CMD") }
        if contains(.shift) { parts.append("SHIFT") }
        return parts.joined(separator: " ")
    }
}

/// Which physical key acts as SUPER.
public enum SuperKey: String, CaseIterable, Sendable {
    /// Caps Lock, remapped to F18 with hidutil while the app runs.
    case capslock
    /// Right Command only; left Command keeps normal shortcuts.
    case rcmd
    /// Right Option only; left Option keeps typing special characters.
    case ropt
    /// Right Control only.
    case rctrl
    case cmd
    case alt
    case ctrl
    /// Control + Option held together.
    case ctrlAlt = "ctrl+alt"

    public init?(config raw: String) {
        let s = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        switch s {
        case "capslock", "caps", "capslk": self = .capslock
        case "rcmd", "rightcmd", "rightcommand", "rcommand": self = .rcmd
        case "ropt", "ralt", "rightalt", "rightopt", "rightoption", "roption": self = .ropt
        case "rctrl", "rightctrl", "rightcontrol", "rcontrol": self = .rctrl
        case "cmd", "command": self = .cmd
        case "alt", "opt", "option": self = .alt
        case "ctrl", "control": self = .ctrl
        case "ctrl+alt", "ctrl+opt", "alt+ctrl", "opt+ctrl", "ctrl+option": self = .ctrlAlt
        default: return nil
        }
    }

    /// Glyph used in the key binding overlay.
    public var symbol: String {
        switch self {
        case .capslock: return "⇪"
        case .rcmd, .cmd: return "⌘"
        case .ropt, .alt: return "⌥"
        case .rctrl, .ctrl: return "⌃"
        case .ctrlAlt: return "⌃⌥"
        }
    }

    /// When SUPER is a plain modifier, a binding that spells that modifier out means SUPER.
    public func normalize(_ mods: Modifiers) -> Modifiers {
        var m = mods
        switch self {
        case .cmd: if m.contains(.cmd) { m.remove(.cmd); m.insert(.superKey) }
        case .alt: if m.contains(.alt) { m.remove(.alt); m.insert(.superKey) }
        case .ctrl: if m.contains(.ctrl) { m.remove(.ctrl); m.insert(.superKey) }
        case .ctrlAlt: if m.contains([.ctrl, .alt]) { m.remove([.ctrl, .alt]); m.insert(.superKey) }
        case .capslock, .rcmd, .ropt, .rctrl: break
        }
        return m
    }
}

/// A key as written in the config.
public enum KeySpec: Hashable, Sendable {
    /// A fixed macOS virtual key code (named keys, digits, `code:N`).
    case code(UInt16)
    /// A character resolved through the active keyboard layout (letters, punctuation).
    case character(Character)
}

public enum MouseButton: Int, Sendable {
    case left = 272, right = 273, middle = 274
}

/// macOS virtual key codes (Carbon `kVK_*`). Digit and punctuation names refer to
/// physical positions on an ANSI keyboard, like Omarchy's `code:` bindings.
public enum KeyNames {
    public static let named: [String: UInt16] = [
        "RETURN": 36, "ENTER": 36, "TAB": 48, "SPACE": 49, "BACKSPACE": 51, "DELETE": 117,
        "ESCAPE": 53, "ESC": 53, "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126,
        "HOME": 115, "END": 119, "PAGEUP": 116, "PRIOR": 116, "PAGEDOWN": 121, "NEXT": 121,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100,
        "F9": 101, "F10": 109, "F11": 103, "F12": 111, "F13": 105, "F14": 107, "F15": 113,
        "F16": 106, "F17": 64, "F19": 80, "F20": 90,
        "MINUS": 27, "EQUAL": 24, "BRACKETLEFT": 33, "BRACKETRIGHT": 30, "SEMICOLON": 41,
        "APOSTROPHE": 39, "COMMA": 43, "PERIOD": 47, "SLASH": 44, "BACKSLASH": 42, "GRAVE": 50,
        "SECTION": 10,
    ]

    /// ANSI positions, used as fallback when the layout cannot produce a character.
    public static let ansi: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// The F18 key that Caps Lock is remapped to.
    public static let f18: UInt16 = 79

    /// Pretty label for keys whose glyph is not just a character.
    public static let symbols: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func parse(_ raw: String) -> KeySpec? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("code:") {
            guard let n = UInt16(t.dropFirst(5).trimmingCharacters(in: .whitespaces)), n < 128 else { return nil }
            return .code(n)
        }
        if t.count == 1, let c = t.lowercased().first {
            if c.isNumber, let code = ansi[c] { return .code(code) }
            return .character(c)
        }
        if let code = named[t.uppercased()] { return .code(code) }
        return nil
    }
}
