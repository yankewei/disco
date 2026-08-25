# Disco 目标架构

> 状态：目标架构基线 + 现状标注。
>
> 本文描述目标系统形态；各章节按迁移进度标注“现状”，与代码不一致处以此为准。
> DAP 已全部删除；尚未完成或采用简化实现的部分见各章节标注与
> `docs/disco-acp-facade.md`，完整迁移状态见第 15 节。

## 1. 需求与约束

Disco 是一款 macOS 原生 AI coding agent。产品希望同时获得 SwiftUI 的桌面体验和
Rust agent 生态的扩展能力。

### 1.1 核心需求

1. SwiftUI 负责界面、交互和 macOS 平台集成，不承担模型协议或 agent loop。
2. Rust daemon 是唯一 agent host，负责运行、会话、权限、工具、安全策略和持久化。
3. 系统必须支持三类 agent 后端：
   - Codex app-server：Codex 自有 JSON-RPC 协议，Codex 自己拥有 agent loop 和 thread。
   - OpenCode server：daemon 托管一个 loopback `opencode serve`，通过 REST + SSE 接入；每个
     project-scoped 请求显式携带绝对 `directory`，不依赖 server 当前工作目录。
   - ACP agent：Kimi、Qoder 等，后端通过 ACP 暴露完整 agent 能力。
   - 模型 API：DeepSeek、Codex/OpenAI API Key、Anthropic 等，Disco 基于 Rig
     运行自己的 agent。
4. Swift 只维护一个 daemon 客户端和一套公共运行状态，不感知后端原始协议。
5. 不牺牲 Codex 等后端的独有能力；公共能力统一，可选能力通过能力协商暴露。
6. 会话可恢复、可展示、可搜索；后端状态丢失时仍能查看 Disco 的本地镜像。
7. 审批、取消和终止语义必须对三类后端一致且可验证。

### 1.2 非目标

- 不在 Swift 中重新实现 Codex app-server 或 ACP client 的 agent 语义。
- 不在 Rust 中继续手写 Rig 已经稳定提供的通用 Provider 适配。
- 不要求所有后端具有完全相同的高级能力。
- 不把任意后端原始 JSON 直接泄漏给 SwiftUI。
- 不把 ACP 扩展成承载所有内部实现细节的万能协议。

## 2. 核心架构决策

### A1. Rust daemon 是唯一 agent 内核

SwiftUI 不直连模型、不启动 Codex 或 OpenCode，也不持有后端会话句柄。
这些职责全部收敛到 daemon。

### A2. App 使用 ACP-compatible Disco Protocol

Swift 与 daemon 之间使用一条 JSON-RPC 连接。协议由两部分组成：

- **ACP 标准能力**：初始化、会话、prompt、流式 update、取消和权限请求。
- **`disco/*` 产品扩展**：Provider 配置、账户、模型目录和 ACP 尚未稳定表达的产品能力。

因此，App 面对的是“ACP-compatible Disco Protocol”，而不是纯 ACP，也不是继续扩张后的
DAP。ACP client 可以忽略 `disco/*` 扩展；Disco App 可以在能力协商后使用它们。

### A3. Codex 原始协议只存在于 CodexAdapter 内部

CodexAdapter 将公共运行语义映射为 ACP，将 Codex 独有且产品确实需要的能力映射为
`disco/*` 扩展。Swift 不解析 app-server frame，也不管理其 request ID、重入请求或子进程。

### A4. 三类后端共享 AgentBackend seam

后端差异是真实存在的变化点，因此 daemon 定义一个小型 `AgentBackend` interface，并由
三个 Adapter 实现：

- `CodexAdapter`
- `AcpAdapter`
- `RigBackend`

该 interface 只表达 Disco 真正需要的会话和运行语义，不复制三套后端的全部协议表面。

### A5. 公共能力统一，高级能力协商

