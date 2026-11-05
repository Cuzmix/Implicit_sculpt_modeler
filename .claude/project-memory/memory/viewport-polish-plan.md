---
name: viewport-polish-plan
description: 2026-10-30 thread "Polish viewport, shading, UI and import": audit root causes, plan doc, 17-PR order, defaults chosen, build progress
metadata:
  type: project
  modified: 2026-10-31T01:25:00.000Z
---

Bolt 2026-10-30 18:43 big ask (dense mesh, Blender shading modes, per-view shading, split views, Search icon, popup hover,
brush sheet collision, rail drag-and-drop, chip twist, EXR + env controls, imports). Test asset: /mnt/project-files/gilmon 2.zip
(Nomad OBJ, 3.5M verts, all quads, 426k UVs, #MRGB, 11 objects). Plan doc: https://claude.ai/artifact/57vJ1sQnK7fAWqefo4NKeJ

Root causes confirmed (f878605):
- Import keeps only triangles: polygons and UVs dropped -> texture views/UV checker/Load map do nothing on imports, wireframe shows diagonals.
- MatCap is an object material; wireframe/flat/env/render global; only Second_View.pass per pane -> shading bleeds across panes.
- Work in any pane lends app.camera + grid.main to the pane; kit_view_chips places at grid.main -> main chips drawn over the pane's head (repro: view_grid three_across + right-drag at 640,400).
- Panes ground on theme pane colour, not the scene background.
- Quad Remesh + Subdivide keeps quads on current build (poly_edges 444/1776/7104); triangles show only when not selected, HD, dyntopo, imports.
- Remesh default triangles (remesh_quads off).
- value_item (Chip/Icon looks) never calls ui.hover_roll.
- Brush sheet head overflows below ~830 pt (Import over Model tab).
- Tablets: render mode RENDER_SCENE_MAX 256 MB; gilmon needs 280 MB.

Defaults chosen: Remesh quads default; Solid = classic studio path; Wireframe hidden-line; panes redraw at rest; Four preset keeps axis views, splits copy source; own EXR reader; env turn = Shift+right drag; animation reported not kept.

Progress: 1a #397, 1b #398 (OBJ vt -> Uv_Layout; gilmon Body has no vt), 1c #401 (import long job + render cap RAM/8), Bolt extra #402 brush ring size preview (draw_size_preview), 2 #403 wireframe on every object + remesh_quads default on (settings v9 migration) merged; Bolt bug fixes #405 remesh keeps symmetry (Remesh_Mirror lattice + mirror_settle), #406 shelf tiles narrow to fit (shelf_layout, Shelf.fits refuses adds out of sight), #408 shelf pages: rename any page + up to 6 added pages per space (Shelf_Page.Extra_1..6, settings shelf_extra/shelf_page_name, page-name long press menu); #410 3a Blender shading modes (shading.odin: Shading_Mode/Solid_Lighting/Solid_Color in Passes.shading, layout line `shading`, View_Pass Wire+Unlit, looks removed, chip renamed Shading; palette labels 'Shading: X'), #411 3b shading per view (Second_View.shading, SECOND_SHOWS list, picture_frame takes froms, pane line adds shading words, settings second_shading/lighting/color/matcap), #412 4a+4b (pictures on scene background+floor via thumbnail_view_draw scene=true; preset panes take main shading; grid.home keeps main chips+shelf on main pane while a pane is worked; stat view_chips_at); #413 5a+5c layout checks (ui layout_fault counts overlaps/spills on main axis; exit stats layout_overlaps/layout_overlap_at; scenario layout_fits_at_every_size; brush sheet head Import->icon then tabs wrap under SHEET_FIELD_MIN 140); #414 5b Search icon only (top_search_field/TOP_SEARCH_W gone; arrange pill shifted: touch_check coords updated), palette rows picked by moving pointer/press, long press keeps (no run), footer Show where it lives, stat palette_pick; #415 6 pen twist on value chips/icons (value_roll in brush_values.odin); #416 7 drag and drop on bars (bar_drag.odin, ui.lift/held_still, 8 bar_* scenarios); #417 8a own OpenEXR reader (exr.odin, fixtures src/app/testdata/exr made by pip OpenEXR); #418 8b env controls (own Turn/Tilt, Plain/Shown/Blurred backdrop, RECENT list, Shift+right turns env only while an image env shows in Material Preview/Rendered; Alt+right keeps panning); #419 9 import audit (Mesh_Part.folder -> folders follow file hierarchy, FBX keeps polygons via shim, Rig_Found skins/animations/shapes in note, clearer errors, build.sh/bat rerun build_ufbx.py when shim changes). All 17 plan steps merged 2026-10-31; full gate green (755/755 scenarios, 1219 tests); final report + try-it checklist https://claude.ai/artifact/WtzYDHTFw1ZkiYHh8gDUDA. Thread done; awaits Bolt's Windows/iPad try.

2026-10-31 08:41 Bolt asked for the 'left for later' items: nested folders, lossy+tiled EXR, STL/glTF quads. #420 merged: EXR tiled (level 0), multi-part (first RGB part), PXR24, B44/B44A, DWAA/DWAB (DWA follows reference scalar C IDCT = ARM; x86 lib uses AVX so ~0.02% values differ by a half step; *_expect.exr fixtures bound it). Reference source: pip download OpenEXR --no-binary (sdist has src/lib/OpenEXRCore). #423 merged: STL/glTF quads found again (geom.mesh_join_quads: file-order DP pass + mutual-best rounds, kept iff 90% paired and corner mean <18 deg; 99.6-99.8% on real heads, spheres stay tris; stat import_quads_joined). #427 merged: nested folders (Folder.parent, FOLDER_DEPTH_MAX 16, scene v35, shared tree_lines walk for Scene palette/Objects card/Lens outliner, tree_drop reads indent, imports nest the file hierarchy under one file folder via Mesh_Part.folders; FBX shim gained part_folders/part_folder; stat folder_parents=). Full gate green 2026-10-31 (10 steps, 1228 tests, 758/758 scenarios); final report gained a 'Follow-ups (31 Oct)' section. Series done; awaits Bolt's Windows/iPad try.

Gotcha: touch_check.py runs many patterns in one call fine here (79 scenarios ~12 min; background it past 10 min). --dump-screen PNGs are cropped to 1280x720 even at 1600x900; rows below 720 must be computed (44 pt per menu row).

Container: setup_deps needs apt X11/wayland dev libs; headless runs via SDL_VIDEO_DRIVER=offscreen + xvfb-run + SwiftShader ICD (scratchpad run.sh). Branch claude/project-thread-ioduzh, reused per PR.

Related: [[remesh-quad-build]], [[sculpt-import-formats]], [[touch-check-offscreen]], [[gate-per-pr]].
