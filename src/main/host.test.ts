import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { AgentEvent, BackendKind } from "../shared/types.js";
import { AgentHost } from "./host.js";
import { DiscoStore } from "./store.js";
import type { AgentBackend, BackendRunContext } from "./backends/types.js";

const temporaryFolders: string[] = [];

function createBackend(
  run: (context: BackendRunContext) => Promise<string>,
): AgentBackend {
  return { supportsPlan: true, run };
}

function createBackends(codex: AgentBackend): Record<BackendKind, AgentBackend> {
  return { codex, claude: codex, opencode: codex };
}

function createSession(store: DiscoStore): string {
  store.createProject({
    id: "project",
    name: "测试项目",
    path: "/tmp/test-project",
    createdAt: "2026-01-01T00:00:00.000Z",
  });
  store.createSession({
    sessionId: "session",
    projectId: "project",
    backend: "codex",
    title: "新对话",
    updatedAt: "2026-01-01T00:00:00.000Z",
  });
  return "session";
}

function createStore(): DiscoStore {
  const folder = mkdtempSync(join(tmpdir(), "disco-host-"));
  temporaryFolders.push(folder);
  return new DiscoStore(join(folder, "disco.sqlite"));
}

afterEach(() => {
  for (const folder of temporaryFolders.splice(0)) {
    rmSync(folder, { recursive: true, force: true });
  }
});

describe("AgentHost", () => {
  it("在失败和部分输出时仍保存 assistant 结果", async () => {
    const store = createStore();
    createSession(store);
    const events: AgentEvent[] = [];
    const host = new AgentHost(
      store,
      (event) => events.push(event),
      createBackends(
        createBackend(async ({ emit, onBackendSessionId }) => {
          onBackendSessionId?.("early-session");
          emit({ type: "text", text: "已经完成一半" });
          throw new Error("后端失败");
        }),
      ),
    );

    await host.prompt("session", "执行任务", "agent");

    expect(events.at(-1)).toMatchObject({
      type: "run-finished",
      status: "failed",
      error: "后端失败",
    });
    expect(store.getSession("session")?.backendSessionId).toBe(
      "early-session",
    );
    expect(store.messages("session")).toEqual([
      expect.objectContaining({ role: "user", text: "执行任务" }),
      expect.objectContaining({
        role: "assistant",
        text: "已经完成一半",
        status: "failed",
        error: "后端失败",
      }),
    ]);
    store.close();
  });

  it("取消运行时保存已产生的内容并结束运行", async () => {
    const store = createStore();
    createSession(store);
    const events: AgentEvent[] = [];
    const host = new AgentHost(
      store,
      (event) => events.push(event),
      createBackends(
        createBackend(
          ({ emit, signal }) =>
            new Promise<string>((_resolve, reject) => {
              emit({ type: "text", text: "正在处理" });
              signal.addEventListener("abort", () => reject(new Error("已中止")), {
                once: true,
              });
            }),
        ),
      ),
    );

    const promptPromise = host.prompt("session", "长任务", "agent");
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    host.cancel("session");
    await promptPromise;

    expect(events.at(-1)).toMatchObject({
      type: "run-finished",
      status: "cancelled",
    });
    expect(store.messages("session")).toEqual([
      expect.objectContaining({ role: "user", text: "长任务" }),
      expect.objectContaining({
        role: "assistant",
        text: "正在处理",
        status: "cancelled",
      }),
    ]);
    store.close();
  });

  it("把审批请求和决定关联到同一次运行", async () => {
    const store = createStore();
    createSession(store);
    const events: AgentEvent[] = [];
    const host = new AgentHost(
      store,
      (event) => events.push(event),
      createBackends(
        createBackend(async ({ requestApproval, emit }) => {
          const decision = await requestApproval(
            "Bash",
            "执行命令",
            { command: "pwd" },
          );
          emit({ type: "text", text: decision });
          return "backend-session";
        }),
      ),
    );

    const promptPromise = host.prompt("session", "检查目录", "agent");
    for (let attempt = 0; attempt < 20; attempt += 1) {
      if (events.some((event) => event.type === "approval-requested")) {
        break;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
    const approval = events.find(
      (event) => event.type === "approval-requested",
    );
    if (!approval || approval.type !== "approval-requested") {
      throw new Error("审批请求未产生");
    }
    host.approve(approval.approvalId, "approved");
    await promptPromise;

    expect(events).toContainEqual(
      expect.objectContaining({
        type: "approval-resolved",
        approvalId: approval.approvalId,
        runId: approval.runId,
      }),
    );
    expect(events.at(-1)).toMatchObject({
      type: "run-finished",
      status: "completed",
    });
    expect(store.getSession("session")?.backendSessionId).toBe(
      "backend-session",
    );
    store.close();
  });

});
