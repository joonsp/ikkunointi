import AppKit
import Carbon
import IkkunointiCore
import ServiceManagement

/// Waybar-like workspace indicator in the menu bar, plus the app menu.
final class StatusBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    var summaries: () -> [WorkspaceSummary] = { [] }
    var issues: () -> (errors: [ConfigIssue], warnings: [ConfigIssue]) = { ([], []) }
    var needsPermission = false
    var onSwitchWorkspace: ((Int) -> Void)?
    var onShowKeys: (() -> Void)?
    var onEditConfig: (() -> Void)?
    var onRevealConfig: (() -> Void)?
    var onReload: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageOnly
        render()
    }

    static var secureInputApp: String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        if let pid = dict?["kCGSSessionSecureInputPID"] as? Int,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            return app.localizedName ?? "another app"
        }
        return "another app"
    }

    func render() {
        guard let button = item.button else { return }
        if needsPermission {
            button.image = nil
            button.title = "Ikkunointi ⚠︎"
            button.imagePosition = .noImage
            return
        }
        button.title = ""
        button.imagePosition = .imageOnly
        let alert = !issues().errors.isEmpty || Self.secureInputApp != nil
        button.image = Self.image(for: summaries(), alert: alert)
        button.toolTip = Self.secureInputApp.map { "Secure input is on (\($0)): hotkeys are paused" }
    }

    private static func image(for workspaces: [WorkspaceSummary], alert: Bool) -> NSImage {
        let slot: CGFloat = 17, gap: CGFloat = 3, height: CGFloat = 17
        let alertWidth: CGFloat = alert ? 13 : 0
        let width = CGFloat(workspaces.count) * slot + CGFloat(max(0, workspaces.count - 1)) * gap + alertWidth
        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for ws in workspaces {
                let rect = NSRect(x: x, y: 0, width: slot, height: height)
                let label = "\(ws.id)" as NSString
                let font = NSFont.monospacedDigitSystemFont(ofSize: ws.id >= 10 ? 9 : 11, weight: ws.isFocused ? .heavy : .semibold)
                let alpha: CGFloat = ws.isFocused || ws.windowCount > 0 || ws.isVisible ? 1 : 0.35
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)]
                let size = label.size(withAttributes: attrs)
                let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.5)
                let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                if ws.isFocused {
                    NSColor.black.setFill()
                    pill.fill()
                    ctx.setBlendMode(.destinationOut)
                    label.draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.black])
                    ctx.setBlendMode(.normal)
                } else {
                    if ws.isVisible {
                        NSColor.black.setStroke()
                        pill.lineWidth = 1
                        pill.stroke()
                    }
                    label.draw(at: origin, withAttributes: attrs)
                }
                x += slot + gap
            }
            if alert {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.black]
                ("!" as NSString).draw(at: NSPoint(x: x + 2, y: 1), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if needsPermission {
            addInfo("Ikkunointi needs Accessibility access")
            add("Open Accessibility Settings…") { [weak self] in self?.onOpenAccessibility?() }
            menu.addItem(.separator())
            add("Quit Ikkunointi") { [weak self] in self?.onQuit?() }
            return
        }
        for ws in summaries() {
            let apps = ws.apps.isEmpty ? "empty" : ws.apps.joined(separator: ", ")
            let item = add("\(ws.id)   \(apps)") { [weak self] in self?.onSwitchWorkspace?(ws.id) }
            item.state = ws.isFocused ? .on : .off
        }
        menu.addItem(.separator())
        if let app = Self.secureInputApp {
            addInfo("⚠︎ Secure input is on (\(app)): hotkeys paused")
            menu.addItem(.separator())
        }
        add("Show Key Bindings") { [weak self] in self?.onShowKeys?() }
        add("Edit Config…") { [weak self] in self?.onEditConfig?() }
        add("Reveal Config in Finder") { [weak self] in self?.onRevealConfig?() }
        add("Reload Config") { [weak self] in self?.onReload?() }
        let (errors, warnings) = issues()
        if !errors.isEmpty { addIssues("⚠︎ \(errors.count) config error\(errors.count == 1 ? "" : "s")", errors) }
        if !warnings.isEmpty { addIssues("\(warnings.count) config warning\(warnings.count == 1 ? "" : "s")", warnings) }
        menu.addItem(.separator())
        let login = add("Launch at Login") { [weak self] in self?.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add("Quit Ikkunointi") { [weak self] in self?.onQuit?() }
    }

    private func addIssues(_ title: String, _ list: [ConfigIssue]) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for issue in list.prefix(40) {
            let i = NSMenuItem(title: issue.description, action: nil, keyEquivalent: "")
            i.isEnabled = false
            sub.addItem(i)
        }
        item.submenu = sub
        menu.addItem(item)
    }

    private func addInfo(_ title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }

    @discardableResult
    private func add(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        menu.addItem(item)
        return item
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}
