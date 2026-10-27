# My Mewpon avatar implementation record

Implementation record | Version 1.2.2 build 5 | 16 October 2026

I built Mewpon as a local macOS AI desktop assistant with an animated companion. For the avatar, I combined a native SwiftUI and AppKit shell with the existing Mewpon Canvas engine inside a transparent WKWebView. I extended the engine to support continuous motion, coordinated facial expressions, direct interaction, and a separate native Play Mode panel.

This record explains how I implemented the avatar system and why I changed its rendering and timing. It captures the current implementation at version 1.2.2, build 5, dated 16 October 2026, including the earlier approaches I replaced, the checks I ran, and the limitations I still need to address.

### What I wanted to achieve

My goal was to keep the supplied mascot recognizable while making it respond to assistant events and playful input. The avatar needed to stay compact on the desktop, preserve its outfit between tasks, animate without obvious photo changes, and return control to the assistant whenever real work required attention. Play interactions needed to run locally without asking the language model to generate animation frames.

### How the system fits together

[Architecture figure embedded in the Word edition] The native shell owns windows and assistant state; the local engine owns pose generation and drawing.

I kept the animation system separate from Ollama and the tool executors. Assistant events select supported avatar states, while the renderer turns those states into visible motion. The avatar quality work did not require changes to model inference, tool permissions, or the chat composer.

## How I integrated the original artwork

### Source assets and attribution

I reused the existing Mewpon project from the original Mewpon source directory. The native application lives separately in Project_Asyuris/Mewpon. I retained the original MIT license, manifest, and 277 PNG texture files in the application resources. I extended the rendering code rather than replacing the mascot with newly generated artwork.

The reference sheet is 1448 by 1086 pixels, with individual poses approximately 100 pixels wide. This matters because enlarging an illustration of that size cannot produce genuine new facial or fur detail. My changes improve sampling, expression geometry, and motion consistency within the available artwork.

### Manifest and coordinate system

The manifest describes complete poses and extracted layers such as the head, body, sprout, eyes, props, and effects. Each layer records its file, dimensions, and offsets. Head pivots and sprout pivots provide rotation anchors. I kept the bottom centre of the character as the shared origin, with motion expressed in source pixels and angles expressed in degrees.

This shared space lets a head rotation carry its attached artwork, allows paws to move within the original body texture, and keeps props positioned relative to the character. I avoid treating every activity as a replacement full-body photograph, because differently proportioned source poses made transitions visibly jump.

### Packaging the engine for a native application

I vendored the editable TypeScript source under AvatarEngine. The build uses esbuild to generate ESM and IIFE bundles. The IIFE is copied into the native resource directory and exposes the Mewpon class and its public catalog to the local page. Node and npm are build tools; the packaged application does not need them at runtime.

The local page loads manifest.js, textures.js, mewpon.iife.js, and native-bridge.js. textures.js contains data URLs made from the exact original PNG bytes. This packaging allows Canvas pixel reads in WebKit without loosening browser security. It does not fetch textures from a remote service or alter the original PNG files.

### Why I retained separate source and generated files

My editable implementation is the TypeScript source. The IIFE and textures.js are generated runtime artifacts. After changing the engine, I rebuild it before rebuilding the Swift app; otherwise the native bundle can silently contain an older renderer. The source directory and license remain the reference for future maintenance.

## How I made the renderer consistent

### One logical pixel grid

I render the complete pose onto a logical source-pixel canvas, then copy that result to the visible Canvas at an integer nearest-neighbour scale. Head, body, facial paths, sprout, and props therefore share one pixel density. The backing dimensions still follow the view size and device pixel ratio, while root placement is aligned to the drawing grid.

The scale calculation uses the smaller view dimension, the requested avatar scale, and device pixel ratio. In pixelated mode I floor the requested texel scale and keep it at least one. I also retain logical dimensions when a view is hidden or not laid out, preventing repeated multiplication of backing dimensions. This approach avoids inconsistent sharpness between independently scaled layers.

### Removing white corners and extraction residue

I initially found that a hard alpha cutoff promoted pale extraction residue into visible white edges. I replaced it with cached cleanup derived from the complete pose silhouette. Pixels with extremely low coverage are removed; fractional coverage elsewhere is preserved rather than forced opaque.

The cleanup builds an ink barrier around the silhouette, closes small gaps, and removes eligible pale residue reachable from the exterior within a bounded four-pixel depth. Its colour rule protects warm pink ear pixels, and enclosed white fur is protected by the outline barrier. Using the full pose as the owner also prevents the artificial head and body cut from being mistaken for an outside edge.

