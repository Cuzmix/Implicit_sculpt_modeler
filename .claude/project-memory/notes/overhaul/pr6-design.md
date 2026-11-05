# PR 6: the object menu (verbs by type and space, viewport openers)

Round 3 design.md "Object chip and menu" and §2.5, with §6's corrections (finger long press
rule, pen default guard, object types from what the chip shows). The chip already shows
type, name and badges (`object_chip.odin`, #286); the menu (`kit_object_menu`, new_ui.odin)
today is a fixed list. Split:

- **6a** the menu itself, in `src/app/object_menu.odin` (moved out of new_ui.odin): head, quick
  row, the space's verbs from a table, other spaces' verbs tagged, the rows always there,
  Delete; and the scene menu for empty space. Openers stay as today (chip tap, Scene list
  row's long press). About 300 lines.
- **6b** the viewport openers: right click (with Settings > Controls > Right click: Object
  menu or Brush pie), the pen's side button (fresh installs only), a finger's long press by
  §6's rule, and the `Object_Menu` command. Settings v8. About 250 lines.

## 6a

- `Object_Type :: enum u8 {Sculpt_Mesh, Voxel_Clay, Cage}` and `object_type(obj)`: the same
  switch `object_chip_of` uses (voxel, then cage, then mesh), which then calls it. Lights and
  folders are not Objects: a folder keeps `kit_folder_menu`, lights keep their own palette.
- `Object_Verb :: struct {id: Command_Id, arg: int, label: string}` and
  `OBJECT_VERBS: [Object_Type][Space][]Object_Verb` (rodata), first entry of each the type's
  main verb in that space:
  - Sculpt mesh: Sculpt `Subdivide`, `Remesh`, `Dyntopo_Toggle`, `New_Layer`, `Extract_Masked`,
    `Mirror_Weld`; Model `Add_Cage` ("Make editable"), `Retopologize`; Render `Place_Light`,
    `Studio_Render`.
  - Voxel clay: Sculpt `Voxel_Res_Up`, `Voxel_Res_Down`; Model `Convert_To_Mesh`; Render
    `Place_Light`.
  - Cage: Model `Edit_Cage`, `Tidy_Cage`, `Cage_Smooth`, `Cage_Check`; Sculpt `Apply_Cage`
    ("Make sculptable"); Render `Place_Light`.
- The menu, top to bottom:
  1. **Head**: the type's icon, name, the type tag and its size (triangles, voxel bricks or
     cage faces), not pressable.
  2. **Quick row** of icon buttons: Focus (`Focus_Selected`), Solo, Hide, Lock (new command
     `Lock_Object`, `view_command(.Lock)`), Layers (`Show_Section` Layers; mesh only).
  3. **This space's verbs** for the type (`command_menu_item`, disabled with the command's own
     `enabled`).
  4. **Other spaces' main verbs**, each with that space's tag (its tint) on the right; picking one
     runs `Space_Switch` then the command, in one frame (both are registry runs).
  5. **Always**: Material (`Show_Section` Material), Move to folder (today's rows, as a submenu
     row that opens the list in place), Rename, Duplicate, the conversion (mesh `Convert_To_Voxels`,
     clay `Convert_To_Mesh`, cage `Apply_Cage`) when step 3 or 4 did not show it already.
  6. **Delete** (danger).
- The menu acts on the selected object; opening it on another object selects it first (a
  `Scene_Command` select, applied before the menu's rows run next frame; the rows read
  `k.object_menu_id`, and run only once the selection is that object).
- **Scene menu** (`kit_scene_menu`, empty space): Add object (`Add_Object`), Paste
  (`Paste_Object`), Show all (`Show_All_Objects`), Frame all (`Frame_All`), New folder.
- Exit stats: `object_menu=` (as today), `object_menu_type=`, `object_menu_rows=` (the count of
  rows drawn, so scenarios can check the table), `scene_menu=`.
- Tests: the table has a main verb for every type and space, every verb id has a label and is no
  `None`; `object_type` agrees with the chip's tag. Touch: chip tap on the default mesh shows
  the Sculpt verbs (rows count); in Model the cage's verbs; an other-space row switches space and
  runs; Lock; parity.

## 6b

- **Right click**: `Nav_Prefs.right_click: enum {Object_Menu, Brush_Pie}`, Settings > Controls,
  default Object menu. In `pie_update`'s closed branch, a right tap (not a drag, which orbits as
  the mouse scheme says) with Object menu set opens the object menu for the object under the
  pointer (`scene_raycast_surface` on `mouse_ray`), else the scene menu, at the pointer; with
  Brush pie, today's pie. Shift+right tap keeps today's meaning.
- **Pen side button**: `GESTURE_DEFAULTS[.Pen_Button]` becomes `{.Object_Menu, 0}`. The new
  command `Object_Menu` opens the menu at the pointer as the right click does (over the
  viewport), or under the chip for the selection (elsewhere). Settings v8: a file older than v8
  with no `pen_button` line keeps `{.Brush_Pie, 0}`, so only fresh installs change.
- **Finger long press** (§6 rule): one finger held still for `hold_delay` on the viewport opens
  the menu only where no stroke would have started: empty space (scene menu), or an object while
  the tool is not one that lays a stroke on a finger press (Brush, Curve, Insert, Model's topo
  pen). With Brush, nothing changes (no setting in this PR: the setting §6 allows, off by
  default, is the same as leaving it out). It is a `long_due`-like check in `touch_route` on the
  single finger that has not moved past the slop, firing once per press and muting the press.
