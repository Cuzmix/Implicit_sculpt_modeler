# Brushes and toolbar tools: what has which icon (odin-sculpt at #693, 2026-11-05)

## How icons work today
- Every icon is a glyph from the **Lucide icon font** (`assets/fonts/Lucide.ttf`), picked by codepoint (`rune`), drawn one colour and tinted by the theme. There is **no SVG loader** in the app yet: new SVGs need either a custom icon font built from them (keeping or replacing these codepoints) or an SVG/vector path in `src/ui`.
- Style to match: Lucide's 24×24 viewBox, 2 px stroke, round caps and joins, no fill.
- Sizes drawn: **20 pt** on a shelf/dock tile (`theme.icon_size + 2`, tile 64×58 pt, `ui.BRUSH_TILE`), **18 pt** toolbar icon buttons (`icon_size`), **16 pt** in rows and menus (`icon_small`), up to **26 pt** on Library cards. At 2× and 3× screens that is 40 to 78 px, so design at 24 and check it at 16.
- On the **shelf and the Library**, a brush shows a rendered picture of its own stroke on clay (`brush_previews.odin`) once made; the glyph shows until then, and always for Cloth and History, tools, mask shapes, gestures and commands. **Docks, rails, pies, the quick tile, menus and the palette always show the glyph.**
- Voxel objects reuse the mesh brushes (Draw/Clay/Layer = Add, Smooth, Flatten, Inflate, Mask): no separate icons.

