import SwiftUI
import AppKit

// MARK: - Theme Preference

enum ThemePreference: String, CaseIterable {
    case system, light, dark

    static let storageKey = "themePreference"

    /// nil 表示跟随系统，不强制
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// nil 表示继承 NSApp.effectiveAppearance
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    func next() -> ThemePreference {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// MARK: - Adaptive Color Helper

extension Color {
    /// 根据当前 NSView 外观自动选择浅色/深色值（动态 NSColor，无需透传 colorScheme）
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}

// MARK: - Visual Effect (毛玻璃)

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        let isDark = v.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        v.material = isDark ? .hudWindow : .popover
    }
}

// MARK: - Tooltip

private class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct Tip: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView {
        let v = PassthroughView(); v.toolTip = text; return v
    }
    func updateNSView(_ v: NSView, context: Context) { v.toolTip = text }
}

extension View {
    func tip(_ text: String) -> some View { overlay(Tip(text: text)) }
}

// MARK: - Theme

enum Theme {
    static let claude   = Color(red: 0.92, green: 0.52, blue: 0.40)   // 柔珊瑚
    static let codex    = Color(red: 0.42, green: 0.68, blue: 0.98)   // 天青
    static let gemini   = Color(red: 0.62, green: 0.52, blue: 0.92)   // 薰衣草
    static let grok     = Color(red: 0.65, green: 0.68, blue: 0.75)   // 冷灰银
    static let aider    = Color(red: 0.30, green: 0.78, blue: 0.50)   // 翠绿
    static let openclaw = Color(red: 0.85, green: 0.45, blue: 0.68)   // 玫红
    static let opencode = Color(red: 0.55, green: 0.75, blue: 0.90)   // 天蓝灰
    static let qoder    = Color(red: 0.90, green: 0.75, blue: 0.35)   // 琥珀金

    static let panelWidth: CGFloat = 322
    static let cardRadius: CGFloat = 16
    static let outerPad: CGFloat = 15

    static var brand: LinearGradient {
        LinearGradient(colors: [claude.opacity(0.8), claude],
                       startPoint: .leading, endPoint: .trailing)
    }

    static var bg: LinearGradient {
        LinearGradient(
            colors: [
                Color(light: Color(red: 0.95, green: 0.95, blue: 0.97).opacity(0.94),
                      dark:  Color(red: 0.20, green: 0.21, blue: 0.25).opacity(0.92)),
                Color(light: Color(red: 0.90, green: 0.90, blue: 0.93).opacity(0.96),
                      dark:  Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.95)),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    /// 主色文字：深色模式白/浅色模式黑
    static let tPrimary   = Color(light: Color.black.opacity(0.92), dark: Color.white.opacity(0.97))
    /// 次要文字
    static let tSecondary = Color(light: Color.black.opacity(0.65), dark: Color.white.opacity(0.82))
    /// 辅助/说明文字
    static let tTertiary  = Color(light: Color.black.opacity(0.40), dark: Color.white.opacity(0.58))

    /// 卡片填充背景（替换原 Color.black.opacity(0.26) 硬编码）
    static let cardFill      = Color(light: Color.black.opacity(0.05), dark: Color.black.opacity(0.26))
    /// 卡片顶部高光（替换原 Color.white.opacity(0.05) 硬编码）
    static let cardHighlight = Color(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.05))
    /// 分隔线（替换原 Color.white.opacity(0.06) 硬编码）
    static let hairline      = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.06))
    /// 小卡片背景（替换 Color.black.opacity(0.18~0.20) 硬编码）
    static let subCardFill   = Color(light: Color.black.opacity(0.05), dark: Color.black.opacity(0.20))

    static func color(for kind: ToolKind) -> Color {
        switch kind {
        case .claude:   return claude
        case .codex:    return codex
        case .gemini:   return gemini
        case .grok:     return grok
        case .aider:    return aider
        case .openclaw: return openclaw
        case .opencode: return opencode
        case .qoder:    return qoder
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var tint: Color
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .fill(tint.opacity(0.08))
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Theme.cardHighlight, .clear],
                                startPoint: .top, endPoint: .center))
                    }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [tint.opacity(0.38), tint.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(hover ? 0.42 : 0.30),
                    radius: hover ? 16 : 12, x: 0, y: hover ? 9 : 6)
            .scaleEffect(hover ? 1.012 : 1)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.18), value: hover)
    }
}

