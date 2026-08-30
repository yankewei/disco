import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DiscoStore } from "./store.js";

const folders: string[] = [];
afterEach(() => folders.splice(0).forEach((folder) => rmSync(folder, { recursive: true, force: true })));
describe("DiscoStore", () => {
  it("stores a project, session and mirrored message", () => {
    const folder = mkdtempSync(join(tmpdir(), "disco-store-")); folders.push(folder);
    const store = new DiscoStore(join(folder, "disco.sqlite"));
    const project = { id: "p", name: "Disco", path: "/tmp/disco", createdAt: "2026-01-01T00:00:00.000Z" };
    store.createProject(project); store.createSession({ sessionId: "s", projectId: "p", backend: "codex", title: "新对话", updatedAt: project.createdAt });
    store.appendMessage("s", { id: "m", role: "user", text: "你好", createdAt: project.createdAt });
    expect(store.listProjects()).toEqual([project]);
    expect(store.messages("s")[0]?.text).toBe("你好");
    store.close();
  });
});
