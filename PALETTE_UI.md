# Movable assistant and clearer file results

22 October 2026 · Mewpon 1.4.5 (12)

The assistant now has a native AppKit drag region in its header, an open-hand cursor, and edge resizing. Its initial size is 720 × 640 points, with a 560 × 400-point content minimum. User drag and live-resize completions save the frame. Reopening retains a user-selected position on the current display instead of recentering every time; other displays use a clamped centered placement. The companion remains a separate window.

The header exposes Settings and Hide. Input, window controls, file actions, and the drag region have separate hit areas. Settings opens above the assistant rather than being covered by it.

Search results now have a dedicated Files view alongside Conversation. The file count describes the rows shown, without implying a complete total. Partial searches retain an explicit warning. A local name/folder filter narrows the returned rows without invoking the model or claiming a new disk search. Arrow keys select, Return opens, and double-click provides the same explicit open action. Each row retains Open, Reveal, Quick Look, and approved text-reading controls. Paths inside the home directory use `~`, with the complete path available on hover.

Conversation remains accessible in its own tab. Adjacent assistant messages repeating a tool's exact summary are omitted from display; stored/in-memory conversation history is unchanged. Search results are no longer pushed offscreen by automatic transcript scrolling. Existing native materials, context permissions, mew-Command visibility, local model settings, avatar, outfits, and Play engine are retained.

Validation: the full suite passed 72 functional tests with five optional benchmarks skipped (77 discovered, no failures). Added tests cover native drag/resize configuration and duplicate-summary display behavior. A controlled 20-file fixture rendered the native layout for inspection. The fixture snapshot in `Verification/Phase4/results-ui.png` is a light-appearance layout proof; material backdrops are composited over a solid native background because view-cache rendering does not include WindowServer effects. It is not a screenshot of the user's files. Physical dragging and final installed-window appearance require the new process to be running.

Logs: `Verification/Phase4/palette-ui-tests.log`, `palette-ui-build.log`.
