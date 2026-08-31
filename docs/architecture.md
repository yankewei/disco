# Disco Electron 架构

Disco 是单一 Electron 产品，运行在 macOS。主进程同时负责项目、会话、运行协调和本地持久化；React renderer 只负责界面，不持有 Node.js 或后端凭据。

```text
React renderer
  |  受限 contextBridge IPC
Electron main
  |- AgentHost
  |   |- Codex CLI app-server -> 本机 `codex login`
  |   |- Claude Agent SDK -> Claude Code 登录态
  |   `- OpenCode HTTP/SSE -> opencode serve
  `- SQLite 本地镜像
```

后端统一实现内部 `AgentBackend`，并产生文本、推理、工具和事件项。Codex 启动本机 CLI 的 `app-server` stdio JSON-RPC 通道，使用 `thread/start` 或 `thread/resume` 创建线程，再通过 `turn/start` 执行请求；Claude 使用 Agent SDK 的流式消息，OpenCode 在本机动态端口启动 `opencode serve`，先订阅 SSE，再提交 `prompt_async`，直到收到对应会话的 idle 事件；取消时 Codex 调用 `turn/interrupt`，其他后端沿用各自的取消流程。主进程为每次运行分配 `runId`，发送开始、结束（完成、取消或失败）事件，避免不同会话的流互相污染。

SQLite 仅保存项目、Disco 会话索引、消息镜像、工具记录和运行失败/取消状态；Codex、Claude Code 或 OpenCode 的认证凭据始终留在各自的官方本地运行时中。

安全边界：窗口启用 `contextIsolation` 与 sandbox，renderer 禁用 Node integration；preload 仅暴露经过主进程 Zod 校验的参数化操作。主进程校验工作区目录、导航、IPC 调用来源和全部 IPC 参数。
