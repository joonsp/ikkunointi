import AppKit
import IkkunointiCore
import QuartzCore

/// Hyprland-style gradient border around the focused window: a transparent, click-through
/// overlay window that sits in the gap around it.
final class BorderWindow {
    private let window: NSWindow
    private let gradient = CAGradientLayer()
    private let shape = CAShapeLayer()
    private var width: CGFloat = 2
    private var radius: CGFloat = 12

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // The focused window is frontmost among normal windows, so floating level only
        // ever covers the gap around it.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenNone]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
        view.layer?.addSublayer(gradient)
        shape.fillColor = nil
        shape.strokeColor = NSColor.black.cgColor
        gradient.mask = shape
    }

    func configure(width: CGFloat, radius: CGFloat, gradient g: BorderGradient) {
        self.width = width
        self.radius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let colors = g.colors.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) }
        gradient.colors = colors.count == 1 ? [colors[0], colors[0]] : colors
        // Hyprland: 0deg runs left to right; angles turn clockwise. Layer y points up.
        let rad = g.angle * .pi / 180
        let dx = cos(rad) / 2, dy = -sin(rad) / 2
        gradient.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
        gradient.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        shape.lineWidth = width
        CATransaction.commit()
    }

    /// `frame` is the target window's frame in global top-left coordinates.
    func show(around frame: CGRect) {
        guard width > 0 else { return hide() }
        let outer = frame.insetBy(dx: -width, dy: -width)
        let cocoa = outer.flippedScreenCoordinates
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(cocoa, display: false)
        let bounds = CGRect(origin: .zero, size: cocoa.size)
        gradient.frame = bounds
        shape.frame = bounds
        let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
        let r = max(0, min(radius + width / 2, inset.width / 2, inset.height / 2))
        shape.path = CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
        window.orderFrontRegardless()
    }

    var windowID: CGWindowID { CGWindowID(max(0, window.windowNumber)) }

    func hide() {
        window.orderOut(nil)
    }
}
