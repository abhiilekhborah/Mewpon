# Mewpon 1.6.0 — speed, tolerant commands, and local content search

Implementation record, 24 October 2026. Existing Swift/AppKit/SwiftUI application; original avatar, outfits, expressions, animations, and Play Mode retained.

## What changed

Simple commands go through a local interpreter before Ollama. Known abbreviations and a small command vocabulary use case/whitespace normalization, Damerau–Levenshtein distance, and an unambiguous best-match requirement. Correction is confined to command words and known app/folder aliases. Search expands purpose terms separately; literal paths retain their case and spelling, including in the routing cache. Negations, explanatory questions, quotes, chained commands, and unsupported instructions retain the conservative fallback and tool-authorization boundaries.

Examples now routed locally include `vs cod`, `serch internship repot`, `opn dwnloads`, `btry lvl`, `vol 30`, `whr my resume pdf`, and `opn latest py prj in vs cod`. `dont opn safari` and `how to opn safari` do not become desktop actions. Unknown app names still go through installed-app resolution; a correction never substitutes an arbitrary file path.

`open cv` searches first. A unique, complete search result can be opened through the existing validated open tool; bounded/incomplete hybrid results require selection. A single candidate from an incomplete search is not treated as proof of uniqueness.

## Enable content search

Open Settings → Privacy → Add folder. Choose a specific folder containing documents or projects. Mewpon does not automatically index Documents, Downloads, the home folder, or the disk. Spotlight filename search remains available without content indexing.

The additional index uses the macOS system SQLite library with FTS5. It keeps supported filenames, bounded extracted text, modification time, size, root authorization, and confirmed aliases locally in the app's Application Support directory. SQLite and document extraction run on serialized background actors, away from the UI thread. Index directories/files use owner-only permissions. There is no embedding model, remote search service, or upload.

Supported indexed content: selectable PDF text and UTF-8 `txt`, `md`, `csv`, `swift`, `py`, `json`, `yaml`, and `yml`. Existing extraction limits apply: regular files below 20 MB, excerpts up to 3,000 characters, at most eight PDF pages, and at most 64 KB read for text. Scanned PDFs, images, Office contents, and unsupported encodings are not covered by this index. Existing explicit OCR/document tools remain available.

Indexing is incremental by modification time and size. Each authorized folder is bounded to 20,000 visited entries / 5,000 supported files per refresh. Hidden files, packages, symlinks, dependency trees, and build output are skipped. Changed or missing files are revalidated before search results are returned; stale content evidence is excluded. A background refresh is scheduled after searches, no more than once per 30 seconds, and Settings provides an immediate refresh. This is metadata polling on demand, not a continuous filesystem watcher. Removing folders removes their active index records and authorization; it is not a secure-erasure guarantee for storage backups.

## Retrieval and associations

Search first returns available FTS matches, then merges/refines them with Spotlight results. Queries recognize file types in either position, common misspellings, purpose synonyms, and supported relative dates. Candidate sets are bounded to 256 before a maximum of 20 displayed results. Ranking combines FTS BM25, confirmed aliases, filename evidence, edit-distance similarity, and Spotlight modification metadata. Broader prefix terms improve typo recall, so results remain candidates rather than assertions of identity.

A transparent purpose rule adds a resume tag when an extracted excerpt contains at least three of education, experience, skills, and projects. This can discover a resume whose filename says neither CV nor resume, but it is a heuristic, not general semantic understanding. Explicit aliases provide stronger evidence.

Use a file row's menu → Remember as my CV. After a search returned one candidate, `this is my cv` or `this is my resume` also stores the association without an LLM call. Multiple/no prior candidates require selecting the exact file. Only files already in an authorized content index can acquire an alias. With direct actions enabled, an explicit confirmed association does not add another approval dialog.

Early indexed results can be selected while Spotlight is still working. Mewpon cancels and awaits the outstanding request before opening the selected item, so late search callbacks cannot replace the new task. Explicit result opening uses the same schema and file-type validation; the direct-action setting avoids a redundant approval for the user's selected open action. Sensitive/document/context/system tools keep their approval requirements.

## Python project workflow

The interpreter recognizes recent/latest Python project requests and VS Code aliases without model reasoning. Discovery uses indexed Python files inside authorized folders, prefers enclosing `pyproject.toml`, `requirements.txt`, `setup.py`, or `.git` markers, and orders project candidates by Python-file modification date.

