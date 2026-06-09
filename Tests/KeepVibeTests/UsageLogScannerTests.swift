import XCTest
@testable import KeepVibe

final class UsageLogScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepVibeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testInitialScanAndAppendReuseCache() throws {
        let roots = try makeRoots()
        let claudeFile = roots.claudeProjects.appendingPathComponent("project/session.jsonl")
        let codexFile = roots.codexSessions.appendingPathComponent("2026/06/session.jsonl")

        try writeLines([
            claudeLine(id: "c1", timestamp: "2026-06-07T01:00:00.000Z", sessionId: "s1", input: 10, output: 20),
            claudeLine(id: "c2", timestamp: "2026-06-07T02:00:00.000Z", sessionId: "s1", input: 5, output: 5)
        ], to: claudeFile)
        try writeLines([
            codexLine(timestamp: "2026-06-07T01:30:00.000Z", input: 100, cachedInput: 20, output: 30, reasoning: 10, total: 130)
        ], to: codexFile)

        let now = date("2026-06-07T03:00:00.000Z")
        var usage = UsageLogScanner.summarizeAll(now: now, roots: roots)

        XCTAssertEqual(usage.claude.todayTokens, 40)
        XCTAssertEqual(usage.claude.weekTokens, 40)
        XCTAssertEqual(usage.claude.monthTokens, 40)
        XCTAssertEqual(usage.claude.activeSessions, 0)
        // Codex 口径：total_tokens = input + output（cached_input 是 input 子集、reasoning 不计入）= 100 + 30
        XCTAssertEqual(usage.codex.todayTokens, 130)
        XCTAssertEqual(usage.codex.todayBreakdown.reasoning, 10)

        try appendLines([
            claudeLine(id: "c3", timestamp: "2026-06-07T03:01:00.000Z", sessionId: "s2", input: 1, output: 2),
            codexLine(timestamp: "2026-06-07T03:01:00.000Z", input: 10, cachedInput: 0, output: 5, reasoning: 0, total: 15)
        ], claudeFile: claudeFile, codexFile: codexFile)

        usage = UsageLogScanner.summarizeAll(now: date("2026-06-07T03:03:00.000Z"), roots: roots)

