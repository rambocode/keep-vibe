import Foundation
import IOKit.pwr_mgt

/// 管理系统防睡眠断言（Power Assertion）。
/// 所有方法均应在主线程调用；Timer 和 onExpire 回调也在主线程执行。
@MainActor
final class KeepAwakeManager {

    // MARK: - Private State

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var assertionActive: Bool = false
    private var timer: Timer? = nil
    private var expiresAt: Date? = nil

    // MARK: - Public Interface

    /// 当前是否持有活跃的电源断言
    var isActive: Bool { assertionActive }

    /// 定时模式下距离到期的剩余秒数；永久模式或未激活时返回 nil
    var remaining: TimeInterval? {
        guard assertionActive, let exp = expiresAt else { return nil }
        let r = exp.timeIntervalSinceNow
        return r > 0 ? r : 0
    }

    /// 定时到点后在主线程调用此闭包（由调用方设置）
    var onExpire: (() -> Void)? = nil

    // MARK: - Control

    /// 启动防睡眠断言。若已有旧断言则先释放。
    /// - Parameters:
    ///   - mode: `.standard` 防止用户空闲睡眠；`.clamshell` 合盖也不睡（注意：kIOPMAssertionTypePreventSystemSleep
    ///     仅在接通电源时对合盖生效，纯电池供电下系统仍可能在合盖后睡眠）。
    ///   - duration: `.forever` 永久持有；`.hours(n)` 持有指定小时数后自动释放。
    func start(mode: AwakeMode, duration: AwakeDuration) {
        // 先释放旧断言与计时器
        stop()

        // 根据模式选择断言类型
        let assertionType: CFString
        switch mode {
        case .standard:
            // 防止用户空闲触发的系统睡眠（屏幕仍可关闭）
            assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .clamshell:
            // 防止系统级睡眠，包括合盖场景。
            // 注意：此断言仅在接通电源时对合盖生效；
            // 纯电池供电下 macOS 会忽略该断言并在合盖后进入睡眠。
            assertionType = kIOPMAssertionTypePreventSystemSleep as CFString
        }

        let name = "KeepVibe - \(mode.rawValue)" as CFString
        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name,
            &newID
        )

        guard result == kIOReturnSuccess else {
            // 断言创建失败，静默返回（不激活状态）
            return
        }

        assertionID = newID
        assertionActive = true

        // 定时模式：设置 Timer 在到期时自动 stop 并回调
        if let seconds = duration.seconds {
            expiresAt = Date(timeIntervalSinceNow: seconds)
            let t = Timer.scheduledTimer(
                withTimeInterval: seconds,
                repeats: false
            ) { [weak self] _ in
                // Timer 在主 RunLoop 上触发（见下方 RunLoop.main.add），始终在主线程执行
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stop()
                    self.onExpire?()
                }
            }
            // 在 RunLoop 的 common 模式下运行，防止菜单等 UI 事件阻塞计时
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            // 永久模式
            expiresAt = nil
        }
    }

    /// 停止防睡眠断言，取消计时器，重置所有状态。
    func stop() {
        // 取消计时器
        timer?.invalidate()
        timer = nil
        expiresAt = nil

        // 释放 IOKit 电源断言
        if assertionActive {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
            assertionActive = false
        }
    }
}
