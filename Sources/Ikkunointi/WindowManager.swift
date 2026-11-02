import AppKit
import ApplicationServices
import IkkunointiCore

/// Per-window bookkeeping on the Accessibility side.
final class WindowRecord {
    let id: CGWindowID
    let element: AXUIElement
    unowned let watcher: AppWatcher
    var title: String?
    /// Frame we last set; used to skip redundant AX calls.
    var lastApplied: CGRect?
    /// Frame the window actually had right after we set it (apps may clamp to a min size).
    var lastActual: CGRect?
    /// When we last moved it (to tell our own move notifications from the user's).
    var lastAppliedAt = Date.distantPast
    /// Sitting off-screen because its workspace is hidden.
    var isParked = false

    init(id: CGWindowID, element: AXUIElement, watcher: AppWatcher) {
        self.id = id
        self.element = element
        self.watcher = watcher
    }
}

private struct DragState {
    let id: CGWindowID
    let action: MouseAction
    let start: CGPoint
    let startFrame: CGRect
    let horizontalEdge: Edge
    let verticalEdge: Edge
    let floating: Bool
}

struct WorkspaceSummary {
    let id: Int
    let windowCount: Int
    let isFocused: Bool
    let isVisible: Bool
    let apps: [String]
}

/// The imperative shell around `WMState`: watches apps through the Accessibility API,
/// feeds events into the model and applies the resulting placements.
final class WindowManager {
    let state = WMState()
    private(set) var config = Config()
    private(set) var watchers: [pid_t: AppWatcher] = [:]
    private(set) var records: [CGWindowID: WindowRecord] = [:]
    let border = BorderWindow()
    let keysPanel = KeysPanel()

    /// Called (coalesced) whenever workspaces or focus change; drives the menu bar.
    var onChange: (() -> Void)?
    var onReloadRequest: (() -> Void)?
    /// Rows for the key binding overlay, prepared by the app delegate.
    var bindingRows: [(keys: String, description: String)] = []

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var started = false

    private var pendingSync = Set<pid_t>()
    private var pendingFocusCheck = false
    private var updateScheduled = false
    private var pendingWorkspaceSwitch: Int?
    private var pendingFocusWindow: CGWindowID?
    private var notifyScheduled = false
    private var screenChangeScheduled = false

    /// Focus we just requested; ignore stale focus reports until it lands.
    private var expectedFocus: (id: CGWindowID, until: Date)?
    /// After a close/minimize/hide macOS picks a new key window on its own, possibly one
    /// parked on a hidden workspace. Within this window such focus changes are undone
    /// instead of switching workspaces.
    private var autoFocusGuardUntil = Date.distantPast
    private var newWindowRequests: [pid_t: Date] = [:]

    private var drag: DragState?
    private var nativeDragWindow: CGWindowID?
    private var snapBackHistory: [CGWindowID: [Date]] = [:]

    // MARK: Lifecycle

