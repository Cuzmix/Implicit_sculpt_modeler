---
name: toolbar-svg-icons
description: Brush icons: glossy ball set in notes/icons/glossy, shipped in app #701 (assets/brush_icons, brush_icons.odin atlas)
metadata:
  type: project
  modified: 2026-11-05T16:20:58.358Z
---

2026-11-05 Bolt asked for the full brush list because he plans to generate proper SVG icons for the toolbar.
Inventory (as of odin-sculpt #693): /mnt/project-files/notes/icons/toolbar-brush-icons.md: 18 brushes, 5 tools, 2 mask shapes, 5 gestures (30 icons), 17 built-in presets that reuse their base brush's glyph, clashes listed (Draw=Sculpt tool, Snake hook=Curve tool, Model tool=All tile, Morph=History panel, Flatten=minus, Inflate=Record).

Facts: every icon is a Lucide font glyph (assets/fonts/Lucide.ttf, rune codepoints in BRUSHES, TOOL_ICONS, SHAPE_TOOL_ICONS, GESTURE_ICONS, ICON_* consts); drawn 20 pt on tiles, 18 toolbar, 16 rows, 26 Library. No SVG loader exists: taking Bolt's SVGs needs a custom icon font or an SVG path in src/ui (a build job, design first).

**How to apply:** when Bolt brings the SVGs, start from that file; decide font-vs-vector with him.

2026-11-05 style history: tried Lucide SVGs (svg/), gradient balls (svg-ball/, "AI-ish"), Lucide+colour (svg-duo/), badge (svg-badge/), variants A-D, matcap round tiles (matcap/), SDF renders (render3d/); Bolt finally picked his glossy reference sheet (grey matte ball + glossy coloured effect). Lesson: a circle above a mound reads as a person; check at 16 pt.
2026-11-05 18:30: Bolt "good enough, save files, do the rest": all 18 brushes rendered in glossy style; final set + ray2.py + glossy.js + README in /mnt/project-files/notes/icons/glossy/, zip notes/icons/brush-icons-glossy.zip. Bolt will fine-tune himself. Open: Trim ridge, shelf framing, in-app atlas (build job, design first).
2026-11-05: Bolt said replace the icons with these: merged #701. assets/brush_icons/*.png (96 px, cropped from glossy/), atlas in src/app/brush_icons.odin (KIT_BRUSH_ICONS_IMAGE), drawn via ui.picture_icon on shelf, dock tiles/buttons, pie editor row, radial pie. Shelf no longer shows stroke pictures (Library cards keep them). To change an icon: replace its PNG in assets/brush_icons.