For the neutral head, I separately clear the residual baked sprout footprint above the dome. The extracted head originally retained a contour underneath the separately animated sprout, so moving the sprout revealed a duplicate outline. Mouth cleanup is similarly restricted to a small local area before the procedural mouth is drawn.

### Replacing the mesh that produced diagonal seams

My earlier mesh rendered clipped triangles. Adjacent clips and alpha blending left thin diagonal seams across the pale fur. I replaced that path with inverse sampling into one reusable raster image. Every destination texel is written once, so internal triangle boundaries cannot accumulate or lose coverage.

The warp samples a bilinear displacement field, estimates source coordinates with four inverse iterations, and copies the nearest source texel. I cache the source pixels, displacement array, output ImageData, and canvas. Body deformation normally uses an 8 by 4 field; ear deformation uses 8 by 8. A 16-pixel pad provides room for movement. If pixel reads are unavailable, the safe fallback draws the undeformed source image.

## How I implemented facial expressions

For the default outfit, I keep the original neutral head and body textures in place and morph small navy and pink facial paths. The fur, goggles, ears, and overall silhouette remain the same character. This replaced both the overlapping face patch and the later whole-expression texture swaps.

FacePose stores left and right eye opening, arch, tilt, gaze offsets, brow strength and asymmetry, smile, mouth opening, mouth width, and blush. Eyes use filled Bézier contours; brows use short strokes; the mouth uses one continuous filled contour with a clipped pink interior. I enlarged the mouth to improve readability at desktop size.

| Expression | Facial intent | Accompanying motion |
| --- | --- | --- |
| Neutral | Open eyes and relaxed mouth | Subtle baseline breathing |
| Happy | Closed smiling eyes and open smile | Small bounce and head sway |
| Excited | Tighter smiling eyes and wider mouth | Faster bounce and sprout movement |
| Thinking | Upward side gaze and uneven brows | Small head tilt and gaze offset |
| Confused | Unequal eye opening and brows | Slow alternating head tilt |
| Sad | Lowered eyes and downward mouth | Lowered head and drooping sprout |
| Angry | Inward brows and tense mouth | Restrained lean and head angle |
| Sleepy | Nearly closed eyes and small mouth | Slow breathing and nodding |
| Wink | One closed eye and a smile | Tilt and light bounce |
| Laugh | Closed eyes and broad open mouth | Rhythmic bounce and sway |
| Surprised | Wider eyes and round mouth | Brief upward reaction |
| Embarrassed | Side gaze and blush | Gentle shy head movement |
| Proud | Raised gaze and confident smile | Slightly lifted posture |
| Focused | Narrower eyes and small mouth | Restrained downward attention |

These descriptions record the intended pose parameters, not a claim that every expression is equally readable in every outfit. The Summer outfit now has its own aligned procedural mouth while retaining its sunglasses. Most other outfit faces remain baked into the source artwork and do not yet support the default outfit’s independent facial controls.

## How I coordinated expression transitions

### One expression clock

I introduced ExpressionDirector to advance facial geometry and expression gestures together. On a new expression, it snapshots the currently displayed gesture and resets expression age. FaceRig snapshots the displayed facial geometry at the same time. Both then advance with the same delta time and transition duration.

The default expression transition is 320 milliseconds. I use quintic easing so the interpolation weight begins and ends with zero first and second derivatives. A supplied transition duration can extend this timing; expression transitions retain a 320 millisecond minimum. This produces a deliberate settle instead of an endless exponential drift toward the target.

```text
u = clamp(expressionAge / duration, 0, 1)
w = 6*u^5 - 15*u^4 + 10*u^3
visible = previousVisible + (target - previousVisible) * w
```

The face has fixed target parameters; the gesture target can continue moving while the expression is held. Both use expression-local age. I removed the previous dependency on total application time, which caused a new expression to begin halfway through an unrelated oscillation. A new selection starts from the visible pose, including when another transition is still in progress.

### Keeping the body from trailing behind the face

Activities and the base rig still use their own smoothing. I apply the coordinated expression offsets after that filter. Passing the gesture through another filter made the head and body settle later than the face, even when their nominal transition durations matched. The expression director now owns that part of the timing once.

### Correct reaction order

