import SwiftUI

// MARK: - Formatting Helpers

private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: "%.1fM", Double(n) / 1_000_000)
    } else if n >= 1_000 {
        return String(format: "%.1fk", Double(n) / 1_000)
    } else {
        return "\(n)"
    }
}

private func formatCost(_ v: Double, approx: Bool = false) -> String {
    let prefix = approx ? "≈" : ""
    return "\(prefix)$\(String(format: "%.2f", v))"
}

private func formatUptime(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(seconds) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return "\(hours)小时\(minutes)分"
}

private func formatResetIn(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%d:%02d", m, s)
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    return String(format: "%.1f GB", gb)
}

private func relativeTime(_ date: Date) -> String {
    let diff = Int(-date.timeIntervalSinceNow)
    if diff < 60 { return "\(diff)秒前" }
    if diff < 3600 { return "\(diff / 60)分钟前" }
    return "\(diff / 3600)小时前"
}

// MARK: - Color Helpers

private extension Color {
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let accentBlue = Color.blue
    static let accentOrange = Color.orange
    static let accentGreen = Color.green
    static let textSecondary = Color.secondary
}

// MARK: - Section Card

private struct SectionCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Segmented Pill Button

private struct PillSegment<T: Hashable>: View {
    let title: String
    let value: T
    @Binding var selected: T
    let action: (T) -> Void

    var isSelected: Bool { selected == value }

    var body: some View {
        Button(action: { action(value) }) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentBlue : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Progress Row

private struct ProgressRow: View {
    let label: String
    let icon: String
    let iconColor: Color
    let value: String
    let progress: Double  // 0..1
    let barColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 14)
                Text(label)
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                Spacer()
                Text(value)
                    .font(.caption)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * min(1, max(0, progress)), height: 4)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Token Cost Row

private struct TokenCostRow: View {
    let label: String
    let tokens: Int
    let cost: Double
    let approx: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.textSecondary)
            Spacer()
            Text(formatTokens(tokens))
                .font(.caption)
                .monospacedDigit()
            Text(formatCost(cost, approx: approx))
                .font(.caption)
                .foregroundColor(.textSecondary)
                .monospacedDigit()
        }
    }
}

// MARK: - System Stats Card

private struct SystemStatsCard: View {
    let stats: SystemStats?

    private var cpuFraction: Double {
        guard let s = stats else { return 0 }
        return s.cpuPercent / 100.0
    }

    private var memFraction: Double {
        guard let s = stats, s.memTotalBytes > 0 else { return 0 }
        return Double(s.memUsedBytes) / Double(s.memTotalBytes)
    }

    var body: some View {
        SectionCard {
            // Section title
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("系统状态")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.textSecondary)
            }

            Divider()

            // Uptime
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text("开机时长")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                Spacer()
                Text(stats.map { formatUptime($0.uptimeSeconds) } ?? "—")
                    .font(.caption)
                    .monospacedDigit()
            }

            // CPU
            ProgressRow(
                label: "CPU",
                icon: "cpu",
                iconColor: .accentGreen,
                value: stats.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "—",
                progress: cpuFraction,
                barColor: .accentGreen
            )

            // Memory
            ProgressRow(
                label: "内存",
                icon: "memorychip",
                iconColor: .blue,
                value: stats.map { "\(formatBytes($0.memUsedBytes)) / \(formatBytes($0.memTotalBytes))" } ?? "—",
                progress: memFraction,
                barColor: .blue
            )

            // Battery
            if let s = stats, let batt = s.batteryPercent {
                HStack(spacing: 6) {
                    Image(systemName: s.batteryCharging ? "battery.100.bolt" : "battery.100")
                        .foregroundColor(.accentGreen)
                        .frame(width: 14)
                    Text("电池")
                        .font(.caption)
                        .foregroundColor(.textSecondary)
                    Spacer()
                    if s.batteryCharging {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                    Text("\(batt)%")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Claude Usage Card

private struct ClaudeUsageCard: View {
    let usage: AgentUsage?

    var body: some View {
        SectionCard {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentOrange)
                    .font(.caption)
                Text("Claude Code")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }

            Divider()

            if let u = usage {
                // Today
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                        Text(formatTokens(u.todayTokens))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(formatCost(u.todayCost))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                // Window section
                if let win = u.window {
                    Divider()

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .foregroundColor(.accentOrange)
                            .frame(width: 14)
                        Text("5h 窗口")
                            .font(.caption)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text(formatTokens(win.tokens))
                            .font(.caption)
                            .monospacedDigit()
                        Text(String(format: "%.1fk tok/min", win.tokensPerMin / 1000))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                            .monospacedDigit()
                    }

                    // Window progress
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 5)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentOrange)
                                    .frame(width: geo.size.width * min(1, max(0, win.usedFraction)), height: 5)
                            }
                        }
                        .frame(height: 5)

                        if let resetIn = win.resetIn {
                            Text("剩 \(formatResetIn(resetIn))")
                                .font(.caption2)
                                .foregroundColor(.textSecondary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                }

                Divider()

                // Week / Month
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本周")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                        Text(formatTokens(u.weekTokens))
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        Text(formatCost(u.weekCost))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Divider().frame(height: 36)
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本月")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                        Text(formatTokens(u.monthTokens))
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        Text(formatCost(u.monthCost))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                            .monospacedDigit()
                    }
                }

                Divider()

                // Active sessions
                HStack(spacing: 4) {
                    Image(systemName: u.activeSessions > 0 ? "circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundColor(u.activeSessions > 0 ? .accentGreen : .secondary)
                    Text(u.activeSessions == 0 ? "无活跃会话" : "\(u.activeSessions) 个活跃会话")
                        .font(.caption2)
                        .foregroundColor(.textSecondary)
                    Spacer()
                }
            } else {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
        }
    }
}

