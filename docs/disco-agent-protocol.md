# Disco Agent Protocol (DAP) v1

## 1. 概述

**Disco Agent Protocol (DAP)** 是 disco 应用的进程间通信协议，用于 SwiftUI 客户端与 Rust 守护进程之间的双向通信。Rust 守护进程负责管理 AI agent 运行，客户端提供用户界面。

### 协议特性

- **协议名称**：Disco Agent Protocol (DAP)
- **协议版本**：v1
- **传输层**：Unix Domain Socket
  - 路径：`~/Library/Application Support/disco/disco.sock`
- **帧格式**：JSONL（每行一个 JSON 对象，以 `\n` 分隔）
- **通信模式**：全双工（full duplex）

### 设计目标

- 支持多模型 AI agent 运行管理
- 支持流式内容传输
- 支持工具执行与审批流程
- 支持上下文用量监控
- 支持会话持久化与恢复

---

## 2. 消息类型

DAP 定义三种消息类型，所有消息均为单行 JSON 对象。

### 2.1 Request（请求）

请求是双向的，客户端和服务端均可发送。每个请求必须包含唯一的 `id`，用于匹配响应。

**格式**：

```json
{
  "id": 1,
  "method": "session/list",
  "params": {
    "projectID": "proj_123"
  }
}
```

**字段说明**：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | integer | 是 | 请求唯一标识符，用于匹配响应 |
| `method` | string | 是 | 方法名称 |
| `params` | object | 是 | 方法参数，可为空对象 `{}` |

### 2.2 Response（响应）

响应是对 Request 的回复，通过 `id` 字段与请求匹配。响应必须包含 `result` 或 `error` 之一，不能同时包含两者。

**成功响应格式**：

```json
{
  "id": 1,
  "result": {
    "sessions": []
  }
}
```

**错误响应格式**：

```json
{
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found"
  }
}
```

**字段说明**：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | integer | 是 | 对应请求的 ID |
| `result` | object | 否 | 成功结果，与 `error` 互斥 |
| `error` | object | 否 | 错误信息，与 `result` 互斥 |

### 2.3 Event（事件）

事件是服务端向客户端的单向通知，不包含 `id` 字段，客户端无需响应。

**格式**：

```json
{
  "event": "message.delta",
  "data": {
    "runID": "run_456",
    "sessionID": "sess_789",
    "delta": "Hello"
  }
}
```

**字段说明**：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `event` | string | 是 | 事件名称 |
| `data` | object | 是 | 事件数据 |

---

## 3. Client → Daemon Requests

客户端向服务端发送的请求，涵盖生命周期管理、服务商配置、会话管理和 agent 运行控制。

### 3.1 生命周期

#### `initialize`

初始化连接，协商协议版本。

**请求**：

```json
{
  "id": 1,
  "method": "initialize",
  "params": {
    "clientInfo": {
      "name": "disco-client",
      "version": "1.0.0"
    },
    "protocolVersion": "v1"
  }
}
```

**响应**：

```json
{
  "id": 1,
  "result": {
    "daemonVersion": "1.0.0",
    "protocolVersion": "v1"
  }
}
```

#### `shutdown`

关闭连接，清理资源。

**请求**：

```json
{
  "id": 2,
  "method": "shutdown",
  "params": {}
}
```

**响应**：

```json
{
  "id": 2,
  "result": {}
}
```

### 3.2 服务商管理

#### `provider/configure`

配置或更新服务商。

**请求**：

```json
{
  "id": 3,
  "method": "provider/configure",
  "params": {
    "providerID": "deepseek_api",
    "vendor": "deepseek",
    "baseURL": "https://api.deepseek.com/v1",
    "apiKey": "sk-xxx",
    "model": "deepseek-chat",
    "thinkingEnabled": true
  }
}
```

**响应**：

```json
{
  "id": 3,
  "result": {
    "providerID": "deepseek_api",
    "vendor": "deepseek"
  }
}
```

#### `provider/list`

列出所有已配置的服务商。

**请求**：

```json
{
  "id": 4,
  "method": "provider/list",
  "params": {}
}
```

**响应**：

```json
{
  "id": 4,
  "result": {
    "providers": [
      {
        "providerID": "deepseek_api",
        "vendor": "deepseek",
        "baseURL": "https://api.deepseek.com/v1",
        "model": "deepseek-chat",
        "thinkingEnabled": true
      },
      {
        "providerID": "openai_api",
        "vendor": "openai",
        "baseURL": "https://api.openai.com/v1",
        "model": "gpt-4",
        "thinkingEnabled": false
      }
    ]
  }
}
```

