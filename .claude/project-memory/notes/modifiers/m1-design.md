# M1: copies in the renderer (design)

Part of the Live stack plan (https://claude.ai/artifact/AsztZy5PHcrx6eSmmeyGNS), approved by Bolt 2026-11-05.

## Goal
An object's copies (Mirror, Array, Radial, Along a curve) are the same `Mesh_Buffers` drawn again under
another placing. A stroke costs what it costs today however many copies there are; the GPU pays the
triangles of each shown copy, culled per copy.

## Shape
- The app expands an object with copies into extra `render.Draw_Item`s that point at the same `mesh`, each
  with `model = transform * placing_k` and `copy = k` (1-based; 0 is the object itself). Every other
  consumer (shadow maps, the studio render's TLAS instances, damage boxes, the idle cache's key, passes,
  thumbnails) then works unchanged, because each copy is just an item with its own model.
- The one conflict: culling results live on `Mesh_Buffers` (`indirect`, `visible`, `lod_visible`,
  `draw_count`, `lod_draw_count`, `tess_*`, `cull.culled`). They move into a `Draw_State` struct;
  `Mesh_Buffers.draw` is the item's own and `Mesh_Buffers.copy_draws: [dynamic]Draw_State` holds copy k's
  at k-1 (grown on demand, released with the buffers). `prepare_draws` and `draw_item_triangles` read the
  item's state through `draw_state(item)`.
- Copies cull on the CPU (frustum and back-facing chunks under their own `model`; the simplified copies
  allowed, as the item's own). GPU culling and the skin's near grid stay the item's own (copy 0): a copy
  of a skinned item draws the mesh's triangles lit by the skin's normals, as far chunks already do.
- `Draw_Item.model` may now be a reflected similarity (det < 0). `draw_items` flips the front face for
  such an item through a new `gpu.set_front_face(pass, Front_Face)`: Vulkan `vkCmdSetFrontFace` (core in
  1.3, FRONT_FACE added to every graphics pipeline's dynamic states, set from the pipeline's own value at
  each bind), Metal `setFrontFacingWinding`, WebGPU a twin pipeline made on first use with the other
  winding. Normals already transform by `(float3x3)model`, which is right for a reflection. The shadow
  passes cull nothing, so they need no flip (checked in M1).
- No shader change in M1. The Mirror row's clip plane (M2) adds `float4 clip` to `Frame_Uniforms` and
  `SV_ClipDistance` (Vulkan `shaderClipDistance`, Metal `clip_distance`), a discard on the web.

## Budget and proof
- Stroke: unchanged (no CPU work per copy but culling, which runs on the pool: ~0.05 ms per copy at 2M).
- `Viewport_Stats` counts copies' triangles and draws like the item's own; exit stats gain `copies_drawn=`.
- A scripted run with `--copies-test=N` (debug flag, radial copies of the selected object) dumps a PNG; parity
  check unchanged with N = 0; smoke under validation with N = 12 (a reflected one among them).

## Not in M1
The Live stack data, card, picking and brushing through copies (M2, M3).

## After review (sm-architect, go with changes)
- `gpu.set_front_face(pass, flipped: bool)` is sticky pass state, XORed with each pipeline's own winding at
  every bind and reset at begin_render_pass: Vulkan FRONT_FACE dynamic on every graphics pipeline, set after
  each bind; Metal at bind; WebGPU a twin pipeline (other winding) made at creation for every pipeline that
  culls, picked at bind. Called per item in draw_items and in view_depth_draw (Live AO and studio depth cull).
- Draw_State covers indirect_ensure, gpu_cull_item/keep, skin_tess_split, draw_skinned_item; destroy
  releases copies' buffers. prepare_draws skips GPU culling and the skin grid for copies explicitly.
- The path render leaves copies out in PR 1 (shared placed meshes later); textured items' reflected copies
  draw untextured until the tangent sign is carried.
- The app copies every item made from the object (the HD window's too), with the same live, damage, chunks
  and hidden slices, and a matching froms entry.
