import AppKit
import ApplicationServices

/// Owns the AXObserver for one running application and the per-window subscriptions.
final class AppWatcher {
    let app: NSRunningApplication
    let pid: pid_t
    let element: AXUIElement
    private(set) var observer: AXObserver?
    private var watched: [CGWindowID: AXUIElement] = [:]
    weak var manager: WindowManager?

    var bundleID: String? { app.bundleIdentifier }
    var name: String { app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)" }

    init(app: NSRunningApplication, manager: WindowManager) {
        self.app = app
        self.pid = app.processIdentifier
        self.element = AXUIElementCreateApplication(app.processIdentifier)
        self.manager = manager
        AXUIElementSetMessagingTimeout(element, 1.0)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Apps that are still launching refuse observers; the caller retries.
    func subscribe() -> Bool {
        if observer != nil { return true }
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let obs = created else { return false }
        var ok = false
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            let r = AXObserverAddNotification(obs, element, name as CFString, refcon)
            if r == .success || r == .notificationAlreadyRegistered { ok = true }
        }
        guard ok else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        return true
    }

    func watch(_ window: AXUIElement, id: CGWindowID) {
        guard let observer, watched[id] == nil else { return }
        watched[id] = window
        for name in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
    }

    func unwatch(_ id: CGWindowID) {
        guard let window = watched.removeValue(forKey: id), let observer else { return }
        for name in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverRemoveNotification(observer, window, name as CFString)
        }
    }

    /// Destroyed elements can no longer answer `_AXUIElementGetWindow`; match by identity.
    func windowID(for element: AXUIElement) -> CGWindowID? {
        watched.first { CFEqual($0.value, element) }?.key ?? element.windowID
    }

    func invalidate() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        watched.removeAll()
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.manager?.handleAX(notification as String, element: element, watcher: watcher)
}
