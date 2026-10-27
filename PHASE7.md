# Mewpon Phase 7 — implementation and verification record

25 October 2026 · work in progress · 1.8.0 (20) preview. Phase 7 is not complete.

## What changed

The existing Swift/AppKit/SwiftUI application and mascot are preserved. Text and recognized voice commands enter the same fast router, permission policy, executor and result verification path. Deterministic app, volume, time and reminder commands do not require the LLM. Each reasoning round rebudgets history and selected tools to the model context.

Heavy local inference jobs share a cancellable serial lease. Background model warm-up yields to interactive work; Calendar and Contacts stores initialize only when requested. No cloud LLM endpoint was introduced.

### Voice

Apple Speech is the default streaming command recognizer. It checks on-device support and sets requiresOnDeviceRecognition; unavailable locales fail closed. Whisper.cpp supplies separately installed/packaged multilingual file and utterance transcription. The verified GGML multilingual base model is bundled, with fixed process arguments and all runtime dependencies. Model publisher/revision/hash and licenses are included.

Microphone listening starts explicitly. The optional Hey Mewpon listener uses on-device ASR and exact phrase matching; it is not a dedicated low-power keyword model. Wake audio is not saved. A persistent visible indicator, Stop all voice, pause, sleep and termination handling release recording. Wake restart waits for command execution and generated replies to finish, avoiding self-interruption. Microphone capture has one owner across commands and meetings.

Voice Studio uses installed macOS voices, actual generated PCM/WAV, rate/pitch/volume, preview and immediate interruption. It does not claim emotional style control or streaming synthesis. Playback metering drives the existing avatar mouth at 20 Hz. Existing blinking, gestures, outfits, Play Mode and six themes remain in place. Listening/transcription events use existing avatar states.

English synthetic audio passed local synthesis and transcription. Hindi remains experimental: base-model decoding initially returned Urdu script, and a generic Devanagari prompt improved script selection but still had word errors. The separately verified small model is now the Hindi default: the short synthetic fixture improved from 60% to 20% word error, which remains experimental. Neither synthetic test establishes real human accuracy or noise tolerance.

### Meetings

Imported audio/video is decoded natively into bounded 16 kHz mono audio. Explicit microphone recording seals 30-second chunks, keeps a bounded transcription backlog and stores sensitive records with AES-GCM. Key material resides in an app-specific, non-synchronizing Keychain entry. Plaintext processing files live in private temporary locations and are removed after processing; crash-proof erasure is not claimed.

ScreenCaptureKit system capture requires a fresh macOS picker selection and an acknowledged consent checkbox. It excludes Mewpon audio, captures the selected target, and saves images only with the per-session slide option enabled. A serial callback queue owns audio writes. Stop flushes final PCM and awaits delivery before returning. Capture is bounded to two hours and 240 changed frames. Frames are sampled at most once per second, compared at low resolution, and saved at most once per three seconds after a meaningful change. This is frame-change detection, not semantic slide understanding. It does not bypass application restrictions or auto-join meetings.

Notes, bookmarks, highlights, decisions, comments and manual speaker labels are stored locally. Offline automatic diarization uses a source-built sherpa-onnx C helper, CNRS segmentation and a 3D-Speaker embedding model. A public 56.861-second four-speaker fixture produced four clusters in approximately 6.7 seconds. Labels require high confidence and at least 80% segment coverage; mixed or uncertain segments stay unknown. Manual names are preserved. Clusters do not identify people, and real English/Indian English/Hindi meeting quality remains unverified.

Meeting search combines lexical and available native semantic similarity on a background actor, with cancellation and a 200 ms debounce. No unencrypted transcript search database was added. Search retrieves evidence; it does not infer the current user’s identity.

Local summaries use bounded transcript groups and schema-constrained Ollama JSON with no tools. Every stored quote must occur verbatim in the referenced transcript segment, and owners/deadlines must be present as complete terms in that quote. Invalid results are rejected. These are grounded extractive notes, not a guarantee of complete executive summaries or reliable action classification. TXT, Markdown, SRT, paginated PDF, recording WAV and actual captured PNG exports are implemented. Existing files are not silently overwritten. Grounded action notes can be tracked and marked complete without inventing deadlines. Configurable retention selects old inactive meetings for an explicit Apply action, moving their encrypted records and attachments to recoverable Trash in batches; it does not silently run a deletion monitor.

### Productivity

Encrypted local reminders support future times, completion, daily/weekly recurrence and an optional notification horizon of 40 occurrences. Recurrence uses Calendar arithmetic across daylight saving changes. Notification authorization remains separate and opt-in; reminder storage works without it. Global pause removes the assistant’s scheduled reminder notifications.

