import Foundation

public enum WorkspaceTarget: Equatable, Sendable {
    /// `workspace, 3`
    case number(Int)
    /// `workspace, +1` / `-1`: numeric neighbour.
    case relative(Int)
    /// `workspace, e+1` / `e-1`: next/previous workspace that has windows.
    case existingRelative(Int)
    /// `workspace, previous`: the workspace you came from.
    case previous

    public init?(hypr raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "previous" || s == "back" {
            self = .previous
        } else if s.hasPrefix("e"), let n = Int(s.dropFirst()) {
            self = .existingRelative(n)
        } else if s.hasPrefix("+") || s.hasPrefix("-"), let n = Int(s) {
            self = .relative(n)
        } else if let n = Int(s), n >= 1 {
            self = .number(n)
        } else if s.hasPrefix("name:") || s.hasPrefix("special") {
            return nil
        } else {
            return nil
        }
    }
}

/// Everything a key binding (or `ikkunointictl dispatch`) can do. Names follow
/// Hyprland dispatchers so an Omarchy config reads the same.
public enum Action: Equatable, Sendable {
    case exec(String)
    case newWindow(app: String)
    case killActive
    case toggleFloating
    case fullscreen(mode: Int)
    case toggleSplit
    case toggleLayout
    case pseudo
    case moveFocus(Direction)
    case swapWindow(Direction)
    case workspace(WorkspaceTarget)
    case moveToWorkspace(WorkspaceTarget, silent: Bool)
    case resizeActive(dx: Double, dy: Double)
    case cycleNext(previous: Bool)
    case focusMonitor(Direction)
    case centerWindow
    case reload
    case showKeys
    case exit

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static let dispatcherNames = [
        "exec", "newwindow", "killactive", "togglefloating", "fullscreen", "togglesplit", "togglelayout", "pseudo",
        "movefocus", "swapwindow", "movewindow", "workspace", "movetoworkspace", "movetoworkspacesilent",
        "resizeactive", "cyclenext", "focusmonitor", "centerwindow", "reload", "showkeys", "exit",
    ]

    public static func parse(dispatcher rawDispatcher: String, args rawArgs: String) throws -> Action {
        let dispatcher = rawDispatcher.trimmingCharacters(in: .whitespaces).lowercased()
        let args = rawArgs.trimmingCharacters(in: .whitespaces)
        func fail(_ msg: String) -> ParseError { ParseError(description: msg) }
        func direction() throws -> Direction {
            guard let d = Direction(hypr: args) else { throw fail("\(dispatcher): expected direction l/r/u/d, got '\(args)'") }
            return d
        }
        func workspaceTarget() throws -> WorkspaceTarget {
            // `movetoworkspace, 3,address:...` style extra args are ignored.
            let first = args.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            guard let t = WorkspaceTarget(hypr: first) else {
                throw fail("\(dispatcher): unsupported workspace '\(args)' (use a number, +1/-1, e+1/e-1 or previous)")
            }
            return t
        }

        switch dispatcher {
        case "exec":
            guard !args.isEmpty else { throw fail("exec: missing command") }
            return .exec(args)
        case "newwindow":
            guard !args.isEmpty else { throw fail("newwindow: missing app name or bundle id") }
            return .newWindow(app: args)
        case "killactive", "closewindow":
            return .killActive
        case "togglefloating":
            return .toggleFloating
        case "fullscreen":
            if args.isEmpty { return .fullscreen(mode: 0) }
            guard let m = Int(args.split(separator: " ").first ?? ""), m == 0 || m == 1 else {
                throw fail("fullscreen: mode must be 0 (fullscreen) or 1 (maximize)")
            }
            return .fullscreen(mode: m)
        case "togglesplit":
            return .toggleSplit
        case "togglelayout":
            return .toggleLayout
        case "pseudo":
            return .pseudo
        case "movefocus":
            return .moveFocus(try direction())
        case "swapwindow", "movewindow":
            return .swapWindow(try direction())
        case "workspace":
            return .workspace(try workspaceTarget())
        case "movetoworkspace":
            return .moveToWorkspace(try workspaceTarget(), silent: false)
        case "movetoworkspacesilent":
            return .moveToWorkspace(try workspaceTarget(), silent: true)
        case "resizeactive":
            let parts = args.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            guard parts.count == 2, let dx = Double(parts[0]), let dy = Double(parts[1]) else {
                throw fail("resizeactive: expected 'dx dy' in points, e.g. '-100 0'")
            }
            return .resizeActive(dx: dx, dy: dy)
        case "cyclenext":
            let a = args.lowercased()
            return .cycleNext(previous: a == "prev" || a == "previous" || a == "b")
        case "focusmonitor":
            return .focusMonitor(try direction())
        case "centerwindow":
            return .centerWindow
        case "reload":
            return .reload
        case "showkeys":
            return .showKeys
        case "exit":
            return .exit
        default:
            throw fail("unknown dispatcher '\(rawDispatcher.trimmingCharacters(in: .whitespaces))'")
        }
    }

    /// Short human description used by the key binding overlay when `bindd` gave none.
    public var summary: String {
        switch self {
        case .exec(let c): return "Run \(c)"
        case .newWindow(let a): return "New \(a) window"
        case .killActive: return "Close window"
        case .toggleFloating: return "Toggle floating"
        case .fullscreen(let m): return m == 0 ? "Fullscreen" : "Maximize"
        case .toggleSplit: return "Toggle split"
        case .toggleLayout: return "Toggle scrolling layout"
        case .pseudo: return "Pseudo tile"
        case .moveFocus(let d): return "Focus \(d.rawValue)"
        case .swapWindow(let d): return "Swap \(d.rawValue)"
        case .workspace(let t): return "Workspace \(t.summary)"
        case .moveToWorkspace(let t, let silent): return "Move to workspace \(t.summary)\(silent ? " (silent)" : "")"
        case .resizeActive(let dx, let dy):
            if dy == 0 { return dx > 0 ? "Grow width" : "Shrink width" }
            if dx == 0 { return dy > 0 ? "Grow height" : "Shrink height" }
            return "Resize \(Int(dx)) \(Int(dy))"
        case .cycleNext(let p): return p ? "Previous window" : "Next window"
        case .focusMonitor(let d): return "Focus monitor \(d.rawValue)"
        case .centerWindow: return "Center window"
        case .reload: return "Reload config"
        case .showKeys: return "Show key bindings"
        case .exit: return "Quit Ikkunointi"
        }
    }

    /// Whether holding the key should repeat the action even without `binde`.
    public var repeatsByDefault: Bool {
        if case .resizeActive = self { return true }
        return false
    }
}

extension WorkspaceTarget {
    public var summary: String {
        switch self {
        case .number(let n): return "\(n)"
        case .relative(let n): return n > 0 ? "+\(n)" : "\(n)"
        case .existingRelative(let n): return n > 0 ? "next" : "previous"
        case .previous: return "back"
        }
    }
}
