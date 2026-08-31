import type { MessageItem, MessageItemState } from "../../shared/types.js";
import {
  CodexAppServer,
  type AppServerNotification,
  type AppServerRequest,
  type CodexAppServerClient,
} from "./codexAppServer.js";
import type { AgentBackend, BackendEvent, BackendRunContext } from "./types.js";

interface ActiveTurn {
  threadId: string;
  turnId?: string;
  emit: (event: BackendEvent) => void;
  requestApproval: BackendRunContext["requestApproval"];
  signal: AbortSignal;
  resolve: () => void;
  reject: (error: Error) => void;
  items: Map<string, MessageItem>;
  streamedTextItemIds: Set<string>;
  streamedReasoningItemIds: Set<string>;
  planItemId?: string;
}

export class CodexBackend implements AgentBackend {
  readonly supportsPlan = true;
  private readonly activeTurns = new Map<string, ActiveTurn>();
  private readonly removeNotificationHandler: () => void;
  private readonly removeServerRequestHandler: () => void;
  private readonly removeErrorHandler: () => void;

  constructor(
    private readonly appServer: CodexAppServerClient = new CodexAppServer(),
  ) {
    this.removeNotificationHandler = appServer.onNotification(
      (notification) => this.handleNotification(notification),
    );
    this.removeServerRequestHandler = appServer.onServerRequest((request) =>
      this.handleServerRequest(request),
    );
    this.removeErrorHandler = appServer.onError((error) =>
      this.handleTransportError(error),
    );
  }

  async run({
    backendSessionId,
    modelId,
    reasoningEffort,
    sandboxMode,
    workingDirectory,
    prompt,
    mode,
    emit,
    signal,
    onBackendSessionId,
    requestApproval,
  }: BackendRunContext): Promise<string> {
    if (signal.aborted) {
      throw new Error("运行已取消");
    }

    const sandbox =
      mode === "plan" ? "read-only" : sandboxMode ?? "workspace-write";
    const approvalPolicy = mode === "plan" ? "never" : "on-request";
    const threadParams = {
      cwd: workingDirectory,
      approvalPolicy,
      sandbox,
      ...(modelId ? { model: modelId } : {}),
    } as const;
    const thread = backendSessionId
      ? await this.appServer.resumeThread({
          threadId: backendSessionId,
          ...threadParams,
        })
      : await this.appServer.startThread(threadParams);
    const threadId = thread.thread.id;
    onBackendSessionId?.(threadId);

    let resolveCompletion: () => void = () => {};
    let rejectCompletion: (error: Error) => void = () => {};
    const completion = new Promise<void>((resolve, reject) => {
      resolveCompletion = resolve;
      rejectCompletion = (error) => reject(error);
    });
    const activeTurn: ActiveTurn = {
      threadId,
      emit,
      requestApproval,
      signal,
      resolve: resolveCompletion,
      reject: rejectCompletion,
      items: new Map(),
      streamedTextItemIds: new Set(),
      streamedReasoningItemIds: new Set(),
    };
    this.activeTurns.set(threadId, activeTurn);

    const interruptTurn = (): void => {
      const turnId = activeTurn.turnId;
      if (!turnId) {
        return;
      }
      void this.appServer
        .interruptTurn({ threadId, turnId })
        .catch((error: unknown) => activeTurn.reject(toError(error)));
    };
    signal.addEventListener("abort", interruptTurn, { once: true });

    try {
      const turn = await this.appServer.startTurn({
        threadId,
        input: [{ type: "text", text: prompt }],
        ...(reasoningEffort ? { effort: reasoningEffort } : {}),
      });
      activeTurn.turnId = turn.turn.id;
      if (signal.aborted) {
        interruptTurn();
      }
      await completion;
      if (signal.aborted) {
        throw new Error("运行已取消");
      }
      return threadId;
    } finally {
      signal.removeEventListener("abort", interruptTurn);
      if (this.activeTurns.get(threadId) === activeTurn) {
        this.activeTurns.delete(threadId);
      }
    }
  }

  async shutdown(): Promise<void> {
    for (const activeTurn of this.activeTurns.values()) {
      activeTurn.reject(new Error("Disco 正在关闭"));
    }
    this.activeTurns.clear();
    this.removeNotificationHandler();
    this.removeServerRequestHandler();
    this.removeErrorHandler();
    await this.appServer.shutdown();
  }

