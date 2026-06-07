import Foundation

enum ClaudeUsageParser {
    /// 扫描 ~/.claude/projects/**/*.jsonl，汇总 Claude 用量统计
    static func summarize(now: Date) -> AgentUsage {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")

        // 时间边界（本地时区）
        var cal = Calendar.current
        cal.firstWeekday = 2   // 周一为本周起点（中文惯例 / ISO 8601）
        let startOfDay   = cal.startOfDay(for: now)
        // 本周起点：从今天 00:00 回退到本周一
        let weekdayIdx   = (cal.component(.weekday, from: now) - cal.firstWeekday + 7) % 7
        let startOfWeek  = cal.date(byAdding: .day, value: -weekdayIdx, to: startOfDay)!
        let startOfMonth: Date = {
            var comps = cal.dateComponents([.year, .month], from: now)
            comps.day = 1
            return cal.date(from: comps)!
        }()
        let cutoff35days = now.addingTimeInterval(-35 * 86400)
        let fiveMinAgo   = now.addingTimeInterval(-5 * 60)

        // ISO8601 解析器（带小数秒）
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // 去重集合
        var seenIds = Set<String>()

        // 统计累加
        var todayTokens  = 0;  var todayCost  = 0.0
        var weekTokens   = 0;  var weekCost   = 0.0
        var monthTokens  = 0;  var monthCost  = 0.0

        // 活跃会话：sessionId -> 最后事件时间
        var sessionLastSeen = [String: Date]()

        // 5h 窗口事件列表
        var windowTimestamps = [Date]()
        var windowTokens     = [Int]()

        // 遍历所有 .jsonl 文件
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return AgentUsage()
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }

            // 按 mtime 跳过超过 35 天的文件
            if let mtime = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if mtime < cutoff35days { continue }
            }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let lineStr = String(line)
                guard let data = lineStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // 只处理 type == "assistant"
                guard let typeVal = obj["type"] as? String, typeVal == "assistant" else { continue }

                // 必须有 message.usage
                guard let message = obj["message"] as? [String: Any],
                      let usage   = message["usage"]  as? [String: Any]
                else { continue }

                // 去重：优先用 message["id"]，其次 requestId
                let dedupeKey: String
                if let msgId = message["id"] as? String, !msgId.isEmpty {
                    dedupeKey = msgId
                } else if let reqId = obj["requestId"] as? String, !reqId.isEmpty {
                    dedupeKey = reqId
                } else {
                    // 无法去重的行跳过
                    continue
                }
                guard seenIds.insert(dedupeKey).inserted else { continue }

                // 解析时间戳
                guard let tsStr = obj["timestamp"] as? String,
                      let ts = isoFormatter.date(from: tsStr)
                else { continue }

                // 提取 usage 字段
                let inputTokens   = usage["input_tokens"]                as? Int ?? 0
                let outputTokens  = usage["output_tokens"]               as? Int ?? 0
                let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheReadTok  = usage["cache_read_input_tokens"]     as? Int ?? 0

                let totalTokens = inputTokens + outputTokens + cacheCreation + cacheReadTok

                // 成本
                let model = message["model"] as? String ?? ""
                let cost = Pricing.claudeCost(
                    model:      model,
                    input:      inputTokens,
                    output:     outputTokens,
                    cacheWrite: cacheCreation,
                    cacheRead:  cacheReadTok
                )

                // 时间分桶（三个桶独立判断，避免跨月时本周一落在上月导致漏计）
                if ts >= startOfMonth { monthTokens += totalTokens; monthCost += cost }
                if ts >= startOfWeek  { weekTokens  += totalTokens; weekCost  += cost }
                if ts >= startOfDay   { todayTokens += totalTokens; todayCost += cost }

                // 收集用于 5h 窗口计算的事件
                windowTimestamps.append(ts)
                windowTokens.append(totalTokens)

                // 活跃会话
                if let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty {
                    if sessionLastSeen[sessionId].map({ ts > $0 }) ?? true {
                        sessionLastSeen[sessionId] = ts
                    }
                }
            }
        }

        // 计算活跃会话数
        let activeSessions = sessionLastSeen.values.filter { $0 >= fiveMinAgo }.count

        // 计算 5h 窗口
        let window = computeWindow(timestamps: windowTimestamps, tokens: windowTokens, now: now)

        return AgentUsage(
            todayTokens:    todayTokens,
            todayCost:      todayCost,
            weekTokens:     weekTokens,
            weekCost:       weekCost,
            monthTokens:    monthTokens,
            monthCost:      monthCost,
            window:         window,
            activeSessions: activeSessions,
            costIsApprox:   false
        )
    }

    // MARK: - 5h 窗口计算

    private struct Block {
        var start: Date
        var tokens: Int
    }

    private static func computeWindow(timestamps: [Date], tokens: [Int], now: Date) -> WindowStat? {
        guard !timestamps.isEmpty else { return nil }

        // 按时间排序
        let indices = timestamps.indices.sorted { timestamps[$0] < timestamps[$1] }
        let sortedTS  = indices.map { timestamps[$0] }
        let sortedTok = indices.map { tokens[$0] }

        let fiveHours: TimeInterval = 5 * 3600

        // 分块：相邻事件时间差 > 5h 则开新块
        var blocks = [Block]()
        for i in sortedTS.indices {
            let ts  = sortedTS[i]
            let tok = sortedTok[i]
            if let last = blocks.last, ts.timeIntervalSince(last.start) < fiveHours {
                blocks[blocks.count - 1].tokens += tok
            } else {
                blocks.append(Block(start: ts, tokens: tok))
            }
        }

        // 找包含 now 的当前块（blockStart <= now < blockStart+5h）
        var currentBlock: Block? = nil
        for block in blocks.reversed() {
            let blockEnd = block.start.addingTimeInterval(fiveHours)
            if block.start <= now && now < blockEnd {
                currentBlock = block
                break
            }
        }

        // 若无活跃块，取最近块（窗口已过期，仍展示最近块）
        if currentBlock == nil {
            currentBlock = blocks.last
        }

        guard let blk = currentBlock else { return nil }

        let blockEnd       = blk.start.addingTimeInterval(fiveHours)
        let resetIn        = max(0, blockEnd.timeIntervalSince(now))
        let elapsed        = fiveHours - resetIn            // 已过去秒数
        let usedFrac       = min(1.0, elapsed / fiveHours)  // 按时间推进 0..1
        let elapsedMinutes = max(1.0, elapsed / 60.0)
        let tokPerMin      = Double(blk.tokens) / elapsedMinutes

        return WindowStat(
            tokens:       blk.tokens,
            tokensPerMin: tokPerMin,
            resetIn:      resetIn > 0 ? resetIn : nil,
            usedFraction: usedFrac
        )
    }
}
