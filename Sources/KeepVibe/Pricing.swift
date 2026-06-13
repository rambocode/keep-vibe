import Foundation

// 每百万 token 价格
enum Pricing {
    /// Claude：根据 model 名包含 opus/sonnet/haiku 选择费率（每百万 token，官方价）
    /// - opus:   input $5/M,  output $25/M, cacheWrite $6.25/M, cacheRead $0.50/M
    /// - sonnet: input $3/M,  output $15/M, cacheWrite $3.75/M, cacheRead $0.30/M
    /// - haiku:  input $1/M,  output $5/M,  cacheWrite $1.25/M, cacheRead $0.10/M
    /// cacheWrite 对应 cache_creation_input_tokens，cacheRead 对应 cache_read_input_tokens
    /// 规则：cacheWrite = 1.25×input，cacheRead = 0.1×input。与 usage.py:_DEFAULT_PRICES 一致。
    static func claudeCost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        let m = model.lowercased()

        let inRate: Double
        let outRate: Double
        let cacheWriteRate: Double
        let cacheReadRate: Double

        if m.contains("opus") {
            inRate = 5.0
            outRate = 25.0
            cacheWriteRate = 6.25
            cacheReadRate = 0.5
        } else if m.contains("haiku") {
            inRate = 1.0
            outRate = 5.0
            cacheWriteRate = 1.25
            cacheReadRate = 0.10
        } else {
            // 默认按 sonnet（含 "sonnet" 或无法识别的 model）
            inRate = 3.0
            outRate = 15.0
            cacheWriteRate = 3.75
            cacheReadRate = 0.30
        }

        let perM = 1_000_000.0
        return Double(input) / perM * inRate
             + Double(output) / perM * outRate
             + Double(cacheWrite) / perM * cacheWriteRate
             + Double(cacheRead) / perM * cacheReadRate
    }

    /// Codex：gpt-5-codex 近似费率
    /// - input（非缓存部分）= max(input - cachedInput, 0) × $1.25/M
    /// - cachedInput × $0.125/M
    /// - output（reasoning 计入 output）× $10/M
    static func codexCost(input: Int, cachedInput: Int, output: Int) -> Double {
        let nonCachedInput = max(input - cachedInput, 0)
        let perM = 1_000_000.0
        return Double(nonCachedInput) / perM * 1.25
             + Double(cachedInput) / perM * 0.125
             + Double(output) / perM * 10.0
    }
}
