import SwiftUI

// MARK: - 入口

@MainActor
struct DashboardView: View {
    @ObservedObject var state: AppState

    private var hasAnyData: Bool {
        (state.dashboard?.totalTokens ?? 0) > 0
        || state.claude != nil || state.codex != nil
        || state.gemini != nil || state.grok != nil
        || state.aider  != nil || state.openclaw != nil
        || state.opencode != nil || state.qoder != nil
    }

    var body: some View {
        if hasAnyData {
            VStack(alignment: .leading, spacing: 11) {
                if let data = state.dashboard, data.totalTokens > 0 {
                    DashHeader(data: data)
                    TotalSection(data: data)
                    SummaryRow(data: data)
                }
                AgentsOverviewSection(state: state)
                if let data = state.dashboard {
                    if !data.achievements.isEmpty {
                        AchievementsCard(achievements: data.achievements)
                    }
                    HourlyChartCard(tokens: data.hourlyTokens)
                    if !data.modelBreakdown.isEmpty {
                        ModelBreakdownCard(models: data.modelBreakdown)
                    }
                    if !data.projectBreakdown.isEmpty {
                        ProjectRankingCard(projects: data.projectBreakdown)
                    }
                    HeatmapSectionCard(heatmap: data.heatmap)
                }
            }
        } else {
            EmptyDash()
        }
    }
}

// MARK: - 头部（回顾 + 日期范围）

private struct DashHeader: View {
    let data: DashboardData
    var body: some View {
        HStack(alignment: .center) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LinearGradient(
                    colors: [Theme.claude, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("回顾")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.tPrimary)
            Spacer()
            if let start = data.startDate {
                Text("自 \(startStr(start)) · \(data.activeDays) 天活跃")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.tTertiary)
            }
        }
    }

    private func startStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - 总 token + 字数当量

private struct TotalSection: View {
    let data: DashboardData
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(Fmt.human(data.totalTokens))
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.claude, Color(red:0.98,green:0.60,blue:0.30)],
                        startPoint: .leading, endPoint: .trailing))
                Text("tokens")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.tSecondary)
            }
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                Text("这些 token ≈ 码了 \(Fmt.human(data.wordEquivalent))字")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tSecondary)
                Image(systemName: "flame.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 5 项摘要卡片行

private struct SummaryRow: View {
    let data: DashboardData
    var body: some View {
        HStack(spacing: 6) {
            summaryCard("总成本",    value: "$\(Int(data.totalCost))",              tint: Theme.tPrimary)
            summaryCard("连续",      value: "\(data.streak) 天",                    tint: .green)
            summaryCard("日均",      value: "$\(Int(data.dailyAvgCost))",            tint: Theme.tSecondary)
            summaryCard("峰值日",    value: data.peakDay.isEmpty ? "-" : data.peakDay, tint: .red)
            summaryCard("本命模型",  value: data.topModel.isEmpty ? "-" : data.topModel, tint: Theme.codex)
        }
    }

    @ViewBuilder
    private func summaryCard(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.tTertiary)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Theme.subCardFill)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.hairline, lineWidth: 0.6)))
    }
}

// MARK: - 成就

private struct AchievementsCard: View {
    let achievements: [AchievementDef]
    var body: some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.orange.opacity(0.15)))
                    Text("成就")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tPrimary)
                    Text("\(achievements.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(achievements) { ach in
                        AchievementBadge(ach: ach)
                    }
                }
            }
        }
    }
}

private struct AchievementBadge: View {
    let ach: AchievementDef
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ach.iconColor.opacity(0.18))
                Image(systemName: ach.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ach.iconColor)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(ach.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tPrimary)
                Text(ach.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(Theme.subCardFill)
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(ach.iconColor.opacity(0.15), lineWidth: 0.7)))
    }
}

// MARK: - 活跃时段（24h 柱状图）

private struct HourlyChartCard: View {
    let tokens: [Int]
    private var maxTok: Int { max(tokens.max() ?? 1, 1) }
    private var peakHour: Int { tokens.indices.max(by: { tokens[$0] < tokens[$1] }) ?? 0 }

