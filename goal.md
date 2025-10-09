# AutoParry Goals

## Performance Targets
- Ultra-tight P99 commit: ≤ 10 ms on high-end rigs.
- Prediction horizon: stable lookahead ≥ 0.9 s without degrading TTI error targets.
- Autotuner learning rate: converges in ≤ 3 presses after abrupt physics changes.

## Quick Checks
- Smoke test: run 5k synthetic threats at mixed speeds/angles; expect ≥ 99.9% on-time.
- Hitch gauntlet: inject 5× 180 ms hitches mid-approach; expect 0 misses, realized lead deviation ≤ 20 ms each time.
- Flicker storm: toggle highlight at 15–25 Hz for 300 ms windows; expect 0 gated-out presses within grace.
