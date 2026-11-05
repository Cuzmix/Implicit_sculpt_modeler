---
name: modifiers-live-stack-plan
description: Live stack (modifiers) series, 2026-11-05: Bolt approved all 4 picks; series done: PR1 #662, PR2 #668, PR3 #671, PR4 #675, PR5 #681 merged
metadata:
  type: project
  modified: 2026-11-05T10:05:10.644Z
---

Bolt 2026-11-05: "plan for modifiers like mirror etc". Plan + mock: https://claude.ai/artifact/AsztZy5PHcrx6eSmmeyGNS (source /mnt/project-files/notes/modifiers/plan.html, M1 design m1-design.md beside it).
Bolt replied "Looks good proceed" = all 4 recommended picks: Mirror and weld becomes the Mirror row's Apply (Modify topology button gone); fixed row order, one of each kind; cage deformers later; own Live stack card + rail button.

Built:
- PR1 #662 merged 2026-11-05: Draw_Item.copy (CPU-culled copies of the same GPU mesh), gpu.set_front_face for reflected placings, *_clip.frag shader variants (discard; SV_ClipDistance unusable in slang WGSL/Metal), src/app/stack.odin (Stack/Stack_Mirror, card, History .Stack, stack bytes in scene file v43, `stack` script verb). Brush symmetry locked on across mirror planes while shown.

- PR2 #668 merged 2026-11-05: Stack_Array/Stack_Radial, stack_steps/stack_frames, scene_raycast_framed + Stroke.frame/stroke_frame (press on any copy sculpts through it), Apply the stack (symmetrize then mesh_join copies), Stack_Drag one undo per drag, scene file v45, ui_shots `stack_card`. Gotcha: on this VM's lavapipe, many copies make frames ~1 s and the bench pointer reads as held still -> stroke edit opens mid-stroke (fewer dabs); not a copies bug.
- PR3 #671 merged 2026-11-05: Stack_Along (curve object id, count, axis; object stays put, copies on bezier_frames), scene v47, script verbs `stack along 8 x` and `curve_add x y z ...` (add an open curve; `select 1` back to the sculpt).

- PR4 #675 merged 2026-11-05: cage rows (Smooth/Flat, Mirror, Thickness, Bevel) moved from Model palette to the Live stack card top (kit_cage_live public); cages take Array/Radial/Along as drawn copies, no sculpt Mirror row, Apply to sculpt keeps the stack. Smoke here needs SDL_VIDEODRIVER=offscreen.

- PR5 #681 merged 2026-11-05: stack_bake (geom.mesh_symmetrize out_from gives vertex sources) used by object_export/print/link/boolean marks; Export sheet 'Bake the live stack' (Export_Once.keep_stack); link return Swap takes shown rows out; App.stack_bakes exit stat (app.stats resets on every rebuild, so counters live on App). Blender not installed here (link_check skips).

Open follow-ups: Blender add-on round trip with a baked stack untested (no bpy here); copies on a boolean preview not drawn specially; device runs.

Card redesign 2026-11-05: Bolt asked for UX/UI overhaul mocks (row buttons ran off the card, help truncated). Mocks canvas https://claude.ai/artifact/X3KkAkbRYDhra8YCuT7cqW: A folded rows (recommended; one-line rows w/ eye + menu, one open at a time, Add menu, cage SHAPE/COPIES groups), B pipeline chips, C slim rows + on-view handles (later add-on). Bolt picked 'A now, C's handles later' 2026-11-05: redesign PR1 = A (Stack_Row enum, Stack_Card in Kit_State, ui.thumb_row rows, kit_stack_menus drawn after cards; cage bodies kit_cage_smooth/mirror/thickness/bevel in model.odin; ui_shots stack_card, stack_card_cage, stack_add). PR1 #685 merged 2026-11-05. PR2 #689 merged 2026-11-05: src/app/stack_handles.odin (only the open row's handle; Array tip drag, Radial pivot drag, Mirror chip tap flips kept side, plane stays at origin so no file change); routed like light markers (frame, navigate, column, object_menu); Frame all includes copies; scripts stack open ROW, radial pivot. 33 touch scenarios fail here on base too (view panes, history, adjust remesh): environment, not ours. References panel mocks + ref zoom pop-out bug went to coordinator for routing.

Pre-existing failures on odin-sculpt (not ours) as of 2026-11-05: app tests sections_show_at_most_five_controls, show_every_option_unfolds_the_sections, textured_export_carries_the_maps (paint_pick_id "unpick first").

Related [[keep-symmetry]], [[mirror-weld-quads]], [[poly-modeling-plan]].
