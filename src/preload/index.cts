import { contextBridge, ipcRenderer } from "electron";
import type { AgentEvent, DiscoAPI } from "../shared/types.js";

const api: DiscoAPI = {
  listProjects: () => ipcRenderer.invoke("disco:projects"),
  createProject: (path, locale) =>
    ipcRenderer.invoke("disco:create-project", path, locale),
  listSessions: (projectId) => ipcRenderer.invoke("disco:sessions", projectId),
  createSession: (
    projectId,
    backend,
    modelId,
    reasoningEffort,
    sandboxMode,
    locale,
  ) =>
    ipcRenderer.invoke(
      "disco:create-session",
      projectId,
      backend,
      modelId,
      reasoningEffort,
      sandboxMode,
      locale,
    ),
  loadMessages: (sessionId) => ipcRenderer.invoke("disco:messages", sessionId),
  prompt: (sessionId, text, mode, locale) =>
    ipcRenderer.invoke("disco:prompt", sessionId, text, mode, locale),
  cancel: (sessionId) => ipcRenderer.invoke("disco:cancel", sessionId),
  approve: (approvalId, decision) =>
    ipcRenderer.invoke("disco:approve", approvalId, decision),
  providers: (locale) => ipcRenderer.invoke("disco:providers", locale),
  about: () => ipcRenderer.invoke("disco:about"),
  chooseDirectory: () => ipcRenderer.invoke("disco:choose-directory"),
  chooseFiles: (withDirectories) =>
    ipcRenderer.invoke("disco:choose-files", withDirectories),
  onEvent: (listener) => {
    const handler = (_event: Electron.IpcRendererEvent, event: AgentEvent) =>
      listener(event);
    ipcRenderer.on("disco:event", handler);
    return () => ipcRenderer.removeListener("disco:event", handler);
  },
};

contextBridge.exposeInMainWorld("disco", api);