#### `provider/models`

获取指定服务商支持的模型列表。

**请求**：

```json
{
  "id": 5,
  "method": "provider/models",
  "params": {
    "providerID": "deepseek_api",
    "vendor": "deepseek"
  }
}
```

`providerID` 是稳定的 Provider profile 标识。迁移期客户端可以省略，daemon 会根据
`vendor` 选择旧版默认 profile。`codex_app_server` 和 `codex_api` 是两个不同
Provider，不共享会话或配置。

**响应**：

```json
{
  "id": 5,
  "result": {
    "models": [
      {
        "id": "deepseek-chat",
        "displayName": "DeepSeek Chat",
        "contextWindow": 64000,
        "supportedReasoningEfforts": ["low", "medium", "high"],
        "defaultReasoningEffort": "medium"
      }
    ]
  }
}
```

### 3.3 Codex 专用

#### `codex/account`

查询本机 Codex 账户状态。

**请求**：

```json
{
  "id": 6,
  "method": "codex/account",
  "params": {}
}
```

**响应（已登录）**：

```json
{
  "id": 6,
  "result": {
    "requiresOpenaiAuth": false,
    "account": {
      "type": "chatgpt",
      "email": "user@example.com",
      "planType": "plus"
    }
  }
}
```

**响应（未登录）**：

```json
{
  "id": 6,
  "result": {
    "requiresOpenaiAuth": true
  }
}
```

#### `codex/models`

获取 Codex 支持的模型列表。

**请求**：

```json
{
  "id": 7,
  "method": "codex/models",
  "params": {}
}
```

**响应**：

```json
{
  "id": 7,
  "result": {
    "models": [
      {
        "id": "codex-mini",
        "displayName": "Codex Mini",
        "supportedReasoningEfforts": ["low", "medium", "high"],
        "defaultReasoningEffort": "medium"
      }
    ]
  }
}
```

### 3.4 会话管理

#### `session/projects`

列出所有项目。

**请求**：

```json
{
  "id": 8,
  "method": "session/projects",
  "params": {}
}
```

**响应**：

```json
{
  "id": 8,
  "result": {
    "projects": [
      {
        "id": "proj_123",
        "name": "disco",
        "path": "/Users/dev/projects/disco",
        "createdAt": "2026-01-15T10:30:00Z"
      }
    ]
  }
}
```

#### `session/project/create`

创建新项目。

**请求**：

```json
{
  "id": 9,
  "method": "session/project/create",
  "params": {
    "projectID": "proj_456",
    "name": "my-project",
    "path": "/Users/dev/projects/my-project"
  }
}
```

`projectID` 可选。客户端可提供稳定 ID；相同路径已存在时，daemon 返回已有项目，
因此该请求可安全重试。

**响应**：

```json
{
  "id": 9,
  "result": {
    "project": {
      "id": "proj_456",
      "name": "my-project",
      "path": "/Users/dev/projects/my-project",
      "createdAt": "2026-01-20T14:20:00Z"
    }
  }
}
```

#### `session/list`

列出指定项目下的所有会话。

**请求**：

```json
{
  "id": 10,
  "method": "session/list",
  "params": {
    "projectID": "proj_123"
  }
}
```

**响应**：

```json
{
  "id": 10,
  "result": {
    "sessions": [
      {
        "id": "sess_789",
        "projectID": "proj_123",
        "providerID": "deepseek_api",
        "vendor": "deepseek",
        "model": "deepseek-chat",
        "createdAt": "2026-01-15T10:30:00Z",
        "updatedAt": "2026-01-15T11:45:00Z",
        "title": "讨论架构设计"
      }
    ]
  }
}
```

#### `session/create`

创建新会话。

**请求**：

```json
{
  "id": 11,
  "method": "session/create",
  "params": {
    "sessionID": "sess_abc",
    "projectID": "proj_123",
    "providerID": "deepseek_api",
    "vendor": "deepseek",
    "model": "deepseek-chat"
  }
}
```

**响应**：

```json
{
  "id": 11,
  "result": {
    "session": {
      "id": "sess_abc",
      "projectID": "proj_123",
      "providerID": "deepseek_api",
      "vendor": "deepseek",
      "model": "deepseek-chat",
      "createdAt": "2026-01-20T15:00:00Z"
    }
  }
}
```