文本、推理、工具状态、权限、取消、用量和终止状态属于公共能力。归档、fork、compact、
sandbox、插件、模型切换等属于可选能力。后端不支持时，UI 必须隐藏或禁用对应操作，不能
伪造等价行为。

### A6. 会话采用 M3 分层所有权

agent 后端持有权威对话状态，daemon 持有稳定的 Disco 会话注册表和可展示镜像。Swift
只使用 Disco session ID，不接触后端句柄。

### A7. 配置由 daemon 管理

App 通过 `disco/*` 扩展提交和读取配置。daemon 负责校验、持久化、权限、迁移和明确的
成功/失败响应。App 不通过直接写文件和文件监听建立第二套隐式协议。

## 3. 系统总览

```text
┌─────────────────────────────────────────────────────────┐
│ SwiftUI App                                             │
│                                                         │
│  Conversation UI   Settings UI   Permission UI          │
│           └──────────── DiscoClient ─────────────┐       │
│                   ACP + disco/* extensions       │       │
└──────────────────────────────────────────────────┼───────┘
                                                   │
                                      JSON-RPC over stdio
                                                   │
┌──────────────────────────────────────────────────┼───────┐
│ Rust daemon                                      ▼       │
│                                                         │
│  Protocol Facade ─ SessionRegistry ─ RunCoordinator     │
│          │          PermissionBroker   MirrorStore       │
│          │          ConfigStore        ToolPolicy        │
│          ▼                                              │
│  AgentBackend seam                                      │
│    ├── CodexAdapter ── Codex app-server JSON-RPC        │
│    ├── OpenCodeAdapter ── REST + SSE ── opencode serve  │
│    ├── AcpAdapter   ── External ACP agent               │
│    └── RigBackend   ── Rig ── Model Provider APIs       │
│                                                         │
│  SQLite + credential storage                            │
└─────────────────────────────────────────────────────────┘
```

## 4. 进程与传输

### 4.1 默认拓扑

App 启动 daemon 子进程，默认使用 stdio 传输 JSON-RPC：

- stdout 只允许协议 frame。
- stderr 用于结构化日志，禁止输出凭据和完整敏感内容。
- App 退出时，默认取消活动运行并终止其启动的 daemon。
- daemon 负责终止自己启动的 Codex 和 ACP 子进程，避免孤儿进程。

是否支持脱离 App 的后台运行是独立产品决策。需要时可增加 Unix Domain Socket transport，
但 transport 不得改变上层协议和模块 interface。

### 4.2 协议版本

- ACP crate、schema 和 Swift DTO 必须固定到明确版本。
- 初始化时协商 protocol version 和 capability。
- 后端兼容差异只能存在于对应 Adapter，不能散落在 RunCoordinator 或 SwiftUI。
- 升级 ACP 前必须运行 Swift ↔ daemon 契约测试和真实后端冒烟测试。

## 5. App 与 daemon 的协议面

### 5.1 ACP 标准能力

具体方法名以固定的 ACP schema 为准，语义至少覆盖：

- initialize 与 capability negotiation
- session new/resume/list/close/delete（按 capability 启用）
- prompt 与 session update
- cancel
- request permission

所有 ACP 字段沿用协议规定的 camelCase，不使用全局 snake_case 自动转换猜测 wire name。

### 5.2 Disco 产品扩展

产品管理能力使用 `disco/*` 逻辑命名空间，候选方法包括：

ACP v1 SDK 要求自定义 wire method 以 `_` 开头，因此当前实现在线上使用
`_disco/*`（例如 `_disco/provider/list`）；下划线只属于 ACP transport 兼容层，产品语义
仍归属于 `disco/*`。未来协议允许非下划线 namespaced extension 时，可以增加等价别名，但
不得改变产品层语义。

```text
disco/provider/list
disco/provider/configure
disco/provider/models
disco/account/status
disco/config/get
disco/config/update
disco/session/archive
disco/session/unarchive
disco/session/fork
disco/session/compact
```

