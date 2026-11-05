# Paint layers on vertices and the skin (PT1-PT2): design

2026-11-03. Builds plan v2's PT1 and PT2 (https://claude.ai/artifact/CiCECeBofwvGhBwRpGEH84, notes/surface/plan-v2.md).
Needs review before code because it adds a sculptor undo kind, replaces the level block's paint format, grows the
GPU paint record and adds the skin's paint buffer.

## What exists when this is done
An object's paint is a stack of layers in the Layers card's new Paint tab (beside Sculpt). Each layer has a name, an
eye, an opacity, a blend (Mix, Multiply, Screen, Overlay, Add), channel dots (colour, roughness, metal; height shown
off, see below) and a target (Vertices, or Skin when the object has a detail skin). The Paint brush, every sculpting
brush with Colour on, Fill, Gradient, Clear, Blur and the eyedropper all work on the picked layer. The brush's Colour
section shows roughness and metal values beside the swatch whenever the picked layer has those dots on, and one stroke
lays all enabled channels. Every view (Clay, Material, Rendered, Full render, exports, thumbnails) reads the same
composite; MatCaps show colour only. Paint layers survive Remesh, Decimate, Quad Remesh in place, Mirror and weld,
Slice and booleans, projected onto the new surface in the same undo step as the rebuild.

## Data (package sculpt, `paint_layers.odin`)

    Paint_Channel :: enum u8 {Color, Roughness, Metal, Height}
    Paint_Blend   :: enum u8 {Mix, Multiply, Screen, Overlay, Add}
    Paint_Target  :: enum u8 {Vertices, Skin}            // Texels arrives with PT3
    Material_Paint :: [4]u8                              // roughness, its coverage, metal, its coverage

    Paint_Layer :: struct {
        id:       u32,          // stable through moves, for undo steps (Undo_Step.paint_layer)
        name:     [32]u8,
        blend:    Paint_Blend,
        target:   Paint_Target,
        channels: bit_set[Paint_Channel; u8],
        visible:  bool,
        opacity:  f32,
        color:    []Color,          // per vertex (or per skin sample); nil until painted, and nil while picked (it is s.color then)
        material: []Material_Paint, // nil until roughness or metal is first painted
        nodes:    []bool,           // per node: the layer has coverage there (what an opacity change recomposites)
    }
    Paint_Layers :: struct {
        list:     [dynamic]Paint_Layer,
        picked:   int,     // index; its colours are Sculptor.color meanwhile, as a layer mask is Sculptor.mask
        next_id:  u32,
        named:    int,
        shown:    []Color,          // the composite, nil while the stack is plain (one visible Mix layer at full opacity, colour only)
        shown_material: []Material_Paint, // nil while nothing has roughness or metal
    }

- Polypaint is the picked layer. `Sculptor.color` keeps its meaning for every writer (paint_dab, the channel dab, Blur,
  Fill/Clear/Gradient, project, levels carry, file, undo), so none of them changes. The first paint on an object with
  an empty stack makes "Paint 1" (color_ensure). Picking another layer swaps arrays, as `sculptor_layer_mask_pick` does;
  it is not an undo step.
- Readers that mean "what shows" go through `sculptor_paint_shown(s) -> ([]Color, []Material_Paint)`: the GPU upload,
  OBJ/PLY/glTF/USD export, thumbnails, the eyedropper (`sculptor_color_at`), Mask by colour, Remesh/Decimate/Quad
  Remesh's colour carry, the Blender link and Send. With a plain stack it returns `s.color` itself: no copy, no cost.
- Per-channel coverage. Colour keeps its coverage byte; roughness and metal each carry their own, so turning a dot off
  and painting leaves that channel untouched, and erasing (Ctrl) takes coverage off every enabled channel.
