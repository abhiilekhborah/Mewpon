> Updated 22 October 2026 in 1.4.4 (11): clicking other apps or changing Spaces no longer suppresses Mewpon. Explicit show/hide controls determine visibility. The deliberately opened assistant floats over ordinary app windows on its Space; the avatar stays normal and full-screen participation remains opt-in. Sleep suppression remains. The conservative click-away policy described below is historical.

# Mewpon window and shortcut repair

21 October 2026 · 1.4.2 (9)

## What changed

The avatar, launcher, interaction menu, and Play window previously used floating levels. Several windows also joined all Spaces and full-screen Spaces. Wake handling reapplied a policy that ordered the avatar forward, and the shortcut only toggled the launcher. These independent paths could leave the mascot visible after dismissing the input window.

`WindowVisibilityCoordinator` now owns Hidden, Companion, and Assistant intent. The global shortcut toggles Hidden ↔ Assistant; Escape requests Hidden. Companion is a separate menu and Settings choice. User choices persist. Startup restores an explicitly saved Companion choice, but never opens the input interface automatically. Background completion does not change visibility.

Suppression is separate from user intent. Workspace application activation, active-Space changes, sleep, and display reconfiguration suppress both windows. Wake does not restore them. This is intentionally conservative: Companion must be summoned again after an application/Space change. AppKit has no universal public notification proving that another app entered full screen, including custom video/game modes. The implementation uses Workspace signals and ordinary window layering instead of guessing from the frontmost app, reading private Space state, or polling screen contents.

All Mewpon surfaces now use normal window levels. The avatar is borderless, transparent, nonactivating, and cannot become key. It retains its existing WebKit engine, outfit, alpha hit testing, drag position, and Play controls. The launcher is a separate activating panel with its own native composer. Opening responses no longer resizes or moves the avatar window. The input panel remains bounded; long responses scroll.

The avatar does not join other Spaces unless the existing explicit preference enables that. The launcher uses `moveToActiveSpace` only when deliberately summoned; full-screen auxiliary participation is restricted to the explicit full-screen option and never raises the window level. No background completion calls `orderFront`, `activate`, or changes the requested mode.

Shortcut registration uses Carbon's application event target, validates signature/identifier, unregisters old bindings, and reports registration failures. Native menu key equivalents provide the same in-app action. Only configured combinations are registered; no unrestricted keyboard monitor is installed. macOS can reserve shortcuts and Secure Input can restrict delivery. Settings and menu actions remain available.

## Transitions and focus

`WindowTransition` coordinates native frame contraction/expansion and opacity over 140–180 ms with a controlled ease-out curve. A generation token rejects stale completion handlers after interrupted transitions. Hiding immediately disables mouse hit testing; completion orders the window out and restores its canonical frame. Repeated shows do not restart a settled transition. Reduce Motion removes these animations. These are eased transitions, not a simulated physical spring.

The palette requests key-window status and native first responder at explicit activation. Existing composer attachment/key-window callbacks fulfill focus without sleeps. Dismissal cancels only the focus request and pending approval, preserving conversation, drafts, and running model generation. When appropriate, explicit hiding returns activation to the app remembered before invocation.

Permission sheets cannot activate Mewpon while it is suppressed or another app is active. A pending request can be presented when the user explicitly reopens the assistant. Existing tool validation and authorization remain intact.

## Verification

The full run passed 65 functional tests, with five opt-in benchmarks skipped and zero failures (70 discovered). See `Verification/Phase4/window-fix-tests.log` and `window-fix-build.log` for the executed regression and packaging checks. Tests cover visibility parity through 101 toggles, hidden-state persistence against background events, suppression without restoration, and real AppKit transition interruption/cleanup. The broader suite exercises native focus/IME, avatar expressions and rig, Play interactions, search, routing, permission denial/cancellation, local OCR/PDF reading, and Ollama transport.

Packaged-app UI checks verified immediate typing after reopening, Escape dismissal, the native Quick Command menu toggle hiding both windows, separate Companion mode, and a complete locally generated recursion answer with focus retained. An external synthetic Option–Space attempt reached the target application's normal key handling instead of proving Carbon hotkey delivery; it is not counted as a global hardware-key pass. Safari entered full screen through its native green button and was restored using its Exit Full Screen menu command; no Mewpon overlay was visible in the captured Safari view. This is one browser-window check, not validation of every video/game overlay mode. Physical global shortcuts, actual cross-Space/full-screen video/game behavior, second-display hot-plug, streaming while hidden, and rendered 60 FPS remain acceptance checks rather than claimed passes.

Runtime profiling records `launcher.window_visible`, `launcher.first_responder`, and, when an actual Carbon callback is received, `shortcut.dispatch_to_window_visible`. This measures dispatch to AppKit ordering, not display-paint latency or time before macOS delivers the event. No synthetic or previous-release timing is presented as a measurement of the final build.

The local backend, avatar assets, conversation store, and model configuration were not replaced. No TCC permissions, notification access, or login registration were enabled by this repair.