这些方法不是 Codex 原始方法的透明代理。它们表达 Disco 产品语义，由 daemon 根据会话
Provider 和 capability 路由到内部 Adapter。只有无法形成稳定产品语义的特性才使用
后端命名空间，例如
`disco/codex/collaboration_mode`。

会话创建时通过 namespaced `_meta` 指定可选 `providerId`；未指定时使用 daemon
配置的默认 Provider。daemon 再将 Provider 解析到内部 Backend Adapter。后端原始句柄永远
不出现在 App 的公共 interface 中。

### 5.3 错误模型

错误至少区分：

- 无效请求或协议版本不兼容
- capability 不支持
- 配置或认证失败
- 后端不可用或子进程退出
- 会话句柄失效
- 用户拒绝权限
- 运行取消
- 工具或模型执行失败
- daemon 内部错误

面向用户的错误使用中文；稳定的机器可读 code 不包含供应商文案。

## 6. AgentBackend seam

以下为语义草图，不要求照搬为最终 Rust 类型：

```rust
trait AgentBackend {
    fn capabilities(&self) -> BackendCapabilities;

    async fn create_session(&self, request: CreateSession)
        -> Result<BackendSession>;

    async fn resume_session(&self, handle: &BackendHandle)
        -> Result<BackendSession>;

    async fn start_run(
        &self,
        session: &BackendSession,
        request: RunRequest,
        sink: Arc<dyn RunEventSink>,
    ) -> Result<RunHandle>;

    async fn delete_session(&self, handle: &BackendHandle)
        -> Result<DeleteOutcome>;
}

trait RunHandle {
    async fn cancel(&self);
    async fn respond_permission(&self, response: PermissionResponse);
}
```

`SessionRegistry` 负责列表和路由，因此 backend interface 不提供跨 Disco 项目的全局列表。
Adapter 负责把后端协议转换成公共运行语义。

### 6.1 RunEventSink

daemon 内部需要一个小型公共事件 interface，供运行协调、镜像和协议输出共同消费。它不应
演化为复制 ACP、Codex 和 Rig 全部类型的庞大枚举。

公共语义限定为：

- assistant text delta
- reasoning delta
- tool update
- usage update
- permission request/resolution
- session metadata update
- backend extension

运行的最终结果由单独的 `RunOutcome` 表达，而不是依赖“stream 自然结束”推断成功。

## 7. 三个 Backend Adapter

### 7.1 CodexAdapter

CodexAdapter 是 app-server 的唯一 client，负责：

- 子进程启动、initialize/initialized、读写循环和退出恢复
- thread 创建、恢复和生命周期操作
- turn 启动、interrupt 和最终状态
- message、reasoning、item、tool 和 usage 更新
- command/file 等 approval server request
- account、models、config 和 Codex 可选能力

公共映射示例：

| Disco/ACP 语义 | Codex app-server |
|---|---|
| create/resume session | thread start/resume |
| prompt | turn/start |
| cancel | turn/interrupt |
| assistant/reasoning update | item delta notifications |
| permission request | approval server request |
| backend handle | thread ID |

Codex 新增能力时先判断其是否具有跨后端的稳定产品语义：

1. 有稳定语义：扩展通用 `disco/*` capability。
2. 只有 Codex 有价值：添加明确的 `disco/codex/*` 扩展。
3. 仅用于调试：保留在 Adapter 内，不暴露给 Swift。

禁止提供任意 app-server raw frame tunnel 作为正式产品 interface。

### 7.2 AcpAdapter

AcpAdapter 对下游 ACP agent 是 host，对上游 App 是 agent。数据内容尽量透传，但必须处理：

- 上下游 capability 交集
- Disco session ID 与下游 session ID 的双向映射
- request ID 和进程 generation
- permission request 的重入转发
- cancel、终止状态和断线
- 子进程恢复后的 session resume/load
- 不支持 delete 等能力时的降级

