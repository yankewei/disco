import type { JSX } from "react";
import type { ProjectInfo, SessionInfo } from "../shared/types";
import { ProjectTree } from "./ProjectTree";

interface WorkspaceSidebarProps {
  projects: ProjectInfo[];
  sessionsByProject: Map<string, SessionInfo[]>;
  selectedProjectId?: string;
  activeSessionId?: string;
  expandedProjects: Set<string>;
  onAddProject: () => void;
  onAddSession: () => void;
  onToggleProject: (projectId: string) => void;
  onAddSessionForProject: (projectId: string) => void;
  onSelectSession: (session: SessionInfo) => void;
  onOpenSettings: () => void;
}

export function WorkspaceSidebar({
  projects,
  sessionsByProject,
  selectedProjectId,
  activeSessionId,
  expandedProjects,
  onAddProject,
  onAddSession,
  onToggleProject,
  onAddSessionForProject,
  onSelectSession,
  onOpenSettings,
}: WorkspaceSidebarProps): JSX.Element {
  return (
    <aside className="sidebar">
      <div className="brand">
        <span>Disco</span>
        <span className="brand-caret">⌄</span>
      </div>
      <button className="new-session" onClick={onAddSession}>
        新对话
      </button>
      <button className="add-project" onClick={onAddProject}>
        添加项目
      </button>
      <div className="sidebar-scroll">
        {projects.map((project) => (
          <ProjectTree
            key={project.id}
            project={project}
            expanded={expandedProjects.has(project.id)}
            isActive={selectedProjectId === project.id}
            sessions={sessionsByProject.get(project.id) ?? []}
            activeSessionId={activeSessionId}
            onToggle={onToggleProject}
            onAddSession={onAddSessionForProject}
            onSelectSession={onSelectSession}
          />
        ))}
        {projects.length === 0 && (
          <button className="sidebar-hint" onClick={onAddProject}>
            选择一个本地文件夹
          </button>
        )}
      </div>
      <div className="sidebar-footer">
        <button
          className="settings-button"
          aria-label="Agent 设置"
          title="Agent 设置"
          onClick={onOpenSettings}
        >
          ⚙
        </button>
      </div>
    </aside>
  );
}
