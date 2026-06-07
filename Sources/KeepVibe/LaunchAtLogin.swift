import Foundation

enum LaunchAtLogin {
    private static let label = "com.keepvibe.launcher"
    private static let plistName = "\(label).plist"

    private static var plistURL: URL {
        let launchAgentsDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        return launchAgentsDir.appendingPathComponent(plistName)
    }

    /// plist 文件是否存在即视为已启用
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 写入或删除 LaunchAgent plist，并通过 launchctl 加载/卸载
    static func set(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    // MARK: - Private helpers

    private static var executablePath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: raw).standardized.path
    }

    private static func install() {
        let url = plistURL

        // 确保 ~/Library/LaunchAgents 目录存在
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else { return }

        try? data.write(to: url, options: .atomic)

        // launchctl load -w <plist>
        run("/bin/launchctl", args: ["load", "-w", url.path])
    }

    private static func uninstall() {
        let url = plistURL

        // 先 unload，文件可能不存在时静默忽略
        run("/bin/launchctl", args: ["unload", "-w", url.path])

        try? FileManager.default.removeItem(at: url)
    }

    /// 同步执行外部命令，失败静默
    private static func run(_ command: String, args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
