---
name: hd-detail
description: Design, bench numbers and gotchas of HD detail (ZBrush-style HD geometry: up to 3 Loop steps above the top level, sculpted one window at a time) in src/sculpt/hd.odin
metadata:
  type: project
  modified: 2026-10-19T00:33:02.428Z
---

Built 2026-10-18/19 (thread "Faking 3D like ZBrush", Bolt away), PR #7, self-merged into odin-sculpt as d75845d. Roadmap: [[sculpt-perf-work]]; levels: [[subdivision-levels]]; LOD: [[simplified-drawing]].
- Design: Levels.hd {steps 1-3, detail per top-level node ([][]Vec3, nil if never sculpted), window ^Level}. A window = whole top-level nodes nearest the point (box distance) up to a vertex budget (4M default, UI slider 1-16M), patch = region + k rings sorted by top triangle id, k-1 full Loop steps, last step topology only, cropped. Canonical order makes frames bit-identical across windows. Detail per node in grid order (hd_grid_index), deduped. Leaving re-encodes only moved vertices of edited nodes; encode/decode round trip is ~1e-7, not bitwise, so tests compare a reopened window within 1e-6 and shifted windows bitwise.
- Border: vertices shared with non-region descendants never move (Sculptor.fade == 0) and sit linearly on the top triangles (corners exactly). Brushes scale by Sculptor.fade (u8), a smoothstep over 8 top-level edges (capped at a quarter of the window radius). Distance = nearest border vertex passed along by BFS, then 4<<k Jacobi passes on compact band arrays. A ring-count fade gave stripes and unsmoothed distance gave ripples (zig-zag border). Seal fans (both windings) along border edges stop T-junction pinholes; a test checks every directed edge of window + outside top triangles has a reverse.
- App: A toggles (opens at the pointer); Scene panel has Divide HD / Delete HD / Sculpt HD and the window slider; one window at a time; Subdivide refused while HD steps > 0; history entries use level HD_LEVEL (-1), dropped on leave; an older undo leaves HD first. Top level is drawn with hidden chunks/groups (Draw_Item.hidden).
- Bench (`build/bench --hd`, 4 threads): 10M with 2 steps (160M HD vertices) opens a 4M window in 1.26 s (about half is sculptor_init), stroke frame 2.46 ms, leave 56 ms, window 530 MB, 11.2 MB stored vs ~25.7 GB for real levels. 1M with 2 steps opens in 1.05 s vs 5.6 s / 1.9 GB to build the levels. Fade costs 36-71 ms of an open.
- Gotcha: in this VM a fresh page costs ~10-15 us, so fresh temp arrays dominate small passes: reuse already-touched scratch (the fade reuses window_parents). Temp-arena make() does not touch pages; slice.fill does.
- Not done: no push of HD detail down to lower levels (ZBrush doesn't either); no Windows try yet.
