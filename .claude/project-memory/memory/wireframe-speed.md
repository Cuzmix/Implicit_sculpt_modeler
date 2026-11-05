---
name: wireframe-speed
description: Wireframe overlay active-object-only, drawn in the shading pass via barycentrics (#508, quads #570); verified on 3060 Ti 2026-11-04, iPad not yet
metadata:
  type: project
  modified: 2026-11-02T20:33:42.542Z
---

Bolt reported wireframe slow on dense meshes and asked that it show on the active mesh only (2026-11-02). Merged #508:
- Overlay (lines, poly edges, group fill) only on the selected object; Wireframe shading mode still shows all.
- Where Gpu_Caps.barycentric (VK_KHR_fragment_shader_barycentric / Metal supportsShaderBarycentricCoordinates), plain opaque items draw edges in the shading pass (mesh_wire.frag.slang, first line `// barycentric`, MSL 2.3); others fall back to the LINE-fill second pass. Dense areas fade to 50% wire colour (WIRE_DENSE).
- gpubench cases "Orbit, wireframe" / "Orbit, wireframe as lines"; exit stats wire_shaded/wire_lines/wire_barycentric.
- Measured on lavapipe (4x1M orbit): wire cost +210% -> ~+20% (active-only on the line path).

Container: `apt-get install mesa-vulkan-drivers vulkan-validationlayers spirv-tools` works now (lavapipe, validation). Neither lavapipe nor SwiftShader has barycentrics.

- 2026-11-03 Bolt's 3060 Ti gpubench: barycentrics on; 502k shaded 1.31 vs lines 2.49 ms. 1M+ bench sphere is QUADS, so wire = polygon-edge line list (unculled, 20M: 24.7 vs 5.2 ms). #570 draws polygon edges in the shading pass too: per-tri 4-bit flags (levels_polygon_tri_edges, Mesh_Buffers.tri_edges), tri = command first_instance (first_index/3; LOD = WIRE_ALL_EDGES) + SV_PrimitiveID; Vulkan gate now also geometryShader + drawIndirectFirstInstance. Unverified on GPU; fallback lines still unculled.
- 3 app tests (sections_show_at_most_five_controls etc.) failed on odin-sculpt 2026-11-03, not ours.

- 2026-11-04 Bolt's 3060 Ti gpubench confirms #570: wireframe vs no simplify 20M 5.90/5.24, 10M 3.66/3.01, 5M 2.42/2.28 ms (lines 24.9 at 20M). Oddity: at 502k/1M shaded (1.90, 2.48) is slightly slower than lines (1.81, 2.11), was 1.31 at 502k on 11-03; not investigated.

**Why:** perf-critical render change.
**How to apply:** open follow-up: iPad gpubench to confirm the barycentric path (wire_barycentric=true) and its numbers; Mali support unknown. Related: [[perf-25m-study]], [[perf-critical-care]].
