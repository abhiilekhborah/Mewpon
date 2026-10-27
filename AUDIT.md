> Historical MVP v1 record. See [PHASE2.md](PHASE2.md) for the updated application and current verification.

# Existing avatar audit

The existing the original Mewpon source project project is a TypeScript Canvas 2D engine, not React or PixiJS. The original project is separate from the writable `Project_Asyuris` workspace. Its source, assets, and renderer are preserved. The native application embeds its existing IIFE bundle and all 277 referenced sprite assets in a local WKWebView. No original source files were edited.

## Verified control API

`Mewpon` exposes `ready`, `setExpression`, `setActivity`, `stopActivity`, `setOutfit`, `playAnimation`, `stopAnimation`, `reset`, `start`, `stop`, and `on`. `reset` resets the outfit too, so assistant activity transitions must use `stopActivity` / `stopAnimation` and `setExpression`, never `reset`.

Expressions: neutral, happy, excited, thinking, confused, sad, angry, sleepy, wink, laugh, surprised, embarrassed, proud, focused.

Activities: typing, reading, writing, idea, drinking, listening, cooking, searching, working, talking.

Outfits: default, hoodie, student, gamer, detective, wizard, raincoat, winter, summer, sleepy.

Movement animations: idle, walk, run, jump, talk. One-shots: bounce, nod, shake, squish, hop.

## Interactions and assets

The existing pointer module preserves gaze, hover, pet, click, double-click, and dragging. Its `onDrag` option permits moving the native window without moving the character off its canvas. Interaction events permit expanding the assistant after a click. Agent activities lock reactions by design.

The asset loader accepts the existing inline `window.MEWPON_MANIFEST`, avoiding fetch restrictions under file URLs. All sprite PNGs referenced by the manifest must be bundled. `ready` resolves after asset loading. The renderer should be stopped while its window is hidden, then restarted when visible.

## Build

`npm ci` followed by `npm run build` creates ESM and IIFE bundles with esbuild. Existing distributable bundles were already present and are reused verbatim. `npm test`, `npm run typecheck`, and `npm run test:e2e` are the avatar project's existing verification commands; those original suites were not rerun or reinstalled during this implementation. The existing e2e scripts assume a Linux Chromium location unless CHROMIUM is overridden, so they are not a native macOS harness. The new Swift suite, bundled manifest checks, and actual WKWebView launch are tracked in VERIFICATION.md.

The manifest includes an extra `proud_alt` expression image not accepted by the public API. It remains bundled. The artwork pipeline extracts existing illustration cells using Python/OpenCV/Pillow; regenerating assets is unnecessary for integration. There is no need for React, Electron, Node, or a local web server in the native app at runtime.

## Explicit assistant mapping

Idle → neutral / stop assistant activity; typing → focused; thinking → thinking; file search → focused + searching; application launch → focused + working; other execution → focused + working; success → happy; failure → confused; response presentation → neutral + talking. Talking is visual only, with no audio synchronization in v1. Repeated state updates should be coalesced and delayed idle transitions cancelled when a new operation starts.

## Audit boundary

Inspected every TypeScript source module, both shell implementations (demo and Electron overlay), package/build configuration, asset-generation helpers, and unit/e2e/visual verification scripts. Generated bundle source maps and package-lock contents are build artifacts rather than additional control APIs. The native bridge preserves the original pointer handler instead of layering a replacement gesture recognizer over the canvas. The Electron overlay is useful as an API integration example; the native app does not use Electron's polling interval or IPC.

An initial local-process failure coincided with the source folder becoming available under the `Project_Asyris` spelling. Subsequent file discovery located it, and work continued in the authorized writable workspace using explicit bash invocations.
