import Foundation
import Combine
import CoreGraphics

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

struct AgentUsage {
    var todayTokens: Int = 0
    var todayCost: Double = 0
    var weekTokens: Int = 0
    var weekCost: Double = 0
    var monthTokens: Int = 0
    var monthCost: Double = 0
    var window: WindowStat? = nil        // Claude 有；Codex 为 nil
    var activeSessions: Int = 0          // 活跃会话数（最近5分钟内有活动）
    var costIsApprox: Bool = false       // Codex => true（显示 ≈）
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
    @Published var lastUpdated: Date? = nil
    @Published var launchAtLogin: Bool = false
    @Published var maxContentHeight: CGFloat = 600   // popover 限高：弹出时按状态栏图标所在屏更新
}
