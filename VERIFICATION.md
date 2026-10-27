> Historical MVP v1 record. See [PHASE2.md](PHASE2.md) for the updated application and current verification.

# Verification record · 16 October 2026

## Executed

- Debug executable compiled successfully with Swift 6.3.3, targeting macOS 14+ on arm64.
- Release application packaged and ad-hoc signed with `bash scripts/build-app.sh`.
- `AppInfo.plist` validated with `plutil -lint`.
- **27 XCTest tests passed, zero failures**, in the full suite with normal macOS access. The same suite's native Spotlight test is blocked inside the agent execution sandbox; it passed separately and in the complete suite outside that sandbox.
- Tests cover Ollama NDJSON decoding, string/object tool arguments, real URLSession stub transport, incomplete/HTTP-error responses, model availability, network timeout/cancellation, model-switch unloading, unknown tools, invalid arguments, permission denial/cancellation, stopped action chains, bounded tool loops, arithmetic, file-result parsing, conversation trimming/persistence/clearing, metadata-only logging, native application lookup (Finder and Safari), native system measurements, executable-path rejection, project-scoped Spotlight querying, and avatar mappings.
- `python3 scripts/verify-avatar.py` verified every one of the **277 manifest-referenced assets**, all required bridge files, and the public expression/activity/outfit catalog.
- Packaged engine bundle, sprite manifest, and sprite PNGs were copied from the original avatar, without editing the original codebase.
- Launched the packaged app in a normal macOS desktop session and inspected the actual native UI and Canvas avatar.
- After correcting the resource-bundle lookup, the WKWebView's observed URL was inside `build/Mewpon.app/Contents/Resources/Mewpon_MewponDesktop.bundle/ExistingMewponAvatar/index.html`, rather than a `.build` fallback.
- Observed the compact avatar window, expanded command panel, Settings form, model configuration, native application menu, and opt-in history control (off by default).
- Verified compact collapse visually. Tested the minimize button; app-targeted accessibility snapshots alone did not establish the OS minimized flag, so Dock animation/restore remains a manual check.
- Actual local Qwen chat completed. A greeting returned a concise response.
- Actual local model tool loop returned native battery data and summarized the measured 36% battery level at that time.
- Actual local model calculator call evaluated `17 * (8 + 4) / 3` to `68.0`.
- The final packaged build called the actual date/time tool and returned the device's local date and time in `Asia/Kolkata`.
- SHA-256 comparison confirmed that 280 original bundle/manifest/asset files match the source avatar byte-for-byte.
- App-launch confirmation displayed the exact requested application. Denying it returned an actual permission-denied tool result.
- A model-produced misleading explanation after denial was discovered during UI testing; the final agent now returns the actual denial/failure directly and stops later actions. An automated regression test covers this behavior.
- Application lookup was strengthened with canonical bundle identifiers and Safari's system-managed Cryptex location. Read-only native lookup tests resolve Finder and Safari without launching either app.
- Settings showed the registered Control–Option–Space shortcut without a registration error. The app-targeted injected key chord did not demonstrate system-wide activation; physical-key verification remains pending.
- Native application-menu Quit was exercised during the rebuild/relaunch checks.
- Reopening the running application through LaunchServices expanded the panel. Input focus timing was subsequently adjusted to wait until expanded content mounts. In the rebuilt app, choosing Mewpon → Show Mewpon was verified to expand the panel and focus the command text field. Physical global-shortcut activation remains a manual acceptance check.
- A direct loopback `/api/tags` read outside the execution sandbox confirmed installed `qwen3:8b`, Q4_K_M, 5,225,388,164 bytes. No model was downloaded, installed, or removed.

The first loopback check inside the execution sandbox failed; that was an environment-access result, not proof Ollama was stopped. Subsequent actual app calls and a normal-access loopback check established connectivity.

## Remaining manual acceptance checks

These are not claimed to have passed:

1. Physically press Control–Option–Space from another app; verify expansion and input focus. Change the configured shortcut and test it again. The implementation uses Carbon registration and reports conflicts.
2. Drag the avatar and panel; hide/minimize and restore through the menu bar; reopen the app from Finder; verify position persistence across relaunch and multiple monitors/Spaces.
3. Inspect both light and dark system appearances, reduced-motion/accessibility preferences, and all original expressions/outfits/activities. The original catalog and all assets are verified; individual visual states were not exhaustively reviewed in the native host.
4. Approve a real application launch. **Automatic approval review rejected the agent's attempted “Allow once” click for Safari as insufficiently specifically authorized. No successful approved launch is claimed.** The final lookup path was tested read-only after fixing the discovered Safari resolution issue.
5. Approve a filename search in the real home folder, select an actual result, and approve opening it. Automated search is intentionally scoped to the project, and opening user documents was not performed by the agent.
6. Exercise real macOS Documents/Desktop/Downloads permission prompts and denied access. No Full Disk Access or security-setting changes were requested.
7. Stop Ollama and retry, then restart it; select a missing model and inspect the installation instruction. Transport failures/missing-model errors are automated-test covered, but the agent did not stop the user's Ollama service or change the active model to force these failures.
8. Enable history, restart the app, and confirm chat restoration; disable/clear it and confirm deletion. Storage round trips and clearing pass automated tests; the user's history preference was left off.
9. Cancel a long real generation. Actual URLSession cancellation and deadlines pass controlled transport tests; no long live generation was started solely to cancel it.

## Honest scope

This is a local MVP development application, not a notarized or App Store sandboxed release. Read the permission/security notes in README.md. No voice, screen control, terminal execution, browser automation, cloud sync, or audio synchronization is implemented. The existing avatar's baked outfit faces and illustration quality remain unchanged.
