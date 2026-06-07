import Foundation

enum ClaudeUsageParser {
    /// 扫描 ~/.claude/projects/**/*.jsonl，汇总 Claude 用量统计。
    /// 实际读取由 UsageLogScanner 增量缓存，保留该入口用于兼容旧调用点。
    static func summarize(now: Date) -> AgentUsage {
        UsageLogScanner.summarizeClaude(now: now)
    }
}
