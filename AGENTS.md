# Repository Guidelines

## Project Overview

Disco is a macOS desktop coding-agent client written in Rust. It presents several model sources (Codex, OpenCode Go, DeepSeek, Kimi) through one conversation experience while preserving the **execution semantics of each source** — a Codex turn is executed by the local Codex app-server; a remote provider turn is executed by Disco's own runtime.

## Project Principles
1. 尽最大努力保持 macOS 原生体验和 UI (maximize macOS-native experience and UI).
2. 尽量复用 rust 的 crate，而不是重新写一个 crate，例如 ACP 已有 rust-sdk

## Code Layout

当前活跃代码全部位于 `crates/` 目录下。`disco/` 前缀的 Swift 文件为历史遗留，不作为变更参考。

### 依赖层级（从底层到顶层）

**Layer 0 — 共享类型（无内部依赖）**

- **disco-domain** — 核心领域类型语言（Project, Run, Session, RunEvent, ToolCall 等 UUID 标识符和事件结构）。所有 crate 共享的类型基础，修改需全局审视影响。依赖: chrono, serde, uuid。
- **disco-protocol** — 与隔离工具运行时通信的版本化 NDJSON 协议（ToolRequest, ToolResponse, ToolOperation）。仅依赖 serde，变更需保持协议版本兼容。

**Layer 1 — 核心协调（依赖 Layer 0）**

- **disco-kernel** — 运行协调与确定性 UI 投影。拥有 EventJournal trait、Kernel 状态机、RunProjection。是连接引擎和存储的枢纽。依赖: disco-domain。
- **disco-acp-engine** — 通用 ACP (Agent Client Protocol) 引擎。管理 ACP 生命周期（initialize → session/new → session/prompt）、连接线程、以及 session/update 到 Disco 活动模型的投影。新 agent CLI 通过 AcpSpec 接入，无需重写引擎。依赖: agent-client-protocol SDK。
- **disco-codex-engine** — 本地 Codex app-server 发现与 JSON-RPC 传输。管理 Codex 子进程生命周期、模型发现和 turn 执行。依赖: serde_json。
- **disco-rig-engine** — Rig 支持的远程 API provider 引擎（DeepSeek, Kimi 等 OpenAI 兼容 provider）。管理模型列表、checkpoint 和 in-process agent 原语。依赖: rig。

**Layer 2 — 特化绑定与持久化（依赖 Layer 0–1）**

- **disco-opencode-engine** — OpenCode 的 AcpSpec 绑定。仅定义二进制发现、ACP 模式进入方式和模型列表解析；所有协议级逻辑在 disco-acp-engine 中。新 agent 应创建独立 spec crate 而非扩展此 crate。依赖: disco-acp-engine。
- **disco-tool-runtime** — 受限的 workspace 作用域工具执行（文件读写、目录列表）。包含路径遍历防护和大小限制。依赖: disco-protocol。
- **disco-storage** — SQLite 事件日志持久化。实现 EventJournal 和 ProjectStore trait，管理 schema 迁移。依赖: disco-domain, disco-kernel, rusqlite。

**Layer 3 — 用户界面与应用（依赖 Layer 0–2）**

- **disco-ui** — GPUI 原生 macOS 界面。渲染对话、设置、Markdown 和 composer 输入；跨所有引擎后端统一调度。是体积最大的 crate，修改时注意 GPUI 渲染性能。依赖: disco-domain, disco-kernel, disco-codex-engine, disco-opencode-engine, disco-rig-engine, gpui。
- **disco-app** — 应用组合根（main binary）。组装 UI、存储、引擎和 GPUI 应用生命周期；初始化日志和数据目录。依赖: disco-ui, disco-storage, disco-codex-engine, disco-opencode-engine, gpui。

### 变更约束

- **disco-domain** 和 **disco-protocol** 是公共契约——修改类型或协议版本前必须检查所有下游 crate 的兼容性。
- **disco-kernel** 的状态机变更需同步更新 storage 和 UI 的投影逻辑。
- 新增 ACP agent 只需实现 `AcpSpec`，不应修改 `disco-acp-engine` 核心。
- 引擎 crate（codex, opencode, rig）之间不应互相依赖；它们通过 kernel 和 domain 共享类型。
- `unsafe_code` 被全局禁止；`dbg!`, `todo!`, `unwrap()` 被 clippy 拒绝。

## Architecture Decisions

- [ADR 0001](docs/adr/0001-separate-codex-and-remote-provider-runtimes.md) — Codex 走本地 app-server，远程 provider 走 Rig，保持各自执行语义。
- [ADR 0002](docs/adr/0002-acp-engine-boundary.md) — OpenCode 通过 ACP stdio JSON-RPC 接入，Disco 拥有持久化 run event 和审批；新 agent CLI 通过 AcpSpec 扩展。

## Local Development

```bash
cargo fmt --all -- --check   # 格式检查
cargo clippy --workspace --all-targets -- -D warnings  # 静态分析
cargo test --workspace        # 运行全部测试
```
