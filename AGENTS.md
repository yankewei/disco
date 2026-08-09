# AGENTS.md

本文件面向 AI 编程代理，介绍 disco 项目的架构、构建方式与开发约定。阅读前不需要任何项目背景知识。

## 项目概览

**disco** 是一款 macOS 原生应用，用 SwiftUI + AppKit 编写。当前形态是一个多模型 AI 聊天客户端，并已接入初步的 ChatGPT/Codex 订阅运行时：用户可以配置多家 OpenAI 兼容服务商（DeepSeek、OpenAI、Moonshot Kimi、Kimi Code、智谱 GLM）或复用本机 Codex 登录，然后在会话中流式对话，支持推理（reasoning）、token usage、上下文压缩展示与本地会话持久化。Kimi Code 当前接入的是 Chat Completions API，不是 Kimi CLI Agent。

项目的长期目标是演进为完整的多模型 coding agent。总体蓝图见仓库根目录的 `macos-multi-model-agent-plan.md`（中文，含 ADR-001~006 架构决策）。**当前代码仍属于聊天 MVP，但已实现 Project/Workspace 身份切片和 Codex Runtime 的第一段链路**：能选择并持久化可读目录、按 Project 分组会话、恢复 bookmark/不可用状态，也能启动 `codex app-server`、读取登录/模型信息、start/resume thread、start/interrupt turn，并映射文本、推理、usage、上下文压缩和终止事件；尚无把 workspace 传入 Codex 的 cwd/sandbox、命令与文件 item、审批、diff、Generic 工具循环或 Tool Host。`ChatMessage.Part.toolCall` 仍只是展示预留。

实现或修改 Project/Workspace、Agent 事件、Codex 协议、审批、diff、Generic 工具循环、Tool Host、运行持久化或 coding-agent UI 前，先阅读 `coding-agent-implementation-plan.md`，并以对应 Phase 的完成标准作为交付边界。上下文压缩当前行为和已知缺口记录在 `context-compaction-implementation-plan.md`；Kimi Code API/未来 ACP 的路线决策记录在 `kimi-code-integration-research.md`。

注意：蓝图与实现存在有意的取舍，例如蓝图建议 AsyncHTTPClient + Keychain，当前 MVP 使用 URLSession + 明文凭据文件（见下文"安全注意事项"）。以代码现状为准，蓝图中的章节引用（如 `计划 §8`、`ADR-001`）用于说明设计意图。

## 文档索引

- `macos-multi-model-agent-plan.md`：长期产品蓝图与 ADR-001～006。
- `coding-agent-implementation-plan.md`：coding agent 的阶段性实施路线和验收标准。
- `context-compaction-implementation-plan.md`：上下文压缩 v1 的当前实现记录、持久化契约和待补测试。
- `project-workspace-implementation-plan.md`：Project/Workspace 纵向切片的实现边界和验收标准。
- `kimi-code-integration-research.md`：Kimi Code API 当前决策与未来 ACP 接入边界。

## 技术栈

- **语言/平台**：Swift（`SWIFT_VERSION = 5.0` 语言模式），macOS only，`MACOSX_DEPLOYMENT_TARGET = 26.5`
- **UI**：SwiftUI + AppKit；`NavigationSplitView` 侧栏 + 聊天主视图
- **并发**：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`、`SWIFT_APPROACHABLE_CONCURRENCY = YES`；状态类（`AppState`、`ConversationStore`、`ConversationPersistence`）均为 `@MainActor`
- **网络**：`URLSession`（`session.bytes(for:)` 流式读取 + 手写 SSE 解析器）；未使用 AsyncHTTPClient
- **持久化**：SwiftData（会话/消息）；UserDefaults（服务商配置）；JSON 文件（API Key）
- **测试**：XCTest
- **SwiftPM 依赖**：`MarkdownView` 4.1.12（Markdown 渲染），间接依赖 Highlightr、swift-cmark、swift-collections、Litext、SwiftMath。首次构建需要网络克隆依赖

## 构建与测试

工程文件为 `disco.xcodeproj`（scheme 名 `disco`），无 Package.swift、无 Makefile。

```bash
# 运行全部测试（与 CI 一致）
xcodebuild test \
  -project disco.xcodeproj \
  -scheme disco \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

