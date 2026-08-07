import Foundation

// MARK: - 模型服务商

/// 支持的模型服务商。`isAvailable` 为 false 的服务商仅展示占位（即将推出）。
enum ProviderVendor: String, CaseIterable, Identifiable {
    case deepseek
    case openai
    case moonshot
    case zhipu
    case anthropic
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .openai: "OpenAI"
        case .moonshot: "Moonshot Kimi"
        case .zhipu: "智谱 GLM"
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
        case .anthropic: "rays"
        case .gemini: "sparkles"
        }
    }

    /// 品牌 logo 资源名（Assets.xcassets/BrandIcons）；为 nil 时 UI 回退到 SF Symbol
    var brandIcon: String? {
        switch self {
        case .deepseek: "brand.deepseek"
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
        case .anthropic: ""
        case .gemini: ""
        }
    }

    /// 当前是否已实现接入（OpenAI 兼容接口已可用，其余待实现）
    var isAvailable: Bool {
        switch self {
        case .deepseek, .openai, .moonshot, .zhipu: true
        case .anthropic, .gemini: false
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
    /// 最近一次验证通过的时间（timeIntervalSince1970）
    var verifiedAtDefaultsKey: String { "provider.\(rawValue).verifiedAt" }
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
    /// 最近一次连接验证通过的时间；nil 表示从未验证（保存配置即视为验证通过）
    var lastVerifiedAt: Date? = nil

    var isConfigured: Bool {
        hasAPIKey && !model.isEmpty && !baseURL.isEmpty
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
