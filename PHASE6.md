# Mewpon Phase 6 — implementation and verification record

Build: **1.7.0 (18)** · verified 25 October 2026 · native macOS / Apple Silicon.

The existing application was extended. Its shortcut launcher, local Ollama integration, avatar artwork, expression rig, outfits, animation engine, and Play Mode were retained. No third-party UI package, cloud model, arbitrary shell tool, or private system API was introduced.

## Using the new features

- `Open Safari`, `Volume 40`, `Mute my Mac`, `Audio output devices`, `Battery status`.
- `Dark mode` / `Light mode` changes **macOS**. `Theme Midnight` changes **Mewpon**.
- `Open display settings`, `Bluetooth status`, `Open Bluetooth settings`.
- `Open my CV in Preview` searches explicitly indexed folders and aliases; a sole match opens directly. Ambiguous matches preserve the requested application when selected.
- `Open my latest Python project in VS Code` uses a completed authorized index, with choices for equal newest modification dates.
- `Put Safari on the left and Preview on the right`; `Center Safari`; `Minimize Safari`; `Restore Safari`.
- `Open Safari and volume 20` runs a bounded native plan without model inference between steps.
- `Run routine Studying` / `Set my Mac for studying` runs a routine that I have explicitly saved in Settings → Permissions.
- `Move today's screenshots into a new folder` prepares an expiring, frozen preview. Desktop must first be an authorized operation folder. Commit obeys the file-change policy.
- `Start my development server` runs a registered development workflow. Settings can configure an isolated Python localhost server or register a reviewed JSON manifest.

Settings → Appearance offers **Liquid Glass, Minimal Light, Midnight, Arctic Blue, Warm Paper, Developer**. The current selection persists. The explicit Light/Dark override remains available; “Theme default” uses the theme's preferred appearance, with Liquid Glass following macOS.

## Authorization

`AutomationTrustPolicy` is the single capability-policy engine. `AssistantModel.authorizeAction` is used by normal agent tasks, explicit result selections, and saved routine steps. `ToolRouter` checks the emergency automation switch before every tool, including read-only tools. Disabling automation also cancels the active request.

Default trusted categories are ordinary application/document actions, audio, appearance, and explicitly saved low-risk routines. File changes, window control, normal quit, and sleep ask by default. Context inspection and custom program execution always ask or deny, even if an imported policy attempts to allow them.

Settings exposes Ask, Allow, selected folder/application scopes, Deny, revocation, saved routines, and recent tool/time/outcome metadata. File mutation always requires an operation folder; broad Allow alone does not authorize the disk. Search/content indexing uses a separate folder picker in Privacy. No personal content folder or Desktop operation scope was added during verification. The temporary nonsensitive fixture index and workflow registration were revoked afterward.

macOS still enforces its own permissions. **Accessibility is granted**, and **Automation → Mewpon → System Events is enabled**, verified in the native UI. Both dark and light appearance changes succeeded. Screen capture uses the existing one-shot system picker. Microphone and Full Disk Access were not requested.

The existing `mew → Command` toggle and separately signed launch-after-Quit helper remain enabled; General reports both listeners Ready. The user previously physically confirmed hide/show and launch-after-Quit. Modifier-only physical recognition was not falsely claimed as a synthetic keyboard test in this phase.

## Native controls

| Area | Implementation | Boundaries |
|---|---|---|
| Applications | Cached application resolution, NSWorkspace open/activate, existing normal hide/quit | Ambiguity returns choices; normal quit leaves save prompts to the target app |
| Audio | Public CoreAudio volume, mute, output enumeration and exact device switching | Device must expose writable properties; outcomes are read back |
| Media | Fixed Music/Spotify Apple Events verbs | Running known app and target-specific macOS permission required; five-second script timeout |
| Appearance | Fixed boolean-only System Events appearance preferences | Readback verified; no model-generated AppleScript |
| Displays | NSScreen names, pixel/point sizes and Settings navigation | No direct public brightness implementation in this release |
| Bluetooth | Authorization check before public host-controller state | Unapproved access returns a limitation without scanning or initiating a permission request |
| Wi-Fi | Existing supported connection status and Settings navigation | No private radio toggles or forced network changes |
| Battery | Actual percentage, charge status, source and system information | Battery health is not implemented; no invented health value |
| Power | Public IOKit sleep request | Not exercised live because it would suspend the session; lock returns Control–Command–Q |
| Windows | Semantic Accessibility position/size/minimize/restore/close/menu actions | Exact running app and focused/sole window; apps may constrain frames; no coordinate clicks |
| Files | Scoped create/copy/move/rename, no overwrite | Rejects disk/home roots, sensitive credential paths, direct source symlinks and escapes; no delete tool |

