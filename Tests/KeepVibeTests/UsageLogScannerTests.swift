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
            codexLine(timestamp: "2026-06-07T01:30:00.000Z", input: 100, cachedInput: 20, output: 30, reasoning: 10, total: 140)
        ], to: codexFile)

        let now = date("2026-06-07T03:00:00.000Z")
        var usage = UsageLogScanner.summarizeAll(now: now, roots: roots)

        XCTAssertEqual(usage.claude.todayTokens, 40)
        XCTAssertEqual(usage.claude.weekTokens, 40)
        XCTAssertEqual(usage.claude.monthTokens, 40)
        XCTAssertEqual(usage.claude.activeSessions, 0)
        XCTAssertEqual(usage.codex.todayTokens, 140)

        try appendLines([
            claudeLine(id: "c3", timestamp: "2026-06-07T03:01:00.000Z", sessionId: "s2", input: 1, output: 2),
            codexLine(timestamp: "2026-06-07T03:01:00.000Z", input: 10, cachedInput: 0, output: 5, reasoning: 0, total: 15)
        ], claudeFile: claudeFile, codexFile: codexFile)

        usage = UsageLogScanner.summarizeAll(now: date("2026-06-07T03:03:00.000Z"), roots: roots)

        XCTAssertEqual(usage.claude.todayTokens, 43)
        XCTAssertEqual(usage.claude.activeSessions, 1)
        XCTAssertEqual(usage.codex.todayTokens, 155)
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