  private handleNotification(notification: AppServerNotification): void {

    const params = recordValue(notification.params);
    const threadId = stringValue(params?.threadId);
    if (!params || !threadId) {
      return;
    }
    const activeTurn = this.activeTurns.get(threadId);
    if (!activeTurn) {
      return;
    }

    switch (notification.method) {
      case "turn/started":
        this.handleTurnStarted(activeTurn, params);
        return;
      case "turn/completed":
        this.handleTurnCompleted(activeTurn, params);
        return;
      case "error":
        this.handleTurnError(activeTurn, params);
        return;
      case "item/started":
      case "item/updated":
      case "item/completed":
        this.handleItemNotification(
          activeTurn,
          notification.method,
          params,
        );
        return;
      case "item/agentMessage/delta":
        this.handleAgentMessageDelta(activeTurn, params);
        return;
      case "item/reasoning/summaryTextDelta":
      case "item/reasoning/textDelta":
        this.handleReasoningDelta(activeTurn, params);
        return;
      case "item/commandExecution/outputDelta":
      case "command/exec/outputDelta":
      case "process/outputDelta":
        this.handleCommandOutputDelta(activeTurn, params);
        return;
      case "turn/plan/updated":
        this.handlePlanUpdated(activeTurn, params);
        return;
      default:
        return;
    }
  }

  private handleTurnStarted(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): void {
    const turn = recordValue(params.turn);
    const turnId = stringValue(turn?.id);
    if (turnId) {
      activeTurn.turnId = turnId;
    }
  }

  private handleTurnCompleted(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): void {
    const turn = recordValue(params.turn);
    const turnId = stringValue(turn?.id);
    if (activeTurn.turnId && turnId && activeTurn.turnId !== turnId) {
      return;
    }
    if (!activeTurn.turnId && turnId) {
      activeTurn.turnId = turnId;
    }
    const status = stringValue(turn?.status);
    if (status === "completed") {
      activeTurn.resolve();
      return;
    }
    if (status === "interrupted") {
      activeTurn.reject(new Error("运行已取消"));
      return;
    }
    const error = recordValue(turn?.error);
    activeTurn.reject(
      new Error(stringValue(error?.message) ?? "Codex turn 执行失败"),
    );
  }

  private handleTurnError(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): void {
    if (params.willRetry === true) {
      return;
    }
    const error = recordValue(params.error);
    activeTurn.reject(
      new Error(stringValue(error?.message) ?? "Codex app-server 执行失败"),
    );
  }

  private handleItemNotification(
    activeTurn: ActiveTurn,
    method: string,
    params: Record<string, unknown>,
  ): void {
    const item = recordValue(params.item);
    if (!item) {
      return;
    }
    const itemType = stringValue(item.type);
    const itemId = stringValue(item.id);
    if (!itemType || !itemId) {
      return;
    }
    if (itemType === "plan") {
      activeTurn.planItemId ??= itemId;
    }
    let state: MessageItemState;
    if (method === "item/started") {
      state = "started";
    } else if (method === "item/completed") {
      state = "completed";
    } else {
      state = "updated";
    }

    if (itemType === "agentMessage") {
      if (
        method === "item/completed" &&
        !activeTurn.streamedTextItemIds.has(itemId)
      ) {
        const messageItem = toMessageItem(item, state);
        if (messageItem) {
          this.emitItem(activeTurn, messageItem);
        }
      }
      return;
    }
    if (itemType === "reasoning") {
      if (
        method === "item/completed" &&
        !activeTurn.streamedReasoningItemIds.has(itemId)
      ) {
        const messageItem = toMessageItem(item, state);
        if (messageItem) {
          this.emitItem(activeTurn, messageItem);
        }
      }
      return;
    }

    const messageItem = toMessageItem(
      item,
      state,
      itemType === "plan" ? activeTurn.planItemId : undefined,
    );
    if (messageItem) {
      this.emitItem(activeTurn, messageItem);
    }
  }

  private handleAgentMessageDelta(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): void {
    const itemId = stringValue(params.itemId);
    const delta = stringValue(params.delta);
    if (!itemId || !delta) {
      return;
    }
    activeTurn.streamedTextItemIds.add(itemId);
    activeTurn.emit({ type: "text", text: delta });
  }

  private handleReasoningDelta(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): void {
    const itemId = stringValue(params.itemId);
    const delta = stringValue(params.delta);
    if (!itemId || !delta) {
      return;
    }
    activeTurn.streamedReasoningItemIds.add(itemId);
    activeTurn.emit({ type: "reasoning", text: delta });
  }

