# Mewpon Phase 4 — native macOS integration

Implementation record · 19 October 2026 · app 1.4.0, build 7 · macOS 14+ / Apple Silicon

This extends the existing application. The original avatar engine, outfits, expressions, animations, Play Mode, Liquid Glass materials, Ollama transport, conversation store, and tool authorization boundary remain in use. Phase 4 has implemented features and explicit platform fallbacks; it is **not a claim that every acceptance item has been exercised on every macOS configuration**.

## Command palette and focus

`CommandPalette.swift` adds a separate 620 × 430-point launcher. Opening it does not move the companion. It chooses the display under the pointer, uses that display’s visible frame, positions near its upper center, and clamps smaller displays. Display-change events dismiss the palette and constrain the companion to the remaining display. Offset-display and small-display placement have geometry tests; physical display hot-plug testing remains outstanding.

The launcher is an activating, key-capable `NSPanel`. Focus uses the existing AppKit `ComposerFocus`: requests survive until the native text view is mounted in a visible key window, then call `makeFirstResponder`. Window attachment and key-window notifications fulfill pending requests. No timer is used to obtain focus. The existing multiline editor still handles IME composition before Return and supports Shift–Return for a newline.

Escape hides the palette without discarding the draft. It denies a pending approval if the palette is closed. It does not cancel an already-running model answer merely because the user switches apps. Explicit Stop, cancellation shortcuts, and Pause cancel the current task. The palette does not automatically disappear on application deactivation.

Arrow keys choose suggestions, Tab fills the selected suggestion, and Return submits it. Search results support keyboard selection and Return to Open when the input is empty. Native file rows have separate Open, Reveal, and Quick Look actions. File rows use workspace icons, parent paths, file types, and modification dates when supplied by Spotlight.

The Carbon registration now dispatches shortcut identifiers to Quick Command, Open Chat, Show/Hide Avatar, and Cancel Task. Only those registered combinations are handled; there is no global key-event monitor. Quick Command defaults to **Option–Space**. The old Control–Option–Space default migrates once to Option–Space; custom keys and Command–Shift configurations are preserved. The former combination overlaps Apple’s input-source shortcut. Registration errors are shown in Settings, and the native menu remains available. macOS does not expose a universal conflict detector for every app and system shortcut.

Open Chat, Avatar, and Cancel shortcuts are disabled until configured; their keys are C, H, and Period, with selectable Control–Option or Command–Shift modifiers. Quick Command supports Space or M with the listed modifier combinations. Arbitrary-key recording is not implemented.

Native automation also verified a complete streamed recursion answer from the configured `qwen3:4b-instruct` Ollama model, with input focus retained afterward. Native automation verified menu activation, immediate typing, draft preservation through six reopen cycles, arrow/Tab completion, calculator execution, and Escape dismissal. Synthetic shortcut attempts did not produce a verifiable global activation; **physical Option–Space, cross-Space, and full-screen keyboard testing remain manual acceptance items**. The implementation should not be described as fully verified system-wide until those pass.

## One native approval presenter

The original `PermissionManager`, capability checks, per-request denial set, exact tool arguments, bounded tool execution, and local action log remain the authority for actions. New capabilities cover file inspection, system control, and task context.

UI testing exposed inconsistent outcomes with the duplicated SwiftUI sheet presentation. The final app uses one `PermissionPresenter` and a native `NSAlert`, attached to the active palette or chat window. There are no competing SwiftUI permission sheets. Deny is the default keyboard action; Allow once requires choosing its button. Any response other than the explicit second-button response is denied. Canceling the task closes the dialog, and callbacks for an expired request ID are ignored. Native tests exercise the actual Deny and Allow buttons using AppKit, as well as task cancellation. Automated external UI attempts to deny still produced inconsistent outcomes; physical-click validation remains outstanding, and those attempts are not counted as a passed denial test. The presentation change does not grant persistent capabilities or remove approval checks.

## Desktop presence and lifecycle

The native status menu includes Open Mewpon, Quick Command, Settings, New Conversation, Show/Hide Avatar, Play Mode, Recent Tasks, a last-checked Ollama status, Pause/Resume, and Quit. Recent task commands only populate a draft; they do not immediately execute again. Connection status is event-driven and explicitly describes the last check rather than claiming continuous monitoring.

Settings expose companion mode (accessory activation policy, no Dock icon) and normal mode (regular activation policy). A native ICNS app icon is derived from the existing neutral mascot asset. Launch Services normally opens one app process; startup also exits if another process with the same bundle identifier is already running.

