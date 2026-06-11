import Foundation

/// 纯逻辑：根据 resetAt 与已提醒 key 决定哪些目标到期、下次何时触发。
enum ResetReminderPlanner {
    struct Target: Equatable {
        var key: String
        var resetAt: Date
    }

    static func dueTargets(_ targets: [Target], firedKeys: Set<String>, now: Date) -> [Target] {
        targets.filter { $0.resetAt <= now && !firedKeys.contains($0.key) }
    }

    static func nextFireDate(_ targets: [Target], firedKeys: Set<String>, now: Date) -> Date? {
        targets
            .filter { $0.resetAt > now && !firedKeys.contains($0.key) }
            .map(\.resetAt)
            .min()
    }

    /// resetAt 已跳到下一窗口，但上一窗口到期时未提醒（定时器错过 / 休眠后 refresh 更新了 resetAt）。
    static func missedTarget(
        kind: String,
        previousResetAt: Date,
        currentResetAt: Date,
        now: Date
    ) -> Target? {
        guard previousResetAt <= now,
              Int(previousResetAt.timeIntervalSince1970) != Int(currentResetAt.timeIntervalSince1970)
        else { return nil }
        let key = "\(kind):\(Int(previousResetAt.timeIntervalSince1970))"
        return Target(key: key, resetAt: previousResetAt)
    }
}

enum ResetReminderStorage {
    private static let firedKeysKey = "resetReminder.firedKeys"

    private static func lastResetAtKey(kind: ToolKind) -> String {
        "resetReminder.lastResetAt.\(kind.rawValue)"
    }

    static func loadFiredKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: firedKeysKey) ?? [])
    }

    static func saveFiredKeys(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: firedKeysKey)
    }

    static func loadLastResetAt(kind: ToolKind) -> Date? {
        let ts = UserDefaults.standard.double(forKey: lastResetAtKey(kind: kind))
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    static func saveLastResetAt(kind: ToolKind, date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastResetAtKey(kind: kind))
    }
}
