import Foundation

/// Token counts as Claude Code records them per API response.
public struct TokenUsage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    /// Everything except cache reads, which dwarf the rest and cost a fraction.
    public var fresh: Int { input + output + cacheWrite }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
}

public struct UsageEntry: Equatable, Sendable {
    /// API message id; one response is written as several transcript lines sharing it.
    public let id: String
    public let date: Date
    public let usage: TokenUsage
}

/// Reads token usage out of Claude Code's session transcripts (~/.claude/projects/**/*.jsonl).
/// Local files only: no network, no credentials. It cannot see usage from other devices or
/// claude.ai, nor how much of a plan limit is left.
public enum ClaudeUsage {
    private static let marker = Data("\"usage\"".utf8)

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func parse(line: Data) -> UsageEntry? {
        guard line.range(of: marker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let id = message["id"] as? String,
              let u = message["usage"] as? [String: Any],
              let stamp = obj["timestamp"] as? String, let date = date(stamp) else { return nil }
        func n(_ key: String) -> Int { (u[key] as? NSNumber)?.intValue ?? 0 }
        return UsageEntry(id: id, date: date, usage: TokenUsage(
            input: n("input_tokens"), output: n("output_tokens"),
            cacheWrite: n("cache_creation_input_tokens"), cacheRead: n("cache_read_input_tokens")))
    }

    public static func entries(in transcript: Data) -> [UsageEntry] {
        transcript.split(separator: 10).compactMap { parse(line: Data($0)) }
    }

    /// Sum of usage since `since`, counting each API response once (its last transcript line).
    public static func total(_ entries: [UsageEntry], since: Date) -> TokenUsage {
        var latest: [String: TokenUsage] = [:]
        for e in entries where e.date >= since { latest[e.id] = e.usage }
        return latest.values.reduce(TokenUsage(), +)
    }

    /// 950, 12k, 1.2M
    public static func format(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1000)
        case ..<1_000_000: return "\(Int((Double(n) / 1000).rounded()))k"
        case ..<10_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return "\(Int((Double(n) / 1_000_000).rounded()))M"
        }
    }
}

/// Whether a Claude Code agent is busy, judged by its session transcripts: they are appended
/// to on every message and tool call (subagents included).
public enum ClaudeActivity {
    public static var transcripts: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// When any transcript under `root` was last written.
    public static func lastWrite(root: URL = transcripts) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
        var latest: Date?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let d = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate else { continue }
            if latest.map({ d > $0 }) ?? true { latest = d }
        }
        return latest
    }

    /// Working means a write within `grace`. A long silent tool call (a big build, say) writes
    /// nothing, so the grace period has to cover those.
    public static func isWorking(now: Date = Date(), grace: TimeInterval = 300, root: URL = transcripts) -> Bool {
        lastWrite(root: root).map { now.timeIntervalSince($0) < grace } ?? false
    }
}

/// One rate-limit window of a Claude subscription.
public struct LimitWindow: Equatable, Sendable {
    /// 0...100
    public let usedPercent: Double
    public let resetsAt: Date

    /// Percent left; a window whose reset time has passed is full again.
    public func left(at now: Date) -> Double {
        now >= resetsAt ? 100 : min(100, max(0, 100 - usedPercent))
    }
}

/// Plan usage as Claude Code hands it to a status line command (`rate_limits`). Claude Code
/// offers no other supported way to read it, so the status line saves it to `fileURL` and
/// the app reads that file. It is only as fresh as the last status line update.
public struct PlanLimits: Equatable, Sendable {
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    /// When the status line wrote the file.
    public var updated: Date?

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/ikkunointi/claude-rate-limits.json")
    }

    /// Accepts `{"rate_limits": {...}, "at": epoch}` or the bare `rate_limits` object.
    public static func parse(_ data: Data) -> PlanLimits? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let limits = obj["rate_limits"] as? [String: Any] ?? obj
        func window(_ key: String) -> LimitWindow? {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
        let out = PlanLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"),
                             updated: (obj["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        return out.fiveHour == nil && out.sevenDay == nil ? nil : out
    }

    /// The tighter of the two windows: what runs out first.
    public func lowestLeft(at now: Date) -> Double? {
        [fiveHour, sevenDay].compactMap { $0?.left(at: now) }.min()
    }
}

/// Scans the transcript directory, re-reading only files that changed since the last scan.
public final class ClaudeUsageScanner {
    private struct Cached { let modified: Date; let size: Int; let entries: [UsageEntry] }
    private var cache: [String: Cached] = [:]
    private let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    /// Entries from every transcript modified at or after `since`.
    public func scan(since: Date) -> [UsageEntry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [UsageEntry] = []
        var live: [String: Cached] = [:]
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let modified = v.contentModificationDate, modified >= since, let size = v.fileSize else { continue }
            let hit: Cached
            if let c = cache[url.path], c.modified == modified, c.size == size {
                hit = c
            } else {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                hit = Cached(modified: modified, size: size, entries: ClaudeUsage.entries(in: data))
            }
            live[url.path] = hit
            out += hit.entries
        }
        cache = live
        return out
    }
}
