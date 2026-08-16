# AGENTS.md

本文件面向 AI 编程代理，介绍 disco 项目的架构、构建方式与开发约定。阅读前不需要任何项目背景知识。

## 项目概览

**disco** 是一款 macOS 原生 AI coding agent 应用，采用 **Rust daemon + SwiftUI 薄客户端** 架构。

- **Rust daemon**（`disco-daemon/`）：agent loop、工具执行（shell/file/search）、多模型服务商适配、上下文压缩、SQLite 持久化
- **SwiftUI 客户端**（`disco/`）：UI 渲染、用户交互、通过 Unix Domain Socket 与 daemon 通信
- **通信协议**：JSONL over Unix Domain Socket（`~/Library/Application Support/disco/disco.sock`），详见 `docs/disco-agent-protocol.md`

项目的长期目标是支持完整的 coding agent 能力，包括 computer use（虚拟键鼠 + 屏幕捕获）和 browser use（headless Chrome）。

## 文档索引

- `docs/disco-agent-protocol.md`：Disco Agent Protocol (DAP) 协议规范
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
  - `disco-protocol`：协议 DTO + JSONL 编解码
  - `disco-core`：agent loop + 会话管理 + 上下文压缩 + 审批流
  - `disco-providers`：模型服务商适配（OpenAI Responses API、Chat Completions）
  - `disco-tools`：工具执行器（shell、file_edit、search）
  - `disco-persist`：SQLite 持久化
  - `disco-daemon`：可执行文件入口、Unix socket listener、请求路由

### SwiftUI 客户端

- **语言/平台**：Swift（Swift 6 并发模型，`default-isolation = MainActor`），macOS only
- **UI**：SwiftUI + AppKit；`NavigationSplitView` 侧栏 + 聊天主视图
- **网络**：POSIX Unix Domain Socket + DispatchSource 异步读取
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

# 运行 daemon
cargo run -p disco-daemon
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
│   ├── disco-protocol/      # 协议 DTO + JSONL 编解码
│   ├── disco-core/           # Agent loop + 会话管理 + 上下文压缩 + 审批
│   ├── disco-providers/      # 模型服务商适配
│   ├── disco-tools/          # 工具执行器（shell、file_edit、search）
│   ├── disco-persist/        # SQLite 持久化
│   └── disco-daemon/         # 可执行文件入口 + socket listener + 路由

disco/
├── App/                      # SwiftUI 界面与应用状态
│   ├── AppState.swift        # 根状态：daemon 连接、服务商配置、会话列表
│   ├── ConversationStore.swift  # 单会话状态 + daemon 事件处理
│   ├── ChatView.swift        # 聊天时间线、消息行、输入框、审批对话框
│   ├── SettingsView.swift    # 设置页：服务商配置
│   └── ...
├── Daemon/                   # daemon 通信层
│   ├── DaemonClient.swift    # Unix socket 连接 + JSONL 收发
│   ├── DaemonProtocol.swift  # 协议 DTO（与 Rust disco-protocol 对应）
│   └── DaemonProcessManager.swift  # daemon 进程管理
├── AgentDomain/              # 领域模型（ChatMessage、RuntimeContract 等）
└── Assets.xcassets/
```

## 架构约定

### 协议层

- **JSONL 帧格式**：每行一个完整 JSON 对象，`\n` 分隔
- **三种消息类型**：
  - Request（`{id, method, params}`）：客户端 → daemon，需要响应
  - Response（`{id, result}` 或 `{id, error}`）：daemon → 客户端
  - Event（`{event, data}`）：daemon → 客户端，流式通知
- **字段命名**：协议使用 snake_case（Rust 默认），Swift 端通过 `.convertToSnakeCase` / `.convertFromSnakeCase` 自动转换
- **终止事件保证**：一次 run 恰好发射一个终止事件（`run.completed` / `run.failed` / `run.cancelled`）

### Daemon 侧

- **Agent loop**：多轮模型循环（最多 24 轮，单次运行最多 64 个工具调用），支持审批流
- **工具执行**：`CompositeExecutor` 按工具名路由到 `ShellExecutor`、`FileEditExecutor`、`SearchExecutor`
- **审批流**：`ApprovalManager` 使用 oneshot channel 阻塞等待用户响应，支持 session 级别指纹缓存
- **Provider trait**：统一的 `ModelProvider` 接口，支持 Responses API 和 Chat Completions API
- **SQLite 持久化**：WAL 模式，写入串行化（单进程 tokio 天然串行）

### 客户端侧

- **DaemonClient**：`@MainActor` 隔离，POSIX socket + DispatchSource 异步读取
- **事件路由**：`ConversationStore.handleDaemonEvent()` 将 daemon 事件翻译为 UI 状态变更
- **JSON 编解码**：`DaemonJSONValue.decoded()` 用于动态 JSON → 具体类型的二次解码
- **Sendable 安全**：`DaemonClient` 标记 `@unchecked Sendable`，`eventStream` 在 init 时创建后不可变

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
