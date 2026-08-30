import { query } from "@anthropic-ai/claude-agent-sdk";
import type { AgentBackend, BackendRunContext } from "./types.js";

export class ClaudeBackend implements AgentBackend {
  async run({
    backendSessionId,
    workingDirectory,
    prompt,
    mode,
    emit,
    signal,
    requestApproval,
  }: BackendRunContext): Promise<string> {
    const response = query({
      prompt,
      options: {
        cwd: workingDirectory,
        resume: backendSessionId,
        includePartialMessages: true,
        permissionMode: mode === "plan" ? "plan" : "default",
        settingSources: ["user", "project"],
        canUseTool: async (toolName, input, options) => {
          const decision = await requestApproval(
            toolName,
            options.title,
            input,
          );
          if (decision === "approved") {
            return { behavior: "allow" as const };
          }
          return { behavior: "deny" as const, message: "用户拒绝" };
        },
      },
    });
    signal.addEventListener("abort", () => response.close(), { once: true });

    let resolvedSessionId = backendSessionId ?? crypto.randomUUID();
    for await (const message of response) {
      if (
        message.type === "stream_event" &&
        message.event.type === "content_block_delta" &&
        message.event.delta.type === "text_delta"
      ) {
        emit({ type: "text", text: message.event.delta.text });
      }
      if (message.type === "result" && message.subtype !== "success") {
        throw new Error(message.errors.join("\n") || "Claude Code 运行失败");
      }
      if (
        message.type === "result" &&
        message.subtype === "success" &&
        message.is_error
      ) {
        throw new Error(message.result || "Claude Code 运行失败");
      }
      resolvedSessionId = message.session_id ?? resolvedSessionId;
    }

    return resolvedSessionId;
  }
}
