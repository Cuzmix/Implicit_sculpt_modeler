# Round 2, PR 11: Arrange, Home, Export and Settings (design)

PR 11 covers four screens of the approved round 2 mock: `settings2`, `export2`, `home2` and `custom2`. Each one is a sheet or a page of its own, so the work is split into four PRs, one per screen. All four change Lens only. Classic keeps what it has.

Order: **11a Settings**, **11b Export**, **11c Home**, **11d Arrange and the dial**. Settings comes first because the Dial section it adds is where 11d's sector choices also show.

## What the app has, and what differs from the mock

| Screen | Today | Mock |
|---|---|---|
| Settings | A 400-point panel at the right with five tabs (Interface, Camera, Touch, Keys, System), each one long list. | A wide sheet with sections down the side (Interface, Camera, Touch, Pen, Dial, Performance, Frame rate, Bars, Files, Shortcuts), a search field over them, and Reset this section and Reset all settings at the foot. Touch lists every gesture as a row with what it does on the right. |
| Export | The Menu's Export submenu, plus Save screenshot..., Turntable video... and 3D print..., each going straight to a file dialog. | One sheet: the formats on the left (Sculpt scene, OBJ, PLY, STL, glTF, USD, Screenshot, Turntable video, 3D print), the chosen format's options on the right, and the file name and its size at the foot before Export. |
| Home | A NEW SCENE column of six shape tiles and Open a file..., with Recent and Autosaves tabs of scene pictures beside it. | A large **Continue** card for the newest scene, **Start new** as six big tiles, and a **Recent** row with Open... and Import... |
| Arrange | A head card under the top bar ("Arranging Sculpt", Done, Panels, Reset bars, Revert, Save as new, and Show chips for the bars), ringed buttons, and the column drop zones. | The workspace switcher becomes Reset zone, Reset workspace, Save as new and Done. Every zone shows its outline and its name (Off-hand, Dial, Shelf, Panels, Rail). The dial is a zone too, and the Library has a Dial tab that chooses its four sectors. |

## 11a: Settings (`settings2`)

### Blocks and sections

- Today's tab procs become **blocks**, one for each caption group: Look, Size, Layout, Hands, Motion, Starting, Brush ring, Panels, View grid, Bars, Action bar, Wheel, Inspector, Pies, Panel places, Orbit, Safe zone, Pan and zoom, Mouse, One finger, Hold, Pen on empty space, Pen, Gestures, Gesture map, Shapes, Keys, Statistics, Display, Autosave, Earlier saves, Undo history and Blender link. Each block is one proc with the code it has now.
- `Settings_Block` lists them. Each block has a caption and the words search matches: its caption and the labels of its rows.
- **Classic** lists blocks per tab, in today's order, so Classic's panel is unchanged.
- **Lens** lists blocks per section:
  - Interface: Look, Size, Layout, Hands, Motion, Starting, Brush ring, Panels, View grid, Inspector, Panel places.
  - Camera: Orbit, Safe zone, Pan and zoom, Mouse.
  - Touch: Hold, Gestures (new, below), Palm and pen (new), then the Gesture map's hold rows and Shapes.
  - Pen: One finger's Touch strength, Pen on empty space, and Pen.
  - Dial: Wheel, plus Keep the dial in clean view, which moves out of Layout in Lens.
  - Performance: Statistics, Display without the frame rate.
  - Frame rate: the frame rate controls and Rest when idle.
  - Bars: Bars, Action bar and Pies.
  - Files: Autosave, Earlier saves, Undo history and Blender link.
  - Shortcuts: Keys.

### The sheet (Lens)

- About 780 by 540 points, centred under the top bar, with the same window behaviour as today: it moves, Esc closes it, and Done is the close button.
- The **side column** (190 points wide) has:
  - **Search settings**, a text field. While it holds text, a section shows only when one of its blocks matches, and the body shows only the matching blocks.
  - The sections as list rows, the current one tinted.
  - At the foot, **Reset this section** and **Reset all settings**. Reset all needs a second tap, as Reset everything does today.
- The **body** has the section's title with a close button, then its blocks in a scroll.
- On a window narrower than about 820 points, the sheet falls back to today's panel, with the sections as a select at its top.

### Resets

- `settings_reset(app, tab)` stays for Classic's tabs.
- `section_reset(app, section)` resets the blocks of one section. Each block gets a reset proc made from the lines of `settings_reset` that set its values, so Classic's tab reset becomes the resets of its blocks.

### Touch's new rows

