## Coordinated expression correction — 1.2.2

Facial geometry and expression gestures now advance from one expression-local clock with a 320 ms quintic transition. A new selection begins at the currently visible face and gesture; both settle together, with no portrait swaps or second body filter. Held expression motion starts from its own first frame instead of an arbitrary point in application time. Neutral returns fully settle.

Click reactions now actually display surprise for 450 ms, then happiness for 1.3 seconds, then return to the selected expression. New selections cancel the remaining reaction stages. Automatic blinks and random glances run only in neutral so they cannot overwrite an intentional expression. Angry and embarrassed motions use restrained gestures instead of high frequency shaking. Mouth contours are larger for readability.

Validation: 46 engine tests and three native avatar/catalog tests pass, including reaction event order, interrupted selections, shared face/gesture timing, 140 outfit/expression combinations, and unchanged neutral head/body textures throughout transitions. A six second, 180 frame native WebKit renderer sequence is in `Verification/Coordinated/expressions-motion.gif`. Summer now uses the same mouth rig while preserving its sunglasses; other outfit facial-art limitations described below still apply.

# Avatar quality and Play Mode — 1.2

## Continuous-character correction

The earlier whole-expression-pose fix removed duplicated goggles but still changed the mascot's silhouette. Default expressions now keep the same original neutral head/body/accessory textures permanently. Small navy/pink facial paths morph from their currently displayed geometry into the next expression; eye width and mouth geometry have no primitive-switch threshold. Original head/body joints, gaze, breathing, paws and sprout still animate.

Two additional rendering defects were found in consecutive frames: the extracted head retained the old sprout contour under the moving sprout, and clipped triangle meshes left diagonal alpha seams across the fur. The residual sprout contour is removed from the head. Mesh motion now inverse-samples a displacement field into one reusable image, writing each destination texel once. There are no overlapping clipped triangles. Exterior cleanup now flood-fills panel residue behind a closed outline barrier, including larger corners that the previous two-pixel cleanup missed, while protecting enclosed white fur.

The actual native WebKit renderer capture is [expressions-motion.gif](Verification/Seamless/expressions-motion.gif): 90 consecutive frames at 30 fps, showing neutral → happy → confused → angry → sleepy → neutral. This is a deterministic renderer capture, not a desktop screen recording. Native checks assert the same head/body textures across 56 expression/transition samples and that the baked sprout contour is empty. Unit tests also verify seam-free identity/translated/sheared images and continuous facial retargeting. This section supersedes the older expression and mesh descriptions below.

Verification: **42 TypeScript tests** and type checking passed. The **35-test native suite** passed during this correction; after the raster-warp replacement, the three targeted native avatar/catalog regressions passed again, followed by the final facial-contour capture check. All original outfit screenshots were regenerated; representative clothing, pink ears, chef hat and props were inspected. Cleanup protects warm pink pixels and limits flood depth to four source pixels to avoid hollowing pale artwork. The packaged app is **1.2.1 (build 4)** and passed strict signature verification. It was relaunched with the existing outfit preference retained.

## Expression and outline correction

The initial compositor incorrectly pasted an elliptical region of an expression head over a neutral head, then blended a previous patch on top. Those regions included goggles and fur. This has been removed. Each default expression now renders its own original matching head, body, eyes and sprout exactly once, with continuous rig motion and no head crossfade. Focused retains its original single laptop; its screen/neck are pinned while the correctly located paws can move.

The initial hard alpha cutoff also made pale extraction residue opaque. It has been replaced by an exterior-aware cleanup mask derived from each complete pose. Only pale residue reachable from the outside within the two-pixel edge band is removed; enclosed white fur and the head/body cut are protected. Original fractional alpha is retained rather than promoted to opaque.

Verification for this correction: 34 TypeScript tests passed, native expression tests checked 56 transition samples for exactly one matching head/body and no alpha promotion, and the outfit/activity/Play integration test passed. All 14 default expressions were captured on light and dark backgrounds in [Verification/ExpressionFix/Expressions](Verification/ExpressionFix/Expressions) and inspected. These corrections supersede the original face-patch and hard-mask descriptions below and in the historical Phase 2 report. Baked outfit faces retain the artwork limitation described below.

This update changes the avatar engine, bridge, avatar entry controls and a separate Play panel. The AI backend, chat layout/composer, Ollama transport and desktop tools were not changed. `CompanionView` only gains an avatar Play context action and accessibility description.

## Use

Click the mascot → **Play with Mewpon**. The existing shortcut still opens the assistant. The compact pastel panel has Play together, Expressions, Activities, Outfits and Animations tabs, placed near the avatar within the current display.

- Select any of 14 expressions, 11 activities or 10 original outfits. Thinking uses the compatible `idea` identifier.
- Pet, poke, high five, wave, dance, jump, twirl, follow the cursor, nap, wake/stretch, or choose Random.
- High five focuses the avatar and waits for a paw click or interruption. Click its highlighted paw to celebrate. Right-click the avatar to return to Play controls.
- Click/stroke the head to pet; click the lower body to poke. Repeated pokes alternate surprise, confusion and annoyance.
- Arrow keys select tiles; Return activates them. Escape or Close exits Play.
- Nap uses the original lying-down sleepy artwork until awakened; the preferred outfit remains independent and returns afterward.
- Closing restores assistant state. Assistant work interrupts Play and removes cursor monitors. Play cannot open over a nonempty composer or an active assistant request.

