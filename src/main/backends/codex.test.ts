import { describe, expect, it, vi } from "vitest";
import type {
  AppServerNotification,
  AppServerRequest,
  CodexAppServerClient,
  ThreadResumeParams,
  ThreadStartParams,
  TurnInterruptParams,
  TurnStartParams,
} from "./codexAppServer.js";
import { CodexBackend } from "./codex.js";
import type { BackendRunContext } from "./types.js";

class FakeCodexAppServer implements CodexAppServerClient {
  private notificationHandler:
    | ((notification: AppServerNotification) => void)
    | undefined;
  private serverRequestHandler:
    | ((request: AppServerRequest) => Promise<unknown>)
    | undefined;
  readonly startThread = vi.fn(
    async (params: ThreadStartParams) => ({
      thread: { id: "thread-new" },
      params,
    }),
  );
  readonly resumeThread = vi.fn(
    async (params: ThreadResumeParams) => ({
      thread: { id: params.threadId },
    }),
  );
  readonly startTurn = vi.fn(async (params: TurnStartParams) => ({
    turn: { id: "turn-1" },
    params,
  }));
  readonly interruptTurn = vi.fn(
    async (params: TurnInterruptParams) => {
      this.emitNotification({
        method: "turn/completed",
        params: {
          threadId: params.threadId,
          turn: {
            id: params.turnId,
            status: "interrupted",
          },
        },
      });
      return {};
    },
  );
  readonly shutdown = vi.fn(async () => {});

  onNotification(
    handler: (notification: AppServerNotification) => void,
  ): () => void {
    this.notificationHandler = handler;
    return () => {
      if (this.notificationHandler === handler) {
        this.notificationHandler = undefined;
      }
    };
  }

  onServerRequest(
    handler: (request: AppServerRequest) => Promise<unknown>,
  ): () => void {
    this.serverRequestHandler = handler;
    return () => {
      if (this.serverRequestHandler === handler) {
        this.serverRequestHandler = undefined;
      }
    };
  }

  onError(): () => void {
    return () => {};
  }

  emitNotification(notification: AppServerNotification): void {
    this.notificationHandler?.(notification);
  }

  emitServerRequest(request: AppServerRequest): Promise<unknown> {
    if (!this.serverRequestHandler) {
      throw new Error("未注册 app-server 请求处理器");
    }
    return this.serverRequestHandler(request);
  }
}

function createContext(
  overrides: Partial<BackendRunContext> = {},
): BackendRunContext {
  return {
    workingDirectory: "/tmp/project",
    prompt: "执行任务",
    mode: "agent",
    emit: () => {},
    signal: new AbortController().signal,
    requestApproval: async () => "approved",
    ...overrides,
  };
}

async function waitForTurnStart(
  appServer: FakeCodexAppServer,
): Promise<void> {
  await vi.waitFor(() => expect(appServer.startTurn).toHaveBeenCalled());
}