- **GESTURES** is the mock's list: each row is a label on the left with a compact select on the right.
  - One finger or pen on the model: Sculpt or Turn the view (`finger_model`).
  - One finger on empty space: Orbit. This row only states the behaviour; it has nothing to change.
  - Two fingers: Pan, zoom and roll, Pan and zoom, or Pan only (`pinch_zoom`, `two_finger_pan` and `twist_roll` together).
  - Three fingers drag: Size and focal shift, or Off (`three_finger`).
  - Two-finger tap, Three-finger tap and Four-finger tap: the Gesture map's choices for those slots.
- The other Gesture map slots (the holds, the pen's side button and the one-finger tap) follow as the same rows. The switches the list leaves out stay under the list: Zoom about the fingers, Lift one of two fingers to turn, and Double tap.
- **PALM AND PEN**:
  - Ignore touches while the pen is near (`palm_rejection`).
  - Finger can sculpt when no pen is used, a switch for `finger_model`. The mock shows it, and the same row with a select would mean the same thing, so the switch lives here and the GESTURES row reads from the same value.

### Tests

- Every block is in exactly one Lens section and in one Classic tab.
- Search for "hold" finds Touch only. Search for "autosave" finds Files.
- Reset this section on Touch puts Touch's values back and leaves Camera's alone.
- Touch scenario `lens_settings_sections_and_search`: open Settings, tap Touch, type "pal", and check that the section is Touch and one block shows.

## 11b: Export (`export2`)

- New `Export_Format`: Scene, OBJ, PLY, STL, glTF, USD, Screenshot, Turntable, Print. Menu > Export..., the top bar's Export, and Ctrl+E open the sheet on the format used last.
- The left column has one row per format with its icon and suffix.
- The right side shows the chosen format's options. They come from settings the app already has:
  - The mesh formats show the selected object, its triangles and the level that goes out.
  - Screenshot: Without background.
  - Turntable: Frames.
  - 3D print: the size, its unit and the three sides, as `kit_print` draws them.
  - Scene: Save a copy versus Save as.
- The mock's **Selected, Visible or All** objects, **Reduce to** and **Close holes** are new exporter features. The writers today take one object, so 11b shows "Selected object" with its name. Visible and All with Merge into one file come in a follow-up, once OBJ, PLY and STL can write several objects.
- The foot shows the file name the dialog will suggest and an estimate of its size. The estimate is the triangle count times the format's bytes per triangle: STL 50, OBJ and PLY from their vertex and face lines, glTF and USD binary.
- **Export** opens the save dialog with only that format's filter.
- Classic keeps its menus. The commands stay in Search.

## 11c: Home (`home2`)

- **Continue**: the newest Recent scene as a card about 540 by 360 points, with its picture large, its name, "Saved 2 min ago · 3.73M tris · 5 objects" from the scene's preview block, and Open. With no recent scene, the card offers the last autosave, or else a sphere.
- **Start new**: six tiles, 3 by 2, in the mock's order: Sphere, Head base (today's Head), Box, Voxel block, Plane and Empty scene.
  - Box and Plane use `primitive_mesh`. Voxel block makes a voxel object, and Empty scene makes no object.
  - Today's Bust, Figure, Hand and Creature move behind a "More starters" row, so nothing is lost.
- **Recent**: one row of pictures with their dates, then Autosaves as a link. Open... and Import... for every format the app reads sit at the row's right.
- Classic keeps its Home layout.

## 11d: Arrange and the dial (`custom2`)

- In Arrange, the top bar's workspace switcher becomes "Arranging Sculpt", Reset zone, Reset workspace, Save as new and Done. Today's head card goes; its Show chips move into the Library's Panels tab.
- Every zone draws its outline and a name tag: Off-hand, Dial, Shelf (with "page 1 of 4"), Panels and Rail (with its count). A tap on a zone picks it for Reset zone.
- **The dial as a zone**: in Arrange it drags to move and pinches to resize. Its sectors are chosen in the Library's **Dial** tab: Top, Right, Bottom and Left, each a select, then Size, Show names under icons, and Keep the dial in clean view.
- A sector is a modifier that holds or latches (Smooth, Invert, Mask or Hide), the brush pie, or any command, which runs on a tap. Modifier sectors keep today's hold and latch rules. A sector set to a command does not claim a finger as a modifier does.
- Dial sectors are part of the settings (`dial_sector`), not of a workspace layout, because they belong to the hand rather than the screen.
- 11d gets its own short design before it is built, because it touches the wheel's finger rules (`rail_finger_move`, `touch_event`).

