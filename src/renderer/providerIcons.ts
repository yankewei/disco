import type { BackendKind } from "../shared/types";

export const providerIcons: Record<
  BackendKind,
  { glyph: string; tint: string }
> = {
  codex: { glyph: "❋", tint: "#272725" },
  claude: { glyph: "✳", tint: "#d9774b" },
  opencode: { glyph: "◆", tint: "#6f6d69" },
};