describe("CodexBackend", () => {
  it("通过 app-server 发送计划模式线程并映射流式事件", async () => {
    const appServer = new FakeCodexAppServer();
    const emittedEvents: unknown[] = [];
    const onBackendSessionId = vi.fn();
    const backend = new CodexBackend(appServer);
    const runPromise = backend.run(
      createContext({
        mode: "plan",
        emit: (event) => emittedEvents.push(event),
        onBackendSessionId,
      }),
    );

    await waitForTurnStart(appServer);
    appServer.emitNotification({
      method: "turn/started",
      params: { threadId: "thread-new", turn: { id: "turn-1" } },
    });
    appServer.emitNotification({
      method: "turn/plan/updated",
      params: {
        threadId: "thread-new",
        turnId: "turn-1",
        plan: [
          { step: "分析需求", status: "completed" },
          { step: "输出计划", status: "inProgress" },
        ],
      },
    });
    appServer.emitNotification({
      method: "item/reasoning/summaryTextDelta",
      params: {
        threadId: "thread-new",
        turnId: "turn-1",
        itemId: "reasoning-1",
        delta: "先分析需求",
      },
    });
    appServer.emitNotification({
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-new",
        turnId: "turn-1",
        itemId: "message-1",
        delta: "计划完成",
      },
    });
    appServer.emitNotification({
      method: "item/completed",
      params: {
        threadId: "thread-new",
        turnId: "turn-1",
        item: {
          type: "agentMessage",
          id: "message-1",
          text: "计划完成",
        },
      },
    });
    appServer.emitNotification({
      method: "turn/completed",
      params: {
        threadId: "thread-new",
        turn: { id: "turn-1", status: "completed" },
      },
    });

    await expect(runPromise).resolves.toBe("thread-new");
    expect(onBackendSessionId).toHaveBeenCalledWith("thread-new");
    expect(appServer.startThread).toHaveBeenCalledWith({
      cwd: "/tmp/project",
      approvalPolicy: "never",
      sandbox: "read-only",
    });
    expect(appServer.startTurn).toHaveBeenCalledWith({
      threadId: "thread-new",
      input: [{ type: "text", text: "执行任务" }],
    });
    expect(emittedEvents).toEqual([
      {
        type: "item",
        item: {
          id: "plan-turn-1",
          type: "todo_list",
          items: [
            { text: "分析需求", completed: true },
            { text: "输出计划", completed: false },
          ],
          state: "updated",
        },
      },
      { type: "reasoning", text: "先分析需求" },
      { type: "text", text: "计划完成" },
    ]);
    await backend.shutdown();
    expect(appServer.shutdown).toHaveBeenCalledOnce();
  });

  it("恢复已有线程并映射命令执行状态", async () => {
    const appServer = new FakeCodexAppServer();
    const emittedEvents: unknown[] = [];
    const backend = new CodexBackend(appServer);
    const runPromise = backend.run(
      createContext({
        backendSessionId: "thread-existing",
        modelId: "o3",
        reasoningEffort: "high",
        sandboxMode: "danger-full-access",
        emit: (event) => emittedEvents.push(event),
      }),
    );

    await waitForTurnStart(appServer);
    appServer.emitNotification({
      method: "item/started",
      params: {
        threadId: "thread-existing",
        turnId: "turn-1",
        item: {
          type: "commandExecution",
          id: "command-1",
          command: "pwd",
          status: "inProgress",
          aggregatedOutput: null,
        },
      },
    });
    appServer.emitNotification({
      method: "item/commandExecution/outputDelta",
      params: {
        threadId: "thread-existing",
        turnId: "turn-1",
        itemId: "command-1",
        delta: "/tmp",
      },
    });
    appServer.emitNotification({
      method: "item/completed",
      params: {
        threadId: "thread-existing",
        turnId: "turn-1",
        item: {
          type: "commandExecution",
          id: "command-1",
          command: "pwd",
          status: "completed",
          aggregatedOutput: "/tmp/project\n",
        },
      },
    });
    appServer.emitNotification({
      method: "turn/completed",
      params: {
        threadId: "thread-existing",
        turn: { id: "turn-1", status: "completed" },
      },
    });

    await expect(runPromise).resolves.toBe("thread-existing");
    expect(appServer.resumeThread).toHaveBeenCalledWith({
      threadId: "thread-existing",
      cwd: "/tmp/project",
      model: "o3",
      approvalPolicy: "on-request",
      sandbox: "danger-full-access",
    });
    expect(appServer.startTurn).toHaveBeenCalledWith({
      threadId: "thread-existing",
      input: [{ type: "text", text: "执行任务" }],
      effort: "high",
    });
    expect(emittedEvents).toEqual([
      {
        type: "item",
        item: {
          id: "command-1",
          type: "command_execution",
          command: "pwd",
          output: "",
          state: "started",
        },
      },
      {
        type: "item",
        item: {
          id: "command-1",
          type: "command_execution",
          command: "pwd",
          output: "/tmp",
          state: "updated",
        },
      },
      {
        type: "item",
        item: {
          id: "command-1",
          type: "command_execution",
          command: "pwd",
          output: "/tmp/project\n",
          state: "completed",
        },
      },
    ]);
  });

  it("将 app-server 命令审批请求转换为 Disco 审批", async () => {
    const appServer = new FakeCodexAppServer();
    const requestApproval = vi.fn(async () => "denied" as const);
    const backend = new CodexBackend(appServer);
    const runPromise = backend.run(createContext({ requestApproval }));

    await waitForTurnStart(appServer);
    await expect(
      appServer.emitServerRequest({
        id: 7,
        method: "item/commandExecution/requestApproval",
        params: {
          threadId: "thread-new",
          turnId: "turn-1",
          itemId: "command-1",
          command: "rm -rf tmp",
          cwd: "/tmp/project",
          reason: "需要删除临时文件",
        },
      }),
    ).resolves.toEqual({ decision: "decline" });
    expect(requestApproval).toHaveBeenCalledWith(
      "Codex 命令执行",
      "需要删除临时文件",
      expect.objectContaining({ command: "rm -rf tmp", cwd: "/tmp/project" }),
    );

    appServer.emitNotification({
      method: "turn/completed",
      params: {
        threadId: "thread-new",
        turn: { id: "turn-1", status: "completed" },
      },
    });
    await expect(runPromise).resolves.toBe("thread-new");
  });

  it("取消运行时中断当前 turn", async () => {
    const appServer = new FakeCodexAppServer();
    const controller = new AbortController();
    const backend = new CodexBackend(appServer);
    const runPromise = backend.run(
      createContext({ signal: controller.signal }),
    );

    await waitForTurnStart(appServer);
    controller.abort();

    await expect(runPromise).rejects.toThrow("运行已取消");
    expect(appServer.interruptTurn).toHaveBeenCalledWith({
      threadId: "thread-new",
      turnId: "turn-1",
    });
  });

});
