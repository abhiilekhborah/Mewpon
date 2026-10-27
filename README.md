# Mewpon

A local AI desktop companion for macOS that combines natural-language commands, native Mac controls, and an animated character.

Mewpon lives beside your work. Ask a question, open an app, find a document, arrange a window, or take a break in Play Mode. Common commands run through native Swift tools; open-ended conversations use an Ollama model running on your Mac.

**Status:** active development. Version 1.8.0 is a Phase 7 preview. Core desktop features have live verification; newer voice, meeting, and productivity features have additional limitations documented in [the implementation record](PHASE7.md).

## What Mewpon can do

- **Control everyday Mac tasks:** open apps and folders, adjust volume, check battery, switch macOS appearance, and arrange supported application windows.
- **Find your files:** search filenames and content in folders you explicitly add, with tolerant matching and actionable results.
- **Combine actions:** execute supported multi-step requests and save reusable routines, while respecting your permission settings.
- **Answer locally:** chat with an installed Ollama model, with streaming responses and optional model warm-up.
- **Be a desktop companion:** expressive avatar animations, original outfits, petting, high five, activities, and a separate Play Mode.
- **Fit your desktop:** six themes, including Liquid Glass on supported macOS versions, with native material fallbacks.

## Phase 7 preview

- **Voice:** on-device Apple Speech where supported, local Whisper transcription, and a Voice Studio with installed macOS voices, WAV export, and avatar playback metering. Optional wake listening is off by default.
- **Meeting workspace:** audio/video import, encrypted local records, transcript search, notes, evidence-linked extractive summaries, offline speaker clustering, and document exports.
- **Productivity:** local reminders, optional Calendar/Reminders/Contacts integration, reviewed Mail drafts, and opt-in notifications.
- **Information tools:** local unit/time-zone conversion, experimental English/Hindi translation, and explicitly enabled weather and news sources.

System-audio capture still needs a successful controlled live verification. Human speech accuracy, real-meeting speaker quality, and notification delivery also need broader evaluation. These previews are not a claim of unrestricted Mac control or complete meeting understanding.

## Try it

| Ask Mewpon | What happens |
| --- | --- |
| `Open Safari` | Opens the application through macOS. |
| `What time is it?` | Returns your Mac's current local time. |
| `How much battery do I have?` | Reads native battery information. |
| `Calculate 17 * (8 + 4) / 3` | Calculates locally without model inference. |
| `Change to dark mode` | Changes macOS appearance with the required permission. |
| `Find my resume` | Searches permitted folders and presents matching files. |
| `Explain recursion` | Streams an answer from your local language model. |

Type **mew**, then press **Command** to show or hide Mewpon when the optional launcher is enabled. The launcher can reopen the app after Quit and requires its own Input Monitoring permission. A conventional configurable global shortcut is also available.

Click the character to access **Play with Mewpon**. Drag the avatar or panel background to move it. Settings contains themes, models, privacy controls, and feature configuration.

## Local by default

Language-model inference stays on your Mac. Core desktop commands do not need a cloud AI account or API key. Model installation requires a download; online weather, news, browser navigation, and account-backed macOS services can use the network when explicitly enabled or invoked.

Folder access and macOS permissions are feature-specific. Wake listening and meeting capture do not start merely because a workspace opens. Sensitive meeting records use AES-GCM encryption with an app-specific Keychain key. Capability policies control supported actions, and the interface reports actual tool outcomes.

## Build and run

Requirements:

- macOS 14 or later; Apple Silicon recommended.
- Xcode and its command-line tools, with a Swift toolchain compatible with the package.
- Ollama running locally for conversation and model-backed features.

From the project directory, install a model of your choice and build:

```bash
ollama pull qwen3:8b
bash scripts/build-app.sh
open build/Mewpon.app
```

Select an installed model in Settings. Common native commands can run without invoking it. First use of an unloaded model can take longer than subsequent responses.

The build script packages an app and signs it using an available development identity, falling back to ad-hoc signing. This is a local development build, not a notarized public release. No third-party Swift packages are required. Optional Whisper and diarization backends need their separately obtained runtimes and verified model files; the build does not download them automatically. See [Phase 7 research and provenance](PHASE7_RESEARCH.md).

Developer checks:

```bash
swift test --disable-sandbox
python3 scripts/verify-avatar.py
```

Some tests require a desktop session or opt-in local model fixtures. SwiftPM's `--disable-sandbox` flag does not disable macOS security protections.

## Built with

Swift, SwiftUI, and AppKit provide the desktop application. Ollama handles local language-model inference. A bundled Canvas avatar runs inside WKWebView. Native macOS frameworks handle supported system actions, speech, audio, and account integrations; optional Whisper.cpp and sherpa-onnx backends handle offline transcription and speaker clustering.

## More details

- [Demo video guide](DEMO_GUIDE.md)
- [Native automation, permissions, and themes](PHASE6.md)
- [Current preview features and verification limits](PHASE7.md)
- [Local search and command performance](SPEED_SEARCH.md)
- [Avatar and Play Mode](PLAY_MODE.md)
- [Avatar implementation record](Docs/Mewpon_Avatar_Implementation_Record.md)

Third-party runtimes, models, and artwork retain their own licenses and notices. See `ThirdPartyNotices` and the relevant provenance records.

Raw local verification captures, machine diagnostics, and personal document exports are intentionally excluded from this repository. Historical implementation records may refer to verification artifacts retained only in the development workspace.
