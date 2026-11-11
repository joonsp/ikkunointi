import AppKit
import Carbon
import IOKit.pwr_mgt
import IkkunointiCore
import ServiceManagement

/// Waybar-like workspace indicator in the menu bar, plus the app menu.
final class StatusBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    /// Separate click-to-toggle button: the main item's click is taken by the menu.
    private let awakeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var awakeAssertion: IOPMAssertionID?
    /// Switched on by hand (cup click); never persisted.
    private var manualAwake = false
    /// "Keep Awake While Claude Works": hold the screen awake only while an agent is busy.
    private var agentWorking = false
    private var agentTimer: Timer?
    private static let awakeAutoKey = "awakeWhileClaudeWorks"
    private var awakeAuto: Bool {
        get { UserDefaults.standard.bool(forKey: Self.awakeAutoKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.awakeAutoKey) }
    }
    /// Claude Code token usage, read from the local session transcripts.
    private let usageItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let usageMenu = NSMenu()
    private let usageScanner = ClaudeUsageScanner()
    private let usageQueue = DispatchQueue(label: "ikkunointi.claude-usage", qos: .utility)
    private var usageTimer: Timer?
    private var usageTick = 0
    private let claudeHook = ClaudeStatusLineHook()
    private static let claudeAskedKey = "claudeSettingsAsked"
    private var tokensToday: TokenUsage?
    private static let hideUsageKey = "hideClaudeUsage"
    private var showUsage: Bool {
        get { !UserDefaults.standard.bool(forKey: Self.hideUsageKey) }
        set { UserDefaults.standard.set(!newValue, forKey: Self.hideUsageKey) }
    }
    private static let compactKey = "compactIndicator"
    private var compact: Bool {
        get { UserDefaults.standard.bool(forKey: Self.compactKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.compactKey) }
    }

    var summaries: () -> [WorkspaceSummary] = { [] }
    var issues: () -> (errors: [ConfigIssue], warnings: [ConfigIssue]) = { ([], []) }
    var needsPermission = false
    /// False when the user switched window tiling off: only the menu bar utilities remain.
    var tilingEnabled = true
    var onSetTiling: ((Bool) -> Void)?
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
        awakeItem.autosaveName = "IkkunointiKeepAwake"
        awakeItem.button?.target = self
        awakeItem.button?.action = #selector(toggleAwake)
        applyAwakeAuto()
        usageItem.autosaveName = "IkkunointiClaudeUsage"
        usageMenu.autoenablesItems = false
        usageItem.menu = usageMenu
        if let button = usageItem.button {
            let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude token usage")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = "…"
        }
        applyUsageVisibility()
        render()
        // First run with Claude Code around: offer the settings change once, never do it unasked.
        if showUsage, !UserDefaults.standard.bool(forKey: Self.claudeAskedKey),
           claudeHook.isClaudeCodePresent, !claudeHook.isInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.claudeAskedKey)
                self?.offerClaudeSetup()
            }
        }
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
        if !tilingEnabled {
            let image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Ikkunointi (tiling off)")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Ikkunointi: window tiling is off"
            return
        }
        let alert = !issues().errors.isEmpty || Self.secureInputApp != nil
        // Compact, for narrow (notched) menu bars: the focused workspace plus whatever
        // the other displays are showing.
        let shown = compact ? summaries().filter { $0.isFocused || $0.isVisible } : summaries()
        button.image = Self.image(for: shown, alert: alert)
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
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let tiling = tilingEnabled && !needsPermission
        if needsPermission {
            addInfo("Ikkunointi needs Accessibility access to tile windows")
            add("Open Accessibility Settings…") { [weak self] in self?.onOpenAccessibility?() }
            menu.addItem(.separator())
        } else if tiling {
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
        }
        let tilingItem = add("Window Tiling") { [weak self] in
            guard let self else { return }
            self.onSetTiling?(!self.tilingEnabled)
        }
        tilingItem.state = tilingEnabled ? .on : .off
        if tiling {
            let compactItem = add("Compact Workspace Indicator") { [weak self] in
                guard let self else { return }
                self.compact.toggle()
                self.render()
            }
            compactItem.state = compact ? .on : .off
        }
        let awake = add("Keep Screen Awake") { [weak self] in self?.toggleAwake() }
        awake.state = manualAwake ? .on : .off
        let auto = add("Keep Awake While Claude Works") { [weak self] in
            guard let self else { return }
            self.awakeAuto.toggle()
            self.applyAwakeAuto()
        }
        auto.state = awakeAuto ? .on : .off
        let usage = add("Show Claude Token Usage") { [weak self] in
            guard let self else { return }
            self.showUsage.toggle()
            self.applyUsageVisibility()
        }
        usage.state = showUsage ? .on : .off
        if claudeHook.isInstalled {
            add("Restore Claude Settings…") { [weak self] in self?.offerClaudeRestore() }
        } else if claudeHook.isClaudeCodePresent {
            add("Modify Claude Settings…") { [weak self] in self?.offerClaudeSetup() }
        }
        if tiling {
            menu.addItem(.separator())
            add("Show Key Bindings") { [weak self] in self?.onShowKeys?() }
            add("Edit Config…") { [weak self] in self?.onEditConfig?() }
            add("Reveal Config in Finder") { [weak self] in self?.onRevealConfig?() }
            add("Reload Config") { [weak self] in self?.onReload?() }
            let (errors, warnings) = issues()
            if !errors.isEmpty { addIssues("⚠︎ \(errors.count) config error\(errors.count == 1 ? "" : "s")", errors) }
            if !warnings.isEmpty { addIssues("\(warnings.count) config warning\(warnings.count == 1 ? "" : "s")", warnings) }
        }
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

    /// The cup: keep the screen awake until clicked again. Never persisted.
    @objc private func toggleAwake() {
        manualAwake.toggle()
        updateAwake()
    }

    /// Starts or stops watching for agent activity.
    private func applyAwakeAuto() {
        agentTimer?.invalidate()
        agentTimer = nil
        agentWorking = false
        if awakeAuto {
            checkAgent()
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.checkAgent() }
            RunLoop.main.add(t, forMode: .common)
            agentTimer = t
        }
        updateAwake()
    }

    private func checkAgent() {
        usageQueue.async { [weak self] in
            let working = ClaudeActivity.isWorking()
            DispatchQueue.main.async {
                guard let self, self.awakeAuto, self.agentWorking != working else { return }
                self.agentWorking = working
                self.updateAwake()
            }
        }
    }

    /// Holds a power assertion that blocks idle display sleep (and with it idle system sleep)
    /// while the cup is on, or while an agent works in automatic mode. The kernel drops it
    /// if the app exits.
    private func updateAwake() {
        let want = manualAwake || (awakeAuto && agentWorking)
        if want, awakeAssertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Ikkunointi: keep screen awake" as CFString, &id)
            if result == kIOReturnSuccess {
                awakeAssertion = id
            } else {
                manualAwake = false
                NSSound.beep()
            }
        } else if !want, let id = awakeAssertion {
            IOPMAssertionRelease(id)
            awakeAssertion = nil
        }
        renderAwake()
    }

    private func renderAwake() {
        guard let button = awakeItem.button else { return }
        let on = awakeAssertion != nil
        let label: String
        if manualAwake {
            label = "Screen stays awake (click to allow sleep)"
        } else if on {
            label = "Screen stays awake while Claude Code is working"
        } else if awakeAuto {
            label = "Screen will stay awake while Claude Code works (click to keep it awake now)"
        } else {
            label = "Keep screen awake"
        }
        if let image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: label) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "☕"
        }
        // Dimmed: off. Outline: armed, waiting for an agent. Filled: holding the screen awake.
        button.appearsDisabled = !on && !awakeAuto
        button.toolTip = label
    }

    private func applyUsageVisibility() {
        usageItem.isVisible = showUsage
        usageTimer?.invalidate()
        usageTimer = nil
        guard showUsage else { return }
        usageTick = 0
        refreshUsage()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.refreshUsage() }
        RunLoop.main.add(t, forMode: .common)
        usageTimer = t
    }

    /// Explains the settings change and makes it only if the user agrees.
    private func offerClaudeSetup() {
        let alert = NSAlert()
        alert.messageText = "Let Ikkunointi modify Claude Code's settings?"
        alert.informativeText = [
            "Claude Code only reports how much of your plan is left to its status line. To show that in the menu bar, "
                + "Ikkunointi would change the statusLine command in ~/.claude/settings.json to run a small wrapper "
                + "(~/.config/ikkunointi/claude-statusline.sh).",
            "Your current status line keeps working as before, and a backup of the settings is saved next to the file. "
                + "You can undo this any time with “Restore Claude Settings…” in the Ikkunointi menu.",
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: "Modify Claude Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        report(claudeHook.install())
    }

    private func offerClaudeRestore() {
        let alert = NSAlert()
        alert.messageText = "Restore Claude Code's settings?"
        alert.informativeText = "This puts back the status line command you had before and removes Ikkunointi's wrapper. "
            + "The Claude usage indicator will stop updating."
        alert.addButton(withTitle: "Restore Claude Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        report(claudeHook.uninstall())
    }

    private func report(_ outcome: ClaudeStatusLineHook.Outcome) {
        NSLog("Ikkunointi: Claude settings: %@", "\(outcome)")
        if case .skipped(let reason) = outcome {
            let alert = NSAlert()
            alert.messageText = "Claude Code's settings were not changed"
            alert.informativeText = reason
            alert.runModal()
        }
        refreshUsage()
    }

    /// The limits file is tiny and read every tick; the transcripts only once a minute.
    private func refreshUsage() {
        let now = Date()
        let scanTokens = usageTick % 6 == 0
        usageTick += 1
        usageQueue.async { [weak self] in
            guard let self else { return }
            var limits = (try? Data(contentsOf: PlanLimits.fileURL)).flatMap(PlanLimits.parse)
            if limits?.updated == nil {
                limits?.updated = (try? PlanLimits.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            var today: TokenUsage?
            if scanTokens {
                let midnight = Calendar.current.startOfDay(for: now)
                today = ClaudeUsage.total(self.usageScanner.scan(since: midnight), since: midnight)
            }
            DispatchQueue.main.async {
                if let today { self.tokensToday = today }
                self.renderUsage(limits, now: now)
            }
        }
    }

    /// Normal above 25% left, then yellow through orange to red at 0%.
    private static func usageColor(left: Double) -> NSColor? {
        guard left <= 25 else { return nil }
        let t = CGFloat((25 - max(0, left)) / 12.5)   // 0 at 25%, 1 at 12.5%, 2 at 0%
        return t <= 1 ? NSColor.systemYellow.blended(withFraction: t, of: .systemOrange)
                      : NSColor.systemOrange.blended(withFraction: t - 1, of: .systemRed)
    }

    private func renderUsage(_ limits: PlanLimits?, now: Date) {
        usageMenu.removeAllItems()
        func info(_ title: String) {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            usageMenu.addItem(i)
        }
        defer {
            if let t = tokensToday {
                usageMenu.addItem(.separator())
                info("Tokens today on this Mac: \(ClaudeUsage.format(t.fresh))")
            }
        }
        guard let button = usageItem.button else { return }
        guard let limits, let left = limits.lowestLeft(at: now) else {
            button.contentTintColor = nil
            button.title = "–"
            button.toolTip = "Claude usage: no data yet"
            if claudeHook.isInstalled {
                info("No Claude usage data yet")
                info("It appears after the next reply in a Claude Code session")
                info("(needs a Claude subscription plan)")
            } else {
                info("Claude usage needs a change to Claude Code's settings")
                usageMenu.addItem(ClosureMenuItem(title: "Modify Claude Settings…") { [weak self] in self?.offerClaudeSetup() })
            }
            return
        }
        let text = "\(Int(left.rounded(.down)))%"
        let color = Self.usageColor(left: left)
        button.contentTintColor = color
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: color == nil ? .medium : .bold)]
        if let color { attrs[.foregroundColor] = color }
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        button.toolTip = "Claude usage left"
        let times = DateFormatter()
        times.dateFormat = "EEE HH:mm"
        func line(_ name: String, _ w: LimitWindow?) {
            guard let w else { return }
            let reset = now >= w.resetsAt ? "has reset" : "resets \(times.string(from: w.resetsAt))"
            info("\(name): \(Int(w.left(at: now).rounded(.down)))% left · \(reset)")
        }
        line("5-hour limit", limits.fiveHour)
        line("Weekly limit", limits.sevenDay)
        if let updated = limits.updated {
            let minutes = Int(now.timeIntervalSince(updated) / 60)
            info(minutes < 1 ? "Updated just now" : "Updated \(minutes) min ago (refreshes while Claude Code runs)")
        }
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
