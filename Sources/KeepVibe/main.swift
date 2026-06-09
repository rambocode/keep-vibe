import Cocoa
import SwiftUI
import Combine
import Carbon.HIToolbox
import UserNotifications

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    // 弹窗显示期间监听全局点击，作为 transient 行为的兜底，确保点击外部必然关闭
    private var popoverEventMonitor: Any?
    // 承载弹窗定位的透明锚点窗口：始终贴到图标真实屏幕位置，避免 Hidden Bar 收起图标时弹窗跳到 (0,0)
    private var popoverAnchorWindow: NSWindow?
    private let state = AppState()
    private let keepAwakeManager = KeepAwakeManager()
    private let sitReminder = SitReminder()
    private var awakeRemainingTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var refreshGeneration: Int = 0

    // 空闲提醒：监听 idleReminderMinutes，距上次 Claude 活动超阈值时发通知
    private var idleReminderTimer: Timer?
    private var idleReminderCancellable: AnyCancellable?
    private var lastClaudeActivity: Date?
    private var lastClaudeActivitySignature: Int?
    private var idleReminderFired = false

    private static let claudeStatusColor = NSColor(red: 0.92, green: 0.52, blue: 0.40, alpha: 1)
    private static let codexStatusColor = NSColor(red: 0.42, green: 0.68, blue: 0.98, alpha: 1)

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化开机启动状态
        state.launchAtLogin = LaunchAtLogin.isEnabled

        // 设置 keepAwake 到期回调
        keepAwakeManager.onExpire = { [weak self] in
            guard let self else { return }
            self.state.keepAwake = false
        }

        // 建 NSStatusItem
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            configureStatusBarButton(button)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
        updateStatusTitle()

        // 建 NSPopover
        let popover = NSPopover()
        popover.behavior = .transient
        // 初始外观跟随用户偏好（默认跟随系统 = nil）
        let savedThemeRaw = UserDefaults.standard.string(forKey: ThemePreference.storageKey) ?? ""
        popover.appearance = (ThemePreference(rawValue: savedThemeRaw) ?? .system).nsAppearance
        let host = NSHostingController(
            rootView: MenuContentView(
                state: state,
                onToggleAwake: { [weak self] enabled in
                    guard let self else { return }
                    self.handleToggleAwake(enabled)
                },
                onSelectMode: { [weak self] mode in
                    guard let self else { return }
                    self.state.mode = mode
                    if self.state.keepAwake {
                        self.keepAwakeManager.start(mode: mode, duration: self.state.duration)
                    }
                },
                onSelectDuration: { [weak self] duration in
                    guard let self else { return }
                    self.state.duration = duration
                    if self.state.keepAwake {
                        self.keepAwakeManager.start(mode: self.state.mode, duration: duration)
                    }
                },
                onToggleLaunch: { [weak self] enabled in
                    guard let self else { return }
                    LaunchAtLogin.set(enabled)
                    self.state.launchAtLogin = LaunchAtLogin.isEnabled
                },
                onSitReminderChanged: { [weak self] in
                    self?.sitReminder.updateRunning()
                },
                onTestSitReminder: { [weak self] in
                    self?.sitReminder.testPing()
                },
                onRefresh: { [weak self] in
                    self?.refresh(queueIfRunning: true)
                },
                onQuit: {
                    NSApp.terminate(nil)
                },
                onThemeChanged: { [weak self] pref in
                    self?.popover?.appearance = pref.nsAppearance
                }
            )
        )
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.delegate = self
        self.popover = popover

        // 配置空闲提醒（监听 idleReminderMinutes）
        setupIdleReminder()
        sitReminder.updateRunning()

        // 立即刷新一次
        refresh()
    }

    private func configureStatusBarButton(_ button: NSStatusBarButton) {
        // 基底图标由 button.image 承载，保证状态项始终可见、可点击。
        button.image = makeStatusBarSymbol("hourglass") ?? makeStatusBarIcon()
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString()
        button.isBordered = false
    }

    /// 生成菜单栏用的模板 SF Symbol 图标（跟随系统明暗自动着色，保证两种外观下都可见）。
    private func makeStatusBarSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "KeepVibe")?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        return image
    }

    private func makeStatusBarIcon() -> NSImage? {
        let resourceURL = Bundle.main.url(forResource: "menubar-icon-white", withExtension: "png")
            ?? Bundle.module.url(forResource: "menubar-icon-white", withExtension: "png")
        guard let url = resourceURL,
              let image = NSImage(contentsOf: url)
        else {
            return NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "KeepVibe")
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "KeepVibe"
        return image
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }

        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

        func appendSegment(value: String, color: NSColor) {
            if title.length > 0 {
                title.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }

            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = false

            let attachment = NSTextAttachment()
            attachment.image = image
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(
                string: " \(value)",
                attributes: [
                    .font: font,
                    .baselineOffset: 1,
                    .foregroundColor: color
                ]
            ))
        }

        if state.keepAwake {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Self.claudeStatusColor]))
            let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = false

            let attachment = NSTextAttachment()
            attachment.image = image
            title.append(NSAttributedString(attachment: attachment))
        }

        if let claudeWindow = state.claude?.window {
            appendSegment(
                value: String(format: "%.0f", (1 - claudeWindow.usedFraction) * 100),
                color: Self.claudeStatusColor
            )
        }
        if let codexWindow = state.codex?.window {
            appendSegment(
                value: String(format: "%.0f", (1 - codexWindow.usedFraction) * 100),
                color: Self.codexStatusColor
            )
        }
        if title.length == 0 {
            appendSegment(value: "…", color: .secondaryLabelColor)
        }

        button.attributedTitle = title
        button.image = nil
    }

    // MARK: - Popover toggle

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        refresh()

        // accessory app 的 transient 弹窗只有在 app 处于 active 时才能可靠
        // 捕获「点击其它应用」的事件；不激活会导致偶发不自动隐藏。
        NSApp.activate(ignoringOtherApps: true)
        showPopover(popover, under: button)
        installPopoverEventMonitor()
    }

    /// 把弹窗显示在状态栏图标的正下方——无论图标被 Hidden Bar / Bartender 等移到屏幕
    /// 左侧还是右侧。关键：不直接用 `show(relativeTo:of:)`（图标坐标异常时 AppKit 会把
    /// 弹窗 fallback 到屏幕原点 (0,0)），而是用一个与图标等位的透明锚点窗口承载定位，
    /// 弹窗箭头始终指向该矩形底边中点。
    private func showPopover(_ popover: NSPopover, under button: NSStatusBarButton) {
        let anchorRect = statusItemScreenRect(button)
        let anchor = popoverAnchorWindow ?? makePopoverAnchorWindow()
        popoverAnchorWindow = anchor
        anchor.setFrame(anchorRect, display: false)
        anchor.orderFrontRegardless()
        guard let anchorView = anchor.contentView else { return }
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    /// 图标在屏幕上的真实矩形（屏幕坐标，左下为原点）。
    /// 若图标被收起到屏幕可见区之外，退回到鼠标光标处，避免落到 (0,0)。
    private func statusItemScreenRect(_ button: NSStatusBarButton) -> NSRect {
        let statusItemRect: NSRect?
        if let win = button.window, button.bounds.width > 0 {
            statusItemRect = win.convertToScreen(button.convert(button.bounds, to: nil))
        } else {
            statusItemRect = nil
        }

        return PopoverAnchorResolver.resolve(
            statusItemRect: statusItemRect,
            screenFrames: NSScreen.screens.map(\.frame),
            mouseLocation: NSEvent.mouseLocation
        )
    }

    /// 创建一个透明、不吃事件的锚点窗口，仅用于定位弹窗（不显示任何内容）。
    private func makePopoverAnchorWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        w.level = .statusBar
        w.ignoresMouseEvents = true
        return w
    }

    // MARK: - Popover 外部点击兜底

    /// 弹窗显示后，监听全局鼠标按下；点击发生在弹窗之外时立即关闭。
    private func installPopoverEventMonitor() {
        removePopoverEventMonitor()
        popoverEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let popover = self.popover, popover.isShown else { return }
                popover.performClose(nil)
            }
        }
    }

    private func removePopoverEventMonitor() {
        if let monitor = popoverEventMonitor {
            NSEvent.removeMonitor(monitor)
            popoverEventMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.removePopoverEventMonitor()
            self.popoverAnchorWindow?.orderOut(nil)
        }
    }

    // MARK: - Awake toggle

    private func handleToggleAwake(_ enabled: Bool) {
        state.keepAwake = enabled
        if enabled {
            keepAwakeManager.start(mode: state.mode, duration: state.duration)
            updateAwakeRemainingTimer()
        } else {
            keepAwakeManager.stop()
            updateAwakeRemainingTimer()
        }
        // 立即更新剩余时间显示
        state.awakeRemaining = keepAwakeManager.remaining
        updateStatusTitle()
    }

    // MARK: - Refresh

    private func updateAwakeRemainingTimer() {
        awakeRemainingTimer?.invalidate()
        awakeRemainingTimer = nil

        guard state.keepAwake, keepAwakeManager.remaining != nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let remaining = self.keepAwakeManager.remaining
                self.state.awakeRemaining = remaining
                if remaining == nil || remaining == 0 {
                    self.updateAwakeRemainingTimer()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        awakeRemainingTimer = timer
    }

    private func refresh(queueIfRunning: Bool = false) {
        guard refreshTask == nil else {
            if queueIfRunning {
                refreshPending = true
            }
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let now = Date()

        // 三路并行：系统监控 / 日志扫描 / Python 外部工具
        refreshTask = Task {
            async let sys  = Task.detached(priority: .utility) { SystemMonitor.sample() }.value
            async let scan = Task.detached(priority: .utility) { UsageLogScanner.summarizeAll(now: now) }.value
            async let ext  = ScriptRunner.loadAsync()

            let s = await sys
            let u = await scan
            let e = await ext

            if generation == refreshGeneration {
                state.system    = s
                state.claude    = u.claude
                state.codex     = u.codex
                state.dashboard = u.dashboard
                state.lastUpdated   = Date()
                state.awakeRemaining = keepAwakeManager.remaining
                noteClaudeActivity(from: u.claude)
                // 周配额进度条（Python 脚本提供）
                if let q = e?.claude, let q7 = q.q7 {
                    let at = q.q7_reset.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    state.claude?.weekQuota = QuotaStat(usedFraction: q7 / 100.0, resetAt: at)
                }
                if let q = e?.codex, let pw = q.pw {
                    let at = q.rw.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    state.codex?.weekQuota = QuotaStat(usedFraction: pw / 100.0, resetAt: at)
                }
                if let q = e?.codex, let p5 = q.p5 {
                    let resetIn = q.r5.map { max(0, Date(timeIntervalSince1970: TimeInterval($0)).timeIntervalSinceNow) }
                    state.codex?.window = WindowStat(
                        tokens: state.codex?.window?.tokens ?? 0,
                        tokensPerMin: state.codex?.window?.tokensPerMin ?? 0,
                        resetIn: resetIn,
                        usedFraction: min(max(p5 / 100.0, 0), 1)
                    )
                }
                state.gemini   = e?.gemini.map   { toolStatToAgentUsage($0) }
                state.grok     = e?.grok.map     { toolStatToAgentUsage($0) }
                state.aider    = e?.aider.map    { toolStatToAgentUsage($0) }
                state.openclaw = e?.openclaw.map { toolStatToAgentUsage($0) }
                state.opencode = e?.opencode.map { toolStatToAgentUsage($0) }
                state.qoder    = e?.qoder.map    { toolStatToAgentUsage($0) }
                updateStatusTitle()
            }
            refreshTask = nil
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
    }

    // MARK: - 空闲提醒（idle reminder）

    /// 在启动时调用：监听 state.idleReminderMinutes 变化，按需启停空闲提醒定时器。
    private func setupIdleReminder() {
        // UNUserNotificationCenter 要求正规 App Bundle；swift run 时跳过
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

        idleReminderCancellable = state.$idleReminderMinutes
            .removeDuplicates()
            .sink { [weak self] minutes in
                self?.reconfigureIdleReminder(minutes: minutes)
            }
        reconfigureIdleReminder(minutes: state.idleReminderMinutes)
    }

    /// 根据当前阈值（分钟）启停定时器。<= 0 表示禁用。
    private func reconfigureIdleReminder(minutes: Int) {
        idleReminderTimer?.invalidate()
        idleReminderTimer = nil
        idleReminderFired = false

        guard minutes > 0 else { return }

        // 每 30 秒检查一次是否超过空闲阈值
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdleReminder()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleReminderTimer = timer
    }

    /// 检查距上次 Claude 活动是否超过阈值，超过则发一次通知（直到下次有活动才会再次提醒）。
    private func checkIdleReminder() {
        let minutes = state.idleReminderMinutes
        guard minutes > 0, let last = lastClaudeActivity else { return }

        let idleSeconds = Date().timeIntervalSince(last)
        let threshold = TimeInterval(minutes * 60)

        if idleSeconds >= threshold {
            if !idleReminderFired {
                idleReminderFired = true
                sendIdleNotification(minutes: minutes)
            }
        } else {
            idleReminderFired = false
        }
    }

    /// 依据最新 Claude 用量推断是否“刚有活动”，若发生变化则刷新最近活动时间。
    private func noteClaudeActivity(from claude: AgentUsage?) {
        guard let claude else { return }
        // 用关键字段构造签名：tokens / 活跃会话 / 窗口 tokens 任一变化都视为有新活动
        let signature = claude.todayTokens
            ^ (claude.activeSessions << 20)
            ^ ((claude.window?.tokens ?? 0) << 4)

        if lastClaudeActivitySignature == nil {
            // 首次记录：以当前时间作为基线，不立即视为“刚活动”
            lastClaudeActivitySignature = signature
            lastClaudeActivity = Date()
            return
        }

        if signature != lastClaudeActivitySignature {
            lastClaudeActivitySignature = signature
            lastClaudeActivity = Date()
            idleReminderFired = false
        }
    }

    /// 发送一条空闲提醒通知。
    private func sendIdleNotification(minutes: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "KeepVibe"
        content.body = "Claude 已空闲超过 \(minutes) 分钟，记得保持节奏 ✨"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "keepvibe.idle.reminder",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// MARK: - 外部工具用量转换

/// 将 Python 采集的 ExternalToolStat 映射为统一的 AgentUsage。
private func toolStatToAgentUsage(_ stat: ExternalToolStat) -> AgentUsage {
    var u = AgentUsage()
    u.todayTokens  = (stat.today?.inputTokens ?? 0) + (stat.today?.outputTokens ?? 0)
    u.todayCost    = stat.today?.cost ?? 0
    u.todayBreakdown = TokenBreakdown(input: stat.today?.inputTokens ?? 0, output: stat.today?.outputTokens ?? 0)
    u.yesterdayTokens = (stat.yesterday?.inputTokens ?? 0) + (stat.yesterday?.outputTokens ?? 0)
    u.yesterdayCost = stat.yesterday?.cost ?? 0
    u.yesterdayBreakdown = TokenBreakdown(input: stat.yesterday?.inputTokens ?? 0, output: stat.yesterday?.outputTokens ?? 0)
    u.weekTokens   = (stat.week?.inputTokens ?? 0) + (stat.week?.outputTokens ?? 0)
    u.weekCost     = stat.week?.cost ?? 0
    u.weekBreakdown = TokenBreakdown(input: stat.week?.inputTokens ?? 0, output: stat.week?.outputTokens ?? 0)
    u.monthTokens  = (stat.month?.inputTokens ?? 0) + (stat.month?.outputTokens ?? 0)
    u.monthCost    = stat.month?.cost ?? 0
    u.monthBreakdown = TokenBreakdown(input: stat.month?.inputTokens ?? 0, output: stat.month?.outputTokens ?? 0)
    u.yearTokens   = (stat.year?.inputTokens ?? 0) + (stat.year?.outputTokens ?? 0)
    u.yearCost     = stat.year?.cost ?? 0
    u.yearBreakdown = TokenBreakdown(input: stat.year?.inputTokens ?? 0, output: stat.year?.outputTokens ?? 0)
    u.activeSessions = stat.today?.sessions ?? 0
    return u
}

// MARK: - Debug dump (核对数据用：KeepVibe --dump)

if CommandLine.arguments.contains("--dump") {
    let now = Date()
    func fmt(_ u: AgentUsage) -> String {
        let w = u.window.map { "5h窗口 tokens=\($0.tokens) tok/min=\(Int($0.tokensPerMin)) resetIn=\(Int($0.resetIn ?? 0))s used=\(String(format: "%.2f", $0.usedFraction))" } ?? "(无窗口)"
        return """
          今日: \(u.todayTokens) tok  $\(String(format: "%.2f", u.todayCost))
          昨日: \(u.yesterdayTokens) tok  $\(String(format: "%.2f", u.yesterdayCost))
          本周: \(u.weekTokens) tok  $\(String(format: "%.2f", u.weekCost))
          本月: \(u.monthTokens) tok  $\(String(format: "%.2f", u.monthCost))
          \(w)
          活跃会话: \(u.activeSessions)  成本近似: \(u.costIsApprox)
        """
    }
    let sys = SystemMonitor.sample()
    print("=== 系统状态 ===")
    print("  开机时长: \(Int(sys.uptimeSeconds))s  CPU: \(String(format: "%.1f", sys.cpuPercent))%  内存: \(sys.memUsedBytes/1_048_576)/\(sys.memTotalBytes/1_048_576) MB  电池: \(sys.batteryPercent.map { "\($0)%" } ?? "无") 充电:\(sys.batteryCharging)")
    print("=== Claude Code ===")
    let usage = UsageLogScanner.summarizeAll(now: now)
    print(fmt(usage.claude))
    print("=== Codex ===")
    print(fmt(usage.codex))
    exit(0)
}

// MARK: - Entry point

private func configureMenuBarProcessForDebugRuns() {
    let lsuiElement = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false
    guard !lsuiElement else { return }

    // swift run 启动时没有 .app/Info.plist，需在创建 NSApplication 前标记为 UIElement。
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
    _ = TransformProcessType(&psn, UInt32(kProcessTransformToUIElementApplication))
}

configureMenuBarProcessForDebugRuns()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
