# Command registry: design (workstream 1, step 1)

Base: odin-sculpt 9757a21. Goal: every shortcut, menu row, pie slice and command button runs through one table, with no visible change. Later work (search, rebinding, toasts with Undo, adjust-last, scripts) reads the same table.

## What exists
- `src/app/shortcuts.odin` `handle_shortcuts`: 27 hand-written `key_pressed` checks with ad-hoc modifier tests (some ignore Shift, some ignore Ctrl). Called from `kit_frame` (`new_ui.odin`) when no text field has the keys.
- `kit_frame` also handles F11 (Stats), Tab (inspector) and Escape/AC Back (close floating things, then `replay_stop`).
- Menus (`kit_menu`, `kit_view_menu`, `kit_object_menu` in `new_ui.odin`) call the same procs directly and type their shortcut text by hand ("Ctrl+O", "Shift+F"…), so the text can drift from the real binding.
- Top bar undo/redo `icon_button`s pass `keys = "Ctrl+Z"` by hand.
- Pie (`pie.odin`) picks `sculpt.Brush_Kind(slice)` directly.
- Panels set `app.ui.scene_command` (deferred one frame) or call `mask_command`, `hide_command`, `file_dialog`, `focus_selected`, `studio_toggle` directly.

## Design

New file `src/app/commands.odin`, package `main`. No new package, no new import edges (it uses `sdl` for key codes, which `app` already imports).

```odin
Command_Id :: enum u8 {
	None,
	// File
	Open_Scene, Save_Scene, Save_Scene_As, Import_Mesh, Export_Mesh, Screenshot,
	// Edit
	Undo, Redo, Delete_Object, Duplicate_Object,
	// Tools
	Tool_Move, Tool_Sculpt, Tool_Curve, Tool_Insert, Brush, // Brush takes the Brush_Kind as its argument
	Symmetry_X, Size_Down, Size_Up, Strength_Down, Strength_Up,
	Replay_Stroke,
	// Object
	Remesh, Dyntopo_Toggle, Subdivide, Level_Up, Level_Down, Hd_Toggle, Group_Shortcut,
	Mask_Clear, Mask_Invert, Show_All, Invert_Hidden,
	// View
	View_Axis, // argument: camera.Axis_View
	Ortho_Toggle, Focus_Selected, Reset_Camera, Wireframe, Flat_Shading, Polygroups, Studio_Render,
	// App
	Stats, Inspector, Settings, Reduce_Motion,
}

Command :: struct {
	label:   string,                          // "Save scene", the menu and search text
	help:    string,                          // one sentence: what it does (search, long-press help later)
	icon:    rune,                            // 0 for none
	args:    int,                             // 0: no argument; n: takes 0..<n (Brush: len(Brush_Kind))
	run:     proc(app: ^App, arg: int),
	enabled: proc(app: ^App, arg: int) -> bool, // nil: always
	checked: proc(app: ^App, arg: int) -> bool, // nil: not a toggle
}

COMMANDS := [Command_Id]Command{ ... }   // a full enumerated array: the compiler refuses a missing row

Key_Mod :: enum u8 {Ctrl, Shift, Alt}
Chord :: struct {
	key:    sdl.Keycode,
	mods:   bit_set[Key_Mod; u8], // matched exactly: Ctrl+Z is not Ctrl+Shift+Z
	repeat: bool,                 // key repeat runs it again ([ and ], undo)
}
Binding :: struct {chord: Chord, command: Command_Id, arg: int}

DEFAULT_BINDINGS := [?]Binding{
	{{sdl.K_Z, {.Ctrl}, true}, .Undo, 0},
	{{sdl.K_Z, {.Ctrl, .Shift}, true}, .Redo, 0},
	{{sdl.K_Y, {.Ctrl}, true}, .Redo, 0},
	{{sdl.K_S, {.Ctrl}, false}, .Save_Scene, 0},
	... // one row per line of today's handle_shortcuts, plus F11 and Tab
}
```

App gains `bindings: [dynamic]Binding`, filled from `DEFAULT_BINDINGS` at start (workstream 4 later loads user overrides from settings; nothing is saved in this step).

