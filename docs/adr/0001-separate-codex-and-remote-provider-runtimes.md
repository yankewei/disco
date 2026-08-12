---
status: proposed
---

# Separate Codex and remote Provider Runtimes

Disco will keep Codex on the local Codex app-server and execute remote API Providers, including OpenCode Go, through Rig. This preserves Codex-native thread, approval, tool, and file-change behavior while giving subscription and API-key Providers one portable execution path; directly reimplementing every remote protocol would duplicate provider quirks, while routing Codex through Rig would discard useful app-server semantics.

## Consequences

- The conversation layer must dispatch each turn to the Runtime owned by the selected Provider.
- Both Runtimes must project their output into the same Disco run-event vocabulary without pretending their native capabilities are identical.
- OpenCode Go uses Rig's OpenAI-compatible client because Rig 0.41.0 has no dedicated OpenCode Go module.
- Provider capabilities such as streaming, tool calls, reasoning fields, and usage reporting must be verified per Provider and model.
