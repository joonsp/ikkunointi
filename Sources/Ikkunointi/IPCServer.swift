import AppKit
import IkkunointiCore

/// Unix socket server for `ikkunointictl` (hyprctl equivalent). Requests are a JSON array of
/// arguments terminated by a newline; the reply is plain text (or JSON with -j).
final class IPCServer {
    let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "ikkunointi.ipc")
    private var handler: (([String]) -> String)?

    struct Failure: Error, CustomStringConvertible { let description: String }

    init(path: String) { self.path = path }

    func start(handler: @escaping ([String]) -> String) throws {
        self.handler = handler
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure(description: "socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw Failure(description: "bind(\(path)) failed: \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw Failure(description: "listen failed: \(errno)") }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(10) { break }
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let args = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] ?? []
        let handler = self.handler
        let reply = DispatchQueue.main.sync { handler?(args) ?? "error: not ready" }
        let out = Array((reply.hasSuffix("\n") ? reply : reply + "\n").utf8)
        var offset = 0
        while offset < out.count {
            let n = out[offset...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            offset += n
        }
    }
}

extension WindowManager {
    static let ipcUsage = """
    usage: ikkunointictl [-j] <command> [args...]

      dispatch <dispatcher> [args]   run a dispatcher, e.g. `dispatch workspace 2`,
                                     `dispatch movefocus l`, `dispatch exec open -a Notes`
      clients                        managed windows (alias: windows)
      activewindow                   the focused window
      workspaces                     workspaces with windows or on screen
      activeworkspace                the focused workspace
      monitors                       displays and their workspaces
      binds                          key bindings
      reload                         reload ~/.config/ikkunointi/ikkunointi.conf
      -j                             JSON output
    """

    func handleIPC(_ argv: [String]) -> String {
        var args = argv
        let json = args.contains("-j")
        args.removeAll { $0 == "-j" }
        guard let command = args.first?.lowercased() else { return Self.ipcUsage }
        let rest = Array(args.dropFirst())
        flush()
        switch command {
        case "dispatch":
            guard let dispatcher = rest.first else { return "error: dispatch needs a dispatcher" }
            do {
                perform(try Action.parse(dispatcher: dispatcher, args: rest.dropFirst().joined(separator: " ")))
                return "ok"
            } catch {
                return "error: \(error)"
            }
        case "clients", "windows":
            let ids = records.keys.sorted { a, b in
                let wa = state.windows[a]?.workspace ?? 0, wb = state.windows[b]?.workspace ?? 0
                return wa != wb ? wa < wb : a < b
            }
            return render(ids.compactMap(windowInfo), json: json, text: windowLine)
        case "activewindow":
            guard let id = state.focusedWindow, let info = windowInfo(id) else { return json ? "{}" : "no focused window" }
            return render([info], json: json, single: true, text: windowLine)
        case "workspaces":
            return render(workspaceInfos(), json: json, text: workspaceLine)
        case "activeworkspace":
            let info = workspaceInfos().first { $0["focused"] as? Bool == true } ?? [:]
            return render([info], json: json, single: true, text: workspaceLine)
        case "monitors":
            let infos: [[String: Any]] = state.monitors.map { m in
                ["id": Int(m.id), "name": m.name, "frame": rectArray(m.frame), "visibleFrame": rectArray(m.visibleFrame),
                 "activeWorkspace": state.activeWorkspace[m.id] ?? 0, "focused": state.focusedMonitor == m.id]
            }
            return render(infos, json: json) { i in
                let f = i["frame"] as! [Int]
                return "monitor \(i["id"]!) \"\(i["name"]!)\" \(f[2])x\(f[3]) at \(f[0]),\(f[1])  workspace \(i["activeWorkspace"]!)\((i["focused"] as! Bool) ? "  (focused)" : "")"
            }
        case "binds":
            let infos: [[String: Any]] = bindingRows.map { ["keys": $0.keys, "description": $0.description] }
            return render(infos, json: json) { "\(($0["keys"] as! String).padding(toLength: 14, withPad: " ", startingAt: 0)) \($0["description"]!)" }
        case "reload":
            onReloadRequest?()
            let errors = config.errors.map(\.description)
            return errors.isEmpty ? "ok" : "ok, with config errors:\n" + errors.joined(separator: "\n")
        case "version":
            return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        case "help", "-h", "--help":
            return Self.ipcUsage
        default:
            return "error: unknown command '\(command)'\n\n" + Self.ipcUsage
        }
    }

