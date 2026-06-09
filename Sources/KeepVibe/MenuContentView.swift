import SwiftUI

// MARK: - Main View

@MainActor
struct MenuContentView: View {
    @ObservedObject var state: AppState
    var onToggleAwake: (Bool) -> Void
    var onSelectMode: (AwakeMode) -> Void
    var onSelectDuration: (AwakeDuration) -> Void
    var onToggleLaunch: (Bool) -> Void
    var onSitReminderChanged: () -> Void
    var onTestSitReminder: () -> Void
    var onRefresh: () -> Void
    var onQuit: () -> Void
    var onThemeChanged: (ThemePreference) -> Void

    @State private var sel: RangeKey = .today
    @State private var panelMode: PanelMode = .cards

    enum PanelMode { case cards, dashboard, settings }

    @AppStorage(ThemePreference.storageKey) private var themeRaw = ThemePreference.system.rawValue
    private var theme: ThemePreference { ThemePreference(rawValue: themeRaw) ?? .system }

    @AppStorage("showClaude")   private var showClaude   = true
    @AppStorage("showCodex")    private var showCodex    = true
    @AppStorage("showGemini")   private var showGemini   = true
    @AppStorage("showGrok")     private var showGrok     = true
    @AppStorage("showAider")    private var showAider    = true
    @AppStorage("showOpenClaw") private var showOpenClaw = true
    @AppStorage("showOpenCode") private var showOpenCode = true
    @AppStorage("showQoder")    private var showQoder    = true

    private var visibleCount: Int {
        [showClaude, showCodex, showGemini, showGrok,
         showAider, showOpenClaw, showOpenCode, showQoder].filter { $0 }.count
    }
    private var useWide: Bool { visibleCount > 2 }
    private var panelWidth: CGFloat { useWide ? 640 : Theme.panelWidth }

