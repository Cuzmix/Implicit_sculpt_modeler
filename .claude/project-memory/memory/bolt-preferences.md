---
name: bolt-preferences
description: How Bolt wants Claude to work on the sculpt project (goal, autonomy, testing)
metadata:
  type: feedback
---

- Main goal is ZBrush-level performance; measure at 500k, 1M, 5M, 7M, 10M vertices (`build/bench` in src/bench). **Why:** Bolt said performance is the main goal (2026-10-15). **How to apply:** every perf change gets a before/after bench table.
- Bolt often steps away and wants Claude to keep working autonomously toward the goal and report results when they return; don't park on questions, pick defaults.
- Bolt tests Windows on their own machine; don't set up Windows CI.
- 2026-10-25: Bolt said no live collaborative/LAN sculpting ("Don't do 6" on the wow-features list); don't propose it again.
- 2026-10-27: Bolt asked "why did you jump straight to Lua" after a plugin-language card offered only Lua / grow our own / skip. **Why:** a tech choice card that anchors on one option hides real alternatives (Bolt raised Wasmtime themselves). **How to apply:** for any language, runtime or library choice, compare the credible candidates side by side (e.g. Lua, WebAssembly via Wasmtime/WAMR, QuickJS) with costs before recommending one.
- 2026-10-27: Bolt: "take best of all worlds ... don't limit it to lights, I mean everything". **Why:** the app should not be a clone of one tool (ZBrush iPad was the layout model, Nomad earlier). **How to apply:** every feature design compares ZBrush, Nomad, Blender, 3DCoat, Marmoset (and others) and picks the best idea from each, saying which came from where. Also: the scene is real 3D, so lights and similar features can live in 3D space (positions, gizmo-moved markers), not only camera-fixed.