“透传”不等于字节代理。会话 ID、权限、生命周期和本地镜像仍由 daemon 控制。

### 7.3 RigBackend

RigBackend 用于只有模型接口、没有完整 agent 协议的 Provider：

- Rig 负责 Provider 客户端、completion/streaming、基础 agent runner 和通用工具接入。
- Disco 负责 system policy、workspace、审批、工具安全、会话持久化和运行事件。
- Provider 特有差异封装在 RigBackend 内部，不能进入 AgentBackend interface。
- Rig 尚不支持的 Provider 功能可以添加局部 Adapter，但不得恢复一套平行的通用 Provider
  框架。

RigBackend 的 backend handle 指向 daemon 自己持久化的会话，因此 daemon 同时是 agent 和
权威状态持有者。

### 7.4 Provider 与 Backend Adapter

Provider 是用户选择的具体 agent 来源；Backend Adapter 是 daemon 内部的实现分类。多个
Provider 可以复用同一个 Adapter，但仍然拥有独立的配置、账户、模型目录和 capability。

| Provider | `backend_kind` | Adapter | agent loop 持有者 | 权威会话 |
|---|---|---|---|---|
| `codex_app_server` | `codex` | CodexAdapter | Codex | Codex thread |
| `codex_api` | `rig` | RigBackend | Disco + Rig | daemon SQLite |

`codex_app_server` 和 `codex_api` 是两个不同 Provider。API Key 方式只复用模型能力，
不自动获得 app-server 的 thread、approval、sandbox、plugin 或 compact 语义。

上下文压缩的权威来源由 `BackendCapabilities.compaction` 声明：CodexAdapter 和 AcpAdapter
标记为 `Native`，只把原生压缩事件转发给 client；RigBackend 标记为 `Local`，使用 daemon
生成的摘要 checkpoint 作为后续模型上下文前缀，原始 transcript 仍完整保存在 SQLite。
当前 `agent-client-protocol` Rust SDK 还没有 typed `compaction_update` 枚举，因此原生事件
通过 `_disco/session/compaction` 私有通知承载；payload 使用 ACP v1 RFD 的
`sessionUpdate: "compaction_update"` camelCase 字段，待 SDK 纳入标准类型后可直接替换。

## 8. 会话与持久化

### 8.1 状态所有权

| Backend | 权威状态 | 恢复句柄 |
|---|---|---|
| CodexAdapter | Codex thread 存储 | thread ID |
| AcpAdapter | 下游 agent 会话存储 | ACP session ID |
| RigBackend | daemon SQLite | local session ID |

daemon 使用稳定的 `disco_session_id` 对外。`backend_handle` 是不透明内部值，不允许 Swift
缓存或构造。

### 8.2 注册表

`sessions` 至少保存：

```text
id                  Disco session ID
project_id          所属项目
provider_id         不可变的 Provider profile ID
backend_handle      后端不透明句柄
backend_generation  下游进程 generation
title
model
created_at
updated_at
deleted_at          软删除/后台 GC
```

项目使用规范化 cwd 匹配。路径比较必须解析符号链接并使用路径 component 语义，不能使用
字符串前缀判断。

### 8.3 镜像

镜像是展示和恢复降级数据，不冒充后端权威历史。初期保存完整的追加式事件，再生成派生的
message view：

```text
mirror_events
  session_id + run_id + sequence  唯一键
  event_kind
  payload
  created_at

mirror_messages
  从 mirror_events 可重建的展示模型
```

写入要求：

- 同一 run 的 sequence 单调递增。
- 重复事件幂等。
- 中断的 run 标记 incomplete/cancelled/failed。
- 摘要是可删除、可重建的派生数据，不取代原始镜像。
- 后端句柄失效时，session 进入 mirror-only 状态，禁止假装可以继续原会话。

