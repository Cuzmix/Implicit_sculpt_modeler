# 2.7 Smaller vertices (B3): design and decision

Status 2026-10-31: decided **not to build now**. The measurements below show the GPU copy of a mesh is
not what stops a 50M scene from fitting a tablet, and the only layout that saves much costs every
stroke more upload. Revisit only if a 20M/50M run on the iPad or the RTX shows GPU memory, not CPU
memory, running out first.

## What a vertex costs on the GPU today

| Buffer | Layout | Bytes per vertex |
|---|---|---|
| `positions` | `float3` (`geom.Vec3`) | 12 |
| `normals` | octahedral `SHORT2_NORM` (`Normal_Packed`) | 4 |
| `indices` | `u32`, about 2 triangles per vertex | 24 |
| total |  | **40** |

So 50M vertices are about 2 GB on the GPU (README's gpubench paragraph says the same), of which 60% is
indices. The CPU side at 50M is about 4.5 GB (README: 888 MB of CPU mesh at 10M, plus the sculptor's
BVH, undo and levels), more than twice the GPU's.

## Measured: how chunks reference vertices

A throwaway test over the sculptor's chunks (one chunk per BVH leaf, leaf size 64), on geodesic spheres:

| Vertices | Chunks | Chunks whose index span > 65535 | Worst span | Vertices referenced per chunk, summed, per vertex |
|---|---|---|---|---|
| 100k | 5,368 | 0 | 62,630 | 1.59 |
| 1M | 52,738 | 1,557 (3%) | 624,490 | 1.59 |

Each node owns a contiguous run of vertices, but its triangles also reach vertices owned by its
neighbours (`Node.shared_*`), and those can sit anywhere in the buffer. So:

- 16-bit indices relative to a per-chunk `vertex_offset` work at 100k and fail for a growing share of
  chunks from 1M up. A mixed 16/32-bit index buffer would need two index buffers and two draw lists per
  mesh, and the culling kernels would have to write both.
- Making chunks self-contained (each chunk its own copy of the shared vertices it touches) multiplies
  the vertex count by 1.59, and every stroke must then also write each moved shared vertex's copies:
  about 1.6x today's `upload_kb` per dab.

## The candidate layouts

| Layout | Bytes per vertex | Saving | Cost |
|---|---|---|---|
| Today | 40 | - | - |
| A. Positions `unorm16x3` over the object's box + 16-bit octahedral normal (12 B vertex), `u32` indices | 36 | 10% | Position steps of box/65535: on a 2-unit object 3e-5, 6% of an edge at 50M; visible as faceting when zoomed into HD detail. Every reader changes: `mesh.vert`, the line, wire and depth-only shaders, the studio and render mode's storage reads, the BLAS build (`R16G16B16A16_SNORM` is a required acceleration structure vertex format, so ray query survives), the GPU culling's chunk records (unchanged) and GPU Smooth all, which writes positions. |
| B. A's 8-byte vertex (8-bit octahedral normal), `u32` indices | 32 | 20% | 8-bit normals (about 1.4 degrees a step) are expected to band on smooth clay under the studio light; not tried. |
| C. Self-contained chunks, 12 B vertices, `u16` indices | 1.59 x 12 + 12 = 31 | 22% | Stroke uploads x1.6, a second vertex order the sculptor keeps in step, and the culling commands gain a `vertex_offset` per chunk. |
| D. C with 8 B vertices | 1.59 x 8 + 12 = 25 | 38% | C's costs plus B's banding. |

None of them changes the CPU side, which is the larger and, on the iPad's shared memory, the one the
system's per-app limit would be hit by first.

## Decision and what would reopen it

- Not built. 2.4/2.5's GPU culling already took the per-frame cost of big meshes off the CPU; memory
  is the next limit and it is the CPU mesh's.
- Reopen when a gpubench at 20M or 50M (`build.bat gpubench --vertices=50000000`) on the RTX or the
  iPad fails or slows for GPU memory while the CPU still has room. Then build A first (one PR of about
  400 lines plus the shaders, with parity judged by `--tolerance` because positions round), and C only
  if A's 10% is not enough, since C taxes every stroke.
- The bigger lever for 50M on a tablet is the CPU mesh: levels and HD already keep the base small; the
  sculptor's per-vertex arrays (faces, owners, undo) are where a design for 50M should start.
