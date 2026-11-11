import XCTest
@testable import IkkunointiCore

final class ClaudeUsageTests: XCTestCase {
    func line(_ id: String, _ time: String, out: Int, type: String = "assistant") -> String {
        """
        {"type":"\(type)","timestamp":"\(time)","message":{"id":"\(id)","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":5000,"output_tokens":\(out)}}}
        """
    }

    func testCountsEachResponseOnceAndRespectsCutoff() {
        let text = [
            line("a", "2026-11-11T08:00:00.000Z", out: 10),
            line("a", "2026-11-11T08:00:01.000Z", out: 40),      // same response, later block
            line("b", "2026-11-11T09:00:00Z", out: 5),
            line("old", "2026-11-10T09:00:00.000Z", out: 999),
            line("u", "2026-11-11T09:00:00.000Z", out: 7, type: "user"),
            "{\"type\":\"user\",\"message\":{\"content\":\"mentions \\\"usage\\\" only\"}}",
            "not json \"usage\"",
        ].joined(separator: "\n")
        let entries = ClaudeUsage.entries(in: Data(text.utf8))
        XCTAssertEqual(entries.count, 4)
        let since = ISO8601DateFormatter().date(from: "2026-11-11T00:00:00Z")!
        XCTAssertEqual(ClaudeUsage.total(entries, since: since),
                       TokenUsage(input: 4, output: 45, cacheWrite: 200, cacheRead: 10000))
        XCTAssertEqual(ClaudeUsage.total(entries, since: since).fresh, 249)
    }

    func testPlanLimits() {
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":2000},"seven_day":{"used_percentage":91,"resets_at":9000}},"at":1500.5}"#
        let limits = PlanLimits.parse(Data(json.utf8))!
        XCTAssertEqual(limits.fiveHour?.left(at: Date(timeIntervalSince1970: 1600)), 76.5)
        XCTAssertEqual(limits.lowestLeft(at: Date(timeIntervalSince1970: 1600)), 9)
        // The 5-hour window has reset; the weekly one still binds.
        XCTAssertEqual(limits.fiveHour?.left(at: Date(timeIntervalSince1970: 2500)), 100)
        XCTAssertEqual(limits.lowestLeft(at: Date(timeIntervalSince1970: 9500)), 100)
        XCTAssertEqual(limits.updated, Date(timeIntervalSince1970: 1500.5))
        // Bare object, one window missing.
        let bare = PlanLimits.parse(Data(#"{"five_hour":{"used_percentage":120,"resets_at":2000}}"#.utf8))!
        XCTAssertNil(bare.sevenDay)
        XCTAssertEqual(bare.lowestLeft(at: Date(timeIntervalSince1970: 0)), 0)
        XCTAssertNil(PlanLimits.parse(Data("{}".utf8)))
        XCTAssertNil(PlanLimits.parse(Data("null".utf8)))
    }

    func testActivityFollowsTranscriptWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ikkunointi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(ClaudeActivity.isWorking(root: root))
        let dir = root.appendingPathComponent("proj/session/subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("a.jsonl"))
        try Data("x".utf8).write(to: root.appendingPathComponent("proj/notes.txt"))
        XCTAssertTrue(ClaudeActivity.isWorking(root: root))
        XCTAssertFalse(ClaudeActivity.isWorking(now: Date().addingTimeInterval(301), root: root))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: dir.appendingPathComponent("a.jsonl").path)
        XCTAssertFalse(ClaudeActivity.isWorking(root: root))
    }

    func testFormat() {
        XCTAssertEqual(ClaudeUsage.format(950), "950")
        XCTAssertEqual(ClaudeUsage.format(1234), "1.2k")
        XCTAssertEqual(ClaudeUsage.format(12_400), "12k")
        XCTAssertEqual(ClaudeUsage.format(1_250_000), "1.2M")
        XCTAssertEqual(ClaudeUsage.format(42_000_000), "42M")
    }
}
