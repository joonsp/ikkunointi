import CoreGraphics

public struct WindowState: Equatable {
    public let id: WindowID
    public var pid: Int32
    public var workspace: Int
    public var isFloating: Bool
    /// Minimized, app hidden (⌘H) or in native fullscreen: kept in its slot but not laid out.
    public var isExcluded = false
    /// Last known frame while floating (restored when the workspace is shown again).
    public var floatingFrame: CGRect?
    public var isPseudo = false
    /// Size the window had when we first saw it; used by pseudo tiling.
    public var initialSize: CGSize?
}

public struct FullscreenState: Equatable {
    public var id: WindowID
    /// 0 = cover the monitor's usable area, 1 = maximize inside the outer gaps.
    public var mode: Int
}

public final class Workspace {
    public let id: Int
    public let tree = DwindleTree()
    public fileprivate(set) var floating: [WindowID] = []
    public fileprivate(set) var lastFocused: WindowID?
    public fileprivate(set) var fullscreen: FullscreenState?
    /// Monitor the workspace was last shown on.
    public fileprivate(set) var monitor: MonitorID?
    /// Scrolling layout; holds the same tiled windows as `tree`, so switching is instant.
    public let strip = ScrollStrip()
    /// Column the scrolling viewport keeps in view. Follows keyboard focus and clicks, but
    /// not hover focus, so focus-follows-mouse can't make the strip slide under the cursor.
    public fileprivate(set) var scrollAnchor: WindowID?
    /// Set by `togglelayout`; nil follows `general:layout`.
    public fileprivate(set) var layoutOverride: LayoutKind?

    init(id: Int, ratio: CGFloat, columnWidth: CGFloat) {
        self.id = id
        tree.defaultRatio = ratio
        strip.defaultWidth = columnWidth
    }

    public var windowIDs: [WindowID] { tree.windows + floating }
    public var isEmpty: Bool { tree.isEmpty && floating.isEmpty }
}

public struct Monitor: Equatable {
    public let id: MonitorID
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var name: String

    public init(id: MonitorID, frame: CGRect, visibleFrame: CGRect, name: String = "") {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.name = name
    }
}

public enum Placement: Equatable {
    /// Tiled, pseudo or fullscreen: the window must have exactly this frame.
    case frame(CGRect)
    /// Visible floating window: restore this frame if the window was parked, otherwise leave it.
    case floating(CGRect?)
    /// On a workspace that is not shown: park it off-screen at this monitor's corner.
    case hidden(MonitorID)
    /// Minimized / hidden app: leave it alone.
    case excluded
}

public enum FocusTarget: Equatable {
    case window(WindowID)
    /// The workspace on this monitor has nothing focusable.
    case emptyMonitor(MonitorID)
}

/// The window manager's model: workspaces, monitors, focus history. Pure logic;
/// the app shell applies `placements()` through the Accessibility API.
public final class WMState {
    public private(set) var windows: [WindowID: WindowState] = [:]
    public private(set) var workspaces: [Int: Workspace] = [:]
    public private(set) var monitors: [Monitor] = []
    public private(set) var activeWorkspace: [MonitorID: Int] = [:]
    public private(set) var focusedWindow: WindowID?
    public private(set) var focusedMonitor: MonitorID?
    public private(set) var previousWorkspace: Int?
    /// Most recently focused first.
    public private(set) var mru: [WindowID] = []

    public var gapsIn: CGFloat
    public var gapsOut: CGFloat
    public var splitRatio: CGFloat {
        didSet { workspaces.values.forEach { $0.tree.defaultRatio = splitRatio } }
    }
    public var workspaceBackAndForth: Bool
    /// `general:layout`: layout of workspaces that were not toggled.
    public var defaultLayout: LayoutKind = .dwindle
    /// `scrolling:column_width` for new columns.
    public var columnWidth: CGFloat = 0.5 {
        didSet { workspaces.values.forEach { $0.strip.defaultWidth = columnWidth } }
    }

    public init(gapsIn: CGFloat = 5, gapsOut: CGFloat = 10, splitRatio: CGFloat = 0.5, workspaceBackAndForth: Bool = false) {
        self.gapsIn = gapsIn
        self.gapsOut = gapsOut
        self.splitRatio = splitRatio
        self.workspaceBackAndForth = workspaceBackAndForth
    }

