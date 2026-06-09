import Foundation
import SwiftUI

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
    private static let cacheVersion = 3   // 升到 3：ClaudeEvent 加 model；ClaudeFileCache 加 cwd
    private static let retentionDays = 366

    static func summarizeAll(now: Date, roots: UsageLogRoots = .default)
        -> (claude: AgentUsage, codex: AgentUsage, dashboard: DashboardData) {
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
            summarizeCodex(files: cache.codex, now: now, cutoff: cutoff),
            buildDashboard(claudeFiles: cache.claude, codexFiles: cache.codex, now: now)
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
    var cwd: String?          // 从 JSONL user 消息提取的项目目录
}

private struct CodexFileCache: Codable {
    var size: UInt64
    var mtime: TimeInterval
    var offset: UInt64
    var events: [CodexEvent]
}

private struct ClaudeEvent: Codable {
    var timestamp: TimeInterval
    var inputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    var cost: Double
    var sessionId: String?
    var dedupeKey: String
    var model: String         // 模型 id，如 "claude-opus-4-7"
    var tokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
}

private struct CodexEvent: Codable {
    var timestamp: TimeInterval
    var inputTokens: Int
    var cachedTokens: Int   // cached_input：是 inputTokens 的子集，不可再次相加
    var outputTokens: Int
    var reasoningTokens: Int
    var cost: Double
    // 对齐 last_token_usage.total_tokens = input + output（cached 已含于 input、reasoning 不计入）
    var tokens: Int { inputTokens + outputTokens }
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

            // 提取 cwd（优先复用已缓存值；新文件从头扫第一个 user 消息）
            var cwd: String? = shouldAppend ? cached?.cwd : nil
            if cwd == nil {
                _ = readJSONLines(from: URL(fileURLWithPath: path), offset: 0) { data in
                    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let type = obj["type"] as? String, type == "user",
                          let c = obj["cwd"] as? String, !c.isEmpty else { return true }
                    cwd = c
                    return false  // 找到即停止
                }
            }

            let retained = events.filter { Date(timeIntervalSince1970: $0.timestamp) >= cutoff }
            next[path] = ClaudeFileCache(
                size: snapshot.size,
                mtime: snapshot.mtime,
                offset: offset,
                events: retained,
                cwd: cwd
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

        let inputTokens   = usage["input_tokens"] as? Int ?? 0
        let outputTokens  = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheReadTok  = usage["cache_read_input_tokens"] as? Int ?? 0
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
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheWriteTokens: cacheCreation,
                cacheReadTokens: cacheReadTok,
                cost: cost,
                sessionId: obj["sessionId"] as? String,
                dedupeKey: dedupeKey,
                model: model
            )
        )
    }

    private var ignoredClaudeEvent: ClaudeEvent {
        ClaudeEvent(timestamp: 0, inputTokens: 0, outputTokens: 0,
                    cacheWriteTokens: 0, cacheReadTokens: 0,
                    cost: 0, sessionId: nil, dedupeKey: "", model: "")
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

        let inputTokens  = usage["input_tokens"] as? Int ?? 0
        let cachedInput  = usage["cached_input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let reasoningOut = usage["reasoning_output_tokens"] as? Int ?? 0
        let cost = Pricing.codexCost(
            input: inputTokens,
            cachedInput: cachedInput,
            output: outputTokens + reasoningOut
        )

        return ParsedCodexLine(
            date: ts,
            cached: CodexEvent(
                timestamp: ts.timeIntervalSince1970,
                inputTokens: inputTokens,
                cachedTokens: cachedInput,
                outputTokens: outputTokens,
                reasoningTokens: reasoningOut,
                cost: cost
            )
        )
    }

    private var ignoredCodexEvent: CodexEvent {
        CodexEvent(timestamp: 0, inputTokens: 0, cachedTokens: 0,
                   outputTokens: 0, reasoningTokens: 0, cost: 0)
    }
}

// MARK: - Summaries

