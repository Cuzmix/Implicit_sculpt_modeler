---
name: no-github-actions
description: "Bolt 2026-10-29: never start GitHub Actions workflows (Input tests, iPad build) unless asked; test locally"
type: feedback
---
Actions minutes are limited (private repo, macOS runners bill 10x). input-tests.yml is manual-only since PR #300; don't run it or ipad.yml unless Bolt asks.

Test locally instead: `build.bat check`, `build.bat test`, and only the related touch_check.py scenarios.

odin-sculpt has #299:
- Pen roll goes via ui.hover_roll (first 10 deg ROLL_ENGAGE do nothing); never read input.roll / App.pen_roll.
- Palm rejection via pen_holds_hand(app, now).
- Flags: --pen-no-leave, --system-palms.
- Keep diag_* scenarios passing.

Known: Windows spray_replays_from_a_strokes_file crash.

Gotcha: a branch cut before #300 still has the old push/pull_request trigger, so its next push starts Input tests (it happened once on PR #298). Merge odin-sculpt into such a branch before pushing.

2026-10-29 18:42 Bolt: run the quick gate on each PR, then one full gate (scripts/gate.py) at the end of a series.
