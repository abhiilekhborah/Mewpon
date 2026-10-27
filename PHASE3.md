# Mewpon Phase 3 performance report

17 October 2026 · Version 1.3.0 build 6 · MacBook Air M4 target · observed hardware Mac16,12 with 16 GiB memory

## Result

The existing app now uses a Swift deterministic fast path for explicit common commands. Arithmetic, time, system information, app/folder opening, supported file searches, and search-and-open workflows no longer require model inference. General questions and contextual requests retain the Ollama agent. The current UI, artwork, outfits, animations, Play Mode, tool schemas, action confirmations, and restricted execution model remain in place.

## Changes implemented

- `FastIntentRouter` uses normalization, token-level command grammar, bounded intent caching, stable folder/application aliases, and a small explicit typo dictionary. Ambiguous references ask for clarification or use the model. Negation, explanatory questions, quoted instructions, multiple commands, and contextual file references do not enter the fast execution path. Explanation/negation/quoted contexts also omit tools and reject unsolicited model tool calls at execution time.
- `HybridAgentController` runs every deterministic action through the original `ToolRouter`. It never grants authorization itself. Search-and-open requests obtain search approval, inspect current actual results, and obtain a separate open approval only for a single complete result. Empty, multiple, and partial results never auto-open. Failure or cancellation stops dependent steps; independent operations are not artificially serialized beyond the existing request boundary.
- `ApplicationRegistry` caches up to 2,048 discovered applications and 128 resolved lookups. It coalesces registry builds, refreshes after two minutes, and rechecks cached application paths. It scans application roots only, skips package descendants, and never scans the full disk. Native LaunchServices resolution and aliases remain supported. An already-running app is activated by NSWorkspace.
- Spotlight still uses `NSMetadataQuery` in the home scope. It supports literal names, `PDFs named report`, `PDFs from last week`, `Python file named main`, and `recent presentations`. Last week means the previous Monday-to-Monday calendar week; recent means 30 days. Filters are bound predicates, not interpolated query strings. Results rank exact names, prefixes, modification date, then path. Metadata snapshots are bounded to 256 candidates and results to 20. Progress callbacks update the existing result row; useful bounded results can return early with an explicit incomplete flag. Five-second gathering and eight-second tool deadlines remain.
- Application and document/folder opening use asynchronous NSWorkspace APIs. A cancellation-safe completion gate prevents late callbacks from resuming a finished request twice. An OS action already handed off can still finish after cancellation; no rollback is claimed. Native-action timeouts now describe the OS action instead of incorrectly blaming the local model.
- Static hardware and folder metadata is retained for the process lifetime. Battery, storage, VM statistics, date/time, and file results are read fresh. No stale battery response or cached file-search result is replayed.
- Ollama reuses its existing ephemeral URLSession, retains loopback-only endpoints and redirect rejection, and caches installed-model metadata for 30 seconds. Explicit Refresh models bypasses that cache. On a model switch it unloads only the preceding selection owned by the service. Keep-alive is configurable from 0 to 900 seconds, with 300 seconds retained as the default. No models were downloaded.
- Context budgeting estimates serialized input cost conservatively and drops complete oldest turns, preserving assistant/tool-call relationships and the newest request. It includes tool-schema cost and generation reserve. An oversized latest request fails clearly instead of silently truncating it. Security instructions stay intact. The omission notice asks the model to clarify missing context. No extra inference is spent on automatic summarization.
- Explanations and code-writing omit tool schemas. The prompt now explicitly permits writing code as text while forbidding execution, and clarifies that a denied desktop action does not prohibit answering later questions. Thinking controls are sent only for a supported model family or advertised capability. The 4B instruct sample returned no separate thinking in the on/off probe, so no reasoning-speed advantage is inferred from that probe.
- The first useful streamed text is assigned immediately; later text updates are batched at 40 ms. Parsing uses one decoder per stream and bounded response/line sizes. Cancellation and incomplete-stream errors remain supported. The chat display is bounded to 120 entries, and the existing conversation storage limits remain.
- The avatar inverse sampler skips transparent padding outside displacement extrema. Sixty irregular fields produced byte-for-byte identical output to the frozen prior sampler. Textures, logical-grid resolution, expressions, and Play Mode are unchanged. Normal active rendering remains 60 fps, idle at most 30, and hidden views stop. An optional `Prioritize inference` setting caps the avatar at 30 fps only during model requests, then restores 60; it is off by default and does not change artwork resolution.
- `PerformanceProfiler` records monotonic routing, validation, authorization wait, execution, model load, first useful output, generation, UI assignment, and bridge timings. It retains at most 64 categories with 512 samples each, plus kernel-reported peak main-process RSS. Settings can save the local JSON report. It contains no prompt text, arguments, file paths, result bodies, or permission grants.

## Measurement method

Baseline native measurements and all eleven original-model prompts were recorded before optimization. The model routing probe used the real pre-change Ollama service, full tool schemas, Qwen3 8B, context 4,096, temperature 0.4, and a controlled 128-output-token cap. Tool calls were inspected without executing generated actions. This cap makes the routing probe unsuitable as a complete code-quality test; a separate 384-token quality run generated complete functions.

