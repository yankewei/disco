# Disco Electron 架构

Disco 是单一 Electron 产品，运行在 macOS。主进程同时负责项目、会话、运行协调和本地持久化；React renderer 只负责界面，不持有 Node.js 或后端凭据。

```text
React renderer
  |  受限 contextBridge IPC
Electron main
  |- AgentHost
  |   |- Codex SDK -> codex login
  |   |- Claude Agent SDK -> Claude Code 登录态
  |   `- OpenCode HTTP/SSE -> opencode serve
  `- SQLite 镜像 + Electron safeStorage（API key）
```

后端统一实现内部 `AgentBackend`，并产生文本、推理、工具、用量和终止事件。SQLite 仅保存项目、Disco 会话索引、消息镜像和工具记录；订阅 OAuth token 始终留在 Codex、Claude Code 或 OpenCode 的官方本地运行时中。

安全边界：窗口启用 `contextIsolation` 与 sandbox，renderer 禁用 Node integration；preload 仅暴露经过主进程 Zod 校验的参数化操作。主进程校验工作区目录、导航和全部 IPC 参数。