  private handleCommandOutputDelta(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): void {
    const itemId = stringValue(params.itemId);
    const delta = stringValue(params.delta);
    if (!itemId || !delta) {
      return;
    }
    const existingItem = activeTurn.items.get(itemId);
    if (!existingItem || existingItem.type !== "command_execution") {
      return;
    }
    this.emitItem(activeTurn, {
      ...existingItem,
      output: `${existingItem.output}${delta}`,
      state: "updated",
    });
  }

  private handlePlanUpdated(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): void {
    const turnId = stringValue(params.turnId) ?? activeTurn.turnId;
    const plan = Array.isArray(params.plan) ? params.plan : [];
    if (!turnId) {
      return;
    }
    activeTurn.planItemId ??= `plan-${turnId}`;
    this.emitItem(activeTurn, {
      id: activeTurn.planItemId,
      type: "todo_list",
      items: plan.flatMap((step) => {
        const stepRecord = recordValue(step);
        const text = stringValue(stepRecord?.step);
        if (!text) {
          return [];
        }
        return [
          {
            text,
            completed: stringValue(stepRecord?.status) === "completed",
          },
        ];
      }),
      state: "updated",
    });
  }

  private emitItem(activeTurn: ActiveTurn, item: MessageItem): void {
    activeTurn.items.set(item.id, item);
    activeTurn.emit({ type: "item", item });
  }

  private async handleServerRequest(
    request: AppServerRequest,
  ): Promise<unknown> {
    const params = recordValue(request.params);
    const threadId = stringValue(params?.threadId ?? params?.conversationId);
    const activeTurn = threadId ? this.activeTurns.get(threadId) : undefined;
    if (!activeTurn || !params) {
      throw new Error("没有对应的活动 Codex 运行");
    }

    switch (request.method) {
      case "item/commandExecution/requestApproval":
        return this.requestCommandApproval(activeTurn, params);
      case "execCommandApproval":
        return this.requestLegacyCommandApproval(activeTurn, params);
      case "item/fileChange/requestApproval":
        return this.requestFileChangeApproval(activeTurn, params);
      case "applyPatchApproval":
        return this.requestLegacyFileChangeApproval(activeTurn, params);
      case "item/permissions/requestApproval":
        return this.requestPermissionsApproval(activeTurn, params);
      default:
        throw new Error(`不支持 Codex app-server 请求：${request.method}`);
    }
  }

  private async requestCommandApproval(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): Promise<{ decision: "accept" | "decline" }> {
    const command = stringValue(params.command);
    const decision = await activeTurn.requestApproval(
      "Codex 命令执行",
      stringValue(params.reason) ?? "Codex 请求执行命令",
      {
        command,
        cwd: params.cwd,
        reason: params.reason,
        kind: params.kind,
        networkApprovalContext: params.networkApprovalContext,
        commandActions: params.commandActions,
      },
    );
    return { decision: decision === "approved" ? "accept" : "decline" };
  }
  private async requestLegacyCommandApproval(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): Promise<{
    decision:
      | "approved"
      | { denied: { rejection: string } };
  }> {
    const command = stringValue(params.command) ?? stringArray(params.command).join(" ");
    const decision = await activeTurn.requestApproval(
      "Codex 命令执行",
      stringValue(params.reason) ?? "Codex 请求执行命令",
      {
        command,
        cwd: params.cwd,
        reason: params.reason,
        callId: params.callId,
        approvalId: params.approvalId,
        parsedCmd: params.parsedCmd,
      },
    );
    if (decision === "approved") {
      return { decision: "approved" };
    }
    return { decision: { denied: { rejection: "用户拒绝" } } };
  }

  private async requestFileChangeApproval(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): Promise<{ decision: "accept" | "decline" }> {
    const decision = await activeTurn.requestApproval(
      "Codex 文件变更",
      stringValue(params.reason) ?? "Codex 请求修改文件",
      {
        reason: params.reason,
        grantRoot: params.grantRoot,
      },
    );
    return { decision: decision === "approved" ? "accept" : "decline" };
  }
  private async requestLegacyFileChangeApproval(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): Promise<{
    decision:
      | "approved"
      | { denied: { rejection: string } };
  }> {
    const decision = await activeTurn.requestApproval(
      "Codex 文件变更",
      stringValue(params.reason) ?? "Codex 请求修改文件",
      {
        reason: params.reason,
        grantRoot: params.grantRoot,
        callId: params.callId,
        fileChanges: params.fileChanges,
      },
    );
    if (decision === "approved") {
      return { decision: "approved" };
    }
    return { decision: { denied: { rejection: "用户拒绝" } } };
  }

