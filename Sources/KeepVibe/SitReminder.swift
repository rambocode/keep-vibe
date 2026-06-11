import AppKit
import IOKit
import SwiftUI

// 久坐提醒：基于系统空闲时间(HIDIdleTime)判断连续用机时长。
// 连续用机达到设定间隔后提醒；空闲达到离开阈值后清零。
@MainActor
final class SitReminder {
    nonisolated static let enabledKey = "sitReminderOn"
    nonisolated static let intervalKey = "sitReminderInterval"
    nonisolated static let defaultIntervalMinutes = 90
    nonisolated static let awayThresholdSeconds: TimeInterval = 300

    private var timer: Timer?
    private var workStart: Date?
    private let idleSecondsProvider: @MainActor () -> TimeInterval
    private let nowProvider: @MainActor () -> Date
    private let notify: @MainActor (String) -> Void

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var intervalMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: Self.intervalKey)
        return value == 0 ? Self.defaultIntervalMinutes : value
    }

    init(
        idleSecondsProvider: @escaping @MainActor () -> TimeInterval = SitReminder.idleSeconds,
        nowProvider: @escaping @MainActor () -> Date = Date.init,
        notify: @escaping @MainActor (String) -> Void = { body in
            ReminderHUD.show(title: "久坐提醒", body: body)
        }
    ) {
        self.idleSecondsProvider = idleSecondsProvider
        self.nowProvider = nowProvider
        self.notify = notify
    }

    func updateRunning() {
        enabled ? start() : stop()
    }

    func start() {
        stop()
        workStart = nowProvider()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        workStart = nil
    }

    func testPing() {
        notify("测试提醒：久坐提醒已就绪")
    }

    @discardableResult
    func tick() -> Bool {
        let now = nowProvider()
        let idle = idleSecondsProvider()
        if idle >= Self.awayThresholdSeconds {
            workStart = nil
            return false
        }

        guard let startedAt = workStart else {
            workStart = now
            return false
        }

        guard now.timeIntervalSince(startedAt) >= TimeInterval(intervalMinutes * 60) else {
            return false
        }

        notify("已连续用机 \(intervalMinutes) 分钟，起来活动一下")
        workStart = now
        return true
    }

    static func idleSeconds() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        ) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let nanoseconds = dictionary["HIDIdleTime"] as? UInt64
        else {
            return 0
        }
        return TimeInterval(nanoseconds) / 1_000_000_000
    }
}

@MainActor
enum ReminderHUD {
    private static var panel: NSPanel?

    static func show(title: String, body: String, requiresManualDismiss: Bool = false) {
        panel?.close()

        let width: CGFloat = 320
        let height: CGFloat = 80
        let host = NSHostingView(rootView: ReminderHUDView(
            title: title,
            message: body,
            requiresManualDismiss: requiresManualDismiss,
            onClose: { dismissCurrent() }
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let nextPanel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        nextPanel.isOpaque = false
        nextPanel.backgroundColor = .clear
        nextPanel.hasShadow = true
        nextPanel.level = .statusBar
        nextPanel.contentView = host

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            nextPanel.setFrameOrigin(NSPoint(x: frame.maxX - width - 16, y: frame.maxY - height - 16))
        }

        nextPanel.alphaValue = 0
        nextPanel.orderFrontRegardless()
        panel = nextPanel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            nextPanel.animator().alphaValue = 1
        }

        if !requiresManualDismiss {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                dismiss(nextPanel)
            }
        }
    }

    private static func dismissCurrent() {
        guard let panel else { return }
        dismiss(panel)
    }

    private static func dismiss(_ panelToClose: NSPanel) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            panelToClose.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panelToClose.close()
                if panel === panelToClose {
                    panel = nil
                }
            }
        })
    }
}

struct ReminderHUDView: View {
    let title: String
    let message: String
    let requiresManualDismiss: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.claude, Theme.claude.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "figure.walk")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.tPrimary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if requiresManualDismiss {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.tSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("关闭提醒")
            }
        }
        .padding(12)
        .frame(width: 320, height: 80, alignment: .leading)
        .background(VisualEffect())
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.claude.opacity(0.3), lineWidth: 0.75)
        )
        // 跟随用户主题偏好（默认跟随系统）
        .modifier(ThemeColorSchemeModifier())
    }
}

private struct ThemeColorSchemeModifier: ViewModifier {
    @AppStorage(ThemePreference.storageKey) private var themeRaw = ThemePreference.system.rawValue
    private var theme: ThemePreference { ThemePreference(rawValue: themeRaw) ?? .system }
    func body(content: Content) -> some View {
        Group {
            if let scheme = theme.colorScheme {
                content.environment(\.colorScheme, scheme)
            } else {
                content
            }
        }
    }
}