    // MARK: Lookups

    public func workspace(_ id: Int) -> Workspace {
        if let ws = workspaces[id] { return ws }
        let ws = Workspace(id: id, ratio: splitRatio, columnWidth: columnWidth)
        workspaces[id] = ws
        return ws
    }

    public func layout(of ws: Workspace) -> LayoutKind { ws.layoutOverride ?? defaultLayout }

    /// Tiled windows in layout order (strip order when scrolling).
    public func tiledOrder(_ ws: Workspace) -> [WindowID] {
        layout(of: ws) == .scrolling ? ws.strip.windows : ws.tree.windows
    }

    /// Omarchy SUPER+L: flip a workspace between dwindle and scrolling.
    public func toggleLayout(_ workspaceID: Int) {
        let ws = workspace(workspaceID)
        ws.layoutOverride = layout(of: ws) == .dwindle ? .scrolling : .dwindle
    }

    public func monitor(_ id: MonitorID?) -> Monitor? {
        guard let id else { return nil }
        return monitors.first { $0.id == id }
    }

    /// The monitor with the menu bar (origin at 0,0), or the first one.
    public var primaryMonitor: Monitor {
        monitors.first { $0.frame.origin == .zero } ?? monitors.first
            ?? Monitor(id: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    public func monitorShowing(_ workspace: Int) -> MonitorID? {
        activeWorkspace.first { $0.value == workspace }?.key
    }

    public func isVisible(_ workspace: Int) -> Bool { monitorShowing(workspace) != nil }

    public var focusedWorkspace: Int {
        if let m = focusedMonitor, let ws = activeWorkspace[m] { return ws }
        return activeWorkspace[primaryMonitor.id] ?? 1
    }

    public func isFocusable(_ id: WindowID) -> Bool {
        guard let w = windows[id] else { return false }
        return !w.isExcluded
    }

    /// Monitor a workspace lives on (shown there, or last shown there), falling back to the focused one.
    private func homeMonitor(for ws: Workspace) -> Monitor {
        monitor(monitorShowing(ws.id)) ?? monitor(ws.monitor) ?? monitor(focusedMonitor) ?? primaryMonitor
    }

    private func tilingArea(for ws: Workspace) -> CGRect {
        homeMonitor(for: ws).visibleFrame.insetBy(dx: gapsOut, dy: gapsOut)
    }

    /// Recomputes node rects so split orientation / resize math sees current geometry.
    private func refreshRects(_ ws: Workspace) {
        _ = ws.tree.layout(in: tilingArea(for: ws), gapsIn: gapsIn, include: { [unowned self] in self.isFocusable($0) })
    }

    // MARK: Monitors

    /// Installs the current monitor set; keeps workspace assignments for monitors that
    /// still exist and gives new monitors the lowest free workspace.
    public func setMonitors(_ newMonitors: [Monitor]) {
        let sorted = newMonitors.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let old = activeWorkspace
        monitors = sorted
        var active: [MonitorID: Int] = [:]
        for m in sorted { if let ws = old[m.id] { active[m.id] = ws } }
        for m in sorted where active[m.id] == nil {
            let used = Set(active.values)
            if let ws = workspaces.values.filter({ $0.monitor == m.id && !used.contains($0.id) }).map(\.id).min() {
                active[m.id] = ws
            } else {
                // Lowest workspace that is neither shown elsewhere nor holding windows.
                var n = 1
                while used.contains(n) || !(workspaces[n]?.isEmpty ?? true) { n += 1 }
                active[m.id] = n
            }
        }
        activeWorkspace = active
        for (m, ws) in active { workspace(ws).monitor = m }
        if monitor(focusedMonitor) == nil { focusedMonitor = primaryMonitor.id }
        // A display went away and took the focused window's workspace off screen: drop the
        // focus so nothing keeps acting on a parked window. The shell picks a new target.
        if let f = focusedWindow, let w = windows[f], !isVisible(w.workspace) { focusedWindow = nil }
    }

    // MARK: Windows

    /// Adds a window to `workspace` (default: the focused workspace).
    public func addWindow(_ id: WindowID, pid: Int32, floating: Bool, workspace requested: Int? = nil, frame: CGRect? = nil) {
        guard windows[id] == nil else { return }
        let wsID = requested ?? focusedWorkspace
        windows[id] = WindowState(id: id, pid: pid, workspace: wsID, isFloating: floating,
                                  floatingFrame: floating ? frame : nil, initialSize: frame?.size)
        insert(id, into: workspace(wsID))
    }

    private func insert(_ id: WindowID, into ws: Workspace) {
        guard let w = windows[id] else { return }
        if w.isFloating {
            if !ws.floating.contains(id) { ws.floating.append(id) }
            return
        }
        // A new tile ends fullscreen on that workspace so it is not opened invisibly behind it.
        if let fs = ws.fullscreen, windows[fs.id]?.isFloating == false { ws.fullscreen = nil }
        refreshRects(ws)
        let target = splitTarget(in: ws, excluding: id)
        ws.tree.insert(id, splitting: target, fallbackArea: tilingArea(for: ws))
        ws.strip.insert(id, after: target)
    }

    private func splitTarget(in ws: Workspace, excluding id: WindowID) -> WindowID? {
        func usable(_ c: WindowID) -> Bool { c != id && ws.tree.contains(c) && isFocusable(c) }
        if let lf = ws.lastFocused, usable(lf) { return lf }
        if let m = mru.first(where: usable) { return m }
        return ws.tree.windows.last(where: usable)
    }

    private func detach(_ id: WindowID, from ws: Workspace) {
        ws.tree.remove(id)
        ws.strip.remove(id)
        ws.floating.removeAll { $0 == id }
        if ws.lastFocused == id { ws.lastFocused = nil }
        if ws.scrollAnchor == id { ws.scrollAnchor = nil }
        if ws.fullscreen?.id == id { ws.fullscreen = nil }
    }

    /// Removes a window. Returns what should get focus if the removed window had it.
    @discardableResult
    public func removeWindow(_ id: WindowID) -> FocusTarget? {
        guard let w = windows.removeValue(forKey: id) else { return nil }
        let ws = workspace(w.workspace)
        detach(id, from: ws)
        mru.removeAll { $0 == id }
        guard focusedWindow == id else { return nil }
        focusedWindow = nil
        return isVisible(ws.id) ? focusTarget(for: ws.id) : nil
    }

    /// Marks a window minimized/hidden (or back). Returns a focus suggestion when the focused window disappears.
    @discardableResult
    public func setExcluded(_ id: WindowID, _ excluded: Bool) -> FocusTarget? {
        guard var w = windows[id], w.isExcluded != excluded else { return nil }
        w.isExcluded = excluded
        windows[id] = w
        guard excluded, focusedWindow == id else { return nil }
        focusedWindow = nil
        return isVisible(w.workspace) ? focusTarget(for: w.workspace) : nil
    }

    public func setFloatingFrame(_ id: WindowID, _ frame: CGRect) {
        guard var w = windows[id], w.isFloating else { return }
        w.floatingFrame = frame
        windows[id] = w
    }

    /// A floating window was dropped at `frame` by the mouse. If its center is on a monitor
    /// other than the one showing its workspace, it joins that monitor's workspace (keeping
    /// the frame). Returns true when it changed workspace.
    @discardableResult
    public func dropFloating(_ id: WindowID, frame: CGRect) -> Bool {
        guard let w = windows[id], w.isFloating else { return false }
        setFloatingFrame(id, frame)
        guard let from = monitorShowing(w.workspace),
              let to = monitors.first(where: { $0.frame.contains(frame.center) }), to.id != from,
              let ws = activeWorkspace[to.id] else { return false }
        let wasFocused = focusedWindow == id
        moveWindow(id, toWorkspace: ws, follow: false)
        // moveWindow maps the frame proportionally onto the new monitor; keep where it was dropped.
        setFloatingFrame(id, frame)
        if wasFocused { noteFocused(id) }
        return true
    }

    // MARK: Focus

    /// `scroll: false` (hover focus) leaves the scrolling viewport where it is.
    public func noteFocused(_ id: WindowID, scroll: Bool = true) {
        guard let w = windows[id] else { return }
        focusedWindow = id
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        let ws = workspace(w.workspace)
        ws.lastFocused = id
        if scroll, !w.isFloating { ws.scrollAnchor = id }
        if let m = monitorShowing(ws.id) { focusedMonitor = m }
        if let fs = ws.fullscreen, fs.id != id, !w.isFloating { ws.fullscreen = nil }
    }

    /// Focus left our managed windows (our own app, an unmanaged panel, nothing).
    public func clearFocus(monitor: MonitorID? = nil) {
        focusedWindow = nil
        if let monitor, self.monitor(monitor) != nil { focusedMonitor = monitor }
    }

    public func focusTarget(for workspaceID: Int) -> FocusTarget {
        let ws = workspace(workspaceID)
        if let lf = ws.lastFocused, isFocusable(lf), windows[lf]?.workspace == ws.id { return .window(lf) }
        if let m = mru.first(where: { windows[$0]?.workspace == ws.id && isFocusable($0) }) { return .window(m) }
        if let any = ws.windowIDs.first(where: isFocusable) { return .window(any) }
        return .emptyMonitor(monitorShowing(ws.id) ?? focusedMonitor ?? primaryMonitor.id)
    }

    private func applyFocus(_ t: FocusTarget) -> FocusTarget {
        switch t {
        case .window(let id): noteFocused(id)
        case .emptyMonitor(let m): clearFocus(monitor: m)
        }
        return t
    }

    // MARK: Workspaces

    public func resolve(_ target: WorkspaceTarget) -> Int? {
        let current = focusedWorkspace
        switch target {
        case .number(let n): return n
        case .relative(let d): return max(1, current + d)
        case .previous: return previousWorkspace
        case .existingRelative(let d):
            var ids = Set(workspaces.values.filter { !$0.isEmpty }.map(\.id))
            ids = ids.filter { monitorShowing($0) == nil || monitorShowing($0) == focusedMonitor }
            ids.insert(current)
            let sorted = ids.sorted()
            guard let i = sorted.firstIndex(of: current), !sorted.isEmpty else { return nil }
            return sorted[((i + d) % sorted.count + sorted.count) % sorted.count]
        }
    }

    /// Shows workspace `n` (on the focused monitor unless it is already visible elsewhere).
    /// Returns what should receive focus, or nil when nothing changed.
    /// `monitor` overrides where a hidden workspace appears (default: the focused monitor).
    @discardableResult
    public func switchToWorkspace(_ n: Int, on preferredMonitor: MonitorID? = nil) -> FocusTarget? {
        let current = focusedWorkspace
        var target = n
        if target == current {
            guard workspaceBackAndForth, let prev = previousWorkspace, prev != current else { return nil }
            target = prev
        }
        if let m = monitorShowing(target) {
            previousWorkspace = current
            focusedMonitor = m
            return applyFocus(focusTarget(for: target))
        }
        let m = monitor(preferredMonitor)?.id ?? focusedMonitor ?? primaryMonitor.id
        previousWorkspace = current
        activeWorkspace[m] = target
        workspace(target).monitor = m
        focusedMonitor = m
        return applyFocus(focusTarget(for: target))
    }

    /// Moves a window to another workspace. With `follow`, switches there and keeps it focused.
    @discardableResult
    public func moveWindow(_ id: WindowID, toWorkspace n: Int, follow: Bool) -> FocusTarget? {
        guard var w = windows[id], w.workspace != n else { return nil }
        let src = workspace(w.workspace)
        let dst = workspace(n)
        let srcFrame = homeMonitor(for: src).visibleFrame
        let wasFocused = focusedWindow == id
        detach(id, from: src)
        w.workspace = n
        if w.isFloating, let f = w.floatingFrame {
            let dstFrame = homeMonitor(for: dst).visibleFrame
            if dstFrame != srcFrame { w.floatingFrame = f.translated(from: srcFrame, to: dstFrame).integralRounded }
        }
        windows[id] = w
        insert(id, into: dst)
        dst.lastFocused = id
        if follow {
            _ = switchToWorkspace(n)
            noteFocused(id)
            return .window(id)
        }
        guard wasFocused else { return nil }
        focusedWindow = nil
        return isVisible(src.id) ? applyFocus(focusTarget(for: src.id)) : nil
    }

    // MARK: Window operations

    public func toggleFloating(_ id: WindowID, currentFrame: CGRect?) {
        guard var w = windows[id] else { return }
        let ws = workspace(w.workspace)
        if ws.fullscreen?.id == id { ws.fullscreen = nil }
        if w.isFloating {
            w.floatingFrame = currentFrame ?? w.floatingFrame
            w.isFloating = false
            windows[id] = w
            ws.floating.removeAll { $0 == id }
            insert(id, into: ws)
        } else {
            ws.tree.remove(id)
            ws.strip.remove(id)
            w.isFloating = true
            let area = homeMonitor(for: ws).visibleFrame
            if w.floatingFrame.map({ !area.intersects($0) }) ?? true {
                w.floatingFrame = area.centered(size: CGSize(width: area.width * 0.6, height: area.height * 0.65)).integralRounded
            }
            windows[id] = w
            ws.floating.append(id)
        }
    }

    public func toggleFullscreen(_ id: WindowID, mode: Int) {
        guard let w = windows[id] else { return }
        let ws = workspace(w.workspace)
        if let fs = ws.fullscreen, fs.id == id, fs.mode == mode {
            ws.fullscreen = nil
        } else {
            ws.fullscreen = FullscreenState(id: id, mode: mode)
        }
    }

    public func togglePseudo(_ id: WindowID) {
        guard var w = windows[id], !w.isFloating else { return }
        w.isPseudo.toggle()
        windows[id] = w
    }

    public func toggleSplit(_ id: WindowID) {
        guard let w = windows[id], !w.isFloating else { return }
        let ws = workspace(w.workspace)
        // Scrolling columns have no splits; flipping the hidden dwindle tree would only
        // surprise on the next togglelayout.
        guard layout(of: ws) == .dwindle else { return }
        ws.tree.toggleSplit(id)
    }

    public func resizeTiled(_ id: WindowID, dx: CGFloat, dy: CGFloat) {
        guard let w = windows[id], !w.isFloating else { return }
        let ws = workspace(w.workspace)
        if layout(of: ws) == .scrolling {
            // Columns only have a width; height always fills the screen.
            let area = tilingArea(for: ws)
            ws.strip.resize(id, by: dx / (area.width + 2 * gapsIn))
            return
        }
        refreshRects(ws)
        ws.tree.resize(id, dx: dx, dy: dy)
    }

    /// Mouse resizing of tiles: drag a window edge to an absolute coordinate.
    @discardableResult
    public func moveEdge(_ id: WindowID, edge: Edge, to coordinate: CGFloat) -> Bool {
        guard let w = windows[id], !w.isFloating else { return false }
        let ws = workspace(w.workspace)
        if layout(of: ws) == .scrolling {
            guard edge == .left || edge == .right else { return false }
            let area = tilingArea(for: ws)
            guard let f = ws.strip.layout(in: area, gapsIn: gapsIn, focus: nil, include: isFocusable)[id] else { return false }
            let w = edge == .right ? coordinate - f.minX : f.maxX - coordinate
            ws.strip.setWidth(id, ws.strip.fraction(forPixelWidth: w, area: area, gapsIn: gapsIn))
            return true
        }
        refreshRects(ws)
        // The divider sits gapsIn outside the window edge.
        let divider: CGFloat
        switch edge {
        case .right, .bottom: divider = coordinate + gapsIn
        case .left, .top: divider = coordinate - gapsIn
        }
        return ws.tree.moveEdge(of: id, edge: edge, to: divider)
    }

    /// Swaps two tiled windows, even across workspaces on different monitors.
    public func swapWindows(_ a: WindowID, _ b: WindowID) {
        guard var wa = windows[a], var wb = windows[b], a != b, !wa.isFloating, !wb.isFloating else { return }
        if wa.workspace == wb.workspace {
            workspace(wa.workspace).tree.swap(a, b)
            workspace(wa.workspace).strip.swap(a, b)
            return
        }
        let wsA = workspace(wa.workspace), wsB = workspace(wb.workspace)
        wsA.tree.replace(a, with: b)
        wsB.tree.replace(b, with: a)
        wsA.strip.replace(a, with: b)
        wsB.strip.replace(b, with: a)
        if wsA.lastFocused == a { wsA.lastFocused = b }
        if wsB.lastFocused == b { wsB.lastFocused = a }
        if wsA.fullscreen?.id == a { wsA.fullscreen = nil }
        if wsB.fullscreen?.id == b { wsB.fullscreen = nil }
        swap(&wa.workspace, &wb.workspace)
        windows[a] = wa
        windows[b] = wb
        if focusedWindow == a { noteFocused(a) } else if focusedWindow == b { noteFocused(b) }
    }

    /// Hyprland `swapwindow`: swaps with the tile in `direction`; into an empty monitor it moves there.
    @discardableResult
    public func swapInDirection(_ id: WindowID, _ direction: Direction) -> Bool {
        guard let w = windows[id], !w.isFloating else { return false }
        if let other = columnNeighbor(of: id, direction) {
            swapWindows(id, other)
            return true
        }
        switch neighbor(of: id, direction, tiledOnly: true) {
        case .window(let other)?:
            swapWindows(id, other)
            return true
        case .emptyMonitor(let m)?:
            guard let ws = activeWorkspace[m] else { return false }
            moveWindow(id, toWorkspace: ws, follow: false)
            focusedMonitor = m
            noteFocused(id)
            return true
        case nil:
            return false
        }
    }

    /// Frames of everything currently on screen (tiled layout frames and floating frames).
    public func visibleFrames(tiledOnly: Bool = false) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]
        for (id, p) in placements() {
            switch p {
            case .frame(let r): if !tiledOnly || windows[id]?.isFloating == false { out[id] = r }
            case .floating(let r): if !tiledOnly, let r { out[id] = r }
            case .hidden, .excluded: break
            }
        }
        return out
    }

