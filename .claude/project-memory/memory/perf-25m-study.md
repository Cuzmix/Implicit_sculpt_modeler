---
name: perf-25m-study
description: 2026-10-31 analysis of sculpting at 25M polygons and the nine-step plan Bolt approved and that was built (#442-#450), with measured outcomes
metadata:
  type: project
  modified: 2026-10-31T18:40:28.718Z
---

Thread "Speed up sculpting at 25M polygons" (2026-10-31). Report https://claude.ai/artifact/AvDakDd6t9znNrUjjrARvT; notes in /mnt/project-files/notes/perf-25m/. Bolt picked "All nine, in the report's order"; all built or measured the same day.

- "25M polygons when remeshed": Remesh's Quads is on by default, so 25M quads = ~25M vertices = 50M triangles.
- Outcomes (VM, 4 threads, `bench --profile`):
  1. `bench --profile` harness #442.
  2. simplified copies built in the frame's spare time after submit #443 (idle cpu_ms 6.4 -> 1.25 at 12.5M).
  3. normals by scatter: slower, dropped.
  4. Smooth per-triangle corner sums #445: ~15% (report said 2x: wrong).
  5. barriers turned out cheap; real serial cost was undo copies on the frame thread, RECORD_PARALLEL_VERTS 64k->4k #448 (~10% of a large Draw dab).
  6. GPU cull offered on tile GPUs (Mali) but off by default, `--gpu-cull` #450; Metal kernels not built (no Mac to verify), simplified pass not GPU-culled.
  7. undo/redo defer cones + parallel swap #446: 28 -> 19 ms at 25M.
  8. BVH identity tri_order freed after renumber #448: -190 MB at 25M. Packing CPU normals skipped (170 uses, 46 files).
  9. huge pages (glibc.malloc.hugetlb=1) made Remesh 40% slower on the VM; nothing shipped. Ready-to-sculpt already runs on the long job's thread.
- Close-view "bug" in the report was harmless (<=0.24M triangles).
- Profiling tips: perf at /usr/lib/linux-tools/6.8.0-1003-gke/perf, `-e cpu-clock`; `perf report -s tid` segfaults, use `perf script -F tid,ip,sym` and aggregate. VM timing noise is ~15%: alternate A/B runs, never measure while a gate runs.

- Bolt's PC gpubench at 25M after the series (2026-10-31, 3060 Ti, 12 threads, 75 Hz): ready 1.39 s, upload 0.27 s; orbit GPU 2.18/4.38 ms (no simplify 5.71); stroke GPU 1.24, CPU 3.47 ms (brush 0.89, normals 0.55, ui 0.68), latency 4.05 ms, 2.2 MB upload/frame.
- Orbit lag after Remesh on Bolt's PC (2026-10-31): cause was Low latency "During strokes" treating any left-button drag (orbit too) as work -> 1 frame in flight + present wait, 55 ms CPU frames; Bolt found it by turning Low latency Off. Fixed to count only strokes and Tool/Shape drags (#465), and During strokes now steps back to two frames for 20 s when 5 of 8 working frames exceed 1.5 refreshes; panel/README tell users to try Off if it lags. Also #454 builds simplified copies in the long job, and big Remesh targets now go async. Lesson: ask for a Stats screenshot early; gpubench (mailbox, Unlimited) hides vsync/present-wait pacing issues.

**Why:** Bolt asked how much faster 25M sculpting can get and what CPU work could go to the GPU.
**How to apply:** open follow-ups needing Bolt or devices: Mali GPU-cull numbers on the OnePlus Pad, Metal cull kernels, packed normals. Related: [[sculpt-big-meshes]], [[sculpt-perf-work]], [[native-gpu-plan]].
