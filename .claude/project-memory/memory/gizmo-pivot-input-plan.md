---
name: gizmo-pivot-input-plan
description: 2026-11-05 thread "Plan gizmo, pivot and input fixes": Ctrl masks, per-axis gizmo scale, iPad delete key, pivot icon row, gizmo orientation, Add at cursor (6 PRs)
metadata:
  type: project
  modified: 2026-11-05T08:50:18.575Z
---

Bolt 2026-11-05 asked: Ctrl = mask by default, gizmo scale "only X", finger tap no keyboard + Pencil bar delete broken, Nomad-but-better pivot with ZBrush-like icons above the gizmo, add mesh at the cursor from the object menu.
Plan doc: https://claude.ai/artifact/SbcPS7g7B6ymSZgqvVsctN

- PR1 Ctrl masks: DROPPED 2026-11-05 (Bolt: "ctrl key was already used"; Ctrl from empty space already masks); built patch kept at /mnt/project-files/notes/gizmo-pivot/pr1-ctrl-masks.patch. Was: Settings > Keys "Ctrl while sculpting" Mask|Invert (`ctrl_key`, Mask default, Nav_Prefs.ctrl_key); Mask = ZBrush: Ctrl paints mask, Ctrl+Alt erases, Alt on model inverts (not Maya scheme), Alt on empty still orbits. Only with app.tool == .Brush (Model tool keeps Ctrl = variant).
- PR2 per-axis scale: gizmo was always uniform (Transform.scale is one f32; Draw_Item.model must be a similarity). Plan: stretch the mesh (ZBrush way) through the pose path (new sculpt Pose kind), coloured axis knobs, white knob uniform.
- iPad keyboard: finger tap with a hardware keyboard shows no keyboard = iPadOS intended. Pencil bar delete broken = SDL 3.4.18 SDL_uikitviewcontroller.m textFieldTextDidChange sends Backspace only when !SDL_HasKeyboard(); fix in ios/sculpt_ios.m (untestable here).
- PR4 pivot icon row (Edit pivot, To centre, To unmasked centre, On surface, Reset; pivot saved per object), PR5 gizmo orientation (World/Object/Surface/View), PR6 Add at cursor (scene menu at view-target depth, object menu "Add object here" on the surface point).
Progress: PR2 #654 merged (Handle.Scale_X..Z, Pose .Scale with axis = stretch, white knob Screen.uniform on view ring); PR3 #657 merged (ios/sculpt_ios.m deletes_watch, ObjC never compiled here, needs Mac build + iPad try); PR6 #658 merged (Kit_State.menu_point, Scene_Command.placed, object menu Add object here). PR4 #663 merged (pivot_row.odin: Edit pivot/To middle/To unmasked middle/Set/Reset/Snap over gizmo, Move tab switch gizmo_pivot_row_off). PR4b #669 merged (Object.pivot {set,at,normal}, scene v46). PR5 #672 merged (Gizmo_Orient World/Object/Surface/View, gizmo.screen axes param, gizmo_axes, pivot row last icon cycles). ALL PRs DONE 2026-11-05; then mask keys #677 (Ctrl+Alt+drag = mask paint for brush, empty space still unmask shape; M = Mask_Key hold/tap-latch via Modifier_Rail.key, mask_key_event in frame.odin); open: iPad try of #657, tablet feel of row/orientation. touch pen_side_button_over_empty_space_runs_its_own fails on base (pre-existing).
Related: [[gizmo-all-mode]], [[sculpt-touch-camera]].
