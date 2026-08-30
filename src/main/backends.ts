import { spawn } from "node:child_process";
import { Codex, type ThreadEvent } from "@openai/codex-sdk";
import { query } from "@anthropic-ai/claude-agent-sdk";

export type BackendKind = "codex" | "claude" | "opencode";
export type AgentEvent =
  | { type: "text"; text: string }
  | { type: "reasoning"; text: string }
  | { type: "tool"; id: string; title: string; state: "started" | "completed"; output?: string }
  | { type: "plan"; steps: Array<{ text: string; completed: boolean }> }
  | { type: "usage"; input: number; output: number }
  | { type: "finished"; error?: string };

export type ApprovalDecision = "approved" | "denied";
export type RequestApproval = (id: string, toolName: string, title: string | undefined, input: Record<string, unknown>) => Promise<ApprovalDecision>;

export interface AgentBackend {
  readonly kind: BackendKind;
  run(sessionId: string | undefined, cwd: string, prompt: string, mode: "agent" | "plan", emit: (event: AgentEvent) => void, signal: AbortSignal, requestApproval: RequestApproval): Promise<string>;
}

export class CodexBackend implements AgentBackend {
  readonly kind = "codex" as const;
  async run(sessionId: string | undefined, cwd: string, prompt: string, _mode: "agent" | "plan", emit: (event: AgentEvent) => void, signal: AbortSignal, _requestApproval: RequestApproval) {
    const codex = new Codex();
    const thread = sessionId ? codex.resumeThread(sessionId, { workingDirectory: cwd, approvalPolicy: "never" }) : codex.startThread({ workingDirectory: cwd, approvalPolicy: "never" });
    const streamed = await thread.runStreamed(prompt, { signal });
    for await (const event of streamed.events) this.map(event, emit);
    return thread.id ?? sessionId ?? crypto.randomUUID();
  }
  private map(event: ThreadEvent, emit: (event: AgentEvent) => void) {
    if (event.type === "item.completed" && event.item.type === "agent_message") emit({ type: "text", text: event.item.text });
    if (event.type === "item.completed" && event.item.type === "reasoning") emit({ type: "reasoning", text: event.item.text });
    if ((event.type === "item.started" || event.type === "item.completed") && event.item.type === "command_execution") emit({ type: "tool", id: event.item.id, title: event.item.command, state: event.type === "item.started" ? "started" : "completed", output: event.item.aggregated_output });
    if (event.type === "turn.completed") emit({ type: "usage", input: event.usage.input_tokens, output: event.usage.output_tokens });
    if (event.type === "turn.failed") emit({ type: "finished", error: event.error.message });
    if (event.type === "error") emit({ type: "finished", error: event.message });
  }
}

export class ClaudeBackend implements AgentBackend {
  readonly kind = "claude" as const;
  async run(sessionId: string | undefined, cwd: string, prompt: string, mode: "agent" | "plan", emit: (event: AgentEvent) => void, signal: AbortSignal, requestApproval: RequestApproval) {
    const response = query({ prompt, options: { cwd, resume: sessionId, includePartialMessages: true, permissionMode: mode === "plan" ? "plan" : "default", settingSources: ["user", "project"], canUseTool: async (toolName: string, input: Record<string, unknown>, options: { toolUseID: string; title?: string }) => { const decision = await requestApproval(options.toolUseID, toolName, options.title, input); return decision === "approved" ? { behavior: "allow" as const } : { behavior: "deny" as const, message: "用户拒绝" }; } } });
    signal.addEventListener("abort", () => response.close(), { once: true });
    let id = sessionId ?? crypto.randomUUID();
    for await (const message of response as AsyncIterable<any>) {
      if (message.type === "stream_event" && message.event?.type === "content_block_delta" && message.event.delta?.type === "text_delta") emit({ type: "text", text: message.event.delta.text });
      if (message.type === "assistant") for (const block of message.message.content) if (block.type === "text") emit({ type: "text", text: block.text });
      if (message.session_id) id = message.session_id;
    }
    return id;
  }
}

export class OpenCodeBackend implements AgentBackend {
  readonly kind = "opencode" as const;
  async run(sessionId: string | undefined, cwd: string, prompt: string, _mode: "agent" | "plan", emit: (event: AgentEvent) => void, signal: AbortSignal, _requestApproval: RequestApproval) {
    const server = spawn("opencode", ["serve", "--hostname", "127.0.0.1", "--port", "4096"], { stdio: "ignore", detached: false });
    try {
      const session = sessionId ?? (await this.json("/session", { method: "POST", body: JSON.stringify({ title: "新对话" }) })).id;
      await this.json(`/session/${session}/prompt_async`, { method: "POST", body: JSON.stringify({ parts: [{ type: "text", text: prompt }], directory: cwd }), signal });
      emit({ type: "finished" });
      return session;
    } finally { server.kill(); }
  }
  private async json(path: string, init: RequestInit) { const response = await fetch(`http://127.0.0.1:4096${path}`, { ...init, headers: { "content-type": "application/json", ...init.headers } }); if (!response.ok) throw new Error(`OpenCode 请求失败：${response.status}`); return response.json(); }
}
