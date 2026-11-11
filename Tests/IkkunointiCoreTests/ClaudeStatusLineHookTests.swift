import XCTest
@testable import IkkunointiCore

final class ClaudeStatusLineHookTests: XCTestCase {
    var home: URL!
    var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ikkunointi-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func settings() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) as? [String: Any] ?? [:]
    }

    func write(_ json: String) { try! Data(json.utf8).write(to: settingsURL) }

    /// Runs the installed status line the way Claude Code would and returns what it prints.
    func runStatusLine(_ input: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", (settings()["statusLine"] as! [String: Any])["command"] as! String]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        try! p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    func testWrapsExistingStatusLineAndRestoresIt() {
        let original = #"input=$(cat); printf 'it''s %s' "$(echo "$input" | grep -c rate)""#
        let json = try! JSONSerialization.data(withJSONObject: ["theme": "dark", "statusLine": ["type": "command", "command": original, "padding": 2]])
        try! json.write(to: settingsURL)
        let hook = ClaudeStatusLineHook(home: home)
        XCTAssertEqual(hook.install(), .installed)
        XCTAssertEqual(hook.install(), .alreadyInstalled)
        let line = settings()["statusLine"] as! [String: Any]
        XCTAssertEqual(line["padding"] as? Int, 2)
        XCTAssertEqual(settings()["theme"] as? String, "dark")

        let input = #"{"cwd":"/x","rate_limits":{"five_hour":{"used_percentage":80,"resets_at":4102444800}}}"#
        XCTAssertEqual(runStatusLine(input), "its 1")     // the original still renders
        let saved = try! Data(contentsOf: home.appendingPathComponent(".cache/ikkunointi/claude-rate-limits.json"))
        XCTAssertEqual(PlanLimits.parse(saved)?.lowestLeft(at: Date()), 20)
        // Input without limits (session start) must not wipe the saved ones.
        XCTAssertEqual(runStatusLine(#"{"cwd":"/x"}"#), "its 0")
        XCTAssertNotNil(PlanLimits.parse(try! Data(contentsOf: home.appendingPathComponent(".cache/ikkunointi/claude-rate-limits.json"))))

        XCTAssertEqual(hook.uninstall(), .removed)
        XCTAssertEqual((settings()["statusLine"] as! [String: Any])["command"] as? String, original)
        XCTAssertEqual(hook.uninstall(), .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json.ikkunointi-backup").path))
    }

    func testAddsAndRemovesStatusLineWhenThereWasNone() {
        write(#"{"theme":"dark"}"#)
        let hook = ClaudeStatusLineHook(home: home)
        XCTAssertEqual(hook.install(), .installed)
        XCTAssertEqual(runStatusLine(#"{"rate_limits":{"seven_day":{"used_percentage":1,"resets_at":4102444800}}}"#), "")
        XCTAssertEqual(hook.uninstall(), .removed)
        XCTAssertNil(settings()["statusLine"])
        XCTAssertEqual(settings()["theme"] as? String, "dark")
    }

    func testLeavesUnknownSetupsAlone() {
        write("not json")
        XCTAssertEqual(ClaudeStatusLineHook(home: home).install(), .skipped("settings.json is not valid JSON"))
        XCTAssertEqual(try! String(contentsOf: settingsURL, encoding: .utf8), "not json")
        try! FileManager.default.removeItem(at: home.appendingPathComponent(".claude"))
        XCTAssertEqual(ClaudeStatusLineHook(home: home).install(), .skipped("Claude Code is not installed"))
    }
}
