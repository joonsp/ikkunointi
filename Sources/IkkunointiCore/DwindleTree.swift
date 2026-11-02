import CoreGraphics

public enum SplitAxis: Sendable {
    /// Children side by side (the split divides the width).
    case horizontal
    /// Children stacked (the split divides the height).
    case vertical

    public var toggled: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

/// A node of the dwindle binary space partition. Leaves hold a window,
/// inner nodes hold a split with a ratio (fraction of space given to `first`).
public final class TreeNode {
    public fileprivate(set) weak var parent: TreeNode?
    public fileprivate(set) var window: WindowID?
    public fileprivate(set) var axis: SplitAxis = .horizontal
    public fileprivate(set) var ratio: CGFloat = 0.5
    public fileprivate(set) var first: TreeNode?
    public fileprivate(set) var second: TreeNode?
    /// Raw rect (before inner gaps) from the most recent layout pass. `.zero` when hidden.
    public fileprivate(set) var rect: CGRect = .zero

    init(window: WindowID) { self.window = window }

    public var isLeaf: Bool { window != nil }
}

/// Hyprland's "dwindle" layout: every new window splits the focused window's
/// tile in two, along the tile's longer side.
public final class DwindleTree {
    public private(set) var root: TreeNode?
    private var leaves: [WindowID: TreeNode] = [:]
    public var defaultRatio: CGFloat = 0.5

    public init() {}

    public var isEmpty: Bool { root == nil }
    public var count: Int { leaves.count }
    public func contains(_ id: WindowID) -> Bool { leaves[id] != nil }
    public func leaf(_ id: WindowID) -> TreeNode? { leaves[id] }

    /// Windows in reading order (first child before second child).
    public var windows: [WindowID] {
        var out: [WindowID] = []
        func walk(_ n: TreeNode?) {
            guard let n else { return }
            if let w = n.window { out.append(w); return }
            walk(n.first); walk(n.second)
        }
        walk(root)
        return out
    }

    // MARK: Mutation

    /// Inserts `id` by splitting the tile of `target` (falls back to the last window).
    /// The split goes along the longer side of that tile; the new window becomes the
    /// second child (right / bottom), like Hyprland with `force_split = 2`.
    public func insert(_ id: WindowID, splitting target: WindowID?, fallbackArea: CGRect) {
        guard leaves[id] == nil else { return }
        let newLeaf = TreeNode(window: id)
        leaves[id] = newLeaf
        guard root != nil else {
            root = newLeaf
            return
        }
        let targetLeaf = target.flatMap { leaves[$0] } ?? windows.last.flatMap { leaves[$0] }!
        let tileRect = targetLeaf.rect.isEmpty ? fallbackArea : targetLeaf.rect
        let axis: SplitAxis = tileRect.width >= tileRect.height ? .horizontal : .vertical

        // Turn the target leaf into a split node in place; its window moves into a new child.
        let oldLeaf = TreeNode(window: targetLeaf.window!)
        oldLeaf.rect = targetLeaf.rect
        leaves[oldLeaf.window!] = oldLeaf
        targetLeaf.window = nil
        targetLeaf.axis = axis
        targetLeaf.ratio = defaultRatio
        targetLeaf.first = oldLeaf
        targetLeaf.second = newLeaf
        oldLeaf.parent = targetLeaf
        newLeaf.parent = targetLeaf
    }

    /// Removes `id`; its sibling takes over the parent's space.
    public func remove(_ id: WindowID) {
        guard let leaf = leaves.removeValue(forKey: id) else { return }
        guard let parent = leaf.parent else {
            root = nil
            return
        }
        let sibling = parent.first === leaf ? parent.second! : parent.first!
        if let grand = parent.parent {
            if grand.first === parent { grand.first = sibling } else { grand.second = sibling }
            sibling.parent = grand
        } else {
            root = sibling
            sibling.parent = nil
        }
        sibling.rect = parent.rect
    }

    /// Puts window `new` into the tile currently held by `old`.
    public func replace(_ old: WindowID, with new: WindowID) {
        guard let leaf = leaves.removeValue(forKey: old) else { return }
        leaf.window = new
        leaves[new] = leaf
    }

    /// Swaps the tiles of two windows in this tree.
    public func swap(_ a: WindowID, _ b: WindowID) {
        guard let la = leaves[a], let lb = leaves[b], a != b else { return }
        la.window = b
        lb.window = a
        leaves[a] = lb
        leaves[b] = la
    }

    /// Hyprland `togglesplit`: flips the split direction of the window's parent.
    public func toggleSplit(_ id: WindowID) {
        guard let parent = leaves[id]?.parent else { return }
        parent.axis = parent.axis.toggled
    }

