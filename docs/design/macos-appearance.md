# macOS Appearance Contract

Disco follows the current macOS window appearance. It does not maintain a separate application theme preference.

## Behavior

- Light and Vibrant Light use the light palette.
- Dark and Vibrant Dark use the dark palette.
- A system appearance change refreshes the active window immediately.
- Theme changes do not animate. The operating system owns the transition.

## Surface hierarchy

The hierarchy stays identical across appearances:

1. The sidebar is quieter than the conversation canvas.
2. The top bar and ordinary controls sit one surface step above the canvas.
3. Composer, menus, and provider cards use border or elevation only where separation is needed.
4. Selection, focus, hover, and pressed states remain distinct in both appearances.

Dark mode uses near-black neutral surfaces rather than pure black. Primary text uses a softened near-white rather than full white. Borders and elevated surfaces become lighter neutral steps instead of relying on dark drop shadows.

## Semantic colors

- Blue: selection, active controls, and running state.
- Green: ready, connected, completed, and successful state.
- Red: failure and unavailable state.
- Orange: approval or warning state.

Provider artwork may keep its own branded background. All surrounding application chrome must use the semantic appearance palette.

## Input behavior

Composer text inherits the active palette. Placeholder text, insertion cursor, and selection highlight each have separate light and dark values so editing remains legible without increasing visual weight.
