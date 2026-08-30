# AGENTS.md

本文件面向 AI 编程代理，介绍 Disco 当前的架构、构建方式与开发约定。

## 项目概览

Disco 是仅面向 macOS 的 Electron + TypeScript coding agent 桌面应用。

- Electron 主进程负责项目、会话、运行协调、本地持久化和系统能力。
- React renderer 只负责界面，不持有 Node.js 权限或后端凭据。
- preload 通过受限 `contextBridge` 暴露经过主进程校验的 IPC。
- Codex、Claude Code 和 OpenCode 分别通过各自的本地 SDK 或运行时接入。
- SQLite 保存项目、会话和消息镜像；官方运行时继续管理各后端的登录态。

更完整的边界说明见 `docs/architecture.md`。

## 技术栈

- Electron、TypeScript、React、Vite
- `@openai/codex-sdk`、`@anthropic-ai/claude-agent-sdk`
- OpenCode 本地 HTTP 接口
- `better-sqlite3`（WAL 模式）
- Zod（IPC 输入校验）
- Vitest

## 构建与测试

```bash
npm install
npm run dev
npm run build
npm test
npm run package
```

`npm run package` 构建 macOS universal 安装包，需要有效的签名和发布环境配置。

## 代码组织

```text
src/
├── main/
│   ├── backends/              # 每个 agent 后端的独立适配器与共享运行契约
│   ├── host.ts                # 会话运行、事件聚合、审批和取消
│   ├── index.ts               # Electron 生命周期、窗口和 IPC 注册
│   └── store.ts               # SQLite 持久化
├── preload/
│   └── index.cts              # renderer 可访问的最小 IPC API
├── renderer/
│   ├── App.tsx                # 工作区状态与交互协调
│   ├── SettingsView.tsx       # 独立设置窗口
│   ├── *Sidebar.tsx           # 侧栏组件
│   ├── *Timeline.tsx          # 消息与审批时间线
│   ├── *Composer.tsx          # 输入与运行控制
│   └── styles.css
└── shared/
    └── types.ts               # 主进程、preload、renderer 共享契约
```

## 架构约定

### 安全边界

- renderer 必须保持 `contextIsolation: true`、`sandbox: true`、`nodeIntegration: false`。
- 新增 renderer 能力时，先在 `shared/types.ts` 定义最小接口，再由 preload 转发，并在主进程使用 Zod 校验所有不可信参数。
- 外部链接交给系统浏览器；禁止 renderer 任意导航。
- 不读取、复制或记录 Codex、Claude Code、OpenCode 的登录凭据。

### 后端边界

- 每个后端实现 `AgentBackend`，接收 `BackendRunContext`，只产生统一的文本、推理和工具事件。
- 后端专属类型和协议留在对应模块，不泄漏到 renderer。
- 主进程 `AgentHost` 负责把后端事件绑定到 Disco 会话、处理审批、持久化最终消息并发送终止事件。
- 一次 prompt 必须恰好以一个 `run-finished` 事件结束。

### 持久化

- SQLite 是 Disco 的本地镜像，不是后端登录态的来源。
- 数据库字段使用 snake_case，TypeScript 领域类型使用 camelCase。
- 修改 schema 或消息序列化时，必须补充 round-trip 测试。

## 代码风格

- 注释、文档、UI 文案和用户可见错误使用中文；标识符使用英文。
- 保持 TypeScript `strict`、`noUnusedLocals` 和 `noUnusedParameters` 通过。
- 优先使用清晰的类型收窄、早返回和 `switch` 处理联合类型，避免嵌套三元表达式。
- 不要把没有复用价值、没有隐藏复杂性、没有表达稳定领域语义的一两行代码抽成方法。简单空值兜底、字段转发和 getter 应直接内联。
- 组件按稳定界面职责拆分；状态协调留在工作区容器，后端协议留在主进程。
- 不在 React 状态更新中直接修改旧对象或旧集合。

## 测试策略

- `npm run build` 同时验证主进程 TypeScript 和 renderer 生产构建。
- `npm test` 运行 Vitest；网络与 agent SDK 测试不得发送真实请求。
- 存储测试使用临时目录，并在测试结束后清理。
- 改动 IPC 时核对 shared、preload、main 三层签名保持一致。

## 清理原则

- 删除功能时同时删除 shared 类型、preload 转发、IPC handler、主进程方法、样式和依赖，不保留不可达的半套接口。
- 不为假想需求保留未消费事件、未使用字段或无入口的 UI 控件。
- 不提交 `dist-node/`、`dist-renderer/`、真实凭据或本地数据库。