private extension UsageLogScanner {
    static func summarizeClaude(files: [String: ClaudeFileCache], now: Date, cutoff: Date) -> AgentUsage {
        let bounds = timeBounds(now: now)
        let fiveMinAgo = now.addingTimeInterval(-5 * 60)
        var seenIds = Set<String>()
        var todayCost = 0.0, weekCost = 0.0, monthCost = 0.0, yearCost = 0.0
        var today = TokenBreakdown(), week = TokenBreakdown(),
            month = TokenBreakdown(), year = TokenBreakdown()
        var sessionLastSeen = [String: Date]()
        var windowTimestamps = [Date]()
        var windowTokens = [Int]()

        for event in files.values.flatMap(\.events).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !event.dedupeKey.isEmpty,
                  seenIds.insert(event.dedupeKey).inserted
            else { continue }

            let ts = Date(timeIntervalSince1970: event.timestamp)
            guard ts >= cutoff else { continue }

            if ts >= bounds.year {
                year.input      += event.inputTokens
                year.output     += event.outputTokens
                year.cacheWrite += event.cacheWriteTokens
                year.cacheRead  += event.cacheReadTokens
                yearCost += event.cost
            }
            if ts >= bounds.month {
                month.input      += event.inputTokens
                month.output     += event.outputTokens
                month.cacheWrite += event.cacheWriteTokens
                month.cacheRead  += event.cacheReadTokens
                monthCost += event.cost
            }
            if ts >= bounds.week {
                week.input      += event.inputTokens
                week.output     += event.outputTokens
                week.cacheWrite += event.cacheWriteTokens
                week.cacheRead  += event.cacheReadTokens
                weekCost += event.cost
            }
            if ts >= bounds.day {
                today.input      += event.inputTokens
                today.output     += event.outputTokens
                today.cacheWrite += event.cacheWriteTokens
                today.cacheRead  += event.cacheReadTokens
                todayCost += event.cost
            }

            windowTimestamps.append(ts)
            windowTokens.append(event.tokens)

            if let sessionId = event.sessionId, !sessionId.isEmpty {
                if sessionLastSeen[sessionId].map({ ts > $0 }) ?? true {
                    sessionLastSeen[sessionId] = ts
                }
            }
        }