    /// The window (or empty monitor) in `direction` from `id` (or from the focused monitor's center).
    public func neighbor(of id: WindowID?, _ direction: Direction, tiledOnly: Bool = false) -> FocusTarget? {
        // In the scrolling layout left/right walk the strip, including scrolled-away columns.
        if let id, let next = columnNeighbor(of: id, direction) { return .window(next) }
        let frames = visibleFrames(tiledOnly: tiledOnly)
        let sourceMonitor = monitor(id.flatMap { windows[$0] }.flatMap { monitorShowing($0.workspace) } ?? focusedMonitor) ?? primaryMonitor
        let source: CGRect
        if let id, let f = frames[id] {
            source = f
        } else {
            let c = sourceMonitor.visibleFrame.center
            source = CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)
        }
        var recency: [WindowID: Int] = [:]
        for (i, w) in mru.enumerated() { recency[w] = i }
        let candidates = frames.filter { $0.key != id }.map { (id: $0.key, rect: $0.value) }
        if let hit = findInDirection(from: source, direction: direction, candidates: candidates, recency: recency) {
            return .window(hit)
        }
        return monitorTarget(from: sourceMonitor, direction)
    }

    /// Adjacent column for left/right on a scrolling workspace; nil at the strip's ends.
    private func columnNeighbor(of id: WindowID, _ direction: Direction) -> WindowID? {
        guard direction.isHorizontal, let w = windows[id], !w.isFloating else { return nil }
        let ws = workspace(w.workspace)
        guard layout(of: ws) == .scrolling else { return nil }
        return ws.strip.neighbor(of: id, step: direction == .left ? -1 : 1, include: isFocusable)
    }

    private func monitorTarget(from m: Monitor, _ direction: Direction) -> FocusTarget? {
        let others = monitors.filter { $0.id != m.id }.map { (id: $0.id, rect: $0.frame) }
        guard let next = findInDirection(from: m.frame, direction: direction, candidates: others, tolerance: 2),
              let ws = activeWorkspace[next] else { return nil }
        let t = focusTarget(for: ws)
        if case .window = t { return t }
        return .emptyMonitor(next)
    }

    /// Hyprland `focusmonitor`.
    public func focusMonitor(_ direction: Direction) -> FocusTarget? {
        guard let t = monitorTarget(from: monitor(focusedMonitor) ?? primaryMonitor, direction) else { return nil }
        return applyFocus(t)
    }

    /// `cyclenext`: next window of the focused workspace in layout order.
    public func cycle(previous: Bool) -> WindowID? {
        let ws = workspace(focusedWorkspace)
        let ids = (tiledOrder(ws) + ws.floating).filter(isFocusable)
        guard !ids.isEmpty else { return nil }
        guard let f = focusedWindow, let i = ids.firstIndex(of: f) else { return ids.first }
        return ids[(i + (previous ? -1 : 1) + ids.count) % ids.count]
    }

    // MARK: Placement

    /// Tile frames a workspace would get if shown on its home monitor (used to put hidden
    /// windows somewhere sensible when the app quits).
    public func tiledFramesIfShown(_ workspaceID: Int) -> [WindowID: CGRect] {
        let ws = workspace(workspaceID)
        let area = homeMonitor(for: ws).visibleFrame.insetBy(dx: gapsOut, dy: gapsOut)
        if layout(of: ws) == .scrolling {
            // Restoring on quit: fan columns out over the screen rather than off it.
            let frames = ws.strip.layout(in: area, gapsIn: gapsIn, focus: nil, include: { [unowned self] in self.isFocusable($0) })
            return frames.mapValues { $0.translated(from: $0, to: area) }
        }
        return ws.tree.layout(in: area, gapsIn: gapsIn, include: { [unowned self] in self.isFocusable($0) })
    }

    /// A scrolled column may hang off the screen edge (macOS allows that) but must not be
    /// entirely off screen, nor reach onto a neighbouring monitor; otherwise it is parked.
    private func columnCanShow(_ f: CGRect, on mon: Monitor) -> Bool {
        let visible = f.intersection(mon.visibleFrame)
        guard !visible.isNull, visible.width >= 24 else { return false }
        return !monitors.contains { $0.id != mon.id && $0.frame.intersects(f) }
    }

    /// Where every window should be right now.
    public func placements() -> [WindowID: Placement] {
        var out: [WindowID: Placement] = [:]
        for ws in workspaces.values where !ws.isEmpty {
            guard let mon = monitor(monitorShowing(ws.id)) else {
                let park = monitor(ws.monitor) ?? primaryMonitor
                for id in ws.windowIDs { out[id] = isFocusable(id) ? .hidden(park.id) : .excluded }
                continue
            }
            let area = mon.visibleFrame.insetBy(dx: gapsOut, dy: gapsOut)
            let scrolling = layout(of: ws) == .scrolling
            let include: (WindowID) -> Bool = { [unowned self] in self.isFocusable($0) }
            let frames: [WindowID: CGRect]
            if scrolling {
                // Follow the focused column; a focused floating window keeps the view where it is.
                let anchor = ws.scrollAnchor.flatMap { ws.strip.contains($0) ? $0 : nil }
                frames = ws.strip.layout(in: area, gapsIn: gapsIn, focus: anchor, include: include)
            } else {
                frames = ws.tree.layout(in: area, gapsIn: gapsIn, include: include)
            }
            func fullscreenFrame(_ mode: Int) -> CGRect { mode == 0 ? mon.visibleFrame : area }
            for id in ws.tree.windows {
                guard let w = windows[id] else { continue }
                guard !w.isExcluded, var f = frames[id] else { out[id] = .excluded; continue }
                if scrolling, ws.fullscreen?.id != id, !columnCanShow(f, on: mon) {
                    out[id] = .hidden(mon.id)
                    continue
                }
                if let fs = ws.fullscreen, fs.id == id {
                    f = fullscreenFrame(fs.mode)
                } else if w.isPseudo, let s = w.initialSize {
                    f = f.centered(size: s).integralRounded
                }
                out[id] = .frame(f)
            }
            for id in ws.floating {
                guard let w = windows[id] else { continue }
                guard !w.isExcluded else { out[id] = .excluded; continue }
                if let fs = ws.fullscreen, fs.id == id {
                    out[id] = .frame(fullscreenFrame(fs.mode))
                    continue
                }
                var f = w.floatingFrame
                if let ff = f, !mon.frame.intersects(ff) { f = mon.visibleFrame.centered(size: ff.size).integralRounded }
                out[id] = .floating(f)
            }
        }
        return out
    }
}