The original click handler set surprise, then immediately replaced it with happiness carrying a negative start time. The expression getter still returned happiness immediately, so surprise was skipped. I replaced that shortcut with ReactionSequence, an explicit list of stages.

```text
Click reaction
Surprised  450 ms  ->  Happy  1300 ms  ->  Selected base expression
```

The sequence carries leftover elapsed time into the next stage and removes completed stages in order. Selecting another expression clears pending stages, so an older happy reaction cannot appear after a new focused selection. Play Mode pokes intentionally use their own surprise, confusion, and annoyance cycle.

Automatic blinking and random idle glances run only while the selected expression is neutral. This prevents them from overriding a wink, closed-eye smile, or deliberate expression gaze. I also reduced rapid angry and embarrassed shaking because it looked like rendering instability.

## How I built the animation system

### A continuous pose rather than a frame playlist

The engine creates a Rig for each step. It contains root position and rotation, body offset and scale, head movement, eye movement, paw offsets, ear motion, sprout rotation, mouth level, prop transforms, and effect values. Pose functions modify these numbers; the renderer then applies them to the original textures and procedural face.

The composition includes baseline breathing, the current activity, a movement or one-shot if present, pet action motion, gaze and interaction springs, and the coordinated expression gesture. These are different control layers with different lifetimes. I use bounded scaling and small source-pixel offsets to preserve the mascot’s proportions.

### Movement and one shots

| Group | Implementation |
| --- | --- |
| Walk and run | Opposite paw phases, positive-part paw lift, small body bob, and delayed head and sprout sway. Run increases cadence and reach. |
| Jump | A crouch phase, sine-shaped flight arc, and a short landing compression. The main movement path divides progress into 0–18%, 18–78%, and 78–100%. |
| Talk | Procedural syllable-like mouth motion with pauses and small head motion. |
| Bounce nod shake squish hop | Short named one-shot definitions applied by normalized progress. |
| Body and ears | Spatial displacement of existing textures rather than detached paw or ear cutouts. |

### Scheduling and priority

AnimationController runs one scheduled activity, movement, or one-shot at a time. Its queue holds up to 16 items, ordered by priority. Higher-priority interruptible work can replace the current item; equal-priority replacement is explicit. Completion events distinguish a natural finish from interruption.

```text
idle 0 | hover 10 | reaction 20 | movement 30
speech 40 | activity 50 | system 90
```

These numeric priorities belong to the animation controller. PetDirector and assistant attention form an additional ownership layer; I do not treat the priority list as the entire application policy. Assistant work can close Play Mode before an animation is scheduled.

For paw deformation, I use smooth lower-body weights and Gaussian influence around the original left and right paw positions. This keeps the upper body stable while the visible paw regions move. Props have separate anchors so a pan, book, or laptop does not inherit an unrelated deformation.

## How I implemented activities and props

Activities combine small continuous rig changes with original prop artwork. I use an entrance weight for activity motion and retain prop textures while their visibility fades. The character generally keeps its stable head and body; sleeping deliberately selects the original sleepy outfit for the different resting silhouette.

| Activity | What I animate |
| --- | --- |
| Typing | Alternating paw taps with pauses, lowered gaze, small head motion, and a laptop. |
| Working | The typing family with a slower tap cadence and laptop visibility. |
| Writing | Paw movement plus short pen or prop oscillations, without forcing the typing laptop. |
| Reading | Side-to-side scan keys and a page-turn interval within a six-second cycle. |
| Thinking | The UI label maps to the supported idea activity identifier, with upward gaze and a small head tilt. |
| Drinking | A five-second cycle that lifts, tilts, pauses, and lowers the cup with the paw. |
| Listening | Head tilt, ear motion, and a small pulsing visual accent. |
| Cooking | Pan and paw movement, a timed toss, and a palette-matched food pixel. |
| Searching | A slow scanning arc shared by gaze, head, paw, and magnifier motion. |
| Talking | A procedural mouth rhythm with pauses and restrained head movement. |
| Sleeping | Slow breathing and tiny movement, using the sleepy artwork. |

### Keeping props attached

I place props in the same root coordinate system as the body. A hat follows the head transform; hand props use their own pivot and the relevant paw offsets. The chef hat no longer inherits pan flipping. I adjusted the cup and book positions after reviewing native snapshots.

The laptop is drawn once from the original typing artwork through a constrained polygon. I keep it pinned while a foreground pass lets the correct paw regions appear over it. That avoids using a differently proportioned focused portrait just to display a computer.

