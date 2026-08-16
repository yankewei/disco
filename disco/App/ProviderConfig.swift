import Foundation

// MARK: - 模型服务商

/// 支持的模型服务商。`isAvailable` 为 false 的服务商仅展示占位（即将推出）。
enum ProviderVendor: String, CaseIterable, Identifiable {
    case deepseek
    case openai
    case moonshot
    case kimiCode
    case zhipu
    case chatgpt
    case anthropic
    case gemini

    var id: String { rawValue }

    /// 迁移期 DAP 使用的 Rust Vendor wire value。
    var daemonVendor: String {
        switch self {
        case .deepseek: "deepseek"
        case .openai: "openai"
        case .moonshot: "moonshot_kimi"
        case .kimiCode: "kimi_code"
        case .zhipu: "glm"
        case .chatgpt: "codex"
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        }
    }

    /// 会话创建后固定使用的 daemon Provider profile。
    var daemonProviderID: String {
        switch self {
        case .openai: "codex_api"
        case .chatgpt: "codex_app_server"
        default: "\(daemonVendor)_api"
        }
    }

    var title: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openai: "OpenAI"
        case .moonshot: "Moonshot Kimi"
        case .kimiCode: "Kimi Code"
        case .zhipu: "智谱 GLM"
        case .chatgpt: "Codex (OpenAI)"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        }
    }

    var subtitle: String {
        switch self {
        case .deepseek: "深度求索 DeepSeek API，兼容 OpenAI 接口"
        case .openai: "OpenAI 官方 API"
        case .moonshot: "月之暗面 Kimi API，兼容 OpenAI 接口"
        case .kimiCode: "Kimi Code 订阅 API，使用 Chat Completions 接口"
        case .zhipu: "智谱清言 GLM API，兼容 OpenAI 接口"
        case .chatgpt: "使用 Codex (OpenAI) 订阅额度（codex app-server）"
        case .anthropic: "Anthropic 官方 Claude API"
        case .gemini: "Google Gemini API"
        }
    }

    var icon: String {
        switch self {
        case .deepseek: "wave.3.right"
        case .openai: "circle.hexagongrid.fill"
        case .moonshot: "moon.stars.fill"
        case .kimiCode: "chevron.left.forwardslash.chevron.right"
        case .zhipu: "brain.head.profile"
        case .chatgpt: "bubble.left.and.bubble.right.fill"
        case .anthropic: "rays"
        case .gemini: "sparkles"
        }
    }

    /// 品牌 logo 资源名（Assets.xcassets/BrandIcons）；为 nil 时 UI 回退到 SF Symbol
    var brandIcon: String? {
        switch self {
        case .deepseek: "brand.deepseek"
        case .kimiCode: "brand.kimiCode"
        case .chatgpt: "brand.codex"
        default: nil
        }
    }

    /// 选择该服务商时自动填入的默认 Base URL
    var defaultBaseURL: String {
        switch self {
        case .deepseek: "https://api.deepseek.com/v1"
        case .openai: "https://api.openai.com/v1"
        case .moonshot: "https://api.moonshot.cn/v1"
        case .kimiCode: "https://api.kimi.com/coding/v1"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .chatgpt: ""
        case .anthropic: ""
        case .gemini: ""
        }
    }

    /// 是否需要 API Key。false 表示订阅登录类服务商（ChatGPT/Codex），
    /// 登录态由 codex CLI 管理（ADR-003：应用不读取 ~/.codex/auth.json）。
    var requiresAPIKey: Bool {
        switch self {
        case .chatgpt: false
        default: true
        }
    }

    /// 当前是否已实现接入（OpenAI 兼容接口与 ChatGPT 订阅已可用，其余待实现）
    var isAvailable: Bool {
        switch self {
        case .deepseek, .openai, .moonshot, .kimiCode, .zhipu, .chatgpt: true
        case .anthropic, .gemini: false
        }
    }

    /// 该服务商在当前统一请求体中可用的推理档位，顺序即为 UI 展示顺序。
    var supportedReasoningEfforts: [String] {
        switch self {
        case .deepseek: ["none", "low", "high", "max"]
        case .kimiCode: ["none", "low", "high", "max"]
        case .openai, .moonshot, .zhipu: ["none", "high"]
        default: []
        }
    }

    /// 当前模型可使用的供应商托管工具。能力判断集中在服务商层，
    /// Provider/Runtime 只消费统一的 HostedToolKind。
    func hostedTools(for model: String) -> Set<HostedToolKind> {
        switch self {
        case .deepseek where model.lowercased() == "deepseek-v4-flash":
            [.webSearch]
        case .openai:
            [.webSearch]
        default:
            []
        }
    }

    /// 当前客户端已知的模型上下文上限。未知模型返回 nil，避免把估算值伪装成服务端能力。
    func contextWindow(for model: String) -> Int? {
        let normalizedModel = model.lowercased()
        switch self {
        case .deepseek where normalizedModel.contains("deepseek-v4"):
            return 1_000_000
        case .kimiCode where normalizedModel == "kimi-for-coding":
            return 262_144
        default:
            return nil
        }
    }

    /// 用客户端已知的服务商能力补齐目录中未声明的字段；服务端显式值始终优先。
    func enrichingCatalogEntry(_ entry: ModelCatalogEntry) -> ModelCatalogEntry {
        let reasoningEfforts = supportedReasoningEfforts
        return ModelCatalogEntry(
            id: entry.id,
            displayName: entry.displayName,
            contextWindow: entry.contextWindow ?? contextWindow(for: entry.id),
            supportedReasoningEfforts: entry.supportedReasoningEfforts
                ?? (reasoningEfforts.isEmpty ? nil : reasoningEfforts),
            defaultReasoningEffort: entry.defaultReasoningEffort,
            hostedTools: entry.hostedTools ?? hostedTools(for: entry.id),
            supportsToolCalling: entry.supportsToolCalling
        )
    }

    static func reasoningEffortTitle(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none": "关闭"
        case "minimal": "极低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "极高"
        case "max": "最高"
        default: effort
        }
    }

    /// 该服务商 API Key 在 auth 文件中使用的 account
    var keychainAccount: String {
        "\(rawValue)-api-key"
    }

    /// 该服务商配置在 UserDefaults 中的 key
    var baseURLDefaultsKey: String { "provider.\(rawValue).baseURL" }
    var modelDefaultsKey: String { "provider.\(rawValue).model" }
    var modelCatalogDefaultsKey: String { "provider.\(rawValue).modelCatalog" }
    /// 旧版分散模型目录键，仅用于启动迁移和配置清理。
    var modelsDefaultsKey: String { "provider.\(rawValue).models" }
    var thinkingEnabledDefaultsKey: String { "provider.\(rawValue).thinkingEnabled" }
    var modelReasoningCapabilitiesDefaultsKey: String {
        "provider.\(rawValue).modelReasoningCapabilities"
    }
    var modelContextWindowsDefaultsKey: String {
        "provider.\(rawValue).modelContextWindows"
    }
    /// 用户按模型填写的上下文窗口覆盖值，独立于服务端模型目录缓存。
    var contextWindowOverridesDefaultsKey: String {
        "provider.\(rawValue).contextWindowOverrides"
    }
    var reasoningEffortDefaultsKey: String {
        "provider.\(rawValue).reasoningEffort"
    }
    /// 最近一次验证通过的时间（timeIntervalSince1970）
    var verifiedAtDefaultsKey: String { "provider.\(rawValue).verifiedAt" }

    /// 判断该服务商是否已经具备可用配置。
    /// API Key 服务商需要 Key 和模型；订阅服务商不需要 Key，模型和验证记录即可。
    func isConfigured(_ config: ProviderConfig?) -> Bool {
        guard let config else { return false }
        if requiresAPIKey {
            return config.hasAPIKey && !config.model.isEmpty
        }
        return !config.model.isEmpty && config.lastVerifiedAt != nil
    }
}

