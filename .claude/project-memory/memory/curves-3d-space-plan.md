---
name: curves-3d-space-plan
description: 2026-11-05 Bolt asked for standalone curves in 3D space (Blender-like, editable handles); all 9 PRs merged #691-#700, untested on tablet
metadata:
  type: project
---

Bolt 2026-11-05: curves should live in 3D space as their own objects (no mesh needed to draw on), with handles to manipulate, like Blender. Follows [[bezier-curves-plan]] (curve objects already exist; gap: drawing needs a surface for the first point/drag, no Add > Curve, points snap to surface, only smooth/corner, no multi-select/gizmo/extend/numbers).

Plan + working mock: https://claude.ai/artifact/DL4BbVKsirEBDdqmirxww8 (source /mnt/project-files/notes/curves-3d/mock.html). Awaiting Bolt's pick before building.

9 PRs: 1 drawing plane (Surface/View/Floor/Front/Side, grid shown while drawing); 2 Add > Curve (Line, Bezier, Circle, Spiral, Helix at the add point); 3 Draw/Edit tabs (Tab) + point selection (tap, Shift, box, A), handles of selected points only, double-tap = corner; 4 object gizmo on selected points + G/R/S + snap; 5 handle types Auto/Aligned/Free/Vector (Bezier_Point.corner -> Handle_Type, CURV format change); 6 grow nubs at ends, join, split, reverse; 7 profile pad (closed 2D Bezier in place of Tube_Profile enum, presets as starts, Mirror); 8 width along (taper curve multiplying radius, presets Even/Taper/Both ends/Bulge); 9 Point section (X/Y/Z, radius, tilt), README, touch scenarios.
Defaults offered: edit in Curve tool's Edit tab; off-model plane = View; tap selects, double-tap toggles corner.

Bolt 2026-11-05 15:28 said 'looks good' and asked about the profile -> PRs 7-8 added to mock (step 7). Bevel Object (profile from another curve object) deliberately left out.

Bolt said go 2026-11-05 15:37. Building on branch claude/project-thread-vi205c (restart from odin-sculpt after each merge). PR1 #691 merged (Curve_Plane in curve_tool.odin: curve_plane_at/curve_plane_hit/curve_land/curve_first_anchor; View plane normal = camera forward, not eye->point; setting curve_plane, default Surface).
PR2 #692 (Add > Curve, curve_shape_add), PR3 #693 (Edit tab, Bezier_Point.selected never saved, curve_key_taken claims Tab/A/Delete), PR4 #695 (curve_gizmo.odin: Move tool's gizmo on picked points, G/R/S modal, draw_gizmo_shape shared); PR5 #696 (geom.Handle_Type replaces corner, scene v48, curve_changed runs bezier_auto_handles); PR6 #697 (curve_grow.odin: nubs, Draw taps from picked end, Join/Split/Reverse; curve_object_add chain param) merged 2026-11-05. GitHub merge API gave 502/405 once; Bolt merged #693 by hand.
PR7 #698 merged (geom/tube_profile.odin Tube_Outline in Tube_Options.profile, app/curve_profile_pad.odin pad in kit_curve_tube, Flatness gone, scene v49; touch scenario tube_profile_pad_edits_the_outline opens Tool card via UI["inspector"]).
PR8 #699 merged (geom/tube_width.odin Tube_Width in Tube_Options.width, kit_curve_pad over Pad_Target union serves both pads, scene v50; touch scenario tube_width_pad_tapers_it scrolls card with wheel:-12).
PR9 #700 merged (curve_point_values.odin Point section in Edit tab, Scene_Command .Curve_Points shares look_drag; glossary entries). Series done 2026-11-05; awaits Bolt's device run (pads and point drags only tried in desktop simulation).
