---
name: gate-on-bolts-pc
description: "Bolt 2026-11-06: agents run gate.py themselves on his Linux laptop; the 2026-11-02 rule that only Bolt runs it is retired"
metadata:
  type: feedback
  modified: 2026-11-06T15:00:00.000Z
---

On 2026-11-02, in the detail skin thread, Bolt said "Skip running the gate I will run it on my pc", because a gate run in the cloud container took 25 to 30 minutes per PR and held up the series.

On 2026-11-06 Bolt said "you can run the gate since we are working this pc": agents now work on his Linux laptop (real GPU, 24 threads; [[local-machine-real-gpu]]), where `gate.py --changed` takes minutes and the touch suite about 2 minutes offscreen.

**Why:** the reason for skipping the gate (slow cloud runs) no longer holds on the local machine.

**How to apply:** run `python3 scripts/gate.py --changed` on each PR of a series and the full `gate.py` on the last one ([[gate-per-pr]]), then self-merge ([[self-merge]]). A failure that is already on odin-sculpt is listed separately in the PR, not fixed in passing. Cloud threads, if any still run, keep the old practice: check, touched tests, build and a look, with the gate left for this machine.
