import Foundation

/// Claude Code only hands plan usage (`rate_limits`) to its status line command, so the
/// usage indicator needs a small wrapper there. This installs it into ~/.claude/settings.json
/// and takes it out again, keeping whatever status line was configured before.
/// Never called without the user's explicit go-ahead (the app asks first).
///
/// Layout under the home directory:
///   .config/ikkunointi/claude-statusline.sh        the wrapper Claude Code runs
///   .config/ikkunointi/claude-statusline.original  the user's previous command (empty: none)
///   .cache/ikkunointi/claude-rate-limits.json      latest status line input (see PlanLimits)
///   .claude/settings.json.ikkunointi-backup        settings as they were before the first edit
public struct ClaudeStatusLineHook {
    public enum Outcome: Equatable { case installed, alreadyInstalled, removed, notInstalled, skipped(String) }

    private let home: URL
    private var settingsURL: URL { home.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath() }
    private var configDir: URL { home.appendingPathComponent(".config/ikkunointi") }
    private var scriptURL: URL { configDir.appendingPathComponent("claude-statusline.sh") }
    private var originalURL: URL { configDir.appendingPathComponent("claude-statusline.original") }

    static let marker = "ikkunointi/claude-statusline.sh"
    static let command = #"sh "$HOME/.config/ikkunointi/claude-statusline.sh""#
    static let script = #"""
    #!/bin/sh
    # Installed by Ikkunointi with your permission (its menu has "Restore Claude Settings" to undo).
    # Saves Claude Code's status line input, which carries the plan's rate limits, for the menu
    # bar indicator, then runs the status line command that was configured before
    # (kept next to this file in claude-statusline.original).
    input=$(cat)
    case "$input" in
    *'"rate_limits"'*)
        dir="$HOME/.cache/ikkunointi"
        ( umask 077; mkdir -p "$dir" && printf '%s' "$input" > "$dir/.rate-limits.$$" \
            && mv -f "$dir/.rate-limits.$$" "$dir/claude-rate-limits.json" ) 2>/dev/null
        ;;
    esac
    orig="$(dirname "$0")/claude-statusline.original"
    if [ -s "$orig" ]; then
        printf '%s' "$input" | bash -c "$(cat "$orig")"
    fi
    exit 0

    """#

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Claude Code has been used on this machine.
    public var isClaudeCodePresent: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
    }

    /// The status line currently runs through our wrapper.
    public var isInstalled: Bool {
        ((readSettings()?["statusLine"] as? [String: Any])?["command"] as? String)?.contains(Self.marker) == true
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.ikkunointi-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
    }

    /// Wraps the current status line (or adds one that prints nothing). Does nothing when
    /// Claude Code is not set up on this machine or its settings can't be understood.
    @discardableResult
    public func install() -> Outcome {
        let fm = FileManager.default
        guard isClaudeCodePresent else { return .skipped("Claude Code is not installed") }
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            guard let s = readSettings() else { return .skipped("settings.json is not valid JSON") }
            settings = s
        }
        var line = settings["statusLine"] as? [String: Any] ?? ["type": "command"]
        if settings["statusLine"] != nil, settings["statusLine"] as? [String: Any] == nil { return .skipped("unexpected statusLine setting") }
        guard line["type"] as? String == "command" else { return .skipped("statusLine is not a command") }
        let current = line["command"] as? String ?? ""
        do {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            // Always refresh the script so app updates reach it.
            try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
            if current.contains(Self.marker) { return .alreadyInstalled }
            try Data(current.utf8).write(to: originalURL, options: .atomic)
            line["command"] = Self.command
            settings["statusLine"] = line
            try writeSettings(settings)
            return .installed
        } catch {
            return .skipped("\(error.localizedDescription)")
        }
    }

    /// Puts the previous status line back (or removes ours if there was none).
    @discardableResult
    public func uninstall() -> Outcome {
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: scriptURL)
            try? fm.removeItem(at: originalURL)
            try? fm.removeItem(at: home.appendingPathComponent(".cache/ikkunointi/claude-rate-limits.json"))
        }
        guard var settings = readSettings(), var line = settings["statusLine"] as? [String: Any],
              (line["command"] as? String)?.contains(Self.marker) == true else { return .notInstalled }
        let original = (try? String(contentsOf: originalURL, encoding: .utf8)) ?? ""
        if original.isEmpty {
            settings["statusLine"] = nil
        } else {
            line["command"] = original
            settings["statusLine"] = line
        }
        do { try writeSettings(settings) } catch { return .skipped("\(error.localizedDescription)") }
        return .removed
    }
}
