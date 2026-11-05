---
name: sculpt-decisions
description: Decisions and current architecture of the sculpt prototype (representation, perf design, bench results, plan status, doc links)
metadata:
  type: project
  modified: 2026-10-15T22:01:43.065Z
---

Plan agreed with Bolt 2026-10-14: 1) verify stack 2) window/viewport/UI 3) brush + mesh vs SDF 4) validate both OSes + go/no-go.
- Backend: SDL_GPU (Vulkan on Linux; Windows Vulkan assumed unless Bolt says D3D12). Doc: https://claude.ai/code/artifact/6e7fb48c-24bb-4f03-9c8d-926f3d857845
- Representation (2026-10-15): triangle mesh primary; voxel remesh later as an explicit command. Doc: https://claude.ai/code/artifact/22879fde-164c-4eeb-afc5-7b0c83b56c91
- Perf design (commit 6309abb, 2026-10-15), modelled on Blender 4.3's PBVH: mesh split into nodes (BVH leaves, ~1024 tris) that own contiguous vertex ranges + list shared verts; dabs run per node on jobs.Pool (workers spin 200us); normals recomputed once per frame in sculptor_flush (not per dab); GPU upload = dirty node ranges; parallel setup (Morton BVH + radix sort, hash-set dedupe; Odin slice.sort is ~87 ns/elem, avoid in hot setup). Release builds use -no-bounds-check.
- Bench (`./build.sh bench`, add --prefault=3000 on the cloud VM because first-touch of memory is very slow there): 10M verts large brush 33 ms -> 1.4 ms/frame (4 threads), setup 23 s -> 1.6 s, upload 32 -> 1.8 MB/frame. Plan doc: https://claude.ai/code/artifact/d90fe32f-b9e1-4e07-bf3b-858be7d71c4a
- 25M verts (commit 2206d44, 2026-10-15): setup ~5 s, large brush ~4-6 ms/frame (97k verts/dab), 2.7 GB RSS; the VM got noisy that day (10M read 2-3.5 ms vs 1.4 earlier), so compare runs back to back.
- Scene (commit 44e4f0d, 2026-10-15, Bolt's ask): many objects, each mesh in local space + Transform (position, uniform scale; no rotation yet). Tools: Select/Move (W, gizmo in src/gizmo) and Brush (B, sculpts the object the stroke starts on). Scene panel: typed vertex count for Add sphere / Remesh selected; remesh currently rebuilds the sphere (detail not kept); shape-preserving voxel remesh is still the planned separate command.
- Idle objects (2026-10-15, PR #1 merged into odin-sculpt; Windows timing confirmation pending from Bolt): lag with 2x10M spheres was GPU (all objects redrawn every frame); CPU already ~0 for idle meshes. Fix: unselected objects drawn once into a cached colour+depth image, copied in each frame, selected drawn on top; redrawn only on camera/size/selection/idle-object change. App flags --spheres=N, --no-cache; bench --meshes=N.
- Perf roadmap status, PRs and results since 2026-10-16: [[sculpt-perf-work]].
- "Fake 3D like ZBrush" study (2026-10-15, notes/zbrush-fake-3d-plan.md): no-mesh/2.5D rejected (ZBrush Edit mode is a real mesh; pixol canvas can't rotate). Bolt parked it; remaining ideas: multires, HD regions, cluster LOD.
- Step 4 (2026-10-18): Linux side re-validated on 29530d3 (tests, GPU-debug smoke, bench) and `./build.sh wincheck` compiles app+bench for windows_amd64 without linking; the real Windows run still waits on Bolt; container has no real GPU so only CPU timings are meaningful.
