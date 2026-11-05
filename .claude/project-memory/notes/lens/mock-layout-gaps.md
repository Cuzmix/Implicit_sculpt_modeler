# Lens: make the app match the mockups (gap list)

> **Superseded 2026-10-28 by `round2-build-plan.md`** (PR 1 here, the Lens top bar #226, stays; PRs 2-9 are replaced).

Bolt, 2026-10-28: "See the workspace mock we designed, we picked option C. I want the interaction, panels, UI, layout etc." He means the screens in **Sculpt Workspace Directions** (https://claude.ai/artifact/HZ7t24kdzBsBZGps8tcar2), not only the features.

What #210-#225 built is the Lens *logic* (panel model, workspaces, Arrange, passes, view grid, camera links, wipe/guides, pane work, view windows) plus the Lens colours (#216). The *layout* is still the ZBrush-iPad one (compare `screens/lens-look-main.png` with the mock): Home/Menu/Save/Import/Export at top left, "Pass Shaded" in the top bar, a left bar of tool icons, a modifier wheel, a long right icon rail, the brush palette as a two-pane ZBrush window, and the bottom tool strip with pages. None of the mock's chrome below exists yet.

Exact sizes, positions and copy for every element are in the mock source: `/mnt/project-files/ui-direction/template.html` (builder functions `topbar`, `leftRail`, `rightRail`, `shelf`, `panel`, `phd`, `brushBody`, `layersBody`; screens `S.sculpt`, `S.focus`, `S.split`, `S.inspect`, `S.arrange`, `S.custom`). Coordinates are in points on a 1440x900 desktop or a 1366x1024 tablet. Tokens: Design system tab.

## Sculpt workspace (default, desktop) — the main gap

| Zone | Mock | App today |
|---|---|---|
| Top bar (48) | Left: Menu, file name over "Saved 2 min ago", divider, Undo, Redo. Centre: workspace switcher pill (Focus, Sculpt, Inspect, Studio, +) with the amber modified dot. Right: Search field "Search commands, brushes, panels  Ctrl K", History, Settings | Home, Menu, Save, Import, Export, "Sculpt" label; title centred; Pass chip, History, timer, Help, Settings. Undo/Redo live on the left bar |
| Off-hand rail (left, 60) | Vertical Size slider (value on top, SIZE at bottom), vertical Strength slider, separator, hold-to-use Smooth, Invert, Mask. Mirrors in left-handed mode | Left bar of tool icons + modifier wheel at bottom left |
| Main pane | Inset rounded pane. Header chips top left: camera chip (colour dot, "Persp 35 mm", chevron), pass chip ("Studio"), link + maximise group. Nav gizmo top right. Stat line bottom left ("Char.001 · 3.73M tris · 1.93M verts · GPU 0.6 ms"). Mini view bottom right inside the pane, labelled "Front · Silhouette" | Full-bleed viewport; object name + active vertices top left; head thumbnail top right outside the pane; pass in the top bar |
| Right column (300) | Stack of collapsible panels with the mock header (grip, chevron, icon, title, summary, float button, more): **Brush** (brush card with icon tile, name, pack, star; Radius; Strength; Falloff curve; Alpha thumbnails + "+"; Lazy stroke; Pen pressure drives size), **Symmetry** collapsed with X Y Z toggles as its summary, **Layers** (eye, name, value; locked Base; New layer), **Scene** collapsed with "5 objects · Char.001" | One floating Brush window with a ZBrush-style section list on the left (Brush, Preset, Stroke, Colour, Falloff, Alpha, Pen, Options, Stroke recorder, Object, Scene) |
| View rail (right, 48) | Eight slots: View layout, Passes, Camera, Frame, Symmetry, Wireframe, Lights, Mini view | About 15 icons (search, palettes, layers, AO, camera, lights, axes, symmetry, slice, crop, grid, ...) |
| Shelf (bottom, 56) | Left: mode segment (Sculpt, Paint, Move, Curve). Centre: ten brush tiles with labels + All. Right: object chip (cube, "Char.001 3.73M tris", chevron) | Floating tool strip with brushes, then tool icons, with page dots |

## Other workspaces and states

- **Focus (tablet):** three floating islands (Menu/Undo/Redo top left; centre pill "Focus ▾" + symmetry X; Search, Layout, Passes, History top right); off-hand island on the left (Size, Strength, Smooth, Invert, Mask); brush strip bottom centre (7 + All); long press a brush tile = popover (Radius, Strength, Alpha, Lazy stroke, "Pin as panel", "All settings"); gesture hint chip bottom right.
- **Split views:** View layout popover from the view rail (six preset thumbnails, "New panes start as" segment, three toggles); right column collapsed to a vertical tab strip; ortho panes with labelled proportion guides; active pane Glaze outline; divider grip.
- **Inspect:** no off-hand rail or shelf; 2x2 panes; pass popover from a pane's pass chip with Shading and Diagnostics groups and shortcut letters; Passes panel in the column with This pane / All panes, Shading and Geometry radio lists, Overlays toggles, Compare (Wipe with Normals/Wire/Render).
- **Arrange mode:** top bar becomes "Arranging Sculpt" + Reset zone, Reset workspace, Save as new, Done; dashed zone outlines with labels (Off-hand rail, Left column, Right column, "Right rail · 9 slots", "Shelf · page 1 of 3"); Library drawer (tabs Commands, Brushes, Panels, Views, Bars; search "Search 412 commands"; grouped command tiles with shortcuts); remove badges and + tiles; Glaze drop line; locks on anchors.
- **Custom ("Detail pass"):** left column with Scene/Layers as tabs of one panel (outliner rows with eye/lock, Selection sets) and a collapsed History; floating "My bar"; floating Lights card with pin and close; minimised History chip on the pane; render mini view.
- **Interactions tab:** the nine flows (switch workspace, maximise and restore pill, hold to peek, split from where you are, dock a floating panel, put any command on a bar, brush settings in context, recover from a broken layout, change one pane's pass) with their timings.

## Suggested PR order (each merged before the next)

1. Top bar as in the mock (pass chip leaves it; Home moves into Menu; Save/Import/Export into Menu).
2. Shelf: mode segment, brush tiles, object chip (replaces the paged tool strip in Sculpt; the dock stays for Focus/Classic).
3. Off-hand rail with vertical Size/Strength and hold-to-use modifiers; right view rail trimmed to the eight slots (all registry slots, so Customise bars still works).
4. Right column panels: split the brush palette into Brush, Symmetry, Layers, Scene panels with the mock header, summaries and collapse; Brush panel content as in the mock, "All settings" opening the full palette.
5. Pane chrome: inset pane, header chips (camera, pass, link, maximise), stat line, nav gizmo inside, mini view inside the pane.
6. Focus islands + brush long-press popover with Pin as panel.
7. Popovers: View layout picker, pass popover with groups and shortcuts; Passes panel layout for Inspect.
8. Arrange visuals: zone outlines and labels, Library drawer tabs and tiles, badges, drop line, locks.
9. Custom pieces: tab groups, minimised chip, floating bar.

Default: the mock layout becomes the default for every workspace; keep today's ZBrush-iPad layout as a "Classic" workspace (or a Look/Layout setting) so nothing is lost. Compare each PR's `--dump-screen` against the matching mock screen side by side before merging.
