import type { ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import type { BackendRunContext } from "./types.js";
import { OpenCodeBackend } from "./opencode.js";

function eventData(event: Record<string, unknown>): string {
  return `data: ${JSON.stringify({ payload: event })}\n\n`;
}

function createFakeProcess(): ChildProcess {
  const childProcess = new EventEmitter() as ChildProcess;
  let exitCode: number | null = null;
  Object.defineProperty(childProcess, "exitCode", {
    get: () => exitCode,
  });
  childProcess.kill = vi.fn(() => {
    exitCode = 0;
    childProcess.emit("exit", 0, null);
    return true;
  });
  return childProcess;
}

describe("OpenCodeBackend", () => {
  it("等待 prompt_async 对应的 SSE 空闲事件并转发输出", async () => {
    const fakeProcess = createFakeProcess();
    const encoder = new TextEncoder();
    const eventBody = new ReadableStream<Uint8Array>({
      start(controller) {
        setTimeout(() => {
          controller.enqueue(
            encoder.encode(
              eventData({
                type: "message.updated",
                properties: {
                  sessionID: "ses_test",
                  info: { id: "msg_assistant", role: "assistant" },
                },
              }),
            ),
          );
          controller.enqueue(
            encoder.encode(
              eventData({
                type: "message.part.delta",
                properties: {
                  sessionID: "ses_test",
                  messageID: "msg_assistant",
                  partID: "prt_text",
                  field: "text",
                  delta: "完成",
                },
              }),
            ),
          );
          controller.enqueue(
            encoder.encode(
              eventData({
                type: "session.idle",
                properties: { sessionID: "ses_test" },
              }),
            ),
          );
          controller.close();
        }, 0);
      },
    });
    const fetchImplementation = vi.fn(async (url: string) => {
      if (url.endsWith("/global/health")) {
        return new Response("{}", { status: 200 });
      }
      if (url.includes("/session?")) {
        return new Response(JSON.stringify({ id: "ses_test" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      if (url.includes("/event?")) {
        return new Response(eventBody, {
          status: 200,
          headers: { "content-type": "text/event-stream" },
        });
      }
      if (url.includes("/prompt_async?")) {
        return new Response(null, { status: 204 });
      }
      throw new Error(`未预期的请求：${url}`);
    });
    const spawnProcess = vi.fn(() => fakeProcess);
    const emittedEvents: unknown[] = [];
    const context: BackendRunContext = {
      workingDirectory: "/tmp/project",
      prompt: "执行任务",
      mode: "agent",
      emit: (event) => emittedEvents.push(event),
      signal: new AbortController().signal,
      requestApproval: async () => "approved",
    };
    const backend = new OpenCodeBackend({
      executablePath: "/tmp/opencode",
      fetchImplementation: fetchImplementation as unknown as typeof fetch,
      spawnProcess:
        spawnProcess as unknown as typeof import("node:child_process").spawn,
    });

    await expect(backend.run(context)).resolves.toBe("ses_test");
    expect(emittedEvents).toEqual([{ type: "text", text: "完成" }]);
    expect(fetchImplementation).toHaveBeenCalledWith(
      expect.stringContaining("/prompt_async?directory="),
      expect.objectContaining({ method: "POST" }),
    );
    expect(spawnProcess).toHaveBeenCalledWith(
      "/tmp/opencode",
      expect.arrayContaining(["serve", "--port"]),
      expect.objectContaining({ cwd: "/tmp/project" }),
    );
    expect(fakeProcess.kill).toHaveBeenCalled();
  });

  it("将 OpenCode 权限请求转换为审批拒绝回复", async () => {
    const fakeProcess = createFakeProcess();
    const encoder = new TextEncoder();
    const eventBody = new ReadableStream<Uint8Array>({
      start(controller) {
        setTimeout(() => {
          const events = [
            {
              type: "message.updated",
              properties: {
                sessionID: "ses_test",
                info: { id: "msg_assistant", role: "assistant" },
              },
            },
            {
              type: "permission.v2.asked",
              properties: {
                id: "per_test",
                sessionID: "ses_test",
                action: "file.write",
                resources: ["src/**"],
                metadata: { title: "写入文件" },
              },
            },
            {
              type: "session.idle",
              properties: { sessionID: "ses_test" },
            },
          ];
          controller.enqueue(encoder.encode(events.map(eventData).join("")));
          controller.close();
        }, 0);
      },
    });
    let permissionReply: string | undefined;
    const fetchImplementation = vi.fn(
      async (url: string, init?: RequestInit) => {
        if (url.endsWith("/global/health")) {
          return new Response("{}", { status: 200 });
        }
        if (url.includes("/event?")) {
          return new Response(eventBody, {
            status: 200,
            headers: { "content-type": "text/event-stream" },
          });
        }
        if (url.includes("/prompt_async?")) {
          return new Response(null, { status: 204 });
        }
        if (
          url.includes("/api/session/ses_test/permission/per_test/reply?")
        ) {
          permissionReply = JSON.parse(String(init?.body)).reply as string;
          return new Response("true", { status: 200 });
        }
        throw new Error(`未预期的请求：${url}`);
      },
    );
    const context: BackendRunContext = {
      backendSessionId: "ses_test",
      workingDirectory: "/tmp/project",
      prompt: "写文件",
      mode: "agent",
      emit: () => {},
      signal: new AbortController().signal,
      requestApproval: async (toolName, title, input) => {
        expect(toolName).toBe("file.write");
        expect(title).toBe("写入文件");
        expect(input).toMatchObject({ patterns: ["src/**"] });
        return "denied";
      },
    };
    const backend = new OpenCodeBackend({
      executablePath: "/tmp/opencode",
      fetchImplementation: fetchImplementation as unknown as typeof fetch,
      spawnProcess:
        vi.fn(() => fakeProcess) as unknown as typeof import("node:child_process").spawn,
    });

    await expect(backend.run(context)).resolves.toBe("ses_test");
    expect(permissionReply).toBe("reject");
  });
});
