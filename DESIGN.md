# Disco interface direction

## 1. Visual theme and atmosphere

Disco is a quiet, native macOS workspace with one bright point of energy. System surfaces stay neutral and content-first; a coral, amber, and plum orb carries the product identity without turning the whole window into a gradient.

## 2. Color palette and roles

- Canvas: macOS `windowBackgroundColor`, the conversation reading surface.
- Surface: macOS `controlBackgroundColor`, used only where controls need grouping.
- Coral `#F05A63`: primary action, focus, and selection.
- Amber `#F39A58`: warmth inside the Disco mark.
- Plum `#8D5AC8`: depth inside the Disco mark, never a page background.
- Success: system green. Danger: system red.

## 3. Typography rules

- SF Pro and PingFang SC through the macOS system font stack.
- Rounded design only for the Disco wordmark and short display headings.
- Body copy uses the standard system design for long-session legibility.
- Scale: 28 title, 20 section title, 15 body, 13 secondary, 11 metadata.

## 4. Component styling

- Radius scale: 8 for small controls, 14 for rows and banners, 22 for the composer, capsule for status chips.
- Primary buttons use coral fill, white content, and a 0.96 pressed scale.
- Secondary controls use semantic system fills and no decorative border.
- Inputs are grouped in one continuous connection surface with hairline dividers.
- Model rows are flat; selection uses a coral tint and checkmark.

## 5. Layout principles

- Spacing scale: 4, 8, 12, 16, 24, 32.
- Conversation content is capped at 760 points for reading comfort.
- The composer floats above the window edge and never joins the scroll view.
- Settings follow the task order: endpoint, credential, connection, model, save.

## 6. Depth and elevation

- The conversation canvas is flat.
- The composer is the highest surface, using system material and one soft shadow.
- Settings use one grouped credential surface and one model surface, not a grid of cards.
- Hairline dividers separate rows; borders do not decorate containers.

## 7. Do and don't

- Do keep the Disco mark as the only saturated visual anchor.
- Do reveal message utilities on hover while keeping them keyboard accessible.
- Do use native focus rings, selection, and semantic colors.
- Do keep API errors adjacent to the composer.
- Do keep persisted conversation history in a native macOS sidebar.
- Don't imply a connection was verified when it was only saved.
- Don't use purple-blue page gradients, generic hero cards, or ornamental glass.

## 8. Window behavior

- Main window minimum: 820 by 560. Preferred: 1120 by 760.
- Settings window: 700 by 680 with a single internal scroll region.
- Long model identifiers truncate in the middle and expose the full value as help text.
- All icon actions keep a minimum 40-point hit area.

## 9. Prompt guide

- Chat canvas: system window background, 760-point reading column, 24-point horizontal padding, 32-point message rhythm.
- Composer: system regular material, 22-point radius, 16-point inner padding, coral 40-point send control.
- Settings connection group: system control background, 14-point radius, 52-point leading icon column, hairline row dividers.
- Model selection: flat 44-point rows, coral at 10% opacity for selection, checkmark circle at 16 points.
