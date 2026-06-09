import Foundation
import Combine
import CoreGraphics
import SwiftUI

enum AwakeMode: String, CaseIterable { case standard, clamshell }   // 标准防睡 / 合盖也不睡
enum AwakeDuration: Hashable, CaseIterable {                          // 永久 / 1小时 / 2小时 / 4小时
    case forever, hours(Int)
    static var allCases: [AwakeDuration] { [.forever, .hours(1), .hours(2), .hours(4)] }
    var label: String { switch self { case .forever: return "永久"; case .hours(let h): return "\(h)小时" } }
    var seconds: TimeInterval? { switch self { case .forever: return nil; case .hours(let h): return TimeInterval(h*3600) } }
}

struct SystemStats {
    var uptimeSeconds: TimeInterval = 0
    var cpuPercent: Double = 0           // 0..100
    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    var batteryPercent: Int? = nil       // nil 表示无电池
    var batteryCharging: Bool = false
}

struct WindowStat {                      // Claude 的 5 小时窗口
    var tokens: Int = 0
    var tokensPerMin: Double = 0
    var resetIn: TimeInterval? = nil     // 距窗口重置剩余秒数
    var usedFraction: Double = 0         // 0..1 进度条
}

struct QuotaStat {                       // 周配额（Python 脚本提供）
    var usedFraction: Double             // 0..1
    var resetAt: Date?                   // 绝对重置时间
}

// 单个时间范围内的 token 分项统计
struct TokenBreakdown: Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0   // Codex reasoning tokens
    // Codex 口径：cached_input 是 input 的子集，且 total_tokens=input+output（不含 reasoning）。
    // Claude 口径：cache_read/cache_write 是独立类别，total=四项之和。
    var isCodex: Bool = false

    // Codex 与 Claude 的 token 口径不同，分别对账各自 last_token_usage.total_tokens / 官方 usage。
    var total: Int {
        isCodex ? input + output         // Codex: last_token_usage.total_tokens = input+output
                : input + output + cacheRead + cacheWrite
    }
    // 缓存命中率：
    // - Codex：cached_input 是 input 的子集，命中率 = cacheRead / input
    // - Claude：cache_read 是独立类别，命中率 = cache_read / (input + cache_read)
    var cacheHitRate: Double {
        let denom = isCodex ? input : input + cacheRead
        guard denom > 0 else { return 0 }
        return Double(cacheRead) / Double(denom) * 100
    }
}

struct AgentUsage {
    var todayTokens: Int = 0
    var todayCost: Double = 0
    var yesterdayTokens: Int = 0
    var yesterdayCost: Double = 0
    var weekTokens: Int = 0
    var weekCost: Double = 0
    var monthTokens: Int = 0
    var monthCost: Double = 0
    var yearTokens: Int = 0
    var yearCost: Double = 0
    var todayBreakdown: TokenBreakdown = .init()
    var yesterdayBreakdown: TokenBreakdown = .init()
    var weekBreakdown:  TokenBreakdown = .init()
    var monthBreakdown: TokenBreakdown = .init()
    var yearBreakdown:  TokenBreakdown = .init()
    var window: WindowStat? = nil
    var weekQuota: QuotaStat? = nil
    var activeSessions: Int = 0
    var costIsApprox: Bool = false

    func breakdown(for key: RangeKey) -> TokenBreakdown {
        switch key {
        case .today: return todayBreakdown
        case .yesterday: return yesterdayBreakdown
        case .week:  return weekBreakdown
        case .month: return monthBreakdown
        case .year:  return yearBreakdown
        }
    }
}

// 时间范围选择器 key（与 SegmentedTabs 绑定）
enum RangeKey: String, CaseIterable, Identifiable {
    case today, yesterday, week, month, year
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .week:  return "本周"
        case .month: return "本月"
        case .year:  return "今年"
        }
    }
}

extension AgentUsage {
    func tokens(for key: RangeKey) -> Int {
        switch key {
        case .today: return todayTokens
        case .yesterday: return yesterdayTokens
        case .week:  return weekTokens
        case .month: return monthTokens
        case .year:  return yearTokens
        }
    }
    func cost(for key: RangeKey) -> Double {
        switch key {
        case .today: return todayCost
        case .yesterday: return yesterdayCost
        case .week:  return weekCost
        case .month: return monthCost
        case .year:  return yearCost
        }
    }
}

