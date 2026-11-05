---
name: ui-zbrush-build
description: Building the ZBrush-for-iPad-style layout in 7 phases; PR status and the layout helpers it added
metadata:
  type: project
  modified: 2026-10-26T20:55:00.311Z
---

Bolt approved the final mock (https://claude.ai/artifact/7rueE5Y2oigRxaENscCHXE) and plan doc (https://claude.ai/artifact/JMYFsps6688BZQfKDZQJW6) on 2026-10-26 and asked to implement it. Thread "Design feature hierarchy from ZBrush iPad". See [[feature-hierarchy]].

- PRs #107, #110, #112, #114, #116 (2026-10-26) built the final mock in 7 phases: Studio look, top bar, left brush bar, right view bar, bottom toolbar dock (3 pages), modifier wheel, palette tray (kit_tray.odin, Show where), navigation head (render/nav_head.odin). autosave_crash_then_recover is timing-flaky under full-suite load.
- Layout helpers in src/app/kit_bars.odin: kit_top(), kit_left(app), kit_right(app), kit_card_place, side_panel_below; TOP_BAR_H 52. scripts/touch_check.py has a UI dict of bar positions; inspector x moved -54.

**Why:** Bolt wants a 1:1 ZBrush-for-iPad feel; our own icons kept, no brand names in the app.
**How to apply:** new panels/cards place themselves with those helpers; new touch scenarios use the UI dict; coordinate with [[sculpt-registry]] thread when moving controls.

## Gap list (2026-10-27)
The 15-PR ZBrush-iPad gap list build and each PR's status: [[ui-zbrush-gaplist]].