// MARK: - Codex Usage Card

private struct CodexUsageCard: View {
    let usage: AgentUsage?

    var body: some View {
        SectionCard {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundColor(.accentBlue)
                    .font(.caption)
                Text("Codex")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }

            Divider()

            if let u = usage {
                // Today
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("今日")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                        Text(formatTokens(u.todayTokens))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(formatCost(u.todayCost, approx: u.costIsApprox))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                Divider()

                // Week / Month
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本周")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                        Text(formatTokens(u.weekTokens))
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        Text(formatCost(u.weekCost, approx: u.costIsApprox))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Divider().frame(height: 36)
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本月")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                        Text(formatTokens(u.monthTokens))
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        Text(formatCost(u.monthCost, approx: u.costIsApprox))
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                            .monospacedDigit()
                    }
                }

                Divider()

                // Active sessions
                HStack(spacing: 4) {
                    Image(systemName: u.activeSessions > 0 ? "circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundColor(u.activeSessions > 0 ? .accentGreen : .secondary)
                    Text(u.activeSessions == 0 ? "无活跃会话" : "\(u.activeSessions) 个活跃会话")
                        .font(.caption2)
                        .foregroundColor(.textSecondary)
                    Spacer()
                }
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
        }
    }
}

// MARK: - Keep Awake Control Card

private struct KeepAwakeCard: View {
    @ObservedObject var state: AppState
    let onToggleAwake: (Bool) -> Void
    let onSelectMode: (AwakeMode) -> Void
    let onSelectDuration: (AwakeDuration) -> Void

    var body: some View {
        SectionCard {
            // Title row
            HStack(spacing: 8) {
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundColor(.accentOrange)
                Text("保持唤醒")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.keepAwake },
                    set: { onToggleAwake($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.85)
            }

            if state.keepAwake {
                Divider()

                // Mode selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("模式")
                        .font(.caption2)
                        .foregroundColor(.textSecondary)

                    HStack(spacing: 4) {
                        ForEach(AwakeMode.allCases, id: \.self) { m in
                            PillSegment(
                                title: m == .standard ? "标准防睡" : "合盖也不睡",
                                value: m,
                                selected: Binding(
                                    get: { state.mode },
                                    set: { _ in }
                                ),
                                action: onSelectMode
                            )
                        }
                    }
                    .padding(3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Duration selector
                VStack(alignment: .leading, spacing: 4) {
                    Text("时长")
                        .font(.caption2)
                        .foregroundColor(.textSecondary)

                    HStack(spacing: 2) {
                        ForEach(AwakeDuration.allCases, id: \.self) { d in
                            PillSegment(
                                title: d.label,
                                value: d,
                                selected: Binding(
                                    get: { state.duration },
                                    set: { _ in }
                                ),
                                action: onSelectDuration
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Countdown
                if let remaining = state.awakeRemaining {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                        Text("剩余 \(formatResetIn(remaining))")
                            .font(.caption2)
                            .foregroundColor(.textSecondary)
                            .monospacedDigit()
                        Spacer()
                    }
                }
            }
        }
        .opacity(state.keepAwake ? 1.0 : 0.85)
    }
}

// MARK: - Main View

@MainActor
struct MenuContentView: View {
    @ObservedObject var state: AppState
    var onToggleAwake: (Bool) -> Void
    var onSelectMode: (AwakeMode) -> Void
    var onSelectDuration: (AwakeDuration) -> Void
    var onToggleLaunch: (Bool) -> Void
    var onRefresh: () -> Void
    var onQuit: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                // Keep Awake
                KeepAwakeCard(
                    state: state,
                    onToggleAwake: onToggleAwake,
                    onSelectMode: onSelectMode,
                    onSelectDuration: onSelectDuration
                )

                // System Stats
                SystemStatsCard(stats: state.system)

                // Claude Code
                ClaudeUsageCard(usage: state.claude)

                // Codex
                CodexUsageCard(usage: state.codex)

                // Footer
                SectionCard {
                    // Launch at login
                    HStack {
                        Image(systemName: "arrow.up.circle")
                            .foregroundColor(.secondary)
                            .frame(width: 14)
                        Text("开机自启")
                            .font(.caption)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { state.launchAtLogin },
                            set: { onToggleLaunch($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.8)
                    }

                    Divider()

                    // Refresh + timestamp + Quit
                    HStack {
                        Button(action: onRefresh) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                if let updated = state.lastUpdated {
                                    Text("更新于 \(relativeTime(updated))")
                                        .font(.caption2)
                                        .foregroundColor(.textSecondary)
                                } else {
                                    Text("刷新")
                                        .font(.caption2)
                                        .foregroundColor(.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)

                        Spacer()

                        Button(action: onQuit) {
                            HStack(spacing: 4) {
                                Image(systemName: "power")
                                    .font(.caption)
                                Text("退出")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