        var u = AgentUsage()
        u.todayTokens = today.total;  u.todayCost = todayCost;  u.todayBreakdown = today
        u.weekTokens  = week.total;   u.weekCost  = weekCost;   u.weekBreakdown  = week
        u.monthTokens = month.total;  u.monthCost = monthCost;  u.monthBreakdown = month
        u.yearTokens  = year.total;   u.yearCost  = yearCost;   u.yearBreakdown  = year
        u.window = computeWindow(timestamps: windowTimestamps, tokens: windowTokens, now: now)
        u.activeSessions = sessionLastSeen.values.filter { $0 >= fiveMinAgo }.count
        u.costIsApprox = false
        return u
    }

    static func summarizeCodex(files: [String: CodexFileCache], now: Date, cutoff: Date) -> AgentUsage {
        let bounds = timeBounds(now: now)
        let activeWindow = now.addingTimeInterval(-5 * 60)
        var todayCost = 0.0, weekCost = 0.0, monthCost = 0.0, yearCost = 0.0
        // Codex 口径：total=input+output（cached_input 是 input 子集、reasoning 不计入 total_tokens）
        var today = TokenBreakdown(isCodex: true), week = TokenBreakdown(isCodex: true),
            month = TokenBreakdown(isCodex: true), year = TokenBreakdown(isCodex: true)
        var activeSessions = 0

        for file in files.values {
            var fileLastEventTime: Date?
            for event in file.events {
                let ts = Date(timeIntervalSince1970: event.timestamp)
                guard ts >= cutoff else { continue }

                if ts >= bounds.year {
                    year.input     += event.inputTokens
                    year.cacheRead += event.cachedTokens
                    year.output    += event.outputTokens
                    year.reasoning += event.reasoningTokens
                    yearCost += event.cost
                }
                if ts >= bounds.month {
                    month.input     += event.inputTokens
                    month.cacheRead += event.cachedTokens
                    month.output    += event.outputTokens
                    month.reasoning += event.reasoningTokens
                    monthCost += event.cost
                }
                if ts >= bounds.week {
                    week.input     += event.inputTokens
                    week.cacheRead += event.cachedTokens
                    week.output    += event.outputTokens
                    week.reasoning += event.reasoningTokens
                    weekCost += event.cost
                }
                if ts >= bounds.day {
                    today.input     += event.inputTokens
                    today.cacheRead += event.cachedTokens
                    today.output    += event.outputTokens
                    today.reasoning += event.reasoningTokens
                    todayCost += event.cost
                }
                if fileLastEventTime.map({ ts > $0 }) ?? true {
                    fileLastEventTime = ts
                }
            }
            if let fileLastEventTime, fileLastEventTime >= activeWindow {
                activeSessions += 1
            }
        }

        var u = AgentUsage()
        u.todayTokens = today.total;  u.todayCost = todayCost;  u.todayBreakdown = today
        u.weekTokens  = week.total;   u.weekCost  = weekCost;   u.weekBreakdown  = week
        u.monthTokens = month.total;  u.monthCost = monthCost;  u.monthBreakdown = month
        u.yearTokens  = year.total;   u.yearCost  = yearCost;   u.yearBreakdown  = year
        u.activeSessions = activeSessions
        u.costIsApprox = true
        return u
    }

    // MARK: - Dashboard

    static func buildDashboard(claudeFiles: [String: ClaudeFileCache],
                                codexFiles: [String: CodexFileCache],
                                now: Date) -> DashboardData {
        var cal = Calendar.current
        cal.timeZone = .current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current

        var seenIds = Set<String>()
        var totalTokens = 0
        var totalCost = 0.0
        var earliestDate: Date?
        var dayToCost     = [String: Double]()
        var dayToByClaude = [String: Double]()
        var dayToByCodex  = [String: Double]()
        var hourTokens    = Array(repeating: 0, count: 24)
        var modelTokens   = [String: Int]()
        var modelCost     = [String: Double]()
        var projectTokens = [String: Int]()
        var projectCost   = [String: Double]()
        var weekendTokens = 0
        var dayProjects   = [String: Set<String>]()

        // Claude events
        for (filePath, file) in claudeFiles {
            let proj = file.cwd.flatMap { c -> String? in
                let n = URL(fileURLWithPath: c).lastPathComponent
                return n.isEmpty ? nil : n
            } ?? encodedProjectName(from: filePath)

            for event in file.events {
                guard !event.dedupeKey.isEmpty,
                      seenIds.insert(event.dedupeKey).inserted else { continue }
                let ts = Date(timeIntervalSince1970: event.timestamp)
                let day = fmt.string(from: ts)
                let tok = event.tokens
                totalTokens += tok; totalCost += event.cost
                if earliestDate == nil || ts < earliestDate! { earliestDate = ts }
                dayToCost[day, default: 0]     += event.cost
                dayToByClaude[day, default: 0] += event.cost
                let h = cal.component(.hour, from: ts)
                hourTokens[h] += tok
                let mk = event.model.isEmpty ? "claude" : event.model
                modelTokens[mk, default: 0] += tok; modelCost[mk, default: 0] += event.cost
                projectTokens[proj, default: 0] += tok; projectCost[proj, default: 0] += event.cost
                let wd = cal.component(.weekday, from: ts)
                if wd == 1 || wd == 7 { weekendTokens += tok }
                dayProjects[day, default: []].insert(proj)
            }
        }

        // Codex events
        for file in codexFiles.values {
            for event in file.events {
                let ts = Date(timeIntervalSince1970: event.timestamp)
                let day = fmt.string(from: ts)
                let tok = event.tokens
                totalTokens += tok; totalCost += event.cost
                if earliestDate == nil || ts < earliestDate! { earliestDate = ts }
                dayToCost[day, default: 0]    += event.cost
                dayToByCodex[day, default: 0] += event.cost
                let h = cal.component(.hour, from: ts)
                hourTokens[h] += tok
                modelTokens["codex", default: 0] += tok; modelCost["codex", default: 0] += event.cost
                projectTokens["Codex", default: 0] += tok; projectCost["Codex", default: 0] += event.cost
                let wd = cal.component(.weekday, from: ts)
                if wd == 1 || wd == 7 { weekendTokens += tok }
            }
        }

        let activeDays = dayToCost.count
        let dailyAvg = activeDays > 0 ? totalCost / Double(activeDays) : 0
        let peakEntry = dayToCost.max(by: { $0.value < $1.value })
        let peakDay: String = {
            guard let p = peakEntry else { return "" }
            let parts = p.key.split(separator: "-")
            return parts.count == 3 ? "\(parts[1])-\(parts[2])" : p.key
        }()
        let topModelKey = modelTokens.max(by: { $0.value < $1.value })?.key ?? ""
        let activeDaySet = Set(dayToCost.keys)
        let streak = computeStreak(activeDaySet: activeDaySet, now: now, fmt: fmt, cal: cal)
        let weekendPct = totalTokens > 0 ? Double(weekendTokens) / Double(totalTokens) * 100 : 0
        let maxProjInDay = dayProjects.values.map(\.count).max() ?? 0
        let uniqueProjs = Set(projectTokens.keys).count

        let dailyCosts = dayToCost.map {
            DailyEntry(date: $0.key, totalCost: $0.value,
                       byClaude: dayToByClaude[$0.key] ?? 0,
                       byCodex: dayToByCodex[$0.key] ?? 0)
        }
        let models = modelTokens.map {
            ModelStat(model: $0.key, displayName: modelDisplayName($0.key),
                      tokens: $0.value, cost: modelCost[$0.key] ?? 0)
        }.sorted(by: { $0.tokens > $1.tokens })
        let projects = projectTokens.map {
            ProjectStat(project: $0.key, tokens: $0.value, cost: projectCost[$0.key] ?? 0)
        }.sorted(by: { $0.tokens > $1.tokens })
        let achievements = computeAchievements(
            totalTokens: totalTokens, totalCost: totalCost, streak: streak,
            maxProjInDay: maxProjInDay, uniqueProjs: uniqueProjs, weekendPct: weekendPct
        )

        var data = DashboardData()
        data.dailyCosts       = dailyCosts
        data.heatmap          = dayToCost
        data.totalTokens      = totalTokens
        data.totalCost        = totalCost
        data.startDate        = earliestDate
        data.activeDays       = activeDays
        data.streak           = streak
        data.dailyAvgCost     = dailyAvg
        data.peakDay          = peakDay
        data.topModel         = modelDisplayName(topModelKey)
        data.wordEquivalent   = Int(Double(totalTokens) * 0.60)
        data.hourlyTokens     = hourTokens
        data.modelBreakdown   = models
        data.projectBreakdown = projects
        data.achievements     = achievements
        return data
    }

    // MARK: - Dashboard helpers

    static func modelDisplayName(_ model: String) -> String {
        let m = model.lowercased()
        func ver(_ family: String) -> String {
            let parts = m.components(separatedBy: "-")
            if let idx = parts.firstIndex(of: family), idx + 2 < parts.count {
                return "\(family.capitalized) \(parts[idx+1]).\(parts[idx+2])"
            }
            if let idx = parts.firstIndex(of: family), idx + 1 < parts.count {
                return "\(family.capitalized) \(parts[idx+1])"
            }
            return family.capitalized
        }
        if m.contains("opus")   { return ver("opus")   }
        if m.contains("sonnet") { return ver("sonnet") }
        if m.contains("haiku")  { return ver("haiku")  }
        if m.contains("gpt")    {
            let parts = m.components(separatedBy: "-")
            if let idx = parts.firstIndex(of: "gpt"), idx + 1 < parts.count {
                return "GPT-\(parts[idx+1])"
            }
            return "GPT"
        }
        if m == "codex" { return "Codex" }
        return model
    }

    private static func encodedProjectName(from filePath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsPath = home + "/.claude/projects"
        var rel = filePath
        if rel.hasPrefix(projectsPath) { rel = String(rel.dropFirst(projectsPath.count)) }
        let dirName = rel.split(separator: "/").first.map(String.init) ?? rel
        // strip leading "-"
        var stripped = dirName.hasPrefix("-") ? String(dirName.dropFirst()) : dirName
        // strip encoded home prefix
        let homeEncoded = String(home.dropFirst()).replacingOccurrences(of: "/", with: "-")
        if stripped.hasPrefix(homeEncoded) {
            stripped = String(stripped.dropFirst(homeEncoded.count))
            if stripped.hasPrefix("-") { stripped = String(stripped.dropFirst()) }
        }
        // take last 2 dash-separated words as display name
        let parts = stripped.components(separatedBy: "-").filter { !$0.isEmpty }
        if parts.count >= 2 { return parts.suffix(2).joined(separator: "-") }
        return parts.last ?? dirName
    }

    private static func computeStreak(activeDaySet: Set<String>, now: Date,
                                      fmt: DateFormatter, cal: Calendar) -> Int {
        var streak = 0
        var date = cal.startOfDay(for: now)
        // allow today to have no data yet (check yesterday first)
        if !activeDaySet.contains(fmt.string(from: date)) {
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        while activeDaySet.contains(fmt.string(from: date)) {
            streak += 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    private static func computeAchievements(totalTokens: Int, totalCost: Double,
                                            streak: Int, maxProjInDay: Int,
                                            uniqueProjs: Int, weekendPct: Double) -> [AchievementDef] {
        var list = [AchievementDef]()
        if totalTokens >= 1_000_000_000 {
            list.append(.init(key: "billion", title: "十亿俱乐部",
                              subtitle: Fmt.human(totalTokens) + " tokens",
                              icon: "diamond.fill", iconColor: .orange))
        }
        if totalCost >= 1000 {
            list.append(.init(key: "kilo_usd", title: "破千刀",
                              subtitle: "≈$\(Int(totalCost))",
                              icon: "dollarsign.circle.fill", iconColor: .red))
        }
        if streak >= 7 {
            list.append(.init(key: "streak", title: "坚持",
                              subtitle: "连续 \(streak) 天",
                              icon: "flame.fill", iconColor: .orange))
        }
        if maxProjInDay >= 5 {
            list.append(.init(key: "multi_project", title: "多线作战",
                              subtitle: "单日 \(maxProjInDay) 个项目",
                              icon: "square.grid.2x2.fill", iconColor: .purple))
        }
        if uniqueProjs >= 10 {
            list.append(.init(key: "spread", title: "广撒网",
                              subtitle: "\(uniqueProjs) 个项目",
                              icon: "network", iconColor: .blue))
        }
        if weekendPct >= 30 {
            list.append(.init(key: "weekend", title: "周末战士",
                              subtitle: String(format: "周末占 %.0f%%", weekendPct),
                              icon: "figure.strengthtraining.traditional", iconColor: .green))
        }
        return list
    }

    static func timeBounds(now: Date) -> (day: Date, week: Date, month: Date, year: Date) {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let day = cal.startOfDay(for: now)
        let weekdayIdx = (cal.component(.weekday, from: now) - cal.firstWeekday + 7) % 7
        let week = cal.date(byAdding: .day, value: -weekdayIdx, to: day)!
        var monthComps = cal.dateComponents([.year, .month], from: now)
        monthComps.day = 1
        let month = cal.date(from: monthComps)!
        var yearComps = cal.dateComponents([.year], from: now)
        yearComps.month = 1; yearComps.day = 1
        let year = cal.date(from: yearComps)!
        return (day, week, month, year)
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
