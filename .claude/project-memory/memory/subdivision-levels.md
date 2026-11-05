---
name: subdivision-levels
description: Design, bench numbers and gotchas of multires subdivision levels (Loop subdivision, detail per level, sync on level change, undo across levels) in src/sculpt/levels.odin
metadata:
  type: project
  modified: 2026-10-17T18:17:23.458Z
---

Built 2026-10-17 (roadmap item 5, thread "Faking 3D like ZBrush"), commit c31b16d, 4th commit of PR #5 (merged 2026-10-17). Roadmap status: [[sculpt-perf-work]]; architecture: [[sculpt-decisions]].
- Design: each level is a full mesh with its own Sculptor and GPU buffers (Object.gpu[MAX_LEVELS=8]); only the current level is drawn and sculpted, so a stroke costs what a plain mesh of that size costs. Loop subdivision, closed manifold meshes only. Each vertex above the base stores detail = offset in a frame built from the level below. A level change syncs only nodes the edits reached (CSR deps/dependents per level): push down (0.5 own change + 0.5 average of the fine ring), re-encode detail, decode levels above. The current level is never moved by its own sync.
- Undo: app history entries are {object id, level}; undo switches level first, and LIFO order keeps levels consistent. Delete lower/higher clears that object's history. Subdivide is refused past 12 GB.
- Bench (`build/bench --levels --prefault=3000`, 4 threads; 9.84M top, 5 levels, 38k base): build 3.05 s, RSS 1.8 GB, stroke frame 2.06 ms on top vs 0.10 ms on base, step down 34 ms, step up 49 ms sync + 24 ms normals + 34 MB upload.
- Lesson: in this VM first touch of fresh memory dominates; a persistent residual scratch buffer and writing detail during build cut the 10M step down from 77 to 34 ms. Subdivide time is mostly sculptor_init page faults (left as is).
- Gotchas: ImGui `%s` varargs need cstrings (fmt.ctprintf); an Odin string segfaults. Windows batch splits %2.. at '=', so give Bolt `build\sculpt.exe --flag=N` after `build.bat release`, not `build.bat run --flag=N`.
- Not done: Remesh drops levels and detail; open meshes can't subdivide. HD-geometry regions came later: [[hd-detail]].
