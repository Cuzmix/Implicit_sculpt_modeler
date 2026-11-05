# Surface space: UV unwrap, texture paint and shader graph (plan)

Bolt asked 2026-11-01 for UV unwrapping, texturing and shaders, compared with other apps, with wow features and HTML mocks; the shader graph like three.js's (overlay with transparency, split or full screen) and mobile friendly; UVs referencing UV editors, mobile friendly. Plan only, no code yet.

Mock (live WebGL, five screens): https://claude.ai/artifact/GvRMYf6uCFT8KGXT2Twwep (source: notes/surface/surface-mock.html).

## What exists today (checked in the repo, 2026-11-01)

- Quad Remesh (AutoRemesher or built-in) makes UVs: planar charts within 55 degrees of a seed quad, packed in rows (`retopo`, `geom.Uv_Layout`); New UVs relays them. UVs live on the base level's quads (`Levels.faces`) and are dropped by Delete lower and dynamic topology.
- Bake maps: normal, displacement, base colour (polypaint over materials), ORM (traced occlusion), polygroup ID, and NAME.glb with the maps embedded.
- Object textures (`src/app/textures.odin`): base colour, ORM and normal maps per object, decoded on a thread, shown through the UVs (Shading: Clay, Maps, Normal, Checker), loadable from PNG/JPEG/etc., saved in the scene, one undo step each.
- Full render reads the maps; texture arrays give up to 64 textured objects under Vulkan with descriptor indexing, 3 elsewhere.
- Polypaint per vertex with Sculpt/Both/Paint channels, Colors card, polygroups with per-group materials, PBR presets and matcaps.
- Missing: editing UVs or seams, UVs on triangle sculpts, painting into textures, roughness/metal paint, layers of paint, any material graph.

## Where it lives

A fourth space, **Surface** (violet tint `#B99CFF`), beside Sculpt, Model and Render (`Space` enum in `spaces.odin`), with three shelf pages: **UV**, **Paint**, **Shade**. Polypaint stays in Sculpt; Surface's Paint writes layers. The UV pane and the graph are Lens pane kinds, so split views, Focus, workspaces and the mini view work as they do for viewports.

## Comparison (take, avoid, do better)

UVs: Blender (seams on edges, ABF/LSCM/min-stretch unwrap, live unwrap, pins, good packer; avoid edit-mode ceremony), ZBrush UV Master (one tap, control painting protect/attract, polygroups as islands, flatten preview; avoid no editor), 3D-Coat (UV room, auto seams, texel density; avoid density of UI), RizomUV (quality reference for stretch and packing; avoid separate app), Nomad/Substance (auto unwrap only).
Paint: Substance Painter (layers, fill layers, smart masks and materials; avoid baked-maps-first and desktop), Procreate (best touch painting; avoid colour-only), Nomad (vertex colour+rough+metal layers on a tablet; avoid resolution tied to mesh), ZBrush (Spotlight; colour only), 3D-Coat/Marmoset (smart materials from curvature/AO).
Shaders: Blender nodes (power; avoid graphs that don't export and mouse-only UI), three.js node editor (graph over the scene: Bolt's reference), Substance Designer (every node is a picture, exports anywhere), Unreal/Unity (per-node live previews; compile waits). ZBrush, Nomad, Procreate have no graph.

## Wow features

- W1 Peel: a slider morphs the model into its UV layout and back.
- W2 Seams that hide themselves: auto seams weighted by visibility (traced occlusion), cavities, underside, then polygroups and creases.
- W3 Masks from the sculpt, live: cavity, height, facing up, thickness, polygroups, sculpt mask, and the difference between two subdivision levels (exactly the detail sculpted on top of the form). No bake.
- W4 Paint now, UVs later: layers live on vertices of a 20M sculpt; when UVs arrive they move onto texels in one step through the existing bake.
- W5 Probe: press on the model, every node shows its value there.
- W6 Every graph exports: the graph's result is maps, so glTF, USD, Blender link, Full render and game engines see exactly the viewport.
- W7 The graph over the model: Overlay with backdrop slider, Split as a Lens pane, Full with the mini view, Hold to peek; Stack view as the phone default.
- W8 Material time-lapse: graph edits and paint strokes are History steps, so the existing timeline replays a material being made.

## Engineering

