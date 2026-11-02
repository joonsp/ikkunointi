import Foundation

public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// 0xRRGGBBAA
    public init(rgba hex: UInt32) {
        r = Double((hex >> 24) & 0xff) / 255
        g = Double((hex >> 16) & 0xff) / 255
        b = Double((hex >> 8) & 0xff) / 255
        a = Double(hex & 0xff) / 255
    }
}

public struct BorderGradient: Equatable, Sendable {
    public var colors: [RGBA]
    public var angle: Double

    /// Parses Hyprland color values: `rgba(33ccffee) rgba(00ff99ee) 45deg`, `rgb(7aa2f7)`,
    /// `0xee33ccff`, `rgba(51, 204, 255, 0.9)`.
    public static func parse(_ raw: String) -> BorderGradient? {
        let pattern = #"rgba?\([^)]*\)|0x[0-9a-fA-F]{8}|-?\d+(?:\.\d+)?\s*deg"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        // Reject anything the token regex did not account for.
        let leftover = re.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        guard leftover.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var colors: [RGBA] = []
        var angle = 0.0
        for m in matches {
            let token = ns.substring(with: m.range).lowercased()
            if token.hasSuffix("deg") {
                angle = Double(token.dropLast(3).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if let c = parseColor(token) {
                colors.append(c)
            } else {
                return nil
            }
        }
        guard !colors.isEmpty else { return nil }
        return BorderGradient(colors: colors, angle: angle)
    }

    static func parseColor(_ token: String) -> RGBA? {
        if token.hasPrefix("0x") {
            guard let v = UInt32(token.dropFirst(2), radix: 16) else { return nil }
            // Hyprland's legacy 0xAARRGGBB
            return RGBA(rgba: (v << 8) | (v >> 24))
        }
        let isRGBA = token.hasPrefix("rgba(")
        let inner = token.drop(while: { $0 != "(" }).dropFirst().dropLast()
        if inner.contains(",") {
            let parts = inner.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.allSatisfy({ $0 != nil }), parts.count == (isRGBA ? 4 : 3) else { return nil }
            let p = parts.map { $0! }
            return RGBA(r: p[0] / 255, g: p[1] / 255, b: p[2] / 255, a: isRGBA ? p[3] : 1)
        }
        let hex = inner.trimmingCharacters(in: .whitespaces)
        if hex.count == 8, let v = UInt32(hex, radix: 16) { return RGBA(rgba: v) }
        if hex.count == 6, let v = UInt32(hex, radix: 16) { return RGBA(rgba: (v << 8) | 0xff) }
        return nil
    }
}

public enum RuleEffect: Equatable, Sendable {
    case float
    case tile
    case workspace(Int, silent: Bool)
}

public struct WindowRule {
    public var effect: RuleEffect
    public var classPattern: NSRegularExpression?
    public var titlePattern: NSRegularExpression?

    /// `class:` matches either the bundle identifier or the app name (case-insensitive).
    public func matches(bundleID: String?, appName: String?, title: String?) -> Bool {
        func test(_ re: NSRegularExpression?, _ values: [String?]) -> Bool {
            guard let re else { return true }
            return values.contains { v in
                guard let v else { return false }
                return re.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil
            }
        }
        return test(classPattern, [bundleID, appName]) && test(titlePattern, [title])
    }
}

public struct KeyBinding {
    public var mods: Modifiers
    public var key: KeySpec
    /// The key as written, for display.
    public var keyLabel: String
    public var action: Action
    public var description: String?
    public var repeats: Bool
    public var line: Int
}

public enum MouseAction: String, Sendable {
    case move = "movewindow"
    case resize = "resizewindow"
}

public struct MouseBinding {
    public var mods: Modifiers
    public var button: MouseButton
    public var action: MouseAction
    public var line: Int
}

public struct ConfigIssue: CustomStringConvertible, Equatable {
    public var file: String?
    public var line: Int
    public var message: String
    public init(file: String?, line: Int, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }
    public var description: String {
        let place = file.map { "\(($0 as NSString).lastPathComponent):\(line)" } ?? "line \(line)"
        return "\(place): \(message)"
    }
}

public struct Config {
    public var superKey: SuperKey = .capslock
    public var gapsIn: Double = 5
    public var gapsOut: Double = 10
    public var borderSize: Double = 2
    public var activeBorder = BorderGradient(colors: [RGBA(rgba: 0x33ccffee), RGBA(rgba: 0x00ff99ee)], angle: 45)
    public var rounding: Double = 12
    /// Fraction of a split given to the first child.
    public var splitRatio: Double = 0.5
    public var workspaceBackAndForth = false
    public var keyBindings: [KeyBinding] = []
    public var mouseBindings: [MouseBinding] = []
    public var windowRules: [WindowRule] = []
    public var execOnce: [String] = []
    public var exec: [String] = []
    public var errors: [ConfigIssue] = []
    public var warnings: [ConfigIssue] = []

    public init() {}

    /// Parses hyprland.conf-flavoured text. `loader` resolves `source = path` includes.
    public static func parse(_ text: String, file: String? = nil, loader: ((String) -> String?)? = nil) -> Config {
        var parser = Parser(loader: loader)
        parser.run(text, file: file, depth: 0)
        return parser.config
    }
}

private struct Parser {
    var config = Config()
    var variables: [String: String] = [:]
    let loader: ((String) -> String?)?

    init(loader: ((String) -> String?)?) { self.loader = loader }

    mutating func run(_ text: String, file: String?, depth: Int) {
        var sections: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for (index, raw) in lines.enumerated() {
            let lineNo = index + 1
            func error(_ msg: String) { config.errors.append(ConfigIssue(file: file, line: lineNo, message: msg)) }

            let line = Parser.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "}" {
                if sections.isEmpty { error("unexpected '}'") } else { sections.removeLast() }
                continue
            }
            if line.hasSuffix("{") {
                let name = line.dropLast().trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !name.contains("=") {
                    sections.append(name.lowercased())
                    continue
                }
            }
            guard let eq = line.firstIndex(of: "=") else {
                error("expected 'key = value'")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("$") {
                variables[String(key.dropFirst())] = substitute(rawValue)
                continue
            }
            let value = substitute(rawValue)
            let keyword = key.lowercased()

            if keyword.hasPrefix("bind") && sections.isEmpty {
                parseBind(keyword: keyword, value: value, file: file, line: lineNo)
                continue
            }
            switch keyword {
            case "windowrule", "windowrulev2":
                parseRule(value, file: file, line: lineNo)
                continue
            case "exec-once":
                config.execOnce.append(value)
                continue
            case "exec":
                config.exec.append(value)
                continue
            case "source":
                guard depth < 8 else { error("source nesting too deep"); continue }
                guard let loader, let included = loader(value) else { error("cannot read source '\(value)'"); continue }
                run(included, file: value, depth: depth + 1)
                continue
            default:
                break
            }

            let fullKey = (sections + [keyword]).joined(separator: ":")
            setOption(fullKey, value, file: file, line: lineNo)
        }
        if !sections.isEmpty {
            config.errors.append(ConfigIssue(file: file, line: lines.count, message: "missing '}' for section '\(sections.last!)'"))
        }
    }

    /// `#` starts a comment, `##` is a literal `#` (Hyprland semantics).
    static func stripComment(_ s: String) -> String {
        var out = ""
        var it = Array(s)
        var i = 0
        while i < it.count {
            if it[i] == "#" {
                if i + 1 < it.count && it[i + 1] == "#" {
                    out.append("#")
                    i += 2
                    continue
                }
                break
            }
            out.append(it[i])
            i += 1
        }
        it.removeAll()
        return out
    }

    /// Replaces `$name` with known variables; unknown ones (e.g. `$HOME`) are left for the shell.
    func substitute(_ s: String) -> String {
        guard s.contains("$") else { return s }
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "$" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let name = String(chars[(i + 1)..<j])
                if !name.isEmpty, let v = variables[name] {
                    out += v
                    i = j
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Splits on the first `count - 1` commas; the rest stays in the last field.
    static func split(_ s: String, into count: Int) -> [String] {
        s.split(separator: ",", maxSplits: count - 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    mutating func parseBind(keyword: String, value: String, file: String?, line: Int) {
        func error(_ msg: String) { config.errors.append(ConfigIssue(file: file, line: line, message: msg)) }
        let flags = keyword.dropFirst(4)
        var repeats = false, described = false, mouse = false
        for f in flags {
            switch f {
            case "e": repeats = true
            case "d": described = true
            case "m": mouse = true
            case "l", "n", "i", "t", "s", "o", "p", "c", "g", "u": break
            case "r":
                config.warnings.append(ConfigIssue(file: file, line: line, message: "release binds (bindr) fire on press here"))
            default:
                error("unknown bind flag '\(f)'")
                return
            }
        }
        let parts = Parser.split(value, into: described ? 5 : 4)
        guard parts.count >= 3 else {
            error("bind needs at least 'MODS, KEY, dispatcher'")
            return
        }
        guard let mods = Modifiers.parse(parts[0]) else {
            error("unknown modifier in '\(parts[0])'")
            return
        }
        let keyText = parts[1]
        var description: String?
        var rest = Array(parts.dropFirst(2))
        if described {
            description = rest.first
            rest = Array(rest.dropFirst())
        }
        guard let dispatcher = rest.first, !dispatcher.isEmpty else {
            error("bind is missing a dispatcher")
            return
        }
        let args = rest.count > 1 ? rest[1] : ""

        if mouse || keyText.lowercased().hasPrefix("mouse:") {
            guard let code = Int(keyText.lowercased().replacingOccurrences(of: "mouse:", with: "")),
                  let button = MouseButton(rawValue: code) else {
                error("unknown mouse button '\(keyText)' (use mouse:272 or mouse:273)")
                return
            }
            guard let action = MouseAction(rawValue: dispatcher.lowercased()) else {
                error("mouse binds support movewindow and resizewindow, not '\(dispatcher)'")
                return
            }
            config.mouseBindings.append(MouseBinding(mods: mods, button: button, action: action, line: line))
            return
        }

        guard let key = KeyNames.parse(keyText) else {
            error("unknown key '\(keyText)'")
            return
        }
        do {
            let action = try Action.parse(dispatcher: dispatcher, args: args)
            config.keyBindings.append(KeyBinding(
                mods: mods, key: key, keyLabel: keyText, action: action,
                description: (description?.isEmpty ?? true) ? nil : description,
                repeats: repeats || action.repeatsByDefault, line: line))
        } catch {
            config.errors.append(ConfigIssue(file: file, line: line, message: "\(error)"))
        }
    }

    mutating func issue(_ msg: String, _ file: String?, _ line: Int, warning: Bool = false) {
        let i = ConfigIssue(file: file, line: line, message: msg)
        if warning { config.warnings.append(i) } else { config.errors.append(i) }
    }

    mutating func parseRule(_ value: String, file: String?, line: Int) {
        guard let comma = value.firstIndex(of: ",") else {
            issue("windowrule needs 'effect, matcher'", file, line)
            return
        }
        let effectText = value[..<comma].trimmingCharacters(in: .whitespaces).lowercased()
        let matchers = String(value[value.index(after: comma)...])

        let effect: RuleEffect
        let words = effectText.split(separator: " ").map(String.init)
        switch words.first {
        case "float": effect = .float
        case "tile": effect = .tile
        case "workspace":
            guard words.count >= 2, let n = Int(words[1]), n >= 1 else {
                issue("workspace rule needs a workspace number", file, line)
                return
            }
            effect = .workspace(n, silent: words.count > 2 && words[2] == "silent")
        default:
            issue("window rule '\(effectText)' is not supported (float, tile, workspace N)", file, line, warning: true)
            return
        }

        // Split "class:..., title:..." on matcher prefixes so regexes may contain commas.
        let prefixRe = try! NSRegularExpression(pattern: #"(?:^|,)\s*(class|title|app|initialclass|initialtitle)\s*:"#, options: [.caseInsensitive])
        let ns = matchers as NSString
        let found = prefixRe.matches(in: matchers, range: NSRange(location: 0, length: ns.length))
        guard !found.isEmpty else {
            issue("windowrule needs a class: or title: matcher", file, line)
            return
        }
        var rule = WindowRule(effect: effect, classPattern: nil, titlePattern: nil)
        for (i, m) in found.enumerated() {
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            let start = m.range.location + m.range.length
            let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
            let pattern = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                issue("invalid regex '\(pattern)'", file, line)
                return
            }
            if kind.hasSuffix("title") { rule.titlePattern = re } else { rule.classPattern = re }
        }
        config.windowRules.append(rule)
    }

    mutating func setOption(_ key: String, _ value: String, file: String?, line: Int) {
        var problems: [(String, Bool)] = []
        defer { for (msg, isWarning) in problems { issue(msg, file, line, warning: isWarning) } }
        func error(_ msg: String) { problems.append((msg, false)) }
        func warn(_ msg: String) { problems.append((msg, true)) }
        func number() -> Double? {
            // Hyprland accepts CSS-like "5 10 5 10"; we use the first value.
            guard let first = value.split(separator: " ").first, let d = Double(first) else {
                error("\(key): expected a number, got '\(value)'")
                return nil
            }
            return d
        }
        func bool() -> Bool? {
            switch value.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default:
                error("\(key): expected true/false, got '\(value)'")
                return nil
            }
        }
        switch key {
        case "input:super_key":
            if let k = SuperKey(config: value) { config.superKey = k } else {
                error("input:super_key: unknown key '\(value)' (capslock, rcmd, ropt, rctrl, cmd, alt, ctrl, ctrl+alt)")
            }
        case "general:gaps_in":
            if let v = number() { config.gapsIn = max(0, v) }
        case "general:gaps_out":
            if let v = number() { config.gapsOut = max(0, v) }
        case "general:border_size":
            if let v = number() { config.borderSize = max(0, v) }
        case "general:col.active_border":
            if let g = BorderGradient.parse(value) { config.activeBorder = g } else {
                error("general:col.active_border: cannot parse '\(value)'")
            }
        case "general:layout":
            if value.lowercased() != "dwindle" { warn("only the dwindle layout is supported") }
        case "decoration:rounding":
            if let v = number() { config.rounding = max(0, v) }
        case "dwindle:default_split_ratio":
            if let v = number() { config.splitRatio = min(max(v, 0.1), 1.9) / 2 }
        case "binds:workspace_back_and_forth":
            if let b = bool() { config.workspaceBackAndForth = b }
        case "general:col.inactive_border", "dwindle:preserve_split", "dwindle:pseudotile", "dwindle:force_split":
            break // accepted for compatibility; not meaningful here
        default:
            warn("unsupported option '\(key)' ignored")
        }
    }
}