    var body: some View {
        Card(tint: Theme.claude) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.claude.gradient).frame(width: 8, height: 8)
                        .shadow(color: Theme.claude.opacity(0.6), radius: 3)
                    Text("活跃时段")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tPrimary)
                    Spacer()
                    Text("高峰 \(String(format: "%02d", peakHour)):00")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.tTertiary)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                GeometryReader { geo in
                    let barW = (geo.size.width - 23 * 2) / 24
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<24, id: \.self) { h in
                            let ratio = Double(tokens[h]) / Double(maxTok)
                            let h2 = max(2, geo.size.height * CGFloat(ratio))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(h == peakHour
                                      ? AnyShapeStyle(Theme.claude.opacity(0.9))
                                      : AnyShapeStyle(LinearGradient(
                                            colors: [Theme.claude.opacity(0.55), Theme.claude.opacity(0.25)],
                                            startPoint: .top, endPoint: .bottom)))
                                .frame(width: barW, height: h2)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                }
                .frame(height: 72)
                HStack {
                    Text("0"); Spacer(); Text("6"); Spacer()
                    Text("12"); Spacer(); Text("18"); Spacer(); Text("23")
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.tTertiary)
            }
        }
    }
}

// MARK: - 模型用量

private let modelBarColors: [Color] = [
    Theme.claude, Theme.codex, Theme.gemini, Theme.grok,
    .purple, .teal, .mint, .indigo
]

private struct ModelBreakdownCard: View {
    let models: [ModelStat]
    private var maxTok: Int { max(models.map(\.tokens).max() ?? 1, 1) }

    var body: some View {
        Card(tint: Theme.codex) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.codex.gradient).frame(width: 8, height: 8)
                        .shadow(color: Theme.codex.opacity(0.5), radius: 3)
                    Text("模型用量")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tPrimary)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                VStack(spacing: 10) {
                    ForEach(Array(models.prefix(6).enumerated()), id: \.element.id) { i, m in
                        ModelRow(stat: m, ratio: Double(m.tokens)/Double(maxTok),
                                 tint: modelBarColors[i % modelBarColors.count])
                    }
                }
            }
        }
    }
}

private struct ModelRow: View {
    let stat: ModelStat
    let ratio: Double
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stat.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tPrimary)
                Spacer()
                Text("\(Fmt.human(stat.tokens))  $\(Int(stat.cost))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.hairline)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * CGFloat(ratio)), height: 5)
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - 项目排行

private struct ProjectRankingCard: View {
    let projects: [ProjectStat]
    @State private var hideCost = false
    private var maxTok: Int { max(projects.map(\.tokens).max() ?? 1, 1) }

    var body: some View {
        Card(tint: Theme.aider) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.aider.gradient).frame(width: 8, height: 8)
                        .shadow(color: Theme.aider.opacity(0.5), radius: 3)
                    Text("项目排行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tPrimary)
                    Spacer()
                    Button { hideCost.toggle() } label: {
                        Image(systemName: hideCost ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                VStack(spacing: 10) {
                    ForEach(Array(projects.prefix(8).enumerated()), id: \.element.id) { i, p in
                        ProjectRow(stat: p,
                                   ratio: Double(p.tokens)/Double(maxTok),
                                   tint: modelBarColors[i % modelBarColors.count],
                                   hideCost: hideCost)
                    }
                }
            }
        }
    }
}

private struct ProjectRow: View {
    let stat: ProjectStat
    let ratio: Double
    let tint: Color
    let hideCost: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stat.project)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tPrimary)
                    .lineLimit(1)
                Spacer()
                if hideCost {
                    Text("$●●●")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tTertiary)
                } else {
                    Text("\(Fmt.human(stat.tokens))  $\(Int(stat.cost))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tTertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.05)).frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * CGFloat(ratio)), height: 5)
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - 热力图卡片（原有逻辑，重新包装）

private enum HeatmapRange: String, CaseIterable, Hashable {
    case week, month, year
    var label: String {
        switch self { case .week: "周"; case .month: "月"; case .year: "年" }
    }
}

private func heatColor(ratio: Double) -> Color {
    let r = min(1, max(0, ratio))
    if r <= 0 { return Theme.hairline }
    return Color(red: 0.20 + 0.78 * r, green: 0.21 + 0.54 * r, blue: 0.18 - 0.00 * r)
}

private let dashFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private struct HeatmapSectionCard: View {
    let heatmap: [String: Double]
    @State private var range: HeatmapRange = .month

    var body: some View {
        Card(tint: Theme.qoder) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.qoder.gradient).frame(width: 8, height: 8)
                        .shadow(color: Theme.qoder.opacity(0.6), radius: 3)
                    Text("活跃热力")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tPrimary)
                    Spacer()
                    Picker("", selection: $range) {
                        ForEach(HeatmapRange.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                    .controlSize(.mini)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HeatmapBody(heatmap: heatmap, range: range)
            }
        }
    }
}

private struct HeatmapBody: View {
    let heatmap: [String: Double]
    let range: HeatmapRange
    private var maxCost: Double { max(heatmap.values.max() ?? 0, 0.0001) }
    private var cellSize: CGFloat { range == .year ? 10 : 12 }
    private var cellGap: CGFloat  { range == .year ? 2 : 3 }
    private var weekCols: Int     { range == .week ? 1 : range == .month ? 5 : 52 }

