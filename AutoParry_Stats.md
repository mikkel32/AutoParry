# AutoParry Performance & Reliability Stats

## Default Timing Baseline
- **Activation window**: AutoParry waits just 0.12 s before it considers a target close enough to trigger, with threat prediction spanning a 0.12 – 0.55 s time-to-impact window. 【F:src/core/autoparry.lua†L66-L78】
- **Reaction bias**: Scheduled presses default to firing 20 ms ahead of impact (`pressReactionBias = 0.02`), while smart tuning is allowed to adapt the bias between 10 ms and 120 ms based on observed threat deltas. 【F:src/core/autoparry.lua†L24-L45】【F:src/core/autoparry.lua†L66-L78】
- **Lookahead budget**: Smart scheduling can look up to 0.75 s ahead, keeping slack between 10 ms and 45 ms so presses remain aggressively early without becoming unsafe. 【F:src/core/autoparry.lua†L24-L45】【F:src/core/autoparry.lua†L66-L82】

## Reaction Pipeline Metrics
AutoParry timestamps every stage of the decision pipeline and exposes the numbers in both telemetry and the in-game status label.

- **React** — time from the latest highlight/target detection to the current frame or most recent press. Pending detections display as `React: pending` until a press resolves. 【F:src/core/autoparry.lua†L684-L713】
- **Decide** — latency between detection and the frame where pressing became inevitable. AutoParry preserves the last decision time so the UI still shows the measurement after the press completes. 【F:src/core/autoparry.lua†L684-L746】
- **Commit** — latency from the decision frame to the actual key event, reflecting execution delay (including VirtualInput retries when necessary). 【F:src/core/autoparry.lua†L702-L747】
- The status panel renders these three readouts continuously as `React | Decide | Commit`, giving instant feedback on whether the system is keeping up. 【F:src/core/autoparry.lua†L5141-L5143】

The telemetry test-suite asserts that every press carries valid reaction, decision, and commit latencies, and that aggregated stats (averages, counts, diagnostics summary) stay in sync with the per-press data. 【F:tests/autoparry/telemetry.spec.lua†L124-L185】

## Reliability Under Stress
Target gating, highlight caching, and retry logic keep AutoParry responsive even when Roblox services misbehave.

- **Highlight gate with grace window**: AutoParry requires the character highlight before pressing but grants a 0.2 s grace period so brief highlight flickers never block a late parry. 【F:src/core/autoparry.lua†L122-L126】【F:src/core/autoparry.lua†L3605-L3626】
    - Tests cover both the initial gating delay and the flicker tolerance to guarantee presses continue while the highlight is momentarily missing. 【F:tests/autoparry/parry_loop.spec.lua†L788-L887】
- **Long-frame resilience**: Even if the game hitches for 180 ms mid-approach, the parry still fires on time the very next frame. 【F:tests/autoparry/parry_loop.spec.lua†L970-L999】
- **Remote failures**: The loop keeps pressing when the parry RemoteEvent disappears and automatically recovers once it returns, proving that detection/decision state persists across service outages. 【F:tests/autoparry/parry_loop.spec.lua†L889-L967】
- **Virtual input back-off**: Missing or crashing `VirtualInputManager` calls trigger adaptive retries (50 – 250 ms window) while surfacing a “waiting for input permissions” status so you know why nothing fired. Recoveries reset the retry budget immediately. 【F:src/core/autoparry.lua†L136-L150】【F:src/core/autoparry.lua†L1534-L1599】【F:src/core/autoparry.lua†L3317-L3357】
    - Regression tests simulate a transient failure and ensure a successful retry lands in under 400 ms. 【F:tests/autoparry/parry_loop.spec.lua†L1001-L1053】
- **Smart schedule telemetry**: Every scheduled press logs prediction ETA, lead, slack, and latency samples so you can post-mortem any hesitation. The harness captures a `parry_timeline` artifact for manual inspection. 【F:tests/autoparry/parry_loop.spec.lua†L1056-L1146】

## Telemetry-guided Oscillation Spam
AutoParry continuously folds telemetry summaries back into the oscillation spam engine so burst cadence reflects real outcomes rather than static presets.

