# Round 2, PR 9: Scene, Layers and tool palettes (design)

Screens `scene2`, `tools2` and `geo2` of the approved round 2 mock. Lens chrome only. Built as two PRs, as PR 4 was:

- **9a: the Scene and Layers cards** (`scene2`).
- **9b: the Tools card and the mask context bar** (`tools2`, `geo2`).

## 9a: Scene and Layers cards

### Scene card (`lens_scene.odin`)

The stack's Scene card stops drawing the tray's Objects section and draws the mock's list instead.

- **Header line:** "5 objects".
- **Filter field:** "Filter objects", shown once there are more than ten objects. It matches names, ignoring case. A folder shows while any object in it matches.
- **Object rows:** the Objects card's thumbnail rows (`ui.thumb_row`, `thumb_for`). Each row shows the picture, the name and the triangle count ("3.73M tris"). The toggles are the eye and a **lock**. Folders are rows with their count and chevron, as on the card. Rows behave as they do on the Objects card:
  - a tap selects; Ctrl, Shift or Select several adds to the selection;
  - a drag reorders or moves a row into a folder (`kit_tree_drags`);
  - the eye column sweeps;
  - a long press (or a right click) opens the object's menu, which is the existing `object_menu_open` menu.
- **SELECTION SETS:** the app's selection sets are ZBrush's: stored masks of the selected object, which is what the mock's "Face front" and "Left ear" are. A caption, then each of the selected object's sets as a row with how much it masks ("38 %"). A tap restores it (Replace), and a long press opens the Sets section on it, where Add, Subtract, Store over, Rename and Delete are. Then "Store mask as set".

### Lock

The lock is a new per-object flag, `Object.locked`, the fourth view bit. The scene file moves to **version 25** ("each object's lock (a fourth view bit)"); older files read with every object unlocked. What the lock does:

- A locked object takes no press in the view: `scene_raycast` and the curve tool's pick pass over it, so a stroke, a mask stroke, a tap and the gizmo's pick go through to whatever is behind it, or orbit. It still draws as it is (a ghost is dimmed; a locked object is not).
- Its row's lock icon is lit, and Ctrl+click on the lock locks every other object (ZBrush's Freeze others).
- Changing it is a `View` scene command, `.Lock` / `.Unlock`. Like turning an eye, it is not an undo step.

### Layers card (`lens_layers.odin`)

The card stops drawing the tray's Layers section and draws the mock's rows, newest on top:

- **A layer's row:** the eye, the name, the strength as a number, and a red dot while it records. A tap on the row picks it. A tap on the dot, or on the empty dot place, records into it or stops recording. The picked row is taller and holds the strength slider, with the slider's range as the section's (−1 to 2, or ±5 with Wide strength).
- **Base:** the last row stands for the surface under the layers. It shows "locked" while a layer records, since strokes then go only into that layer, and "base" otherwise.
- **New layer:** a row at the end. The mock drew an **Add | Replace** segment beside it, which is left out: New layer already makes the new layer the one recording, which is what a second mode would have added, and the layer model has no other way for a stroke to go into a layer.
- **Layer options**, a fold under the rows: the picked layer's name, Delete and Bake, Duplicate, Invert, Merge down, Move up and down, Bake all and Wide strength (the existing `Layer_Edit` commands and `layer_remove`).

### Classic

Classic draws the tray's Objects and Layers sections as before.

### Stats

- `scene_filter=`, `scene_rows=`, `object_locks=` (how many objects are locked).
- `layer_rows=`.

### Tests

- Lock round trip in a scene file. An older file reads with everything unlocked.
- A raycast passes over a locked object.
- The filter matches names and keeps the folders of matching objects.
- touch_check:
  - `lens_scene_card_locks_an_object`: tap the lock, then a stroke on it does nothing (dabs 0).
  - `lens_scene_card_filters_past_ten` (with `--script` adding objects).
  - `lens_layers_card_records_and_picks`.

## 9b: Tools card and context bar

### Tools card

The stack gets a sixth card, **Tools** (`Stack_Card.Tools`, after Scene; `stack` layout lines that lack it put it after Scene). It has four tabs, and its header line names the tab.

- **Mask:** the mask's commands as a 3-across grid of big labelled buttons, with the key under the label: Invert, Clear, Blur, Sharpen, Grow, Shrink, By cavity, By angle (the Mask by section's kinds) and Extract. Under the grid: Mask blur and Show the mask.
- **Visibility:** the same grid of the visibility commands (Show all, Invert visible, Hide masked, Delete hidden, Grow, Shrink), then Store visibility's V1 to V8.
- **Geometry:**
  - REMESH: the Half / Same / Double segment, the density slider and a Remesh button. These are the existing remesh quick menu's choices and its target.
  - SUBDIVISION: the levels as numbered chips (a tap steps to that level), Divide, and the Dynamic topology switch.
  - MODIFY TOPOLOGY: the mesh repair grid (Close holes, Delete hidden, Weld points, Check mesh, Fix mesh, Delete half).