Avatar visibility supports Companion, Focus (hidden), and Hidden. The shortcut and status item remain available when the avatar is hidden. Position is saved using AppKit window autosave, with corner placement and custom dragging. Space/full-screen policy is configurable; full-screen participation is off by default. Play uses the same collection behavior as the companion. The compact companion refuses key-window status; explicit input activation enables it. Avatar clicks, play controls, and drag behavior still require real-world focus/layering acceptance across other apps.

`AvatarHitTesting` observes mouse-move events only. Outside the companion or its WebKit content it allows pointer events through; within the canvas it checks the rendered alpha of one pixel. It makes at most one WebKit request at a time, checks only while the pointer is within the compact mascot, and does not change hit handling while a mouse button is held. Expanded chat and Play bypass this hit test. It never reads screen pixels or global keystrokes. Failures keep the mascot clickable. Animation under a stationary pointer is not continuously sampled; this avoids polling but can leave the last hit classification until the next pointer movement.

Sleep cancels active work and pauses the avatar. Wake constrains the window, reapplies visibility, and refreshes Ollama availability. Display reconfiguration is notification-driven. These handlers are implemented, but actual sleep/wake and physical monitor removal have not been exercised in this session. No Ollama process is started or stopped by these integrations.

Login uses `SMAppService.mainApp` register/unregister, reads the OS registration status, and reports errors. It is not enabled automatically. The development bundle reported registration unavailable before registration; enablement and a subsequent login remain unverified. Keep the app in a stable installed location before enabling. There is no privileged helper. Disable the login item before manually removing the app; a separate uninstaller is not implemented.

## Finder, Spotlight, and system tools

The existing home-scoped `NSMetadataQuery` search now understands yesterday, previous calendar week, current month, recent presentations, screenshot metadata, and largest videos in addition to name/type filters. Largest-video queries ask Spotlight to sort by size and retain bounded results. Indexing, privacy access, the 256-candidate bound, and the 20-row display limit can make results incomplete; partial results are labeled and never automatically opened by the search-and-open workflow.

A tracked local PDF is the positive search fixture. The native query test finds its actual indexed path. During packaged-app testing the same search returned no matches; this difference is consistent with process-specific macOS privacy access but its cause has not been conclusively established. The app reports indexing/access limitations and offers a native file picker. It does not invent a path or request Full Disk Access. The picker fallback and Quick Look rendering of the fixture were verified in the UI.

| Capability | Implementation / boundary |
| --- | --- |
| Open apps, documents, folders | Existing validated tools and cancellation-safe async workspace open |
| Reveal file | `activateFileViewerSelecting`, actual path required, Allow once |
| Quick Look | Embedded `QLPreviewView` in native window, actual readable path, Allow once |
| Switch/hide/quit app | Exact running-app match; normal `NSRunningApplication` operations; Allow once; never force quit |
| Battery/storage/hardware/time/calculator | Existing native deterministic tools preserved |
| Wi-Fi | CoreWLAN power/link status only; no scan, SSID collection, or Location request |
| Output volume | Public CoreAudio scalar controls; master control or available first stereo channels; range 0–100; Allow once for read/change |
| System Settings | Allowlisted pane identifiers only; reports that opening a pane did not change the setting |
| Brightness | No implemented public hardware control; offers Display settings |
| Focus / Do Not Disturb | No toggle implemented; offers Focus settings |
| Global media playback | No arbitrary control of another player; use that player’s controls |
| Screen locking | No automated lock operation; explains Control–Command–Q and offers Lock settings |

Volume support depends on the output device. Unsupported or unsettable controls fail explicitly. If a device accepts one channel and rejects another, the result warns that a partial change may have occurred. It does not claim rollback. Stereo scalar changes apply the same requested level to both exposed channels; balance preservation and arbitrary multichannel mixing are not implemented. These hardware controls need device-specific acceptance testing.

## Task context and privacy dashboard

Context is disabled by default. Approved context inspection may read a remembered source app’s selected text, window title, or exposed file document URL. It uses public Accessibility APIs with bounded IPC timeouts on a background task, checks cancellation before subsequent reads, excludes secure text fields, and shows an inspection indicator in the palette. Missing AX data produces a clear fallback to Services, paste, or drag and drop. App content is untrusted tool data, never an instruction source.

Finder selection uses the focused Finder element’s selected rows/children and exposed file URLs, with bounded traversal. If Finder does not expose them, the user can drop the file instead. No filename is converted into an invented path. A task to open a document’s parent folder requires context approval and a separate open-path approval.

