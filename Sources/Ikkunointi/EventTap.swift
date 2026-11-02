import AppKit
import IkkunointiCore

struct KeyCombo: Hashable {
    let code: UInt16
    let mods: Modifiers
}

struct MouseCombo: Hashable {
    let button: MouseButton
    let mods: Modifiers
}

struct TapBinding {
    let action: Action
    let repeats: Bool
}

protocol EventTapDelegate: AnyObject {
    func tapPerform(_ action: Action)
    func tapBeginDrag(_ action: MouseAction, at point: CGPoint)
    func tapContinueDrag(to point: CGPoint)
    func tapEndDrag(at point: CGPoint)
    func tapMouseUp(at point: CGPoint)
}

/// A session event tap running on its own thread, so a slow Accessibility call on the main
/// thread can never make the whole system's keyboard lag. Matching is a dictionary lookup;
/// actions are dispatched to the main queue.
final class EventTap {
    weak var delegate: EventTapDelegate?

    private let lock = NSLock()
    private var keys: [KeyCombo: TapBinding] = [:]
    private var mouse: [MouseCombo: MouseAction] = [:]
    private var superKey: SuperKey = .capslock

    // Only touched on the tap thread.
    private var swallowedKeyUps = Set<UInt16>()
    /// Caps Lock (as F18) state from its own key events (fallback only).
    private var f18Down = false
    private var f18LastSeen = Date.distantPast
    /// Set once we've seen `CGEventSource.keyState` report F18 during a real press. From then
    /// on it is authoritative (it can't get stuck on a missed key-up); until then we rely
    /// on the tracked key events.
    private var keyStateSeesF18 = false
    private var dragButton: MouseButton?

    // Drag coalescing between threads (guarded by `lock`).
    private var pendingDragPoint: CGPoint?
    private var dragFlushScheduled = false

    private var tap: CFMachPort?
    private var thread: Thread?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func configure(keys: [KeyCombo: TapBinding], mouse: [MouseCombo: MouseAction], superKey: SuperKey) {
        lock.lock()
        self.keys = keys
        self.mouse = mouse
        self.superKey = superKey
        lock.unlock()
    }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: eventTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "ikkunointi.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            f18Down = false
            swallowedKeyUps.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            lock.lock()
            let mode = superKey
            lock.unlock()
            if mode == .capslock && code == KeyNames.f18 {
                // Caps Lock (as F18) is ours.
                f18Down = type == .keyDown
                f18LastSeen = Date()
                if f18Down && !keyStateSeesF18 && Self.f18KeyState() { keyStateSeesF18 = true }
                return nil
            }
            if type == .keyUp {
                return swallowedKeyUps.remove(code) != nil ? nil : pass
            }
            let mods = normalize(event.flags, mode)
            lock.lock()
            let binding = keys[KeyCombo(code: code, mods: mods)]
            lock.unlock()
            if let binding {
                swallowedKeyUps.insert(code)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat || binding.repeats {
                    let action = binding.action
                    DispatchQueue.main.async { [weak self] in self?.delegate?.tapPerform(action) }
                }
                return nil
            }
            if mode == .capslock && mods.contains(.superKey) && keyStateSeesF18 {
                // SUPER + unbound key: swallow it like a compositor would instead of typing.
                swallowedKeyUps.insert(code)
                return nil
            }
            return pass

        case .leftMouseDown, .rightMouseDown:
            let button: MouseButton = type == .leftMouseDown ? .left : .right
            lock.lock()
            let mode = superKey
            let action = mouse[MouseCombo(button: button, mods: normalize(event.flags, mode))]
            lock.unlock()
            guard let action else { return pass }
            dragButton = button
            let p = event.location
            DispatchQueue.main.async { [weak self] in self?.delegate?.tapBeginDrag(action, at: p) }
            return nil

        case .leftMouseDragged, .rightMouseDragged:
            guard dragButton != nil else { return pass }
            queueDrag(event.location)
            return nil

        case .leftMouseUp, .rightMouseUp:
            let button: MouseButton = type == .leftMouseUp ? .left : .right
            let p = event.location
            if dragButton == button {
                dragButton = nil
                DispatchQueue.main.async { [weak self] in self?.delegate?.tapEndDrag(at: p) }
                return nil
            }
            if button == .left {
                DispatchQueue.main.async { [weak self] in self?.delegate?.tapMouseUp(at: p) }
            }
            return pass

        default:
            return pass
        }
    }

    private func queueDrag(_ p: CGPoint) {
        lock.lock()
        pendingDragPoint = p
        let schedule = !dragFlushScheduled
        dragFlushScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let point = self.pendingDragPoint
            self.dragFlushScheduled = false
            self.lock.unlock()
            if let point { self.delegate?.tapContinueDrag(to: point) }
        }
    }

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK) distinguish left from right.
    private static let leftCtrl: UInt64 = 0x0001, leftCmd: UInt64 = 0x0008, rightCmd: UInt64 = 0x0010
    private static let leftAlt: UInt64 = 0x0020, rightAlt: UInt64 = 0x0040, rightCtrl: UInt64 = 0x2000

    private static func f18KeyState() -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(KeyNames.f18))
    }

    private func capsSuperHeld() -> Bool {
        if keyStateSeesF18 { return Self.f18KeyState() }
        // Fallback: tracked key events, expiring so a missed key-up can't turn plain keys into chords.
        return f18Down && Date().timeIntervalSince(f18LastSeen) < 10
    }

    private func normalize(_ flags: CGEventFlags, _ mode: SuperKey) -> Modifiers {
        Self.normalize(flags, mode, capsHeld: mode == .capslock && capsSuperHeld())
    }

    /// Maps raw event flags to abstract modifiers, deciding what counts as SUPER.
    static func normalize(_ flags: CGEventFlags, _ mode: SuperKey, capsHeld: Bool) -> Modifiers {
        let raw = flags.rawValue
        let ctrl = flags.contains(.maskControl), alt = flags.contains(.maskAlternate), cmd = flags.contains(.maskCommand)
        var m: Modifiers = flags.contains(.maskShift) ? [.shift] : []
        func add(_ cond: Bool, _ mod: Modifiers) { if cond { m.insert(mod) } }
        switch mode {
        case .capslock:
            add(capsHeld, .superKey)
            add(ctrl, .ctrl); add(alt, .alt); add(cmd, .cmd)
        case .rcmd:
            add(raw & rightCmd != 0, .superKey); add(raw & leftCmd != 0, .cmd); add(ctrl, .ctrl); add(alt, .alt)
        case .ropt:
            add(raw & rightAlt != 0, .superKey); add(raw & leftAlt != 0, .alt); add(ctrl, .ctrl); add(cmd, .cmd)
        case .rctrl:
            add(raw & rightCtrl != 0, .superKey); add(raw & leftCtrl != 0, .ctrl); add(alt, .alt); add(cmd, .cmd)
        case .cmd:
            add(cmd, .superKey); add(ctrl, .ctrl); add(alt, .alt)
        case .alt:
            add(alt, .superKey); add(ctrl, .ctrl); add(cmd, .cmd)
        case .ctrl:
            add(ctrl, .superKey); add(alt, .alt); add(cmd, .cmd)
        case .ctrlAlt:
            if ctrl && alt { m.insert(.superKey) } else { add(ctrl, .ctrl); add(alt, .alt) }
            add(cmd, .cmd)
        }
        return m
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
