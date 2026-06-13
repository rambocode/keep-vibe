import XCTest
@testable import KeepVibe

/// 价格回归：锁定 Claude 计价与 Anthropic 官方 per-million 定价一致。
/// 历史 bug：Swift 价格表与官方 / usage.py 脱节（Opus 误为 $15/$75 旧价），且无测试守护，
/// 导致 Dashboard 的 Claude「≈成本」对 Opus 长期偏高约 3 倍。此处用官方价独立手算对账。
final class PricingTests: XCTestCase {

    // 各项取 100 万 token，成本数值即“每百万单价之和”，便于与官方价直接手算对账。
    private let oneM = 1_000_000

    func testClaudeOpusCostMatchesOfficialPricing() {
        // 官方：input $5 / output $25 / cacheWrite $6.25 / cacheRead $0.5（每百万）
        let cost = Pricing.claudeCost(model: "claude-opus-4-8",
                                      input: oneM, output: oneM, cacheWrite: oneM, cacheRead: oneM)
        XCTAssertEqual(cost, 5 + 25 + 6.25 + 0.5, accuracy: 1e-6)   // = 36.75
    }

    func testClaudeOpusOutputIsNotLegacyRate() {
        // 防回归：Opus 输出价应为 $25/M（曾误为 $75/M，使成本约 3×）
        let outOnly = Pricing.claudeCost(model: "claude-opus-4-8",
                                         input: 0, output: oneM, cacheWrite: 0, cacheRead: 0)
        XCTAssertEqual(outOnly, 25, accuracy: 1e-6)
    }

    func testClaudeSonnetCostMatchesOfficialPricing() {
        // 官方：input $3 / output $15 / cacheWrite $3.75 / cacheRead $0.3
        let cost = Pricing.claudeCost(model: "claude-sonnet-4-6",
                                      input: oneM, output: oneM, cacheWrite: oneM, cacheRead: oneM)
        XCTAssertEqual(cost, 3 + 15 + 3.75 + 0.3, accuracy: 1e-6)   // = 22.05
    }

    func testClaudeHaikuCostMatchesOfficialPricing() {
        // 官方：input $1 / output $5 / cacheWrite $1.25 / cacheRead $0.1
        let cost = Pricing.claudeCost(model: "claude-haiku-4-5",
                                      input: oneM, output: oneM, cacheWrite: oneM, cacheRead: oneM)
        XCTAssertEqual(cost, 1 + 5 + 1.25 + 0.1, accuracy: 1e-6)    // = 7.35
    }

    func testUnknownModelFallsBackToSonnet() {
        // 无法识别的 model 名按 sonnet 兜底（与 Pricing 注释一致）
        let cost = Pricing.claudeCost(model: "claude-mystery-9",
                                      input: oneM, output: oneM, cacheWrite: oneM, cacheRead: oneM)
        XCTAssertEqual(cost, 3 + 15 + 3.75 + 0.3, accuracy: 1e-6)
    }
}
