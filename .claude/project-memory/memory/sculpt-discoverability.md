---
name: sculpt-discoverability
description: UX roadmap phase 3 (discoverability) in thread "Build command registry and touch controls": palette #62, hints #63, Help #64, Object pages #65, action bar #66, Basic/More #67, first-run tips #68, starter scenes #69 (complete)
metadata:
  type: project
---

Phase 3 of the UX roadmap (12_Product_Roadmap.md), worked autonomously while Bolt is away (self-merge into odin-sculpt).

- PR #62 merged 2026-10-26: command palette. Ctrl+K, `/` or the Search button (top right) opens it; ranks every registry command (one row per arg) and Settings tabs: exact > prefix > word prefix > SEARCH_WORDS synonyms > fuzzy (3+ letters); recents (8, saved by name like `Brush:Clay` in settings.txt `palette_recent`) then enabled first. Kit gained text_field(hold, hint) and menu_item(highlight); `typing(app)` is true while the palette is open; a system-hidden keyboard closes it; --ui-events `text:` + touch_check `type()`. Design and review: /mnt/project-files/notes/registry/command-palette-design.md.
- PR #63 merged 2026-10-26: shortcut + gesture hints. command_gesture (follows Nav_Prefs and the tool), command_hint/hint_join, command_button and kit_command_pair (every panel button that runs a command); kit button/switch_row/tabs `keys`, menu_item `hint`; source-scan test controls_that_run_commands_show_their_hints; stat long_tip_keys; touch_check decodes stats as UTF-8.
- PR #64 merged 2026-10-26: Help window (Menu > Help, F1, palette "Help: Keys/Gestures/Glossary"; `.Help` takes a Help_Tab arg, no new palette kind). Keys from DEFAULT_BINDINGS by command_group (complete enum-range switch); Gestures from command_gesture + TOUCH_HELP (Help_Line with show proc; a test fails any gesture missing there); Glossary rows name commands the palette must find. Help and Settings share the inspector's place (side_panel_open/close). kit_scroll_begin/end is the shared scrolling body. Mask-tap gestures need the modifier buttons on. Design: /mnt/project-files/notes/registry/help-cheat-sheet-design.md.
- PR #65 merged 2026-10-26: Object tab pages Shape/Select/Surface/Build (Object_Page, OBJECT_SECTIONS table in kit_object.odin, test each section on one page, <=6 per page); Polypaint and Polygroups now separate sections (Kit_Section.Groups).
- PR #66 merged 2026-10-26: contextual action bar over the dock (kit_action_bar.odin): Mask/Hidden/HD groups of command_buttons, folds to one button + popover per group when room is short (rail, sliders, panels), waits when even that doesn't fit; setting `action_bar`. object_has_mask caches on History.serial (bump it in any new proc that changes done/undone). Paint/Group/Make group are disabled (paint_ready) in HD and dyntopo. Scenarios needing a non-default setting write settings_file() and pass --settings-file (e.g. `modifier_rail Off`).
- PR #67 merged 2026-10-26: Basic/More per inspector section (max 5 controls; rest under `kit_more(app,.X)`/`kit_more_end`, ui.more). Settings `all_options` = Show every option. ui.Context.controls counts widgets; kit_more_test.odin fails any section over 5 in its widest state. Brush/Scene sections now in BRUSH_SECTIONS/SCENE_SECTIONS tables. Test globals used by parallel tests must be @(thread_local).
- PR #68 merged 2026-10-26: first-run tips (kit_coach.odin): 3 cards (draw/turn/move) dismissed by doing; settings row `coach` bitmask (7=done); shows only on interactive runs or `--coach`; detection in camera_apply_input + Shift-snap orbit; kit_floating() is the shared "something floats" list.
- PR #69 merged 2026-10-26: starter scenes. geom starters (Head, Bust, Figure, Hand, Creature; geom.is_starter, STARTER_MIN_VERTICES 15k, thin-part lattice), starters get up to 3 levels (starter_levels, object_make_primitive), Menu > New scene (.New_Scene arg into NEW_SCENE_SHAPES, Scene_Command.New, scene_new/scene_replace shared with Open, 2-tap guard 4 s). Phase 3 complete. Menu > Settings is now at (85,566) in touch_check (UI["menu_settings"]).
- Next: phases 4-6 (Phase 4: brush presets, bind where you see it, user pies, keys settings, gesture map editor).
- Test runs: pass `-out:build/app_test` to `odin test src/app`, else it drops an `app` binary in the repo root.
- Known, pre-existing: at ~820 pt wide the centred tools bar overlaps the undo group.

**Why:** the scorecard rated "find a command" lowest; tablets have no shortcuts ([[ux-research]], [[sculpt-registry]]).
**How to apply:** a new command gets SEARCH_WORDS (and PALETTE_LABELS if its label needs its menu heading); pointer-bound commands stay out via palette_lists.