## 11a as built

Screens: `screens/round2/pr11a-settings-touch.png` and `pr11a-settings-search.png`.

- **Blocks.** `settings_blocks.odin` holds every heading's group once (`Settings_Block`). Classic's tabs and Lens's sections are lists of `Settings_Entry`, each a block and its caption. Classic's panel draws exactly as before; I checked this with a dump.
- **Resets.** **Reset this section** sits at the end of the section's settings ("Reset Touch settings"), not at the side's foot. Ten section rows, the search and both resets need about 650 points at 44 points a row, which is more than the sheet's height. **Reset all settings** stays at the side's foot. The section list scrolls when a window is too short for it.
- **Two fingers** has four choices, adding Zoom and roll, plus "As set in Classic" when the three switches are in a mix that none of the four names.
- **One finger on empty space** is a row of text ("Turns the view"), because nothing changes it.
- **Reset all includes the layout**, which is Lens, so the touch scenario `settings_reset_everything` now closes the sheet with Esc instead of tapping Classic's Done.
- **Tests.** `lens_settings_test.odin` (every block has one place, search finds the section, a section reset leaves the other sections alone) and the touch scenario `lens_settings_sections_and_search`.

## 11b as built

Screens: `screens/round2/pr11b-export-stl.png` and `pr11b-export-print.png`.

- **The sheet** (`lens_export.odin`) is a popover 680 by 420 points under the top bar: the nine formats down the side, the chosen one's options, and a foot with the file name, the size estimate, Cancel and Export. Esc and the close button shut it, and the format is kept in the settings (`export_format`).
- **The Menu** has one Export... row (Ctrl+E). The rows it replaced (the Export submenu, Screenshot, Turntable video and 3D print) are gone from the list. Send to Blender moved to More, and Export workspace to Workspaces. Search still finds every command; their place reads "Menu · Export...".
- **Export** runs the format's own command. A mesh format calls `file_dialog_export`, which offers that format's filter alone and suggests the file beside the scene's.
- **The size** is the estimate from the design, shown to a tenth of a megabyte below ten (4.8 MB, not 4 MB).
- **Not built**: Selected, Visible or All objects, Reduce to and Close holes, as the design said. They wait for writers that take several objects.
- **Tests**: `lens_export_test.odin` and the touch scenario `lens_export_sheet_picks_a_format`.

## 11c as built

Screens: `screens/round2/pr11c-home-continue.png`, `pr11c-home-starts.png` and `pr11c-new-starts.png` (the four new starts after a tap).

- **The page** (`lens_home.odin`) sits under the same heading as Classic's, and the whole page scrolls. Its parts:
  - The Continue card, 47% of the width and 360 points tall.
  - Start new, as six tiles over a More starters row.
  - Recent and Autosaves, with Open... and Import OBJ, PLY, STL... at their right.
  - A window narrower than 760 points keeps Classic's page.
- **Continue** shows the newest Recent scene's picture, name, when it was saved, its vertices and its objects. A tap on the picture or on Open opens it. With work to lose, the first tap arms the card (`CONTINUE_ARMED`) and turns the button into Discard and open. If that scene is the one open, the button says Back to it. With no Recent scene the card offers the newest autosave (Recover), and with no autosave a sphere (Start).
- **Starts** live in one table, `NEW_SCENES`. Classic's six keep their numbers, and four new ones follow:
  - Cube.
  - Plane: a new `geom.Primitive`, a slab voxel remeshed from a flattened box.
  - Voxel block: `voxel.clay_fill_box`, through a shared `volume_fill` of a `Fill_Shape`.
  - Empty scene: no object at all.
  - These four reach Scene_Command `.New` through its existing `voxels` and `on` fields; no new command kind.
- **The tiles** are drawn in the kit: a lit ball, an isometric box, a slab, a grid of voxel squares, and a square with a plus.
- **The Cube tile** keeps the shape's name, Cube, rather than the mock's "Box", so the tile matches Add object and the object it makes.
- **Not built**: the mock's search field and settings button in Home's heading. Search and Settings stay one tap away once Home closes.
- **Tests**:
  - `new_scene_test.odin`: the starts' numbers and names, the voxel block and the empty scene.
  - `voxel/box_test.odin`: the box's volume, its flat sides, and serial against parallel.
  - The Plane in `primitives_test.odin`.
  - The touch scenario `lens_home_starts_and_continues`.