// MARK: - Equal Height Grid (2列等高)

struct EqualHeightGrid: Layout {
    var columns = 2
    var hSpacing: CGFloat = 13
    var vSpacing: CGFloat = 13

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let colW = colWidth(in: proposal.width ?? 600)
        var h: CGFloat = 0
        for row in stride(from: 0, to: subviews.count, by: columns) {
            if row > 0 { h += vSpacing }
            h += rowHeight(row: row, colW: colW, subviews: subviews)
        }
        return CGSize(width: proposal.width ?? 600, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let colW = colWidth(in: bounds.width)
        var y = bounds.minY
        for row in stride(from: 0, to: subviews.count, by: columns) {
            let rh = rowHeight(row: row, colW: colW, subviews: subviews)
            for i in row..<min(row + columns, subviews.count) {
                let x = bounds.minX + CGFloat(i - row) * (colW + hSpacing)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: .init(width: colW, height: rh))
            }
            y += rh + vSpacing
        }
    }

    private func colWidth(in total: CGFloat) -> CGFloat {
        (total - hSpacing * CGFloat(columns - 1)) / CGFloat(columns)
    }
    private func rowHeight(row: Int, colW: CGFloat, subviews: Subviews) -> CGFloat {
        (row..<min(row + columns, subviews.count)).map {
            subviews[$0].sizeThatFits(.init(width: colW, height: nil)).height
        }.max() ?? 0
    }
}

// MARK: - Ring Gauge (缓存命中率环)

struct RingGauge: View {
    var value: Double
    var tint: Color
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4.5)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value / 100)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.35), radius: 4)
            VStack(spacing: -1) {
                Text("\(Int(value.rounded()))")
                    .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("%")
                    .font(.system(size: size * 0.16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.5), value: value)
    }
}

// MARK: - Mini Bar (配额进度条)

struct MiniBar: View {
    var value: Double
    var tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(3, geo.size.width * min(1, value / 100)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.45), value: value)
    }
}

// MARK: - Metric Cell (指标格子)

struct MetricCell: View {
    var icon: String
    var label: String
    var value: String
    var tint: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 21, height: 21)
                .background(Circle().fill(tint.opacity(0.10)))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tTertiary)
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.tPrimary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct RingMetricCell: View {
    var value: Double
    var label: String
    var tint: Color
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value / 100)))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 21, height: 21)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tTertiary)
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.tPrimary)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.5), value: value)
    }
}

// MARK: - Cost Headline (大号成本焦点)

struct CostHeadline: View {
    var value: String
    var caption: String
    var tint: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.tPrimary)
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tTertiary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Segmented Tabs (时间范围选择器)

struct SegmentedTabs: View {
    @Binding var sel: RangeKey
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(RangeKey.allCases) { k in
                let on = k == sel
                Text(k.label)
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { sel = k }
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Icon Button (底部图标按钮)

struct IconButton: View {
    var icon: String
    var label: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.10 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Fmt (格式化工具)

enum Fmt {
    static func human(_ n: Int) -> String {
        let v = Double(n)
        if v >= 100_000_000 { return String(format: "%.1f亿", v / 100_000_000) }
        if v >= 1_000_000   { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000       { return String(format: "%.0fK", v / 1_000) }
        return String(format: "%.0f", v)
    }

    static func countdown(_ epoch: Int?) -> String {
        guard let e = epoch else { return "?" }
        let s = TimeInterval(e) - Date().timeIntervalSince1970
        if s <= 0 { return "即将重置" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }

    static func reset(_ epoch: Int?) -> String {
        guard let e = epoch else { return "?" }
        let d = Date(timeIntervalSince1970: TimeInterval(e))
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    static func relativeTime(_ date: Date) -> String {
        let diff = Int(-date.timeIntervalSinceNow)
        if diff < 60   { return "\(diff)秒前" }
        if diff < 3600 { return "\(diff / 60)分钟前" }
        return "\(diff / 3600)小时前"
    }
}
