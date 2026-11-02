import AppKit
import ApplicationServices

/// Private but long-stable HIServices call that maps an AX window to its CGWindowID.
/// Used by yabai, AeroSpace, Rectangle, AltTab.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    /// nil when the attribute is missing or the app did not answer.
    func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { copy(attribute) as? String }

    func bool(_ attribute: String) -> Bool? { (copy(attribute) as? NSNumber)?.boolValue }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = copy(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    /// nil on failure, [] when the app truly has none.
    func elements(_ attribute: String) -> [AXUIElement]? {
        guard let v = copy(attribute), CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        return (v as? [AXUIElement]) ?? []
    }

    var position: CGPoint? {
        guard let v = copy(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = copy(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, v)
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }
}

/// Focuses a specific window of another app. Uses the SkyLight calls yabai and AltTab rely
/// on (they work for background apps without disabling SIP); falls back to plain activation.
enum WindowFocus {
    private struct PSN { var high: UInt32 = 0; var low: UInt32 = 0 }
    private typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Int32
    private typealias PostEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFront: SetFrontFn? = symbol("_SLPSSetFrontProcessWithOptions", skyLight)
    private static let postEventRecord: PostEventFn? = symbol("SLPSPostEventRecordTo", skyLight)
    private static let getPSN: GetPSNFn? = symbol("GetProcessForPID", UnsafeMutableRawPointer(bitPattern: -2)) // RTLD_DEFAULT

    private static func symbol<T>(_ name: String, _ handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let userGenerated: UInt32 = 0x200

    static func focus(pid: pid_t, windowID: CGWindowID, element: AXUIElement) {
        if !bringToFront(pid: pid, windowID: windowID) {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        element.set(kAXMainAttribute, kCFBooleanTrue)
        element.perform(kAXRaiseAction)
    }

    /// Activates an app without choosing a window.
    static func activate(pid: pid_t) {
        if !bringToFront(pid: pid, windowID: 0) {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
    }

    @discardableResult
    private static func bringToFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getPSN, let setFront else { return false }
        var psn = PSN()
        guard withUnsafeMutablePointer(to: &psn, { getPSN(pid, $0) }) == noErr else { return false }
        guard withUnsafeMutablePointer(to: &psn, { setFront($0, windowID, userGenerated) }) == 0 else { return false }
        if windowID != 0 { makeKeyWindow(&psn, windowID) }
        return true
    }

    /// Port of the event-record trick from https://github.com/Hammerspoon/hammerspoon/issues/370
    private static func makeKeyWindow(_ psn: inout PSN, _ windowID: CGWindowID) {
        guard let postEventRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for i in 0..<4 { bytes[0x3c + i] = raw[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        for kind: UInt8 in [0x01, 0x02] {
            bytes[0x08] = kind
            withUnsafeMutablePointer(to: &psn) { p in
                bytes.withUnsafeMutableBufferPointer { buf in _ = postEventRecord(p, buf.baseAddress!) }
            }
        }
    }
}

enum WindowList {
    /// True if the window server still knows this window (on any Space).
    static func exists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return !list.isEmpty
    }

    /// The window under the cursor if it is the topmost thing there: nil when a menu, popup,
    /// panel or the menu bar covers the point. `ignoring` skips our own overlay windows.
    static func topmostNormalWindow(at point: CGPoint, ignoring: Set<CGWindowID>) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, !ignoring.contains(id),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point) else { continue }
            if (info[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
            return (info[kCGWindowLayer as String] as? Int) == 0 ? id : nil
        }
        return nil
    }

    /// Topmost normal-level window under a point (global top-left coordinates).
    static func windowID(at point: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if bounds.contains(point) { return id }
        }
        return nil
    }
}

extension CGRect {
    /// Converts between AppKit (bottom-left origin) and AX/CG (top-left origin) coordinates.
    /// The conversion is its own inverse.
    var flippedScreenCoordinates: CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: h - maxY, width: width, height: height)
    }
}

extension CGPoint {
    var flippedScreenCoordinates: CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: x, y: h - y)
    }
}
