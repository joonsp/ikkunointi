import Foundation

public enum IPC {
    /// Unix socket shared by the app and `ikkunointictl`. Lives in the per-user temp dir
    /// (`/var/folders/.../T/`), which is the same for GUI apps and shells. Override with
    /// `IKKUNOINTI_SOCKET`.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["IKKUNOINTI_SOCKET"], !override.isEmpty {
            return override
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let dir = n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("ikkunointi.sock")
    }
}