- The spam tuner computes a weighted stats pressure score from wait delta, lead delta, commit latency P99, activation latency, reaction time, decision-to-press delay, success rate/miss count, cancellation rate, immediate-fire rate, average threat speed, schedule lookahead percentiles, and threat tempo/volatility before every burst evaluation. 【F:src/core/autoparry.lua†L4156-L4305】
- Positive pressure now shrinks the burst gap, raises burst presses, lowers panic tightness/slack thresholds, and extends the panic window/lookahead to sustain up to 180 Hz bursts without misses; relaxed telemetry restores the base cadence and raises the guards to avoid wasted presses when reactions are sharp and success is high. 【F:src/core/autoparry.lua†L4307-L4709】
- A rolling telemetry trend captures whether recent summaries are heating up or cooling off and nudges the spam tuner accordingly—tightening cadence during spikes while relaxing panic guards once conditions stabilize. 【F:src/core/autoparry.lua†L4287-L4355】【F:src/core/autoparry.lua†L4709-L4807】
- Reaction and decision consistency metrics now surface via `reactionStdDev`, `decisionStdDev`, and `decisionToPressStdDev`, with derived `reactionFocusScore`, `cognitiveLoadScore`, and `neuroTempoScore` steering additional tightening or relaxation so the burst cadence mirrors how quickly (and reliably) the system has been thinking. 【F:src/core/autoparry.lua†L2896-L2954】【F:src/core/autoparry.lua†L4320-L4524】【F:src/core/autoparry.lua†L4563-L4671】
- Every burst captures the derived stats aggression, reaction/decision pressure, miss telemetry, trend momentum, lookahead pressure, and dynamic panic thresholds so telemetry dashboards and the in-game overlay can confirm how the tuner responded. 【F:src/core/autoparry.lua†L4824-L4881】
- Specs cover aggressive, relaxed, lookahead-collapse, trend-momentum, reaction/miss escalation, neuro-focus, and cognitive-overload scenarios to ensure the tuner reacts exactly when the summary indicates. 【F:tests/autoparry/oscillation_spam.spec.lua†L21-L207】【F:tests/autoparry/oscillation_spam.spec.lua†L209-L378】

## Decision Aggressiveness
- AutoParry captures detection moments whenever a threat reacquires the highlight or the system shifts targets, ensuring no state is lost even while holding the parry key. 【F:src/core/autoparry.lua†L4666-L4734】
- As soon as the proximity/inequality thresholds trigger, AutoParry stamps the decision time so commit latency reflects nothing but execution overhead. 【F:src/core/autoparry.lua†L4939-L4976】
- Adaptive tuning continuously nudges reaction bias and slack based on observed deltas, preventing the system from getting “too slow” after a run of easy threats. 【F:src/core/autoparry.lua†L24-L45】【F:src/core/autoparry.lua†L2468-L2495】

## Error Visibility & Diagnostics
- Telemetry counters track every press, latency sample, and adaptive adjustment, with diagnostics summarizing averages and emitting actionable hints (e.g., when activation latency creeps too high). 【F:src/core/autoparry.lua†L884-L1040】【F:tests/autoparry/telemetry.spec.lua†L124-L185】
- When VirtualInput access fails, AutoParry logs Roblox warnings (once per outage) and updates the status label so you know the exact blocker. 【F:src/core/autoparry.lua†L1534-L1579】【F:src/core/autoparry.lua†L3317-L3349】

## Register Pressure Snapshot
- The register scan harness confirms every AutoParry function stays under the 200-local budget, with `Helpers.applySmartTuning` peaking at 44 locals while the module aggregates 1202 locals across 296 functions. 【7ebed2†L4-L118】【7ebed2†L122-L148】
- No other AutoParry routine exceeds 50 locals, keeping comfortable headroom below the enforced cap during runtime tuning and UI updates. 【7ebed2†L4-L118】

## What To Watch
- **Consistently low React/Decide numbers (<100 ms)** mean AutoParry is keeping up; rising values suggest ping spikes or highlight issues. The telemetry feed captures every sample for offline review.
- **Commit spikes** usually mean Roblox refused VirtualInput (focus loss, permissions). The retry window and status text will call this out immediately so you can refocus before the next threat.

Taken together, the timing telemetry, resilience tests, and adaptive tuning ensure AutoParry reacts immediately, keeps firing through transient failures, and gives you the data you need to spot any slowdown before it costs a life.