> 现状：`mirror_events` 尚未实现。当前 `messages` 表持久化 user/assistant 文本、
> reasoning、tool call 元数据及关联的 tool result 记录；Swift 恢复时将这些记录
> 合并为包含 thinking/tool_call 的聊天历史。后续仍可按本节设计补充独立事件表。

### 8.4 删除语义

“删除会话”表示同时删除 Disco 本地注册表与镜像，并删除 Codex/OpenCode
等后端中的权威会话。删除必须是可观测的完整操作：

- 先请求后端删除，成功后再删除本地记录。
- 后端删除失败或不支持时，保留本地记录并返回明确错误，不报告假成功。
- RigBackend 的权威会话就在 daemon，由同一个持久化事务删除。
- 只想从列表隐藏时使用 archive，不降级成“仅删除本地”。

## 9. 运行、取消和权限不变量

每次运行必须满足以下不变量：

1. 一个 prompt 恰好产生一个最终 `RunOutcome`。
2. 最终状态只能是 completed、failed 或 cancelled 之一。
3. cancel 幂等，并在模型流、工具执行和等待权限阶段都有效。
4. permission request 带稳定 ID，并绑定 run、具体影响快照和 fingerprint。
5. permission response 只能消费一次，不能作用于其他 run 或已变化的工具参数。
6. JSON-RPC 读取循环不能因为等待 permission response 而阻塞；必须支持重入请求。
7. 普通增量允许受控合并，但不允许静默丢失 permission、tool completion 或最终状态。
8. App/transport 断开时执行明确策略，默认取消活动运行并清理子进程。
9. 同一会话最多只有一个活动 run；run 结束前不接收第二个 prompt。
10. 不同会话可以并行运行。
11. 会话的 `provider_id` 创建后不可变，后端或模型失败时也不自动切换。

`PermissionBroker` 统一三类后端的产品审批体验：

- Codex approval → Disco permission
- 下游 ACP RequestPermission → 嵌套转发
- Rig 工具执行 → Disco permission

MVP 只提供“仅允许本次”和“本会话允许相同 fingerprint”，不提供全局永久允许。

Adapter 保留后端原始选项的语义；无法等价转换时通过 capability 或文案明确降级。

## 10. 配置、账户和凭据

`ConfigStore` 是 daemon 内的深模块，对 App 提供小型 `disco/*` interface，内部隐藏：

- schema 版本和迁移
- Provider 配置校验
- 模型目录缓存与刷新
- Codex/ACP agent 可执行文件定位
- 默认 Provider、Provider profile 与 Backend Adapter 的映射
- 凭据存储

安全要求：

- 凭据不进入 UserDefaults、会话表、协议日志或错误详情。
- MVP 使用文件存储时，目录权限为 `0700`，文件权限为 `0600`，并采用原子写入。
- 未来切换 macOS Keychain 只替换 ConfigStore 内部 Adapter，不改变 App interface。
- 配置变更返回明确结果；不依赖 App 猜测文件监听是否成功。

> 现状：迁移尚未收敛为单一 ConfigStore。Swift 客户端仍维护设置页配置，并将 API Key
> 写入 `~/Library/Application Support/disco/config/auth.json`（文件权限 `0600`），
> 将非敏感配置和模型目录缓存写入 UserDefaults；daemon 的 `provider_service` + SQLite
> `provider_profiles` 负责运行时校验、backend 装配和运行时配置副本。客户端同步配置时，
> daemon 也会保存收到的 API Key 到 SQLite 明文；数据库及其 WAL/SHM 伴随文件均为 `0600`
> （daemon 启动时将进程 umask 设为 `0o077`）。因此当前存在双份凭据存储，尚未接入
> macOS Keychain，后续应明确单一权威存储并消除重复副本。

## 11. 工具与安全

