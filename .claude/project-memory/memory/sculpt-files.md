---
name: sculpt-files
description: File import/export (OBJ, PLY) and native .sculpt scene save/open in the sculpt app, PR #11 merged 2026-10-24: what is saved, limits, numbers
metadata:
  type: project
  modified: 2026-10-24T16:43:23.736Z
---

Part of the "lets do all of it" brainstorm list (after [[sculpt-brushes]], [[sculpt-remesh]], [[sculpt-dyntopo]]). PR #11 self-merged into odin-sculpt (8f9bee3) 2026-10-24.
- File menu: Open scene Ctrl+O, Save scene Ctrl+S, Save as Ctrl+Shift+S, Import mesh (OBJ/PLY), Export selected (OBJ/PLY); SDL system dialogs; flags `--open --import --export --save`. Every outcome shows as a note in the menu bar (amber = problem) for 15 s.
- .sculpt stores every subdivision level as positions (exact on reopen), the current level's mask, dyntopo, names, placement, camera. NOT stored: HD detail (only HD step count), undo history. Format is versioned (SCENE_VERSION 1); AGENTS.md says bump and keep reading old versions.
- Import welds/cleans, recentres and scales to radius 1 (export puts it back in file coordinates). Open (non-closed) meshes sculpt and work with dyntopo, but subdivision/HD/remesh need closed ones.
- Normal/displacement baking parked: needs UVs, none exist yet. Tell Bolt if asked.
- Bench `build/bench --files` (VM, 4 threads): 10M OBJ write 1.8 s / parse 1.5 s, PLY write 75 ms / parse 150 ms, scene write 0.5 s / read 3.4 s; 10M scene with 5 levels write 0.4 s / read 6.3 s (read = rebuild levels; VM first-touch memory is slow, desktop should be several times faster).
- Windows file dialogs untested (headless VM).
- Mid-PR, another session pushed a skills catch-up (4b0e0f1) to odin-sculpt; merging needed file:line citation remapping in .claude/skills. Expect that again: fetch odin-sculpt before opening a PR.
