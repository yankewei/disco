import { app, BrowserWindow, dialog, ipcMain, shell } from "electron";
import { join } from "node:path";
import { z } from "zod";
import updater from "electron-updater";
import { AgentHost } from "./host.js";
import { DiscoStore } from "./store.js";

const { autoUpdater } = updater;
let window: BrowserWindow | undefined;
let settingsWindow: BrowserWindow | undefined;
let host: AgentHost;
const id = z.string().uuid();
const backend = z.enum(["codex", "claude", "opencode"]);

function createWindow() {
  window = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 960,
    minHeight: 640,
    backgroundColor: "#101312",
    titleBarStyle: "hiddenInset",
    webPreferences: { preload: join(import.meta.dirname, "../preload/index.cjs"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  window.webContents.setWindowOpenHandler(({ url }) => { void shell.openExternal(url); return { action: "deny" }; });
  window.webContents.on("will-navigate", (event, url) => { if (!url.startsWith("file:") && !url.startsWith("http://127.0.0.1:5173")) event.preventDefault(); });
  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) void window.loadURL(devUrl); else void window.loadFile(join(import.meta.dirname, "../../dist-renderer/index.html"));
}

function openSettingsWindow() {
  if (settingsWindow && !settingsWindow.isDestroyed()) { settingsWindow.focus(); return; }
  settingsWindow = new BrowserWindow({
    width: 940,
    height: 660,
    minWidth: 800,
    minHeight: 540,
    backgroundColor: "#fffefc",
    titleBarStyle: "hiddenInset",
    parent: window,
    webPreferences: { preload: join(import.meta.dirname, "../preload/index.cjs"), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  settingsWindow.on("closed", () => { settingsWindow = undefined; });
  settingsWindow.webContents.setWindowOpenHandler(({ url }) => { void shell.openExternal(url); return { action: "deny" }; });
  settingsWindow.webContents.on("will-navigate", (event, url) => { if (!url.startsWith("file:") && !url.startsWith("http://127.0.0.1:5173")) event.preventDefault(); });
  const devUrl = process.env.VITE_DEV_SERVER_URL;
  if (devUrl) void settingsWindow.loadURL(`${devUrl}#settings`); else void settingsWindow.loadFile(join(import.meta.dirname, "../../dist-renderer/index.html"), { hash: "settings" });
}

ipcMain.handle("disco:projects", () => host.listProjects());
ipcMain.handle("disco:create-project", (_event, path: unknown) => host.createProject(z.string().min(1).parse(path)));
ipcMain.handle("disco:delete-project", (_event, projectId: unknown) => host.deleteProject(id.parse(projectId)));
ipcMain.handle("disco:sessions", (_event, projectId: unknown) => host.listSessions(projectId === undefined ? undefined : id.parse(projectId)));
ipcMain.handle("disco:create-session", (_event, projectId: unknown, kind: unknown) => host.createSession(id.parse(projectId), backend.parse(kind)));
ipcMain.handle("disco:delete-session", (_event, sessionId: unknown) => host.deleteSession(id.parse(sessionId)));
ipcMain.handle("disco:messages", (_event, sessionId: unknown) => host.messages(id.parse(sessionId)));
ipcMain.handle("disco:prompt", (_event, sessionId: unknown, text: unknown, mode: unknown) => { void host.prompt(id.parse(sessionId), z.string().trim().min(1).max(100_000).parse(text), z.enum(["agent", "plan"]).parse(mode)); });
ipcMain.handle("disco:cancel", (_event, sessionId: unknown) => host.cancel(id.parse(sessionId)));
ipcMain.handle("disco:approve", (_event, approvalId: unknown, decision: unknown) => { host.approve(z.string().uuid().parse(approvalId), z.enum(["approved", "denied"]).parse(decision)); });
ipcMain.handle("disco:providers", () => host.providers());
ipcMain.handle("disco:about", () => ({ dataPath: join(app.getPath("userData"), "disco.sqlite"), version: app.getVersion() }));
ipcMain.handle("disco:open-settings", () => openSettingsWindow());
ipcMain.handle("disco:choose-directory", async () => (await dialog.showOpenDialog({ properties: ["openDirectory", "createDirectory"] })).filePaths[0] ?? null);
ipcMain.handle("disco:choose-files", async (_event, withDirectories: unknown) => (await dialog.showOpenDialog({ properties: withDirectories === true ? ["openFile", "openDirectory", "multiSelections"] : ["openFile", "multiSelections"] })).filePaths);

app.whenReady().then(() => { host = new AgentHost(new DiscoStore(join(app.getPath("userData"), "disco.sqlite")), (event) => window?.webContents.send("disco:event", event)); createWindow(); if (process.env.DISCO_TEST_SETTINGS === "1") openSettingsWindow(); if (app.isPackaged && process.env.DISCO_DISABLE_AUTO_UPDATE !== "1") void autoUpdater.checkForUpdatesAndNotify(); });
app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
app.on("activate", () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