  private async requestPermissionsApproval(
    activeTurn: ActiveTurn,
    params: Record<string, unknown>,
  ): Promise<{
    permissions: Record<string, unknown>;
    scope: "turn";
  }> {
    const decision = await activeTurn.requestApproval(
      "Codex 权限请求",
      stringValue(params.reason) ?? "Codex 请求额外权限",
      {
        cwd: params.cwd,
        reason: params.reason,
        permissions: params.permissions,
      },
    );
    return {
      permissions:
        decision === "approved"
          ? grantedPermissions(params.permissions)
          : {},
      scope: "turn",
    };
  }

  private handleTransportError(error: Error): void {
    for (const activeTurn of this.activeTurns.values()) {
      activeTurn.reject(error);
    }
  }
}

function toMessageItem(
  item: Record<string, unknown>,
  state: MessageItemState,
  idOverride?: string,
): MessageItem | undefined {
  const id = idOverride ?? stringValue(item.id);
  const itemType = stringValue(item.type);
  if (!id || !itemType) {
    return undefined;
  }

  switch (itemType) {
    case "agentMessage":
      return { id, type: "text", text: stringValue(item.text) ?? "", state };
    case "reasoning":
      return {
        id,
        type: "reasoning",
        text: textParts(item.summary, item.content),
        state,
      };
    case "commandExecution":
      return {
        id,
        type: "command_execution",
        command: stringValue(item.command) ?? "",
        output: stringValue(item.aggregatedOutput) ?? "",
        state: commandState(item.status),
      };
    case "fileChange":
      return {
        id,
        type: "file_change",
        changes: fileChanges(item.changes),
        state: fileChangeState(item.status),
      };
    case "mcpToolCall":
      return {
        id,
        type: "mcp_tool_call",
        server: stringValue(item.server) ?? "",
        tool: stringValue(item.tool) ?? "",
        arguments: item.arguments,
        result: item.result,
        error: errorText(item.error),
        state: mcpToolState(item.status),
      };
    case "webSearch":
      return {
        id,
        type: "web_search",
        query: stringValue(item.query) ?? "",
        state,
      };
    case "plan":
      return {
        id,
        type: "todo_list",
        items: planTextItems(stringValue(item.text) ?? ""),
        state,
      };
    case "error":
      return {
        id,
        type: "error",
        message: stringValue(item.message) ?? "Codex item 执行失败",
        state,
      };
    default:
      return undefined;
  }
}

function textParts(summary: unknown, content: unknown): string {
  const summaryText = stringArray(summary).join("\n");
  if (summaryText) {
    return summaryText;
  }
  return stringArray(content).join("\n");
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((part): part is string => typeof part === "string");
}

function fileChanges(value: unknown): Array<{
  path: string;
  kind: "add" | "delete" | "update";
}> {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.flatMap((change) => {
    const changeRecord = recordValue(change);
    const path = stringValue(changeRecord?.path);
    const kind = stringValue(changeRecord?.kind);
    if (!path || (kind !== "add" && kind !== "delete" && kind !== "update")) {
      return [];
    }
    return [{ path, kind }];
  });
}

function planTextItems(
  text: string,
): Array<{ text: string; completed: boolean }> {
  return text
    .split("\n")
    .map((line) => line.replace(/^\s*(?:[-*]|\d+[.)])\s*/, "").trim())
    .filter((line) => line.length > 0)
    .map((line) => ({ text: line, completed: false }));
}

function grantedPermissions(value: unknown): Record<string, unknown> {
  const permissions = recordValue(value);
  if (!permissions) {
    return {};
  }
  return Object.fromEntries(
    Object.entries(permissions).filter(([, permission]) => permission !== null),
  );
}

function commandState(value: unknown): MessageItemState {
  if (value === "completed" || value === "failed" || value === "declined") {
    return "completed";
  }
  if (value === "inProgress") {
    return "started";
  }
  return "updated";
}

function fileChangeState(value: unknown): MessageItemState {
  if (value === "completed" || value === "failed" || value === "declined") {
    return "completed";
  }
  if (value === "inProgress") {
    return "started";
  }
  return "updated";
}

function mcpToolState(value: unknown): MessageItemState {
  if (value === "completed" || value === "failed") {
    return "completed";
  }
  return "started";
}

function errorText(value: unknown): string | undefined {
  const error = recordValue(value);
  return stringValue(error?.message) ?? stringValue(value);
}


function recordValue(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}