Window Accessibility IPC runs off the UI thread, with short messaging timeouts, cancellation forwarding, and bounded menu/all-window traversal. A target's unresponsive Accessibility server therefore does not block Mewpon's main thread. Frame readback determines success; partially accepted/constrained changes are reported honestly. Preferences discovery currently recognizes exposed English Settings/Preferences menu titles.

## Planning and execution

`OperatorIntents` extends `FastIntentRouter` before the existing route grammar. It recognizes common system/theme/file/window commands, bounded multi-action instructions, and reviewed workflows. Negation, quoted commands, how-to questions, unknown clauses, and potentially destructive requests do not acquire a deterministic execution route.

`HybridAgentController` executes at most eight native plan steps in order, checks cancellation/authorization, stops on denial/failure, and composes results from actual tool outcomes. It never replays effects from the routing cache. The plan test uses a model service that fails if inference is called, proving zero model calls on that path.

Saved routines contain up to eight whitelisted native steps and are stored as owner-only local JSON. They can be updated by saving the same name, or removed. Each step still respects its capability policy; a routine does not silently authorize unsupported brightness, denied windows, or context inspection.

Screenshot organization identifies real screenshots through Spotlight metadata rather than filename guessing. A frozen list of paths, modification stamps, sizes and destination expires after five minutes. Commit revalidates everything, does not overwrite, stops on error/cancellation, and reports partial moves rather than claiming atomic rollback.

## Reviewed development workflows

The strict local manifest contains only `name`, `executable`, `arguments`, `directory`; maximum 900 bytes. Programs come from an explicit allowlist. Shell executables, inline eval flags, outside working directories, and arbitrary model-supplied commands are rejected. Registration is revocable.

Preparation freezes the manifest bytes and SHA-256 digest for five minutes. Execution checks the current registration and exact human-readable preview, then launches `Process` with an argv array and sanitized environment. Ordinary tool arguments reject control characters; only the known workflow preview field allows line feeds so the exact reviewed multi-line preview can pass validation.

Custom program runs always require individual approval, since a registered npm/node/Python/Shortcuts workflow may execute project code. The separately recognized built-in server is only `/usr/bin/python3 -I -m http.server <unprivileged-port> --bind 127.0.0.1`, with no project startup scripts; after explicit configuration it can use the trusted-routines policy. Up to three processes are managed; duplicate directory starts are rejected. Stop managed workflows and Quit terminate managed direct processes. Arbitrary descendant process trees are not supervised in this release.

The UI reports process liveness, **not server readiness**. Verification separately fetched the controlled test page and received HTTP 200. It then stopped the process, confirmed port 8000 closed, and revoked the fixture registration. No personal files were served.

## Theme architecture and research

Mandatory research preceded theme implementation. [THEME_RESEARCH.md](THEME_RESEARCH.md) records real GitHub URLs, MIT licenses, deployment/toolchain compatibility, maintenance observations, dependency footprint, and the reason each candidate was not integrated. Raw findings are in `Verification/Phase6/theme-research.json`. No shortlisted repository's source was copied.

`MewponTheme` provides light/dark semantic palettes for backgrounds, surfaces, text, secondary text, accents, borders, selections and status, plus glass, typography, radius, spacing and motion preferences. `ThemeManager` owns selection, persistence, strict local JSON import and live updates. Existing native SwiftUI/AppKit components consume the shared appearance and colors. Imported files are limited to 64 KB, exact supported keys, hexadecimal palettes, finite bounded layout values and contrast checks; no script, URL, font or resource loading is supported.

The glass/solid conditional now changes only the background. The native editor and hosting content remain mounted, preserving focus, text selection and composition. “Theme default” uses an optional preferred color scheme so returning from a forced dark theme does not retain a stale dark override. Conversation, active task, avatar object, WebKit view and Play Mode state remain the same through all six switches. The avatar itself is not recolored.

## Functional verification