Exact selected-text explanation/summarization commands read context after approval, then send the returned text to the configured loopback model. That explanation phase has no action tools. Denial stops before model inference. Clipboard reading is a separate explicit action with Allow once, not a background monitor. Text is bounded to 3000 characters; users are asked to select a smaller passage rather than silently clipping it.

Settings show actual Accessibility and Screen Recording preflight status, an explicit AX request button, notification status, OS settings links, and honest explanations for other categories. There is no general all-app Automation grant query. Automation is not requested because no Apple Events integration is installed. Microphone is unused. Screen Recording status does not imply capture or screen understanding exists.

**Not implemented:** browser extension/page-URL integration, image/vision understanding, screen capture, microphone/voice, and general document-content analysis. These are not claimed as unsupported by macOS; they are capabilities still absent from this build. AX-granted selected-text/Finder workflows require user-controlled permission and app-specific acceptance testing. No permission was silently enabled for this work.

## Drag/drop, Services, Shortcuts, notifications

The avatar/chat surface and palette accept one file/folder or text item per drop. Files become actionable rows without being executed or analyzed. Scripts still fail the existing Open validation. Plain text becomes an editable draft, without immediate inference. HTTP(S) URLs are accepted as text; no web request is made. Image files can be opened or previewed as files. Raw image-paste/OCR/vision analysis is not implemented.

Services declares **Ask Mewpon / Explain Selected Text** in Info.plist. The service places bounded selected text into an explanation draft for review. The user presses Return to run it locally. Services availability can depend on the source app and macOS Services settings; discovery in other apps still needs acceptance testing.

App Intents expose Open Mewpon, Ask Mewpon, Show Avatar, and Play Mode. Ask creates a draft rather than bypassing the UI or approval boundary. `build-app.sh` emits Swift constant values, runs Xcode’s metadata processor, verifies `extract.actionsdata` exists, and packages `Metadata.appintents` before signing. The artifact contains all four intent identifiers. Shortcuts app discovery and running the actions through the system UI have not been verified end to end.

Notifications use local `UserNotifications`, requested only through the opt-in setting. Completion/failure notification is limited to tasks lasting at least ten seconds while their result is not visible. Notifications omit prompts, file names, context, and model output; clicking one opens Mewpon. No cloud push or scheduling system was added. OS notification permission and delivery were not enabled during testing, so actual delivery remains unverified.

## Verification and remaining acceptance

The final regression run passed **55 functional tests**, with **5 opt-in performance benchmarks skipped** (60 discovered, zero failures). The verification folder contains the indexed PDF and test logs. A subsequent focused native-button test also passed after changing it to exercise the actual NSButton actions. The original avatar assets and engine implementation were not replaced. Native regression includes the avatar catalog, rig/expression behavior, Play interactions, IME, repeated focus, Ollama transport, tool denial, deadline/cancellation behavior, route grammar, search date/type filters, and app/file validation. Positive indexed search is an opt-in native integration test (`MEWPON_PHASE4_FIXTURE=1`) after importing the tracked PDF with `mdimport`.

Measured in the signed app over 7 menu-driven activations: native first-responder fulfillment p50 **5.87 ms**, maximum **22.98 ms**; activation-method completion p50 **21.95 ms**, maximum **45.65 ms**. These are separate milestones, not additive, and exclude display painting and physical keyboard latency. Seven samples do not support tail-percentile claims. Main-process peak RSS in that session was **112.7 MiB**, excluding WebKit and Ollama. See `Verification/Phase4/app-metrics.json`. No sustained idle CPU or inference-contention improvement is claimed.

The bundle remains an ad-hoc-signed development app. Notarization, App Sandbox entitlement migration, and a packaged uninstaller were not added.

Remaining acceptance includes physical global-key activation, Spaces/full-screen policy, real second-display hot-plug, safe-area behavior under every display layout, sleep/wake, granted Accessibility workflows in multiple apps, Services/Shortcuts discovery, login after reboot, notification delivery, supported audio-device writes, and sustained idle/animation performance. Earlier hanging was not reproduced conclusively or diagnosed from the terminated process; this release must not be presented as a proven fix for that earlier hang.

## Primary API references

- [AppKit panel key-window behavior](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)
- [Apple input-source keyboard shortcuts](https://support.apple.com/en-ie/guide/mac-help/mchlp1406/mac)
- [SMAppService login registration](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Quick Look view](https://developer.apple.com/documentation/quicklookui/qlpreviewview)
- [Accessibility messaging timeouts](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
- [CoreAudio scalar volume](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyvolumescalar)
- [App Shortcuts provider](https://developer.apple.com/documentation/appintents/appshortcutsprovider)
