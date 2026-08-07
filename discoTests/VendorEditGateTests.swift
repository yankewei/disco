import XCTest
@testable import disco

/// VendorEditGate 纯逻辑测试：验证“验证通过后可选择模型”的门控不产生死锁，
/// 且输入改动后指纹自动失效、必须重新验证。
final class VendorEditGateTests: XCTestCase {
    private func makeGate(
        savedBaseURL: String? = nil,
        draftBaseURL: String = "",
        draftAPIKey: String = "",
        hasLoadedModels: Bool = true,
        verifiedFingerprint: CredentialFingerprint? = nil
    ) -> VendorEditGate {
        VendorEditGate(
            savedBaseURL: savedBaseURL,
            draftBaseURL: draftBaseURL,
            draftAPIKey: draftAPIKey,
            hasLoadedModels: hasLoadedModels,
            verifiedFingerprint: verifiedFingerprint
        )
    }

    func testNewVendorRequiresVerificationBeforeModelSelection() {
        var gate = makeGate(draftBaseURL: "https://api.deepseek.com/v1", draftAPIKey: "sk-1")
        XCTAssertFalse(gate.canSelectModel)

        // 验证通过（记录指纹）后解锁——修复“验证成功但模型列表仍禁用”的死锁
        gate.verifiedFingerprint = gate.currentFingerprint
        XCTAssertTrue(gate.canSelectModel)
    }

    func testVerificationFingerprintTracksInputChanges() {
        var gate = makeGate(draftBaseURL: "https://api.deepseek.com/v1", draftAPIKey: "sk-1")
        gate.verifiedFingerprint = gate.currentFingerprint
        XCTAssertTrue(gate.canSelectModel)

        // 改动 Key 后指纹失效，必须重新验证
        gate.draftAPIKey = "sk-2"
        XCTAssertFalse(gate.canSelectModel)

        // 改动 Base URL 后同样失效
        gate.draftAPIKey = "sk-1"
        gate.draftBaseURL = "https://api.deepseek.com"
        XCTAssertFalse(gate.canSelectModel)
    }

    func testKeyReplacementOnConfiguredVendorRequiresVerification() {
        var gate = makeGate(
            savedBaseURL: "https://api.deepseek.com/v1",
            draftBaseURL: "https://api.deepseek.com/v1"
        )
        XCTAssertTrue(gate.canSelectModel)

        // 输入新 Key 后必须验证才能保存（修复“新 Key 永远无法保存”的问题）
        gate.draftAPIKey = "sk-new"
        XCTAssertFalse(gate.canSelectModel)

        gate.verifiedFingerprint = gate.currentFingerprint
        XCTAssertTrue(gate.canSelectModel)
    }

    func testSavedConfigUnchangedAllowsDirectSelection() {
        let gate = makeGate(
            savedBaseURL: "https://api.deepseek.com/v1",
            draftBaseURL: "https://api.deepseek.com/v1"
        )
        XCTAssertTrue(gate.canSelectModel)
    }

    func testBaseURLComparisonIgnoresTrailingSlash() {
        // 保存时配置会被归一化（去尾部斜杠）；草稿带斜杠不应被误判为“已修改”
        let gate = makeGate(
            savedBaseURL: "https://api.deepseek.com/v1",
            draftBaseURL: "https://api.deepseek.com/v1/"
        )
        XCTAssertTrue(gate.canSelectModel)
    }

    func testModelsNotLoadedLocksSelection() {
        let gate = makeGate(
            draftBaseURL: "https://api.deepseek.com/v1",
            draftAPIKey: "sk-1",
            hasLoadedModels: false
        )
        XCTAssertFalse(gate.canSelectModel)
    }

    func testWhitespaceAroundAPIKeyIsIgnoredInFingerprint() {
        var gate = makeGate(draftBaseURL: "https://api.deepseek.com/v1", draftAPIKey: "  sk-1  ")
        gate.verifiedFingerprint = gate.currentFingerprint
        XCTAssertTrue(gate.canSelectModel)

        // 尾随空格不改变指纹，仍视为已验证
        gate.draftAPIKey = "sk-1"
        XCTAssertTrue(gate.canSelectModel)
    }
}