- Height. On Vertices the positions are the height and on Skin the skin's heights are: a second height store would be
  twin data (sm-design 2: one store). Nomad's vertex paint has colour, roughness and metal for the same reason. The
  height dot shows off with the note "Height is the sculpt itself here: sculpt it, or record a sculpt layer"; it turns
  on with the Texels target (PT3), where a height map is a real store. This departs from the plan's "16-bit height" on
  Vertices; the plan's 16-bit roughness becomes 8-bit plus a dithered composite (the plan's own banding fix), since
  the GPU record has 8 bits for it anyway.
- Composite (CPU, `paint_composite`): bottom up per vertex in f32, each layer's channels blended by coverage ×
  opacity with its blend mode, colour then quantised with a 4×4 ordered dither keyed on the vertex number
  (deterministic, the same serial and parallel). Runs in `sculptor_flush` over the ranges it reports (painting,
  sculpting and mask changes alike), and over a layer's `nodes` when its opacity, blend, eye or dots change (those
  nodes are marked `.Paint` stale, so the upload path is the one strokes use). A whole recomposite (layer added,
  removed, moved, merged) is a parallel pass over the vertices.

## Undo (sculptor steps, app History kind `.Paint`)
- `Undo_Step.paint_layer: u32`: the id of the layer whose colours (and `Saved_Node.materials`, new, saved beside
  `colors` through the same `color_saved` stamps) the step holds; undo writes them into that layer wherever it is
  (Sculptor.color when picked, else its own arrays), as `mask_layer` finds a layer's mask.
- `Undo_Step.paint_op: Paint_Op`, one of: add/remove (the step holds the removed layer, as Layer_Op), set (old opacity,
  blend, eye, dots, target, name: swapped, its own inverse; a slider drag is one step as sculptor_layer_set does), move
  (a swap), stack (Merge down and Merge all: the whole list moved into the step, as Layer_Stack). All swaps in place,
  so undo and redo are the same proc (`paint_step_swap`), and `step_move` re-counts bytes.
- No new app History kind: the app records these as `.Paint` with names ("New paint layer", "Paint layer opacity",
  "Merge paint down"...). (The plan said `.Paint_Layer`; one more kind buys nothing, since the History panel names
  steps by text and the sculptor step does the work.)

## Brush (app and sculpt)
- `Brush` gains `roughness, metal: u8`; `Brush_Settings` gains `roughness, metal: f32` (saved with brush presets and
  settings like colour). paint_dab writes each enabled channel of the picked layer with the same weight; Blur evens
  material too. The Colour section (kit_colors.odin) shows a Roughness and a Metal slider row beside the swatch only
  while the picked layer has those dots on, as Wafer's brush panel does; the eyedropper picks roughness and metal from
  the composite too.

## GPU (render)
- `Paint_Packed` grows from [2]u32 to [3]u32: x colour (as now), y group (low 16 bits as now), z roughness, its
  coverage, metal, its coverage. 8 → 12 bytes a vertex, only on meshes with paint or groups (the buffer is nil
  otherwise). mesh.vert, skin.vert and skin_tess.vert pass `material` as one more float4 varying; mesh_shading blends
  `surf.xy` (metal, roughness) toward the paint by its coverage when the item is physically based (`surf.y > 0`), and
  leaves Classic and MatCap shading colour only, said in the view readout's Shading line. render_trace (Full render)
  reads the same record, so Rendered and Full agree.
- Skin target (PT2): `Mesh_Buffers.skin_paint`, one [2]u32 per skin sample (composite colour, composite material),
  bound in skin.frag at set 2 binding 4 and read at the three samples `skin_grid_corners` already finds for the normal
  (one more fetch each), and in skin_tess.vert per grid vertex. Nil, and a 1-element dummy bound, while no layer
  targets the skin.

## File (no compatibility before release)
The level block's LEVELS_PAINT part (current level, canon order) is replaced: groups as now, then the paint stack:
u32 count, u32 picked, u32 next_id, u32 named; per layer name[32], id, blend u8, target u8, channels u8, visible u8,
opacity f32, then u8 has-colour + colours, u8 has-material + materials, each per vertex in canon order (Vertices) or
per sample in skin_file's order (Skin). `nodes` and the composite are rebuilt on read. SCENE_VERSION 37 → 38. The plan
named it a LAYR section; it lives in the level block because paint is per level (polypaint already is) and its
vertex order is the level's canon order, which only the level block knows.

