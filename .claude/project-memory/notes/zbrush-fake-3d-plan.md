# Can we "fake 3D" like ZBrush? Verdict and plan

_2026-10-15 · planning pass for the Odin sculpt app (branch `odin-sculpt`)_

## Verdict

**Dropping the real 3D mesh is not feasible for a sculpt app you can rotate, and it is not what ZBrush does when you sculpt.** ZBrush's 2.5D "pixol" canvas is real, but it is a painting/illustration mode: once a model is dropped to the canvas it is an image with depth, and you can no longer turn it. All ZBrush 3D sculpting ("Edit" mode) works on a real polygon mesh.

**The idea behind the question is feasible, though, and it is the right way to stand out:** keep the real mesh, but make every frame pay only for what changed and what is on screen, and make the stroke itself feel better than the competition. ZBrush's speed comes from exactly that kind of trick (subdivision levels, HD regions, a cached canvas), not from the absence of a mesh.

Our numbers say where the work is. Sculpting 10M verts already costs about 1.4 ms/frame on the CPU, so deforming the mesh is not the bottleneck. What is left is (1) drawing huge meshes every frame on the GPU, (2) memory and setup above ~25M verts per object, and (3) stroke feel, which today is basic.

## What ZBrush actually does

| Claim | Status |
|---|---|
| The canvas is made of **pixols**: each screen point stores colour, depth, material, orientation and lighting. A 3D model dropped to the canvas becomes 2.5D and stops being editable as 3D. | **Verified** (Maxon docs, Wikipedia) |
| 3D sculpting uses a real mesh with **subdivision levels** ("dynamic levels of resolution"): sculpt big forms low, detail high, changes propagate between levels. | **Verified** (Wikipedia, ZBrush docs) |
| **HD Geometry** lets a model go to roughly a billion polygons. You press **A** to enter HD sculpt mode, which works on a portion of the model at a time (users see a radial preview of the part that is loaded). | **Verified** at feature level (Maxon docs page summary, Novedge, ZBrushCentral). The exact loading rule is not public. |
| ZBrush is **CPU-based**: sculpting and the viewport do not depend on the GPU. | **Widely reported** (ZBrushCentral users, hardware vendors); I could not load Maxon's own requirements page to confirm the wording. |
| The 3D viewport is drawn by ZBrush's own software rasterizer into the same pixol-style buffer, and only the changed part of the screen is redrawn during a stroke. | **Inferred** from the CPU-only design and the pixol heritage. Not documented. |
| Internal data layout, threading, and how many triangles are really drawn during navigation. | **Not public.** Anything said about these is guesswork. |

So ZBrush "fakes" three things, all of which we can copy: it never shows more detail than the current level needs, it never holds the full HD mesh in an editable state, and (most likely) it never redraws the whole model while you are mid-stroke.

## The options, rated for this app

| Approach | What it is | Fit for us |
|---|---|---|
| **Stroke-time partial redraw** ("2.5D during the stroke") | The camera cannot move while you drag, so cache the frame's colour+depth once at stroke start and each frame redraw only the BVH nodes whose screen box overlaps the brush, scissored to that rectangle. | **Do first.** Frame cost scales with brush size, not mesh size. We already have the colour+depth cache for idle objects (PR #1), so this extends it to the active object. |
| **Stroke feel** | All input samples, pressure, smoothed path, lazy mouse, dabs spaced along the surface, low-latency present. | **Do first.** Cheap and it is what users actually feel. Details below. |
| **Multires (subdivision levels)** | Store a base mesh plus Catmull-Clark levels; sculpt at any level; propagate edits up and down as displacements. | **Core feature.** This is ZBrush's main trick for smooth big-form sculpting on a 10M+ model. Biggest single build item. |
| **HD-style regions** | Above the top regular level, keep the highest detail only for a region the user picks (or near the cursor); everything else is stored compactly (displacements on disk or packed) and drawn at the lower level. | **Later.** Needed for 100M+ totals. Builds on multires. |
| **Cluster LOD for navigation** | Pre-build simplified clusters per BVH node (Nanite-like); while orbiting, draw coarse clusters for far or tiny nodes. | **Later**, once Windows GPU numbers show orbiting is slow. Pure display trick, the sculpt data is untouched. |
| **Displacement/texture detail layer** | Fine detail lives in a vector-displacement texture over a lower mesh, applied in a shader. | **Not as the core.** Detail is limited by texture resolution and UV stretching, and big form changes stretch it. Useful later for export (normal/displacement maps). |
| **GPU compute sculpting** | Keep the mesh on the GPU and run dabs in compute shaders. | **Not now.** CPU dabs are 1.4 ms at 10M and the upload is ~1.8 MB/frame, so there is little to gain, and SDL_GPU compute adds a second code path. Revisit if per-object counts go well past 25M. |
| **Sparse voxel / SDF** (Adobe Medium style) | Narrow-band SDF in sparse 8x8x8 blocks, meshed for display. | **Keep for remesh only.** Great clay feel and no topology issues, but fine detail costs far more memory than a mesh. Matches our earlier decision: mesh primary, voxel remesh as a command. |
| **Pure 2.5D pixol canvas** | Sculpt depth into a screen image. | **No.** You cannot rotate the result, which is the main thing a sculpt app must do. |