    /// Hyprland `resizeactive`: grows (positive) or shrinks (negative) the window by
    /// moving the nearest divider on each axis. Requires a prior layout pass.
    public func resize(_ id: WindowID, dx: CGFloat, dy: CGFloat) {
        guard let leaf = leaves[id] else { return }
        if dx != 0 { adjust(leaf, axis: .horizontal, delta: dx) }
        if dy != 0 { adjust(leaf, axis: .vertical, delta: dy) }
    }

    private func adjust(_ leaf: TreeNode, axis: SplitAxis, delta: CGFloat) {
        var child = leaf
        var node = leaf.parent
        while let n = node {
            if n.axis == axis, let f = n.first, let s = n.second, !f.rect.isEmpty, !s.rect.isEmpty {
                let size = axis == .horizontal ? n.rect.width : n.rect.height
                guard size > 0 else { return }
                let d = delta / size
                n.ratio = clampRatio(n.first === child ? n.ratio + d : n.ratio - d)
                return
            }
            child = n
            node = n.parent
        }
    }

    /// Moves the divider bordering `edge` of the window to the absolute coordinate
    /// `coordinate` (x for left/right, y for top/bottom). Returns false when that edge
    /// is not shared with a sibling (e.g. it touches the monitor edge).
    @discardableResult
    public func moveEdge(of id: WindowID, edge: Edge, to coordinate: CGFloat) -> Bool {
        guard let leaf = leaves[id] else { return false }
        let axis: SplitAxis = (edge == .left || edge == .right) ? .horizontal : .vertical
        let wantFirst = (edge == .right || edge == .bottom)
        var child = leaf
        var node = leaf.parent
        while let n = node {
            if n.axis == axis, (n.first === child) == wantFirst,
               let f = n.first, let s = n.second, !f.rect.isEmpty, !s.rect.isEmpty {
                let origin = axis == .horizontal ? n.rect.minX : n.rect.minY
                let size = axis == .horizontal ? n.rect.width : n.rect.height
                guard size > 0 else { return false }
                n.ratio = clampRatio((coordinate - origin) / size)
                return true
            }
            child = n
            node = n.parent
        }
        return false
    }

    private func clampRatio(_ r: CGFloat) -> CGFloat { min(max(r, 0.1), 0.9) }

    // MARK: Layout

    /// Computes window frames inside `area` (already inset by the outer gaps).
    /// `include` decides which windows take part (minimized windows are skipped and
    /// their space collapses). `gapsIn` is applied per side, like Hyprland, so two
    /// neighbours end up `2 * gapsIn` apart.
    public func layout(in area: CGRect, gapsIn: CGFloat, include: (WindowID) -> Bool = { _ in true }) -> [WindowID: CGRect] {
        var raw: [WindowID: CGRect] = [:]
        if let root { assign(root, rect: area, include: include, into: &raw) }
        var out: [WindowID: CGRect] = [:]
        for (id, r) in raw {
            var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
            if x0 > area.minX + 0.5 { x0 += gapsIn }
            if x1 < area.maxX - 0.5 { x1 -= gapsIn }
            if y0 > area.minY + 0.5 { y0 += gapsIn }
            if y1 < area.maxY - 0.5 { y1 -= gapsIn }
            out[id] = CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1)).integralRounded
        }
        return out
    }

    private func hasVisible(_ n: TreeNode?, _ include: (WindowID) -> Bool) -> Bool {
        guard let n else { return false }
        if let w = n.window { return include(w) }
        return hasVisible(n.first, include) || hasVisible(n.second, include)
    }

    private func clear(_ n: TreeNode?) {
        guard let n else { return }
        n.rect = .zero
        clear(n.first)
        clear(n.second)
    }

    private func assign(_ n: TreeNode, rect: CGRect, include: (WindowID) -> Bool, into out: inout [WindowID: CGRect]) {
        n.rect = rect
        if let w = n.window {
            if include(w) { out[w] = rect } else { n.rect = .zero }
            return
        }
        guard let f = n.first, let s = n.second else { return }
        let fv = hasVisible(f, include), sv = hasVisible(s, include)
        switch (fv, sv) {
        case (true, true):
            if n.axis == .horizontal {
                let w = rect.width * n.ratio
                assign(f, rect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), include: include, into: &out)
                assign(s, rect: CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height), include: include, into: &out)
            } else {
                let h = rect.height * n.ratio
                assign(f, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), include: include, into: &out)
                assign(s, rect: CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h), include: include, into: &out)
            }
        case (true, false):
            assign(f, rect: rect, include: include, into: &out)
            clear(s)
        case (false, true):
            assign(s, rect: rect, include: include, into: &out)
            clear(f)
        case (false, false):
            clear(n)
        }
    }
}