        XCTAssertEqual(usage.claude.todayTokens, 43)
        XCTAssertEqual(usage.claude.activeSessions, 1)
        // 130 + (10 + 5) = 145
        XCTAssertEqual(usage.codex.todayTokens, 145)
        XCTAssertEqual(usage.codex.todayBreakdown.reasoning, 10)
        XCTAssertEqual(usage.codex.activeSessions, 1)
    }

    func testRewriteSameFileReplacesCachedEvents() throws {
        let roots = try makeRoots()
        let claudeFile = roots.claudeProjects.appendingPathComponent("project/session.jsonl")

        try writeLines([
            claudeLine(id: "old", timestamp: "2026-06-07T01:00:00.000Z", input: 100, output: 0)
        ], to: claudeFile)

        var usage = UsageLogScanner.summarizeAll(now: date("2026-06-07T02:00:00.000Z"), roots: roots)
        XCTAssertEqual(usage.claude.todayTokens, 100)

        try writeLines([
            claudeLine(id: "new", timestamp: "2026-06-07T01:30:00.000Z", input: 7, output: 8)
        ], to: claudeFile)

        usage = UsageLogScanner.summarizeAll(now: date("2026-06-07T02:00:00.000Z"), roots: roots)
        XCTAssertEqual(usage.claude.todayTokens, 15)
    }

    func testClaudeDedupeAcrossFiles() throws {
        let roots = try makeRoots()
        try writeLines([
            claudeLine(id: "dup", timestamp: "2026-06-07T01:00:00.000Z", input: 10, output: 0)
        ], to: roots.claudeProjects.appendingPathComponent("a/session.jsonl"))
        try writeLines([
            claudeLine(id: "dup", timestamp: "2026-06-07T01:01:00.000Z", input: 99, output: 0)
        ], to: roots.claudeProjects.appendingPathComponent("b/session.jsonl"))

        let usage = UsageLogScanner.summarizeAll(now: date("2026-06-07T02:00:00.000Z"), roots: roots)

        XCTAssertEqual(usage.claude.todayTokens, 10)
    }

    func testCachedEventsRebucketAcrossDayWeekAndMonth() throws {
        let roots = try makeRoots()
        let claudeFile = roots.claudeProjects.appendingPathComponent("project/session.jsonl")
        try writeLines([
            claudeLine(id: "may", timestamp: "2026-05-31T23:30:00.000+08:00", input: 10, output: 0),
            claudeLine(id: "jun", timestamp: "2026-06-01T01:00:00.000+08:00", input: 20, output: 0),
            claudeLine(id: "today", timestamp: "2026-06-07T01:00:00.000+08:00", input: 30, output: 0)
        ], to: claudeFile)

        var usage = UsageLogScanner.summarizeAll(now: date("2026-06-07T02:00:00.000+08:00"), roots: roots)
        XCTAssertEqual(usage.claude.todayTokens, 30)
        XCTAssertEqual(usage.claude.weekTokens, 50)
        XCTAssertEqual(usage.claude.monthTokens, 50)

        usage = UsageLogScanner.summarizeAll(now: date("2026-06-08T02:00:00.000+08:00"), roots: roots)
        XCTAssertEqual(usage.claude.todayTokens, 0)
        XCTAssertEqual(usage.claude.weekTokens, 0)
        XCTAssertEqual(usage.claude.monthTokens, 50)
    }

    func testYesterdayRangeUsesPreviousCalendarDayForClaudeAndCodex() throws {
        let roots = try makeRoots()
        let claudeFile = roots.claudeProjects.appendingPathComponent("project/session.jsonl")
        let codexFile = roots.codexSessions.appendingPathComponent("2026/06/session.jsonl")

        try writeLines([
            claudeLine(id: "before-yesterday", timestamp: "2026-06-06T23:59:00.000+08:00", input: 7, output: 0),
            claudeLine(id: "yesterday", timestamp: "2026-06-07T12:00:00.000+08:00", input: 20, output: 3),
            claudeLine(id: "today", timestamp: "2026-06-08T09:00:00.000+08:00", input: 11, output: 1)
        ], to: claudeFile)
        try writeLines([
            codexLine(timestamp: "2026-06-07T13:00:00.000+08:00", input: 30, cachedInput: 5, output: 4, reasoning: 2, total: 34),
            codexLine(timestamp: "2026-06-08T09:30:00.000+08:00", input: 40, cachedInput: 10, output: 6, reasoning: 3, total: 46)
        ], to: codexFile)

        let usage = UsageLogScanner.summarizeAll(now: date("2026-06-08T10:00:00.000+08:00"), roots: roots)

        XCTAssertEqual(usage.claude.todayTokens, 12)
        XCTAssertEqual(usage.claude.yesterdayTokens, 23)
        XCTAssertEqual(usage.claude.weekTokens, 12)
        XCTAssertEqual(usage.claude.monthTokens, 42)
        XCTAssertEqual(usage.codex.todayTokens, 46)
        XCTAssertEqual(usage.codex.yesterdayTokens, 34)
        XCTAssertEqual(usage.codex.yesterdayBreakdown.reasoning, 2)
        XCTAssertEqual(usage.codex.weekTokens, 46)
    }

    private func makeRoots() throws -> UsageLogRoots {
        let claude = tempRoot.appendingPathComponent("claude/projects")
        let codex = tempRoot.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return UsageLogRoots(
            claudeProjects: claude,
            codexSessions: codex,
            cacheFile: tempRoot.appendingPathComponent("Application Support/KeepVibe/usage-cache-v1.json")
        )
    }

    private func writeLines(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendLines(_ lines: [String], claudeFile: URL, codexFile: URL) throws {
        try appendLine(lines[0], to: claudeFile)
        try appendLine(lines[1], to: codexFile)
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }

    private func claudeLine(
        id: String,
        timestamp: String,
        sessionId: String = "session",
        input: Int,
        output: Int
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","sessionId":"\(sessionId)","message":{"id":"\(id)","model":"claude-sonnet-4","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }

    private func codexLine(
        timestamp: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int
    ) -> String {
        """
        {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cachedInput),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)}}}}
        """
    }
}

