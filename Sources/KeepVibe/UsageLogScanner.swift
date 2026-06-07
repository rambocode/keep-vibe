import Foundation

struct UsageLogRoots {
    var claudeProjects: URL
    var codexSessions: URL
    var cacheFile: URL

    static var `default`: UsageLogRoots {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return UsageLogRoots(
            claudeProjects: home.appendingPathComponent(".claude/projects"),
            codexSessions: home.appendingPathComponent(".codex/sessions"),
            cacheFile: support.appendingPathComponent("KeepVibe/usage-cache-v1.json")
        )
    }
}

enum UsageLogScanner {
    private static let cacheVersion = 1
    private static let retentionDays = 35

    static func summarizeAll(now: Date, roots: UsageLogRoots = .default) -> (claude: AgentUsage, codex: AgentUsage) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var cache = loadCache(from: roots.cacheFile)
        let claudeScan = scanClaude(root: roots.claudeProjects, files: cache.claude, cutoff: cutoff)
        let codexScan = scanCodex(root: roots.codexSessions, files: cache.codex, cutoff: cutoff)
        cache.claude = claudeScan.files
        cache.codex = codexScan.files
        if claudeScan.changed || codexScan.changed {
            saveCache(cache, to: roots.cacheFile)
        }

        return (
            summarizeClaude(files: cache.claude, now: now, cutoff: cutoff),
            summarizeCodex(files: cache.codex, now: now, cutoff: cutoff)
        )
    }

    static func summarizeClaude(now: Date, roots: UsageLogRoots = .default) -> AgentUsage {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var cache = loadCache(from: roots.cacheFile)
        let scan = scanClaude(root: roots.claudeProjects, files: cache.claude, cutoff: cutoff)
        cache.claude = scan.files
        if scan.changed {
            saveCache(cache, to: roots.cacheFile)
        }
        return summarizeClaude(files: cache.claude, now: now, cutoff: cutoff)
    }

    static func summarizeCodex(now: Date, roots: UsageLogRoots = .default) -> AgentUsage {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var cache = loadCache(from: roots.cacheFile)
        let scan = scanCodex(root: roots.codexSessions, files: cache.codex, cutoff: cutoff)
        cache.codex = scan.files
        if scan.changed {
            saveCache(cache, to: roots.cacheFile)
        }
        return summarizeCodex(files: cache.codex, now: now, cutoff: cutoff)
    }
}

// MARK: - Cache model

private struct UsageCache: Codable {
    var version: Int = UsageLogScanner.cacheVersionForCacheModel
    var claude: [String: ClaudeFileCache] = [:]
    var codex: [String: CodexFileCache] = [:]
}

private struct ClaudeFileCache: Codable {
    var size: UInt64
    var mtime: TimeInterval
    var offset: UInt64
    var events: [ClaudeEvent]
}

private struct CodexFileCache: Codable {
    var size: UInt64
    var mtime: TimeInterval
    var offset: UInt64
    var events: [CodexEvent]
}

private struct ClaudeEvent: Codable {
    var timestamp: TimeInterval
    var tokens: Int
    var cost: Double
    var sessionId: String?
    var dedupeKey: String
}

private struct CodexEvent: Codable {
    var timestamp: TimeInterval
    var tokens: Int
    var cost: Double
}

private struct FileSnapshot {
    var size: UInt64
    var mtime: TimeInterval
}

private extension UsageLogScanner {
    static var cacheVersionForCacheModel: Int { cacheVersion }

    static func loadCache(from url: URL) -> UsageCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(UsageCache.self, from: data),
              cache.version == cacheVersion
        else {
            return UsageCache()
        }
        return cache
    }

    static func saveCache(_ cache: UsageCache, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
        } catch {
            // 缓存失败不影响本次展示；下次刷新会重新扫描。
        }
    }
}

// MARK: - Scanning

private extension UsageLogScanner {
    static func scanClaude(root: URL, files cachedFiles: [String: ClaudeFileCache], cutoff: Date) -> (files: [String: ClaudeFileCache], changed: Bool) {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return ([:], !cachedFiles.isEmpty)
        }

        var next = [String: ClaudeFileCache]()
        let snapshots = jsonlSnapshots(root: root, cutoff: cutoff)
        let parser = ClaudeLineParser()
        var changed = Set(cachedFiles.keys) != Set(snapshots.keys)