### What talking currently means

The engine contains an audio envelope and lip-sync API, but the desktop assistant does not currently implement voice output or live speech synchronization. The talking activity is a visual state driven by procedural timing. I therefore do not record the shipped avatar as having speech recognition, a wake word, or a voice conversation feature.

## How I designed Play Mode

### A separate native experience

I implemented Play Mode as a SwiftUI view hosted in a separate floating AppKit panel. Clicking the compact mascot opens a small chooser with Play with Mewpon and Open assistant. Play Mode stays separate from the assistant conversation so playful controls do not crowd or change the chat interface.

The Play panel is 306 by 440 points and is positioned near the avatar, constrained to the visible display. It uses a compact pastel design with five categories: Play together, Expressions, Activities, Outfits, and Animations. The shell handles native window behaviour; the local engine still performs all character motion.

### Catalog and keyboard controls

The panel exposes 14 expressions, 11 activities including sleeping, 10 original outfits, eight animation tiles, and the direct play actions. The outfits are default, hoodie, student, gamer, detective, wizard, raincoat, winter, summer, and sleepy. The Thinking activity uses idea internally, avoiding an unsupported activity name.

Arrow keys move between tiles, Return activates the selected tile, and Escape closes Play Mode. The close button has an accessibility label, and action status is visible as text. High five focuses the avatar so the next paw click reaches it. Right-clicking the avatar returns focus to the Play controls.

### Direct interaction with the character

Pointer handling checks the rendered character’s bounding box. The upper 70 percent is treated as the head region for play interaction. A head press or stroke triggers petting; a lower-body click triggers a poke. These are region heuristics based on the hit box, not a per-pixel anatomical classifier.

Outside Play Mode, movement past a four-pixel threshold begins a drag and the existing onDrag hook moves the native window. Pointer capture keeps the gesture coherent. A 280 millisecond double-click window distinguishes single and double clicks. During Play, a head stroke is treated as petting instead of dragging the companion.

### High five and feedback

High five raises a paw and enters an explicit waiting state. A highlighted region indicates the target, and a click in the expected lower-right hit region triggers a short celebration dance. The action waits until the user responds or a higher-priority state interrupts it; it does not pretend that the user completed the interaction after a fixed timeout.

## How I implemented local play actions

PetDirector owns the current action, action age, duration, poke count, following flag, high-five waiting flag, and autonomous-idle interval. It advances from the engine’s delta time. It does not call the model, create a polling loop, or start a timer for every action.

| Action | Duration or ending rule | Visible behaviour |
| --- | --- | --- |
| Pet | 2.4 seconds | Soft head response, ear motion, sprout movement, and happy expression. |
| Poke | 2.4 second action; 1.6 second expression | Small recoil; repeated pokes cycle surprise, confusion, then anger. |
| High five | Waits for paw hit or interruption | Raises the right paw and displays a target. |
| Wave | 2.4 seconds | Raised paw with an oscillating wave. |
| Dance | 4.8 seconds normally | Alternating paws, body bounce, head sway, and celebration pixels. |
| Jump | 1.1 seconds | Crouch, lift, flight, and landing. |
| Twirl | 1.6 seconds | A full in-plane cartwheel with a small lift. |
| Follow cursor | Toggle plus 1.2 second entry action | Turns on event-driven gaze and small window-follow steps. |
| Nap | Waits for wake or interruption | Original sleepy pose with slow breathing. |
| Wake or stretch | 1.1 seconds | Short paw stretch, head lift, and mouth opening. |
| Random action | Uses chosen action duration | Chooses pet, wave, dance, jump, or spin, excluding the previous choice. |

### Entry and exit envelopes

Most pet gestures use a smooth entrance over 250 milliseconds and a smooth ending over the final 250 milliseconds. Persistent actions have no timed ending envelope. A successful high five starts a dance with a shorter 1.8 second celebration duration.

### Quiet autonomous behaviour

The Quiet surprises switch controls autonomous idle behaviour. When idle is allowed, the director waits before choosing a small pet or wave gesture. The first interval is 14 seconds; later cleared intervals are randomized between 14 and 30 seconds. The engine also has occasional brief facial idle reactions, but explicit expression selection, an activity, or an attention-owned state prevents idle behaviour from replacing the user’s choice.

Nap temporarily uses sleepy artwork without overwriting the preferred outfit. Waking or leaving the sleeping state restores the saved preference. Twirl is a two-dimensional rotation: the supplied sheet contains no side or back drawings, so I did not implement a dimensional turn.