A sole candidate from a completed authorized-folder refresh can be opened automatically. Multiple candidates or an incomplete index are shown for selection; recency alone is insufficient. A selection from a VS Code workflow retains VS Code as its target. Exact LaunchServices/running-app bundle identities can resolve registered apps outside the standard Applications directories, including translocated VS Code. Arbitrary supplied application paths remain restricted. The selected folder is revalidated against current authorized indexed projects before LaunchServices receives it. The app uses `NSWorkspace`, never shell commands or project-code execution. A success message reports the OS callback/acceptance rather than asserting that a particular editor document has painted.

## Model and UI performance

The installed `qwen3:4b-instruct` Q4_K_M model remains selected for these measurements. The installed alternatives were 4B variants and an 8B model; no smaller model was available. No model was downloaded and no unrelated resident model was unloaded. The client retains local loopback streaming, bounded context/history, cancellation, deadlines, metadata caching, and a single selected-model keep-alive. Preloading now uses the configured context size to avoid warming a different-sized context.

Typing immediately updates native text storage and local avatar state. Repeated identical typing/attention events no longer send redundant WebKit bridge updates. Native task completion preserves success/failure expressions instead of immediately replacing them with a speaking expression. Renderer assets and Play Mode were preserved. Stream text remains batched rather than rebuilding the UI for each token.

Native visual verification also fixed packaged menu-icon sizing, unnecessary single-line composer scrollbars, visible Settings section navigation, and a progressive-result sizing bug. AppKit marks programmatic frame animation as live resizing; deferring all updates during that state clipped a fast one-file result. Layout now defers only while an actual mouse resize gesture is held and applies pending geometry afterward. A native regression test covers working → one result → completion. Content replacement no longer animates old/new transcript blocks together. Window movement, explicit hide/show behavior, keyboard navigation, and accessibility preferences remain supported.

## Measured results

Raw samples and logs: `Verification/SpeedSearch/`. The original routing and native baselines were collected before production speed/search edits. Routing used the same 15 prompts, 100 trials each, including 13 action requests and two safety controls. These are debug-build backend measurements on this Mac, predominantly warm; they exclude keyboard-event delivery, display painting, and app startup.

| Measurement | Samples | Before p50 / p95 | After p50 / p95 |
| --- | ---: | ---: | ---: |
| Cached routing, mixed suite | 1,500 each | 0.0183 / 0.0468 ms | 0.0135 / 0.0259 ms |
| Cached Safari lookup | 30 each | 0.0016 / 0.0098 ms | 0.0018 / 0.0033 ms |
| Native system information | 30 each | 5.48 / 21.24 ms | 5.48 / 5.87 ms |
| Native date/time tool | 30 each | 0.0219 / 0.0403 ms | 0.0203 / 0.0345 ms |

The useful improvement is routing coverage: four of the 13 action prompts previously reached the intended native tool family; now all 13 do. Previously, six required model fallback and three incorrectly attempted application lookup for a folder/project request. Both safety controls continue to avoid a deterministic action. These counts establish this suite's behavior, not arbitrary language accuracy. Tiny timing differences between already-fast cached operations should not be treated as universal speedups.

| Additional measurement | Samples | p50 / p95 |
| --- | ---: | ---: |
| Authorized FTS search, initial run | 300 | 0.223 / 0.290 ms |
| Authorized FTS search, final repeat | 300 | 0.182 / 0.269 ms |
| Routing → native date/time dispatch | 100 | 0.0160 / 0.0178 ms |
| Route + validate + execute date/time | 100 | 0.0665 / 0.0750 ms |
| Routing → calculator dispatch | 100 | 0.0156 / 0.0211 ms |
| Route + validate + execute calculator | 100 | 0.0347 / 0.0555 ms |

The FTS fixture was a real, generated selectable-text PDF, `Alex_Example_Final_2026.pdf`, containing education, experience, skills, and projects. It was explicitly authorized in an isolated index; searches for CV, education/projects, and internship found its actual path. Initial indexing took 5.21 ms in one run and 3.43 ms in a repeat. This tiny controlled library is not a large-library benchmark. There was no FTS implementation before this change, so no fabricated FTS before-time is provided. The unchanged native tool microbenchmarks above are not complete desktop-operation latencies.

Spotlight absent-query trials were sparse: three each, p50 100.6 ms before and 406.8 ms afterward, with no meaningful p95. They ran under different cache/load conditions and do not establish a Spotlight speed improvement. Early content-index results reduce dependence on waiting for Spotlight; final Spotlight gathering still has a five-second bound.