Swift uses ContinuousClock; auxiliary local HTTP comparisons use a monotonic clock. Native timing tests are debug builds; packaged-app checks use the release build. Percentiles use nearest ranks. p95 is reported only with at least 20 samples and p99 only with at least 100. Low-count samples are exploratory. Tests were sequential across models. Model load, prompt-cache warmth, system swap, other apps, and OS activation affect results. No target is presented as a guarantee.

### Native backend before and after

All values are milliseconds. These times exclude model inference and action-confirmation waiting. Lookup is not launch completion. The absent-query test is a real Spotlight query, not a cached search response.

| Operation | Before/after n | Before p50 | After p50 | Time reduction |
| --- | --- | --- | --- | --- |
| Warm Safari lookup | 30/30 | 0.0160 | 0.0017 | +89.6% |
| Warm Finder lookup | 30/30 | 0.0150 | 0.0018 | +88.1% |
| Repeated absent application lookup | 5/5 | 8.61 | 0.3337 | +96.1% |
| Fresh system information | 30/30 | 5.13 | 5.10 | +0.6% |
| Native date and time | 30/30 | 0.0178 | 0.0190 | -6.8% |
| Native calculator | 100/100 | 0.0020 | 0.0023 | -12.2% |
| Spotlight absent filename query | 3/3 | 99.12 | 96.28 | +2.9% |

Positive app lookups and native arithmetic were already fast; the main user-visible gain is removing the preceding model request. The absent-application improvement comes from registry reuse. Small regressions in arithmetic/date timings are microbenchmark variability, not hidden or rounded into an improvement. Spotlight changes improve structure and progress but did not remove index/OS costs.

### Routing for the eleven requested commands

The before column is one baseline model request's first content/tool-call output, including a cold first Safari request. After columns measure classification only, 100 samples per prompt. These are deliberately different architectural stages: a model classification dependency was replaced by a native router. They are not end-to-end OS latency, and no speedup ratio is calculated between them. General questions still go to Ollama after classification.

| Command | Before model first output ms n=1 | After router p50 ms | After router p99 ms | Destination |
| --- | --- | --- | --- | --- |
| Open Safari. | 8669.5 | 0.0050 | 0.0096 | Native |
| Open Finder. | 1053.5 | 0.0054 | 0.0066 | Native |
| Show Downloads. | 1066.3 | 0.0058 | 0.0065 | Native |
| What's my battery? | 897.5 | 0.0067 | 0.0084 | Native |
| What time is it? | 1003.7 | 0.0063 | 0.0066 | Native |
| Calculate 145 × 23. | 1426.1 | 0.0083 | 0.0120 | Native |
| Find my resume. | 1124.6 | 0.0065 | 0.0082 | Native |
| Find PDFs named report. | 1202.5 | 0.0080 | 0.0102 | Native |
| Explain recursion. | 197.8 | 0.0214 | 0.0254 | LLM |
| Write a simple C++ binary search function. | 192.4 | 0.0376 | 0.0438 | LLM |
| Find my report and open it. | 1104.7 | 0.0088 | 0.0101 | Native |

### Models and quality

Both compared text models were already installed, Q4_K_M. Other installed vision variants were not selected for this text-only task.

| Measurement | Qwen3 8B | Qwen3 4B instruct |
| --- | --- | --- |
| Reported resident model allocation at 4,096 context | 5,569,815,510 bytes | 3,175,339,786 bytes |
| Eleven-prompt probe generation range | about 18.5–20 tokens/s | about 33.6–38 tokens/s |
| Separate complete binary-search sample | 20.0 tokens/s; 5.63 s total | 36.8 tokens/s; 2.97 s total |
| First recursion sample with model loading | 4.36 s first output; 3.38 s load | 2.09 s first output; 1.58 s load |
| Subsequent warm first-output samples | 0.181 s and 0.055 s | 0.122 s and 0.047 s |

These model samples are too few and too varied for p95/p99 or a broad quality ranking. In the eleven-prompt dry run, 8B selected a search tool for search-and-open, while 4B requested clarification. The deterministic workflow now handles that case safely without either model. Both complete C++ samples compiled and passed found/missing/first/last checks. During packaged-app testing, 4B initially refused a code request following a denied search; prompt clarification fixed the denial-context benchmark for both models. The new context-quality outputs are retained rather than silently excluding that failure. A final packaged-app request also displayed the complete C++ function after the prompt correction.

For this Mac, the selected everyday profile is the existing `qwen3:4b-instruct`, 4,096 context, 768 response tokens, temperature 0.4, Automatic thinking, and 300-second keep-alive. Qwen3 8B remains available for harder work. The source's fallback model default remains 8B; the tested machine's preference was set to the installed 4B instruct model. This recommendation considers memory, latency, and the limited functional checks; it is not a claim that 4B matches 8B on complex reasoning. No MLX backend was installed or benchmarked, and no evidence justified migrating away from Ollama.

### Avatar and inference

