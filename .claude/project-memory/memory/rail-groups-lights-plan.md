---
name: rail-groups-lights-plan
description: 2026-11-01 Bolt's asks (thread "Plan dynamic rail panels and UI fixes"): nav head top right, rail panel groups, Scene+Objects merge, pen no-switch setting, caps, richer lights; findings and state
metadata:
  type: project
  modified: 2026-11-01T18:50:39.606Z
---

Bolt 2026-11-01 18:47 asked to plan: nav head (3D gizmo) back to top right or a setting; rail panels user-addable and drag-one-onto-another makes a panel group (tabs); retire Objects card in favour of Scene; setting so the pen doesn't switch meshes; raise shelf and rail caps; lights: colour, more settings, more types. Also "debate me and push back".

Findings (code at 4cfefa3):
- Nav head lives in the View island (lens_chrome.odin kit_view_chips, off-hand top corner) since #472; kit_nav_head (pen side, left of rail) is only the fallback.
- Rail = Bar_List of commands (VIEW_RAIL_MAX 12, scrolls); any panel CAN be added today via Arrange > + > search, just hidden. Panel stack already has groups-as-tabs (stack_groups.odin, Lens_Stack.joined) — reuse for rail groups.
- Three object lists: Objects card (kit_objects_card.odin: thumbnails + Actions split/merge/boolean/align), Lens Scene card (lens_scene.odin outliner, chips, lights, sets), Scene palette tree (kit_scene.odin).
- Pen switching: stroke_start (sculpt_tool.odin) selects whatever object the stroke starts on. Finger taps already have `tap_switches`.
- Shelf SHELF_MAX 12 = exactly what fits a tablet's palm-safe row (8x64pt at 42pt min); rail scrolls.
- Lights already have colour, kelvin, angle/radius, cone/soft edge, distance, space; hidden behind More in kit_lights.odin. Kinds Sun/Point/Spot, LIGHT_COUNT 8. Missing: area lights, shadows per light, specular/diffuse split, aim at object.

See [[top-bar-three-islands]], [[sculpt-lights-3d]], [[lens-panel-model]].

State 2026-11-01 19:40: PR1 merged #481 from branch claude/project-thread-caq54e (nav_place Corner default / View_Island; stroke_switches on by default; VIEW_RAIL_MAX/SHELF_MAX/BAR_SLOTS_MAX 24; shelf_palm). Plan + mocks https://claude.ai/artifact/6q6XCT1Q3oQ1gu9X8fFpkv (source /mnt/project-files/notes/rail-groups/plan.html). Bolt 19:17 asked groups can also be stacked: plan now says a group shows as Tabs or Stacked (header switch, per group; new groups start as tabs). PR2-7 (lights unfold/presets, area lights, per-light shadows+highlights, Panels picker + Camera card, rail groups, Scene absorbs Objects card) wait for Bolt's go.
Gotcha: touch scenarios nav_head coords now At("navigation head/navigation head", 1186, 86); full_brushes_page(step) gives a 24-tile Brushes page.
- 2026-11-01 19:34-19:53 Bolt agreed: rail = the stack folded to icons (Photoshop dock model): one list of groups; tap pops beside rail, pin docks it into the column (stack Left/Right/Float kept, stack's own order, Panels button and "beside" column retire; old stack lines migrate to pinned rail groups once). Plus: hold a tab or right-click a group button opens group settings popover (name, colour, Tabs/Stacked, pin open, ungroup). Took "sounds good" as go to build PR2-7.
- 2026-11-01 20:50: #482 lights card merged, #483 Panels picker merged (rail + opens picker of every card/section, Show_Panel command, SECTION_ICONS, Brush_Preset searched under Brushes, which fixed 4 palette_* scenarios broken since #480). Order changed: UI PRs (6 rail groups, 7 Scene absorbs Objects) before render PRs 3+4. PR6 design /mnt/project-files/notes/rail-groups/design.md: groups additive first; retiring the stack's own order/Panels button/beside columns is a separate PR6b (pushback).
- Gotcha: offscreen dumps crop to 1280x720 so the rail's popovers fall outside; add `--script=set left_handed 1` to see them.
- 2026-11-01 22:10: #485 rail groups merged (Rail_Group slots, rail_groups.odin, rail_group lines in settings/layouts), #486 Scene absorbs Objects card merged (scene_pictures setting, Objects_Card command removed and mapped to Show_Panel:Scene, touch scenarios use scene_pictures() workspace). Area lights design /mnt/project-files/notes/rail-groups/area-lights-design.md (Lights 560->816 B, representative point, no LTC) put to Bolt for a go. Left: PR3+4 render, PR6b retire stack's own order/Panels button/beside columns, full gate.
- 22:15: pushed back on PR6b: the stack's Icons strip is what split-view panes use (lens_panes.odin), so retiring it breaks panes; recommended keeping strip + beside columns. Two decision cards open (area lights approach; PR6b keep/retire). Waiting; full gate still owed at the series end.
- 2026-11-02 07:33: Bolt chose keep the stack strip + side columns (PR6b dropped) and area lights 'cheap first, measure'. Building PR3+4.
- 2026-11-02 09:00: PR3+4 area lights built on branch (commit 3e0c278): Light_Kind.Area (width/height/disc), per-light shine (-1..1, Highlight 0-200%) and no_shadows; render.Lights 816 B (axis, extra), Material_Uniforms 1152. Perf lesson: area code inside mesh_shading's loops, even never taken, cost ~35% fragment time on SwiftShader, so it lives in mesh_area/textured_area.frag variants (AREA_LIGHTS) with pipelines made lazily (Mesh_Pipelines.area, lights_have_area). SwiftShader 100k sphere: old 575 ms, new base ~605, 4 point ~600, 4 area ~1000. Scene file: area written as Spot in lights_put + lights_more_put at SCEN chunk end. Blender-side area watts unverified (no Blender here).
