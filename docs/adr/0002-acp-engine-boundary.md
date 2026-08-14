---
status: proposed
---

# Add ACP as a third execution boundary for local agent clients

Disco executes each Provider through the Runtime that owns its semantics. Today there
are two Runtimes: **Codex** (the local Codex app-server) and **Rig** (remote API
Providers). OpenCode's CLI agent is a third local client that runs its own sandbox,
tools, permissions, and file semantics, so it does not belong on Rig, and it is not the
Codex app-server.

OpenCode exposes two compatible surfaces:

- **`opencode serve`** — a headless HTTP server with a full OpenAPI 3.1 surface over
  sessions, projects, providers, OAuth, and permissions. Designed for programmatic /
  browser clients that want OpenCode itself to own all state.
- **`opencode acp`** — the [Agent Client
  Protocol](https://agentclientprotocol.com) subprocess over stdio JSON-RPC. OpenCode
  runs its internal agent loop and reports plan, message, tool, permission, and usage
  items to a host client; the client owns durable conversation and run state.

Disco is a local macOS app that already owns Tasks, Projects, Keychain credentials,
approvals, and durable `RunEventPayload`s. We choose **ACP** for OpenCode so Disco keeps
ownership of that state, exactly as it does for Codex, instead of delegating it to the
`serve` server and reconciling two authoritative copies.

## Decision

- Introduce `crates/disco-opencode-engine`, an ACP client that spawns
  `opencode acp` as a stdio JSON-RPC subprocess, mirrors the
  `disco-codex-engine` transport and event loop, and projects ACP items into the
  existing Disco run-event vocabulary.
- Build the ACP transport on the official
  [`agent-client-protocol`](https://crates.io/crates/agent-client-protocol) Rust
  SDK (v2, stable v1 protocol) instead of a hand-rolled JSON-RPC layer: the SDK
  owns the connection, typed message parsing, and subprocess lifecycle; the
  engine owns discovery and the projection of typed `session/update`
  notifications into Disco run events.
- Extend the conversation dispatch rules so a "local agent client" Provider runs through
  the new ACP engine rather than through Codex or Rig.

```text
Codex Provider   -> Codex Runtime  -> codex app-server
OpenCode Provider-> Acp Runtime    -> opencode acp     (stdio JSON-RPC)
OpenCode Go      -> Rig Runtime    -> OpenAI-compatible client
DeepSeek         -> Rig Runtime    -> Rig DeepSeek adapter
Kimi             -> Rig Runtime    -> Rig Moonshot adapter
```

- **Not** integrated first release: `opencode serve` HTTP, remote/multi-client hosting,
  OAuth/browser auth, and reusing an OpenCode TUI's running server.

## Consequences

- Disco owns durable run events, approvals, and conversation history; OpenCode runs its
  internal agent, sandbox, and tool loop (same split as Codex).
- The ACP engine must speak the ACP lifecycle: `initialize`, `session/new`,
  `session/prompt`, `session/cancel`, and the `session/update` notification variants
  (`plan`, `agent_message_chunk`, `tool_call`, `tool_call_update`,
  `usage_update`, and permission requests), mapping each into existing
  `RunEventPayload` events.
- The ACP engine depends on a locally installed `opencode` binary and advertises the
  models/permissions OpenCode exposes via `session/config` / session options; Disco
  must present the "OpenCode CLI not installed" case as a first-class error like Codex.
- A Provider launched through ACP does not imply remote subscription access; OpenCode Go
  subscription remains a Rig Provider with its own Keychain credential.
