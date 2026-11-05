---
name: ui-direction-lens
description: 2026-10-27 UI redesign exploration result: three directions (Stage, Workbench, Lens), Lens chosen by Bolt 2026-10-27; links to mockups, report and Figma
metadata:
  type: project
  modified: 2026-10-27T18:50:48.981Z
---

Thread "Explore new UI direction in Figma" (2026-10-27), design only, no code.
- Mockups (HTML, Figma ran out of calls): https://claude.ai/artifact/HZ7t24kdzBsBZGps8tcar2 . Report doc: https://claude.ai/artifact/LT1ZgSsMuUtFFtd7tm1RZw . Figma design system only: see [[figma-access]].
- Directions: A Stage (canvas first, islands, sheets, PiP camera deck), B Workbench (Blender-like tiled editors + task tabs), C **Lens** (Bolt chose it 2026-10-27 19:12; score 32 vs 27 vs 22).
- Lens = 7 fixed zones (anchored top bar, left off-hand rail, right view rail, shelf, left column, right column, floating layer) + view grid of 1-4 panes from 6 presets. One Panel type with 3 presentations (docked, floating card, popover; plus minimised chip). One slot type = Bar_Slot (= Pie_Slot). Workspaces snapshot zones/grid/pane camera+pass; built-ins Focus, Sculpt (default), Inspect, Studio; amber dot when modified. Anchors that can't be removed: Menu, Search, Undo, Redo, workspace switcher. Pane camera colour dots; secondary panes refresh after each stroke; second pane = thumbnail window grown up.
- Tokens: frame #0D0F12, surface #161A1F, accent "Glaze" #5ED6C4, camera colours #A08CFF/#F3B54A/#FF86B9, Inter, targets 48.
- P0 order: panel model + two columns; workspaces; Arrange mode; pass switcher + Normals/Depth/Curvature/AO views + hold to peek; second pane. Significant/later: strokes in any pane, heavy passes (Studio/live AO/render mode are singletons on App) per pane.
- Toolbar thread stores bar slots under zone names (settings.txt `bar_count <zone> N`, `bar <zone> <slot> <Command_Name>`; zones right_rail, bottom_tools; dock keeps `dock ...` + `dock_count N`), landing in the PR after #207. Long press on rail/strip buttons keeps their own extras; slot popover opens in Customise bars mode.
- Mockup sources saved in /mnt/project-files/ui-direction/ (template.html + icons.js + img.js assemble into sculpt-directions.html; rast.py/load.py/batch.py render passes; ledger.json = Figma node ids). Renders came from /mnt/project-files/Female expression6.obj via a numba rasteriser.

**Why:** Bolt asked for an ambitious, non-ZBrush-clone direction before implementing. **How to apply:** Bolt picked Lens, so build it in the P0 order, one PR merged before the next. See [[ui-zbrush-gaplist]], [[best-of-all-worlds]].
- 2026-10-28 Bolt: "I want the interaction, panels, UI, layout" of the mock, not just the features. #210-#225 built logic + colours only; the layout is still ZBrush-iPad. Gap list + 9-PR order (mock layout default, old layout kept as "Classic"): /mnt/project-files/notes/lens/mock-layout-gaps.md; side by side screens/mock-vs-app.png; routed to the Lens build thread via coordinator.
