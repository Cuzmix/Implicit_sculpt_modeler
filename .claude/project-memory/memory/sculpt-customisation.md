---
name: sculpt-customisation
description: UX roadmap phase 4 (customisation) in thread "Build command registry and touch controls": brush presets #70, then editable dock, bind-where-you-see-it, pies, keys settings, gesture map
metadata:
  type: project
  modified: 2026-10-26T04:11:14.690Z
---

Phase 4 of the UX roadmap (12_Product_Roadmap.md), worked autonomously while Bolt is away (self-merge into odin-sculpt). Follows [[sculpt-discoverability]] (phase 3 done with #69).

- Design + sm-architect review: /mnt/project-files/notes/registry/brush-presets-design.md. Review split it in two PRs.
- PR #70 merged 2026-10-26: brush presets (presets.odin). Brush_Settings.preset (from 1, 0 = plain) + `plain` stash; while on a preset the per-kind slots hold its values, preset_leave restores (called by .Brush, --brush); settings_save writes brush_plain. settings.txt `preset <escaped name> ...` (18 fields) and `brush_preset <name>` resolved after the loop. Preset section first in Brush tab (folded; title "Preset: X · changed##preset"), which moved Brush tab rows down 46 pt (touch_check slider_drag_sideways). Commands Preset_Save_New/Save/Revert/Delete, Brush_Reset in the Tools range.
- PR #71 merged 2026-10-26: editable dock + presets in the browser (dock.odin: Dock_Slot{kind,preset from 1}, Kit_State.dock from DOCK_DEFAULT, long press slot -> k.dock_menu popover; kit_brush_grid shared by browser and slot menu, scroll body sized to room above dock; settings `dock <slot> brush|preset <name>`). ui select lists now scroll when taller than the window; brush tiles cut long names. touch_check spots SLOT_SETTINGS/PINCH/PRESET/RESET, BROWSER_PRESET (layout depends on preset count). Item 1 of phase 4 done.
- PR #72 merged 2026-10-26: bind where you see it. keymap.odin (Key_Override over DEFAULT_BINDINGS; keymap(app) = defaults when no overrides; command_keys/command_chords take app; never read DEFAULT_BINDINGS for display), kit_bind.odin (Ctrl+Alt+click any enabled command control during layout -> Assign key popover via command_run + ui clicked_rect; palette help 'Assign key' button; conflict Use it here/Keep it there; reserved keys). settings `key <Command[:Arg]> <chord|none>` (chord = rest of line). Design: notes/registry/bind-keys-design.md.
- PR #73 merged 2026-10-26: user pies + starred commands (user_pies.odin). Pie.which (0 brush, 1-4 user), Q/Shift+Q; Kit_State.pies/favourites; palette action row Star / Put in a pie / Assign key (touch_check PALETTE_STAR/PIE/ASSIGN at y=319 with "wire"); pie editor popover; settings `pie <0-3> <0-7> <cmd|empty>`, `favourite <cmd>`. kit_begin mutes kit input while a pie is open; Pie.opened_frame guards a same-frame palette click. Design: notes/registry/user-pies-design.md.
- PR #74 merged 2026-10-26: Settings > Keys tab (kit_keys.odin: keys_rows/keys_match search, row tap -> bind_open with Bind_Popover.from_keys re-anchoring) + Nav_Prefs.mouse_scheme ZBrush/Blender/Maya via mouse_button_owner (navigate.odin, the only button mapping). Performance tab renamed System (5 tabs fit); touch_check open_settings x: 1241/1315/1388/1462/1535. --ui-events mdown/mup/rdown/rup; Escape in a side-panel field no longer closes it. Design: notes/registry/keys-settings-design.md.
- PR #75 merged 2026-10-26: gesture map (gesture_map.odin): Nav_Prefs.gestures [Gesture_Slot]Pie_Slot (2/3/4-finger tap+hold, Pen_Button) replaced tap_history/hold_history; settings key `gesture_map` ("gesture" is the Ctrl+Shift tool); notes under the map in warning colour; .Brush_Pie command; --ui-events pright. PHASE 4 COMPLETE (#70-#75).
- Next: Phase 5 (autosave/crash recovery first) of 12_Product_Roadmap.md.

**Why:** roadmap phase 4 "Make it yours"; Nomad/Blender have presets ([[ux-research]]).
**How to apply:** anything that changes app.brush.kind outside .Brush must call preset_leave first.
