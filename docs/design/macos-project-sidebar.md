# macOS Project Sidebar Contract

This document fixes the product and interaction baseline for Disco's Rust project sidebar. The approved SwiftUI sidebar and the approved project mockup are the visual references.

## Product role

The sidebar is a source list, not a dashboard. It should answer three questions quickly:

1. Which project am I in?
2. Which task is active?
3. Can I safely switch context or create another task?

Project rows organize tasks. Task rows own conversation selection. Selecting an already active project must not reset the active task.

## Visual baseline

- Use the system font and compact source-list density.
- Keep the sidebar visually quieter than the conversation canvas.
- Use one restrained neutral fill for selection, not a card or bordered container.
- Use semantic appearance values for background, separator, hover, pressed, selection, focus, and text.
- Keep project names medium weight and task names regular weight.
- Do not display controls that have no action or clear status meaning.

## Interaction states

| State | Feedback |
| --- | --- |
| Rest | Sidebar background only |
| Hover | Subtle neutral fill |
| Pressed | Immediate darker neutral fill |
| Selected task | Persistent neutral selection fill |
| Keyboard focus | Slightly stronger selection or focus fill |
| Running task | Blue status dot on the active task |
| Navigation locked | Unavailable projects and tasks use reduced opacity and no pointer cursor |

The lock is intentional while the single Codex runtime is executing. Disclosure controls may still expand or collapse projects because they do not change execution context.

## Keyboard contract

- Up and Down move through visible project and task rows.
- Left collapses an expanded project. From a task, it moves to the parent project.
- Right expands a collapsed project. From an expanded project, it moves to the first task.
- Return activates the focused row.
- Keyboard navigation does not switch tasks while a run is in progress.

## Context menus

Project rows expose a compact context menu for operations that already have stable semantics:

- New Task
- Reveal in Finder
- Copy Path

Reveal and copy remain available while the runtime is busy because they do not change execution context. New Task follows the global navigation lock.

Task context menus remain deferred until task rename or removal has persistent domain semantics. A menu containing only weak or duplicated actions is not part of the baseline.
