import type { JSX } from "react";
import type { ProjectInfo, SessionInfo } from "../shared/types";

interface ProjectTreeProps {
  project: ProjectInfo;
  expanded: boolean;
  isActive: boolean;
  sessions: SessionInfo[];
  activeSessionId?: string;
  onToggle: (projectId: string) => void;
  onAddSession: (projectId: string) => void;
  onSelectSession: (session: SessionInfo) => void;
}

export function ProjectTree({
  project,
  expanded,
  isActive,
  sessions,
  activeSessionId,
  onToggle,
  onAddSession,
  onSelectSession,
}: ProjectTreeProps): JSX.Element {
  return (
    <div className="project-tree">
      <div className="project-item">
        <button
          className={`project-row ${isActive ? "active" : ""}`}
          onClick={() => onToggle(project.id)}
        >
          <span className={`project-caret${expanded ? " open" : ""}`}>▸</span>
          <span>{project.name}</span>
        </button>
        <button
          className="project-add"
          aria-label="新建会话"
          title="新建会话"
          onClick={(event) => {
            event.stopPropagation();
            onAddSession(project.id);
          }}
        >
          +
        </button>
      </div>
      {expanded && (
        <nav className="session-tree">
          {sessions.map((session) => (
            <button
              key={session.sessionId}
              className={`session-tree-item ${
                activeSessionId === session.sessionId ? "active" : ""
              }`}
              onClick={() => onSelectSession(session)}
            >
              <span>{session.title}</span>
            </button>
          ))}
        </nav>
      )}
    </div>
  );
}