打开 Xcode 直接 `open disco.xcodeproj` 即可运行 App。

CI：`.github/workflows/ci.yml`，在 `macos-26` runner 上对每个 push/PR 执行上述测试命令。

## 代码组织

```text
disco/
├── App/                      # SwiftUI 界面与应用状态
│   ├── discoApp.swift        # @main 入口；测试环境下注入内存替身
│   ├── ContentView.swift     # NavigationSplitView + 会话侧栏
│   ├── ChatView.swift        # 聊天时间线、消息行、输入框
│   ├── SettingsView.swift    # 设置页：主从布局的服务商配置
│   ├── AppState.swift        # 根状态：服务商配置、会话列表、Runtime 装配
│   ├── ConversationSession.swift / ConversationStore.swift  # 单会话状态与发送循环
│   ├── ProviderConfig.swift  # ProviderVendor 枚举与服务商配置模型
│   └── DiscoTheme.swift      # 配色、圆角、动效常量
├── AgentDomain/              # 纯领域契约，不依赖 UI/网络
│   ├── ModelContract.swift   # ModelProvider 协议、ModelRequest、ModelEvent
│   ├── RuntimeContract.swift # AgentRuntime 协议、AgentRunRequest、AgentEvent
│   ├── ChatMessage.swift     # 消息模型（有序 parts：text / reasoning / toolCall）
│   └── Workspace.swift       # Project/Workspace 领域模型与目录解析
├── AgentRuntime/
│   ├── GenericAgentRuntime.swift       # 通用文本运行时：上下文压缩、ModelEvent → AgentEvent
│   ├── ContextCompactor.swift          # Generic checkpoint、摘要和 overflow recovery
│   ├── TokenEstimator.swift             # 本地 token 粗略估算
│   ├── CodexAppServerProtocol.swift    # codex-cli 0.147.0 的版本化 wire DTO
│   ├── CodexAppServerTransport.swift   # app-server 子进程、JSONL/JSON-RPC、usage/compact 路由
│   └── CodexRuntime.swift              # Codex 事件 → AgentEvent、取消、usage 与 thread 恢复
├── Providers/
│   ├── OpenAIResponsesProvider.swift         # OpenAI Responses API + 兼容服务商
│   └── OpenAIChatCompletionsProvider.swift   # Chat Completions API；当前用于 Kimi Code
├── Persistence/
│   ├── ConversationPersistence.swift  # SwiftData 的 Project/会话持久化 + 内存替身
│   └── AuthFileStore.swift            # API Key 存储（Application Support/disco/config/auth.json）+ 内存替身
└── Assets.xcassets/
discoTests/                   # XCTest 单元测试，@testable import disco
```

## 架构约定

- **Provider 与 Runtime 正交（ADR-001）**：`ModelProvider` 只做认证、请求构造、流式协议解析与错误转换，是无状态传输；模型、推理开关由 Runtime 按会话配置填入 `ModelRequest`。
- **统一事件，不统一原始协议（ADR-002）**：内部统一为 `ModelEvent` / `AgentEvent`，但保留 provider 私有的 DTO 与 SSE 解析。UI 层不接触 provider 具体错误类型，Runtime 在边界处翻译为 `AgentFailure`（用户可读的中文消息）。
- **终止事件保证**：一次运行恰好发射一个终止事件（`runCompleted` / `runFailed` / `runCancelled`），随后流结束。改动 Runtime 时必须维持该不变量。
- **Codex wire 与领域隔离**：`CodexAppServerTransport`/`CodexRuntime` 消化 JSON-RPC method、request ID、thread/turn/item ID、usage 和压缩生命周期；SwiftUI 不解析 Codex payload。协议 DTO 当前对应 `codex-cli 0.147.0`，升级 CLI 时先生成并 diff schema，再更新 DTO 与合约测试。
- **Codex 当前能力边界**：支持 thread/turn、文本、推理、终止、token usage 和上下文压缩；`handleServerRequest` 仍明确拒绝审批/工具请求。接入审批前不得声明对应 app-server capability，也不得把需要审批的请求当作已执行。
- **配置在运行时创建时固定**：`GenericAgentRuntime.Configuration` 创建后不可变；切换模型/推理开关时 `AppState` 重建 Runtime（计划 §6.3）。
- **两套 API 并列**：OpenAI、DeepSeek、Moonshot Kimi 与 GLM 由 `OpenAIResponsesProvider` 走 `/responses`（`store: false`）；Kimi Code 由 `OpenAIChatCompletionsProvider` 走 `/chat/completions`，使用 Kimi 原生 `thinking` 与 `reasoning_content` 字段。
- **Base URL 校验**：仅允许 HTTPS，无 user/password/query/fragment，尾部斜杠归一化（`AppState.validatedBaseURL`）。
- **UserDefaults 键**：按服务商隔离，形如 `provider.<vendor>.baseURL|model|models|modelCatalog|modelContextWindows|contextWindowOverrides|thinkingEnabled|verifiedAt`；旧版单服务商键（`apiBaseURL` 等）在启动时迁移，勿新增对 legacy 键的依赖。

