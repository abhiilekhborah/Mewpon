# Mewpon 1.1 · Phase 2

This updates the existing native app and original Canvas engine. It keeps macOS 14 as the deployment target, the local Ollama service, all MVP tools, capability validation, confirmation UI, model settings, and opt-in history.

## Focus and interaction audit

The v1 fault was reproduced in the actual app: submitting disabled the SwiftUI text field, leaving the window as first responder. Its cached FocusState could remain true after re-enabling it. Padding around the field also belonged to the draggable window background rather than the editor. The shared nonactivating panel and a focusable WKWebView complicated activation further.

The replacement is a native NSTextView inside a scroll view, still embedded in SwiftUI. `ComposerFocus` holds a pending focus request until the editor is attached to a visible key window with no approval sheet. It responds to actual window-key notifications, view attachment, and layout. There are no timed focus sleeps or repeated focus-stealing loops.

- The panel activates normally. Its title chrome is hidden, using a titled/full-content style with native minimize support.
- The avatar WebView declines first-responder status; canvas mouse reactions, petting, gaze, and dragging remain in the original pointer module.
- The entire composer text region, including native text insets, accepts text clicks and uses an I-beam. Decorative placeholder/focus-ring layers do not hit-test.
- Window-background dragging is disabled around content. An explicit header handle and the existing avatar drag hook move the panel.
- The editor stays editable during generation so a new draft can be written. Sending remains serialized; the button becomes Stop.
- Return submits; Shift–Return inserts a newline. Marked IME text is committed through the input manager rather than being treated as a submit command.
- Text storage and selection are not replaced by streaming updates.
- AppKit owns the window frame. SwiftUI intrinsic window sizing is disabled; expansion is constrained to the current visible display. The transcript adapts to available display height.

## Design system and responses

macOS 26 uses the installed SDK's native `glassEffect(.regular, in:)`. macOS 14–15 uses native regular material; Reduce Transparency uses a readable solid system surface. No CSS glass imitation or deployment-target increase was introduced.

Collapsed mode contains only the original animated avatar on a transparent window. Expanded mode adds one restrained glass panel below it, a small header/options menu, a readable transcript, and a full-width composer. Settings provides System/Light/Dark appearance selection without changing the system's appearance.

The response renderer is native SwiftUI/AttributedString:

- headings, emphasis, lists, quotes, rules, inline code, code fences, tables and links;
- monospaced horizontally scrolling code blocks with language labels, lexical highlighting, and Copy;
- HTTP/HTTPS/mailto links only; no executable HTML, JavaScript, local-file links, or browser component per message;
- stable block identities and incremental parsing of the mutable streaming tail;
- follow-output only near the bottom, with a Latest button after the reader scrolls away;
- actual structured tool results and existing permission-gated file actions.

The parser supports ordinary fenced Markdown; it is not a complete CommonMark/LaTeX implementation. Mathematical TeX is displayed as text. Code highlighting is lexical, not a language-server tokenizer.

## Animation audit and changes

The existing engine already had head/body/eyes/sprout layers for large reference poses. However, activity rendering preferred tiny flattened frame strips, outfits bypassed those strips, and the transition renderer retained an opaque previous whole character while fading the next one over it. Changing head art to the sleepy pose for blinking also changed the silhouette. The tick accumulator could double-count elapsed time when throttling.

The updated, vendored source is in `AvatarEngine`. It preserves the original public API and adds atomic `transitionTo({expression, activity, duration})` and performance diagnostics. `npm run build` updates the native app's IIFE resource.

- A stable character base is retained per outfit. Body, head, goggles/headphones/headwear, eyes, and sprout use a common bottom-centre coordinate system and parent transforms.
- Default expressions use small, aligned facial patches and detached eyes; expression changes no longer replace the body's silhouette. Only the face patch blends, never two complete characters.
- Body texture deformation uses pinned neck vertices and weighted paw regions. Typing/walking/running move the actual paw texture independently rather than shaking a flattened image.
- Typing alternates paws with pauses; the original laptop pixels remain in a root-anchored prop pass with a restrained screen-light pulse.
- Searching uses the original magnifier texture under the same paw transform, with a controlled arc, eye following, head turn, and secondary motion. A detective outfit's baked magnifier is not duplicated.
- Listening combines head tilt, ear deformation where the source art permits it, the original effects, and a small headphone indicator pulse.
- Thinking uses upward gaze, head/sprout motion and a small palette-matched thought indicator.
- Talking adds timed visual mouth articulation and head gestures. It does not claim speech-audio synchronization.
- Walk/run use alternating paw displacement, weight shift and follow-through. Jump has anticipation, flight, landing and recovery phases.
- Joint targets interpolate continuously. Scale changes are clamped to ±3%; activity props ease into/out of view. Idle breathing, randomized blinking/gaze/micro-expressions, ear movement and sprout motion have different phases.
- All original PNG textures and manifest files remain unchanged. Texture deformation and a small procedural mouth/indicator overlay extend motion without generating a different mascot.