| Required check | Actual evidence/result |
|---|---|
| Open Safari twice | Native commands returned accepted open outcomes, no Mewpon prompt; Safari Start Page independently visible |
| Adjust volume | Read 55%, set 40%, restored 55%, readback success |
| Battery | Native percentage/charge/source output verified |
| Light/dark | Both succeeded; final macOS light mode |
| Display Settings | Actual Displays page visible in System Settings |
| Find PDF without exact name | Controlled CV found by purpose/content in the explicitly indexed fixture folder |
| Open in Preview | Actual `Alex_Example_Final_2026.pdf` document visible in Preview |
| Arrange windows | Safari center/left readbacks passed; Preview constrained its frame and correctly returned unconfirmed exact placement |
| Saved routine | Explicitly saved Verification: Volume 55 + Open Safari; ran without extra prompts; removed afterward |
| Destructive operation | Delete operation rejected in file-operation tests; unknown tools and unsafe deterministic routes rejected |
| All six themes | Native switch/screenshot for every theme; gallery checked; final Liquid Glass |
| Avatar/Play state | Real AppKit/WebKit tests retain the same avatar, web view, Play Mode, content root and editor first responder across six themes; existing expression/render integration tests pass |
| Conversation/tasks | State-preservation regression passes; no root/view replacement on theme switch |
| Multiple actions | Native Open Terminal + Volume 55 completed; zero-inference sequential-plan test passes |
| Unsupported controls | Brightness returns an explicit unsupported result; Bluetooth without permission returns a limitation and does not crash |
| Development workflow | Built-in fixture server started, HTTP 200 verified, duplicate start rejected, stopped and revoked |

Live checks caught and fixed: missing Bluetooth usage description/TCC termination; approval sheet withheld after application switching; editor focus lost when glass/solid branches replaced content; stale forced theme appearance; repeated multi-step feedback; workflow preview rejected by single-line validation; stale preview file list hiding the final workflow outcome.

The final full suite discovered **113 tests: 103 passed, 10 optional benchmark/inference tests skipped, zero failures**. The opt-in routing and native timing workloads were also run separately. `final-workflow-tests.log` contains the final full-suite result (the broad test filter matched the whole test module). Release build and nested signatures verified successfully in `final-build.log`.

Actual screenshot organization of personal Desktop files, media playback/device switching, sleep, multi-monitor hardware movement and arbitrary third-party workflows were not exercised live. They are not represented as passing live checks.

## Measured performance

Measurements are local observations, not universal latency guarantees. Debug microbenchmarks reuse the prior workload; native release samples come from the app's monotonic profiler. See `Verification/Phase6/performance-comparison.json`, `routing.json`, `native-task-timing.json`, `runtime-metrics.json` and `native-ui-results.json`.

| Same workload | Prior p50 / p95 | Phase 6 p50 / p95 |
|---|---:|---:|
| Cached routing, 1,500 samples | 0.011542 / 0.023791 ms | 0.009583 / 0.037292 ms |
| Time/calculator native tasks, 200 samples | 0.058417 / 0.070625 ms | 0.040541 / 0.043792 ms |

Routing median improved slightly; its p95 regressed slightly and remains below 0.04 ms. The microbenchmark includes repeated cached inputs, and is not a cold application launch or inference measurement. Separate runs and system load prevent attributing tiny differences solely to code.

The native release capture recorded:

- Input routing p50 0.162 ms; submit state assignment p50 0.073 ms (12 requests).
- Window tool p50 26.17 ms, maximum 45.26 ms (four calls), excluding user review time.
- CV resolve/open acceptance 309.09 ms (one call); this is OS request acceptance, not Preview display-paint latency.
- Two-action saved routine 301.74 ms (one call).
- Theme apply assignment/notification p50 29.92 ms, maximum 70.91 ms (seven switches); this includes scheduling/observation and is not display-paint timing.
- Main-process peak resident memory 112,033,792 bytes (~106.8 MiB). This excludes WebKit and Ollama; there is no comparable same-workload historical memory capture, so no memory-saving percentage is claimed.
- UI layout-assignment p50 6.81 ms, p95 262.10 ms (41 samples). This exposes resize work and should not be misrepresented as every frame meeting a 16 ms deadline.

The native task paths above use zero chat inference; model warming is separate background work. Optional user interactions for trusted ordinary commands were zero. Default Ask window policy prompted once per action, as configured; selecting Allow or a matching application scope removes covered Mewpon prompts without changing OS permissions.

The earlier first-response warm-up work remains intact; its separate controlled results and cold-model caveat are recorded in `Verification/FirstResponse.md`. This phase makes no new promise that a genuinely unloaded model answers instantly.

## Remaining platform limits

Direct brightness, Focus switching, locking, Wi-Fi/Bluetooth radio changes and universal graphical-app manipulation are not provided as unrestricted controls. Supported Settings pages, explicit keyboard alternatives and registered reviewed Shortcuts/workflows are the available paths. No security bypass, broad credential access, permanent deletion or bulk overwrite tool exists. Exact window arrangement depends on the target app's exposed Accessibility properties and minimum size.
