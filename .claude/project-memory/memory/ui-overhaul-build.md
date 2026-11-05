---
name: ui-overhaul-build
description: 2026-10-29 Bolt approved building the whole UI overhaul (spaces, chip bar, docks, palette groups, object menu, offers, paint toggle, motion I+II with settings); design note and PR order
metadata:
  type: project
---

Bolt 2026-10-29 10:55 in thread "Plan the app UI overhaul": "Let's do all of it and we can add them as settings too ok I like the plan proceed with all" -> build every item of the round 3 plan (https://claude.ai/artifact/WVaWC8riMYVtzkU1xpqsjq), each animation also a setting (Settings > Interface > Motion: Full/Reduced/Off + one switch per kind).

Design note: /mnt/project-files/notes/overhaul/design.md; screen PNGs to compare dumps against: /mnt/project-files/notes/overhaul/screens/<id>.png (r3sculpt, r3model, r3render, r3menu, r3offer, r3arrange, r3tablet, pgA-pgF, motion*).
PR order (each self-merged into odin-sculpt, full gate): 1 Spaces, 2 Chip bar, 3 Docks I, 4 Palette groups, 5 Object menu, 6 Offers, 7 Paint toggle, 8 One palette type, 9 Motion I, 10 Motion II, 11 Sweep (touch, README, skills). Texture space after, own plan.
2026-10-29 13:06 Bolt approved the History revamp (round 3 tab 12: H1-H6) and five more panels (tab 13: P1 Layers, P2 layer masks, P3 Objects outliner, P4 Materials/matcaps, P5 Export presets+print checks, P6 Help overlay+tour, plus motion rows 14-24) -> queued after the overhaul PRs; dock targets include left/right. Paint Blur/Erase (strokes v14, paint_dial) **#278 merged** 2026-10-29. Classic removal #275 merged; **Spaces PR 1 #284 merged** 2026-10-29 16:20 (settings v5: the brush engine took v4; workspace file stays v1 with a space line). **Chip bar PR 2 #286 merged** 2026-10-29 17:00. Side worktrees (scratchpad wt-*) need a real deps/ dir of per-entry symlinks to the main deps (odin, sdl3, luau...), never a deps symlink; nothing is committed. The brush-engine thread merges often: merge the base, run check/test/smoke plus the touch scenarios near both changes when the merge is sculpt-only and clean.
Per-PR progress and gotchas: [[ui-overhaul-progress]].

**Why:** Bolt approved the screens and wants the overhaul built end to end. **How to apply:** keep the order; follow [[ui-modes-brainstorm]] decisions; update this file as each PR merges.
