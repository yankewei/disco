# AGENTS.md

本文件面向 AI 编程代理，介绍 Disco 当前的原生 macOS 架构、构建方式与开发约定。

## 项目概览

Disco 是仅面向 macOS 14+ 的 SwiftUI/AppKit coding agent 桌面应用。

- SwiftUI/AppKit 负责界面、窗口、菜单和用户交互。
- `AppModel` 负责工作区、会话和设置状态。
- `AgentHost` 负责 Provider 运行、事件聚合、审批、取消和最终消息持久化。
- Codex 通过本地 Codex CLI app-server 接入，OpenCode 通过本地 HTTP/SSE 接入。
- SQLite 保存项目、会话和消息镜像；Provider 官方运行时继续管理登录态。

更完整的边界说明见 `docs/architecture.md`。

## 技术栈

- Swift 5.9、SwiftUI、AppKit、Foundation
- Codex CLI app-server、OpenCode 本地 HTTP/SSE 接口
- SQLite（WAL 模式）
- XcodeGen、Xcode、xcodebuild

## 构建与测试

```bash
brew install xcodegen
xcodegen generate --spec project.yml --project .
xcodebuild -project Disco.xcodeproj -scheme Disco -configuration Debug -sdk macosx CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Disco.xcodeproj -scheme Disco -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## 代码组织

```text
Sources/
├── DiscoApp.swift          # 应用入口和原生窗口配置
├── NativeViews.swift       # SwiftUI/AppKit 界面
├── AppModel.swift          # 工作区和会话状态协调
├── AgentHost.swift         # 运行、审批、取消和事件聚合
├── CodexBackend.swift      # Codex app-server 适配器
├── OpenCodeBackend.swift   # OpenCode HTTP/SSE 适配器
├── JSONRPC.swift           # JSON-RPC stdio 通道
├── ProcessSupport.swift    # Provider 进程管理
├── SQLiteStore.swift       # SQLite 镜像和迁移
├── TimelineBuilder.swift   # 统一消息时间线
├── Models.swift            # 共享领域模型
└── Environment.swift       # 应用路径和 Provider 环境
Resources/
├── Assets.xcassets         # 应用图标
└── Info.plist              # 应用元数据
Tests/
└── NativeCoreTests.swift   # 原生核心测试
```

## 架构约定

### 安全边界

- 不读取、复制或记录 Codex、OpenCode 的登录凭据。
- 外部链接交给系统浏览器；Provider 进程只使用用户已安装的 CLI。
- 应用启用 Hardened Runtime；原生 v1 暂不启用 App Sandbox。
- 后端专属协议和类型留在对应适配器中，不泄漏到界面层。

### 后端边界

- 每个后端实现 `AgentBackend`，接收 `BackendRunContext`，只产生统一的文本、推理和工具事件。
- `AgentHost` 将后端事件绑定到 Disco 会话，处理审批、持久化最终消息并发送终止状态。
- 一次 Prompt 必须恰好以一个完成、取消或失败状态结束。
- Provider 进程必须支持取消、超时和优雅关闭，避免残留子进程。

### 持久化

- SQLite 是 Disco 的本地镜像，不是 Provider 登录态的来源。
- 数据库字段使用 snake_case，Swift 领域类型使用 camelCase。
- 修改 schema 或消息序列化时，必须补充 round-trip 测试。
- 迁移旧数据库前应确保旧客户端已经退出，避免并发写入。

## 代码风格

- 标识符遵循 Swift API Design Guidelines，使用有明确语义的名称。
- 文档、UI 文案和用户可见错误使用中文；注释仅在解释非显然逻辑时使用英文。
- 保持 Swift 编译器严格检查通过，避免强制解包和不必要的全局状态。
- 优先使用清晰的类型收窄、早返回和 `switch` 处理联合类型。
- 不要把没有复用价值、没有隐藏复杂性、没有表达稳定领域语义的一两行代码抽成方法。
- 不在 SwiftUI 状态更新中直接修改旧对象或旧集合。

## 测试策略

- 使用 `xcodebuild` 验证原生应用构建和测试。
- Provider 协议测试不得发送未经明确要求的真实请求。
- 存储测试使用临时目录，并在测试结束后清理。
- 修改模型、消息序列化或迁移逻辑时，必须补充 round-trip 测试。

## 清理原则

- 删除功能时同时删除对应的模型、适配器、界面、样式和构建配置，不保留不可达代码。
- 不提交 `DerivedData/`、构建产物、真实凭据或本地数据库。