会话创建后 `providerID` 不可变。切换 Provider 需要创建新会话。旧客户端可以在
`session/create` 中省略 `providerID`，daemon 会从 `vendor` 映射到默认 Provider。
`sessionID` 也可省略；客户端提供稳定 ID 时，相同会话参数的重复请求返回已有会话，
参数不一致则返回 `invalid_params`。

#### `session/delete`

删除会话。

**请求**：

```json
{
  "id": 12,
  "method": "session/delete",
  "params": {
    "sessionID": "sess_789"
  }
}
```

**响应**：

```json
{
  "id": 12,
  "result": {}
}
```

### 3.5 Agent 运行

#### `run/start`

启动 agent 运行。

**请求**：

```json
{
  "id": 13,
  "method": "run/start",
  "params": {
    "sessionID": "sess_abc",
    "text": "帮我分析这段代码的性能问题"
  }
}
```

**响应**：

```json
{
  "id": 13,
  "result": {
    "runID": "run_def"
  }
}
```

#### `run/cancel`

取消正在运行的 agent。此操作是幂等的，对已结束的 run 也返回成功。

**请求**：

```json
{
  "id": 14,
  "method": "run/cancel",
  "params": {
    "runID": "run_def"
  }
}
```

**响应**：

```json
{
  "id": 14,
  "result": {}
}
```

#### `run/approve`

响应审批请求。

**请求**：

```json
{
  "id": 15,
  "method": "run/approve",
  "params": {
    "approvalID": "appr_xyz",
    "decision": "approve_once"
  }
}
```

**`decision` 取值**：

- `approve_once`：仅批准本次
- `approve_for_session`：批准整个会话（如果 `allowsSessionApproval` 为 true）
- `decline`：拒绝

**响应**：

```json
{
  "id": 15,
  "result": {}
}
```

#### `run/answer`

回答用户输入请求。

**请求**：

```json
{
  "id": 16,
  "method": "run/answer",
  "params": {
    "requestID": "req_uvw",
    "answers": [
      {
        "questionID": "q1",
        "answers": ["选项 A", "选项 B"]
      }
    ]
  }
}
```

**响应**：

```json
{
  "id": 16,
  "result": {}
}
```

#### `run/compact`

手动触发上下文压缩。

**请求**：

```json
{
  "id": 17,
  "method": "run/compact",
  "params": {
    "sessionID": "sess_abc"
  }
}
```

**响应**：

```json
{
  "id": 17,
  "result": {
    "compaction": {
      "id": "comp_123",
      "status": "running"
    }
  }
}
```

---

## 4. Daemon → Client Events

服务端向客户端发送的事件通知，涵盖流式内容、工具执行、审批流程、上下文用量和运行状态。

### 4.1 流式内容

#### `message.delta`

文本内容增量。

**事件**：

```json
{
  "event": "message.delta",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "delta": "这段代码的时间复杂度是 O(n log n)"
  }
}
```

#### `reasoning.delta`

推理过程增量（仅当模型支持 reasoning 时）。

**事件**：

```json
{
  "event": "reasoning.delta",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "delta": "让我分析一下这个算法的性能瓶颈..."
  }
}
```

### 4.2 工具执行

#### `tool.started`

工具开始执行。

**事件**：

```json
{
  "event": "tool.started",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "toolCallID": "tc_001",
    "toolName": "read_file",
    "arguments": {
      "path": "/Users/dev/project/main.py",
      "lines": [1, 50]
    }
  }
}
```

#### `tool.completed`

工具执行完成。

**事件**：

```json
{
  "event": "tool.completed",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "toolCallID": "tc_001",
    "toolName": "read_file",
    "output": "def main():\n    print('Hello, world!')\n..."
  }
}
```

### 4.3 审批与用户交互

#### `approval.requested`

请求用户审批。

**事件**：

```json
{
  "event": "approval.requested",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "approvalID": "appr_xyz",
    "kind": "command",
    "title": "执行命令",
    "reason": "需要删除临时文件",
    "impact": {
      "type": "command",
      "executable": "rm",
      "arguments": ["-rf", "/tmp/build"],
      "cwd": "/Users/dev/project"
    },
    "fingerprint": "sha256:abc123...",
    "allowsSessionApproval": true
  }
}
```

**`impact` 联合类型**：

`impact` 字段根据 `kind` 不同，包含不同的结构：

**命令执行** (`type: "command"`)：

```json
{
  "type": "command",
  "executable": "git",
  "arguments": ["commit", "-m", "fix bug"],
  "cwd": "/Users/dev/project"
}
```

