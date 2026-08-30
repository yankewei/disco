import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DiscoStore } from "./store.js";

const folders: string[] = [];

afterEach(() => {
  for (const folder of folders.splice(0)) {
    rmSync(folder, { recursive: true, force: true });
  }
});

describe("DiscoStore", () => {
  it("保存项目、会话和完整消息镜像", () => {
    const folder = mkdtempSync(join(tmpdir(), "disco-store-"));
    folders.push(folder);
    const store = new DiscoStore(join(folder, "disco.sqlite"));
    const project = {
      id: "p",
      name: "Disco",
      path: "/tmp/disco",
      createdAt: "2026-01-01T00:00:00.000Z",
    };
    store.createProject(project);
    store.createSession({
      sessionId: "s",
      projectId: "p",
      backend: "codex",
      title: "新对话",
      updatedAt: project.createdAt,
    });
    store.appendMessage("s", {
      id: "m",
      role: "assistant",
      text: "完成",
      reasoning: "检查文件",
      toolCalls: [
        {
          id: "tool",
          name: "读取文件",
          status: "completed",
          output: "README.md",
        },
      ],
      items: [
        {
          id: "item-text",
          type: "text",
          text: "完成",
          state: "completed",
        },
        {
          id: "item-file",
          type: "file_change",
          changes: [{ path: "README.md", kind: "update" }],
          state: "completed",
        },
      ],
      createdAt: project.createdAt,
    });

    expect(store.listProjects()).toEqual([project]);
    expect(store.listSessions("p")).toHaveLength(1);
    expect(store.messages("s")).toEqual([
      {
        id: "m",
        role: "assistant",
        text: "完成",
        reasoning: "检查文件",
        toolCalls: [
          {
            id: "tool",
            name: "读取文件",
            status: "completed",
            output: "README.md",
          },
        ],
        items: [
          {
            id: "item-text",
            type: "text",
            text: "完成",
            state: "completed",
          },
          {
            id: "item-file",
            type: "file_change",
            changes: [{ path: "README.md", kind: "update" }],
            state: "completed",
          },
        ],
        createdAt: project.createdAt,
      },
    ]);
    store.close();
  });
});