    func start(config: Config) {
        guard !started else { return }
        started = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        apply(config: config)
        refreshMonitors()
        installObservers()
        adoptExistingWindows()
        refreshFocus()
        applyLayout()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func apply(config: Config) {
        self.config = config
        state.gapsIn = CGFloat(config.gapsIn)
        state.gapsOut = CGFloat(config.gapsOut)
        state.splitRatio = CGFloat(config.splitRatio)
        state.workspaceBackAndForth = config.workspaceBackAndForth
        border.configure(width: CGFloat(config.borderSize), radius: CGFloat(config.rounding), gradient: config.activeBorder)
        if started { applyLayout() }
    }

    /// Puts every parked window back on screen. Called on quit and on SIGTERM.
    func shutdown() {
        timer?.invalidate()
        border.hide()
        keysPanel.close()
        for rec in records.values where rec.isParked {
            guard let w = state.windows[rec.id] else { continue }
            let ws = state.workspace(w.workspace)
            let mon = state.monitor(ws.monitor) ?? state.primaryMonitor
            var target: CGRect?
            if w.isFloating {
                target = w.floatingFrame
            } else {
                target = state.tiledFramesIfShown(w.workspace)[rec.id]
            }
            if target.map({ !mon.frame.intersects($0) }) ?? true {
                target = mon.visibleFrame.centered(size: rec.element.size ?? CGSize(width: 900, height: 600))
            }
            if let t = target { setFrame(rec, t) }
        }
        for w in watchers.values { w.invalidate() }
    }

    private func installObservers() {
        let wnc = NSWorkspace.shared.notificationCenter
        func app(_ n: Notification) -> NSRunningApplication? {
            n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }
        observers.append(wnc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n) { self?.addApp(a) }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n) { self?.removeApp(a.processIdentifier) }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let a = app(n) else { return }
            if self.watchers[a.processIdentifier] == nil { self.addApp(a) }
            self.scheduleSync(a.processIdentifier)
            self.scheduleFocusCheck()
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let a = app(n) else { return }
            self.autoFocusGuardUntil = Date() + 0.6
            self.scheduleSync(a.processIdentifier)
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = app(n) { self?.scheduleSync(a.processIdentifier) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleScreensChanged()
        })
    }

    // MARK: Apps

    private func shouldManage(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != ownPID && !app.isTerminated
    }

    func addApp(_ app: NSRunningApplication) {
        guard shouldManage(app), watchers[app.processIdentifier] == nil else { return }
        let w = AppWatcher(app: app, manager: self)
        watchers[w.pid] = w
        subscribe(w, attempt: 0)
    }

    private func subscribe(_ w: AppWatcher, attempt: Int) {
        guard watchers[w.pid] === w, !w.app.isTerminated else { return }
        if w.subscribe() {
            for rec in records.values where rec.watcher === w { w.watch(rec.element, id: rec.id) }
            scheduleSync(w.pid)
            return
        }
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.subscribe(w, attempt: attempt + 1) }
    }

    private func removeApp(_ pid: pid_t) {
        guard let w = watchers.removeValue(forKey: pid) else { return }
        var suggestion: FocusTarget?
        for rec in records.values where rec.watcher === w {
            if let s = removeRecord(rec.id) { suggestion = s }
        }
        w.invalidate()
        newWindowRequests[pid] = nil
        autoFocusGuardUntil = Date() + 0.6
        if let suggestion { focus(suggestion, activateIfEmpty: false) }
        applyLayout()
    }

    private func adoptExistingWindows() {
        for app in NSWorkspace.shared.runningApplications where shouldManage(app) {
            let w = AppWatcher(app: app, manager: self)
            watchers[w.pid] = w
            if !w.subscribe() { subscribe(w, attempt: 1) }
        }
        var found: [(watcher: AppWatcher, element: AXUIElement, id: CGWindowID, frame: CGRect)] = []
        for w in watchers.values {
            for el in w.element.elements(kAXWindowsAttribute) ?? [] {
                guard let id = el.windowID, let f = el.frame else { continue }
                found.append((w, el, id, f))
            }
        }
        // Left-to-right, top-to-bottom so the initial dwindle order matches what was on screen.
        found.sort { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        for item in found {
            let mon = state.monitors.first { $0.frame.contains(item.frame.center) }
            adopt(item.element, id: item.id, watcher: item.watcher, workspace: mon.flatMap { state.activeWorkspace[$0.id] }, initial: true)
        }
    }

    // MARK: Windows

    private enum Kind { case tiled, floating }

    private func classify(_ el: AXUIElement) -> Kind? {
        guard el.string(kAXRoleAttribute) == kAXWindowRole else { return nil }
        guard let size = el.size, size.width >= 40, size.height >= 40 else { return nil }
        switch el.string(kAXSubroleAttribute) ?? "" {
        case kAXStandardWindowSubrole:
            return el.isSettable(kAXSizeAttribute) ? .tiled : .floating
        case kAXDialogSubrole, kAXFloatingWindowSubrole, kAXSystemDialogSubrole:
            return .floating
        default:
            return nil
        }
    }

    private func isOnScreen(_ f: CGRect) -> Bool {
        state.monitors.contains { m in
            let i = m.frame.intersection(f)
            return !i.isNull && i.width >= 40 && i.height >= 40
        }
    }

    private func adopt(_ el: AXUIElement, id: CGWindowID, watcher w: AppWatcher, workspace: Int?, initial: Bool) {
        guard records[id] == nil, let kind = classify(el) else { return }
        let title = el.string(kAXTitleAttribute)
        var floating = kind == .floating
        var ws = workspace
        var follow = false
        for rule in config.windowRules where rule.matches(bundleID: w.bundleID, appName: w.app.localizedName, title: title) {
            switch rule.effect {
            case .float: floating = true
            case .tile: floating = false
            case .workspace(let n, let silent):
                ws = n
                follow = !silent && !initial
            }
        }
        let rec = WindowRecord(id: id, element: el, watcher: w)
        rec.title = title
        var frame = el.frame
        if let f = frame, !isOnScreen(f) {
            // Left off-screen (e.g. parked by a previous run that crashed): bring it back.
            let mon = state.monitor(state.focusedMonitor) ?? state.primaryMonitor
            frame = mon.visibleFrame.centered(size: f.size).integralRounded
            rec.isParked = true
        }
        records[id] = rec
        w.watch(el, id: id)
        state.addWindow(id, pid: w.pid, floating: floating, workspace: ws, frame: frame)
        let excluded = w.app.isHidden || el.bool(kAXMinimizedAttribute) == true || el.bool("AXFullScreen") == true
        state.setExcluded(id, excluded)
        if follow, let ws { pendingWorkspaceSwitch = ws }
        if let t = newWindowRequests[w.pid], Date().timeIntervalSince(t) < 5 {
            newWindowRequests[w.pid] = nil
            pendingFocusWindow = id
        }
    }

    @discardableResult
    private func removeRecord(_ id: CGWindowID) -> FocusTarget? {
        guard let rec = records.removeValue(forKey: id) else { return nil }
        rec.watcher.unwatch(id)
        snapBackHistory[id] = nil
        if drag?.id == id { drag = nil }
        if nativeDragWindow == id { nativeDragWindow = nil }
        return state.removeWindow(id)
    }

    private func syncApp(_ w: AppWatcher) {
        if w.app.isTerminated {
            removeApp(w.pid)
            return
        }
        guard let elements = w.element.elements(kAXWindowsAttribute) else { return }
        var seen = Set<CGWindowID>()
        var suggestion: FocusTarget?
        let hidden = w.app.isHidden
        for el in elements {
            guard let id = el.windowID else { continue }
            seen.insert(id)
            if records[id] != nil {
                let excluded = hidden || el.bool(kAXMinimizedAttribute) == true || el.bool("AXFullScreen") == true
                let wasExcluded = state.windows[id]?.isExcluded ?? false
                if let s = state.setExcluded(id, excluded) { suggestion = s }
                // Back from native fullscreen / another Space / ⌘H: place it again.
                if wasExcluded && !excluded { records[id]?.lastApplied = nil }
            } else {
                adopt(el, id: id, watcher: w, workspace: nil, initial: false)
            }
        }
        for rec in records.values where rec.watcher === w && !seen.contains(rec.id) {
            if WindowList.exists(rec.id) {
                // On another macOS Space or in native fullscreen: keep its slot, stop tiling it.
                if let s = state.setExcluded(rec.id, true) { suggestion = s }
            } else if let s = removeRecord(rec.id) {
                suggestion = s
            }
        }
        if let suggestion {
            autoFocusGuardUntil = Date() + 0.6
            focus(suggestion, activateIfEmpty: false)
        }
    }

    // MARK: Events

    func handleAX(_ name: String, element: AXUIElement, watcher w: AppWatcher) {
        switch name {
        case kAXWindowCreatedNotification:
            scheduleSync(w.pid)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            scheduleFocusCheck()
        case kAXUIElementDestroyedNotification:
            guard let id = w.windowID(for: element), records[id] != nil else { return }
            autoFocusGuardUntil = Date() + 0.6
            if let s = removeRecord(id) { focus(s, activateIfEmpty: false) }
            scheduleLayout()
        case kAXWindowMiniaturizedNotification:
            guard let id = w.windowID(for: element) else { return }
            autoFocusGuardUntil = Date() + 0.6
            if let s = state.setExcluded(id, true) { focus(s, activateIfEmpty: false) }
            scheduleLayout()
        case kAXWindowDeminiaturizedNotification:
            guard let id = w.windowID(for: element) else { return }
            state.setExcluded(id, false)
            records[id]?.lastApplied = nil
            scheduleLayout()
            scheduleFocusCheck()
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = w.windowID(for: element) { frameChanged(id) }
        default:
            break
        }
    }

    private func frameChanged(_ id: CGWindowID) {
        guard let rec = records[id], let w = state.windows[id], !w.isExcluded else { return }
        if drag?.id == id { return }
        guard let actual = rec.element.frame else { return }
        // Our own move echoing back (or a no-op notification): nothing to do.
        if let la = rec.lastActual, actual.isApproximately(la, tolerance: 1) { return }
        if rec.isParked {
            // Some apps pull their windows back on screen when activated; push it away again.
            if isOnScreen(actual), allowSnapBack(id) {
                rec.isParked = false
                scheduleLayout()
            }
            return
        }
        if w.isFloating {
            state.setFloatingFrame(id, actual)
            rec.lastActual = actual
            if id == state.focusedWindow { updateBorder(frame: actual) }
            return
        }
        if let target = rec.lastApplied, actual.isApproximately(target, tolerance: 1) {
            rec.lastActual = actual
            return
        }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            // The user is dragging/resizing a tile by its title bar or edge; resolved on mouse up.
            nativeDragWindow = id
            if id == state.focusedWindow { updateBorder(frame: actual) }
            return
        }
        // The app moved its own tile: snap it back, but don't fight forever.
        guard allowSnapBack(id) else { return }
        rec.lastApplied = nil
        scheduleLayout()
    }

    private func allowSnapBack(_ id: CGWindowID) -> Bool {
        let now = Date()
        var history = (snapBackHistory[id] ?? []).filter { now.timeIntervalSince($0) < 3 }
        defer { snapBackHistory[id] = history }
        guard history.count < 4 else { return false }
        history.append(now)
        return true
    }

    private func scheduleSync(_ pid: pid_t) {
        pendingSync.insert(pid)
        scheduleUpdate()
    }

    private func scheduleFocusCheck() {
        pendingFocusCheck = true
        scheduleUpdate()
    }

    private func scheduleLayout() {
        scheduleUpdate()
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.flush() }
    }

    /// Processes queued syncs and focus checks. Also called before every action so the
    /// model reflects the latest clicks.
    func flush() {
        updateScheduled = false
        let pids = pendingSync
        pendingSync.removeAll()
        // Only real focus/activation events may follow a window to another workspace;
        // a sync (e.g. from the timer) just reconciles.
        let followFocus = pendingFocusCheck
        let passiveCheck = !pids.isEmpty
        pendingFocusCheck = false
        for pid in pids { if let w = watchers[pid] { syncApp(w) } }
        if let ws = pendingWorkspaceSwitch {
            pendingWorkspaceSwitch = nil
            switchWorkspace(ws)
        }
        if followFocus || passiveCheck { refreshFocus(allowFollow: followFocus) }
        applyLayout()
        if let id = pendingFocusWindow {
            pendingFocusWindow = nil
            focusWindow(id)
        }
    }

    private func tick() {
        for app in NSWorkspace.shared.runningApplications where shouldManage(app) && watchers[app.processIdentifier] == nil {
            addApp(app)
        }
        if let front = NSWorkspace.shared.frontmostApplication, watchers[front.processIdentifier] != nil {
            scheduleSync(front.processIdentifier)
        }
        notifyChange()
    }

    // MARK: Focus

    /// Reads the real focused window from macOS and reconciles the model with it.
    /// `allowFollow`: a focused window on a hidden workspace switches to that workspace
    /// (⌘Tab, Dock). Without it, focus is pulled back to the current workspace instead.
    private func refreshFocus(allowFollow: Bool = true) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.processIdentifier == ownPID { return }
        guard let w = watchers[front.processIdentifier],
              let el = w.element.element(kAXFocusedWindowAttribute),
              let id = el.windowID,
              let win = state.windows[id], !win.isExcluded else {
            if expectedFocus.map({ Date() < $0.until }) ?? false { return }
            if state.focusedWindow != nil {
                state.clearFocus(monitor: monitorUnderMouse())
                updateBorder()
                notifyChange()
            }
            return
        }
        if let expected = expectedFocus {
            if expected.id == id {
                expectedFocus = nil
            } else if Date() < expected.until {
                return
            } else {
                expectedFocus = nil
            }
        }
        if id == state.focusedWindow {
            updateBorder()
            return
        }
        if !state.isVisible(win.workspace) {
            if !allowFollow || Date() < autoFocusGuardUntil {
                focus(state.focusTarget(for: state.focusedWorkspace))
                return
            }
            // ⌘Tab, Dock click, notification...: follow the window to its workspace.
            let home = state.workspace(win.workspace).monitor
            state.switchToWorkspace(win.workspace, on: home)
        }
        state.noteFocused(id)
        applyLayout()
    }

    /// `activateIfEmpty`: on an empty workspace make ourselves frontmost so typing can't land
    /// in a window parked off-screen. Not done after a close, where the app should stay active.
    func focus(_ target: FocusTarget, activateIfEmpty: Bool = true) {
        switch target {
        case .window(let id):
            focusWindow(id)
        case .emptyMonitor(let m):
            state.clearFocus(monitor: m)
            expectedFocus = nil
            if activateIfEmpty {
                WindowFocus.activate(pid: ownPID)
                NSApp.activate(ignoringOtherApps: true)
            }
            updateBorder()
            notifyChange()
        }
    }

    func focusWindow(_ id: CGWindowID) {
        guard let rec = records[id] else { return }
        state.noteFocused(id)
        expectedFocus = (id, Date() + 0.6)
        WindowFocus.focus(pid: rec.watcher.pid, windowID: id, element: rec.element)
        updateBorder()
        notifyChange()
    }

    func switchWorkspace(_ n: Int) {
        guard let target = state.switchToWorkspace(n) else { return }
        // A late focus report for a window we just parked must not bounce us back.
        autoFocusGuardUntil = Date() + 1.0
        applyLayout()
        focus(target)
    }

    // MARK: Layout

    /// Applies `state.placements()`: parks hidden windows first, then moves visible ones.
    /// `force` re-applies frames even when we believe they are already correct.
    func applyLayout(force: Set<CGWindowID> = []) {
        let placements = state.placements()
        var hides: [(WindowRecord, MonitorID)] = []
        var shows: [(WindowRecord, CGRect?)] = []
        for (id, p) in placements {
            guard let rec = records[id] else { continue }
            switch p {
            case .frame(let r):
                if rec.isParked || force.contains(id) || !(rec.lastApplied?.isApproximately(r) ?? false) {
                    shows.append((rec, r))
                }
            case .floating(let r):
                if rec.isParked || force.contains(id) { shows.append((rec, r)) }
            case .hidden(let m):
                if !rec.isParked { hides.append((rec, m)) }
            case .excluded:
                break
            }
        }
        if !hides.isEmpty || !shows.isEmpty {
            var enhanced: [pid_t: Bool] = [:]
            func prepare(_ w: AppWatcher) {
                guard enhanced[w.pid] == nil else { return }
                // Chromium/Electron animate AX frame changes while "enhanced UI" is on.
                let on = w.element.bool("AXEnhancedUserInterface") == true
                if on { w.element.set("AXEnhancedUserInterface", kCFBooleanFalse) }
                enhanced[w.pid] = on
            }
            for (rec, m) in hides {
                prepare(rec.watcher)
                if state.windows[rec.id]?.isFloating == true, let f = rec.element.frame, isOnScreen(f) {
                    state.setFloatingFrame(rec.id, f)
                }
                park(rec, on: m)
            }
            for (rec, r) in shows {
                prepare(rec.watcher)
                if let r {
                    setFrame(rec, r)
                } else {
                    let w = state.windows[rec.id]
                    let mon = state.monitor(w.flatMap { state.monitorShowing($0.workspace) }) ?? state.primaryMonitor
                    let f = mon.visibleFrame.centered(size: rec.element.size ?? CGSize(width: 800, height: 600)).integralRounded
                    setFrame(rec, f)
                    state.setFloatingFrame(rec.id, f)
                }
            }
            for (pid, on) in enhanced where on {
                watchers[pid]?.element.set("AXEnhancedUserInterface", kCFBooleanTrue)
            }
        }
        updateBorder()
        notifyChange()
    }

    private func setFrame(_ rec: WindowRecord, _ r: CGRect) {
        let el = rec.element
        rec.lastAppliedAt = Date()
        defer {
            rec.lastApplied = r
            rec.lastActual = el.frame
            rec.isParked = false
            rec.lastAppliedAt = Date()
        }
        if !rec.isParked, let cur = el.frame {
            if cur.isApproximately(r, tolerance: 0.5) { return }
            if abs(cur.width - r.width) < 0.5, abs(cur.height - r.height) < 0.5 {
                el.setPosition(r.origin)
                return
            }
            if abs(cur.minX - r.minX) < 0.5, abs(cur.minY - r.minY) < 0.5 {
                el.setSize(r.size)
                return
            }
        }
        // Size, position, size: the first resize can be clamped at the old position.
        el.setSize(r.size)
        el.setPosition(r.origin)
        el.setSize(r.size)
    }

    private func park(_ rec: WindowRecord, on monitorID: MonitorID) {
        let mon = state.monitor(monitorID) ?? state.primaryMonitor
        let size = rec.element.size ?? CGSize(width: 800, height: 600)
        rec.element.setPosition(parkPoint(mon, size))
        rec.isParked = true
        rec.lastApplied = nil
        rec.lastActual = rec.element.frame
        rec.lastAppliedAt = Date()
    }

    /// AeroSpace-style hiding: macOS won't let a window go fully off-screen, so we leave a
    /// 1pt sliver in the bottom corner that doesn't spill onto a neighbouring monitor.
    private func parkPoint(_ m: Monitor, _ size: CGSize) -> CGPoint {
        let v = m.visibleFrame
        let right = CGPoint(x: v.maxX - 1, y: v.maxY - 1)
        let left = CGPoint(x: v.minX - size.width + 1, y: v.maxY - 1)
        let others = state.monitors.filter { $0.id != m.id }
        func spill(_ p: CGPoint) -> CGFloat {
            others.reduce(0) { $0 + $1.frame.overlapArea(CGRect(origin: p, size: size)) }
        }
        return spill(right) <= spill(left) ? right : left
    }

    func updateBorder(frame override: CGRect? = nil) {
        guard config.borderSize > 0, let id = state.focusedWindow, let rec = records[id], let w = state.windows[id],
              !w.isExcluded, !rec.isParked, state.isVisible(w.workspace) else {
            border.hide()
            return
        }
        if let fs = state.workspace(w.workspace).fullscreen, fs.id == id, fs.mode == 0 {
            border.hide()
            return
        }
        guard let f = override ?? rec.element.frame else {
            border.hide()
            return
        }
        border.show(around: f)
    }

    // MARK: Monitors

    private func monitorUnderMouse() -> MonitorID? {
        let p = NSEvent.mouseLocation.flippedScreenCoordinates
        return state.monitors.first { $0.frame.contains(p) }?.id
    }

    func refreshMonitors() {
        let monitors = NSScreen.screens.map { s -> Monitor in
            let number = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return Monitor(id: number?.uint32Value ?? 0, frame: s.frame.flippedScreenCoordinates,
                           visibleFrame: s.visibleFrame.flippedScreenCoordinates, name: s.localizedName)
        }
        state.setMonitors(monitors)
    }

    private func scheduleScreensChanged() {
        guard !screenChangeScheduled else { return }
        screenChangeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.screenChangeScheduled = false
            self.refreshMonitors()
            // macOS may have shoved windows around while displays changed: re-apply everything.
            let placements = self.state.placements()
            for rec in self.records.values {
                if rec.isParked, case .hidden(let m)? = placements[rec.id] { self.park(rec, on: m) } else { rec.lastApplied = nil }
            }
            self.applyLayout()
        }
    }

    // MARK: Mouse

    func beginDrag(_ action: MouseAction, at point: CGPoint) {
        flush()
        guard let id = WindowList.windowID(at: point), let rec = records[id], let w = state.windows[id],
              !rec.isParked, let frame = rec.element.frame else { return }
        focusWindow(id)
        drag = DragState(id: id, action: action, start: point, startFrame: frame,
                         horizontalEdge: point.x < frame.midX ? .left : .right,
                         verticalEdge: point.y < frame.midY ? .top : .bottom,
                         floating: w.isFloating)
    }

    func continueDrag(to p: CGPoint) {
        guard let d = drag, let rec = records[d.id] else { return }
        let dx = p.x - d.start.x, dy = p.y - d.start.y
        switch d.action {
        case .move:
            let origin = CGPoint(x: d.startFrame.minX + dx, y: d.startFrame.minY + dy)
            rec.element.setPosition(origin)
            rec.lastAppliedAt = Date()
            updateBorder(frame: CGRect(origin: origin, size: d.startFrame.size))
        case .resize where d.floating:
            var f = d.startFrame
            if d.horizontalEdge == .right { f.size.width += dx } else { f.origin.x += dx; f.size.width -= dx }
            if d.verticalEdge == .bottom { f.size.height += dy } else { f.origin.y += dy; f.size.height -= dy }
            f.size.width = max(f.width, 120)
            f.size.height = max(f.height, 80)
            setFrame(rec, f.integralRounded)
            updateBorder()
        case .resize:
            let x = d.horizontalEdge == .right ? d.startFrame.maxX + dx : d.startFrame.minX + dx
            let y = d.verticalEdge == .bottom ? d.startFrame.maxY + dy : d.startFrame.minY + dy
            state.moveEdge(d.id, edge: d.horizontalEdge, to: x)
            state.moveEdge(d.id, edge: d.verticalEdge, to: y)
            applyLayout()
        }
    }

    func endDrag(at p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        guard let rec = records[d.id] else { return }
        if d.floating {
            if let f = rec.element.frame {
                state.setFloatingFrame(d.id, f)
                rec.lastActual = f
            }
            updateBorder()
            return
        }
        if d.action == .move {
            dropTile(d.id, at: p)
        } else {
            applyLayout(force: [d.id])
        }
    }

    /// Left mouse released without our drag: finish a native title-bar drag or edge resize of a tile.
    func mouseUp(at p: CGPoint) {
        guard let id = nativeDragWindow else { return }
        nativeDragWindow = nil
        guard let rec = records[id], let w = state.windows[id], !w.isFloating,
              let target = rec.lastApplied, let actual = rec.element.frame else {
            applyLayout(force: [id])
            return
        }
        if abs(actual.width - target.width) > 2 || abs(actual.height - target.height) > 2 {
            if abs(actual.minX - target.minX) > 2 { state.moveEdge(id, edge: .left, to: actual.minX) }
            if abs(actual.maxX - target.maxX) > 2 { state.moveEdge(id, edge: .right, to: actual.maxX) }
            if abs(actual.minY - target.minY) > 2 { state.moveEdge(id, edge: .top, to: actual.minY) }
            if abs(actual.maxY - target.maxY) > 2 { state.moveEdge(id, edge: .bottom, to: actual.maxY) }
            applyLayout(force: [id])
        } else {
            dropTile(id, at: p)
        }
    }

    /// A tile dropped by the mouse swaps with the tile under the cursor, or moves to the
    /// workspace of the monitor it was dropped on; otherwise it snaps back.
    private func dropTile(_ id: CGWindowID, at p: CGPoint) {
        guard let w = state.windows[id] else { return }
        let tiles = state.visibleFrames(tiledOnly: true)
        if let other = tiles.first(where: { $0.key != id && $0.value.contains(p) })?.key {
            state.swapWindows(id, other)
        } else if let m = state.monitors.first(where: { $0.frame.contains(p) }),
                  state.monitorShowing(w.workspace) != m.id, let ws = state.activeWorkspace[m.id] {
            state.moveWindow(id, toWorkspace: ws, follow: false)
            state.noteFocused(id)
        }
        applyLayout(force: [id])
        focusWindow(id)
    }

    // MARK: Actions

    func perform(_ action: Action) {
        flush()
        let focused = state.focusedWindow
        let rec = focused.flatMap { records[$0] }
        switch action {
        case .exec(let command):
            Shell.run(command)
        case .newWindow(let app):
            openNewWindow(app)
        case .killActive:
            closeFocusedWindow(rec)
        case .toggleFloating:
            guard let id = focused, let rec else { return }
            state.toggleFloating(id, currentFrame: rec.element.frame)
            applyLayout(force: [id])
            rec.element.perform(kAXRaiseAction)
        case .fullscreen(let mode):
            guard let id = focused, let rec else { return }
            state.toggleFullscreen(id, mode: mode)
            applyLayout(force: [id])
            rec.element.perform(kAXRaiseAction)
            updateBorder()
        case .toggleSplit:
            guard let id = focused else { return }
            state.toggleSplit(id)
            applyLayout()
        case .pseudo:
            guard let id = focused else { return }
            state.togglePseudo(id)
            applyLayout()
        case .moveFocus(let dir):
            if let t = state.neighbor(of: focused, dir) { focus(t) }
        case .swapWindow(let dir):
            guard let id = focused, state.swapInDirection(id, dir) else { return }
            applyLayout()
            focusWindow(id)
        case .workspace(let target):
            if let n = state.resolve(target) { switchWorkspace(n) }
        case .moveToWorkspace(let target, let silent):
            guard let n = state.resolve(target) else { return }
            guard let id = focused else {
                if !silent { switchWorkspace(n) }
                return
            }
            let next = state.moveWindow(id, toWorkspace: n, follow: !silent)
            autoFocusGuardUntil = Date() + 1.0
            applyLayout()
            if let next { focus(next) }
        case .resizeActive(let dx, let dy):
            guard let id = focused, let rec, let w = state.windows[id] else { return }
            if w.isFloating {
                guard var f = rec.element.frame else { return }
                f.size.width = max(120, f.width + dx)
                f.size.height = max(80, f.height + dy)
                setFrame(rec, f)
                state.setFloatingFrame(id, f)
                updateBorder()
            } else {
                state.resizeTiled(id, dx: CGFloat(dx), dy: CGFloat(dy))
                applyLayout()
            }
        case .cycleNext(let previous):
            if let id = state.cycle(previous: previous) { focusWindow(id) }
        case .focusMonitor(let dir):
            if let t = state.focusMonitor(dir) { focus(t) }
        case .centerWindow:
            guard let id = focused, let rec, let w = state.windows[id], w.isFloating, let f = rec.element.frame else { return }
            let mon = state.monitor(state.monitorShowing(w.workspace)) ?? state.primaryMonitor
            let c = mon.visibleFrame.centered(size: f.size).integralRounded
            setFrame(rec, c)
            state.setFloatingFrame(id, c)
            updateBorder()
        case .reload:
            onReloadRequest?()
        case .showKeys:
            let mon = state.monitor(state.focusedMonitor) ?? state.primaryMonitor
            keysPanel.toggle(rows: bindingRows, around: mon.visibleFrame.flippedScreenCoordinates)
        case .exit:
            NSApp.terminate(nil)
        }
    }

    private func closeFocusedWindow(_ rec: WindowRecord?) {
        var window = rec?.element
        var pid = rec?.watcher.pid
        if window == nil, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            // Unmanaged window (dialog, panel): close whatever macOS has focused.
            window = AXUIElementCreateApplication(front.processIdentifier).element(kAXFocusedWindowAttribute)
            pid = front.processIdentifier
        }
        guard let window, let pid else { return NSSound.beep() }
        if let button = window.element(kAXCloseButtonAttribute), button.perform(kAXPressAction) == .success { return }
        KeyStroke.send(KeyboardLayout.shared.keyCode(for: "w") ?? 13, flags: .maskCommand, to: pid)
    }

    /// Opens a new window of an app: ⌘N if it is running, launch otherwise.
    private func openNewWindow(_ spec: String) {
        let wanted = spec.lowercased()
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased() == wanted || $0.localizedName?.lowercased() == wanted
        }), !app.isTerminated {
            let pid = app.processIdentifier
            newWindowRequests[pid] = Date()
            WindowFocus.activate(pid: pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                KeyStroke.send(KeyboardLayout.shared.keyCode(for: "n") ?? 45, flags: .maskCommand, to: pid)
            }
            return
        }
        guard let url = Self.applicationURL(spec) else {
            NSLog("Ikkunointi: newwindow: no app named '%@'", spec)
            return NSSound.beep()
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { [weak self] app, _ in
            guard let app else { return }
            DispatchQueue.main.async { self?.newWindowRequests[app.processIdentifier] = Date() }
        }
    }

    static func applicationURL(_ spec: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spec) { return url }
        let name = spec.hasSuffix(".app") ? spec : spec + ".app"
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: Status

    private func notifyChange() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.notifyScheduled = false
            self?.onChange?()
        }
    }

    func workspaceSummaries() -> [WorkspaceSummary] {
        let focusedWS = state.focusedWorkspace
        var ids = Set(1...5)
        for ws in state.workspaces.values where !ws.isEmpty { ids.insert(ws.id) }
        for ws in state.activeWorkspace.values { ids.insert(ws) }
        return ids.sorted().map { id in
            let ws = state.workspace(id)
            let apps = ws.windowIDs.compactMap { records[$0]?.watcher.name }
            var unique: [String] = []
            for a in apps where !unique.contains(a) { unique.append(a) }
            return WorkspaceSummary(id: id, windowCount: ws.windowIDs.count, isFocused: id == focusedWS,
                                    isVisible: state.isVisible(id), apps: unique)
        }
    }
}

enum Shell {
    /// Runs a command like Hyprland's `exec`, with Homebrew paths added to PATH.
    static func run(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("Ikkunointi: exec failed: %@", "\(error)") }
    }
}

enum KeyStroke {
    /// Sends a key chord straight to one process (bypasses our own event tap).
    static func send(_ code: UInt16, flags: CGEventFlags, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
