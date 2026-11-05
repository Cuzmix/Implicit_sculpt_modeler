# Round 2, PR 2: off-hand island, view rail, view chips, mini view (Lens)

Screens `sculpt2`, `reach` and `lefty` in `/mnt/project-files/ui-direction/round2/screens.js`. Lens chrome only; Classic keeps the brush bar, the readout, the two view columns and the thumbnail window as they are.

## What exists when done

- **Off-hand island** (replaces the brush bar in Lens, same zone `Brush_Bar`, so a workspace that hides the brush bar hides it):
  - Two tall sliders, Size then Strength (`ui.vslider`, a drag moves the value by how far the pointer moves, so a thumb drags without looking).
  - It sits on the off-hand edge, centred between the view chips and the dial, raised clear of the dial as the brush bar is.
  - A long press (or right-click) on either opens the Pen section beside it, as the brush bar's value buttons do.
  - What the brush bar also held lives elsewhere in Lens: brushes on the shelf's All, Stroke, Alpha and Material in the Brush panel, Add and Subtract on the dial's Invert, Undo and Redo in the top bar. Each is in Search as well.
- **The dial** stays the modifier wheel, unchanged.
- **View rail** (replaces the two view columns in Lens, same zone `View_Bar`):
  - A new customisable bar, `Bar_Which.View_Rail` (zone `view_rail` in settings.txt and workspace layouts), with 8 default slots:
    1. View layout: a new `View_Layout_Menu` command and popover with the view grid's presets, Render preview and a view window.
    2. Passes: a new `Pass_Menu` command, the pass list beside the rail.
    3. Camera: the Camera menu.
    4. Frame: Focus selected.
    5. Symmetry: X symmetry, the long press opens the axes.
    6. Wireframe.
    7. Lights: Show section Lights, opened as the bars' section popover beside the rail.
    8. Mini view: the Thumbnail command.
  - Customise bars rings its slots and ends it with a +, as on the other bars.
  - Above the 8 slots sits the tray's button (Palettes). The mock has none, as its panels collapse rather than close; it goes in PR 4 when the stack does that.
- **View chips** (replace the object readout in Lens, at the top-left corner under the top bar):
  - First row:
    - The camera chip: the main camera's dot, Persp or Ortho, and the lens in mm (a full-frame equivalent of the vertical field of view). A tap opens the Camera menu under it.
    - The pass chip: the existing chip (a tap opens the list, a hold peeks).
    - Clean view (maximise) as a small icon chip. The link chip waits for PR 6's panes, since one view has nothing to link.
  - Second row, the object chip: box icon, name, then "3.73M tris · 1.93M verts" plus level, HD or Dynamic when they apply, and a chevron.
    - A tap opens the tray on the Scene palette ("tap for the Scene panel").
    - A long press (or right-click) opens the object menu under it.
  - Each chip has a see-through frame fill, like the top bar's glass, with a 44-pt hit area round a 32-pt pill.
- **Navigation head** moves left of whatever stands at the top right (the tray or the rail), as in the mock.
- **Mini view** (the thumbnail window, in Lens):
  - Picture only, 168 × 200 (portrait, as the mock), at the pen side under the panels. Its bottom keeps clear of the dock and, on a tablet-sized window, of the palm corner.
  - On the picture, a chip names its camera and pass ("Front · Silhouette"). A tap on that chip shows the camera and pass selects and the Flip, Link and Close buttons under the picture; another tap hides them.
  - A tap on the picture swaps it with the main view: the main camera takes what the mini view shows and the mini view keeps the main view as a free camera, so a second tap swaps back.
  - A drag still turns it, as today.
  - Dragging it out into a split waits for PR 7's corner drags.
  - Moved by its grip or docked, it behaves as the thumbnail window does today.
  - It stays off by default: Mini view on the rail or Search turns it on, as the thumbnail did. A second picture costs a draw after every stroke.
- **Left-handed**: everything is anchored through the kit's mirror, so the island, chips and dial go right and the rail, stack, nav head and mini view go left. The model stays put, since the free area follows the chrome.

## Tests

- Unit (`bars_test.odin`):
  - the view rail's default is the 8 commands;
  - it saves and loads through the layout text like the other bars;
  - Classic never shows it.
- Touch scenarios (Lens):
  - the rail shows 8 slots (exit stats `view_rail=`);
  - a drag up the island's Size slider raises the brush size;
  - a tap on the camera chip opens the Camera menu;
  - a tap on the object chip opens the tray's Scene palette;
  - with the mini view on, a tap on its picture swaps the cameras (`camera_swaps=`);
  - left-handed puts the island on the right (`island_x`-style check through the dump or stats).
- Screenshots at 1440×900 against `sculpt2`, at 1366×1024 against `reach`, and left-handed against `lefty`.