### Local inference measurements

Controlled loopback HTTP streaming, installed 4B instruct model, 4,096 context, maximum 128 generated tokens, temperature zero, thinking off, 300-second keep-alive. The warm trial repeats a short two-sentence binary-search question, benefiting from residency and prompt caching. It does not represent every production prompt/history/tool set.

| Measurement | Samples | p50 / p95 |
| --- | ---: | ---: |
| Warm first visible text token | 20 | 45.3 / 63.3 ms |
| Warm complete short response | 20 | 1,559 / 1,634 ms |
| Warm model-load metadata | 20 | 0.73 / 1.08 ms |
| Generation throughput | 20 | 35.0 / 36.3 tokens/s |

One genuinely non-resident trial recorded 3,361 ms of model load, 3,578 ms to first text, and 5,060 ms to completion. These are single cold samples, not cold percentiles. Cold/warm comparison describes residency and caching, not a claimed rewrite of Ollama inference. Five additional structured Open Safari probes returned the expected function and application argument; no probe executed an action. Five repetitions of one tool request do not establish broad tool accuracy.

Ollama reported one resident model using 2,897,215,487 bytes (about 2.90 GB decimal), with the same amount reported as VRAM. The separate native review profiler records main-process RSS and UI-assignment/bridge timings; it excludes WebKit and Ollama. An idle process snapshot is also saved. These are not before/after CPU or whole-system peak-memory benchmarks, so no CPU-reduction percentage is claimed.

### Verification limits

Cold application-launch p50/p95, full keyboard-to-painted-frame latency, large mixed personal-library relevance, and sustained inference CPU/GPU utilization were not measured with enough trials. Native app-opening checks are single functional observations, separate from cached lookup. The computer-use tool cannot generate a modifier-only Command key, so physical `mew` then Command remains a manual hardware check; sequence recognition and visibility transitions have automated coverage. A long native-automation launch stall occurred during review and is excluded from backend latency samples rather than attributed to the app.

## Final verification

The final native suite discovered 92 tests: 83 passed, nine were skipped, and none failed. Skips were the opt-in benchmark methods (run separately where reported above) and the optional pre-imported Spotlight fixture. Additional registry tests verified exact bundle identity outside standard app roots and this Mac's registered VS Code lookup.

The live review app completed `fnd my cv pdf` against the authorized generated document, displayed its actual row, and stored `this is my cv` without another approval after the direct-action fix. The real Python workflow returned the successful `NSWorkspace` callback for the sole controlled project. This Mac has both a Downloads and a translocated VS Code registration; computer-use automation could not bind the editor afterward, so the report does not claim that an editor document painted. This is an OS acceptance observation, not a repeated launch benchmark. Light and dark screenshots were visually checked after correcting adaptive glass foreground contrast. A final seven-test layout/readability run passed after a new test ensured multi-line native results expand into the response view; the production battery command visibly showed its actual battery line. The production Settings panel reported the mew → Command listener Ready.

## Reproduce

From the project directory, prefix shell commands with `rtk` as required by the workspace:

```bash
rtk proxy swift test
rtk proxy env MEWPON_SPEED_OUTPUT=/private/tmp/mewpon-routing.json swift test --filter SpeedSearchTests/testRoutingBenchmark
rtk proxy env MEWPON_SEARCH_OUTPUT=/private/tmp/mewpon-fts.json swift test --filter ContentIndexTests/testContentSearchBenchmark
rtk proxy env MEWPON_TASK_OUTPUT=/private/tmp/mewpon-tasks.json swift test --filter SpeedSearchTests/testNativeTaskBenchmark
rtk proxy env MEWPON_BENCHMARK_OUTPUT=/private/tmp/mewpon-native.json swift test --filter PerformanceBenchmarks/testOptInBaseline
rtk proxy python3 scripts/benchmark-local-inference.py /private/tmp/mewpon-inference.json
rtk proxy python3 scripts/summarize-speed-search.py
rtk proxy bash scripts/build-app.sh
```

The inference script requires Ollama and the already-installed model and declines to run if another model is resident. It never downloads models or executes returned tool calls. The summary script reads the saved verification dataset and omits p95 for fewer than 20 samples. The packaged native review copy has a separate bundle identifier, no global shortcut registration, and controlled visual fixtures; production never loads those fixtures. Screenshot labels distinguish layout fixtures from actual search/command results.
