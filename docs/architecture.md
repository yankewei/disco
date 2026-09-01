# Disco 原生架构

Disco 是仅面向 macOS 的 SwiftUI/AppKit 原生应用。应用进程直接负责界面状态、会话运行协调、Provider 进程管理和本地持久化。

```text
SwiftUI / AppKit
  |
  `- AppModel：工作区、会话和设置状态
      |- AgentHost：运行、审批、取消和事件聚合
      |   |- CodexBackend -> codex app-server stdio JSON-RPC
      |   `- OpenCodeBackend -> opencode serve HTTP/SSE
      `- SQLiteStore：项目、会话和消息镜像
```

Provider 适配器实现统一的 `AgentBackend` 契约，只向 `AgentHost` 产生文本、推理、工具和状态事件。Codex 使用 `thread/start` 或 `thread/resume` 创建线程，再通过 `turn/start` 执行请求；OpenCode 在本地动态端口启动 `opencode serve`，订阅 SSE 后提交 `prompt_async`，直到收到对应会话的 idle 事件。

`AgentHost` 为每次运行维护唯一的运行状态，处理审批、取消、终止和最终消息持久化，并保证一次 Prompt 只产生一个结束状态。Provider 的登录态继续由各自的官方 CLI 管理，Disco 不读取或复制凭据。

SQLite 仅保存项目、Disco 会话索引、消息镜像、工具记录以及运行失败/取消状态。原生客户端首次启动时会从旧 Electron 数据库迁移历史数据；旧客户端代码不再属于当前构建。

应用启用 Hardened Runtime。由于需要直接管理用户已安装的 Provider 可执行文件，原生 v1 暂不启用 App Sandbox；签名和 notarization 在发布阶段完成。
