import CoreGraphics

public enum LayoutKind: String, Sendable {
    case dwindle
    case scrolling
}

/// Hyprland's "scrolling" layout (niri / PaperWM style): windows are columns in an endless
/// horizontal strip. New windows open as a column to the right of the focused one; the
/// viewport scrolls so the focused column is always fully visible.
public final class ScrollStrip {
    public private(set) var columns: [WindowID] = []
    private var widths: [WindowID: CGFloat] = [:]
    /// Fraction of the screen a new column gets (0.5 = two columns fill the screen).
    public var defaultWidth: CGFloat = 0.5
    /// Left edge of the viewport in strip coordinates.
    public private(set) var offset: CGFloat = 0

    public init() {}

    public var windows: [WindowID] { columns }
    public func contains(_ id: WindowID) -> Bool { columns.contains(id) }

    public func width(of id: WindowID) -> CGFloat { widths[id] ?? defaultWidth }

    public func insert(_ id: WindowID, after target: WindowID?) {
        guard !contains(id) else { return }
        let index = target.flatMap { columns.firstIndex(of: $0) }.map { $0 + 1 } ?? columns.count
        columns.insert(id, at: index)
    }

    public func remove(_ id: WindowID) {
        columns.removeAll { $0 == id }
        widths[id] = nil
    }

    public func replace(_ old: WindowID, with new: WindowID) {
        guard let i = columns.firstIndex(of: old) else { return }
        columns[i] = new
        widths[new] = widths.removeValue(forKey: old)
    }

    /// Swaps the columns' positions; each window keeps its own width.
    public func swap(_ a: WindowID, _ b: WindowID) {
        guard let i = columns.firstIndex(of: a), let j = columns.firstIndex(of: b) else { return }
        columns.swapAt(i, j)
    }

    /// The nearest column to the left (`step < 0`) or right that passes `include`.
    public func neighbor(of id: WindowID, step: Int, include: (WindowID) -> Bool = { _ in true }) -> WindowID? {
        guard var i = columns.firstIndex(of: id) else { return nil }
        while true {
            i += step
            guard columns.indices.contains(i) else { return nil }
            if include(columns[i]) { return columns[i] }
        }
    }

    public func setWidth(_ id: WindowID, _ fraction: CGFloat) {
        guard contains(id) else { return }
        widths[id] = min(max(fraction, 0.1), 1.0)
    }

    public func resize(_ id: WindowID, by fraction: CGFloat) {
        setWidth(id, width(of: id) + fraction)
    }

    /// Pixel width of a column so that fractions add up across gaps
    /// (two 0.5 columns plus the gap between them exactly fill `area`).
    public func pixelWidth(_ fraction: CGFloat, area: CGRect, gapsIn: CGFloat) -> CGFloat {
        (fraction * (area.width + 2 * gapsIn) - 2 * gapsIn).rounded()
    }

    /// Inverse of `pixelWidth`.
    public func fraction(forPixelWidth w: CGFloat, area: CGRect, gapsIn: CGFloat) -> CGFloat {
        (w + 2 * gapsIn) / (area.width + 2 * gapsIn)
    }

    /// Frames for every included column. Frames may lie partly or fully outside `area`
    /// (scrolled away). Scrolls just enough to keep `focus` fully in view.
    public func layout(in area: CGRect, gapsIn: CGFloat, focus: WindowID?, include: (WindowID) -> Bool = { _ in true }) -> [WindowID: CGRect] {
        var spans: [(id: WindowID, x: CGFloat, w: CGFloat)] = []
        var x: CGFloat = 0
        for id in columns where include(id) {
            let w = max(1, pixelWidth(width(of: id), area: area, gapsIn: gapsIn))
            spans.append((id, x, w))
            x += w + 2 * gapsIn
        }
        let total = max(0, x - 2 * gapsIn)
        if let focus, let s = spans.first(where: { $0.id == focus }) {
            if s.x < offset {
                offset = s.x
            } else if s.x + s.w > offset + area.width {
                offset = s.x + s.w - area.width
            }
        }
        // Never scroll past the ends.
        offset = max(0, min(offset, total - area.width))
        var out: [WindowID: CGRect] = [:]
        for s in spans {
            out[s.id] = CGRect(x: area.minX + s.x - offset, y: area.minY, width: s.w, height: area.height).integralRounded
        }
        return out
    }
}
