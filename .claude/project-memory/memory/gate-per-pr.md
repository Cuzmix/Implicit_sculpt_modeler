---
name: gate-per-pr
description: Bolt 2026-10-29: run only the quick gate (and the touched tests/scenarios) on each PR, and one full gate at the end of a PR series
metadata:
  type: feedback
  modified: 2026-10-29T18:44:25.096Z
---

On each PR of a series, run the quick gate (`python3 scripts/gate.py --fast`, i.e. check + test, plus the touch_check scenarios and tests for what the change touched), then merge. Run the full `gate.py` (touch suite ~25 min here) once at the end of the series, not before every merge.

**Why:** Bolt said so on 2026-10-29 ("just run the quick gate on each pr then a final one at the end", "just run what you touched only") after threads spent ~30 min of full gate per PR while odin-sculpt kept moving under them.

**How to apply:** for a stack of PRs, quick gate + touched scenarios per PR; full gate on the last one. A merge of odin-sculpt into the branch that only conflicts on `.agents/skills/.manifest.json` needs `agents_sync.py` and the quick gate, not a full rerun. Related: [[no-github-actions]], [[brush-engine-build]].
