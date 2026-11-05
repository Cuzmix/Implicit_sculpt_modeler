# Brushes palette (ZBrush for iPad's Brushes palette)

Bolt, 2026-10-27: "make the brushes tab look like this zbrush for ipad brush tab" (screenshot: orc head, Brushes palette open).

Same popover semantics as today's brush browser (`k.browser`: the brush bar's Brushes and the dock's All brushes open it, a pick closes it, a press outside or Escape closes it), new layout:

| Part | From | Ours |
|---|---|---|
| Card look: dots, large centred "Brushes", sidebar toggle at the left, more at the right, under the top bar beside the brush bar | ZBrush | sidebar toggle hides the category column; Search (a field filtering by name, Nomad/Blender habit) and Close instead of ZBrush's filter |
| Current-brush card top left: big preview, name, its family under it, heart | ZBrush | tap = the brush's settings (long press on a tile does the same); heart = Favorites |
| Category list: Recent, Favorites, All, then categories | ZBrush | Clay, Crease, Smooth, Move, Cloth, Mask, Paint, Clip and hide, Curve and insert, History, My presets, then each content pack |
| Grid: 3 columns of large previews with names, alphabetical | ZBrush | preview = a shaded clay sphere with the brush's icon on it (we have no rendered brush previews yet) |
| A-Z index down the right, tap or drag to jump; letters with no brush dimmed | ZBrush / iOS index | scrubbing strip, one control |
| Recent (last 12 picked) and Favorites remembered | ZBrush | `brush_recent`, `brush_favorite` settings lines (built-in brushes, the library and your presets by name) |

Categories of our brushes: Clay = Draw, Clay, Layer, Inflate (+ Standard, Clay buildup, Blob); Crease = Crease, Pinch (+ Sharp crease, Slash); Smooth = Smooth, Flatten (+ Hard polish, Trim, Smooth stronger/valleys/peaks); Move = Grab, Snake hook (+ Move, Move connected, Move all depth); Cloth; Mask = Mask + mask rectangle/lasso; Paint; Clip and hide = hide rectangle/lasso, clip, slice, knife; Curve and insert = the Curve and Insert tools; History = Morph, History.

The dock's slot menu keeps the plain grid (kit_brush_grid).
