---
name: gate-on-bolts-pc
description: Bolt 2026-11-02: threads skip running gate.py; Bolt runs the gate on his own PC
metadata:
  type: feedback
  modified: 2026-11-02T11:07:55.853Z
---

On 2026-11-02, in the detail skin thread, Bolt said: "Skip running the gate I will run it on my pc".

**Why:** a gate run here takes about 25 to 30 minutes per PR and holds up the series.

**How to apply:** don't run `gate.py` (neither full nor `--changed`). Still type-check (`odin check`), run the touched package's tests with `test_only.py`, build, and look at a dump for visual work. Then merge, and say in the PR that the gate was left for Bolt. This replaces [[gate-per-pr]] until Bolt says otherwise.
