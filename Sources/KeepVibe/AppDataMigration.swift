import Foundation

/// 安装包版本变更时清理「今日」用量缓存，保留历史扫描结果。
enum AppDataMigration {
    private static let installedBuildKey = "keepVibe.installedBuild"
    private static let bundledAppIdentifier = "com.keepvibe.macos"

    private static let pythonScanCacheName = "_tokei_scan_cache.json"
    private static let pythonQuotaCacheName = "_tokei_claude_quota.json"
    private static let pythonScanToolKeys = [
        "claude", "codex", "qoder", "hermes", "openclaw", "opencode",
    ]

    static var usageCacheURL: URL {
        UsageLogRoots.default.cacheFile
    }

    static func currentBuildToken() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version).\(build)"
    }

    /// 仅对已安装的 .app 生效；`swift run` 不会每次启动清缓存。
    static func migrateIfNeeded(now: Date = Date()) {
        guard Bundle.main.bundleIdentifier == bundledAppIdentifier else { return }

        let current = currentBuildToken()
        let previous = UserDefaults.standard.string(forKey: installedBuildKey)
        guard previous != current else { return }

        clearTodayUsageCaches(now: now)
        UserDefaults.standard.set(current, forKey: installedBuildKey)
    }

    /// 只失效今日数据：Swift 日志缓存剔除今日事件；Python 扫描缓存剔除今日分桶。
    static func clearTodayUsageCaches(now: Date = Date()) {
        UsageLogScanner.purgeTodayFromCache(now: now)
        purgeTodayPythonScanCache(now: now)
        clearQuotaFallbackCache()
    }

    private static func todayDateKey(now: Date) -> String {
        let day = Calendar.current.startOfDay(for: now)
        return String(format: "%04d-%02d-%02d",
                      Calendar.current.component(.year, from: day),
                      Calendar.current.component(.month, from: day),
                      Calendar.current.component(.day, from: day))
    }

    private static func purgeTodayPythonScanCache(now: Date) {
        let todayKey = todayDateKey(now: now)

        for dir in tempDirectories() {
            let url = dir.appendingPathComponent(pythonScanCacheName)
            guard var root = loadJSONObject(at: url) as? [String: Any] else { continue }

            var touched = false
            for toolKey in pythonScanToolKeys {
                guard var tool = root[toolKey] as? [String: [String: Any]] else { continue }
                for (path, var entry) in tool {
                    var entryTouched = false
                    if var days = entry["days"] as? [String: Any], days.removeValue(forKey: todayKey) != nil {
                        entry["days"] = days
                        entryTouched = true
                    }
                    if entryTouched, entry["sig"] != nil {
                        entry["sig"] = ""
                    }
                    if entryTouched {
                        tool[path] = entry
                        touched = true
                    }
                }
                root[toolKey] = tool
            }

            if touched {
                writeJSONObject(root, to: url)
            }
        }
    }

    /// 5h/7d 配额回退缓存，不含历史用量。
    private static func clearQuotaFallbackCache() {
        for dir in tempDirectories() {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(pythonQuotaCacheName))
        }
    }

    private static func loadJSONObject(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func writeJSONObject(_ object: Any, to url: URL) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func tempDirectories() -> [URL] {
        var dirs = [FileManager.default.temporaryDirectory]
        let envTmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if !dirs.contains(envTmp) {
            dirs.append(envTmp)
        }
        return dirs
    }
}