**文件变更** (`type: "file_change"`)：

```json
{
  "type": "file_change",
  "paths": ["/Users/dev/project/main.py", "/Users/dev/project/utils.py"],
  "summary": "修改了两个文件",
  "diff": "--- a/main.py\n+++ b/main.py\n..."
}
```

**网络访问** (`type: "network"`)：

```json
{
  "type": "network",
  "host": "api.example.com",
  "scheme": "https",
  "port": 443
}
```

**权限请求** (`type: "permission"`)：

```json
{
  "type": "permission",
  "scope": "filesystem_write",
  "description": "需要写入项目目录的权限"
}
```

#### `approval.resolved`

审批已处理。

**事件**：

```json
{
  "event": "approval.resolved",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "approvalID": "appr_xyz",
    "decision": "approve_once"
  }
}
```

#### `user_input.requested`

请求用户输入。

**事件**：

```json
{
  "event": "user_input.requested",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "requestID": "req_uvw",
    "questions": [
      {
        "id": "q1",
        "header": "选择优化策略",
        "question": "你希望采用哪种优化方式？",
        "options": [
          {
            "id": "opt1",
            "label": "缓存结果",
            "description": "使用内存缓存减少重复计算"
          },
          {
            "id": "opt2",
            "label": "算法优化",
            "description": "改用更高效的算法"
          }
        ],
        "allowsOther": true
      }
    ]
  }
}
```

### 4.4 上下文与用量

#### `context.usage`

上下文用量更新。

**事件**：

```json
{
  "event": "context.usage",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "current": {
      "input": 1500,
      "output": 800,
      "total": 2300,
      "cachedInput": 500,
      "reasoningOutput": 200
    },
    "accumulated": {
      "input": 5000,
      "output": 3000,
      "total": 8000,
      "cachedInput": 2000,
      "reasoningOutput": 1000
    },
    "contextWindow": 64000,
    "source": "provider"
  }
}
```

**字段说明**：

- `current`：当前轮次的用量
- `accumulated`：会话累计用量（可选）
- `contextWindow`：模型上下文窗口大小（可选）
- `source`：用量数据来源
  - `provider`：来自服务商 API
  - `estimate`：本地估算
  - `codex`：来自 Codex 运行时

#### `context.compaction`

上下文压缩状态更新。

**事件**：

```json
{
  "event": "context.compaction",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "id": "comp_123",
    "runtimeKind": "generic",
    "trigger": "automatic",
    "status": "completed",
    "startedAt": "2026-01-20T15:30:00Z",
    "completedAt": "2026-01-20T15:30:05Z",
    "beforeTokens": 50000,
    "afterTokens": 15000
  }
}
```

**字段说明**：

- `runtimeKind`：运行时类型
  - `generic`：通用运行时
  - `codex`：Codex 运行时
- `trigger`：触发方式
  - `automatic`：自动触发
  - `manual`：手动触发
  - `overflow_recovery`：溢出恢复
- `status`：压缩状态
  - `running`：进行中
  - `completed`：已完成
  - `failed`：失败
- `beforeTokens`：压缩前 token 数（可选）
- `afterTokens`：压缩后 token 数（可选）
- `errorMessage`：错误信息（失败时）

### 4.5 运行状态

#### `run.state`

运行状态变更。

**事件**：

```json
{
  "event": "run.state",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "state": "running"
  }
}
```

**`state` 取值**：

- `connecting`：正在连接
- `running`：正在运行
- `waiting_for_tool`：等待工具执行
- `waiting_for_approval`：等待用户审批
- `waiting_for_user_input`：等待用户输入
- `cancelling`：正在取消

#### `run.completed`

运行成功完成。这是三个终止事件之一，一次 run 恰好发射其中一个。

**事件**：

```json
{
  "event": "run.completed",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc"
  }
}
```

#### `run.failed`

运行失败。这是三个终止事件之一。

**事件**：

```json
{
  "event": "run.failed",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc",
    "error": {
      "code": "context_overflow",
      "message": "上下文窗口已满，无法继续",
      "recoverySuggestion": "请尝试压缩上下文或开始新会话",
      "retryable": false
    }
  }
}
```

**`error.code` 取值**：

- `generic`：通用错误
- `no_text_output`：无文本输出
- `context_overflow`：上下文溢出
- `context_compaction_failed`：上下文压缩失败

#### `run.cancelled`

运行已取消。这是三个终止事件之一。