## 1. Brushes (`sculpt.Brush_Kind`, table `BRUSHES` in `src/app/brushes.odin`)
Grouped by Library category (`BRUSH_CATEGORY_OF`, ZBrush's grouping).

| Category | Display name | Internal id | Current icon (Lucide) | Codepoint | Shared with |
|---|---|---|---|---|---|
| Clay | Draw | `Draw` | brush | e1d3 | **Sculpt tool** (`ICON_BRUSH`), fallback icon everywhere |
| Clay | Clay | `Clay` | chart-area | e4d8 | |
| Clay | Inflate | `Inflate` | circle-dot | e349 | **Record** button (`ICON_RECORD`) |
| Clay | Layer | `Layer` | panel-top | e43a | |
| Clay | Clay strips | `Clay_Strips` | align-justify | e040 | |
| Crease | Crease | `Crease` | slash | e522 | |
| Crease | Pinch | `Pinch` | shrink | e220 | |
| Smooth | Smooth | `Smooth` | waves | e283 | |
| Smooth | Flatten | `Flatten` | minus | e120 | **Minimise** window button, `ICON_MINUS` |
| Smooth | Trim dynamic | `Trim_Dynamic` | tent | e227 | |
| Move | Grab | `Grab` | hand | e1d7 | |
| Move | Snake hook | `Snake_Hook` | spline | e38f | **Curve tool** (`ICON_SPLINE`) |
| Move | Elastic | `Elastic` | stretch-horizontal | e27c | |
| Cloth | Cloth | `Cloth` | shirt | e1ca | |
| Mask | Mask | `Mask` | venetian-mask | e2aa | Mask card and history (on purpose) |
| Paint | Paint | `Paint` | paintbrush | e2e7 | `ICON_PAINTBRUSH` elsewhere |
| History | History | `History` | undo-dot | e456 | |
| History | Morph | `Morph` | history | e1f5 | **History panel** (`ICON_HISTORY`) |

## 2. Built-in presets (`BUILT_IN_PRESETS`, `src/app/builtin_presets.odin`)
**None has its own icon**: each shows its base brush's glyph (`preset_slot_icon`). Your presets and pack presets work the same way.

| Preset | Base brush |
|---|---|
| Standard | Draw |
| Clay buildup | Clay |
| Sharp crease, Slash, Hatch | Crease |
| Move, Move connected, Move all depth, Move topological | Grab |
| Hard polish, Trim, Fill, Scrape | Flatten |
| Blob | Inflate |
| Smooth stronger, Smooth valleys, Smooth peaks | Smooth |

## 3. Tools (`Tool` enum, `TOOL_ICONS` in `src/app/dock.odin`; Library category "Curve and insert")
| Display name | Internal id / command | Current icon | Codepoint | Shared with |
|---|---|---|---|---|
| Move (gizmo) | `Tool.Move` / `Tool_Move` | move-3d on bars (`ICON_GIZMO`); move in the Library | e2e5 / e125 | move = **Model action Move** |
| Sculpt | `Tool.Brush` / `Tool_Sculpt` | brush | e1d3 | **Draw** |
| Curve | `Tool.Curve` / `Tool_Curve` | spline | e38f | **Snake hook** |
| Insert | `Tool.Insert` / `Tool_Insert` | shapes | e4b8 | |
| Model | `Tool.Model` / `Tool_Model` | grid (`ICON_GRID`) | e105 | **All** tile on the shelf |

## 4. Mask shapes (`Mask_Shape_Kind`, `SHAPE_TOOL_ICONS`; category "Mask")
| Display name | Internal id | Current icon | Codepoint |
|---|---|---|---|
| Mask rectangle | `Rectangle` | square-dashed | e1cb |
| Mask lasso | `Lasso` | lasso | e1ce |

## 5. Hide and cut gestures (`Gesture_Tool`, `GESTURE_ICONS`; category "Clip and hide")
| Display name | Internal id | Current icon | Codepoint | Shared with |
|---|---|---|---|---|
| Hide rectangle | `Hide_Rectangle` | square-dashed-mouse-pointer | e50e | |
| Hide lasso | `Hide_Lasso` | lasso-select | e1cf | |
| Clip | `Clip` | crop | e0af | Reference image **Crop** |
| Slice | `Slice` | scissors-line-dashed | e4ee | |
| Knife | `Knife` | slice | e2f0 | **Model action Knife** |

## 6. The other tiles on a fresh install's Sculpt shelf pages (`SHELF_*` in `src/app/lens_shelf.odin`)
Pages: **Brushes** = Clay, Draw, Smooth, Inflate, Pinch, Crease, Grab, Flatten, Mask, Layer, Remesh, Dynamic topology. **Paint** = Paint, Mask, Smooth, Colours, Swap colours, Paint channel. **Move** = Grab, Snake hook, Cloth, Move tool, Smooth. **Curve** = Curve, Insert, Smooth. Plus the fixed **All** tile.

| Display name | Command id | Current icon | Codepoint | Shared with |
|---|---|---|---|---|
| All (brush picker) | `Brush_Picker` | grid | e105 | **Model tool** |
| Remesh | `Remesh` | globe (`ICON_REMESH`) | e0eb | |
| Dynamic topology | `Dyntopo_Toggle` | network (`ICON_DYNTOPO`) | e129 | |
| Colours | `Open_Card` Colours | palette (`ICON_COLOUR`) | e1dd | |
| Swap colours | `Swap_Colors` | arrow-left-right | e24a | |
| Paint channel | `Paint_Channel` | blend (`ICON_CHANNEL_BOTH`) | e5a1 | **Live boolean** (`ICON_BOOLEAN`) |

The Model page (27 model actions, 6 cage primitives) and the Render page have their own icon tables (`MODEL_ACTION_ICONS`, `PRIMITIVE_ICONS` in `src/app/model_tool.odin`); ask if you want those listed too.

## Clashes to fix with new icons
1. Draw = Sculpt tool (brush).
2. Snake hook = Curve tool (spline).
3. Model tool = All tile (grid).
4. Morph = History panel (history).
5. Flatten = Minimise button (minus): a plain dash, hard to read as a brush.
6. Inflate = Record button (circle-dot).
7. Knife gesture = Model action Knife (slice), Clip = reference Crop (crop).
8. Paint channel = Live boolean (blend).
9. All 17 built-in presets reuse their base brush's icon (Move ×4, Flatten ×4, Crease ×3, Smooth ×3).

**Needed for full coverage:** 18 brushes + 5 tools + 2 mask shapes + 5 gestures = 30 icons, plus optional per-preset icons (17) and the 6 shelf commands above.