// MARK: - 服务商配置

/// 单个服务商的持久化配置。API Key 本身不进内存，存放在 Application Support 目录下的 auth.json（按服务商隔离）。
struct ProviderConfig: Equatable {
    var baseURL: String
    var model: String
    var hasAPIKey: Bool
    /// 最近一次从服务端加载并由 Adapter 补齐的统一模型目录。
    var modelCatalog: [ModelCatalogEntry]
    /// 该服务商是否开启思考模式（reasoning）
    var thinkingEnabled: Bool
    /// Codex 当前选中的推理档位；nil 表示使用 app-server 的模型默认值。
    var reasoningEffort: String? = nil
    /// 最近一次连接验证通过的时间；nil 表示从未验证（保存配置即视为验证通过）
    var lastVerifiedAt: Date? = nil

    /// 供只需要 ID 列表的设置页和模型切换 UI 使用。
    var models: [String] { modelCatalog.map(\.id) }

    func catalogEntry(for modelID: String) -> ModelCatalogEntry? {
        modelCatalog.first { $0.id == modelID }
    }
}

/// 旧版单服务商配置使用的 account 与 UserDefaults key（用于迁移）
enum LegacyProviderKeys {
    static let keychainAccount = "openai-platform-api-key"
    static let baseURL = "apiBaseURL"
    static let model = "apiModel"
    static let activeVendor = "activeProvider"
    /// 旧版全局思考模式开关（迁移到按服务商后移除）
    static let thinkingEnabled = "thinkingEnabled"
}