UV core (`geom` or a new pure package `uv`, no render/UI):
- UVs on any base mesh (triangles too) as per-corner UVs with seams as an edge bit set; subdivision levels interpolate UVs (Catmull-Clark face-varying, linear at seams).
- Auto seams: edge weights from visibility (sample the existing occlusion), curvature (crease), polygroup borders, user guide paint; charts grown by region growing then cut to disk topology.
- Flattener: LSCM (sparse conjugate gradient on the jobs pool, bit-identical serial/parallel) as start, then ARAP/SLIM-style local-global relax; per-island, so a seam stroke re-solves only the islands it touched (target < 15 ms for a 20k-face island).
- Packer: own raster/skyline packer with rotation steps and texel padding; target fill >= 70 % (today's rows give 70-80 % on spheres but rows waste on mixed sizes).
- Benchmark the own flattener+packer against xatlas (MIT, C++) on the remesh_check fixtures, as AutoRemesher was compared with the own engine; keep the winner or both behind an engine tab.
- Straighten for quad islands (grid from the quad structure, as Rectify/UV Squares).

Paint:
- Layer = channels (colour+coverage, roughness, metal, height, emission later) + blend + opacity + mask (generator or painted).
- Targets: Vertices (per-vertex arrays beside polypaint, SoA, through `apply_dab`-style dirty ranges, works on 20M) or Texels (sparse 128x128 tiles per channel, 16-bit for height, RGBA8 otherwise).
- Texel dabs on the GPU: a compute kernel takes the dab (position, radius in 3D, falloff, alpha) and the tile list whose surface bounds meet it, so strokes cross seams and keep symmetry; per-tile undo like the voxel per-brick undo; gutters dilated at stroke end.
- Composite on the GPU into the object's base/ORM/normal textures, which the viewport and Full render already read.
- Generators run from the high mesh (or level difference) into vertex or texel space; cached, recomputed when the sculpt changes.
- Budgets: 2048 channels on tablets (`TEXTURE_PREVIEW_SIDE` is 2048 on mobile), 4096 on desktop; a dab under 1 ms GPU on the M2 iPad.

Shader graph:
- Data: nodes (kind, params), links; saved per material; History steps per edit.
- Execution: every node kind is a fixed compute kernel over texels (or vertices) writing an image; the output node writes base colour, ORM and normal. No shader compiling on device (App Store safe, identical on Metal and Vulkan), everything exports. Re-run only nodes downstream of a change, at preview resolution while dragging, full on release.
- View-dependent effects (sheen, clearcoat, scattering, transmission) are material switches of the one BSDF, joining the render plan's stage 6.
- Views: Stack (rows = chains of Mix nodes with masks; the default on narrow screens), Graph (Overlay/Split/Full, backdrop slider, Hold to peek, socket targets 48 pt, two-tap wiring as well as drag, insert by tapping a wire), Probe, per-node eye preview on the model, node thumbnails.

Files: per-object UVs/seams in the `OBJ ` chunk's end or a new `UVS ` chunk; layers in a new `LAYR` chunk (only painted tiles, each compressed as QOI); graphs in `MATG`. Older apps step over new chunks; `SCENE_VERSION` unchanged.

Rules touched (designs needed before code, AGENTS section 2): new package (`uv`), new chunks, undo for UV edits and tiles (History), new GPU buffers and compute shaders, Surface space and pane kinds (sm-ui, sm-touch-testing), sm-store (no new permissions; content packs may carry looks).

## Build order (each stage a PR series, gate --changed per PR, full gate at the end)

- S1 UV core: UVs on any base mesh, seams, auto seams, flattener, packer, stretch view, Peel, read-only UV pane; xatlas comparison.
- S2 UV editing: seam pen/eraser on the model with live re-flatten, guide brush, UV pane select/move/pinch/twist, Pack, Straighten, pins, texel density, mirrored halves.
- S3 Paint layers on vertices: roughness/metal/height beside colour, layer stack, blend, fill layers, Surface space and pages.
- S4 Texture paint: sparse tiles, GPU dabs across seams, tile undo, gutters, paint in the UV pane, stencils, vertex-to-texel move.
- S5 Masks from the sculpt and looks built on them.
- S6 Shader graph: kernels, Stack view, Graph view with Overlay/Split/Full, previews, Probe.
- S7 Out: bake to files, glTF/USD with maps, texture sets per material, UDIM tiles, maps over the Blender link.

## Choices for Bolt (defaults in bold)

1. Where: **Surface space with UV/Paint/Shade pages** vs UV under Model and Paint/Shade under Render.
2. Graph execution: **into maps through fixed kernels** vs compiled live shaders (view-dependent nodes, but no export and Slang on device).
3. Flattener: **own in Odin, measured against xatlas**, keep the winner.

## Revision 2026-11-01 10:10: one split view for every pane (Bolt's idea)

Bolt asked whether the shader graph and UVs should use the existing split view, made more flexible like the graph's view types. Answer: yes. Mock https://claude.ai/artifact/GvRMYf6uCFT8KGXT2Twwep stays for the content; the arrangement moves to https://claude.ai/artifact/Rm5R6Yi89MiR6CG7MRfmxe (source notes/surface/split-view-mock.html), detailed in notes/surface/split-view-plan.md. The graph's own Overlay/Split/Full modes and the fixed UV panel are dropped: UVs, Graph, Stack and Texture become pane kinds of the split view, and new stages V1-V4 (pane kinds, floating see-through panes, shelf follows the pane, portrait/phone) come before S1.
