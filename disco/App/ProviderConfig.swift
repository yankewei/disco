import Foundation

// MARK: - 模型服务商

/// 支持的模型服务商。`isAvailable` 为 false 的服务商仅展示占位（即将推出）。
enum ProviderVendor: String, CaseIterable, Identifiable {
    case deepseek
    case openai
    case moonshot
    case zhipu
    case chatgpt
    case anthropic
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openai: "OpenAI"
        case .moonshot: "Moonshot Kimi"
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
        case .deepseek, .openai, .moonshot, .zhipu, .chatgpt: true
        case .anthropic, .gemini: false
        }
    }

    /// 该服务商在当前统一请求体中可用的推理档位，顺序即为 UI 展示顺序。
    var supportedReasoningEfforts: [String] {
        switch self {
        case .deepseek: ["none", "low", "high", "max"]
        case .openai, .moonshot, .zhipu: ["none", "high"]
        default: []
        }
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
    var modelsDefaultsKey: String { "provider.\(rawValue).models" }
    var thinkingEnabledDefaultsKey: String { "provider.\(rawValue).thinkingEnabled" }
    var modelReasoningCapabilitiesDefaultsKey: String {
        "provider.\(rawValue).modelReasoningCapabilities"
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
    /// 该服务商最近一次从服务端加载的可用模型列表（供聊天页快速切换，不实时刷新）
    var models: [String]
    /// 该服务商是否开启思考模式（reasoning）
    var thinkingEnabled: Bool
    /// 最近一次 model/list 返回的模型推理能力；仅 Codex 当前使用，其他服务商为空。
    var modelReasoningCapabilities: [String: ModelReasoningCapability] = [:]
    /// Codex 当前选中的推理档位；nil 表示使用 app-server 的模型默认值。
    var reasoningEffort: String? = nil
    /// 最近一次连接验证通过的时间；nil 表示从未验证（保存配置即视为验证通过）
    var lastVerifiedAt: Date? = nil

}

/// 模型级推理能力。保留服务端原始字符串，便于 Codex 新增档位时无需升级客户端。
struct ModelReasoningCapability: Codable, Equatable, Sendable {
    let supportedEfforts: [String]
    let defaultEffort: String?
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