The bounded sampler's local Node benchmark changed from 0.374 to 0.221 ms p50 across 60 fields, a 40.9% reduction. This is sampler time, not full renderer or GPU frame time. The live native working-animation check observed 59.4 fps, 1.0 ms p95 JavaScript draw time, and one loop over about 2.2 seconds.

A clean warm 4B inference comparison measured median 32.86 tokens/s with the working avatar visible versus 35.23 with it paused, three samples each after warmup. The samples are small and system state is uncontrolled, so they suggest possible contention rather than establish GPU causality. An earlier active sample overlapped compilation and is excluded from this comparison. The optional 30 fps inference mode is implemented and its budget/restore behaviour tested; its throughput benefit has not been separately quantified.

## App observations and remaining limits

- A command succeeded with a nonexistent model selected, confirming that the native route does not require model availability. Calculator returned 3335, time returned the device time, Finder opened after Allow once, a denied resume search stopped, and the asynchronous Downloads request completed. The initial synchronous Downloads check timed out; the later asynchronous callback took approximately 3.06 seconds in one sample. That is OS completion, not routing, and different OS conditions prevent a causal percentage comparison.
- The initial release-app export measured submit-state assignment at 0.247 ms p50, native routing at 0.554 ms p50, and main-process peak RSS at 125,566,976 bytes (about 120 MiB), each from a short interactive sample. The first text-assignment instrumentation included actor scheduling; it was corrected to capture elapsed mutation time before dispatch. The corrected final export measured submit assignment at 0.262 ms p50 (n=2) and text assignment at 0.097 ms p50 (n=132), with 122.5 MiB peak main-process RSS. UI-state assignment is not physical input-to-display-paint latency.
- The initial bridge round-trip sample was 8.28 ms p50 and 45.45 ms p95 (37 calls, including initialization). The under-16-ms avatar target is not established at p95. Screen-paint latency and keyboard event-to-photon timing were not measured.
- Main-process RSS excludes WebKit and Ollama. A later process snapshot showed about 68 MiB main-process RSS and 25 MiB WebKit RSS while hidden, plus the model runner. These are per-process RSS readings, not additive physical-footprint accounting. GPU allocation is from Ollama; GPU utilization was not directly sampled.
- System-wide swap was already about 6.9 GB at baseline and varied up to about 7.5 GB later with other apps running. Those readings cannot be attributed to Mewpon. macOS reported no recorded thermal warning; this does not establish absence of throttling. Sustained battery, GPU, and leak profiling remains open.
- Spotlight privacy/indexing can omit files, and the tests allow zero matches in an unindexed checkout. No protected folder was indexed, no private full-disk cache was created, and no nonexistent path is invented. Search-date filters use filesystem modification time.
- Confirmation waiting remains intentional and is measured separately. The OS can take seconds to activate an app/open a folder. The app cannot guarantee millisecond completion for those operations. No browser session, security setting, tool permission, or permanent authorization was expanded.

## Verification and reproducibility

The full Swift suite passed 45 functional tests with five opt-in benchmark tests skipped. The final targeted routing, native WebKit expression, and transport checks passed after quote safety and the optional frame budget were added. The TypeScript suite passed 47 tests and type checking. The asset audit verified 277 unchanged bundled PNGs and the supported catalog. The release app is ad-hoc signed for local use; strict code-sign verification passed.

Raw evidence is under `Verification/Phase3`: native-before/after.json, model-before-8b.json, model-after-8b.json, model-after-4b.json, quality-model-comparison.json, context-quality.json, thinking-comparison.json, routing-after.json, warp-comparison.json, clean contention samples, system snapshots, app metric exports, and summary.json. No raw user document contents were collected.

Normal checks, from the Mewpon directory:

```bash
cd AvatarEngine
npm run typecheck
npm test
npm run build
cd ..
swift test --disable-sandbox
python3 scripts/verify-avatar.py
bash scripts/build-app.sh
```

The opt-in `PerformanceBenchmarks` tests require explicit output environment variables: `MEWPON_BENCHMARK_OUTPUT` for native tools, `MEWPON_ROUTING_BENCHMARK_OUTPUT` for routing, `MEWPON_MODEL_BENCHMARK_OUTPUT` for the eleven-prompt model probe, `MEWPON_QUALITY_BENCHMARK_OUTPUT` for complete-code/repeated warm samples, and `MEWPON_CONTEXT_BENCHMARK_OUTPUT` for denial-context quality. Use `MEWPON_BENCHMARK_MODEL` to select an installed model and `MEWPON_BENCHMARK_OPTIMIZED=1` to omit schemas for explanation/code prompts. Do not run model comparisons concurrently with builds, other inference, or the native regression suite. The retained developer helpers `scripts/benchmark-contention.py LABEL`, `scripts/benchmark-thinking.py`, and `scripts/profile-system.py` reproduce the auxiliary local HTTP and system samples; Python is not used by the application command path.

API references: [Ollama chat and metrics](https://docs.ollama.com/api/chat), [resident models](https://docs.ollama.com/api/ps), [Apple metadata queries](https://developer.apple.com/documentation/foundation/nsmetadataquery), and [asynchronous NSWorkspace opening](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:configuration:completionhandler:)).