        for (path, snapshot) in snapshots {
            let cached = cachedFiles[path]
            if let cached,
               snapshot.size == cached.size,
               snapshot.mtime == cached.mtime {
                next[path] = cached
                continue
            }

            let shouldAppend = cached.map { snapshot.size > $0.size && $0.offset <= $0.size } ?? false
            changed = true
            var events = shouldAppend ? (cached?.events ?? []) : []
            let startOffset = shouldAppend ? (cached?.offset ?? 0) : 0

            let offset = readJSONLines(from: URL(fileURLWithPath: path), offset: startOffset) { data in
                guard let result = parser.parse(data) else { return false }
                if let event = result.event, event.date >= cutoff {
                    events.append(event.cached)
                }
                return true
            }

            let retained = events.filter { Date(timeIntervalSince1970: $0.timestamp) >= cutoff }
            next[path] = ClaudeFileCache(
                size: snapshot.size,
                mtime: snapshot.mtime,
                offset: offset,
                events: retained
            )
        }

        return (next, changed)
    }

    static func scanCodex(root: URL, files cachedFiles: [String: CodexFileCache], cutoff: Date) -> (files: [String: CodexFileCache], changed: Bool) {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return ([:], !cachedFiles.isEmpty)
        }

        var next = [String: CodexFileCache]()
        let snapshots = jsonlSnapshots(root: root, cutoff: cutoff)
        let parser = CodexLineParser()
        var changed = Set(cachedFiles.keys) != Set(snapshots.keys)

        for (path, snapshot) in snapshots {
            let cached = cachedFiles[path]
            if let cached,
               snapshot.size == cached.size,
               snapshot.mtime == cached.mtime {
                next[path] = cached
                continue
            }

            let shouldAppend = cached.map { snapshot.size > $0.size && $0.offset <= $0.size } ?? false
            changed = true
            var events = shouldAppend ? (cached?.events ?? []) : []
            let startOffset = shouldAppend ? (cached?.offset ?? 0) : 0

            let offset = readJSONLines(from: URL(fileURLWithPath: path), offset: startOffset) { data in
                guard let result = parser.parse(data) else { return false }
                if let event = result.event, event.date >= cutoff {
                    events.append(event.cached)
                }
                return true
            }

            let retained = events.filter { Date(timeIntervalSince1970: $0.timestamp) >= cutoff }
            next[path] = CodexFileCache(
                size: snapshot.size,
                mtime: snapshot.mtime,
                offset: offset,
                events: retained
            )
        }

        return (next, changed)
    }

    static func jsonlSnapshots(root: URL, cutoff: Date) -> [String: FileSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var snapshots = [String: FileSnapshot]()
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  mtime >= cutoff
            else { continue }

            let size = UInt64(values.fileSize ?? 0)
            snapshots[fileURL.standardizedFileURL.path] = FileSnapshot(
                size: size,
                mtime: mtime.timeIntervalSince1970
            )
        }
        return snapshots
    }

    static func readJSONLines(from url: URL, offset: UInt64, parse: (Data) -> Bool) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return offset
        }

        let newline = UInt8(ascii: "\n")
        var processedOffset = offset
        var buffer = Data()

        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 64 * 1024) }
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: newline) {
                let line = buffer[..<newlineIndex]
                if !line.isEmpty {
                    _ = parse(Data(line))
                }
                let nextIndex = buffer.index(after: newlineIndex)
                processedOffset += UInt64(buffer.distance(from: buffer.startIndex, to: nextIndex))
                buffer.removeSubrange(..<nextIndex)
            }
        }

        if !buffer.isEmpty, parse(buffer) {
            processedOffset += UInt64(buffer.count)
        }

        return processedOffset
    }
}

// MARK: - Line parsers

private struct ParsedClaudeLine {
    var date: Date
    var cached: ClaudeEvent
}

private struct ParsedCodexLine {
    var date: Date
    var cached: CodexEvent
}

private final class ClaudeLineParser {
    private let isoFormatter: ISO8601DateFormatter

