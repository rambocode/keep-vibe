import Foundation

enum CodexUsageParser {
    /// 扫描 ~/.codex/sessions/**/*.jsonl，汇总 Codex token 用量
    static func summarize(now: Date) -> AgentUsage {
        let fm = FileManager.default
        let sessionsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions")

        guard fm.fileExists(atPath: sessionsURL.path) else {
            return AgentUsage(costIsApprox: true)
        }

        // 时间分桶基准（本地时区）
        var cal = Calendar.current
        cal.firstWeekday = 2   // 周一为本周起点（中文惯例 / ISO 8601）
        let todayStart   = cal.startOfDay(for: now)
        let weekdayIdx   = (cal.component(.weekday, from: now) - cal.firstWeekday + 7) % 7
        let weekStart    = cal.date(byAdding: .day, value: -weekdayIdx, to: todayStart)!
        let monthStart   = cal.date(from: cal.dateComponents(
            [.year, .month], from: now))!
        let cutoff35d    = now.addingTimeInterval(-35 * 86400)
        let activeWindow = now.addingTimeInterval(-5 * 60)

        // 累加器
        var todayTokens  = 0;  var todayCost   = 0.0
        var weekTokens   = 0;  var weekCost    = 0.0
        var monthTokens  = 0;  var monthCost   = 0.0
        var activeSessions = 0

        // 枚举所有 .jsonl 文件
        let enumerator = fm.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl" else { continue }

            // 按 mtime 快速过滤
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff35d { continue }

            // 逐行解析
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            var fileLastEventTime: Date? = nil

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // 只处理 type == "event_msg" 且 payload.type == "token_count"
                guard let type = obj["type"] as? String, type == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String, payloadType == "token_count"
                else { continue }

                // 解析时间戳
                guard let tsStr = obj["timestamp"] as? String else { continue }
                let ts: Date
                if let d = isoFormatter.date(from: tsStr) {
                    ts = d
                } else {
                    // 回退：去掉小数秒重试
                    var opts = isoFormatter.formatOptions
                    opts.remove(.withFractionalSeconds)
                    let fallback = ISO8601DateFormatter()
                    fallback.formatOptions = opts
                    guard let d2 = fallback.date(from: tsStr) else { continue }
                    ts = d2
                }

                // 跳过 35 天以外的事件
                if ts < cutoff35d { continue }

                // 提取 last_token_usage
                guard let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any]
                else { continue }

                let inputTokens    = (usage["input_tokens"]             as? Int) ?? 0
                let cachedInput    = (usage["cached_input_tokens"]      as? Int) ?? 0
                let outputTokens   = (usage["output_tokens"]            as? Int) ?? 0
                let reasoningOut   = (usage["reasoning_output_tokens"]  as? Int) ?? 0
                let totalTokens    = (usage["total_tokens"]             as? Int) ?? 0

                let cost = Pricing.codexCost(
                    input: inputTokens,
                    cachedInput: cachedInput,
                    output: outputTokens + reasoningOut
                )

                // 今日
                if ts >= todayStart {
                    todayTokens += totalTokens
                    todayCost   += cost
                }
                // 本周
                if ts >= weekStart {
                    weekTokens += totalTokens
                    weekCost   += cost
                }
                // 本月
                if ts >= monthStart {
                    monthTokens += totalTokens
                    monthCost   += cost
                }

                // 追踪文件最后事件时间（用于活跃会话判断）
                if fileLastEventTime.map({ ts > $0 }) ?? true {
                    fileLastEventTime = ts
                }
            }

            // 活跃会话：该文件最后一条 token_count 事件在最近 5 分钟内
            if let lastTime = fileLastEventTime, lastTime >= activeWindow {
                activeSessions += 1
            }
        }

        return AgentUsage(
            todayTokens:     todayTokens,
            todayCost:       todayCost,
            weekTokens:      weekTokens,
            weekCost:        weekCost,
            monthTokens:     monthTokens,
            monthCost:       monthCost,
            window:          nil,       // Codex 不展示 5h 窗口
            activeSessions:  activeSessions,
            costIsApprox:    true
        )
    }
}