    private var maxPanelHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 40
    }

    var body: some View {
        let scroll = ScrollView(.vertical, showsIndicators: false) { panelContent }
            .frame(width: panelWidth)
            .frame(maxHeight: maxPanelHeight)
            .background(Theme.bg)
            .background(VisualEffect())
        Group {
            if let scheme = theme.colorScheme {
                scroll.environment(\.colorScheme, scheme)
            } else {
                scroll
            }
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            switch panelMode {
            case .dashboard:
                DashboardView(state: state)
            case .settings:
                SettingsView(
                    state: state,
                    onToggleAwake: onToggleAwake,
                    onSelectMode: onSelectMode,
                    onSelectDuration: onSelectDuration,
                    onToggleLaunch: onToggleLaunch,
                    onSitReminderChanged: onSitReminderChanged,
                    onTestSitReminder: onTestSitReminder
                )
            case .cards:
                cardsContent
            }
            footer
        }
        .padding(Theme.outerPad)
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 9) {
            Button {
                if panelMode != .cards {
                    withAnimation(.easeInOut(duration: 0.25)) { panelMode = .cards }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "timer")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("KeepVibe")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .tracking(0.5)
                        Text("AI 用量 · 保持唤醒")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.tTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip("主页")

            Spacer()

            if let updated = state.lastUpdated {
                Text(Fmt.relativeTime(updated))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.tTertiary)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    panelMode = panelMode == .dashboard ? .cards : .dashboard
                }
            } label: {
                Image(systemName: "chart.bar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(panelMode == .dashboard ? Theme.claude : Theme.tTertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .tip("数据面板")

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    panelMode = panelMode == .settings ? .cards : .settings
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(panelMode == .settings ? Theme.claude : Theme.tTertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .tip("设置")
        }
    }

    // MARK: - Cards

    // 单张工具卡片的描述：把 8 路工具收敛成数组，避免巨型 Optional tuple ViewBuilder
    private struct CardEntry: Identifiable {
        let id: String
        let tint: Color
        let content: AnyView
    }

    // 当前 sel 下应展示的工具卡片（按固定顺序）
    private var visibleCards: [CardEntry] {
        var out: [CardEntry] = []
        func add(_ id: String, _ show: Bool, _ usage: AgentUsage?, _ tint: Color,
                 _ make: (AgentUsage) -> AnyView) {
            if show, let u = usage, u.tokens(for: sel) > 0 {
                out.append(CardEntry(id: id, tint: tint, content: make(u)))
            }
        }
        add("claude",   showClaude,   state.claude,   Theme.claude)   { AnyView(claudeBlock($0, sel)) }
        add("codex",    showCodex,    state.codex,    Theme.codex)    { AnyView(codexBlock($0, sel)) }
        add("gemini",   showGemini,   state.gemini,   Theme.gemini)   { AnyView(toolBlock(.gemini,   $0, sel)) }
        add("grok",     showGrok,     state.grok,     Theme.grok)     { AnyView(toolBlock(.grok,     $0, sel)) }
        add("aider",    showAider,    state.aider,    Theme.aider)    { AnyView(toolBlock(.aider,    $0, sel)) }
        add("openclaw", showOpenClaw, state.openclaw, Theme.openclaw) { AnyView(toolBlock(.openclaw, $0, sel)) }
        add("opencode", showOpenCode, state.opencode, Theme.opencode) { AnyView(toolBlock(.opencode, $0, sel)) }
        add("qoder",    showQoder,    state.qoder,    Theme.qoder)    { AnyView(toolBlock(.qoder,    $0, sel)) }
        return out
    }

    private var cardsContent: some View {
        let cards = visibleCards
        let visibleIDs = Set(cards.map(\.id))
        return VStack(alignment: .leading, spacing: 13) {
            SegmentedTabs(sel: $sel)

            if cards.isEmpty {
                if state.claude == nil && state.codex == nil {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .frame(height: 90)
                } else {
                    HStack { Spacer()
                        Text("本\(sel.label.dropFirst())暂无数据")
                            .font(.system(size: 12)).foregroundStyle(Theme.tTertiary)
                        Spacer()
                    }.frame(height: 60)
                }
            } else if useWide {
                EqualHeightGrid() {
                    ForEach(cards) { c in
                        Card(tint: c.tint) { c.content }
                    }
                }
            } else {
                ForEach(cards) { c in
                    Card(tint: c.tint) { c.content }
                }
            }

            inactiveToolsLine(hasClaude: visibleIDs.contains("claude"),
                              hasCodex:  visibleIDs.contains("codex"),
                              hasGemini: visibleIDs.contains("gemini"),
                              hasGrok:   visibleIDs.contains("grok"),
                              hasAider:  visibleIDs.contains("aider"),
                              hasClaw:   visibleIDs.contains("openclaw"),
                              hasOCode:  visibleIDs.contains("opencode"),
                              hasQoder:  visibleIDs.contains("qoder"))
        }
    }

    // MARK: - Claude 卡片（含分项 + 窗口配额）

    @ViewBuilder
    func claudeBlock(_ u: AgentUsage, _ key: RangeKey) -> some View {
        let tint = Theme.claude
        let bd = u.breakdown(for: key)
        VStack(alignment: .leading, spacing: 11) {
            cardHead("Claude Code", tint: tint, sessions: u.activeSessions)
            CostHeadline(value: Fmt.human(bd.total), caption: "\(key.label) 总量", tint: tint)
            metricGrid(
                [.init("dollarsign.circle", "≈成本", String(format: "$%.2f", u.cost(for: key)))],
                hit: bd.cacheHitRate,
                extra: [
                    .init("arrow.down",              "输入",  Fmt.human(bd.input)),
                    .init("arrow.up",                "输出",  Fmt.human(bd.output)),
                    .init("bolt.fill",               "缓存读", Fmt.human(bd.cacheRead)),
                    .init("square.stack.3d.up.fill", "缓存写", Fmt.human(bd.cacheWrite)),
                ],
                tint: tint
            )
            if let win = u.window {
                thinDivider
                quotaRow(title: "5h 剩余",
                         pct: (1 - win.usedFraction) * 100,
                         resetIn: win.resetIn,
                         tint: tint)
            }
            if let wq = u.weekQuota {
                thinDivider
                weekQuotaRow(quota: wq, tint: tint)
            }
        }
    }

    // MARK: - Codex 卡片

    @ViewBuilder
    func codexBlock(_ u: AgentUsage, _ key: RangeKey) -> some View {
        let tint = Theme.codex
        let bd = u.breakdown(for: key)
        VStack(alignment: .leading, spacing: 11) {
            cardHead("Codex", tint: tint, sessions: u.activeSessions)
            CostHeadline(value: Fmt.human(bd.total), caption: "\(key.label) 总量", tint: tint)
            metricGrid(
                [.init("dollarsign.circle", "≈成本", String(format: "$%.2f", u.cost(for: key)))],
                hit: bd.cacheHitRate,
                extra: {
                    var m: [Metric] = [
                        .init("arrow.down", "输入",  Fmt.human(bd.input)),
                        .init("bolt.fill",  "缓存读", Fmt.human(bd.cacheRead)),
                        .init("arrow.up",   "输出",  Fmt.human(bd.output)),
                    ]
                    if bd.reasoning > 0 { m.append(.init("brain", "推理", Fmt.human(bd.reasoning))) }
                    return m
                }(),
                tint: tint
            )
            if let win = u.window {
                thinDivider
                quotaRow(title: "5h 剩余",
                         pct: (1 - win.usedFraction) * 100,
                         resetIn: win.resetIn,
                         tint: tint)
            }
            if let wq = u.weekQuota {
                thinDivider
                weekQuotaRow(quota: wq, tint: tint)
            }
        }
    }

    // MARK: - 通用外部工具卡片

    @ViewBuilder
    func toolBlock(_ kind: ToolKind, _ u: AgentUsage, _ key: RangeKey) -> some View {
        let tint = Theme.color(for: kind)
        let bd = u.breakdown(for: key)
        VStack(alignment: .leading, spacing: 11) {
            cardHead(kind.displayName, tint: tint, sessions: u.activeSessions)
            CostHeadline(value: Fmt.human(bd.total > 0 ? bd.total : u.tokens(for: key)),
                         caption: "\(key.label) 总量", tint: tint)
            metricGrid([.init("dollarsign.circle", "≈成本",
                              String(format: "$%.2f", u.cost(for: key)))],
                       tint: tint)
            if let wq = u.weekQuota {
                thinDivider
                weekQuotaRow(quota: wq, tint: tint)
            }
        }
    }

    // MARK: - 周配额行（进度条 + 绝对重置时间）

    func weekQuotaRow(quota: QuotaStat, tint: Color) -> some View {
        let pct = (1 - quota.usedFraction) * 100
        return VStack(spacing: 4) {
            HStack {
                Text("周剩余")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tSecondary)
                Spacer()
                Text(String(format: "%.0f%%", max(0, pct)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(pct <= 15 ? AnyShapeStyle(.red) : AnyShapeStyle(Theme.tPrimary))
                if let at = quota.resetAt {
                    Text("· \(resetDateStr(at))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.tTertiary)
                }
            }
            MiniBar(value: max(0, pct), tint: pct <= 15 ? .red : tint)
        }
    }

    private func resetDateStr(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: - 未活跃工具提示

    @ViewBuilder
    func inactiveToolsLine(hasClaude: Bool, hasCodex: Bool, hasGemini: Bool,
                           hasGrok: Bool, hasAider: Bool, hasClaw: Bool,
                           hasOCode: Bool, hasQoder: Bool) -> some View {
        let names: [(Bool, String)] = [
            (showClaude && !hasClaude, "Claude"),
            (showCodex  && !hasCodex,  "Codex"),
            (showGemini && !hasGemini, "Gemini"),
            (showGrok   && !hasGrok,   "Grok"),
            (showAider  && !hasAider,  "Aider"),
            (showOpenClaw && !hasClaw, "OpenClaw"),
            (showOpenCode && !hasOCode,"OpenCode"),
            (showQoder  && !hasQoder,  "Qoder"),
        ]
        let inactive = names.filter(\.0).map(\.1)
        if !inactive.isEmpty {
            Text("未检测到本地数据: " + inactive.joined(separator: " · "))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tTertiary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    var footer: some View {
        HStack(spacing: 4) {
            Text("成本按 API 价估算，非订阅实付")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tTertiary)
            Spacer()
            IconButton(icon: theme.icon, label: "") {
                let next = theme.next()
                themeRaw = next.rawValue
                onThemeChanged(next)
            }
            .tip("主题：\(theme.label)")
            IconButton(icon: "arrow.clockwise", label: "刷新") { onRefresh() }
            IconButton(icon: "power", label: "退出") { onQuit() }
        }
    }

    // MARK: - Shared card helpers

    struct Metric { var icon, label, value: String
        init(_ i: String, _ l: String, _ v: String) { icon = i; label = l; value = v }
    }

    func cardHead(_ title: String, tint: Color, sessions: Int = 0) -> some View {
        HStack(spacing: 7) {
            Circle().fill(tint.gradient).frame(width: 8, height: 8)
                .shadow(color: tint.opacity(0.6), radius: 3)
            Text(title).font(.system(size: 14, weight: .bold))
            if sessions > 0 {
                Text("\(sessions)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(tint.opacity(0.12)))
            }
            Spacer()
        }
    }

    @ViewBuilder
    func metricGrid(_ top: [Metric], hit: Double = 0, extra: [Metric] = [], tint: Color) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)],
                  alignment: .leading, spacing: 9) {
            ForEach(top.indices, id: \.self) { i in
                MetricCell(icon: top[i].icon, label: top[i].label,
                           value: top[i].value, tint: tint)
            }
            if hit > 0 {
                RingMetricCell(value: hit, label: "Cache Hit", tint: tint)
            }
            let offset = top.count + (hit > 0 ? 1 : 0)
            ForEach(extra.indices, id: \.self) { i in
                MetricCell(icon: extra[i].icon, label: extra[i].label,
                           value: extra[i].value, tint: tint)
                    .id(offset + i)
            }
        }
    }

    func quotaRow(title: String, pct: Double, resetIn: TimeInterval?, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.tSecondary)
                Spacer()
                Text(String(format: "%.0f%%", max(0, pct)))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(pct <= 15 ? AnyShapeStyle(.red) : AnyShapeStyle(Theme.tPrimary))
                if let r = resetIn {
                    Text("· \(formatResetIn(r))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.tTertiary)
                }
            }
            MiniBar(value: max(0, pct), tint: pct <= 15 ? .red : tint)
        }
    }

    var thinDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    private func formatResetIn(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