**事件**：

```json
{
  "event": "run.cancelled",
  "data": {
    "runID": "run_def",
    "sessionID": "sess_abc"
  }
}
```

---

## 5. Response 格式

所有 Response 消息遵循统一格式。

### 5.1 成功响应

```json
{
  "id": 1,
  "result": {
    "key": "value"
  }
}
```

### 5.2 错误响应

```json
{
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found"
  }
}
```

### 5.3 标准错误码

| 错误码 | 含义 | 说明 |
|--------|------|------|
| `-32601` | Method not found | 方法不存在 |
| `-32602` | Invalid params | 参数无效 |
| `-32603` | Internal error | 内部错误 |
| `-32000` | Timeout | 请求超时 |

---

## 6. 协议设计原则

### 6.1 终止事件保证

一次 run 恰好发射一个终止事件（`run.completed`、`run.failed` 或 `run.cancelled`）。客户端可以依赖这个不变量来清理状态和更新 UI。

### 6.2 Event 不要求回复

所有 Event 消息都是单向通知，客户端无需发送 Response。这简化了协议实现，避免了不必要的事务管理。

### 6.3 Request 超时

所有 Request 默认超时时间为 30 秒。超时后，发送方应收到错误码 `-32000` 的 Response。

### 6.4 幂等性

`run/cancel` 操作是幂等的。对已结束的 run（无论是成功、失败还是已取消）调用 `run/cancel` 都返回成功响应。这简化了客户端的重试逻辑。

### 6.5 版本协商

协议版本在 `initialize` 阶段协商。客户端发送支持的 `protocolVersion`，服务端回复实际使用的版本。如果版本不兼容，服务端应返回错误响应并关闭连接。

---

## 7. 连接生命周期

### 7.1 连接建立

1. **客户端连接 Unix socket**
   - 路径：`~/Library/Application Support/disco/disco.sock`
   - 如果 socket 不存在，客户端应启动守护进程或提示用户

2. **客户端发送 initialize request**
   ```json
   {
     "id": 1,
     "method": "initialize",
     "params": {
       "clientInfo": {
         "name": "disco-client",
         "version": "1.0.0"
       },
       "protocolVersion": "v1"
     }
   }
   ```

3. **服务端回复 initialize response**
   ```json
   {
     "id": 1,
     "result": {
       "daemonVersion": "1.0.0",
       "protocolVersion": "v1"
     }
   }
   ```

### 7.2 正常通信

初始化成功后，进入正常通信阶段：

- **客户端 → 服务端**：发送 Request，接收 Response
- **服务端 → 客户端**：发送 Event（无需响应），发送 Response

双方可以并行发送多条消息，无需等待对方响应。

### 7.3 连接关闭

连接可以通过以下方式关闭：

1. **客户端主动关闭**
   - 客户端发送 `shutdown` request
   - 服务端回复 `shutdown` response
   - 服务端清理资源并关闭 socket

2. **服务端检测到客户端断开**
   - 客户端进程退出或崩溃
   - 服务端检测到 socket 断开
   - 服务端清理该客户端关联的资源（运行中的 agent、会话等）

### 7.4 错误处理

- 如果 `initialize` 失败，服务端应关闭连接
- 如果协议版本不兼容，服务端应返回错误并关闭连接
- 如果 socket 意外断开，双方应清理本地状态
- 客户端可以重新连接并发送新的 `initialize` 请求

---

## 附录 A：完整消息流示例

以下是一个典型的 agent 运行消息流：

```
Client → Server: initialize request (id: 1)
Server → Client: initialize response (id: 1)

Client → Server: session/create request (id: 2)
Server → Client: session/create response (id: 2)

Client → Server: run/start request (id: 3)
Server → Client: run/start response (id: 3)

Server → Client: run.state event (state: "connecting")
Server → Client: run.state event (state: "running")

Server → Client: reasoning.delta event
Server → Client: reasoning.delta event
Server → Client: message.delta event
Server → Client: message.delta event

Server → Client: tool.started event
Server → Client: tool.completed event

Server → Client: context.usage event

Server → Client: message.delta event

Server → Client: run.state event (state: "cancelling")
Server → Client: run.cancelled event
```

---

## 附录 B：JSON Schema 参考

本协议的完整 JSON Schema 定义请参考 `docs/dap-schema.json`（待生成）。

---

## 版本历史

- **v1**（2026-01）：初始版本，支持多模型 agent 运行、流式内容、工具执行、审批流程、上下文压缩
