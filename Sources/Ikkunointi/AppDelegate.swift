import AppKit
import ApplicationServices
import Carbon
import IkkunointiCore

final class AppDelegate: NSObject, NSApplicationDelegate, EventTapDelegate {
    private let configStore = ConfigStore()
    private let manager = WindowManager()
    private let tap = EventTap()
    private let statusBar = StatusBar()
    private let ipc = IPCServer(path: IPC.socketPath)
    private var permissionTimer: Timer?
    private var running = false
    private var cleanedUp = false
    private var signalSources: [DispatchSourceSignal] = []
    private var layoutObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSLog("Ikkunointi is already running")
            NSApp.terminate(nil)
            return
        }
        installSignalHandlers()
        wireStatusBar()
        tap.delegate = self
        manager.onChange = { [weak self] in self?.statusBar.render() }
        manager.onReloadRequest = { [weak self] in self?.reloadConfig() }

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            startManaging()
        } else {
            statusBar.needsPermission = true
            statusBar.render()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startManaging()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    private func startManaging() {
        guard !running else { return }
        running = true
        statusBar.needsPermission = false
        let config = configStore.load()
        manager.start(config: config)
        applyInput(config)
        startTap()
        do {
            try ipc.start { [weak self] args in self?.manager.handleIPC(args) ?? "error: shutting down" }
        } catch {
            NSLog("Ikkunointi: IPC disabled: %@", "\(error)")
        }
        configStore.onChange = { [weak self] in self?.reloadConfig() }
        configStore.watch()
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            KeyboardLayout.shared.reload()
            self.applyInput(self.manager.config)
        }
        config.execOnce.forEach(Shell.run)
        config.exec.forEach(Shell.run)
        statusBar.render()
    }

    /// The tap can fail right after permission is granted; keep trying.
    private func startTap() {
        guard !tap.start() else { return }
        NSLog("Ikkunointi: could not create the event tap yet; retrying")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startTap() }
    }

    private func reloadConfig() {
        guard running else { return }
        let config = configStore.load()
        manager.apply(config: config)
        applyInput(config)
        config.exec.forEach(Shell.run)
        statusBar.render()
    }

    /// Resolves bindings against the current keyboard layout and hands them to the tap.
    private func applyInput(_ config: Config) {
        if config.superKey == .capslock { CapsLockRemap.enable() } else { CapsLockRemap.disable() }
        let layout = KeyboardLayout.shared
        var keys: [KeyCombo: TapBinding] = [:]
        var rows: [(keys: String, description: String)] = []
        for b in config.keyBindings {
            guard let code = layout.resolve(b.key) else { continue }
            let mods = config.superKey.normalize(b.mods)
            keys[KeyCombo(code: code, mods: mods)] = TapBinding(action: b.action, repeats: b.repeats)
            rows.append((mods.symbols(superKey: config.superKey) + " " + layout.label(for: code), b.description ?? b.action.summary))
        }
        var mouse: [MouseCombo: MouseAction] = [:]
        for m in config.mouseBindings {
            let mods = config.superKey.normalize(m.mods)
            mouse[MouseCombo(button: m.button, mods: mods)] = m.action
            let button = m.button == .left ? "drag" : m.button == .right ? "right-drag" : "middle-drag"
            rows.append((mods.symbols(superKey: config.superKey) + " " + button, m.action == .move ? "Move window" : "Resize window"))
        }
        tap.configure(keys: keys, mouse: mouse, superKey: config.superKey)
        manager.bindingRows = rows
    }

    private func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        if running { manager.shutdown() }
        CapsLockRemap.disable()
        ipc.stop()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.cleanup()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func wireStatusBar() {
        statusBar.summaries = { [weak self] in self?.manager.workspaceSummaries() ?? [] }
        statusBar.issues = { [weak self] in (self?.manager.config.errors ?? [], self?.manager.config.warnings ?? []) }
        statusBar.onSwitchWorkspace = { [weak self] n in self?.manager.perform(.workspace(.number(n))) }
        statusBar.onShowKeys = { [weak self] in self?.manager.perform(.showKeys) }
        statusBar.onEditConfig = { [weak self] in
            guard let self else { return }
            self.configStore.ensureExists()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-t", self.configStore.fileURL.path]
            try? p.run()
        }
        statusBar.onRevealConfig = { [weak self] in
            guard let self else { return }
            self.configStore.ensureExists()
            NSWorkspace.shared.activateFileViewerSelecting([self.configStore.fileURL])
        }
        statusBar.onReload = { [weak self] in self?.reloadConfig() }
        statusBar.onOpenAccessibility = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        statusBar.onQuit = { NSApp.terminate(nil) }
    }

    // MARK: EventTapDelegate

    func tapPerform(_ action: Action) { manager.perform(action) }
    func tapBeginDrag(_ action: MouseAction, at point: CGPoint) { manager.beginDrag(action, at: point) }
    func tapContinueDrag(to point: CGPoint) { manager.continueDrag(to: point) }
    func tapEndDrag(at point: CGPoint) { manager.endDrag(at: point) }
    func tapMouseUp(at point: CGPoint) { manager.mouseUp(at: point) }
}
