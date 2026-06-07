import Foundation

enum CodexUsageParser {
    /// 扫描 ~/.codex/sessions/**/*.jsonl，汇总 Codex token 用量。
    /// 实际读取由 UsageLogScanner 增量缓存，保留该入口用于兼容旧调用点。
    static func summarize(now: Date) -> AgentUsage {
        UsageLogScanner.summarizeCodex(now: now)
    }
}
