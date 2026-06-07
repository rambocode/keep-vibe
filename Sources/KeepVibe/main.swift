import Cocoa
import SwiftUI

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let state = AppState()
    private let keepAwakeManager = KeepAwakeManager()
    private var refreshTimer: Timer?
    private var refreshGeneration: Int = 0
    private let popoverScreenMargin: CGFloat = 8
    private weak var popoverAnchorScreen: NSScreen?

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
            button.image = makeStatusBarIcon()
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        // 建 NSPopover
        let popover = NSPopover()
        popover.behavior = .transient
        // 锁定浅色外观：整个 popover（含材质背景）统一为 aqua，
        // 避免系统深色模式下文字抗锯齿在错误背景上计算而发虚
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(
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
                onRefresh: { [weak self] in
                    self?.refresh()
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
        self.popover = popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePopoverWindowResize(_:)),
            name: NSWindow.didResizeNotification,
            object: nil
        )

        // 立即刷新一次
        refresh()

        // 每 5 秒定时刷新（MainActor.assumeIsolated 消除 Swift 6 actor 隔离警告：
        // Timer 在主 RunLoop 上触发，始终在主线程执行，断言安全）
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
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

    // MARK: - Popover toggle

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // 多屏：先激活 App，并按状态栏图标所在屏的可视区域限高。
            NSApp.activate(ignoringOtherApps: true)
            let screen = button.window?.screen ?? NSScreen.main
            popoverAnchorScreen = screen
            if let visibleFrame = screen?.visibleFrame {
                state.maxContentHeight = max(320, visibleFrame.height - popoverScreenMargin * 8)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            keepPopoverInsideVisibleFrame(on: screen)
            DispatchQueue.main.async { [weak self] in
                self?.keepPopoverInsideVisibleFrame(on: screen)
            }
        }
    }

    @objc private func handlePopoverWindowResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === popover?.contentViewController?.view.window
        else { return }
        keepPopoverInsideVisibleFrame(on: popoverAnchorScreen)
    }

    private func keepPopoverInsideVisibleFrame(on screen: NSScreen?) {
        guard let window = popover?.contentViewController?.view.window,
              let visibleFrame = screen?.visibleFrame ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else { return }

        var frame = window.frame
        let maxHeight = max(320, visibleFrame.height - popoverScreenMargin * 2)
        if frame.height > maxHeight {
            frame.size.height = maxHeight
        }

        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX + popoverScreenMargin),
            visibleFrame.maxX - frame.width - popoverScreenMargin
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY + popoverScreenMargin),
            visibleFrame.maxY - frame.height - popoverScreenMargin
        )
        window.setFrame(frame, display: true)
    }

    // MARK: - Awake toggle

    private func handleToggleAwake(_ enabled: Bool) {
        state.keepAwake = enabled
        if enabled {
            keepAwakeManager.start(mode: state.mode, duration: state.duration)
        } else {
            keepAwakeManager.stop()
        }
        // 立即更新剩余时间显示
        state.awakeRemaining = keepAwakeManager.remaining
    }

    // MARK: - Refresh

    private func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let now = Date()

        Task.detached(priority: .utility) {
            let sys = SystemMonitor.sample()
            let claude = ClaudeUsageParser.summarize(now: now)
            let codex = CodexUsageParser.summarize(now: now)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard generation == self.refreshGeneration else { return }
                self.state.system = sys
                self.state.claude = claude
                self.state.codex = codex
                self.state.lastUpdated = Date()
                self.state.awakeRemaining = self.keepAwakeManager.remaining
            }
        }
    }
}

// MARK: - Debug dump (核对数据用：KeepVibe --dump)

if CommandLine.arguments.contains("--dump") {
    let now = Date()
    func fmt(_ u: AgentUsage) -> String {
        let w = u.window.map { "5h窗口 tokens=\($0.tokens) tok/min=\(Int($0.tokensPerMin)) resetIn=\(Int($0.resetIn ?? 0))s used=\(String(format: "%.2f", $0.usedFraction))" } ?? "(无窗口)"
        return """
          今日: \(u.todayTokens) tok  $\(String(format: "%.2f", u.todayCost))
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
    print(fmt(ClaudeUsageParser.summarize(now: now)))
    print("=== Codex ===")
    print(fmt(CodexUsageParser.summarize(now: now)))
    exit(0)
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
