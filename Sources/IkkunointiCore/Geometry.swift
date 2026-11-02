import CoreGraphics
import Foundation

/// Window server window number (CGWindowID).
public typealias WindowID = UInt32
/// CGDirectDisplayID of a monitor.
public typealias MonitorID = UInt32

/// All rects in IkkunointiCore use the global "top-left origin, y grows downwards"
/// coordinate space used by the Accessibility API and CGWindowList.

public enum Direction: String, CaseIterable, Sendable {
    case left, right, up, down

    /// Accepts Hyprland spellings: l/r/u/d, left/right/up/down, t/b, top/bottom.
    public init?(hypr: String) {
        switch hypr.trimmingCharacters(in: .whitespaces).lowercased() {
        case "l", "left": self = .left
        case "r", "right": self = .right
        case "u", "t", "up", "top": self = .up
        case "d", "b", "down", "bottom": self = .down
        default: return nil
        }
    }

    public var isHorizontal: Bool { self == .left || self == .right }
}

public enum Edge: Sendable { case left, right, top, bottom }

extension CGRect {
    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    public func isApproximately(_ other: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// Rounds to whole points so we never ask apps for fractional frames.
    public var integralRounded: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Positions `self` (keeping its size, clamped to fit) at the same relative spot inside `to`
    /// as it had inside `from`. Used when floating windows move between monitors.
    public func translated(from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else { return self }
        let w = min(width, to.width), h = min(height, to.height)
        let rx = (midX - from.minX) / from.width
        let ry = (midY - from.minY) / from.height
        var x = to.minX + rx * to.width - w / 2
        var y = to.minY + ry * to.height - h / 2
        x = min(max(x, to.minX), to.maxX - w)
        y = min(max(y, to.minY), to.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A rect of `size` (clamped to fit) centered inside `self`.
    public func centered(size: CGSize) -> CGRect {
        let w = min(size.width, width), h = min(size.height, height)
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    /// Area of the intersection with `other` (0 when disjoint).
    public func overlapArea(_ other: CGRect) -> CGFloat {
        let i = intersection(other)
        return i.isNull ? 0 : i.width * i.height
    }
}

/// Finds the best candidate in `direction` from `source`, Hyprland style:
/// candidates must lie beyond the source edge; those overlapping the source on the
/// perpendicular axis win, nearest first, ties broken by focus recency.
/// Falls back to the nearest candidate anywhere in that half-plane.
public func findInDirection(
    from source: CGRect,
    direction: Direction,
    candidates: [(id: WindowID, rect: CGRect)],
    recency: [WindowID: Int] = [:],
    tolerance: CGFloat = 8
) -> WindowID? {
    func beyond(_ r: CGRect) -> Bool {
        switch direction {
        case .left: return r.maxX <= source.minX + tolerance && r.midX < source.midX
        case .right: return r.minX >= source.maxX - tolerance && r.midX > source.midX
        case .up: return r.maxY <= source.minY + tolerance && r.midY < source.midY
        case .down: return r.minY >= source.maxY - tolerance && r.midY > source.midY
        }
    }
    func gap(_ r: CGRect) -> CGFloat {
        switch direction {
        case .left: return source.minX - r.maxX
        case .right: return r.minX - source.maxX
        case .up: return source.minY - r.maxY
        case .down: return r.minY - source.maxY
        }
    }
    func perpendicularOverlap(_ r: CGRect) -> CGFloat {
        if direction.isHorizontal {
            return min(r.maxY, source.maxY) - max(r.minY, source.minY)
        } else {
            return min(r.maxX, source.maxX) - max(r.minX, source.minX)
        }
    }
    func rank(_ id: WindowID) -> Int { recency[id] ?? Int.max }

    let inHalfPlane = candidates.filter { beyond($0.rect) }
    let overlapping = inHalfPlane.filter { perpendicularOverlap($0.rect) > 0 }

    if !overlapping.isEmpty {
        let best = overlapping.min { a, b in
            let ga = gap(a.rect), gb = gap(b.rect)
            if abs(ga - gb) > 2 { return ga < gb }
            if rank(a.id) != rank(b.id) { return rank(a.id) < rank(b.id) }
            return perpendicularOverlap(a.rect) > perpendicularOverlap(b.rect)
        }
        return best?.id
    }

    let sc = source.center
    return inHalfPlane.min { a, b in
        let da = hypot(a.rect.midX - sc.x, a.rect.midY - sc.y)
        let db = hypot(b.rect.midX - sc.x, b.rect.midY - sc.y)
        return da < db
    }?.id
}