final class ExternalUsageDecodingTests: XCTestCase {
    func testDecodesNestedRangesAndGrokTokenOnlyUsage() throws {
        let json = """
        {
          "codex": {
            "ranges": {
              "today": {"in": 10, "out": 5, "reason": 2, "cost": 0.1, "sessions": 1}
            },
            "p5": 63.5,
            "pw": 12.0,
            "r5": 1781000000,
            "rw": 1781200000,
            "plan": "pro"
          },
          "grok": {
            "ranges": {
              "today": {"tokens": 1234, "sessions": 2, "turns": 4},
              "yesterday": {"tokens": 1111, "sessions": 1},
              "week": {"tokens": 2345, "sessions": 3},
              "month": {"tokens": 3456, "sessions": 4},
              "year": {"tokens": 4567, "sessions": 5}
            },
            "model": "grok"
          }
        }
        """.data(using: .utf8)!

        let usage = try JSONDecoder().decode(ExternalUsage.self, from: json)

        XCTAssertEqual(usage.codex?.p5, 63.5)
        XCTAssertEqual(usage.codex?.r5, 1_781_000_000)
        XCTAssertEqual(usage.codex?.pw, 12.0)
        XCTAssertEqual(usage.grok?.today?.inputTokens, 1234)
        XCTAssertEqual(usage.grok?.today?.outputTokens, 0)
        XCTAssertEqual(usage.grok?.today?.cost, 0)
        XCTAssertEqual(usage.grok?.yesterday?.inputTokens, 1111)
        XCTAssertEqual(usage.grok?.year?.inputTokens, 4567)
    }
}

@MainActor
final class SitReminderTests: XCTestCase {
    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: SitReminder.enabledKey)
        UserDefaults.standard.removeObject(forKey: SitReminder.intervalKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: SitReminder.enabledKey)
        UserDefaults.standard.removeObject(forKey: SitReminder.intervalKey)
    }

    func testTickNotifiesAfterContinuousUseInterval() {
        UserDefaults.standard.set(1, forKey: SitReminder.intervalKey)
        let clock = SitReminderTestClock()
        var messages: [String] = []
        let reminder = SitReminder(
            idleSecondsProvider: { clock.idle },
            nowProvider: { clock.now },
            notify: { messages.append($0) }
        )

        XCTAssertFalse(reminder.tick())
        clock.now = Date(timeIntervalSince1970: 61)

        XCTAssertTrue(reminder.tick())
        XCTAssertEqual(messages, ["已连续用机 1 分钟，起来活动一下"])
    }

    func testAwayIdleResetsContinuousUseTimer() {
        UserDefaults.standard.set(1, forKey: SitReminder.intervalKey)
        let clock = SitReminderTestClock()
        var messages: [String] = []
        let reminder = SitReminder(
            idleSecondsProvider: { clock.idle },
            nowProvider: { clock.now },
            notify: { messages.append($0) }
        )

        XCTAssertFalse(reminder.tick())
        clock.now = Date(timeIntervalSince1970: 30)
        clock.idle = SitReminder.awayThresholdSeconds
        XCTAssertFalse(reminder.tick())

        clock.idle = 0
        clock.now = Date(timeIntervalSince1970: 91)
        XCTAssertFalse(reminder.tick())
        XCTAssertTrue(messages.isEmpty)

        clock.now = Date(timeIntervalSince1970: 152)
        XCTAssertTrue(reminder.tick())
        XCTAssertEqual(messages.count, 1)
    }
}

@MainActor
private final class SitReminderTestClock {
    var now = Date(timeIntervalSince1970: 0)
    var idle: TimeInterval = 0
}
