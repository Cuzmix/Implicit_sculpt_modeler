# Lens round 2: build plan (approved screens)

Bolt approved every screen in **Sculpt Screen Designs** on 2026-10-28 ("All looks good"):
https://claude.ai/artifact/AvrVn5LqUEbNVTt8x8ME7r. He also asked for two additions, which are now drawn on the Split views tab:
- Blender-style corner drag to split and join panes, plus the related pane gestures.
- Resizable panels.

This plan **replaces PRs 2-9 of `mock-layout-gaps.md`**. PR 1 there, the Lens top bar (#226), stays. The `Chrome {Lens, Classic}` switch also stays: everything below is Lens chrome only, and Classic remains as it is today.

## Where the exact design lives

- **Sources:** `/mnt/project-files/ui-direction/round2/`. `screens.js` holds every screen as a function `S.<id>`, with notes in `N2.<id>`. `helpers.js` and `body.html` are the rest; `python3 build.py` assembles them.
- **Coordinates:** points on a 1440×900 desktop or a 1366×1024 tablet.
- **Notes:** every screen's numbered notes are copied below under "Screen notes". They are the behaviour spec.
- **Tokens:** as #216 (THEME_LENS). The accent "Glaze" is #5ED6C4. Before merging a PR, compare its `--dump-screen` side by side with the matching screen.

## Rules that hold on every screen

1. **The viewport fills the window.** The top bar is see-through and everything else floats over the picture. In Lens, `panes_under_panels` is on.
2. **Off-hand side** (left for right-handed users) holds what you touch every few seconds:
   - the shortcut dial in the corner (Smooth top, Pie right, Invert bottom, Mask left; today's modifier wheel);
   - the vertical Size and Strength island above it.
3. **Pen side, upper half** holds the panel stack (Brush, Symmetry, Layers, Scene) and the view rail of 8 slots: View layout, Passes, Camera, Frame, Symmetry, Wireframe, Lights, Mini view.
4. **No controls in the pen-hand palm zone** (lower right). The stack stops above it. The mini view sits under the stack, out of the palm's way.
5. **The shelf floats at the bottom centre.** Its page names (Sculpt, Paint, Move, Curve) sit under the tiles and replace the old mode switch. On a tablet it shows 8 tiles and sits left of centre.
6. **Panels fade to 25%** while a stroke passes under them, and come back when the pen lifts.
7. **Clean view:** Tab or a four-finger tap hides all chrome. The dial stays unless the user turns that off.
8. **Frame** centres the model in the free area, not the whole window.
9. **Left-handed mode mirrors the whole layout.** The model stays where it is.
10. **Touch targets are 44 pt or more.** Hold delay is the app's setting (0.3 s).

## PR order (one PR merged before the next)

1. **Full-window viewport.**
   - The grid room becomes the whole window; the top bar becomes see-through.
   - Panels fade under strokes.
   - Clean view (Tab, four-finger tap; keep-dial setting).
   - Frame uses the free area.
   - Screens: `sculpt2`, `stroke2`, `clean2`.
2. **Off-hand island and dial, view rail, top-left chips, mini view.**
   - Vertical Size and Strength island.
   - The dial at the bottom left (`modifiers.odin` wheel).
   - Trim the view rail to the 8 slots. Keep them as registry bar slots, so Customise still works.
   - Camera, pass and object chips at the top left.
   - The second view as a mini view under the stack.
   - Left-handed mirror.
   - Screens: `sculpt2`, `reach`, `lefty`.
3. **Shelf.**
   - Floating tile strip with named pages, which replaces the paged tool strip in Lens.
   - Long press a tile for quick settings (Radius, Strength, Alpha, Lazy stroke, Pin as panel, All settings).
   - All (or B) opens the brush picker sheet with stroke-preview cards and the app's Brush_Category order.
   - Screens: `brushQuick`, `brushPick`.
4. **Panel stack and Brush panel.**
   - Brush, Symmetry, Layers and Scene panels with the Lens header: grip, chevron, icon, title, summary, float, more.
   - The Brush panel's ZBrush-style section list becomes collapsible groups.
   - Brush pie from the dial's Pie sector, Space or the pen's side button: 8 brushes, flick to pick.
   - Screens: `brushPanel`, `brushPie`, `sculpt2`.
5. **Resizable panels (new).**
   - Drag the stack's inner edge to set its width, 260 to 440 pt. A pill shows the width; double tap resets to 300.
   - Each docked panel has a bottom grip for its height. The content scrolls inside; drag past the header to collapse; double tap to fit.
   - Floating panels resize from any edge or corner with 44 pt targets, snapping to an 8 pt grid.
   - All sizes are saved per workspace in the layout text.
   - Settings › Interface › Scale for all chrome at once. Extend the existing UI scale if there is one.
   - Mirrors in left-handed mode.
   - Screen: `resize2`.
6. **Split views chrome.**
   - Each pane gets its head chips (camera with colour dot, pass, link, maximise).
   - Dividers have a finger grip: double tap evens out; dragging to the window edge closes a pane.
   - The View layout popover offers 6 presets, a "New panes start as" segment and toggles.
   - With 2 or more panes the panel stack collapses to a tab strip beside the rail.
   - Proportion guides from #219.
   - Screen: `split2`.
7. **Corner drag and pane gestures (new; Blender areas plus 4.3 area docking).**
   - **Layout model:** replace `Grid_Preset` with a split tree of at most 4 leaves. Presets become trees. Old `grid` layout lines and workspace files still read, mapped to the matching tree.
   - **Corner handles:** every pane corner gets a rounded handle. Handles are always visible on touch and appear on hover with a mouse. Their hit area is 44 pt. They sit at the visible corner, under the see-through top bar and beside the rails, and fade while sculpting.
   - **Split:** drag from a corner inward. Sideways splits into left and right; up or down splits into top and bottom.
     - A live line and a share pill ("Split · 43 / 57") follow the finger; Ctrl snaps to ½, ⅓ and ¼.
     - The new pane copies the camera and pass it was cut from.
     - A fifth pane is refused with a shake.
   - **Join and cancel:** within the same gesture, carry on into the neighbour pane to join instead. The growing pane brightens and the closing one dims. Going back to the corner, Esc or a second finger cancels.
   - **Swap and move:** drag a pane by its camera chip.
     - Dropping on another pane's centre target swaps the two. This differs from Blender, which replaces, so no view is lost.
     - Dropping on one of that pane's 4 edge targets docks it there.
   - **Dividers:** Ctrl snaps; Shift moves dividers that line up together. Right-click or long press opens Split here, Join with…, Swap and Even out.
   - **Undo:** each pane gesture can be undone with Ctrl Z.
   - Screens: `split3`, `areaGest`.
8. **Focus, Menu and Search.**
   - Focus tablet islands.
   - The Menu list with the Recent submenu.
   - Search results showing where each item lives, with "Put on a bar".
   - Screens: `focus2`, `menu2`, `search2`.
9. **Scene, Layers and tool palettes.**
   - Outliner rows with thumbnails, eye and lock, plus selection sets.
   - Layers with recording and Add/Replace.
   - Tools panel tabs Mask, Visibility, Geometry and Deform, with the mask context bar.
   - Screens: `scene2`, `tools2`, `geo2`.
10. **Inspect and Studio.**
    - The pass popover with groups and shortcuts; wipe compare; hold to peek.
    - Light markers in the scene with aim handles.
    - Lights, Material and Environment panels; a render mini view.
    - Screens: `inspect2`, `studio2`.
11. **Arrange, Home, Export and Settings.**
    - Arrange zones, including the dial as a zone with its 4 sectors chosen in the Library's Dial tab.
    - The Home screen: Continue, Start new, Recent.
    - A single Export sheet for every format.
    - Settings with the Touch section.
    - Screens: `custom2`, `home2`, `export2`, `settings2`.

Everything awaits Bolt's Windows and tablet try, as before.

## Screen notes

### Sculpt (default) (`sculpt2`) — desktop 1440×900 · viewport fills the window, everything floats

1. **See-through top bar**: Menu, file, Undo and Redo on the left; the workspace switcher in the middle; Search, History and Settings on the right. The model shows through it.
2. **View chips** float at the top left: camera, pass, link and maximise, and under them the object chip with its counts (tap for the Scene panel). This keeps the app's "object and vertices" corner, made tappable.
3. **Size and Strength** sit on the left edge, under the off-hand thumb, as tall sliders you can drag without looking.
4. **The shortcut dial**, unchanged from the app: hold Smooth, Invert or Mask while you stroke, or tap to latch; the right sector opens the brush pie. It can be moved, resized and turned in Settings, as today.
5. **Panels float** in a stack on the right and stop well above the bottom corner. Each one collapses to its header with a summary, docks, or pulls off as a free card.
6. **View rail**: eight one-tap view tools (layout, passes, camera, frame, symmetry, wireframe, lights, mini view). It is a customisable bar like the others.
7. **Mini view**: a second camera (Front, silhouette) in the corner. Tap to swap it with the main view, or drag it out into a split.
8. **Shelf**: ten brushes and All, floating at the bottom centre where the pen reaches without crossing the model. Its pages (Sculpt, Paint, Move, Curve) replace the old mode switch.

### Mid-stroke under a panel (`stroke2`) — the panel fades while the pen passes under it

1. **Panels fade to a quarter** while the pen is down and its path crosses them, then come back when it lifts. The stroke keeps going under them: a panel never steals a stroke that started on the model.
2. **Smooth held on the dial** lights its sector, so you can see which modifier the thumb is holding.
3. **Chips and the object line dim too** if the stroke passes them. Nothing reacts to a palm or a stroke that started elsewhere.

### Clean view (`clean2`) — Tab or a four-finger tap hides all chrome; the dial stays unless you turn it off

1. **Clean view** keeps only the dial, so you can still smooth and mask while judging the form. A setting turns the dial off here too.

### Brush panel (`brushPanel`) — every setting, in one panel with groups

1. **Brush card**: a preview of what the brush does, its name and pack, an amber dot when you have changed it, star for favourites, and the preset menu (save, save as new, revert to the pack).
2. **Radius and Strength** are always on top. They are the same values as the Size and Strength sliders on the left edge, so either hand can change them.
3. **Groups, not a second sidebar.** The app's ZBrush-style list (Stroke, Falloff, Alpha, Pen, Options, Recorder) becomes collapsible groups inside one panel. A closed group still shows its setting ("Dots · lazy 0.30").
4. **Falloff and Alpha** as tap-to-pick rows; the curve editor and the full alpha library open from the group's header.
5. **Pen and Surface** collapsed by default: pressure and tilt; Sculpt, Both or Colour; front faces only, lock plane, connected only, dynamic detail.

### Quick settings (`brushQuick`) — long press a shelf tile

1. **Long press a shelf tile** (0.3 s, the app's hold delay) for its quick settings, anchored above the tile so the hand never covers it. Release on a value to keep editing; a tap on the model closes it.
2. **A tap just picks the brush**, as today. Long press is for settings, never for picking.
3. **Pin as panel** turns the same content into a docked Brush panel; **All settings** opens the full Brush panel.

### Brush picker (`brushPick`) — All on the shelf, or B

1. **Categories** in the app's own order (Recent, Favorites, All, then by what a brush does), your presets and each installed pack.
2. **Search and the shelf page** filter the grid; Import takes ZBrush, Nomad and our own brush files as the content packs do today.
3. **Every card shows its stroke** on clay, the way Procreate's library does, so you choose by result instead of by name. Star marks favourites.
4. **Opens from All** on the shelf (or B) as a large sheet above it; the shelf stays visible so you can drag a card straight onto it.

### Brush pie (`brushPie`) — the dial's Pie sector, Space, or the pen's side button

1. **The dial's Pie sector** (or Space, or the pen's side button) opens the brush pie where the pen is.
2. **Eight brushes** you choose (drag from the picker), placed by direction so the hand learns them: a flick toward Crease picks it without reading.
3. **Flick and lift** picks; holding still on a wedge shows that brush's quick settings, so the pie is a fast path to both.

### Focus (`focus2`) — tablet 1366×1024

1. **Menu, Undo, Redo** in one island. Two- and three-finger taps still undo and redo.
2. **Workspace and symmetry**: the two things you check most while sculpting. Tap Focus to switch back to Sculpt.
3. **Search, layout, passes, history**: one tap away, even with every panel hidden.
4. **Off-hand set**: Size, Strength and the dial, exactly as in Sculpt, so muscle memory carries over.
5. **Brush strip**: seven favourites and All, ending before the palm zone. Long press for quick settings; swipe for the other pages.

### Menu (`menu2`) — Menu button, top left

1. **One menu for everything rare**: files, export, video, print, workspaces, customise, settings and help. Home moves in here from the top bar. Every row shows its shortcut, so the menu teaches the keys.
2. **Submenus open sideways** on a tap or hover, with thumbnails coming in the Home screen rather than here.

### Search (`search2`) — Ctrl K or the field in the top bar

1. **Search finds everything**: commands, brushes, panels, settings, recent files. Ctrl K, or the field in the top bar.
2. **Every result says where it lives** ("Tools › Mask"), so search also teaches the layout. Tab opens that place instead of running the command.
3. **Put on a bar** from any result: the quickest way to customise without opening Arrange.

### Scene and Layers panels (`scene2`) — both opened, Brush collapsed

1. **Objects with thumbnails** (ZBrush's subtools, Nomad's scene list): eye to hide, lock to protect, tap to select, drag to reorder or parent. A filter appears past ten objects.
2. **Long press an object** for its actions: show only, duplicate, merge, split, boolean, remesh, mirror, delete.
3. **Selection sets** keep groups of objects you pick often.
4. **Layers of the selected object**: strength slider on the active one, a red dot while it records, Add or Replace for new layers. Locked Base cannot be sculpted by accident.

### Tools · Mask (`tools2`) — with the mask context bar

1. **One Tools panel, four tabs**: Mask, Visibility, Geometry, Deform. They replace the ZBrush-style palettes; every button already exists as a command.
2. **Big labelled buttons** with their shortcut, sized for a finger.
3. **Context bar**: when a mask exists, its most-used actions float above the shelf, so you rarely open the panel at all. The same happens for hidden parts (Show all, Invert, Delete hidden).

### Tools · Geometry (`geo2`) — remesh, subdivision, repair

1. **Remesh** with Half, Same or Double and a density slider, the same choices as the Remesh quick menu on the rail.
2. **Subdivision levels** as numbered chips you tap to step between, with Divide to add one. Dynamic topology sits beside them because you choose one way of adding detail or the other.
3. **Modify topology**: the mesh repair tools (Close holes, Delete hidden, Weld, Check, Fix, Delete half).

### One + two (`split2`) — perspective beside Front and Side ortho

1. **Panes fill the window** edge to edge, and the chrome floats over them, as in the single view. The off-hand set and the dial stay with the main pane; the shelf centres under it.
2. **Divider** with a grip you can grab with a finger; drag to resize, double tap to even out, drag to the edge to close a pane.
3. **Layout picker** from the view rail: six presets in one tap. For anything else, drag from a pane corner (next shot).
4. **Panels shrink to a tab strip** beside the rail so they don't cover the second and third panes; tap a tab to open that panel as a card.
5. **Proportion guides** run across both ortho panes at the same model heights; drag one to move it everywhere.

### Drag from a corner (`split3`) — split a pane, Blender style

1. **Drag from a corner** of any pane to split it, as in Blender. Every pane corner has a small rounded handle: always shown on touch, shown on hover with a mouse. The hit area is 44 pt so a finger finds it.
2. **The split follows your finger**. The direction you drag picks the cut: sideways cuts it into left and right, up or down into top and bottom. The pill shows the share, and Ctrl snaps to ½, ⅓ and ¼.
3. **One gesture, three outcomes**: lift to split, go back to the corner to cancel, or keep going into the next pane to join the two instead. Esc or a second finger also cancels.
4. **Handles sit where the pane is visible**: under the see-through top bar and beside the rails, never hidden behind chrome. They fade while you sculpt, so a stroke that starts near a corner stays a stroke.
5. **The new pane copies** the camera and pass it was cut from, so a split never starts blank. Up to four panes; a fifth split is refused with a short shake.

### Pane gestures (`areaGest`) — split, join, swap, move, resize

1. **From Blender**: corner drag to split and join, drag a pane to dock it on another pane’s edge, Ctrl to snap and Shift to move lined-up dividers.
2. **Changed for a sculpting app**: dropping on a pane’s middle swaps the two instead of replacing one, so no view is lost by accident. Each gesture can be undone with Ctrl Z, and the layout picker still gives the six presets in one tap.
3. **Touch**: corner handles stay visible, targets are 44 pt, and a second finger cancels. Right-click a divider (or long press it) for Split here, Join with…, Swap and Even out.

### Resize panels (`resize2`) — stack width, panel height, floating cards

1. **Drag the inner edge of the panel stack** to make it wider or narrower (260 to 440 pt). The pill shows the width; the dashed line is where it started. Double tap the edge to go back to 300 pt. Left-handed mode puts the edge on the other side.
2. **Drag a panel’s bottom grip** to set its height; the content scrolls inside when it is shorter than its contents. Drag it up past the header to collapse; double tap to fit the contents.
3. **Floating panels resize from any edge or corner**, with 44 pt touch targets. Sizes snap to an 8 pt grid and are saved with the workspace, so Sculpt and Studio can keep different widths.
4. **Everything at once**: Settings › Interface › Scale makes all chrome bigger or smaller, for a 13 inch tablet or a 32 inch monitor. The dial size is its own setting in Customise.

### Inspect workspace (`inspect2`) — four linked and unlinked panes

1. **Wipe compare** inside one pane: drag the handle to sweep Studio against Normals.
2. **Pass popover** from any pane's pass chip, recent passes on top and a one-letter key for each. Holding the chip peeks at the last pass.
3. **An unlinked close-up** (violet) watches the eye's wireframe while the linked panes (teal) turn together.
4. **Inspect hides the shelf and sliders** because you are looking, not sculpting; the dial stays so you can still mask or smooth a spot you find.

### Studio workspace (`studio2`) — lights, material, environment

1. **Lights live in the scene**: drag a marker to move it, the ring handle to aim it. The selected light shows its handle, as Marmoset and Blender do.
2. **Lights panel**: each light with its colour temperature and strength; the selected one opens for Intensity and Size.
3. **Material presets as spheres** you tap, with Roughness under them; Environment collapses to its name and turn.
4. **Render preview** in the corner keeps refining while you light, so you judge the look without leaving Studio.

### Arrange mode (`custom2`) — with the dial sectors open

1. **Arrange** turns the workspace switcher into Reset zone, Reset workspace, Save as new and Done. Every zone shows its outline and name.
2. **The dial is a zone too**: move it, resize it and choose what each of its four sectors does.
3. **Library**: drag a command, brush, panel or view onto any bar; the Dial tab sets the sectors.
4. **Panels** reorder by their grip; drop one outside the stack and it floats.

### Home screen (`home2`) — desktop 1440×900

1. **Continue** is the biggest thing on the screen: most sessions pick up yesterday's file.
2. **Start new** from a sphere, the head base, a box, a voxel block, a plane or an empty scene.
3. **Recent files** with real thumbnails (the app already saves scene previews), plus Open and Import for every format the app reads.

### Export (`export2`) — one sheet for every format

1. **Every format in one sheet**: scene, meshes, images, video and 3D print, so Export is one place instead of five menu items.
2. **Options for the chosen format only**: here STL's objects, real-world size and triangle budget.
3. **The file name and its size** before you press Export.

### Settings · Touch (`settings2`) — gestures, hold delay, palm

1. **Sections down the side** with a search, the same window on desktop and tablet; Dial and Frame rate get their own sections.
2. **Every gesture is listed with what it does**, and each can be changed, so the touch model is never hidden.
3. **Palm and pen**: palm rejection and whether a finger sculpts, the settings that matter most on a tablet.

### Reach map (`reach`) — tablet 1366×1024 · right-handed

1. **Green: off-hand thumb.** Everything you touch every few seconds lives here. The dial sits in the corner where a resting hand already is.
2. **Red: pen-hand palm.** The palm and little finger rest on the lower right while you sculpt. Nothing pressable sits there, so the shelf is shorter on tablets and the mini view sits under the panels, above the palm.
3. **Teal: work area.** The panels and rails cover about a quarter of the screen, so Frame and Reset view aim the model at the middle of what is left.
4. **Pen side, upper half:** brush, layers and symmetry panels, which you change every few minutes. The pen reaches them without the hand crossing the model.

### Left-handed (`lefty`) — tablet 1366×1024 · the whole layout mirrors, the model stays put

(no notes)
