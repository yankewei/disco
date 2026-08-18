# AGENTS.md

本文件面向 AI 编程代理，介绍 disco 项目的架构、构建方式与开发约定。阅读前不需要任何项目背景知识。

## 项目概览

**disco** 是一款 macOS 原生 AI coding agent 应用，采用 **Rust daemon + SwiftUI 薄客户端** 架构。

- **Rust daemon**（`disco-daemon/`）：agent loop、工具执行（shell/file/search）、多模型服务商适配、上下文压缩、SQLite 持久化
- **SwiftUI 客户端**（`disco/`）：UI 渲染、用户交互、通过 stdio 子进程与 daemon 通信
- **通信协议**：ACP v1 over stdio（daemon 唯一 transport，见 `docs/disco-acp-facade.md`）。旧 DAP（JSONL over Unix Domain Socket）已在 Rust 与 Swift 两侧全部删除

项目的长期目标是支持完整的 coding agent 能力，包括 computer use（虚拟键鼠 + 屏幕捕获）和 browser use（headless Chrome）。

## 文档索引

- `docs/disco-agent-protocol.md`：Disco Agent Protocol (DAP) 协议规范（已废弃，仅存档）
- `docs/disco-acp-facade.md`：ACP stdio facade 与扩展方法
- 迁移方案：`~/.qoder-cn/plans/quiet-vista-carp.md`（本地文件，分阶段迁移路线）

## 技术栈

### Rust Daemon

- **语言**：Rust（edition 2024）
- **异步运行时**：tokio
- **HTTP**：reqwest（流式 SSE）
- **序列化**：serde + serde_json
- **持久化**：rusqlite（SQLite，WAL 模式）
- **日志**：tracing + tracing-subscriber
- **Crate 结构**：
  - `disco-protocol`：共享 DTO（Provider 配置、审批、用量等领域类型）
  - `disco-core`：agent loop + 会话管理 + 上下文压缩 + 审批流
  - `disco-providers`：迁移期模型服务商与 Codex app-server 适配
  - `disco-backends`：Codex、ACP、Rig 三类 AgentBackend adapter
  - `disco-tools`：工具执行器（shell、file_edit、search）
  - `disco-persist`：SQLite 持久化
  - `disco-daemon`：可执行文件入口、ACP stdio facade、共享 service 层

### SwiftUI 客户端

- **语言/平台**：Swift（Swift 6 并发模型，`default-isolation = MainActor`），macOS only
- **UI**：SwiftUI + AppKit；`NavigationSplitView` 侧栏 + 聊天主视图
- **网络**：daemon 子进程 stdin/stdout（agent-client-protocol JSON-RPC line transport）
- **序列化**：Foundation JSONEncoder/JSONDecoder（`.convertToSnakeCase` / `.convertFromSnakeCase`）
- **SwiftPM 依赖**：`MarkdownView`（Markdown 渲染），间接依赖 Highlightr、swift-cmark、swift-collections、Litext、SwiftMath

## 构建与测试

### Rust Daemon

```bash
cd disco-daemon

# 编译
cargo build

# 运行全部测试
cargo test

# 运行 daemon（只支持 ACP v1 stdio 模式）
cargo run -p disco-daemon -- --stdio
```

### SwiftUI 客户端

工程文件为 `disco.xcodeproj`（scheme 名 `disco`），无 Package.swift、无 Makefile。

```bash
# 运行全部测试
xcodebuild test \
  -project disco.xcodeproj \
  -scheme disco \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

打开 Xcode 直接 `open disco.xcodeproj` 即可运行 App。

## 代码组织

```text
disco-daemon/
├── Cargo.toml
├── crates/
│   ├── disco-protocol/      # 共享 DTO（Provider 配置、审批、用量等）
│   ├── disco-core/           # Agent loop + 会话管理 + 上下文压缩 + 审批
│   ├── disco-providers/      # 迁移期模型服务商适配
│   ├── disco-backends/       # Codex、ACP、Rig backend adapter
│   ├── disco-tools/          # 工具执行器（shell、file_edit、search）
│   ├── disco-persist/        # SQLite 持久化
│   └── disco-daemon/         # 可执行文件入口 + ACP stdio facade + 共享 service 层