Procs:
```odin
command_run     :: proc(app: ^App, id: Command_Id, arg := 0) -> bool   // false when disabled; runs it otherwise
command_enabled :: proc(app: ^App, id: Command_Id, arg := 0) -> bool
command_checked :: proc(app: ^App, id: Command_Id, arg := 0) -> bool
command_label   :: proc(id: Command_Id, arg := 0) -> string            // Brush: "Clay brush"; View_Axis: "Front view"
command_keys    :: proc(app: ^App, id: Command_Id, arg := 0) -> string // first binding as "Ctrl+Shift+S", temp allocator; "" if none
chord_text      :: proc(c: Chord) -> string                             // temp allocator
chord_held      :: proc(d: ^Device, c: Chord) -> bool                   // pressed this frame with exactly these modifiers
commands_handle_keys :: proc(app: ^App)                                 // replaces handle_shortcuts
command_menu_item :: proc(app: ^App, id: Command_Id, arg := 0, label := "") -> bool // ui.menu_item from the table; runs it; true when picked
```

`commands_handle_keys` walks `app.bindings` in order and, for each binding whose chord is down this frame (the same once-per-frame `key_pressed` semantics as today), runs its command if enabled. Same call site and the same `typing(app)` guard as `handle_shortcuts`.

Ownership: `COMMANDS` and `DEFAULT_BINDINGS` are constants; `app.bindings` is made at start and freed in `app_destroy`. Strings from `command_keys`/`chord_text`/`command_label` are temp-allocated per frame; nothing temp is stored.

Threading: main thread only. No jobs.

Failures: `command_run` on a disabled command returns false and does nothing; bindings with an out-of-range `arg` are an assert in debug (table data, a programming error).

## Behaviour changes (deliberate, small)
1. Modifiers match exactly. Today Shift+B, Shift+C, Shift+1 … also pick tools and brushes because those lines only test `!ctrl && !alt`; after this they don't. This is design rule #36/#38 in the research (one meaning per key). Every chord that works today without extra modifiers keeps working.
2. Menu shortcut text comes from the bindings, so it can never drift. Today's texts all match the bindings, so nothing visible changes.

Escape stays outside the table: it is the universal "close what floats, then stop the replay" key, ordered against popovers in `kit_frame`. Space (pie) and S/U (adjust) stay modal input in `pie.odin` and `adjust.odin`; they are not commands.

## Scene_Command and History
No new `Scene_Command` kind and no History change. Commands that change the scene keep setting `app.ui.scene_command` (still applied at the start of the next frame) or calling `mask_command`/`hide_command`, which record History as today. The registry is only the dispatcher. The operation result channel (step 4) is designed separately.

## Tests
- `build test` gains `src/app` (probed: `odin test src/app` builds and links with SDL on Linux; build.bat copies SDL3.dll next to `test_app.exe`).
- `commands_test.odin`: every command has a label and help; no two default bindings share a chord; every binding's arg is in range; `chord_text` gives "Ctrl+Shift+Z", "Shift+F", "F12", "Del", "Num 1"; `chord_held` with a scripted Device: Ctrl+Shift+Z holds Redo's chord and not Undo's; the texts menus showed before (Ctrl+O, Ctrl+S, Ctrl+Shift+S, F12, F11, Shift+F, Shift+G, Shift+W, Shift+R, P, F, Ctrl+Shift+D, Del) equal `command_keys` for their commands.
- All touch_check scenarios unchanged (they drive keys through `--ui-events`), smoke, check, wincheck, androidcheck.

## Plan (PRs into odin-sculpt)
1. This PR: `commands.odin`, `commands_test.odin`, `handle_shortcuts` replaced, F11/Tab moved in, the three menus and undo/redo buttons use the table, pie picks via `command_run(.Brush, slice)`, `app` added to `build test`. About 450 lines, most of it table rows. README "Controls" notes exact modifiers.
2. Inspector buttons through commands (`kit_object`, `kit_scene`, `boolean`, `retopo`, …), with commands reading the section's chosen values from `app.ui`.
3. `Op_Result` and toasts with Undo; remove `*_last` structs.
4. Settings schema; brush descriptor table (labels, icons, help move out of `ui.odin`/`new_ui.odin`).