// 工具标识：覆盖原生（claude/codex）与 Python 采集（其余六路）
enum ToolKind: String, CaseIterable, Identifiable {
    case claude, codex, gemini, grok, aider, openclaw, opencode, qoder
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .aider: return "Aider"
        case .openclaw: return "OpenClaw"
        case .opencode: return "OpenCode"
        case .qoder: return "Qoder"
        }
    }

    var icon: String {       // SF Symbol 图标名
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "diamond"
        case .grok: return "bolt"
        case .aider: return "hammer"
        case .openclaw: return "pawprint"
        case .opencode: return "curlybraces"
        case .qoder: return "cube"
        }
    }

    var color: Color {       // 主题色
        switch self {
        case .claude: return Color(red: 0.84, green: 0.45, blue: 0.31)   // Claude 橙
        case .codex: return Color(red: 0.20, green: 0.20, blue: 0.22)    // Codex 深灰
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)   // Gemini 蓝
        case .grok: return Color(red: 0.11, green: 0.11, blue: 0.13)     // Grok 黑
        case .aider: return Color(red: 0.18, green: 0.66, blue: 0.45)    // Aider 绿
        case .openclaw: return Color(red: 0.90, green: 0.30, blue: 0.45) // OpenClaw 红
        case .opencode: return Color(red: 0.55, green: 0.36, blue: 0.86) // OpenCode 紫
        case .qoder: return Color(red: 0.95, green: 0.62, blue: 0.18)    // Qoder 黄
        }
    }
}

// Dashboard 每日明细：单日总花费与按工具拆分（Claude/Codex）
struct DailyEntry {
    var date: String          // yyyy-MM-dd
    var totalCost: Double
    var byClaude: Double
    var byCodex: Double
}

// 模型用量统计
struct ModelStat: Identifiable {
    var id: String { model }
    var model: String         // 原始 model id，如 "claude-opus-4-7"
    var displayName: String   // 短名，如 "Opus 4.7"
    var tokens: Int
    var cost: Double
}

// 项目用量统计
struct ProjectStat: Identifiable {
    var id: String { project }
    var project: String       // 项目目录名
    var tokens: Int
    var cost: Double
}

// 成就
struct AchievementDef: Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var subtitle: String
    var icon: String          // SF Symbol
    var iconColor: Color
}

// Dashboard 数据源
struct DashboardData {
    // 日柱状图
    var dailyCosts: [DailyEntry] = []
    // 热力图 date->cost
    var heatmap: [String: Double] = [:]
    // 汇总
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var startDate: Date? = nil
    var activeDays: Int = 0
    var streak: Int = 0
    var dailyAvgCost: Double = 0
    var peakDay: String = ""        // MM-dd
    var topModel: String = ""
    var wordEquivalent: Int = 0
    // 活跃时段（24桶）
    var hourlyTokens: [Int] = Array(repeating: 0, count: 24)
    // 模型/项目排行
    var modelBreakdown: [ModelStat] = []
    var projectBreakdown: [ProjectStat] = []
    // 成就
    var achievements: [AchievementDef] = []
}

@MainActor
final class AppState: ObservableObject {
    @Published var keepAwake: Bool = false
    @Published var mode: AwakeMode = .standard
    @Published var duration: AwakeDuration = .forever
    @Published var awakeRemaining: TimeInterval? = nil
    @Published var system: SystemStats? = nil
    @Published var claude: AgentUsage? = nil
    @Published var codex: AgentUsage? = nil
    // Python 采集的六路工具用量
    @Published var gemini: AgentUsage? = nil
    @Published var grok: AgentUsage? = nil
    @Published var aider: AgentUsage? = nil
    @Published var openclaw: AgentUsage? = nil
    @Published var opencode: AgentUsage? = nil
    @Published var qoder: AgentUsage? = nil
    @Published var dashboard: DashboardData? = nil
    @Published var visibleTools: Set<String> = Set(ToolKind.allCases.map { $0.rawValue })
    @Published var idleReminderMinutes: Int = 0     // 0=禁用
    @Published var selectedTab: Int = 0             // 0=Cards,1=Dashboard,2=Settings
    @Published var lastUpdated: Date? = nil
    @Published var launchAtLogin: Bool = false
}