disco/
├── App/                      # SwiftUI 界面与应用状态
│   ├── AppState.swift        # 根状态：daemon 连接、服务商配置、会话列表
│   ├── ConversationStore.swift  # 单会话状态 + daemon 事件处理
│   ├── ChatView.swift        # 聊天时间线、消息行、输入框、审批对话框
│   ├── SettingsView.swift    # 设置页：服务商配置
│   └── ...
├── Daemon/                   # daemon 通信层
│   ├── ACPDaemonClient.swift # ACP v1 stdio transport client
│   ├── ACPDaemonClientAdapter.swift # DiscoDaemonClient 协议 + ACP update/permission 到 DaemonEvent 的适配
│   ├── DaemonProtocol.swift  # DaemonEvent 与事件 DTO（daemon/UI 共享词汇）
│   └── DaemonProcessManager.swift  # daemon 二进制定位 + 旧版 socket 残留进程清理
├── AgentDomain/              # 领域模型（ChatMessage、RuntimeContract 等）
└── Assets.xcassets/
```

## 架构约定

### 协议层

- **ACP stdio**：daemon 唯一 transport，使用 agent-client-protocol 的 JSON-RPC line transport；Disco 产品操作（provider 配置/列表/models、session 消息、压缩）走 `disco/*` extension 方法，见 `docs/disco-acp-facade.md`
- **字段命名**：ACP wire 格式为 camelCase；daemon 内部共享 DTO 使用 snake_case
- **终止语义**：一次 prompt 恰好以一个终止状态收尾（EndTurn / Cancelled / 错误）

### Daemon 侧

- **Agent loop**：多轮模型循环（最多 24 轮，单次运行最多 64 个工具调用），支持审批流
- **工具执行**：`CompositeExecutor` 按工具名路由到 `ShellExecutor`、`FileEditExecutor`、`SearchExecutor`
- **审批流**：`ApprovalManager` 使用 oneshot channel 阻塞等待用户响应，支持 session 级别指纹缓存
- **Provider trait**：统一的 `ModelProvider` 接口，支持 Responses API 和 Chat Completions API
- **SQLite 持久化**：WAL 模式，写入串行化（单进程 tokio 天然串行）

### 客户端侧

- **ACPDaemonClient**：管理 daemon 子进程生命周期与 ACP JSON-RPC 收发
- **事件路由**：`ConversationStore.handleDaemonNotification()` 将 daemon 事件翻译为 UI 状态变更
- **Sendable 安全**：跨边界类型标注 `Sendable`，状态类标注 `@MainActor`

## 代码风格

- 注释、文档、UI 文案与面向用户的错误消息使用**中文**；标识符用英文。
- Rust 侧遵循标准 Rust 风格（cargo fmt）。
- Swift 侧遵循现有代码的 Swift 常规风格（4 空格缩进等）。
- 状态类标注 `@MainActor`；跨边界类型标注 `Sendable`。

## 测试策略

### Rust

- `cargo test` 覆盖所有 crate
- 协议测试：JSON round-trip 快照测试
- Provider 测试：mock HTTP 响应，不发送真实请求
- 工具测试：shell 命令在临时目录执行

### Swift

- 全部测试在 `discoTests/`，XCTest，`@testable import disco`
- **网络不打真请求**：用自定义 `URLProtocol` 子类注入响应
- **存储用替身**：`InMemoryAuthStore`、`VolatileConversationPersistence`
- `discoApp.swift` 在检测到 `XCTestConfigurationFilePath` 环境变量时自动注入内存替身

## 安全注意事项

- API Key 明文存储在 `~/Library/Application Support/disco/config/auth.json`（0600 权限），按服务商 account 隔离。这是当前 MVP 的明确取舍，未来计划迁移到 daemon 侧 SQLite 加密存储。
- 应用不启用 App Sandbox，因此可以拉起本地 daemon 子进程。
- 凭据不得写入 UserDefaults、SwiftData 或日志。
- `.gitignore` 仅忽略 Xcode 用户态文件、`target/`、`macos/` 构建产物；不要提交任何含真实 Key 的文件。
