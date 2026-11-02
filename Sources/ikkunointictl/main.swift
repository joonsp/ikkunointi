import Foundation
import IkkunointiCore

// hyprctl-style client: forwards its arguments to the running app over a Unix socket.

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args == ["-h"] || args == ["--help"] {
    print("""
    usage: ikkunointictl [-j] <command> [args...]

      dispatch <dispatcher> [args]   e.g. `dispatch workspace 2`, `dispatch movefocus l`
      clients | activewindow | workspaces | activeworkspace | monitors | binds | reload
      -j                             JSON output
    """)
    exit(args.isEmpty ? 1 : 0)
}

let path = IPC.socketPath
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
    fputs("ikkunointictl: socket() failed\n", stderr)
    exit(2)
}
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(path.utf8)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: pathBytes.prefix(raw.count - 1))
    raw[min(pathBytes.count, raw.count - 1)] = 0
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else {
    fputs("ikkunointictl: cannot connect to \(path). Is Ikkunointi running?\n", stderr)
    exit(2)
}

var payload = try! JSONSerialization.data(withJSONObject: args)
payload.append(10)
_ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
shutdown(fd, SHUT_WR)

var reply = Data()
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    reply.append(contentsOf: buffer[0..<n])
}
close(fd)
let text = String(decoding: reply, as: UTF8.self)
FileHandle.standardOutput.write(Data(text.utf8))
exit(text.hasPrefix("error") ? 1 : 0)