## 代码风格

- 注释、文档、UI 文案与面向用户的错误消息使用**中文**；标识符用英文。
- 类型头部的文档注释常引用计划文档章节（如 `/// 通用运行时（计划 §6.1 Generic Agent Runtime）`），新代码保持这一习惯。
- 状态类标注 `@MainActor`；跨边界类型标注 `Sendable`。
- 依赖通过 `init` 注入（`APIKeyStoring`、`ConversationPersisting`、`UserDefaults`、`URLSession`），方便测试替换；默认参数提供生产实现。
- 无 lint/格式化配置文件，遵循现有代码的 Swift 常规风格（4 空格缩进等）。

## 测试策略

- 全部测试在 `discoTests/`，XCTest，`@testable import disco`，测试类标注 `@MainActor`。
- **网络不打真请求**：用自定义 `URLProtocol` 子类注入 `URLSessionConfiguration.ephemeral` 回放 SSE/JSON 响应（见 `OpenAICompatibleProviderTests`）。流式测试应覆盖任意分片，而非"每 chunk 恰好一行"。
- **Codex 不依赖真实登录**：用脚本化 `LineProcess` 回放 app-server JSONL（见 `CodexAppServerTestSupport`）；测试 request/response 路由、事件顺序、多 thread 隔离、取消和进程退出。真实 Codex smoke test 必须显式 opt-in。
- **存储用替身**：`InMemoryAuthStore`、`VolatileConversationPersistence`、独立 suite 的 `UserDefaults`（每个测试用 `UserDefaults(suiteName:)` + `removePersistentDomain` 清理）。
- `discoApp.swift` 在检测到 `XCTestConfigurationFilePath` 环境变量时自动注入内存替身，测试进程不会读写真实凭据/数据库。
- 新增功能应补测试；改动持久化模型时注意 `ConversationPersistenceTests` 的往返断言。

## 安全注意事项

- API Key 明文存储在 Application Support 目录：`~/Library/Application Support/disco/config/auth.json`（0600 权限、原子写入），按服务商 account 隔离。旧版位于沙盒容器（`~/Library/Containers/<bundle-id>/Data/Library/Application Support/disco/config/auth.json`，本应用曾启用 App Sandbox）与更早的 `~/.disco/config/auth.json` 的文件会在首次读取时自动迁移。这是当前 MVP 的明确取舍（对齐 gh/aws CLI 的做法），蓝图中的 Keychain 方案尚未实施——不要假设 Keychain 已在使用。
- 应用不启用 App Sandbox（ADR-006：不以 Mac App Store 沙箱为目标），因此可以拉起本地 `codex app-server` 子进程复用 ChatGPT/Codex 订阅；即便无沙箱，应用自身仍保持最小权限边界（Base URL 强制 HTTPS、凭据文件 0600、日志脱敏）。
- 凭据不得写入 UserDefaults、SwiftData 或日志。
- Base URL 强制 HTTPS，配置错误直接拒绝保存（`APIConfigurationError`）。
- `.gitignore` 仅忽略 Xcode 用户态文件与 `.reasonix/`；不要提交任何含真实 Key 的文件。

## 部署/发布

当前无发布流水线。蓝图（计划 §6、§20）规划为 Developer ID 签名 + Apple 公证 + 自动更新，不面向 Mac App Store；尚未实施。
