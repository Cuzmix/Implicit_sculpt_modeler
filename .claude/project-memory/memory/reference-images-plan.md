---
name: reference-images-plan
description: 2026-11-05 reference images plan (PureRef board + ZBrush Spotlight/planes + Nomad + Blender): plan+mock artifact, 6 PRs R1-R6, awaiting Bolt's 4 picks
metadata:
  type: project
  modified: 2026-11-05T08:25:05.427Z
---

Bolt 2026-11-05 08:18 (thread "Plan reference images like PureRef"): "add reference images... inspiration from nomad and zbrush and most importantly pureref, take the best of all worlds, let's plan". Plan only, no build until picks.

Delivered: plan + live mock https://claude.ai/artifact/LMXDdcQdwqqm63VUEkBZMm (source /mnt/project-files/notes/refs/plan-mock.html).

Design: one image, three places. Board (PureRef canvas inside a new Refs card, not a separate app), On view (screen overlays, opacity, fade under the brush, handles only while the Refs card is open: no Spotlight-style edit mode), In scene (Front/Side/Top planes, not objects, "only in its view" like Blender, Behind/Through). Pick colour -> Colours card; Line up with Proportion guides (guides.odin); Snap view to board; stored as original bytes in a REFS chunk of the .sculpt; History steps hold only placements. Budget: decode on worker, overlays drawn with UI after viewport (0 ms on sculpt passes), GPU copy <=2048 px tablet / 4096 desktop, 256 MB tablet limit.

PRs: R1 store+file+board card, R2 tidy/edit+undo, R3 on view, R4 planes (new shader, design note first), R5 line up + copy board + memory limit, R6 iPad/Android/web drop+paste, README, touch.
Not taken: PureRef always-on-top OS window, URL fetch (network permission), board drawing, Spotlight projection paint (parked for Paint layers), image to mesh.

Picks asked (my recs): 1 board as card (vs own space tab); 2 refs per scene (vs app-wide library); 3 keep originals up to 8192 px; 4 projection paint parked.
Modifiers (Mirror etc.) asked same day went to a separate thread "Plan modifiers like Mirror".

2026-11-05 08:32 Bolt: "OK looks good proceed" = build R1-R6 with my 4 recs (card, per scene, originals <=8192 px, projection paint parked). Bolt also asked to follow the UI upgrade thread ("Plan UI/UX upgrade from T3's approach", [[ui-ux-t3-upgrade]]) so its fixes aren't undone. Rules taken from it: user-facing words are Bar (not dock), Card, Shading (not pass/look), View info (not readout), Clean view; card named "References" in full, "Refs" only where room is short (as Voxel remesh/Voxel); own icon (ui_audit.py refuses shared icons, literal sizes, low contrast); one selected look and theme tokens, ui.MENU_W/POPOVER_W; cards lead with a Common block; no key hints without a keyboard; names on rail on touch; run ui_shots.py and ui_audit.py. Phase 5/6 of that thread touch cards/Tool/Mesh files: keep refs code in its own files to avoid conflicts.

2026-11-05: R1 merged as #651 (references.odin store, kit_references.odin card, REFS chunk after SCEN, SCENE_VERSION 40, History kind References, `reference FILE` verb). Touch expectations for the rail list now include Open_Card:References. Next R2 (Arrange, Same height, crop, flip, grey, rotate, notes, lock, Snap view).
2026-11-05: R2 merged as #653 (Arrange, Same height, notes as image=0 places, Snap view, Flip/Grey/Turn/Crop/Lock non-destructive on Ref, grey = second GPU copy, ui.image_corners, SCENE_VERSION 41).
2026-11-05: R3 merged as #655 (refs_view.odin: overlays drawn before panels, fade under pointer, Show_References command, eyedrop_sample checks overlays, 512px CPU sample, SCENE_VERSION 42).
2026-11-05: R5a #656, R6 #659 merged. R4 design note written, awaiting Bolt's go (new unlit ref_plane shader, axis-only planes, Behind/Through).
2026-11-05: Bolt approved R4 design; merged #666: unlit ref_plane shader, planes through scene middle, Behind = far-plane depth backdrop, Through over model, axis-only 10deg, drag picked plane in view (not gizmo), Scene card References row, SCENE_VERSION 44, verb reference_plane. Next R5b Brow/Chin line-up with Proportion guides. odin-sculpt's ui_audit shared_icons is 29 vs baseline 28 (not from refs).
2026-11-05 13:05: Bolt reported board zoom spill (fixed #683: board drawn inside its clip container). Bolt asked for References card UX mocks (and Live stack mocks, other thread): https://claude.ai/artifact/TgsQkSVdu3MtfoiP2qf1Ps (A board first, recommended; B named rows; C three tabs), decision card posted, awaiting pick. Wait for pick before building.