This is a deformable 2D texture rig, not a newly painted full skeletal asset pack. Some outfit faces and handheld accessories are baked into their original head/body textures. Those outfits retain their existing compatible expression gestures/effects and their original facial/cloth details; independent replacement of every facial feature behind glasses is not claimed. Hats/goggles follow their head texture, and clothing follows its source body layer. The base art is a soft antialiased illustration, not newly generated pixel art; integer nearest-neighbor scaling avoids adding resampling blur.

## Performance and verification

The renderer targets 60 fps for active states/interactions and caps quiet idle at 30 fps. Textures load once, rig state/samples are bounded, there is one guarded requestAnimationFrame loop, and hidden/minimized/occluded views stop rendering. The original throttle accumulator was corrected. Measurements use a bounded time sample and count actual draws.

In the visible running app, the working activity measured **54.5 fps**, **1.0 ms p95 JavaScript draw time**, and **one rendering loop** over a roughly 2.2-second sample. This is a measured sample on this Mac, not a 60 fps guarantee or a GPU-frame-time measurement. WebKit timer precision limits sub-millisecond readings.

The XCTest WebKit document is hidden under the test runner, so its recorded `observedFPS: 0` is expected and is not used as evidence of live frame rate. That test deterministically advances/renders the engine for catalog, transition, and screenshot checks. An initial unbounded RAF wait was stopped and replaced by a bounded sampling interval.

### Executed checks

- TypeScript type checking and 20 avatar/controller tests.
- Native focus tests cover pending requests before mounting, 12 repeated restore cycles, actual minimized/restored state, draft retention, Return/Shift–Return, and an IME marked-text commit.
- Native Markdown tests compare incremental versus full parsing at every character prefix and cover incomplete code fences and all supported block forms.
- Real WKWebView tests exercise 140 outfit/expression combinations, all activities per outfit, rapid transitions, and save 16 screenshots: idle, typing, searching, listening, thinking, jump, and all 10 outfits.
- The existing MVP tests remain in the full Swift suite: local transport, deadlines/cancellation, tools, permissions, lookup, Spotlight, measurements, and storage.
- Actual app checks demonstrated immediate typing after activation, drafting during generation, a multiline draft with Shift–Return, a complete streamed Markdown response, Copy feedback, a consecutive real calculator request (`5 * 9 → 45`), and preserving an earlier scroll position until Latest was clicked.
- Actual floating/expanded/response/Light/Dark/searching screenshots were captured through computer use. The rendered avatar screenshots are saved in [Verification/Avatar](Verification/Avatar).

### Final packaged-build results

| Check | Result |
| --- | --- |
| Full Swift test suite | 34 passed, zero failures |
| Avatar TypeScript tests | 20 passed |
| TypeScript type checking | Passed |
| Bundled catalog | 277 assets, 14 expressions, 10 activities, 10 outfits |
| Original PNG checksums | 277 compared against the original source; zero mismatches |
| Release application | Version 1.1.0 (build 2), macOS 14 minimum; built and launched |
| Ad-hoc package signature | `codesign --verify --deep --strict` passed |
| Final display bounds | Expanded frame constrained inside the 1710 × 1073 display; complete panel and composer visible |
| Final real inference | Local Qwen streamed a heading, bullets and Swift code block successfully |
| Final appearance | Full response inspected in Light and Dark; restored to System |
| Avatar repositioning | Drag moved the native window; position retained through collapse/expansion |

The final native screenshots show the complete expanded window after disabling intrinsic hosting-view sizing. Earlier preliminary screenshots exposed right-edge clipping; that issue was corrected before the final package. The app is left running with the default outfit, System appearance, and idle animation. Avatar snapshots in `Verification/Avatar` were also inspected for the original outfit silhouettes, props, and activity poses.

### Remaining practical limits

Physical global-hotkey activation from another application and exhaustive testing with every installed IME/monitor arrangement still benefit from a user acceptance check. Carbon registration and the existing configurable shortcut are preserved. No successful external application launch is newly claimed from this phase; automatic review previously blocked the Safari approval click in MVP verification. The permission/tool implementation is retained and regression-tested.

Avatar dragging was verified. The additional native header drag handle is implemented, but automated drag attempts did not establish movement from that handle; it remains a manual acceptance item. CPU/GPU utilization and battery impact were not profiled; the measured renderer sample above reports JavaScript draw time and actual draws only.

The 140 combination checks establish API acceptance, finite bounds and outfit preservation. They do not prove artistic quality of every possible outfit/activity pairing; the saved original-art comparisons and inspected native screenshots make the visual scope reviewable.