- workspace 是所有本地文件和搜索工具的默认安全根。
- 路径检查必须处理不存在路径、符号链接、父目录跳转和路径前缀碰撞。
- shell 命令必须经过 PermissionBroker，并支持取消整个进程组。
- 工具参数的批准 fingerprint 必须在执行前重新验证。
- 子进程环境变量采用最小传递策略，禁止无意传播无关凭据。
- 工具输出有大小上限，并保留结构化的截断信息。
- 网络访问和额外目录通过 capability/policy 显式声明。

## 12. 测试策略

### 12.1 Backend contract suite

为 AgentBackend 定义共享契约测试，每个 Adapter 必须通过：

- session 创建和恢复
- 文本与推理流
- 工具状态
- permission 往返
- cancel 的三个阶段
- 恰好一个最终状态
- 后端崩溃和句柄失效
- capability 不支持

### 12.2 协议契约

- Rust ACP/Disco DTO round-trip 和固定 wire fixture。
- Swift 与 Rust 共用相同 JSON fixture，禁止各自只测自己的 Codable/serde。
- 测试 server request 与 notification 在 prompt 未完成时重入。
- 测试慢消费者和有界队列，保证关键事件不丢失。

### 12.3 集成测试

- Swift App client → daemon → fake backend。
- daemon → fake Codex app-server。
- daemon → fake ACP agent。
- daemon → Rig mock model。
- 真实 Codex/OpenCode 测试使用显式 gate，不进入默认离线测试。

## 13. 模块职责

目标模块关系如下，具体 crate 数量可随实现演进，不为了目录整齐创建浅模块：

```text
protocol facade
  只负责 ACP/Disco wire、capability 和请求路由

core
  SessionRegistry、RunCoordinator、PermissionBroker、AgentBackend interface

backends
  CodexAdapter、AcpAdapter、RigBackend

tools
  工具定义、执行、安全根和取消

persist
  注册表、运行、镜像、配置 schema

daemon
  进程装配、transport、生命周期和日志
```

协议 facade 不包含业务分支；Backend Adapter 不直接更新 Swift 状态；Swift 不直接访问
daemon 数据库。

> 现状：`SessionRegistry` 由 `RunCoordinator` + `sessions` 表承担；
> `PermissionBroker` 由 `ApprovalManager` + `RunCoordinator::respond_approval` 承担；
> `ConfigStore` 由 `provider_service` + `provider_profiles` 表承担，均为务实子集而非
> 同名独立模块。

## 14. 被否决的方案

### Swift 直接消费 Codex app-server

会让 Swift 维护第二套协议、子进程、会话模型和审批状态，破坏薄客户端目标。

### 将 Codex 强制压缩成纯 ACP

会丢失 Codex 的 thread、配置、sandbox、插件等高级能力，并导致 Adapter 持续追逐有损映射。

### 完整保留 DAP 作为第二协议

Swift 需要在 DAP 与 ACP 之间维护重复状态；新增后端能力还要同时扩展两套协议。

### App 写配置文件、daemon 监听

文件写入变成没有明确响应和错误语义的隐式协议，难以处理验证、并发和凭据迁移。

### 所有后端共享完整历史

Codex 和外部 ACP agent 不保证可导出或注入完整历史。强行双写会制造无法解决的权威冲突。

### 巨型统一事件模型

复制所有后端协议会产生低 leverage 的浅模块。内部只统一产品确实消费的运行语义，其余通过
capability 和 namespaced extension 表达。

## 15. 迁移路线

迁移以可回退、可验证为原则：

### Phase 0：冻结契约

- 固定 ACP 版本和 Swift/Rust wire fixture。
- 定义 `disco/*` 命名空间和 capability。
- 定义 AgentBackend、RunOutcome 和运行不变量。

状态：已完成。

### Phase 1：建立新协议 facade

- daemon 增加 stdio ACP-compatible transport。
- 保留 DAP，两个 facade 暂时调用同一 RunCoordinator。
- 建立 Swift ↔ daemon 端到端测试。

