# Faster first use and fewer task steps

22 October 2026 · Mewpon 1.4.3 (10)

## Click-away correction · 1.4.4 (11)

App activation, ordinary outside clicks, and Space-change notifications no longer change the requested visibility or start a hide transition. `mew` → Command toggles the entire assistant; close/Escape/menu commands remain explicit dismissal controls. The explicitly opened assistant uses the floating level on its current Space so ordinary app clicks do not cover it. The avatar stays at normal level, and joining full-screen Spaces remains opt-in.

## Shortcut

Type `mew`, then press either Command key within 1.5 seconds of the final letter. The shortcut toggles the same Hidden ↔ Assistant visibility coordinator as Quick Command. It does not create windows or change background-task visibility policy. Option–Space remains a fallback.

Enable keyboard access once in Mewpon Settings → Desktop → Enable keyboard access, approve Mewpon in macOS Input Monitoring, then Refresh shortcut (macOS may require an app restart). The app checks actual permission before creating its listener and reports denial/unavailability. This build does not grant TCC permission automatically.

The passive Core Graphics listener retains only a prefix index (0–3), modifier state, and a timestamp. It does not log, save, send, suppress, or replay keystrokes. Unrelated keys, edits, repeat events, modified keys, app/Space changes, and timeouts reset the prefix. Secure Input blocks recognition. Letters remain in the other application's input; only the trigger typed in Mewpon's own composer is removed from that draft.

Mewpon must already be running, including running hidden. A terminated process cannot recognize keystrokes. The existing opt-in launch-at-login setting can keep it available after signing in; no login item was silently enabled.

## Direct tasks

Explicit, deterministic requests to open an installed app, open a document/folder, or search files can complete after one submitted command. Native routing and exact arguments are required. A search-and-open request opens only one complete, unique search result; ambiguity or partial search still requires selection. Existing schema/path/script validation, deadlines, cancellation, and action logging remain active.

Model-selected actions never qualify for direct authorization. Context inspection, document reading, screen capture, volume/system changes, app quitting, and other sensitive actions retain review. Settings → Performance can restore approval for every app/file request. Clicking an arbitrary result still uses its existing explicit action flow.

## First-use latency

When history is disabled, command readiness no longer waits for history-file cleanup. Native commands continue to bypass Ollama entirely. The installed-model list is refreshed asynchronously, then a configurable empty-prompt Ollama request preloads the selected model. No model is downloaded, no answer is generated, and no recurring warming timer is installed. Keep-alive follows the existing model setting; zero disables preloading. The user can disable preloading to save resident memory.

Preloading has a real memory cost and cannot remove cold loading immediately after boot or after Ollama evicts a model. It moves loading ahead of a later question instead of claiming that disk/model initialization disappears. Errors do not block native commands or raise Mewpon's window. Settings shows the preload result. `startup.model_preload` records request duration without prompt contents.

Folder opens now use a background OS handoff and report that macOS accepted the request, instead of waiting for a Finder lifecycle callback that caused a timeout in packaged-app testing. This reports acceptance, not proof that Finder has painted its window. App/document opens retain their existing cancellation-safe callbacks.

## Verification

The full suite passed 69 functional tests; five optional benchmarks were skipped (74 discovered, zero failures). New tests cover exact sequence recognition, timeout/edit/modifier/repeat rejection, one trigger per Command press, direct-action scope, and empty-prompt/keep-alive preload transport. See `Verification/Phase4/quick-task-tests.log` and `quick-task-build.log`.

The packaged app completed “Show Downloads” after one submission with no approval dialog and no timeout following the folder correction. Settings confirmed both direct actions and preloading enabled.

In the running app, Ollama initially reported no resident models. Launching Mewpon then made the configured `qwen3:4b-instruct` resident (about 2.9 GB reported by Ollama), confirming that preloading actually ran.

The running app reported keyboard listener Ready on this Mac: the required keyboard access was already granted, and no permission was changed by this work. Recognition unit tests and successful listener creation are not a claim that the physical global-key path was exercised. No measured end-to-end startup speedup is claimed from these functional tests.

API references: [Apple passive event taps](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/listenonly), [Apple listen-access preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess()), [Ollama load-model API](https://github.com/ollama/ollama/blob/main/docs/api.md).
