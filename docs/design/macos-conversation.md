# macOS Conversation Contract

Disco's conversation view is a document with runtime status, not a stack of chat cards. The primary reading path stays quiet while reasoning, tools, and failures remain easy to scan.

## Content hierarchy

1. The user request appears under a compact `You` label.
2. Reasoning and tool activity appear under `Disco` as secondary runtime information.
3. The assistant response is the primary result and stays on the canvas without a card.
4. Token usage is tertiary metadata at the end of the turn.

## Surface rules

- User and assistant prose use the canvas directly.
- Thinking and Activity share one neutral secondary surface.
- Secondary surfaces use background steps instead of borders and shadows.
- Failure uses a restrained red-tinted surface and is displayed once.
- Activity rows use separators only between adjacent items.

## Status mapping

| State | Indicator |
| --- | --- |
| Running reasoning or tool | Blue dot |
| Completed activity | Green dot |
| Waiting for approval | Amber dot |
| Failed activity or run | Red treatment |

Streaming content itself is the progress feedback. Conversation updates do not add decorative entrance or completion animation.