状态：已完成。stdio ACP facade 是唯一 transport，DAP 已删除，无双协议并存。

### Phase 2：建立三个 Backend Adapter

- AcpAdapter：优先完成透传、session 映射、权限和恢复。
- CodexAdapter：补全 approval、item、thread 生命周期和 Disco 扩展。
- RigBackend：替换手写 Provider 和自研通用流式解析。

状态：已完成（三个 Adapter 均落地并有契约测试）。

### Phase 3：迁移状态所有权

- daemon 注册表成为会话列表唯一来源。
- 增加 mirror_events 和派生 message view。
- Provider 配置和凭据迁移到 ConfigStore。

状态：部分完成。注册表已是会话列表唯一来源，ConfigStore 由 provider_service +
provider_profiles 承担；`mirror_events`/`mirror_messages` 尚未实现（见 §8.3 现状）。

### Phase 4：切换 Swift 主流程

- Swift 只使用 DiscoClient。
- ConversationStore 只消费公共运行状态和 capability。
- 删除 Swift 中的 Provider、GenericAgentRuntime 和 Codex transport。

状态：部分完成。Swift 主流程已走 DiscoClient，不再保留 Codex transport；
Swift 仍保留 SwiftData 会话/项目快照，作为离线回退缓存（daemon 可用时以 daemon
为权威并刷新缓存）。

### Phase 5：退役旧路径

- 删除 DAP router、DaemonProtocol.swift 和旧协议文档。
- 删除 Rust 手写的通用 Provider/SSE 层中已被 Rig 替代的部分。
- 更新 AGENTS.md、构建脚本和 CI。

状态：部分完成。DAP 与自研 `AgentLoop` 已删除；手写 Provider（openai_responses /
chat_completions）仅保留给上下文压缩使用，未再承担主运行路径。

每个 Phase 完成条件是新路径测试通过且旧路径已有等价替代，而不是代码已经创建。

## 16. 已冻结的 MVP 产品决策

1. 同一会话只允许一个活动 run，运行中不接收新 prompt；不同会话可以并行。
2. `codex_app_server` 和 `codex_api` 是两个不同 Provider，分别由 CodexAdapter 和
   RigBackend 实现，不共享 backend handle 或 capability。
3. Codex/OpenCode 等后端崩溃时，当前 run 失败，但保留 Disco 本地记录并允许
   重新连接或创建新会话。
4. MVP 不支持脱离 App 的后台运行；关闭 App 时取消活动 run 并终止 daemon。
5. 权限批准只支持“本次”和“本会话相同 fingerprint”，不提供全局永久批准。
6. 后端或模型失败时不自动切换，由用户明确选择重试或其他后端。
7. “删除会话”同时删除 Disco 本地记录和后端权威会话，不提供默认的
   “仅本地删除”语义。
8. 会话创建后 Provider 不可变；切换 Provider 必须创建新的 Disco 会话。

## 17. 尚未冻结的产品决策

1. mirror 原始事件的保留周期和空间上限。
2. MVP 凭据使用受限文件还是直接接入 macOS Keychain。
3. 第一版向 UI 暴露哪些 Codex app-server 高级能力。
4. 是否支持多账户，以及账户是按全局、项目还是会话选择。
5. 展示和持久化哪些 reasoning summary、工具输出和文件内容。
6. 外部 ACP agent 的安装、可执行文件信任和版本升级策略。

## 18. 参考资料

- ACP 协议：https://github.com/agentclientprotocol/agent-client-protocol
- ACP Rust SDK：https://github.com/agentclientprotocol/rust-sdk
- Codex app-server：https://github.com/openai/codex/tree/main/codex-rs/app-server
- Codex app-server protocol：https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol
- Rig：https://github.com/0xPlaygrounds/rig
- 已废弃的 DAP 协议存档：`docs/disco-agent-protocol.md`
