import SwiftUI

// MARK: - Settings View

@MainActor
struct SettingsView: View {
    @ObservedObject var state: AppState
    let onToggleAwake: (Bool) -> Void
    let onSelectMode: (AwakeMode) -> Void
    let onSelectDuration: (AwakeDuration) -> Void
    let onToggleLaunch: (Bool) -> Void
    let onSitReminderChanged: () -> Void
    let onTestSitReminder: () -> Void

    @AppStorage("showClaude")   private var showClaude   = true
    @AppStorage("showCodex")    private var showCodex    = true
    @AppStorage("showGemini")   private var showGemini   = true
    @AppStorage("showGrok")     private var showGrok     = true
    @AppStorage("showAider")    private var showAider    = true
    @AppStorage("showOpenClaw") private var showOpenClaw = true
    @AppStorage("showOpenCode") private var showOpenCode = true
    @AppStorage("showQoder")    private var showQoder    = true
    @AppStorage(SitReminder.enabledKey) private var sitReminderOn = false
    @AppStorage(SitReminder.intervalKey) private var sitReminderInterval = SitReminder.defaultIntervalMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsHeader

            HStack(alignment: .top, spacing: 11) {
                VStack(alignment: .leading, spacing: 11) {
                    keepAwakeSection
                    generalSection
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 11) {
                    agentsSection
                    sitReminderSection
                    reminderSection
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    // MARK: - 头部

    var settingsHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.claude.opacity(0.16))
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.claude)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("设置")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.tPrimary)
                Text("显示与提醒")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.tTertiary)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    // MARK: - 保持唤醒

    var keepAwakeSection: some View {
        settingsSection("cup.and.saucer.fill", "保持唤醒") {
            settingsToggleRow("启用", isOn: Binding(
                get: { state.keepAwake },
                set: { onToggleAwake($0) }
            ))

            VStack(alignment: .leading, spacing: 4) {
                Text("模式").font(.system(size: 10)).foregroundStyle(Theme.tTertiary)
                HStack(spacing: 0) {
                    ForEach(AwakeMode.allCases, id: \.self) { m in
                        let label = m == .standard ? "标准" : "合盖"
                        let on = state.mode == m
                        Button {
                            onSelectMode(m)
                        } label: {
                            Text(label)
                                .font(.system(size: 10, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.tTertiary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background {
                                    if on {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(.ultraThinMaterial)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text("时长").font(.system(size: 10)).foregroundStyle(Theme.tTertiary)
                HStack(spacing: 0) {
                    ForEach(AwakeDuration.allCases, id: \.self) { d in
                        let on = state.duration == d
                        Button {
                            onSelectDuration(d)
                        } label: {
                            Text(d.label)
                                .font(.system(size: 10, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.tTertiary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background {
                                    if on {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(.ultraThinMaterial)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let remaining = state.awakeRemaining {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 9)).foregroundStyle(Theme.tTertiary)
                    Text("剩余 \(formatResetIn(remaining))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Theme.tSecondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
    }

    // MARK: - 常规

    var generalSection: some View {
        settingsSection("slider.horizontal.3", "常规") {
            settingsToggleRow("开机自启", isOn: Binding(
                get: { state.launchAtLogin },
                set: { onToggleLaunch($0) }
            ))
        }
    }

    // MARK: - 显示卡片

    var agentsSection: some View {
        settingsSection("square.grid.2x2", "显示卡片") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7),
                                GridItem(.flexible(), spacing: 7)], spacing: 7) {
                settingsRow("Claude",   tint: Theme.claude,   isOn: $showClaude)
                settingsRow("Codex",    tint: Theme.codex,    isOn: $showCodex)
                settingsRow("Gemini",   tint: Theme.gemini,   isOn: $showGemini)
                settingsRow("Grok",     tint: Theme.grok,     isOn: $showGrok)
                settingsRow("Aider",    tint: Theme.aider,    isOn: $showAider)
                settingsRow("OpenClaw", tint: Theme.openclaw, isOn: $showOpenClaw)
                settingsRow("OpenCode", tint: Theme.opencode, isOn: $showOpenCode)
                settingsRow("Qoder",    tint: Theme.qoder,    isOn: $showQoder)
            }
        }
    }

    // MARK: - 空闲提醒

    var sitReminderSection: some View {
        settingsSection("figure.walk.circle", "久坐提醒") {
            settingsToggleRow("启用", isOn: $sitReminderOn)
                .onChange(of: sitReminderOn) { _, _ in
                    onSitReminderChanged()
                }

            if sitReminderOn {
                HStack {
                    Text("间隔").font(.system(size: 10)).foregroundStyle(Theme.tTertiary)
                    Spacer()
                    Picker("", selection: $sitReminderInterval) {
                        Text("45m").tag(45)
                        Text("60m").tag(60)
                        Text("90m").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .controlSize(.mini)
                    .onChange(of: sitReminderInterval) { _, _ in
                        onSitReminderChanged()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)

                settingsActionButton(icon: "bell.badge", title: "测试提醒") {
                    onTestSitReminder()
                }

                Text("基于系统空闲判断连续用机时长，看视频或开会不操作会被视为离开。")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.tTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
        }
    }

    var reminderSection: some View {
        settingsSection("bell.circle", "空闲提醒") {
            settingsToggleRow("启用", isOn: Binding(
                get: { state.idleReminderMinutes > 0 },
                set: { state.idleReminderMinutes = $0 ? 60 : 0 }
            ))

            if state.idleReminderMinutes > 0 {
                HStack {
                    Text("间隔").font(.system(size: 10)).foregroundStyle(Theme.tTertiary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { state.idleReminderMinutes },
                        set: { state.idleReminderMinutes = $0 }
                    )) {
                        Text("30m").tag(30)
                        Text("60m").tag(60)
                        Text("90m").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)

                Text("Claude Code 空闲超过设定时长后发送提醒。")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.tTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
        }
    }

    // MARK: - Shared helpers

    func settingsSection<C: View>(_ icon: String, _ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.claude.opacity(0.95))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.claude.opacity(0.10)))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tSecondary)
            }
            VStack(spacing: 6) { content() }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.subCardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.7)
                )
        )
    }

    func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.tPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    func settingsRow(_ name: String, tint: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint.gradient).frame(width: 6, height: 6)
                .shadow(color: tint.opacity(0.4), radius: 2)
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.tPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    func settingsActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.claude)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tPrimary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04)))
        }
        .buttonStyle(.plain)
    }

    private func formatResetIn(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
