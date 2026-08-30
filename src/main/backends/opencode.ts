import { spawn } from "node:child_process";
import type { AgentBackend, BackendRunContext } from "./types.js";

export class OpenCodeBackend implements AgentBackend {
  async run({
    backendSessionId,
    workingDirectory,
    prompt,
    signal,
  }: BackendRunContext): Promise<string> {
    const serverProcess = spawn(
      "opencode",
      ["serve", "--hostname", "127.0.0.1", "--port", "4096"],
      { stdio: "ignore", detached: false },
    );

    try {
      const sessionId =
        backendSessionId ??
        (
          await this.request<{ id: string }>("/session", {
            method: "POST",
            body: JSON.stringify({ title: "新对话" }),
          })
        ).id;
      await this.request<unknown>(`/session/${sessionId}/prompt_async`, {
        method: "POST",
        body: JSON.stringify({
          parts: [{ type: "text", text: prompt }],
          directory: workingDirectory,
        }),
        signal,
      });
      return sessionId;
    } finally {
      serverProcess.kill();
    }
  }

  private async request<ResponseBody>(
    endpointPath: string,
    init: RequestInit,
  ): Promise<ResponseBody> {
    const response = await fetch(`http://127.0.0.1:4096${endpointPath}`, {
      ...init,
      headers: { "content-type": "application/json", ...init.headers },
    });
    if (!response.ok) {
      throw new Error(`OpenCode 请求失败：${response.status}`);
    }
    return response.json() as Promise<ResponseBody>;
  }
}