- Pen long press: never (a pen held still draws).
- Exit stats: `right_click=`, `object_menu_opened_by=chip|list|right|pen|finger`.
- Tests: settings round trip and the v7 migration (pen_button absent keeps Brush_Pie; v8 fresh
  default is Object_Menu); touch: right click on the model opens the object menu and on empty
  space the scene menu; Brush pie setting restores the pie; pen side button over the model; a
  finger long press on empty space and under the Move tool; a finger held still with Brush
  sculpts as before (no menu); left-handed; parity.

## Architect review (29 Oct, 22:10) and the decisions taken

All required changes taken:
- 6a ships with today's openers; `kit_scene_menu` moves to 6b (nothing in 6a could open it).
- Verb table: mesh in Model `Edit_Cage`, `Retopologize` (step 4 shows the first enabled); a cage's Model
  verbs are `Tidy_Cage`/`Cage_Smooth` with explicit args and labels (no `Edit_Cage`, which a cage refuses);
  no global toggles (`Cage_Check`, `Studio_Render`, `Place_Light`) as object verbs; Render verbs are the
  Material section and the look's object rows only. Scene menu drops `New_Folder`.
- Other-space rows: `command_enabled` checked before `Space_Switch`; the kit's `menu_item` gains a generic
  `tag`/`tag_color` (from `Theme.tints`) with a ui test.
- Opening on another object: `selection_make_primary` directly (as the Scene list does), never `.Select`;
  the menu closes if the selection stops being `object_menu_id`.
- Right click (6b): anchored at `k.ctx.input.mouse`, `scene_raycast`, `d.pointer != .Pen`; Shift+right tap
  opens whichever of the two is not set.
- Pen default (6b): the `gesture_map Pen_Button` line tracked while reading, `version < 8 && !seen` keeps
  Brush_Pie; `gesture_notes` and kit_help fixed; `pen_button_opens_the_brush_pie` updated (writes v7);
  `Object_Menu` out of `pie_lists`. Right click's default for existing users: asked Bolt (card), default
  "Object menu for everyone" while waiting.
- Finger long press (6b): decided by the drag owner after `pointer_route` (Orbit on empty space, or a Move or
  Model press), never on a pending or Shape press, a handle, the pivot latch, topo/mask/lights/focus, a
  replay, the Knife, dial mods, gestures, palms or a near pen; cancels the press as navigate.odin's mute does;
  its own `HOLD_MENU` constant with the ring.
- Store: popover 260 wide for five 48 pt buttons; `scene_menu` in the close list, `kit_floating` and the dial's
  checks.

## 6a as built

- `src/app/object_menu.odin`: the table, `object_type`, `object_menu_open` and `kit_object_menu` (moved out of
  new_ui.odin). Render has no verbs for any type; its rows are the always-there ones.
- Opening on an object a press can pick uses `selection_make_primary`; a hidden, ghosted or locked one is brought
  back by a `.View .Select` scene command and the menu shows "Selecting it..." for that frame
  (`k.object_menu_wait`), since `selection_make_primary` would select an object out of reach.
- Other-space rows show that space's first verb that can run (a mesh in Sculpt offers Retopologize when it has no
  cage to edit), dimmed when none can.
- The head shows triangles for every type (cage faces as triangles drawn; voxel clay its mesh's).
- Touch: object_menu_lists_the_verbs_of_the_type_and_space (rows 11 for the mesh, 8 for a cage in Model),
  object_menu_other_space_row_switches_and_runs, object_menu_quick_row_locks_the_object.

## 6b as built

- Right click: `Nav_Prefs.right_click` (`Right_Click {Object_Menu, Brush_Pie}`, `right_click` line), chosen in Settings > Keys
  under MOUSE BUTTONS (that is where the mouse scheme lives; there is no Controls tab). The default applies to everyone
  (the decision card's recommended option, no answer yet). `pie_update`: mouse or finger right tap, `(right_click ==
  .Object_Menu) != shift`; the right tap no longer drops Shift. A pen with Shift does nothing, as before.
- Pen side button: since #332 there are two slots, `Pen_Button` (model) and `Pen_Button_Empty`; both default to
  `Object_Menu`, and a file older than v8 with no `gesture_map` line for a slot keeps `Brush_Pie` in it (settings v8).
  The note in Settings > Touch now names a side button that is neither its default nor the pie.
- `view_menu_open` (raycast at the point: object menu, else scene menu), `object_menu_here` (the command: at the
  pointer on the view, else under the chip from `k.object_chip_at`), `kit_scene_menu` (Add object, Paste, Show all
  objects, Frame all; a caption with the object count).
- Finger hold: `hold_menu_check` after the owner switch in `pointer_route`, HOLD_MENU 0.5 s, the ring from the theme's
  long_ring in `kit_hold_menu_ring`. Owners: Orbit anywhere but the safe zone (so Render space and "finger turns the
  view" count), Move on the body (the View handle not yet live; on_handle, posed, live, the pivot latch, a topological
  mask and the lattice refuse), Model on a Pressed non-stroke action (its drag state is dropped, so no tap runs).
  Brush, Curve and Insert never. `route_mute` lost its file privacy for it.
- Help: Object menu's command row and a finger row in VIEW. Exit stats `scene_menu=`, `object_menu_opened_by=`,
  `right_click=`.
- Touch: pen_button_opens_the_object_menu, pen_button_opens_the_brush_pie (now a v7 file),
  right_click_opens_the_object_or_scene_menu, right_click_brush_pie_setting_brings_the_pie_back,
  finger_hold_on_empty_space_opens_the_scene_menu (and left-handed), finger_hold_with_the_move_tool_opens_the_object_menu,
  finger_hold_with_a_brush_still_sculpts. Unit: pen_button_default_changes_for_fresh_installs_only.