EventKit reads already authorized calendars/lists. Event writes validate dates, check conflicts, require an exact writable calendar and verify readback. Account writes remain off unless explicitly enabled, since macOS can synchronize them. Google/Microsoft access exists only through accounts already configured in macOS; no external account connection was created.

Contacts lookup searches a requested name and retrieves only names, phone numbers and email addresses. It does not enumerate notes/photos. Email drafting opens the native Mail composer only after reviewing recipient, body and attachments. Mewpon does not automatically send the draft. Email account search, automated Messages/FaceTime calls and external send APIs are not connected.

### Information, proactive features and native controls

Online tools default to denied. Explicitly enabling them permits bounded HTTPS requests to fixed Open-Meteo and BBC sources, with timestamps and attribution. Current/tomorrow weather and news/sports headlines passed public-fixture checks; headlines are not live sports scores. Explicit browser URL/search requests use the native browser. Queries derived from private history require separate action review even with standing online permission. An explicit offline request blocks network use.

Unit conversion and explicit time-zone queries run locally. English/Hindi translation uses local Ollama with tools disabled and schema-constrained output. The installed 8B model passed the two short meaning checks; the 4B model failed the Hindi meaning check. These are narrow fixtures, not a translation quality benchmark. Translation uses a shared inference lease and does not change the selected chat model.

Upcoming-meeting notifications and a scheduled local daily briefing are implemented as separate opt-ins, requiring notification authorization. Briefings require the app to be running. Both remain off and live notification delivery is unverified. New native Hide/Close actions and an optional voice shortcut are implemented; the existing mew → Command launcher remains intact. Their updated UI behavior awaits live verification.

On the user's request, Mewpon and QuickTime windows were hidden/minimized and playback/capture stopped while applications remained running. Subsequent work uses background builds and headless checks; no foreground UI verification or app restart is performed during this constraint.

## Verification

- Full Swift suite: see Verification/Phase7/checkpoint-tests.log. Latest completed broad run: 130 tests, 14 optional environment-dependent skips, zero failures.
- Latest background-only regression run: 52 tests, seven optional skips, zero failures (background-regression-tests.log). It intentionally excludes window-opening UI checks.
- Real opt-in English synthesis, Whisper import, schema-constrained local summary and storage integration: phase7-integration-tests.log; 14 tests passed, no skips in that run.
- Avatar engine: 47 tests passed. Existing native/avatar regression tests also run in the broad suite.
- Voice Studio live: Preview showed Speaking locally, Stop immediately returned Ready, and studio-ui-export.wav was saved. Native afinfo verified a 4.286-second, mono 22.05 kHz Float32 WAV.
- Local model summary fixture returned three grounded quotes; details and timing are in summary-benchmark.json. Synthetic, not a real meeting quality benchmark.
- Cold and warm ASR timings differ substantially. Initial English fixture: ~7.3 seconds cold; later warm short fixture: ~0.4 seconds. Standalone bundled CLI resource run: 1.12 seconds wall, ~337 MiB maximum RSS, zero swaps. These figures do not predict long meeting latency.
- Process-resource snapshot is an instantaneous observation, excludes WebKit/Ollama helpers, and is not a total/peak app memory measurement.
- Microphone and Speech Recognition show allowed in the native interface. Live human transcription result is awaiting the user’s report.
- Calendar showed granted; Reminders and Contacts were requested under explicit approval. Final permission/readback checks are tracked separately.
- The first controlled capture selected the wrong window and produced silent audio. Capture stopped, the test record was moved to recoverable Trash, and the exported test image was removed. Source now separates Prepare from Start and validates the selected owning application before recording. A live retry remains pending; system audio is not verified.
- Actual offline diarization evidence: diarization-benchmark.json and diarization-tests.log. Native helper resource run: 6.54 seconds wall, approximately 247 MiB maximum RSS, zero swaps. Runtime archive publisher digest and model download provenance are recorded separately.
- Online public-fixture checks: online-source-tests.log. Local 8B translation fixture checks: translation-8b-tests.log. New UI controls have not been exercised while windows must remain in the background.

## Remaining work

Phase 7 acceptance remains open: real human speech/noise/Hindi evaluation; system-capture live verification; real-meeting diarization quality; more complete meeting summaries; retention UI verification; real EventKit write/notification delivery tests; upcoming-meeting and daily-briefing delivery checks; browser workflow UI verification; traffic/live sports sources; broader translation evaluation; expanded media/podcast controls; account email integrations and supported communication flows; measured sustained resource/latency tuning.

Milestone 1 has verified native execution evidence. Milestones 2–4 contain working code and fixture evidence but retain the live checks/limitations above. Milestones 5–7 are not declared complete. Existing Phase 6 native system/window/file/media capabilities remain available; the entire Phase 7 wish list is not represented as implemented.

Research and API references: PHASE7_RESEARCH.md. No new permission is silently granted on startup. No wake recording or capture starts merely by opening a workspace.