    private func rectArray(_ r: CGRect) -> [Int] {
        [Int(r.minX.rounded()), Int(r.minY.rounded()), Int(r.width.rounded()), Int(r.height.rounded())]
    }

    private func windowInfo(_ id: CGWindowID) -> [String: Any]? {
        guard let rec = records[id], let w = state.windows[id] else { return nil }
        let ws = state.workspace(w.workspace)
        let frame = rec.element.frame ?? .zero
        return [
            "id": Int(id), "pid": Int(rec.watcher.pid), "app": rec.watcher.name,
            "bundle": rec.watcher.bundleID ?? "", "title": rec.element.string(kAXTitleAttribute) ?? rec.title ?? "",
            "workspace": w.workspace, "floating": w.isFloating, "pseudo": w.isPseudo,
            "fullscreen": ws.fullscreen?.id == id ? ws.fullscreen!.mode : -1,
            "hidden": w.isExcluded, "parked": rec.isParked, "focused": state.focusedWindow == id,
            "frame": rectArray(frame),
        ]
    }

    private func windowLine(_ i: [String: Any]) -> String {
        let f = i["frame"] as! [Int]
        var flags: [String] = [(i["floating"] as! Bool) ? "floating" : "tiled"]
        if i["pseudo"] as! Bool { flags.append("pseudo") }
        if (i["fullscreen"] as! Int) >= 0 { flags.append("fullscreen") }
        if i["hidden"] as! Bool { flags.append("minimized/hidden") }
        if i["parked"] as! Bool { flags.append("parked") }
        if i["focused"] as! Bool { flags.append("FOCUSED") }
        let title = (i["title"] as! String).isEmpty ? "" : " — \(i["title"]!)"
        return "\(i["id"]!)  ws \(i["workspace"]!)  \(f[0]),\(f[1]) \(f[2])x\(f[3])  [\(flags.joined(separator: ", "))]  \(i["app"]!)\(title)"
    }

    private func workspaceInfos() -> [[String: Any]] {
        workspaceSummaries().filter { $0.windowCount > 0 || $0.isVisible }.map { s in
            let ws = state.workspace(s.id)
            return ["id": s.id, "windows": s.windowCount, "apps": s.apps, "focused": s.isFocused, "visible": s.isVisible,
                    "monitor": Int(state.monitorShowing(s.id) ?? ws.monitor ?? 0), "lastFocused": Int(ws.lastFocused ?? 0)]
        }
    }

    private func workspaceLine(_ i: [String: Any]) -> String {
        guard let id = i["id"] else { return "none" }
        var flags: [String] = []
        if i["focused"] as? Bool == true { flags.append("focused") }
        if i["visible"] as? Bool == true { flags.append("visible on monitor \(i["monitor"]!)") }
        let apps = (i["apps"] as? [String] ?? []).joined(separator: ", ")
        return "workspace \(id): \(i["windows"]!) window(s)\(apps.isEmpty ? "" : " — \(apps)")\(flags.isEmpty ? "" : "  (\(flags.joined(separator: ", ")))")"
    }

    private func render(_ items: [[String: Any]], json: Bool, single: Bool = false, text: ([String: Any]) -> String) -> String {
        if json {
            let obj: Any = single ? (items.first ?? [:]) : items
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "error: json" }
            return String(decoding: data, as: UTF8.self)
        }
        return items.isEmpty ? "(none)" : items.map(text).joined(separator: "\n")
    }
}
