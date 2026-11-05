---
name: sculpt-never-lose-work
description: UX roadmap Phase 5 ("Never lose work, try freely") progress: autosave #76, save/versions #77-#79, and the remaining items
metadata:
  type: project
  modified: 2026-10-26T06:57:48.634Z
---

Phase 5 of /mnt/project-files/notes/ux-research/12_Product_Roadmap.md, worked autonomously in thread "Build command registry and touch controls" while Bolt is away (after Phase 4, [[sculpt-customisation]]).

- Item 1, PR #76 merged into odin-sculpt on 2026-10-26: autosave runs on a low-priority thread after a 1.5 s rest (every minute by default; Settings > System lets Bolt pick Off/1/2/5/10). Each session keeps 3 rotating slots in the app's pref folder `autosave/`. A crash-recovery card offers Recover, Not now and Discard; Menu > Open the last autosave opens the newest copy. Design: /mnt/project-files/notes/phase5/autosave-design.md (reviewed by sm-architect).
  - Real SIGKILL tests recover cleanly.
  - At 10M (VM): brush time is unchanged while a copy writes; a stroke stops a copy within 0.7–8 ms; a copy takes about 5 s to read and 2.6 s to write.
  - Not yet tried on Windows or a tablet.
  - Still open (UNVERIFIED): the iPad needs iCloud backup excluded and background time handled (noted in sm-store).
- touch_check gotchas: a scenario defined after `main()` never registers; a menu row added to FILE shifts `UI["menu_settings"]` and the `new_*` coordinates by 44 px.
- Item 2 done 2026-10-26 in three merged PRs: #77 (fsync + durable rename before "Saved"; "Saving..." toast for saves >32 MB), #78 (Save a copy; earlier saves hard-linked into "<stem> versions/", Settings > System keeps 3/5/10, default 5), #79 (Menu > Earlier saves list, menu scrolls on short windows). Design + architect review: /mnt/project-files/notes/phase5/save-versions-design.md.
- touch_check menu coordinates now come from MENU_FILE_ROWS; add new File rows there.
- Item 3 done 2026-10-26, PR #80 merged: Adjust last operation (action bar "<op> / Adjust..." after remesh, decimate, mirror, retopo, extract, smooth all; re-run = history_undo + run again, one History entry; a no-change re-run is redone). State App.adjustable in src/app/adjust_last.odin (adjust.odin is the unrelated S/U brush adjust). Design + review: /mnt/project-files/notes/phase5/adjust-last-design.md.
- Item 4 done 2026-10-26, PR #81 merged: camera history (Alt+Left/Alt+Right, View menu, palette, gesture-map choices; views count after 0.4 s rest, 32 kept, cleared on scene replace). src/app/camera_history.odin.
- Item 5 done 2026-10-26, PR #82 merged: two-phase shapes (finger/pen mask, hide, clip and slice shapes wait with handles + Apply/Flip/Cancel bar; mouse applies at once; Enter/Escape; Settings > Touch > Shapes and --shape-apply=auto|now|confirm). src/app/shape_pending.odin. touch_check: SDL "x11 not available" is a one-off flake, so re-run that scenario alone.
- Item 6 done 2026-10-26, PR #83 merged: Object > Shape > Rebuild (Even/Fewer/Quads + Density; Retopologize moved there, Build section now "UVs and baking") with a checkerboard of the remesh's own lattice while Density is held (geom.remesh_lattice + mesh_area_bounds are the one lattice definition; measuring spread over frames, 1 ms budget). Design+review: /mnt/project-files/notes/phase5/rebuild-panel-design.md. Phase 5 complete; Phase 6 (gizmo, scene tree, selection, posing, stroke engine, history brush, layers anywhere) next.
- touch_check: `--screen-run=N` screenshots run N (no temp script copies); runs whose SDL_Init fails are retried.
- Known touch_check flake (seen twice 2026-10-26 under the full parallel gate): autosave_stops_for_a_stroke failed with autosave_aborts=0 when the thread finished reading 500k before the next frame's press. Fixed in the 8a deformers PR by running it at 2M vertices; if it recurs, re-run alone and consider a deterministic hook.
