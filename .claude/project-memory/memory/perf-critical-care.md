---
name: perf-critical-care
description: Bolt 2026-10-31: be very careful with changes to frame pacing, frames in flight, present modes and similar performance-critical defaults
metadata:
  type: feedback
  modified: 2026-10-31T23:10:34.299Z
---

After Low latency "During strokes" (then the default) made orbiting a 21M mesh lag on Bolt's PC (55 ms frames), Bolt said "we need to be very careful with these kind of change as they could be performance critical". Low latency is now Off by default (#467), with LOW_LATENCY_DEFAULT in src/app/frame_rate.odin.

**Why:** a pacing default that trades throughput for latency hurts every heavy scene, and gpubench (mailbox, Unlimited) hides vsync and present-wait problems, so it shipped unnoticed.

**How to apply:** before changing frame pacing, frames in flight, present modes, vsync or similar defaults, measure a heavy scene (10M+) under Match display with the Stats panel, not only gpubench. Prefer the throughput-safe default, and make latency-for-throughput trades opt-in. Run at least the quick gate even when asked to hurry. Related: [[perf-25m-study]], [[gate-per-pr]].

2026-11-03: Bolt on a stroke-start pause (a whole-mesh area pass at every press in skin_auto_add, 130 ms at 25M, fixed #588): "we cant afford to have hicupps like this as its performance critical". Nothing may run whole-mesh work at a press or in a stroke's first frame; anything that can build big data at a press (auto Detail skin) is suspect. Bolt chose: keep Detail skin, Add a skin by itself off by default (#591).
2026-11-03 19:25 Bolt again: "we have to be very careful of what we add etc sculpting performance cannot degrade". Any new feature touching the stroke path needs before/after stroke-frame timings at 10M-25M (press frame, stroke frames, release, undo) in its report.