## Plan

Each step ends with a bench table at 500k, 1M, 5M, 7M and 10M, as agreed. Timings from this container are CPU-only; GPU numbers need Bolt's Windows machine.

**Step A: stroke feel (small, do now).** What the code does today (`src/app/sculpt_tool.odin`): one mouse position per frame, dabs placed on a straight 3D line between the last and current hit (this cuts through curved surfaces), no pressure, dabs capped at 64 per frame, and the swapchain uses the default vsync present path.
1. Read every mouse/pen motion event with its timestamp instead of the last position per frame, and feed them all to the stroke.
2. Pen pressure from SDL3 pen events, with a pressure curve for size and strength.
3. Smooth the input path (Catmull-Rom through samples) and add a lazy-mouse/stabilizer setting like ZBrush's LazyMouse.
4. Space dabs along the surface: raycast each interpolated screen point instead of interpolating in 3D.
5. Lower input-to-photon latency: try MAILBOX/immediate present where supported and one frame in flight; measure with the existing `last_input_ns` latency stat.
6. Brush basics that set feel: falloff curves, area-plane normal for clay/flatten, front-face only, accumulate vs. limit-per-stroke.

**Step B: stroke-time partial redraw.** At stroke start, render the active object once to a cached colour+depth image (reuse the PR #1 path). Each stroke frame: copy the cache in, then redraw only nodes whose projected bounds touch the brush rectangle, scissored to that rectangle. Measure GPU frame time on Windows at 10M with and without it (`--no-cache` style flag).

**Step C: multires.** Base mesh plus subdivision levels (Catmull-Clark on quads; our icosphere is triangles, so either add a quad base primitive or use Loop for triangles). Store each level as displacements in the parent's tangent frame so lower-level edits carry the detail. Per-level BVH reuses the current node layout. First bench to settle feasibility: cost of propagating a level-2 edit to a 10M top level, per frame and at stroke end.

**Step D: per-node culling and compact vertex format** (already next in the old plan) so the GPU only touches visible nodes and less memory per vertex.

**Step E: HD regions and cluster LOD**, driven by what Bolt's Windows numbers show after B to D.

## What I need from Bolt

1. Pick the direction: **recommended is A then B now, C next.** The alternative is to go straight to multires (C), which is bigger but is the feature most associated with ZBrush's feel.
2. Do you sculpt with a pen tablet? If yes, pressure goes to the top of Step A.
3. The Windows GPU numbers for PR #1 are still the most useful measurement we don't have.

## Sources

- [The Pixol (Maxon ZBrush docs)](https://help.maxon.net/zbr/en-us/Content/html/getting-started/basic-concepts/the-pixol/the-pixol.html)
- [ZBrush (Wikipedia)](https://en.wikipedia.org/wiki/ZBrush)
- [Geometry HD (Maxon ZBrush docs)](https://help.maxon.net/zbr/en-us/Content/html/reference-guide/tool/polymesh/geometry-hd/geometry-hd.html)
- [HD Geometry tips (Novedge)](https://novedge.com/blogs/design-news/zbrush-tip-mastering-hd-geometry-in-zbrush-for-enhanced-digital-sculpting)
- [HD sculpt radial preview thread (ZBrushCentral)](https://www.zbrushcentral.com/t/hd-sculpt-not-using-memory-settings/311073)
- [GPU support thread (ZBrushCentral)](https://www.zbrushcentral.com/t/gpu-support/346284)
- [Medium Under the Hood, Part 2 (Meta developer blog)](https://developers.meta.com/horizon/blog/medium-under-the-hood-part-2-move-tool-implementation/)