    init() {
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parse(_ data: Data) -> ParsedClaudeLine? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let typeVal = obj["type"] as? String, typeVal == "assistant" else {
            return ParsedClaudeLine(date: .distantPast, cached: ignoredClaudeEvent)
        }
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else {
            return ParsedClaudeLine(date: .distantPast, cached: ignoredClaudeEvent)
        }

        let dedupeKey: String
        if let msgId = message["id"] as? String, !msgId.isEmpty {
            dedupeKey = msgId
        } else if let reqId = obj["requestId"] as? String, !reqId.isEmpty {
            dedupeKey = reqId
        } else {
            return ParsedClaudeLine(date: .distantPast, cached: ignoredClaudeEvent)
        }

        guard let tsStr = obj["timestamp"] as? String,
              let ts = isoFormatter.date(from: tsStr)
        else {
            return ParsedClaudeLine(date: .distantPast, cached: ignoredClaudeEvent)
        }

        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheReadTok = usage["cache_read_input_tokens"] as? Int ?? 0
        let totalTokens = inputTokens + outputTokens + cacheCreation + cacheReadTok
        let model = message["model"] as? String ?? ""
        let cost = Pricing.claudeCost(
            model: model,
            input: inputTokens,
            output: outputTokens,
            cacheWrite: cacheCreation,
            cacheRead: cacheReadTok
        )

        return ParsedClaudeLine(
            date: ts,
            cached: ClaudeEvent(
                timestamp: ts.timeIntervalSince1970,
                tokens: totalTokens,
                cost: cost,
                sessionId: obj["sessionId"] as? String,
                dedupeKey: dedupeKey
            )
        )
    }

    private var ignoredClaudeEvent: ClaudeEvent {
        ClaudeEvent(timestamp: 0, tokens: 0, cost: 0, sessionId: nil, dedupeKey: "")
    }
}

private final class CodexLineParser {
    private let fractionalFormatter: ISO8601DateFormatter
    private let wholeSecondFormatter: ISO8601DateFormatter

    init() {
        fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSecondFormatter = ISO8601DateFormatter()
        wholeSecondFormatter.formatOptions = [.withInternetDateTime]
    }

    func parse(_ data: Data) -> ParsedCodexLine? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = obj["type"] as? String, type == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String, payloadType == "token_count"
        else {
            return ParsedCodexLine(date: .distantPast, cached: ignoredCodexEvent)
        }

        guard let tsStr = obj["timestamp"] as? String,
              let ts = fractionalFormatter.date(from: tsStr) ?? wholeSecondFormatter.date(from: tsStr)
        else {
            return ParsedCodexLine(date: .distantPast, cached: ignoredCodexEvent)
        }

        guard let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any]
        else {
            return ParsedCodexLine(date: .distantPast, cached: ignoredCodexEvent)
        }

        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let cachedInput = usage["cached_input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let reasoningOut = usage["reasoning_output_tokens"] as? Int ?? 0
        let totalTokens = usage["total_tokens"] as? Int ?? 0
        let cost = Pricing.codexCost(
            input: inputTokens,
            cachedInput: cachedInput,
            output: outputTokens + reasoningOut
        )

        return ParsedCodexLine(
            date: ts,
            cached: CodexEvent(timestamp: ts.timeIntervalSince1970, tokens: totalTokens, cost: cost)
        )
    }

    private var ignoredCodexEvent: CodexEvent {
        CodexEvent(timestamp: 0, tokens: 0, cost: 0)
    }
}

// MARK: - Summaries

private extension UsageLogScanner {
    static func summarizeClaude(files: [String: ClaudeFileCache], now: Date, cutoff: Date) -> AgentUsage {
        let bounds = timeBounds(now: now)
        let fiveMinAgo = now.addingTimeInterval(-5 * 60)
        var seenIds = Set<String>()
        var todayTokens = 0; var todayCost = 0.0
        var weekTokens = 0; var weekCost = 0.0
        var monthTokens = 0; var monthCost = 0.0
        var sessionLastSeen = [String: Date]()
        var windowTimestamps = [Date]()
        var windowTokens = [Int]()

        for event in files.values.flatMap(\.events).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !event.dedupeKey.isEmpty,
                  seenIds.insert(event.dedupeKey).inserted
            else { continue }

            let ts = Date(timeIntervalSince1970: event.timestamp)
            guard ts >= cutoff else { continue }

            if ts >= bounds.month { monthTokens += event.tokens; monthCost += event.cost }
            if ts >= bounds.week { weekTokens += event.tokens; weekCost += event.cost }
            if ts >= bounds.day { todayTokens += event.tokens; todayCost += event.cost }

            windowTimestamps.append(ts)
            windowTokens.append(event.tokens)

            if let sessionId = event.sessionId, !sessionId.isEmpty {
                if sessionLastSeen[sessionId].map({ ts > $0 }) ?? true {
                    sessionLastSeen[sessionId] = ts
                }
            }
        }