## Rendering

The original reference is the original `assets/reference/sheet.png` (1448 × 1086); individual poses are approximately 100 pixels wide. The previous renderer transformed triangles directly on Retina pixels, magnifying fringes and small seams.

The entire rig now renders on one logical source-pixel canvas, copied with integer nearest-neighbor scaling to the correct backing dimensions. Roots align to the grid; head, body and props share its pixel density. Fractional display ratios retain integer texel scaling. Hidden/unlaid-out canvases retain logical dimensions rather than recursively multiplying backing dimensions.

WebKit initially blocked Canvas reads from file-origin images. The build now creates local `textures.js` from byte-for-byte original PNG data under the existing CSP. Cached coverage masks remove low-opacity extraction fringes without repainting RGB colors or editing source PNGs. No WebKit security setting was relaxed. Decoding and mask preparation are cached. This fixes sampling and coverage; it cannot invent higher-resolution detail. Hard pixel coverage intentionally replaces soft edge antialiasing. No CSS sharpening filter is used.

## Motion and priority

The bottom-centre rig remains the shared coordinate system. Headwear follows the head, clothing/paws follow the body, and props use hand anchors. The chef hat no longer inherits pan flipping. The cup and book were repositioned after screenshot review. Reading scans and turns a page; drinking lifts/tilts a cup; cooking tosses a palette-matched food pixel. Existing typing, search, listening, talking, gait and phased jump motion remain.

`PetDirector` owns local action clocks, idle intervals and nonrepeating random choices. Assistant attention outranks pet actions; selected actions outrank idle gestures. Nap/high-five waiting are deliberate persistent states that end through user action or higher-priority interruption. Selected expressions persist. Idle gestures do not replace selected expressions/activities. Follow Cursor uses event monitors only while enabled in Play, with throttled gaze and small screen-constrained window steps, without global polling.

Public additions: `enterPlayMode()`, `exitPlayMode()`, `interact(name)`, `enableAutonomousIdle(bool)`, `getPetState()`, `setAssistantState(...)`. Existing APIs remain compatible; `setActivity('sleeping')` and `playAnimation('dance'|'wave'|'spin')` are supported. Unknown engine commands throw; attention-owned pet requests return `false`.

## Verification

- TypeScript checking passed; **28 unit tests passed**.
- The full **34-test Swift suite passed**. A subsequent avatar integration run covers the final prop-anchor corrections.
- Native WebKit exercised 140 outfit/expression combinations, all activities per outfit, rapid transitions, persistent selection, nap preference, high five and assistant interruption/restoration.
- Actual Canvas pixels were checked for exact repeated blocks at four avatar scales on this Retina Mac. Fractional DPR calculations were unit-tested at 1, 1.25, 1.5, 2 and 3; five physical monitors were not tested.
- **31 native WebKit snapshots** are in [Verification/Play/Avatar](Verification/Play/Avatar), including all outfits, mini-actions and additional activities. Representative poses and all outfit snapshots were inspected against the reference.
- Native computer-use checks clicked 14 expression, 11 activity, 10 outfit, 8 animation and 10 mini-action controls, plus Random. This establishes dispatch; every click was not an exhaustive artistic review.
- Direct native checks observed body poke, head-stroke happy/closed-eye response and paw-click celebration. Arrow/Return selection, Escape exit, chooser opening and right-click return were observed.
- Follow/stop controls and engine gaze/motion were exercised; full desktop pursuit across multiple monitors remains an acceptance check.
- Hidden XCTest WebKit reports `observedFPS: 0`; this is not a live frame-rate result. Live measurements are recorded separately below.

## Artwork and performance limits

No side/back drawings exist in the supplied sheet. **Twirl is an in-plane cartwheel**, not a mirrored imitation of a dimensional turn. A faithful dimensional turn requires additional original views.

Most outfit faces/accessories are baked into their original textures. They retain original details and compatible gestures/effects; independent eye/mouth replacement behind glasses is not claimed. Default expressions have richer facial behavior. Fully layered outfit faces and genuinely higher-resolution details need larger/layered original assets to preserve the exact mascot.

Active actions target 60 fps; quiet idle/sleep is capped at 30. The frame clock retains budget remainder under variable WebKit scheduling. One guarded RAF loop runs, and hidden/minimized/occluded views stop. Draw-time samples measure JavaScript, not GPU frame time or battery impact. No exhaustive CPU/GPU/memory-leak benchmark is claimed.

Final live packaged-app sample: **45.0 fps**, **1.0 ms p95 JavaScript draw time**, **one loop**, during the working activity over approximately 2.2 seconds. An earlier sample before the frame-clock correction measured 42.3 fps. The final sample does not meet 60 fps; it is reported rather than inferred from the target or the hidden test's stale FPS estimate.

The final avatar integration rerun passed after the cup/book/chef-hat corrections. The release application is version **1.2.0 (build 3)** and its ad-hoc signature passed strict verification. A checksum audit compared all **277 PNGs** against the original repository and all **277 data-resource entries** against their bundled PNGs: **zero mismatches** in both checks.
