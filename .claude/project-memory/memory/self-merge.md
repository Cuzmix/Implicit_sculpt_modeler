---
name: self-merge
description: "Bolt 2026-11-06: agents self-merge their PRs into odin-sculpt (never master); replaces the 2026-11-05 don't-merge instruction to the UV and Pelz threads"
metadata:
  type: feedback
  modified: 2026-11-06T15:00:00.000Z
---

Agents self-merge their own PRs into `odin-sculpt`, never `master`, once the PR's checks are green ([[gate-on-bolts-pc]], [[gate-per-pr]]). The policy wavered by thread: self-merge from 2026-10-18; on 2026-11-04 the GPU thread was told to push to a branch for Bolt to test first; on 2026-11-05 evening the UV and Pelz threads were told "dont merge to the main branch for now keep everything in your own branch", then the UV thread "now you merge as you go along". On 2026-11-06 Bolt settled it: "self merge is allowed".

**Why:** Bolt wants autonomous progress and tests merged work on his devices afterwards.

**How to apply:** merge your own PR after the gate; say in the PR what was verified and what was not (device runs are Bolt's). Branch-only work from before (Pelz B1 on claude/project-thread-072t81) is not merged retroactively without asking: its plan is on hold. When Bolt says "wait" or "don't merge" in a thread, that holds for that thread until he lifts it.