- **Deform:** the tray's Deformation section (the deformation sliders).

Every button is an existing command, through `command_button`, so its shortcut, gesture and enabled state come from the registry.

### Context bar

The context bar is the existing action bar (`kit_action_bar`) in Lens:

- While a mask exists it shows "Mask · Invert · Clear · Blur · Grow · By cavity · Extract…" over the shelf.
- While parts are hidden it shows "Hidden · Show all · Invert · Delete hidden".

The bar is restyled as the mock's chip row, but its rules for when it shows stay as they are.

## 9a as built

Screens: `screens/round2/pr9a-layers-scene.png` (two layers, three objects), `pr9a-filter-lock.png` (twelve objects filtered to "3", Sphere 3 locked), `pr9a-full.png`.

- **Scene rows** are compact thumbnail rows (`Thumb_Row.compact`, a touch target tall with a 34 point picture), so five objects fit where the Objects card shows three, as in the mock. The open card's header says "N objects"; the Layers header names the object.
- **Lock** also leaves the selection: a locked object counts as out of reach for `scene_selection_fix`, as a ghost does, so nothing stays selected that a press cannot reach. A tap on a locked row unlocks and selects it, as `.Select` brings back a hidden or ghosted object. Classic has no lock control, but it honours a lock read from a file.
- **Layers:** the picked row's head leaves out the strength number, because its slider shows it. New layer and Store mask as set are light buttons (text in the accent colour), as the mock's New layer row is.
- **Stats added:** `layer_picked` and `layer_recording`, which the touch scenario reads.
- **Tests:** `a_locked_object_takes_no_press`, `scene_filter_matches_names`, and the extended `view_flags_round_trip_in_the_file` (the lock bit at version 25, refused at 24). The touch scenarios are `lens_scene_card_locks_an_object`, `lens_scene_card_filters_past_ten` and `lens_layers_card_records_and_picks` (two steps).

## 9b as built

Screens: `screens/round2/pr9b-mask-tab-context-bar.png` (the Mask tab and Lens's context bar on a masked sphere), `pr9b-geometry-visibility.png` (the Geometry and Visibility tabs), `pr9b-mask-hidden.png` (Show the mask off: the masked sphere is drawn as the rest).

- **Tiles** are 56 points tall, three across. Each tile shows its icon, its label and its key (`command_keys`), and is dimmed while its command cannot run. **By angle** is Mask by Facing away.
- **Mask blur** is the existing **Steps** slider: the number of rings that Blur, Sharpen, Grow and Shrink move. The mask has no blur radius in pixels.
- **Show the mask** is `Ui_State.mask_hidden`. It reaches the shader through the viewport style's free z lane (`viewport_style`, `mesh_shading.glsl`), so the uniform layout is unchanged. Thumbnails still show the mask. It is a session toggle, not stored.
- **Geometry:**
  - Remesh sends the Remesh scene command at the Density value. It leaves Rebuild's goal setting as it is.
  - Half, Same and Double show none as chosen while Density matches none of them.
  - The level chips are numbered from 1, as the Levels section says "Level 1 of 2".
- **Visibility:** the stored visibilities are the objects' V1 to V8 (`Visibility_Slot`), under the caption OBJECTS SHOWN.
- **Context bar:** in Lens, `action_list` gives the mask "Invert · Clear · Blur · Grow · By cavity · Extract", with Extract bordered in accent, and hidden parts "Show all · Invert · Delete hidden". The buttons were already chips (flat, faint fill), so only the lists changed. Extract runs at once, so it has no ellipsis.
- **Stack:** a saved stack line without Tools gets the card inserted after Scene.
- **Section links:** `stack_card_of` still sends the Mask, Visibility and Deform sections to Palettes, which holds their full controls.
- **Stats added:** `tools_tab`, `mask_hidden` and `selected_level`.
- **Tests:**
  - `context_bar_lists_follow_the_layout`, `tool_tiles_are_registry_commands`, `show_the_mask_goes_to_the_style`, and the stack layout read of an old line.
  - Touch: `lens_tools_card_inverts_the_mask`, `lens_tools_card_hides_the_mask_view`, `lens_tools_card_level_chip_steps_down` and `lens_context_bar_extracts_the_mask`.
