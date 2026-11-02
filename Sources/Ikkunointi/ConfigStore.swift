import AppKit
import IkkunointiCore

/// Loads `~/.config/ikkunointi/ikkunointi.conf`, writes the default on first run and
/// reloads when the file changes (Hyprland-style auto reload).
final class ConfigStore {
    let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/ikkunointi", isDirectory: true)
    var fileURL: URL { directory.appendingPathComponent("ikkunointi.conf") }
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var reloadScheduled = false

    func load() -> Config {
        ensureExists()
        let dir = directory
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            // Keep working with the defaults rather than leaving the user without bindings.
            var c = Config.parse(defaultText())
            c.errors.insert(ConfigIssue(file: fileURL.path, line: 0, message: "cannot read config; using defaults"), at: 0)
            return c
        }
        return Config.parse(text, file: fileURL.path) { include in
            let expanded = (include as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : dir.appendingPathComponent(expanded)
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    func ensureExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? defaultText().write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func defaultText() -> String {
        DefaultConfig.text(terminal: Self.detectTerminal(), browser: Self.detectBrowser(), fileManager: "com.apple.finder")
    }

    static func detectTerminal() -> String {
        let candidates = ["com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
                          "com.googlecode.iterm2", "dev.warp.Warp-Stable"]
        return candidates.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? "com.apple.Terminal"
    }

    static func detectBrowser() -> String {
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
           let id = Bundle(url: url)?.bundleIdentifier {
            return id
        }
        return "com.apple.Safari"
    }

    func watch() {
        source?.cancel()
        source = nil
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.watch() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) {
                // Editors save atomically by replacing the file: follow the new inode.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.watch() }
            }
            self.scheduleReload()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadScheduled = false
            self?.onChange?()
        }
    }
}