## How I connected native state and the engine

### The bridge boundary

AvatarBridge is a main-actor ObservableObject implementing the avatar control interface and WebKit message handling. It publishes readiness, errors, Play state, current pet action, cursor following, and an optional performance summary. The bridge loads the packaged resource bundle, falling back to SwiftPM resources during development.

Swift sends a small allowlisted operation through callAsyncJavaScript with structured arguments. I do not interpolate arbitrary user or model strings into executable JavaScript. native-bridge.js checks expression, activity, outfit, and animation identifiers against supported catalogs before calling the engine.

JavaScript posts ready, pet, activate, drag, and error messages back to Swift. The handler accepts messages only from the main frame of a local file page, bounds drag deltas, and ignores unknown message kinds. Navigation stays within the avatar resource directory. The page uses a nonpersistent data store and a CSP with connect-src none, local scripts, and local or data image sources.

### Assistant state mapping

| Assistant event | Expression | Activity |
| --- | --- | --- |
| Idle | neutral | None |
| Typing | focused | typing |
| Thinking | thinking | None |
| Searching | focused | searching |
| Opening or working | focused | working |
| Success | happy | None |
| Failure | confused | None |
| Responding | neutral | talking |

State updates are coalesced and duplicate JavaScript state keys are ignored. Normal state changes do not call reset, because reset would discard the selected outfit. Delayed returns to idle are cancellable; the current bridge uses 2.5 seconds for a responding return and 1.4 seconds for other requested returns.

### Ownership and cursor following

Assistant attention closes Play Mode and clears pet work. Play cannot open over an active request or nonempty composer. Closing Play removes cursor monitors and restores the assistant’s saved state. Selected expressions remain active during Play until another explicit choice or an ownership change.

Cursor following installs local and global mouse-moved event monitors only while enabled. Events are throttled to about 24 updates per second. Gaze is normalized from cursor distance; beyond 170 points, window steps are capped at two horizontal and 1.5 vertical points per event and constrained to the visible screen. This is event-driven movement, not continuous global cursor polling.

## What I changed while fixing visual problems

### Overlapping goggles and unclear expressions

The first expression compositor overlaid an elliptical expression-head patch on a neutral head. The patch contained goggles and fur as well as facial features, and crossfading patches duplicated those details. I removed the patch approach. An intermediate fix used a complete matching expression pose, which removed duplicated goggles but exposed inconsistent silhouettes between source drawings.

### The photo transition effect

Switching complete heads and bodies still looked like changing pictures. I replaced those swaps for the default outfit with a stable neutral texture and procedural facial geometry. I kept the original character artwork while giving eyes, brows, mouth, and blush independent parameters. The neutral head and body are now asserted to stay unchanged across expression transition samples.

### White corners and moving edge defects

I traced the edge defects to several independent causes: extraction residue, promoted alpha, a retained sprout contour, and clipped triangle seams. I addressed each at its source with exterior-aware cleanup, preserved fractional coverage, the local sprout-footprint removal, and single-raster inverse sampling. I kept the original PNG files unchanged.

### Expressions appearing out of order

The face and body originally settled on different clocks, and expression motion began at arbitrary application-time phases. The click handler also overwrote surprise before it could become visible. I introduced ExpressionDirector and ReactionSequence, synchronized expression timing, cancelled stale stages on selection, and limited automatic blinks and idle glances to neutral.

### The outfit I was using

The current Summer outfit had a baked mouth and sunglasses. I aligned a small mouth cleanup mask to its actual source coordinates and drew the procedural mouth at that location. This gives Summer visible mouth expression changes while keeping the glasses intact. It does not create visible eyes behind the opaque glasses or fully separate every outfit’s facial artwork.

### What I learned from these corrections

I needed to test sequences and interruptions, not just isolated attractive poses. A single screenshot could miss a skipped reaction, a duplicate accessory during a fade, or a body gesture lagging behind the face. I now keep deterministic renderer captures alongside ordering and geometry tests so future changes can be checked against both state behaviour and visible results.

## How I verified the implementation

### Automated evidence for the current correction

The current TypeScript suite has 46 passing tests across controller scheduling, pet action state, rig motion, exterior cleanup, facial geometry, raster warping, and expression coordination. Type checking also passes. The new expression tests verify shared face and gesture timing, interruption from the displayed pose, expression-local motion, complete neutral return, reaction order, and cancellation of pending stages.