## Levels, HD, dynamic topology
- A level change carries the whole stack (every layer's arrays by levels_carry_color's rule, materials alike), and
  only when painted since (color_edited), as today.
- HD and dynamic topology refuse paint as today (paint_allowed). Turning dynamic topology on still drops paint: its
  splits and collapses would have to carry every layer per edit; the confirm already shown for dynamic topology says
  "paint layers are dropped". (The plan wished them kept; that needs paint carried through dyntopo's edits, not in
  PT1-PT2.)

## Across a rebuild (PT2b)
`levels_take_layered` keeps the shown level when it has paint layers too, and `levels_carry_layers` →
`sculptor_layers_project` carries each paint layer through the same Surface_Map as sculpt layers and their masks
(nearest old triangle, corner weights): colours and materials blended by weight, coverage faded by the map's reach
weight. One undo step with the rebuild (the existing swap entry). Skin layers onto a rebuilt object with a skin follow
the skin carry's sample map (skin_carry); onto one without, they become Vertices layers (sampled at the vertices), with
a note.

## Skin target (PT2a)
A layer's target is chosen when it is made (the chip shows Skin only when the object has a skin) and changed later
by "Move to Vertices / Skin", one undo step that resamples (Skin → Vertices: each vertex's sample; Vertices → Skin:
each sample interpolated from its triangle's corners). Arrays are per skin sample (skin_sample numbering). A Skin
layer is painted by `skin_paint_dab` (the samples skin_dab visits, with the dab's falloff, mask and hiding read at the
sample's triangle, symmetry and alphas through the same Dab), undone per node through `Saved_Node.colors` over the
node's sample ranges (skin_node_ranges), as skin heights are. Where an object has any Skin layer the composite is per
sample, with Vertices layers sampled into it, so the stack's order holds across targets; the vertex record's colour
is then zero coverage and the skin buffer carries all of it. Refused above 16M samples with a note (plan). Bake to maps
through the UVs reuses the skin bake.

## Budgets (proven by)
- Paint frame at 10M with one layer: unchanged (1.0 ms; plain stack, no composite). With 4 layers: composite of the
  dab's nodes < 0.3 ms (exit stats `brush_ms`, `upload_kb`).
- Opacity drag of a layer covering 10% of a 10M mesh: composite + upload < 8 ms a frame (new stat `paint_composite_ms`).
- Memory: a layer is 4 bytes a vertex (+4 with roughness or metal): 80/160 MB at 20M; GPU +4 bytes a vertex (80 MB at
  20M) only on painted meshes. The stack refuses a layer that would pass 512 MB per object (plan).
- Skin paint: one more fetch per textured pixel; 1.5M-sample skin painted at the Paint frame's cost (skin dab stats).

## Compare
| Part | Taken from | Why it still holds | Avoided | Done better |
|---|---|---|---|---|
| Layer stack with blend, opacity, eye | Substance, Procreate, ArmorPaint | non-destructive paint is the norm | ZBrush/Blender: one flat colour per vertex, no layers | layers on 20M-vertex sculpts with no UVs |
| Channel dots + per-channel brush values | Wafer (channel set per layer), Nomad (colour/rough/metal on vertices) | one stroke lays a whole look | ZBrush MRGB's material index | continuous values per channel, per-channel coverage |
| Polypaint = picked layer | ours | one store, every tool keeps working | twin data for Sculpt and Surface | no migration, plain stack costs nothing |
| Height on Vertices/Skin | Nomad (none) | the geometry is the height | a second height store | height arrives with texels where it is real |
| CPU composite per dirty node, dithered | Wafer 1.4 dither | 8-bit layers band | 16-bit everywhere | per-node recomposite, nothing per frame |
| Skin target | Ptex (Mari), our detail skin | paint finer than the mesh with no UVs | Ptex files | shared-edge samples, no seams, bakes to maps |
| Carry across rebuilds | Nomad keeps layers through remesh | rebuilds are routine | Blender drops colour attributes on remesh | projection in the rebuild's undo step |

## PRs
1. PT1a: stack, pick, composite, undo, file, Paint tab (list, new, delete, eye, opacity, blend, move, merge down,
   rename), shown-paint readers switched. Tests: composite serial = parallel, undo of each op, file round trip,
   plain stack is zero-copy, a picked layer's undo after re-picking.
2. PT1b: roughness and metal: dots, brush values, Paint_Packed 12 bytes, shaders (all three backends' files), eyedropper.
3. PT2a: Skin target: skin arrays, skin_paint_dab, skin buffer and shader fetch, Move to, bake.
4. PT2b: carry across rebuilds (Vertices and Skin layers), README.

## Revisions after the architect's review (2026-11-03, supersede the sections above where they differ)
1. The stack's structure lives on `Levels.paint` (Paint_Stack: layers' id, name, target, channels, visible, opacity,
   picked id, next id, named), one for every level; each level's sculptor points at it (`Sculptor.paint_stack`) and
   keeps only arrays per layer id (`Sculptor.paint: [dynamic]Layer_Arrays{id, color, material}`, the picked id's
   colour being `Sculptor.color`, `Sculptor.paint_held` naming whose it is). A level change mirrors the stack: every
   layer's arrays are carried from the current level when anything was painted or the destination's ids differ, ids
   not in the stack are dropped, and the picked layer is swapped in. Structural steps are sculptor steps of the
   current level that swap the shared stack; the app already switches to an entry's level before undoing it, so steps
   come back in order.
2. "Anything shows" is `sculptor_paint_shows(s)`; `sculptor_has_color` keeps meaning the picked layer's array. The
   draw flag, thumbnails, rebuild, split/merge and the objects card switch to the former.
3. Readers of what shows also include 3D print export, Close Holes/repair, Split and Merge, Make Skin, Project's
   source, Edit cage's warning and the memory count. Until PT2b, a rebuild flattens the composite into one "Paint 1"
   layer on the new mesh (the carried colour today), with a note when layers were merged; Merge of two objects
   flattens both.
4. Adjust last stroke and the undo bounds read the step's layer (`Undo_Step.paint_layer`), never the live `s.color`.
5. `step_move` puts the picked colours back in their layer before swapping a structural step and re-picks by id after.
6. Skin layers' undo uses its own `Saved_Node.skin_colors` / `skin_materials` swapped by sample ranges as `heights`
   are; a Skin_Op step resamples (new skin) or turns Skin layers into Vertices layers (skin removed) in the same step.
7. Blend modes go to PT6 as the plan has them: PT1 layers are Mix with an opacity, which is exact over bare clay.
8. Roughness and metal get their own optional buffer (`Mesh_Buffers.paint_material`, one u32 a vertex: roughness,
   its coverage, metal, its coverage), bound with a one-element dummy when absent, so `Paint_Packed`, the trace's
   layout and the 8-byte uploads stay; groups-only meshes pay nothing. `options.w` says whether it holds anything.
- Composite only what was painted: a `paint_dirty` node list filled by paint dabs, commands, undo and carries
  (`Stale` keeps only the strongest kind); an opacity or eye drag scans once at its start for the nodes the layer
  covers. Plain to composited (and back) bumps the paint stamp. A single Mix layer at opacity 1 composites to its exact
  bytes (the dither stays inside ±0.47 of a step), tested.
- With Skin layers the vertex record still holds the composite at the vertices (the vertex samples), so Full render,
  exports and far LODs show the paint; the skinned fragment reads the finer skin composite instead.
- Turning dynamic topology on frees every layer's arrays, the composite and the stack.