    var body: some View {
        switch range {
        case .week: rowView
        default:
            let view = gridView
            if range == .year {
                ScrollView(.horizontal, showsIndicators: false) { view.padding(.vertical, 2) }
            } else {
                view
            }
        }
    }

    private var rowView: some View {
        HStack(spacing: cellGap) {
            ForEach(Array(days(7).enumerated()), id: \.offset) { _, d in cell(d) }
        }
    }

    private var gridView: some View {
        let total = weekCols * 7
        let allDays = days(total)
        let cols: [[Date]] = stride(from: 0, to: allDays.count, by: 7).map {
            Array(allDays[$0..<min($0+7, allDays.count)])
        }
        return HStack(alignment: .top, spacing: cellGap) {
            ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                VStack(spacing: cellGap) {
                    ForEach(Array(col.enumerated()), id: \.offset) { _, d in cell(d) }
                }
            }
        }
    }

    private func cell(_ date: Date) -> some View {
        let key = dashFmt.string(from: date)
        let cost = heatmap[key] ?? 0
        return RoundedRectangle(cornerRadius: 2)
            .fill(heatColor(ratio: cost / maxCost))
            .frame(width: cellSize, height: cellSize)
            .help("\(key): $\(String(format: "%.2f", cost))")
    }

    private func days(_ n: Int) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }
}

// MARK: - 工具对比卡片

@MainActor
private struct AgentsOverviewSection: View {
    let state: AppState

    struct AgentItem {
        var name: String
        var tint: Color
        var usage: AgentUsage
    }

    private var items: [AgentItem] {
        [
            state.claude.map   { AgentItem(name: "Claude Code", tint: Theme.claude,   usage: $0) },
            state.codex.map    { AgentItem(name: "Codex",        tint: Theme.codex,    usage: $0) },
            state.gemini.map   { AgentItem(name: "Gemini",       tint: Theme.gemini,   usage: $0) },
            state.grok.map     { AgentItem(name: "Grok",         tint: Theme.grok,     usage: $0) },
            state.aider.map    { AgentItem(name: "Aider",        tint: Theme.aider,    usage: $0) },
            state.openclaw.map { AgentItem(name: "OpenClaw",     tint: Theme.openclaw, usage: $0) },
            state.opencode.map { AgentItem(name: "OpenCode",     tint: Theme.opencode, usage: $0) },
            state.qoder.map    { AgentItem(name: "Qoder",        tint: Theme.qoder,    usage: $0) },
        ]
        .compactMap { $0 }
        .filter { $0.usage.yearTokens > 0 || $0.usage.todayTokens > 0 }
        .sorted { $0.usage.yearTokens > $1.usage.yearTokens }
    }

    var body: some View {
        if !items.isEmpty {
            Card(tint: Theme.claude) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(LinearGradient(colors: [Theme.claude, Theme.gemini],
                                                  startPoint: .leading, endPoint: .trailing))
                            .frame(width: 8, height: 8)
                            .shadow(color: Theme.claude.opacity(0.6), radius: 3)
                        Text("工具对比")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.tPrimary)
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack(spacing: 0) {
                        Text("工具").font(.system(size: 9)).foregroundStyle(Theme.tTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("今日").font(.system(size: 9)).foregroundStyle(Theme.tTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("本周").font(.system(size: 9)).foregroundStyle(Theme.tTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("全年").font(.system(size: 9)).foregroundStyle(Theme.tTertiary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    VStack(spacing: 7) {
                        ForEach(items.indices, id: \.self) { agentRow(items[$0]) }
                    }
                }
            }
        }
    }

    private func agentRow(_ item: AgentItem) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(item.tint).frame(width: 6, height: 6)
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statCell(tokens: item.usage.todayTokens, cost: item.usage.todayCost)
                .frame(width: 64, alignment: .trailing)
            statCell(tokens: item.usage.weekTokens, cost: item.usage.weekCost)
                .frame(width: 64, alignment: .trailing)
            statCell(tokens: item.usage.yearTokens, cost: item.usage.yearCost)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func statCell(tokens: Int, cost: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(tokens > 0 ? Fmt.human(tokens) : "—")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(tokens > 0 ? Theme.tPrimary : Theme.tTertiary.opacity(0.4))
            if cost >= 0.005 {
                Text(cost >= 10 ? "$\(Int(cost))" : String(format: "$%.2f", cost))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Theme.tTertiary)
            }
        }
    }
}

// MARK: - 空状态

private struct EmptyDash: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(Theme.tTertiary)
            Text("暂无数据")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
