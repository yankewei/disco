import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
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

  it("迁移旧数据库中的消息字段", () => {
    const folder = mkdtempSync(join(tmpdir(), "disco-store-migration-"));
    folders.push(folder);
    const databasePath = join(folder, "disco.sqlite");
    const legacyDatabase = new Database(databasePath);
    legacyDatabase.exec(`
      CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL
      );
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        backend TEXT NOT NULL,
        backend_session_id TEXT,
        title TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        reasoning TEXT,
        tools_json TEXT,
        created_at TEXT NOT NULL
      );
      INSERT INTO projects VALUES ('p', 'Disco', '/tmp/disco-migration', '2026-01-01T00:00:00.000Z');
      INSERT INTO sessions VALUES ('s', 'p', 'codex', NULL, '旧对话', '2026-01-01T00:00:00.000Z');
      INSERT INTO messages VALUES ('m', 's', 'assistant', '旧消息', NULL, NULL, '2026-01-01T00:00:00.000Z');
    `);
    legacyDatabase.close();

    const store = new DiscoStore(databasePath);
    expect(store.messages("s")).toEqual([
      {
        id: "m",
        role: "assistant",
        text: "旧消息",
        createdAt: "2026-01-01T00:00:00.000Z",
      },
    ]);
    store.close();
  });

  it("保存运行失败和取消状态", () => {
    const folder = mkdtempSync(join(tmpdir(), "disco-store-status-"));
    folders.push(folder);
    const store = new DiscoStore(join(folder, "disco.sqlite"));
    const project = {
      id: "p",
      name: "Disco",
      path: "/tmp/disco-status",
      createdAt: "2026-01-01T00:00:00.000Z",
    };
    store.createProject(project);
    store.createSession({
      sessionId: "s",
      projectId: "p",
      backend: "claude",
      title: "新对话",
      updatedAt: project.createdAt,
    });

    store.appendMessage("s", {
      id: "m-cancelled",
      role: "assistant",
      text: "部分输出",
      status: "cancelled",
      createdAt: project.createdAt,
    });
    store.appendMessage("s", {
      id: "m-failed",
      role: "assistant",
      text: "",
      status: "failed",
      error: "服务不可用",
      createdAt: project.createdAt,
    });

    expect(store.messages("s")).toEqual([
      {
        id: "m-cancelled",
        role: "assistant",
        text: "部分输出",
        status: "cancelled",
        createdAt: project.createdAt,
      },
      {
        id: "m-failed",
        role: "assistant",
        text: "",
        status: "failed",
        error: "服务不可用",
        createdAt: project.createdAt,
      },
    ]);
    store.close();
  });
});