The native avatar and catalog checks passed in WKWebView. They exercise 140 outfit and expression combinations, activities per outfit, rapid transitions, Play ownership, nap preference restoration, high five, and exact pixel-block scaling. The expression test also checks 56 transition samples for unchanged neutral head and body textures, verifies cleanup without alpha promotion, and confirms that the retained sprout footprint is empty.

The native reaction check observes surprise before happiness, the return to neutral, and a focused selection that survives an earlier click reaction. The latest targeted expression run also generated Summer neutral, happy, sad, and surprised snapshots after I corrected mouth placement.

### Visual evidence and native interaction checks

Verification/Coordinated contains light and dark captures of all default expressions and a six-second sequence of 180 native renderer frames at 30 frames per second. The GIF is a deterministic WKWebView renderer capture, not a desktop recording. Earlier native checks exercised the Play controls, direct petting and poking, paw celebration, keyboard navigation, and closing behaviour. The final packaged build was restarted and its Happy and Surprised controls dispatched successfully.

### Performance and artwork limits

The engine targets 60 frames per second during active work and caps quiet idle at 30. One guarded requestAnimationFrame loop runs; native visibility and document visibility stop drawing when hidden, minimized, or occluded. Cached textures, masks, and warp buffers reduce repeated preparation, but I have not completed a sustained CPU, GPU, memory, or battery benchmark.

A hidden native test can report zero observed frames while deterministic stepping still renders correctly. Its stored FPS estimate is not a live performance measurement. The older live working-activity sample measured about 45 frames per second and one millisecond p95 JavaScript draw time; it predates the final raster warp and expression director, so it is historical evidence rather than a current performance guarantee.

The original asset resolution, baked outfit faces, and absence of side and back views remain real constraints. Default facial rigging and the Summer mouth correction should not be described as fully layered facial animation for every outfit. Multi-monitor cursor pursuit and exhaustive visual review of every transition remain acceptance work.

## How I maintain and extend the avatar

### Rebuild and validate

I edit the TypeScript engine, run its checks, build the generated assets, and then rebuild the native app. From the Mewpon directory, my normal sequence is:

```text
cd AvatarEngine
npm run typecheck
npm test
npm run build
cd ..
swift test --disable-sandbox --filter Avatar
python3 scripts/verify-avatar.py
bash scripts/build-app.sh
open build/Mewpon.app
```

For a clean dependency installation I use npm ci --ignore-scripts before the engine checks. I quit the existing local app before replacing its bundle and then launch the new build. SwiftPM cache paths may need to point to writable directories in a restricted development environment. The local app is ad-hoc signed; this is not a notarized distribution release.

### Adding a feature safely

For a new expression, I add a supported name, facial parameters, and restrained gesture motion, then update the native catalog and tests. I verify its transition from neutral, its interruption midway through another expression, and its return. For a new pet action, I add its action state, duration, pose function, native allowlist, menu tile, and ownership tests. For a new outfit face, I first need correct facial landmarks and cleanly separated artwork or a narrowly bounded repair mask.

### Implementation map

| Source under Mewpon | Responsibility |
| --- | --- |
| AvatarEngine/src/index.ts | Public API, engine step, pose composition, state and visibility. |
| AvatarEngine/src/core/expression.ts | Shared expression director and temporary reaction sequence. |
| AvatarEngine/src/rendering/face.ts | Facial pose targets, easing, and path drawing. |
| AvatarEngine/src/core/rigmotion.ts | Activity, movement, pet, and spatial body motion. |
| AvatarEngine/src/core/pet.ts | Local play action state and idle scheduling. |
| AvatarEngine/src/rendering | draw.ts, mesh.ts, outline.ts, and pixelgrid.ts implement rendering. |
| AvatarEngine/src/interactions/pointer.ts | Hit regions, petting, clicks, and dragging. |
| Sources/MewponDesktop | AvatarBridge.swift, AvatarPlayPanel.swift, and AppCoordinator.swift connect the engine to native UI. |
| Tests/MewponCoreTests | AvatarExpressionTests.swift and AvatarIntegrationTests.swift validate native rendering. |

The native runtime resources are in Sources/MewponDesktop/Resources/ExistingMewponAvatar. PLAY_MODE.md preserves the implementation history, and Verification/Coordinated holds the latest expression captures. This record describes the current 1.2.2 implementation; future changes should update the version, evidence, and limitations together.
