# Customisable bars, dock swipe, Remesh quick menu, Shading and Camera buttons

Bolt's feedback (2026-10-27, thread "Customise toolbars and add Remesh menu"):
press and hold Remesh gives a small menu; swiping the bottom bar moves to the next
section and the sections are fully customisable; the right shortcut bar gets its own
Shading and Camera icons and the user chooses which tools sit there.

## Best of each app
- Remesh quick menu: Nomad's voxel popup (resolution, a pick from the object's own
  density, one big Remesh button, small enough to stay over the bar); ZBrush for iPad's
  long press on DynaMesh (the menu opens over the button, the tap still remeshes at once);
  our own Rebuild section's checkerboard preview (shown while Density is held). Full
  options (Fewer, Quads) stay one tap away under "More options".
- Shading and Camera: ZBrush for iPad's right bar has a Persp button and a Draw/Render
  group; Nomad's top bar has separate Shading and Camera menus. We give each its own
  button that opens its own small menu (tap, not hold, since the button has no other job).
- Swipe between dock pages: Procreate and iPadOS home-screen paging (a sideways swipe
  turns the page and the dots follow; the tiles slide with the finger); a mouse uses the
  wheel over the dock or the dots.
- Customisation: iPadOS edit mode (one "Customise bars" mode, minus badges, a + tile,
  Done); Nomad's "any tool can be a shortcut"; ZBrush for iPad's long press on a dock
  slot to replace it (kept); our Search's "Put in a pie" becomes "Put on a bar" too, so
  any command can be put on a bar from where it is found.

## Model
- `Bar_Slot` (= `Pie_Slot`: a command and its argument) is what the right shortcut column
  and the bottom bar's tool strip hold; the dock's `Dock_Slot` gains `command`, so a dock
  slot holds a brush, a preset or any command.
- `Kit_State.shortcuts [SHORTCUTS_MAX]Bar_Slot` + count; `Kit_State.tools
  [TOOLS_MAX]Bar_Slot` + count; dock slots up to `DOCK_PAGES_MAX` pages, `dock_count`.
- Buttons that do more than run their command keep it through `bar_extra`: Gizmo, Remesh
  (quick menu), Dynamic topology, Retopologize, Subdivide, Live boolean, Studio render,
  Orthographic, Floor grid, Symmetry, Wireframe, Shading, Camera.
- Settings lines (written only when changed, whole): `shortcuts N`, `shortcut i <cmd>`,
  `bar_tools N`, `bar_tool i <cmd>`, `dock_count N`, `dock i command <cmd>`. Older builds
  skip the new keys; a `dock i command` line in an older build is skipped and the slot
  keeps its default.

## Edit mode (Customise bars)
- Entered from Settings > Interface, Search ("Customise bars"), and the dock slot menu.
- Every customisable slot shows a minus badge (remove), a tap opens the slot popover
  (Replace: the brush grid for the dock, "Choose a command" opens Search in choosing mode;
  Move earlier / Move later), and a + tile ends each bar. A Done pill at the top middle
  ends it; Reset bars puts the defaults back.
- While editing, the slots run nothing.
