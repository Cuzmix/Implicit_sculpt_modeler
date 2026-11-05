# UI overhaul: design note

Bolt approved the round 3 screens and the whole plan on 2026-10-29 at 10:55: "Let's do all of it and we can add them as settings too ok I like the plan proceed with all".

- Screens: https://claude.ai/artifact/WVaWC8riMYVtzkU1xpqsjq
- Sources: `/mnt/project-files/ui-direction/round3/`
- PNG of every screen: `/mnt/project-files/notes/overhaul/screens/<id>.png`. Compare each PR's `--dump-screen` against these.
- Brainstorm and decisions: https://claude.ai/artifact/AdNY9KYVfEXXPeDtgc7xwz

Everything below builds on the Lens chrome as it stands after the Classic removal (its own thread, merged first). There is one chrome. `k.chrome` and every Classic branch are gone before PR 1 starts.

## 1. What exists when the overhaul is done

### Spaces
- There are three spaces: Sculpt, Model and Render. Texture is appended later.
- The chip bar shows the space as tabs. The lit tab is tinted with the space's colour.
- Choosing a tool picks the space:
  - a brush, Move, Curve or Insert → Sculpt;
  - the Model tool, a Model action or Add cage → Model;
  - a look, a shot or Render → Render.
- Tapping a tab picks that space's last tool.
- Selecting an object never switches the space.

### Per-space layouts
- Each space keeps its own layout, the workspace current in that space.
- The tab's chevron lists the space's layouts, with Save, Save as, Revert, Reset, Export and Import.
- Studio becomes Render's built-in layout.
- Focus and Inspect stop being workspaces and become view toggles:
  - `View_Focus` hides everything but the dock, the dial and the chip bar.
  - `View_Inspect` sets the four-pane Inspect preset with its passes, and its second tap puts the view back.

### Dial and palm zone
- The dial keeps its corner and its four places. The meanings follow the space:
  - Sculpt: Smooth, Pie, Invert, Mask.
  - Paint on: Blur, Pie, Erase, Mask.
  - Model: Snap, Pie, Alt, Select.
  - Render: Light, Pie, Exposure, Focus.
- A user who changed a sector keeps it in every space. Library > Dial edits the current space's sectors.
- The palm zone rule of round 2 stays: nothing is placed in the pen hand's lower corner.

### Chip bar
- One floating chip bar replaces the top bar. Its sections, split by dividers:
  1. Menu and the file.
  2. Undo and Redo.
  3. Spaces.
  4. The object chip.
  5. Search.
  6. History and Settings.
- In Arrange, any section can be dragged out of the bar into an island of its own (a dock holding that section). An island can be dropped back on the bar.

