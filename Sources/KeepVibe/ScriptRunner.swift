import Foundation

// MARK: - 外部工具用量数据结构

/// 单个时间范围（今日/本周/本月/今年）的用量统计。
/// JSON 字段使用简写：in / out / cost / sessions。
struct ExternalToolRange: Decodable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cost: Double
    var sessions: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "in"
        case outputTokens = "out"
        case tokens
        case cost
        case sessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tokenOnly = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? tokenOnly
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
    }
}

/// 单个外部工具的四个时间维度统计。任意维度都可能缺省。
struct ExternalToolStat: Decodable, Sendable {
    var today: ExternalToolRange?
    var week: ExternalToolRange?
    var month: ExternalToolRange?
    var year: ExternalToolRange?

    enum CodingKeys: String, CodingKey {
        case ranges
        case today
        case week
        case month
        case year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let ranges = try c.decodeIfPresent(Ranges.self, forKey: .ranges) {
            today = ranges.today
            week = ranges.week
            month = ranges.month
            year = ranges.year
        } else {
            today = try c.decodeIfPresent(ExternalToolRange.self, forKey: .today)
            week = try c.decodeIfPresent(ExternalToolRange.self, forKey: .week)
            month = try c.decodeIfPresent(ExternalToolRange.self, forKey: .month)
            year = try c.decodeIfPresent(ExternalToolRange.self, forKey: .year)
        }
    }

    private struct Ranges: Decodable {
        var today: ExternalToolRange?
        var week: ExternalToolRange?
        var month: ExternalToolRange?
        var year: ExternalToolRange?
    }
}

/// Claude 周配额（q7 = 已用百分比，q7_reset = Unix epoch 重置时间）。
struct ExternalClaudeQuota: Decodable, Sendable {
    var q7: Double?
    var q7_reset: Int?
}

/// Codex 周配额（pw = 已用百分比，rw = Unix epoch 重置时间）。
struct ExternalCodexQuota: Decodable, Sendable {
    var p5: Double?
    var pw: Double?
    var r5: Int?
    var rw: Int?
    var plan: String?
}

/// 外部 AI 工具用量汇总。由 Python 脚本 usage.py --json 输出后解析得到。
struct ExternalUsage: Decodable, Sendable {
    var claude: ExternalClaudeQuota?
    var codex: ExternalCodexQuota?
    var gemini: ExternalToolStat?
    var grok: ExternalToolStat?
    var aider: ExternalToolStat?
    var openclaw: ExternalToolStat?
    var opencode: ExternalToolStat?
    var qoder: ExternalToolStat?
}

// MARK: - 脚本执行器

/// 执行外部 Python 脚本 usage.py 以采集 Gemini / Grok / Aider / OpenClaw / OpenCode / Qoder 的用量。
///
/// 脚本解析全程在后台线程进行，完成后切回主线程回调；任何错误（python3 不可用、脚本不存在、
/// 超时、JSON 解析失败）都不会抛异常，统一以 `completion(nil)` 返回并在 stderr 留下诊断信息。
enum ScriptRunner {

    /// python3 脚本执行超时时间（秒）。
    private static let timeoutSeconds: TimeInterval = 8

    /// 在后台线程执行 `python3 <脚本路径> --json`，解析结果后在主线程回调。
    /// - Parameter completion: 主线程回调；解析成功返回 `ExternalUsage`，否则返回 `nil`。
    static func load(completion: @escaping @Sendable (ExternalUsage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let usage = runScript()
            DispatchQueue.main.async {
                completion(usage)
            }
        }
    }

    /// `load` 的 async 封装，供 `async let` 并行调用。
    static func loadAsync() async -> ExternalUsage? {
        await withCheckedContinuation { cont in
            load { cont.resume(returning: $0) }
        }
    }

    // MARK: - Private

    /// 同步执行脚本并解析；必须在后台线程调用。
    private static func runScript() -> ExternalUsage? {
        guard let python = pythonExecutableURL() else {
            FileHandle.standardError.log("ScriptRunner: 未找到可用的 python3")
            return nil
        }
        guard let script = scriptURL() else {
            FileHandle.standardError.log("ScriptRunner: 未找到 usage.py 脚本")
            return nil
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--json"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            FileHandle.standardError.log("ScriptRunner: 启动 python3 失败: \(error)")
            return nil
        }

        // 在超时时间内等待；超时则强制终止进程。
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                // 给进程一点时间响应 SIGTERM，仍存活则不再等待。
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning {
                    FileHandle.standardError.log("ScriptRunner: usage.py 执行超时（\(Int(timeoutSeconds))s），已终止")
                }
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // 读取标准错误用于诊断（不影响解析流程）。
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !errData.isEmpty, let errText = String(data: errData, encoding: .utf8) {
            let trimmed = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                FileHandle.standardError.log("ScriptRunner: usage.py stderr: \(trimmed)")
            }
        }

        guard process.terminationStatus == 0 else {
            FileHandle.standardError.log("ScriptRunner: usage.py 退出码非零: \(process.terminationStatus)")
            return nil
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !outData.isEmpty else {
            FileHandle.standardError.log("ScriptRunner: usage.py 无输出")
            return nil
        }

        do {
            return try JSONDecoder().decode(ExternalUsage.self, from: outData)
        } catch {
            FileHandle.standardError.log("ScriptRunner: JSON 解析失败: \(error)")
            return nil
        }
    }

    /// 定位 usage.py：先查 ~/.keepvibe/usage.py，再查 app bundle 的 Resources/usage.py。
    private static func scriptURL() -> URL? {
        let fm = FileManager.default

        let homeScript = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".keepvibe/usage.py")
        if fm.fileExists(atPath: homeScript.path) {
            return homeScript
        }

        for bundle in [Bundle.main, Bundle.module] {
            if let bundled = bundle.url(forResource: "usage", withExtension: "py"),
               fm.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        return nil
    }

    /// 在常见路径中定位 python3 可执行文件。
    private static func pythonExecutableURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

// MARK: - 诊断辅助

private extension FileHandle {
    /// 向句柄写入一行 UTF-8 文本（用于 stderr 诊断）。
    func log(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        write(data)
    }
}
