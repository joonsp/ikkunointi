import Foundation
import IOKit
import IOKit.hidsystem

/// Turns Caps Lock into F18 (via `hidutil`, no root or Karabiner needed) so it can be held
/// as SUPER. Other user key mappings are preserved and restored on quit.
enum CapsLockRemap {
    private static let capsLock: Int64 = 0x7_0000_0039
    private static let f18: Int64 = 0x7_0000_006D
    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"

    private static var restoreTo: [[String: Int64]]?
    private(set) static var isActive = false

    static func enable() {
        guard !isActive else { return }
        let current = readMappings()
        // Whatever else the user mapped (minus any Caps Lock mapping, including a stale one of ours).
        let others = current.filter { $0[srcKey] != capsLock }
        if restoreTo == nil {
            restoreTo = current.filter { !($0[srcKey] == capsLock && $0[dstKey] == f18) }
        }
        write(others + [[srcKey: capsLock, dstKey: f18]])
        turnOffCapsLockLight()
        isActive = true
    }

    static func disable() {
        guard isActive else { return }
        write(restoreTo ?? readMappings().filter { !($0[srcKey] == capsLock && $0[dstKey] == f18) })
        isActive = false
    }

    private static func readMappings() -> [[String: Int64]] {
        guard let out = run(["property", "--get", "UserKeyMapping"]), let data = out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            return []
        }
        // `hidutil` prints an OpenStep plist, where numbers come back as strings.
        return plist.compactMap { dict in
            var m: [String: Int64] = [:]
            for (k, v) in dict {
                if let n = v as? NSNumber { m[k] = n.int64Value } else if let s = v as? String, let n = Int64(s) { m[k] = n }
            }
            return m[srcKey] != nil && m[dstKey] != nil ? m : nil
        }
    }

    private static func write(_ mappings: [[String: Int64]]) {
        guard let json = try? JSONSerialization.data(withJSONObject: ["UserKeyMapping": mappings]),
              let text = String(data: json, encoding: .utf8) else { return }
        _ = run(["property", "--set", text])
    }

    @discardableResult
    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// If Caps Lock was on when we took the key over, nothing could turn it off again.
    private static func turnOffCapsLockLight() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var on = false
        if IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS, on {
            IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
        }
    }
}