### Docks
- One dock type replaces the off-hand island, the view rail, the shelf and the stack's column.
- A dock sits on an edge (snapped to its middle, as Forger's toolbox does) or floats where it was let go.
- Its density is Icons, Tiles or Panels:
  - Icons: 44 pt slots with an icon only.
  - Tiles: icon and label.
  - Panels: its palette groups stay open as a column.
- A dock holds items:
  - a command or a brush (today's `Bar_Slot`);
  - a value (Size, Strength, Focal shift, as tall sliders);
  - a palette or a palette group.
- A dock can follow the space. The bottom dock does: it holds Sculpt's brush sets (pages Sculpt, Move, Curve, turned by a swipe or the wheel), Model's primitives and actions, or Render's looks, shots and Render.
- The other docks are shared by every space.
- Every dock has a grip (drag to move; long press for its menu) and a + slot (pick anything from Search).
- Default docks:
  - left: Size and Strength;
  - right: palette groups;
  - bottom: the space's set, then the tools strip, then Paint.
- In Arrange: New dock, Library, Reset <space>, Done. Edges light as drop targets while a dock is dragged.

### Palette groups
- Every panel the app has is a palette: Brush, Stroke, Alpha, Symmetry, Layers, Scene, Tools, Lights, Material, Environment, Action, Live stack, Selection and the rest of today's tray sections.
- A group is a stack of tab sets. Each tab set is one or more palettes as tabs.
- Its dock icon shows the first palette's icon with a count badge. A group of two or more shows a 2 × 2 preview when it is a folder made by dropping.
- A tap opens the group beside its dock. The pin keeps it open when another group in the same dock opens.
- Making and changing groups:
  - Drop a palette on another palette's icon in a dock and hold for the hold delay: an Android-style folder is made, named after the target.
  - Drop on an open group: ImGui-style targets appear. The middle adds a tab; the top or bottom stacks a new tab set above or below.
  - A tall group scrolls with one scrollbar. A tab set folds to its header and summary.
  - A tab dragged out floats. Dropped on a dock, it becomes its own icon there. The group's menu has Ungroup.

### Object chip and menu
- The object chip shows the type's icon, the name, the type tag (Sculpt mesh, Voxel clay, Cage, Light, Group, Folder) and up to three badges (level, HD, layers; for a cage: Catmull-Clark level and creases).
- A tap opens the object menu:
  1. Head: name, type and size.
  2. Quick row: Focus, Solo, Hide, Lock, Layers.
  3. The space's verbs for this type.
  4. Rows that are always there: Material, Move to folder, Rename, the conversions. A verb that belongs to another space shows that space's tag and switches to it when picked.
  5. Delete.
- The same menu opens from:
  - a right click on an object in the viewport;
  - the pen's side button over an object;
  - a finger's long press on an object.
- On empty space, the same gestures open the scene menu (Add, Paste, Select all, Frame all).
- The brush pie stays on Space, the dial's Pie sector and Search. The setting Settings > Controls > Right click: Object menu (default) or Brush pie restores the old pie.

### Offers, not refusals
- When the selection does not fit the space (a mesh in Model, a cage in Sculpt, a voxel object under a mesh-only tool):
  - the object chip warns in amber;
  - one offer line, over the dock where the action bar is, names what the object is, what the space needs and the one tap that fixes it (Make editable, Make sculptable, Convert to mesh).
- Tools that cannot act on the selection are dimmed with that reason in their tooltip. They never refuse on press.

### Paint toggle
- Paint is a toggle at the end of the Sculpt dock. Its dot shows the colour.
- On, brushes lay colour: the brush's channel is Both or Color, as the colour island's segment says ("Sculpt + paint" or "Paint only"). Off, the channel is Sculpt.
- The colour island rises above the dock: colour, recent swatches, picker and the segment.

### Motion
- Every press, popover, panel, tab, space switch, drag, drop, dock snap and toast moves by the kit's tokens (round 1 table).
- Round 2 adds:
  - the brush pie and dial unfolding;
  - the camera easing on Frame, Focus, Reset view and bookmarks;
  - cross-fades when the pass or look changes;
  - progress rings on long jobs, then a fade to the new mesh;
  - an undo flash;
  - a mask wipe;
  - the selection outline;
  - Home growing into the scene;
  - panes sliding;
  - the Arrange outline;
  - a save tick;
  - tooltips fading in;
  - the left-handed slide.
- Settings > Interface > Motion:
  - Motion: Full, Reduced or Off. Reduced turns moves into fades of the same length; Off makes every duration 0.
  - One switch per kind (`Motion_Kind`), so any of them can be turned off.
- The OS's reduced-motion preference starts the setting at Reduced.
- Nothing a stroke, the camera under a finger or a drag follows ever animates.

## 2. Data model

### 2.1 Space (`src/app/spaces.odin`, new)
```odin
Space :: enum u8 { Sculpt, Model, Render }   // Texture appended later; never reordered (settings name them)
Spaces :: struct {
	current:  Space,
	tool:     [Space]Space_Tool,   // each space's last tool, restored by a tab tap
	layout:   [Space]int,          // the workspace slot current in each space
	switches: int,                 // exit stat
	slide:    f32,                 // the tab pill's eased x (motion)
}
Space_Tool :: struct { tool: Tool, brush: sculpt.Brush_Kind, action: Model_Action, look: Look_Pick }
```
- `space_of_tool(app) -> Space` is the rule:
  - `Tool.Model` → Model;
  - `app.render_space_tool` set (a look, still or turntable picked) → Render;
  - otherwise Sculpt.
- `space_follow(app)` runs once a frame after the commands and switches `k.spaces.current` when the rule disagrees. A tab tap (`Space_Switch` command, arg the space) restores `tool[space]` first, so the rule then agrees.
- Render's tool: in Render a press on a light moves it (already the Tool's), and a press elsewhere orbits. `drag_decide` gives the Tool nothing in Render, so no stroke lands by accident. Picking a brush from Search in Render switches to Sculpt.
- Tints: `Theme.space[Space]` and `Theme.space_soft[Space]`, a value in every look:
  - Sculpt #5ED6C4 / #1C3B37;
  - Model #FF9F5A / #3D2A1C;
  - Render #8FB8FF / #1E2A40.
  - Lens's accent stays the Sculpt tint, so nothing else changes colour.

### 2.2 Layouts per space (`workspaces.odin`)
- `Built_In` becomes `{Sculpt, Model, Render}`.
- `Workspace` gains `space: Space`: a built-in's is its own; a user's is the space it was saved in.
- `Spaces.layout[space]` is the current slot in each space. `space_switch` is `workspace_switch(k, k.spaces.layout[to])` after keeping the current slot.
- `built_in_layout(.Model)`:
  - open Inspector;
  - the right dock's Action group (Action, Live stack), Selection, Layers, Scene and Symmetry.
- `built_in_layout(.Render)` is today's Studio layout in the new dock words.
- Migration (`SETTINGS_VERSION` 4):
  - an old `workspace_current` of Focus or Inspect becomes Sculpt plus that view toggle on;
  - Studio becomes Render;
  - every own workspace gets space Sculpt, and its text is read through `kit_layout_put`, which ignores lines it no longer knows;
  - the old slots 1 to 3 (Focus, Inspect, Studio) map to Sculpt, Sculpt and Render, and a changed Studio keeps its changes as Render's saved text.
- Workspace files bump `WORKSPACE_FILE_VERSION` to 2 with a `space` line. Version 1 files import as Sculpt.

### 2.3 Docks (`src/app/docks.odin`, new, replacing `lens_shelf.odin`'s strip, `kit_offhand`, `kit_view_rail` and the stack's column)
```odin
Dock_Edge :: enum u8 { Left, Right, Top, Bottom, Float }
Dock_Density :: enum u8 { Icons, Tiles, Panels }
Dock_Value :: enum u8 { Size, Strength, Focal_Shift }
Dock_Item :: union { Bar_Slot, Dock_Value, Group_Ref, Chip_Section }
Group_Ref :: distinct u8     // index into Kit_State.groups
DOCK_MAX :: 8
DOCK_ITEMS :: 24
Dock :: struct {
	used:     bool,
	name:     [24]u8,
	edge:     Dock_Edge,
	along:    f32,               // 0..1 along the edge, 0.5 the middle (snapped), written right-handed
	at:       [2]f32,            // a floating dock's top-left, window points over the scale
	density:  Dock_Density,
	follows:  bool,              // the bottom dock: its items are the space's set
	items:    [DOCK_ITEMS]Dock_Item,
	count:    int,
	sets:     [Space][DOCK_SETS]Bar_List, // a following dock's pages per space (Sculpt: Sculpt, Move, Curve)
	page:     [Space]int,
	// laid out last frame, for drops and Arrange
	rect:     ui.Rect,
	item_at:  [DOCK_ITEMS]ui.Rect,
	slide:    f32,
}
```
- `Kit_State.docks: [DOCK_MAX]Dock`. Default docks (`docks_default`):
  - 0 `Off-hand`: Left, along 0.36, Tiles, items Size and Strength.
  - 1 `Palettes`: Right, along 0.30, Icons, items the groups Brush (Brush, Stroke, Alpha), Layers, Scene, Symmetry and Lights (Lights, Material, Environment).
  - 2 `Tools`: Bottom, along 0.5, Tiles, follows. Sculpt's sets are today's shelf pages Sculpt, Move and Curve, then after a divider the tools strip (`Bar_Which.Tools`), then Paint. Model's set is today's Model page: primitives, actions, Move, Mirror. Render's set is the looks Clay, Studio, Matcap and HDRI, the shots Still, Turntable and Depth of field, then Render.
  - The chip bar is dock 3, Top, along 0.5, holding the six `Chip_Section`s. It is a dock so Arrange treats it as one, but a fresh layout cannot delete it (it holds Menu and Settings). A section dragged out makes a new Float dock holding only that section.
- Layout lines replace `bars`, `stack` and `stack_size` for these zones: `dock <n> <edge> <along> <density> <name>` and `dock_items <n> <item> ...`. Items are written by name: `brush:Clay`, `command:Frame`, `value:Size`, `group:2`, `chip:Spaces`.
  - A following dock's sets are a user setting, not part of a layout, as the dock's brushes are today: `dock_set <space> <page> <slots...>`.
  - Today's `bars`, `stack` and `stack_size` lines are still read once, as the migration of version 3 settings and of workspace files of version 1: the view rail's slots join the Palettes dock after its groups; the shelf pages fill dock 2's Sculpt sets; the stack order fills the groups.
- Placement (`dock_place`):
  - An edge dock is anchored to its edge at `along`.
  - Its long side runs along the edge. Left and Right docks are columns; Top and Bottom docks are rows.
  - It is clamped into the safe area and kept clear of the chip bar, the dial's corner (`rail_reach`) and the palm zone (`lens_palm`). A bottom dock moves left of centre on a tablet, as the shelf does.
  - Floating docks are laid out at `at`. Left-handed mirrors Left and Right and `along`, as `ui.mirrored` does.
- `kit_dock(app, i)` lays out one dock as one root container `dock<i>` (hit testing and `prev_rect` by root name keep working). Then:
  - the grip, the items by kind, and the + slot;
  - a value item is today's `ui.vslider` of the off-hand island;
  - a slot is `bar_slot_button` (tap, long press and lit state as today);
  - a group is `group_icon` (icon, count badge, 2 × 2 preview for a folder);
  - a chip section is the chip bar's section proc.
- `free_area` (today's `lens_free_area`) subtracts every edge dock's rect, so Frame keeps fitting the free area.

### 2.4 Palettes and groups (`src/app/palettes.odin`, new; `lens_stack.odin` folds into it)
```odin
Palette :: enum u8 { Brush, Stroke, Alpha, Falloff, Symmetry, Layers, Scene, Tools, Lights, Material, Environment, Action, Live_Stack, Selection, Mask, Paint, Object, Stats, ... }
TAB_SET_MAX :: 6
GROUP_SETS :: 4
GROUP_MAX :: 16
Tab_Set :: struct { tabs: [TAB_SET_MAX]Palette, count: int, current: int, folded: bool, height: f32 }
Palette_Group :: struct {
	used:    bool,
	name:    [24]u8,     // empty: the first palette's name
	folder:  bool,       // made by a drop: drawn as a 2 × 2 preview
	sets:    [GROUP_SETS]Tab_Set,
	count:   int,
	open:    bool,
	pinned:  bool,
	floated: bool,
	window:  ui.Window,  // where it floats
	width:   f32,        // 0: the stack width of today (300)
	scroll:  f32,
}
```
- `Palette` is one enum over every panel body the app draws. The case list comes from `Stack_Card` and the tray's `Kit_Section` palettes.
  - `palette_body(app, p, inner)` dispatches to today's procs: `stack_brush`, `kit_lens_scene`, `kit_lens_layers`, `kit_lens_tools`, `lens_studio`'s cards, the tray sections' `kit_*_section`.
  - PR 8 then deletes `Stack_Card` and the tray's own list, so there is one palette type.
- `group_panel(app, g, beside)` draws an open group as today's stack does:
  - a header per tab set (grip, tabs, summary when folded, pin, more);
  - its bodies in a `kit_scroll` sized to the room left.
- It opens beside its dock on the side away from the edge, at the icon's height, clamped into the safe area.
- Panels density draws every group of the dock open as a column. That is today's stack column, so the Panels density covers the docked stack.
- Drag and drop (`group_drag`, one `Group_Drag` in `Kit_State`). A drag starts from a dock icon's long press then move, a tab's grip, or a tab dragged past the slop.
  - Over a dock icon: the target scales to 1.08 and a ring fills over `theme.long_press`. Let go after the ring: `group_merge` (folder). Let go before: reorder in the dock.
  - Over an open group: the targets middle (tab) and top or bottom of each tab set (stack above or below), each at least 48 pt. A preview fills the part the palette would take.
  - Over empty space: the palette floats as a group of one at the pointer.
  - Over a dock but no icon: a new icon at that place.
- Layout lines: `group <n> <name> <flags>`, then `group_set <n> <current> <palette> ...`. Old `stack` lines migrate to groups of one in that order, with the Brush card becoming the Brush group (Brush, Stroke, Alpha) and the folded cards becoming closed groups.

### 2.5 Object chip and menu (`src/app/object_menu.odin`, new; `kit_object_menu` moves here)
- `object_type(app, obj) -> Object_Type {Sculpt_Mesh, Voxel_Clay, Cage, Light, Group, Folder}` and `object_badges(app, obj, out: []string)`.
- The rows are a table, `OBJECT_VERBS: [Object_Type][Space][]Object_Verb`, and each `Object_Verb` is a registry command with an optional arg. So the menu needs no logic of its own beyond the table, and a verb from another space is a row with that space's tag that runs `Space_Switch` then the command.
- Opening it:
  - `kit_viewport_input` reads `d.right_tap` on an object, through `object_pickable` at the tap, when `app.nav.right_click == .Object_Menu`;
  - a finger long press on the model when the press is the Tool's and no stroke has started (a `long_due` on the viewport press, cancelled by the slop, and no stroke because the finger's stroke waits `FINGER_HOLD` anyway, so the menu fires before a stroke when the finger holds still);
  - the pen's side button follows the right click (`gesture_map`'s Pen button slot default becomes Object menu, and the Pencil thread's slots keep working).
- Empty space opens `kit_scene_menu`.

### 2.6 Offers (`src/app/offers.odin`, new)
- `space_fit(app) -> (fits: bool, offer: Offer)`, cached on `history.serial` and the selection. `Offer :: struct {what, needs: string, fix: Command_Id, arg: int}`.
- `command.enabled` returns false with `command_reason(app, id) -> string`, the reason shown in the tooltip, for every command that `CAGE_REFUSED_SCENE` or `MESH_ONLY_COMMANDS` refuses today. Those refusal toasts are removed. A press on a dimmed tool does nothing but show its tooltip.
- `kit_offer_line` sits where `kit_action_bar` does and replaces it while an offer stands.

### 2.7 Paint toggle (`paint_toggle.odin`, new, small)
- `Paint_Toggle` command. `app.brush.channel` stays the truth: on is `paint_channel_on` (Both or Color, remembered), off is Sculpt. So strokes, replay and files are unchanged.
- The colour island: `kit_colour_island`, above the bottom dock while the channel is not Sculpt.
- The dial labels Blur and Erase: Smooth under a colour channel already smooths colour; Invert under Color erases to the second colour. The labels follow (`wheel_labels`), and no new modifier is needed.

### 2.8 Motion (`src/ui/motion.odin`, `theme.odin`; `src/app/motion_prefs.odin`, new)
```odin
Motion_Level :: enum u8 { Full, Reduced, Off }
Motion_Kind :: enum u8 { Press, Popovers, Panels, Tabs, Spaces, Drag_Drop, Toasts, Pie, Camera, Passes, Progress, Undo_Flash, Mask_Wipe, Selection, Home, Panes, Arrange, Save_Tick, Tooltips, Hand_Switch }
```
- The kit gains `ctx.motion_off: bit_set[Motion_Kind]`-like control. Since `src/ui` must not know the app's kinds, the kit takes `Motion_Class` per call instead: `tween(ctx, id, target, duration, ease, class = .Move)`. `ctx.motion` is `{level, off: bit_set[0..<32]}`, and the app maps `Motion_Kind` to bit numbers.
- Reduced keeps fades and drops moves and scales: `transform_since` scales and offsets go to identity, and opacity keeps its tween.
- The camera ease (`camera_ease`, `navigate.odin`): `View_Frame`, `View_Focus`, `View_Reset`, bookmarks and the nav head's axis taps set an `Orbit_Ease {from, to, t}` that `camera_apply_input` advances. Any pointer or finger input on the view cancels it at once, so input stays exact.
  - Determinism: the ease is the camera only, never the model. Replays of strokes record the camera per sample already.
- Pass cross-fade: the renderer keeps the last frame's picture (the idle cache already has it). `kit_grid` draws the new pass over it with the tween's opacity for `indicator_time`. Off while recording.
- Progress ring: `Job_Progress` (0 to 1) that remesh, subdivide, voxel conversion and bake already report through `report` gets a `progress` field. The tile of the running command draws a ring.
- The undo flash and the mask wipe are overlay draws in `overlay.odin` fed by the dirty range's bounds, which undo already computes.

## 3. PR order

Each PR is merged into odin-sculpt before the next starts. Each runs the full gate and updates README, sm-ui, the touch scenarios it moves, and memory.

1. **Spaces.**
   - `Space`, `space_follow`, tab command `Space_Switch` (keys Alt+Shift+1..3? no: Ctrl+1..3 if free, decided against `DEFAULT_BINDINGS`).
   - Per-space layouts and the settings v4 migration. Focus and Inspect as view toggles.
   - The tints. Per-space dial sectors and labels; Render's Light, Exposure and Focus sectors as commands.
   - In today's top bar: the workspace pill becomes the space tabs, and the chevron is the layouts menu.
   - Render's press rule.
2. **Chip bar.**
   - `kit_chip_bar` with the six sections, the object chip (type, name, badges) and the warning dot slot.
   - The top bar goes. View chips stay at the top left under it.
3. **Docks I.**
   - The `Dock` type and placement, the off-hand and bottom docks (the shelf's pages become the bottom dock's Sculpt sets; Model and Render sets), and the Paint slot as a plain command until PR 7.
   - Layout lines and migration. The chip bar becomes a dock.
   - Arrange: drag docks to edges and float, New dock, density, delete, Reset <space>, and chip sections out into islands.
4. **Docks II: palette groups.**
   - `Palette_Group` and the Palettes dock replacing the stack column.
   - The group panel beside the dock, pins, folding, scroll.
   - Folders by drop and hold, targets on open groups, tabs dragged out, Ungroup.
   - The view rail's slots join the Palettes dock.
5. **Object menu.**
   - The verb table, right click, long press, pen button, the scene menu and the Right click setting.
6. **Offers.**
   - `space_fit`, the chip warning, the offer line, dimmed tools with reasons, and refusals removed.
7. **Paint toggle.**
   - The command, the colour island and the dial labels.
8. **One palette type.**
   - `Stack_Card`, the tray's palette list and the windows' palette bodies all become `Palette`; the tray and `kit_inspector`'s Lens branch go.
9. **Motion I.**
   - The kit's motion classes and Settings > Interface > Motion.
   - Round 1's table everywhere: press, hover, popovers, groups, tabs, sections, the space switch, Paint, drag lift, hold-to-group, drop, dock snap, offer and toast.
10. **Motion II.**
    - Pie and dial unfold, camera ease, pass and look cross-fade, progress rings and the fade-in, undo flash, mask wipe, selection outline, Home grow, pane slide, Arrange outline, save tick, tooltips and the left-handed slide.
11. **Sweep.**
    - Touch scenarios for every new gesture (docks, groups, spaces, the object menu, offers).
    - README's Interface rewritten.
    - sm-ui and sm-touch-testing updated. Exit stats checked.

After the sweep, the Texture space has its own plan: UVs, texture layers and baking.

## 4. Rules each PR keeps

- `src/ui` gains only generic things: motion classes, a hold ring, drop targets as shapes. It never learns spaces or palettes.
- Panels keep no references between frames: docks and groups are indexes into `Kit_State` arrays, and drops are applied at the start of the next frame (`k.dock_op`, as `Grid_Op` is).
- A layout is text, and every new line round-trips through `kit_layout_text` and `kit_layout_put`.
  - Tests: every built-in layout is canonical, and old layouts (v3 `stack`, `bars`) migrate to the same docks a fresh install has when they are a fresh install's.
- Every hit target is 48 pt. Docks clamp into the safe area. The palm zone stays empty.
- Settings and workspace file versions bump, and every older one keeps reading.
- Determinism: nothing here touches meshes. The camera ease is input-cancelled and never runs during replay (`replay_frame` sets the camera per sample).

## 5. Open choices with defaults (decided; change only if Bolt says)

- **Space keys:** Ctrl+1, Ctrl+2 and Ctrl+3 if none is bound; otherwise Alt+Shift+1..3. The first free set in `DEFAULT_BINDINGS` wins.
- **Group closing:** an unpinned group closes when another group of the same dock opens, or when its icon is tapped again. A viewport press does not close it, so settings stay visible while sculpting.
- **Long-press object menu:** only on a finger. The pen's long press stays the stroke's, since a pen held still is drawing.
- **Render:** the bottom dock's look tiles set `viewport_pass`/look, as the Studio workspace's look does today. Still and Turntable run today's commands.

## 6. Architect review (29 Oct): corrections. This section wins over the sections above.

### Wrong in the note
- **Paint's dial needs new sculpt work.** Today Smooth always smooths the surface (sculpt_tool.odin:873,921), and invert under a channel digs (sculpt/paint.odin:70-80). Blur and Erase need:
  - a colour-smooth dab;
  - erase under a channel;
  - a `STROKES_VERSION` bump.
  - This is its own sm-sculpt design (PR 8a), not a relabel.
- **No operation reports progress.** Remesh, subdivide and the others run on the frame thread inside `scene_apply`. Progress rings need those operations moved off the thread, which needs its own design (async ops).
- **The pass cross-fade needs a kept texture.** The idle cache holds idle objects only. This is a render design of its own.
- **The finger long press loses to the stroke.** The press is `hold_delay` (0.25 s) and the stroke waits `FINGER_HOLD` (90 ms). Rule:
  - the object menu fires on a finger long press only where nothing was laid: empty space, or a tool other than Brush;
  - for Brush, it sits behind a setting (off by default) and uses `stroke_cancel`.
- **Command names.** The camera commands are `Frame_All`, `Focus_Selected` and `Reset_Camera`. The view toggles are new commands, `Focus_Mode` and `Inspect_Mode`.
- **Name clashes.** `Palette_Group` already exists (lens_search.odin:15). New names:
  - groups: `Panel_Group`;
  - the panel type: `Panel_Kind :: union {Kit_Section, Card}`;
  - docks: `Bar_Dock`, with `bar_dock_*` procs, since dock.odin is taken.
- **Object types.** Folders and lights are not Objects, so the type is computed from what the chip shows (Object, Folder or light pick).
- **Tints.** They become generic kit tokens `Theme.tints[4]` and `tints_soft[4]`. `src/ui` never learns `Space`.
- **Left-handed.** `along` mirrors only for Top and Bottom docks.
- **Chip bar.** It stays its own zone, not a dock item. A section pulled out uses a shared `Placement {edge, along, at}` and `bar_dock_place`.
- **Settings slots are absolute.** The v4 migration remaps the old slots:
  - 0 → 0;
  - 3 (Studio) → 2 (Render);
  - 4..11 → 3..10;
  - 1 and 2 (Focus, Inspect) become own Sculpt workspaces named Focus and Inspect if they were changed from the frozen v3 text, and are dropped otherwise;
  - a current of Focus or Inspect becomes Sculpt with that toggle on.
- **Command aliases.**
  - `Workspace:Focus` → `Focus_Mode`;
  - `Workspace:Inspect` → `Inspect_Mode`;
  - `Workspace:Studio` → `Workspace:Render`.
- **The pen side button.** Only fresh installs get Object menu. Existing settings files without a pen_button line keep Brush_Pie (settings v5, PR 6).
- **Motion settings.** The existing `reduce_motion` setting and `Reduce_Motion` command mean Off, and the migration maps them so. The OS reduced-motion preference needs code per platform (sm-store).
- **Docked columns and pinned panels** (`panels.odin`) are decided in PR 5a: they fold into floating groups.

### Defaults taken
- Move keeps the current space, so Move in Model stays Model.
- Ctrl+1..3 switch spaces (they are free).
- One dial array per space. A changed v3 dial is copied into all three spaces; Library edits the current space's.
- `WORKSPACE_FILE_VERSION` goes to 2 with a `space` line, and v1 files import as Sculpt.

### Revised PR order
1. **Spaces.**
   - `spaces.odin` with `space_switch` and an event-driven `space_follow`: Model → Model; Brush, Curve and Insert → Sculpt; Move neutral; Add_Cage switches to Model.
   - `Space_Switch` on Ctrl+1..3, `Focus_Mode`, `Inspect_Mode`.
   - Built_In Sculpt, Model and Render; `Workspace.space`; the filtered layouts menu; the v4 migration and aliases; workspace file v2.
   - Top bar space tabs with tints; Render's press orbits; shelf pages per space.
2. **Chip bar**, without dragging sections out.
3. **Docks.**
   - 3a. The `Bar_Dock` type and placement: off-hand, rail and shelf become docks with the old root names, with layout lines and migration (parity_check).
   - 3b. Per-space bottom sets (Model, Render; the Paint page migrates) and the per-space dial (Model Select, Render Light, Exposure and Focus commands).
   - 3c. Arrange for docks.
4. **`Panel_Kind` union** and `panel_body` (no UI change).
5. **Panel groups.**
   - 5a. Static groups: the Palettes dock replaces the stack column; columns and pins fold in.
   - 5b. Drag and drop: hold ring, targets, folders, Ungroup.
6. **Object menu:** verb table, right click, long press rule, pen default guard.
7. **Offers:** `space_fit`, chip warning, offer line, dimmed commands with `command_reason`. The `scene_apply` guards stay for scripts.
8. **Paint.**
   - 8a. Sculpt: colour smooth, erase under a channel, replay version, determinism test.
   - 8b. Paint toggle UI.
9. **Tray and stack removal.**
10. **Motion I** and Settings > Interface > Motion.
11. **Motion II:** pie and dial unfold, camera ease (duration 0 in `--frames` runs and while recording; it eases shift and distance too), undo flash, mask wipe, selection outline, Home grow, pane slide, Arrange outline, save tick, tooltips, left-handed slide.
12. **Long-job progress rings**, with a fade to the new mesh (async ops design).
13. **Pass and look cross-fade** (kept texture, render design).
14. **Sweep:** chip sections as islands, touch, README and skills.

## 7. Additions after approval (29 Oct, 11:30)

- Palette group drop targets (Bolt): tab, above, below, **left and right**, on docked and floating groups alike. Left or right puts the palette beside the group, which widens into two columns (each its own tab set, a draggable divider between them), growing away from the screen edge it is docked on. Where there is no room for two columns, the drop falls back to below and the hint says so. A whole dock or group dropped left or right of another docked one sits beside it on that edge. Mock: round 3 artifact, tab 10, screen 4b (pgG). Lands in PR 5b.
- History revamp (Bolt: copy Nomad's look, make it better). Mock: round 3 artifact, tab 12 (hList, hStrip, hMenu, hSettings, hScrub). Build order H1 list view (needs per-step sizes from the sculpt History), H2 step menu and bookmarks (Paint back to here replaces Marker), H3 tint of what a step changed, H4 settings tab (MB limit, memory stats, include switches, camera follows the History), H5 quick scrub (hold Undo, two-finger hold and slide), H6 step pictures; later, kept undone branches (needs its own design: it changes the History). Waits for Bolt's comments on the mock.
- More panels (Bolt 12:51: "lets do all of them show me a mock", 12:52 plus more motion): round 3 artifact tab 13 (mLayers, mObjects, mMaterials, mExport, mHelp, mTour, motion demos mMotionRows/mMotionHelp, motion rows 14-24). Build order P1 Layers panel, P2 layer masks (own design: changes how layers add up, scene version bump), P3 Objects outliner, P4 Materials and matcaps, P5 Export presets and checks, P6 Help overlay and tour. Waits for Bolt's comments.
- 2026-10-29 13:06 Bolt approved tabs 12 and 13 ("All looks good proceed"): History H1-H6 and panels P1-P6 join the build queue after the overhaul PRs (P2 layer masks and H-later kept branches get their own design first).
- 2026-10-29 14:20 Bolt: icons for Size, Strength and the other brush values, placeable in the toolbars as Classic had them, with the user choosing. Plan (PR 3a, Docks): `Dock_Value` items Size, Strength, Focal shift, Spacing, Lazy, each with its own icon, placeable on any bar or dock; per item a look picked by long press: Slider (today's tall `ui.vslider`), Chip (icon plus number; tap opens a slider popover beside it, a drag along the chip scrubs, ZBrush iPad style) or Icon (icon only, tap opens the slider). Default unchanged (tall sliders in the left dock). Mock: round 3 artifact tab 14 (vChips, vLooks, vIcons), published 14:45.