        return AgentUsage(
            todayTokens: todayTokens,
            todayCost: todayCost,
            weekTokens: weekTokens,
            weekCost: weekCost,
            monthTokens: monthTokens,
            monthCost: monthCost,
            window: computeWindow(timestamps: windowTimestamps, tokens: windowTokens, now: now),
            activeSessions: sessionLastSeen.values.filter { $0 >= fiveMinAgo }.count,
            costIsApprox: false
        )
    }

    static func summarizeCodex(files: [String: CodexFileCache], now: Date, cutoff: Date) -> AgentUsage {
        let bounds = timeBounds(now: now)
        let activeWindow = now.addingTimeInterval(-5 * 60)
        var todayTokens = 0; var todayCost = 0.0
        var weekTokens = 0; var weekCost = 0.0
        var monthTokens = 0; var monthCost = 0.0
        var activeSessions = 0

        for file in files.values {
            var fileLastEventTime: Date?
            for event in file.events {
                let ts = Date(timeIntervalSince1970: event.timestamp)
                guard ts >= cutoff else { continue }

                if ts >= bounds.day {
                    todayTokens += event.tokens
                    todayCost += event.cost
                }
                if ts >= bounds.week {
                    weekTokens += event.tokens
                    weekCost += event.cost
                }
                if ts >= bounds.month {
                    monthTokens += event.tokens
                    monthCost += event.cost
                }
                if fileLastEventTime.map({ ts > $0 }) ?? true {
                    fileLastEventTime = ts
                }
            }
            if let fileLastEventTime, fileLastEventTime >= activeWindow {
                activeSessions += 1
            }
        }

        return AgentUsage(
            todayTokens: todayTokens,
            todayCost: todayCost,
            weekTokens: weekTokens,
            weekCost: weekCost,
            monthTokens: monthTokens,
            monthCost: monthCost,
            window: nil,
            activeSessions: activeSessions,
            costIsApprox: true
        )
    }

    static func timeBounds(now: Date) -> (day: Date, week: Date, month: Date) {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let day = cal.startOfDay(for: now)
        let weekdayIdx = (cal.component(.weekday, from: now) - cal.firstWeekday + 7) % 7
        let week = cal.date(byAdding: .day, value: -weekdayIdx, to: day)!
        var comps = cal.dateComponents([.year, .month], from: now)
        comps.day = 1
        let month = cal.date(from: comps)!
        return (day, week, month)
    }

    private struct Block {
        var start: Date
        var tokens: Int
    }

    static func computeWindow(timestamps: [Date], tokens: [Int], now: Date) -> WindowStat? {
        guard !timestamps.isEmpty else { return nil }

        let indices = timestamps.indices.sorted { timestamps[$0] < timestamps[$1] }
        let sortedTS = indices.map { timestamps[$0] }
        let sortedTok = indices.map { tokens[$0] }
        let fiveHours: TimeInterval = 5 * 3600

        var blocks = [Block]()
        for i in sortedTS.indices {
            let ts = sortedTS[i]
            let tok = sortedTok[i]
            if let last = blocks.last, ts.timeIntervalSince(last.start) < fiveHours {
                blocks[blocks.count - 1].tokens += tok
            } else {
                blocks.append(Block(start: ts, tokens: tok))
            }
        }

        var currentBlock: Block?
        for block in blocks.reversed() {
            let blockEnd = block.start.addingTimeInterval(fiveHours)
            if block.start <= now && now < blockEnd {
                currentBlock = block
                break
            }
        }
        if currentBlock == nil {
            currentBlock = blocks.last
        }

        guard let block = currentBlock else { return nil }

        let blockEnd = block.start.addingTimeInterval(fiveHours)
        let resetIn = max(0, blockEnd.timeIntervalSince(now))
        let elapsed = fiveHours - resetIn
        let usedFrac = min(1.0, elapsed / fiveHours)
        let elapsedMinutes = max(1.0, elapsed / 60.0)
        let tokPerMin = Double(block.tokens) / elapsedMinutes

        return WindowStat(
            tokens: block.tokens,
            tokensPerMin: tokPerMin,
            resetIn: resetIn > 0 ? resetIn : nil,
            usedFraction: usedFrac
        )
    }
}

private extension ParsedClaudeLine {
    var event: (date: Date, cached: ClaudeEvent)? {
        cached.dedupeKey.isEmpty ? nil : (date, cached)
    }
}

private extension ParsedCodexLine {
    var event: (date: Date, cached: CodexEvent)? {
        cached.tokens == 0 && cached.cost == 0 && date == .distantPast ? nil : (date, cached)
    }
}
