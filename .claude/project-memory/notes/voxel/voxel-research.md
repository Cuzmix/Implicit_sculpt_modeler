# High-performance voxel (SDF) sculpting for a CPU-first, Odin/SDL_GPU sculpting app — research report

Date: 2026-10-27. Scope: desk research on 3D-Coat's voxel sculpting, modern SDF/voxel sculpting architectures, data structures, editing operators, surface extraction, incremental update, threading, GPU use, artifacts, undo, open-source references; then an architecture comparison and a recommendation tailored to our app (Odin, SDL3 + SDL_GPU, existing PBVH-style triangle-mesh sculpt core with per-node GPU upload, ~4 ms brush-to-screen target).

Claim labelling used throughout: **[V]** = VERIFIED (the cited source says it), **[I]** = INFERRED or ASSUMPTION (my reasoning or estimate; numbers marked [I] are mine). Source numbers refer to the list at the end.

---

## 1. Executive summary

- Every shipping voxel sculptor that I could find technical information for (Oculus/Adobe Medium → Substance 3D Modeler, Dreams' evaluator, Clayxels/Womp, OpenVDB-based tools, godot_voxel, Nomad/SculptGL's remesher) converges on the same core: **a narrow-band signed distance field stored in small fixed-size bricks (8³ is the dominant size), sparsely allocated, with a triangle mesh extracted per brick for display** [V: 21, 22, 24, 26, 27, 35]. Medium: 8×8×8 blocks in a hash table, band clamped to ±2 voxels, Transvoxel (an MC variant) meshing, triangles rendered rather than ray-marched "for various performance-related reasons" [V: 21, 22]. Dreams' first engine: 8³ fp16 blocks, incrementally updated, each block independently meshed with a compute-shader marching cubes [V: 24]. OpenVDB: 8³ leaves, 16³/32³ internal nodes, band half-width 3 recommended [V: 26, 27, 30].
- 3D-Coat is the only major desktop sculptor that offers a *pure* voxel mode as a first-class workflow. Its public documentation describes voxels as "numerical values [0..1] placed in a cubic grid" with the surface at the 0.5 threshold, a uniform per-layer resolution (no per-region density), Res+ doubling the voxel count per axis, a proxy/cache mode for low-res posing, voxel-only Live Booleans, and a separate polygonal Surface mode (with LiveClay adaptive tessellation) for fine detail and hard edges [V: 2, 3, 4, 5, 6, 9, 11]. No public source describes its internal storage; "cells 8³ / sparse" could not be verified [I]. User reports put the comfortable range at tens of millions of triangles on a high-end desktop (32 M "a tiny bit of lag", 128 M "hard to use" on a 3090/64 GB) [V-forum: 14].
- For surface extraction, **Naive Surface Nets** (one vertex per surface cell at the mean of edge crossings, one quad per sign-changing edge) gives ~2× fewer triangles than Marching Cubes, better triangle quality, trivially parallel per-brick, and seamless chunking if positive-boundary faces are skipped [V: 37, 38]. OpenVDB's `volumeToMesh`, Nomad and SculptGL all use this dual/surface-net family [V: 31, 60]. Its known defect (rare non-manifold vertices in ambiguous cells) is handled in OpenVDB by sign-flipping ambiguous cells and excluding non-manifold cells from adaptive merging [V: 31]. Dual Contouring with QEFs preserves sharp features but suffers self-intersections and vertices escaping cells in adversarial configurations [V: 41, 44]; it is not needed for clay-like sculpting.
- CPU meshing throughput is adequate for our budget: fast-surface-nets reports ~20 M triangles/s on one 2.5 GHz core [V: 37]. An 8³ brick holds on the order of 100–250 triangles, i.e. ~5–12 µs per brick on one core [I]; a brush touching ~100–200 bricks remeshes in well under 1 ms on 4 threads [I]. GPU MC is faster in absolute terms (e.g. 49–70 ms for a full 256³ volume on an RTX 2070 via WebGPU [V: 49]) but the readback/sync cost makes it a poor fit for small per-dab updates, consistent with our own measurements on the compute smoothing trial [I].
- **Recommendation**: a sparse bricked narrow-band SDF (int16 fixed-point, 8³ bricks, no stored apron, two-level directory), per-brick Surface-Nets meshing into our existing node-range GPU upload path (one brick group = one "node"), synchronous edit+remesh for brush-local work, asynchronous jobs for global operations, copy-on-write brick snapshots for undo, uniform per-layer resolution with ×2 resample, and reuse of our DynaMesh ray-crossing voxelizer for mesh→SDF. Rationale, numbers and a vertical slice are in sections 5–7.

---

## 2. Findings by topic

### 2.1 3D-Coat voxel sculpting

**Model and modes.** The manual's "Pure Voxel Sculpting" page: "Voxels produce a virtual grid in 3D space, and the mesh then occupies sections of this grid to form its shape"; "Mathematically, voxels are numerical values [0..1] placed in a cubic grid", the surface being the 0.5 threshold [V: 6]. Voxel mode "has no polygons" and the visible object is "a geometric approximation of the voxels" [V: 11, 12]. Surface mode is "a triangulated mesh with dynamic subdivision or decimation", switched per layer with the [V]/[S] icon in the Sculpt Tree; pressing Enter in Surface mode "temporarily voxelizes and remeshes the object, then returns to Surface mode" [V: 1]. Surface mode is recommended for "fine details and hard edges"; voxels for "organic modeling and the initial blocking out phase" [V: 2, 12]. LiveClay is a Surface-mode brush family that adds polygons only where you sculpt ("new polygons are added as needed") and the newer "Remove Stretching" option brings similar behaviour to standard surface brushes [V: 11, search summary of 1]. The manual explicitly warns against converting Surface work back to voxels ("it is not recommended to transfer your model from the surface mode into the voxel mode") [V: 11]; conversion to voxels discards Sculpt Layer information and requires closed volumes ("Voxels need a solid volume") [V: 1, 2]. Voxel layers have no surface normals, so the viewport shows faceting unless resolution is high [V: 2]; the manual calls low-resolution stair-stepping "3D jaggies" and notes "the surface can't be too thin in voxel representation" [V: 6].

**Resolution, density, Res+, proxy.** Resolution is uniform per layer: "A voxel model cannot have different densities on a single object. But you can give the whole model more resolution" [V: 11]. "Res+ … will effectively double the number of voxels the current object layer has" [V: 4] (CGPress: "Res+ doubles the resolution of the voxel volume" [V: 13]). The layer's resolution multiplier is shown before its name in the Sculpt Tree [V: 3, 4]. "Density" vs "Resolution" are distinct: changing density rescales the object within the grid (voxel count unchanged), changing resolution changes the number of voxel units; "Clone and degrade" makes a reduced-resolution copy; Resample allows up/down [V: 5, 4]. Measurement units define "voxels per unit" [V: 5]. Legacy proxy/cache mode "stores the current object and leaves a lower (proxy) res version in its place" at 2×/4×/8× reductions, "a big performance gain", changes propagate back; it is disabled by default in favour of a Surface-mode-only multi-resolution system based on Loop subdivision [V: 4, 3]. CGPress (2011) noted "voxels don't have multiple resolution levels, only density" and "Increased density will make voxel tools operate a lot slower and you end up with a more or less sluggish screen update" [V: 13]. Res+ for a small part may need "up to 256x" relative density; the manual calls this "a little bit of trial and error" [V: 5].

**Voxel brushes and volume tools.** Voxel Tools page: Vox Clay ("Expand surface with smoothing"), Grow (Ctrl collapses), Build (deprecated 4.9 brush "based on Voxel Brush Engine" replacement planned), Airbrush, Smooth, Fill ("Voxel based fill tool"), Carve ("Carve with brush alpha"), Blob, Sphere, 2D-Paint, Plane, Scrape ("voxel-based flatten tool"), Pinch, Smudge; "Act as Vox Hide" option [V: 7]. Clay Engine: Base Clay, Wet Clay, Vox Smart Pinch, Vox Pinch, Vox Flatten [V: search of 7]. Objects tools: Primitives, Import (object "should be closed without self-intersections"), Split, Clone, Cut & Clone, Vox Extrude, Vox Layer (thin shell around frozen area), Coat, Snake, Spikes, Toothpaste, Muscles, Cloth, Logo, Sketch, Constructor, Tree Generator [V: 8]. Live Booleans "works only with voxel volumes"; hierarchy of child volumes with union/subtract (Shift/Ctrl at bake), exported mesh is "watertight", instancing breaks under LB; Soft Booleans extended to voxel mode in 2025 [V: 9, 18]. Users and 3D-Coat describe voxel booleans as "flawless in comparison to working with geometry" [V: 12].

**Internals, limits, performance, file format.** No primary source describes 3D-Coat's voxel storage (brick size, sparsity, value type). The 3dcoat.com developer-docs tree exposes a `RegisterVoxHelper` class page [V: 17 (search)], but I could not read its contents; the "8³ cells / sparse" claim remains unverified [I]. Anecdotal performance: on 3DCoat 2024.13, RTX 3090/64 GB, "at 32 million triangles voxel and surface sculpting shows a tiny bit of lag, but still very useable", ~128 M "hard to use" [V-forum snippet: 14]; a Polycount veteran attributes most slowness reports to "absurdly high voxel densities" [V-forum: 14]; voxels are described as more memory-hungry than ZBrush's approach [V-forum: 15]; 32-bit builds ran out of memory (2016) [V-forum: 78]. The native `.3b` format "contains voxel and surface modeling data, paint layers, and UV maps" [V: 17]; no format spec is public [I]. Release notes 2023–2025 mention 5× faster Surface-mode Res+ subdivision, a new Live Booleans system (2024), vector displacement brushes, Soft Booleans in voxel mode (2025), and node-based sculpting (2025); nothing about voxel-engine threading or storage [V: 18, 19, 20].

### 2.2 Modern voxel/SDF sculpting architectures

**Oculus Medium / Adobe Substance 3D Modeler.** "Medium defines 3D objects (sculpts) using an implicit surface" stored as an SDF; "an SDF is never self-intersecting"; narrow band: "it clamps any distance value outside of the range [-2.0 .. +2.0]"; storage: 8×8×8 blocks, "only blocks containing solid parts of the object are stored in a hash table"; meshing: Transvoxel, "a variant of the Marching Cubes algorithm", producing a dense, evenly tessellated, always two-manifold mesh; rendering uses triangles ("we could also raymarch into the SDF on the GPU, but we use triangles for various performance-related reasons") [V: 21]. Move tool: deform the triangle mesh, convert back to SDF via rasterised fragment lists along X (sign from front/back spans) plus per-triangle narrow-band distance; "While it is a lossy conversion, in practice, the loss of data isn't perceptible"; Decrease Resolution is done by scaling the mesh and re-converting because clamped band values "become meaningless" when pushed; thin features can be lost ("isosurface extraction algorithms won't place triangles in between those samples") [V: 22]. Threading: sculpting runs "in parallel across all available threads" using ISPC (SSE4/AVX2); a producer/consumer FIFO hands results to the render thread, which copies for up to 2 ms per 10 ms frame ("We include that two milliseconds in our CPU frame time budget so that we avoid hitches"); when the FIFO is full the sculpt thread stalls (trading tool latency for steady framerate); heavy commits run asynchronously over several frames with an hourglass after 1 s; tool latency "tens of milliseconds" [V: 23]. Adobe's Modeler documentation: 3D space is "a 3D grid made up of millions of tiny cubes called voxels"; resolution is per layer ("Layers are the only scene object that can hold clay"); "If you double the resolution … then up to 8 times more voxels are needed"; Adobe Research improved the up-res algorithm [V: 63].

**Dreams (Media Molecule).** "we called each primitive an 'edit', we support a simple list, not tree of CSG edits. and models are made up of anything from 1 to 100,000 edits" (add, subtract, colour) [V: 24]. First engine: "the compound SDF function, was stored in 8³ fp16 volume texture blocks, incrementally updated as new edits arrived. each block was independently meshed using marching cubes on the compute shader" (histopyramid stream compaction) [V: 24]. The evaluator: hierarchical 4×4×4 splitting of a coarse grid with per-cell edit lists, max-norm distances and interval arithmetic for culling; renderers "required at least 1 to 1.5 voxels of valid data on each side of the mesh"; typical models 600–53 000 edits → 1–10 M surface voxels (±1.5 of surface); ">99%" culling; "10m – 100m voxels evaluated per second on a ps4" [V: 24]. Soft blend: `soft_min(a,b,r){e=max(r-abs(a-b),0); return min(a,b)-e*e*0.25/r;}`, reverting to hard min when far apart [V: 24]. Bricks engine: 8×8×8 bricks in an atlas rasterised as cubes with a short ray-march inside; later point-cloud/splat rendering (Sebastian Aaltonen: "Dreams geom is SDF based, but converted to point cloud for render") [V: 24, 69]. Dual contouring was tried for the mesh path ("the DC mesh is still quite dense … but at least it preserves edges", with holes from evaluator errors and "wobbly" edges) [V: 24]. Lesson for us: an edit-list representation needs a fast evaluator and makes every frame a re-evaluation; grids are "my safe place … filterable" [V: 24] — a stored field is the right choice for brush sculpting with 10⁴–10⁵ dabs per session [I].

**OpenVDB / NanoVDB.** Standard tree `Tree4<float,5,4,3>`: 8³ leaves, 16³ and 32³ internal nodes, unbounded root; topology encoded in per-node bit masks (`mValueMask`, `mChildMask`), values in direct-access buffers; "fast (average O(1)) random access"; narrow-band level set = active band (~3 voxels each side) plus inactive constant inside/outside tiles [V: 26, 27]. Example: a 7897×1504×5774 dragon level set with 228 M active voxels occupies 1 GB vs 14 TB dense [V: 27]. Small leaves are preferred for cache behaviour and to limit waste from partially filled leaves; large flat tables are costly (8192³ with 8³ leaves → 8 GB top table) [V: 27]. Level-set step = advect, dilate band, renormalise by solving the Eikonal PDE, trim; multithreaded Enright step on [6,5,4,3] at 1024³ (3.2 M active voxels): 0.29 s vs 2.46 s single-threaded, ~8× on 8 cores [V: 27]. Accessors cache the last path for coherent access; one accessor per thread [V: 26]. `LevelSetTracker`: "Performs multi-threaded interface tracking of narrow band level sets"; `track()` "rebuild and normalize the narrow band"; `normalize()` "Iterative normalization, i.e. solving the Eikonal equation"; `resize()` dilation+renormalisation or erosion; defaults HJWENO5 spatial, TVD-RK1 temporal, `LEVEL_SET_HALF_WIDTH` (3) [V: 30]. `LevelSetFilter`: `meanCurvature()` ("One iteration of mean-curvature flow"), `laplacian()`, `gaussian()` (4 separable mean passes), `mean()`, `median()` (slow), `offset()`, `fillet()` (rounds concave edges), optional alpha mask; TBB `parallel_for` by grain size [V: 29]. NanoVDB: "a linearized snapshot of an OpenVDB data structure, where nodes are 32B aligned in a continuous block of memory"; pointer-free, portable to CUDA/OpenCL/GLSL/HLSL/WebGL; "faster at random access than OpenVDB" on CPU; blocked bit-quantisation (2/4/8/16-bit) saves "4 to 6 times" memory with 10–30% speedup (memory-bound); limitation: "does not include tools to modify the topology of the tree" [V: 28]. OpenVDB relicensed from MPL-2.0 to Apache-2.0 at v12.0 [V: 32].

**Blender voxel remesher.** Built on OpenVDB `meshToLevelSet` + `volumeToMesh` at a voxel size; "always outputs an all quads manifold mesh" (2019 commit) [V: 33]. Current manual: Voxel Size, Adaptivity (introduces triangles, disables Fix Poles), Fix Poles, Preserve Volume (slower), reprojection of mask/face sets/colour [V: 34]. `volumeToMesh` internals: per-cell 8-bit sign pattern → `sEdgeGroupTable` (vertex count per pattern), vertex at the average of edge zero-crossings (`computePoint`), ambiguous faces resolved by flipping cell signs (`correctCellSigns`), `isNonManifold` test excludes cells from adaptive merging, adaptivity merges 2×2×2…leaf blocks when `1 - n_i·n_j` is under threshold, feature points via Kobbelt-style QEF, TBB-parallel over leaf nodes [V: 31].

**Nomad Sculpt / SculptGL.** Nomad's feature list: voxel remeshing "uses SurfaceNets meshing algorithm (produces quad-only mesh)"; SculptGL docs note the output "can contain non-manifold vertices" and that open meshes get hole filling first [V: 60, search]. Nomad's developer on limits: "voxel has a resolution limit of 1200", "A grid of 2000 means 9 billions cells, and there is no hierarchical support", memory peaks come from the reprojection pass; sphere at max → ~5.5 M vertices; "voxel remesher is not meant to be used with such high poly count" [V-forum: 59]. SculptGL is MIT, archived Jan 2026 [V: 61].

**godot_voxel (Zylann).** Smooth terrain uses Transvoxel with LOD; SDF channel stored 8/16/32-bit; "By default, the engine uses 16-bit"; 8-bit range −10…10 step ~0.078, 16-bit −500…500 step ~0.015 (fixed-point); distances are clamped so far voxels share a value and uniform blocks "do not store data"; block size 16 (or 32); normals via forward differences; meshing on a prioritised thread pool, main-thread budget ~8 ms; a mesh update "touches a block and its 26 neighbors, so 27 locks"; per-block RWLocks were replaced by a spatial lock [V: 35, 36]. MIT licence [V: 79].

**Clayxels / Womp / MudBun.** Clayxels builds "a lightweight point-cloud from voxels" and splats points rather than ray-marching; compute-shader based; freezes to a standard mesh [V: 62]. Womp stores SDF data "on a 3D grid", renders in the cloud with pixel streaming, exports OBJ/FBX/USD/glTF/STL [V: 64]. These are edit-list/primitive modellers, not brush sculptors [I].

**Kizamu / ADFs (MERL).** ADF = distance values at octree cell vertices, subdivided where the trilinear reconstruction error is high; 2D example: 1 713 ADF cells vs 23 573 3-colour quadtree cells [V: 50]. Kizamu: level-12 ADF with 2 000 chisel strokes = 124 MB; original bottom-up generation "requires too much memory", top-down "requires expensive octree neighbor searches"; new tiled generation 20× faster (level-9 in 2 s; level-12 in 7.6 s on a Pentium IV); triangle output of 200 000 triangles in 0.37 s; rendering by points/adaptive ray casting; distance correction far from the surface done in idle time [V: 51]. Lesson: adaptive octrees pay in neighbour lookups and complexity; MERL's own follow-up moved to tiled generation [V: 51].

**GPU brick structures.** GigaVoxels: bricks (small 3D textures) in an octree with a GPU node pool + brick pool managed as a unified cache [V: 52]. ESVO (Laine & Karras): compact SVO with GPU ray casting [V: 53]. "Brickmap" (van Wingerden, Utrecht 2015 — not TU Delft/van der Laan as commonly cited): raw-format, directly editable layered grids avoiding SVO preprocessing [V: 54]. SVDAG compresses identical subtrees [V: 74]. These are rendering structures for opaque voxels; for a brush sculptor they inform the GPU display path, not the editable core [I].

**ZBrush DynaMesh / Sculptris (contrast).** DynaMesh re-skins a mesh at a fixed polygon size per resolution; it is scale-dependent and "designed for low and middle resolution stages"; detail is projected back afterwards [V: 65]. Sculptris Pro adds/removes triangles under the brush with Detail Size and Adaptive settings [V: 66]. Our existing DynaMesh-style remesher and dyntopo already cover this family [V: brief].

**Houdini.** VDB Smooth SDF (mean value / Gaussian / mean curvature), VDB Reshape SDF (offset), VDB Combine (union/difference/intersection); a user reports interactive manipulation at voxel size 0.02 and slowdown at 0.01 [V: 67]. Houdini exposes OpenVDB operators rather than a brush engine [I].

**Unreal Voxel Plugin.** Marching cubes + Transvoxel LODs, background threads, "up to 50 times per second on a single chunk" edits, world size to 2³⁰ voxels per axis; no public storage details [V-forum: 68].

### 2.3 Data structures and memory layouts

- **Dense**: 1024³ × int16 = 2 GiB, ×float = 4 GiB; 4096³ (our remesh lattice) is infeasible as a persistent editable SDF [I]. Nomad's developer notes 2000³ "means 9 billions cells, and there is no hierarchical support" as the reason for the 1200 cap [V: 59].
- **Sparse bricked**: Medium 8³ blocks in a hash table [V: 21]; Dreams 8³ fp16 blocks [V: 24]; Goxel 16³ blocks with reference-counted copy-on-write [V: 57]; godot_voxel 16³/32³ blocks, uniform blocks store no data [V: 35, 36]. Bytes/voxel: int16 = 2, fp16 = 2, float = 4, int8 = 1; NanoVDB blocked quantisation 2–16 bits [V: 28].
- **VDB hierarchy**: [root hash, 32³, 16³, 8³] with bit masks; "fast (average O(1)) random access"; 1 GB for 228 M active voxels (~4.4 bytes/active voxel including overhead for float grids) [V: 27, derived]. Design guidance from the paper: small leaves for cache behaviour and low waste; a flat top table becomes huge at high resolution [V: 27].
- **Adaptive octree / ADF**: memory follows detail, but neighbour queries and regeneration are expensive [V: 50, 51].
- **Narrow band storage**: only |d| ≤ k·h stored, with tiles/flags for inside/outside; Medium ±2 [V: 21], OpenVDB 3 recommended [V: 26, 30], Dreams ±1.5 minimum for renderers [V: 24]. Quantisation: godot_voxel 16-bit fixed point default [V: 35]; NanoVDB fixed-rate bit quantisation uses per-node min/max [V: 28]. A trajectory-analytics paper warns that "narrow-band clipping is harmful" for downstream processing while uniform quantisation is benign — applicable insofar as operations needing distances beyond the band must be avoided [V: search 2.3].
- **Occupancy bitmasks**: VDB's `mValueMask`/`mChildMask` give O(1) topology tests and fast dilation (bit shifts) [V: 27].
- **Morton ordering / cache locality**: VDB sorts/traverses leaves in index order and keeps leaves in L1-sized blocks [V: 27]; godot_voxel stores flat arrays in ZXY order [V: 36]. [I]: storing 8³ int16 bricks contiguously in a pool (1 KiB each, 16 cache lines) and iterating bricks in Morton order of brick coordinates is sufficient; per-voxel Morton is unnecessary at 8³.

### 2.4 Dynamic / adaptive resolution and detail

- All brush-sculpting products examined use **uniform resolution per layer** with explicit global doubling (3D-Coat Res+ [V: 4], Medium Increase Resolution [V: 21], Modeler per-layer resolution with 8× voxel cost per doubling [V: 63]). Adaptive octrees (ADF, Manifold DC) exist in research [V: 50, 42] but no sculptor I found ships adaptive-resolution brush editing [I].
- Up-res preserves detail if done by resampling the SDF (tri-linear/cubic) and renormalising; Adobe mentions a research-improved up-res algorithm without details [V: 63]. Down-res via the mesh route (scale mesh, re-convert) because clamped band values become invalid [V: 22]; down-sampling drops thin features [V: 22].
- 3D-Coat's answer to local detail is to leave voxels (Surface mode + LiveClay) [V: 1, 11]; Medium's answer is Increase Resolution on the whole layer; Modeler's is per-layer resolution [V: 63]. [I]: multi-layer with per-layer resolution gives most of the practical benefit of adaptivity (eyes/teeth as separate high-res layers) at a fraction of the complexity.

### 2.5 Editing operations on SDFs / level sets

- **Add/subtract**: union = min(d, d_brush), subtraction = max(d, −d_brush); smooth union via polynomial smin: quadratic `h = max(k-|a-b|,0)/k; min(a,b) - h*h*k/4` (Quilez, with normalisation so k is the blend thickness in distance units) [V: 56]; Dreams uses the same quadratic form and reverts to hard min when far apart so culling works [V: 24]. smin output is not an exact distance (only a bound), so periodic renormalisation is required if gradients are relied upon [V: 56 ("bounds" discussion), I].
- **Smoothing**: mean-curvature flow and Laplacian flow of the level set are the standard level-set smoothers (OpenVDB `meanCurvature`, `laplacian`, separable `mean`, `gaussian`) [V: 29]. Mean-curvature/Laplacian flows shrink volume; mesh-side the classic fix is Taubin λ|μ (inflate pass), e.g. defaults λ=0.53, μ=−0.53 [V: search 2.5]; [I] on the SDF the cheap analogue is "smooth then offset by the mean signed change" within the brush footprint, or alternate smooth and a small negative offset.
- **Flatten/planar, clay/build, inflate**: in 3D-Coat vocabulary Scrape = "voxel-based flatten", Grow/Build grow the surface, Vox Clay "Expand surface with smoothing" [V: 7]. [I] Implementation on a stored SDF: flatten = d' = max(d, plane_d) within falloff (clip above plane) or min for filling below; clay = union with a flattened disc/ellipsoid stamp whose height is capped by the plane; inflate/grow = d − s·falloff (offset) — the offset is the only brush that keeps d a valid distance; all others produce non-SDF values locally.
- **The "brush writes non-SDF values" problem**: after min/max/smin/clipping, |∇d| ≠ 1 near seams of the operation and the band contents outside the stencil are stale. OpenVDB solves by `track()`: dilate the band as far as the interface moved, renormalise (Eikonal), trim [V: 27, 30]. Fast sweeping is O(N) (Gauss–Seidel sweeps in 2^d directions) and fast marching O(N log N); for simple geometry fast sweeping tends to win, for complex characteristics fast marching [V: 55]. [I] For brush-local work, 1–3 Jacobi/Gauss–Seidel Eikonal iterations restricted to dirty bricks (OpenVDB `setNormCount`) are enough because the brush only corrupts a few voxels of gradient; a full fast-sweep of the dirty region on stroke end restores the band.
- **Gradient clamping / band maintenance**: clamp to ±(k+1) voxels after every operation; bricks whose all values are at the clamp become inside/outside tiles and can be freed (OpenVDB `prune`, godot uniform blocks) [V: 30, 36].
- **Volume preservation**: Blender's Preserve Volume flag for the remesher exists but is slower [V: 34]; OpenVDB notes low volume loss in its advection tests (quality of the scheme) [V: 27]. No source describes a volume-preserving voxel brush; [I] measure the signed sum of d-changes in the stencil and apply a compensating offset if volume preservation is wanted (e.g. for Smooth).

### 2.6 Surface extraction

| Method | Vertices/tris (Lysenko's demo, "noise" case) | Notes [V unless marked] |
|---|---|---|
| Marching Cubes | 172 705 v / 88 071 f | ambiguous cases need MC33/asymptotic decider; Chernyaev MC33 (33 cases), Lewiner's robust table (730 subcases) with later corrections (Etiene 2012, Custodio 2013) [38, 47]; "incredibly difficult to code from scratch" [38] |
| Marching Tetrahedra | 639 522 v / 192 966 f | no ambiguity, manifold, ~4× larger meshes, slowest [38] |
| Naive Surface Nets | 41 888 v / 40 995 f (quads) | fewest primitives, "looks similar to marching cubes, only with fewer vertices and faces"; can create non-manifold vertices [38]; ~20 M tris/s single core [37]; Jyväskylä thesis: SN slightly faster than MC on noise terrain [70] |
| Dual Contouring (Ju 2002) | — | Hermite data + QEF per cell, preserves sharp features, crack-free on octrees; QEF "much more expensive" [41, 38]; vertices can escape cells, self-intersections even on refinement (Keeter) [44]; Manifold DC fixes manifoldness via multiple vertices/cell but still self-intersects and misses thin features off-grid [42, 45] |
| Dual Marching Cubes (Nielson; Schaefer–Warren) | — | dual to MC, multiple dual vertices per cell; non-manifold edges possible in ambiguous cases unless handled [43] |
| Transvoxel (Lengyel) | — | MC with a modified table plus 512→73-class transition cells to stitch LOD boundaries; patent-free; tables MIT on GitHub [39, 40]; used by Medium, godot_voxel, Voxel Plugin [21, 35, 68] |
| OpenVDB volumeToMesh | — | SN-style point per cell (average of crossings), ambiguous-face sign correction, non-manifold detection, adaptive merging by normal deviation, uniform mode = all quads [31] |
| New (2026) | — | arXiv 2604.00157 extends DC with a quadratic optimisation using only sampled SDF values, claims SOTA sharp-feature recovery [46]; Keeter proposes tetrahedralisation of surface points to guarantee manifold, self-intersection-free output [45] (research, unproven at scale) |

**Tradeoffs for incremental per-chunk rebuild** [I unless cited]: SN and MC are both purely local (one cell needs its 8 corners; SN quads need the 4 cells around an edge, so a 1-voxel apron) and parallelise per brick. SN produces ~½ the triangles of MC [V: 38] with better aspect ratios and natural quad topology (what Nomad/SculptGL/Blender users see) [V: 60, 33]. Normals: from the SDF gradient (central differences at the vertex) — fast, smooth, independent of mesh topology; fast-surface-nets does exactly this [V: 37]. Sharp features: not needed for clay; SN rounds them within one cell — the same as MC. Manifoldness: SN can emit non-manifold vertices in the ~0.1 % ambiguous configurations; OpenVDB's sign-correction trick handles faces, and for export we can run our existing manifold-guaranteed MC table over the same bricks as a fallback [I]. Seams: skip faces on the positive boundary of each chunk and read 1 voxel of neighbour data; chunks then tile exactly [V: 37].

### 2.7 Incremental surface updates vs full rebuild

- Dreams' prototype remeshed each 8³ block independently as edits arrived [V: 24]; Medium continuously extracts per block and schedules heavy commits asynchronously over multiple frames with a FIFO to the render thread [V: 21, 23]; godot_voxel schedules a remesh task per edited block and locks the block plus 26 neighbours during meshing [V: 36].
- Full rebuild is only used for remesh-style tools (Blender, Nomad) where the operation itself is global [V: 33, 59].
- Double buffering: Medium's FIFO with a 2 ms/frame copy budget is in effect a bounded double buffer between sculpt and render threads [V: 23]. OpenVDB's `LevelSetTracker` keeps two leaf buffers and swaps after each pass [V: 30].

### 2.8 Multithreading

- OpenVDB parallelises per leaf node with TBB (`parallel_for` over leaf ranges, grain size), with one accessor per thread; its level-set step scaled ~8× on 8 cores, super-linearly from cache effects [V: 27, 29, 30]. `volumeToMesh` uses `parallel_for`/`parallel_reduce` over leaves and merges per-thread seam masks [V: 31].
- Medium: all threads for sculpting via ISPC SIMD, three worker threads for the Move tool, a FIFO to the main thread [V: 23].
- godot_voxel: prioritised thread pool, spatial lock replaced 4 096 per-block RWLocks (244 bytes each on Windows) [V: 36].
- Race avoidance patterns seen: disjoint brick ownership during an edit pass; mesh only after an edit barrier; neighbour reads during meshing (27-brick footprint) [V: 36]; snapshots via copy-on-write (Goxel) [V: 57]. [I] For our job pool: phase 1 edit dirty bricks in parallel (writes confined to own brick), phase 2 mesh dirty bricks ∪ their 26 neighbours' dependency (read-only on voxel data), phase 3 upload — identical in shape to our existing per-node dab/normal/upload phases.

### 2.9 GPU vs CPU

- Medium: CPU SDF edits + CPU meshing, GPU renders triangles; GPU offload "investigating" [V: 21, 23]. Dreams: fully GPU (compute evaluator + compute MC, then splats) because the edit list must be re-evaluated every frame for animation and UGC size [V: 24]. Clayxels/MudBun: GPU compute + splats or ray-march [V: 62].
- GPU MC throughput: WebGPU/Vulkan data-parallel MC on an RTX 2070: Fuel 64³ 2 ms, Bonsai 256³ 49 ms, Skull 256³ 70 ms, Plasma 512³ 322 ms (vs serial C++ 25/228/279/1357 ms) [V: 49]; a 137.5 M-triangle isosurface of a 1 TB dataset in 526 ms with block-compressed data [V: 49]. HistoPyramid MC (Dyken 2008) outperformed geometry-shader approaches [V: 48]. [I] Per-dab, the active region is ~10⁵ voxels; GPU dispatch + fence + readback dominates; our own measurement that upload/readback overhead swamps the compute smoothing trial supports keeping edits on CPU. GPU wins for: full-model operations (global smooth, resample, boolean of two layers), direct SDF ray-marching previews, and if we later render the SDF directly (NanoVDB-style read-only snapshot) [I].
- Direct SDF rendering vs mesh: Medium chose triangles for performance [V: 21]; Dreams needed a year of OIT work on bricks and ended with splats [V: 24]. [I] Our node-range mesh path already handles 10 M vertices at <1 ms GPU; keep it.

### 2.10 Topology consistency and artifacts

- Stair-stepping/aliasing at low resolution ("3D jaggies") and faceting without normals [V: 6, 2]; cure is resolution and gradient normals [I].
- Thin features vanish below voxel size ("the surface can't be too thin" [V: 6]; Medium: down-sampling drops thin features [V: 22]; Keeter: thin features only captured if on the grid [V: 45]).
- Normals from SDF gradient (central/forward differences) are smooth and cheap [V: 37, 35]; mesh-area normals on SN meshes are also acceptable but noisier [I].
- Smoothing artifacts: volume shrinkage from curvature flows [V: 2.5]; Nomad users see distortion/chipping on large resolution jumps [V: 59].
- Chunk seams: solved by apron + positive-boundary skipping [V: 37]; LOD seams need Transvoxel transition cells [V: 39]; godot_voxel still shows "occasional sharp little steps" at LOD seams and smooths them in the vertex shader [V: 35] — irrelevant for us since we have no LOD.
- Vertex placement: SN mean-of-crossings is stable; DC/QEF can leave the cell [V: 44]; OpenVDB clamps and re-weights near seams [V: 31].
- Clamped bands hide the far field, so operations needing distance > band (large offsets, large smin radii) must dilate first [V: 22, 30].

### 2.11 Undo/redo, history, previews

- Goxel: 16³ blocks with reference-counted copy-on-write; "the image also keeps snapshots of the layers at every changes for undo history" cheaply because unchanged blocks are shared [V: 57].
- Blender sculpt undo is delta-based per step, with memory split into fixed-size blocks so diffs are small [V: 58].
- A patent describes per-chunk XOR + RLE compression of undo data computed in compute stages [V: 76].
- Medium previews the Move tool in the vertex shader and commits asynchronously; brush previews are implicit because sculpting is fast [V: 23]. Live Booleans in 3D-Coat support undo [V: 9].
- [I] Our per-node undo (store only touched node data) maps 1:1 to per-brick snapshots; a brick is 1 KiB, so even thousands of touched bricks per stroke are a few MB.

### 2.12 Open-source implementations worth studying

| Project | Licence | Why |
|---|---|---|
| OpenVDB (incl. NanoVDB) | Apache-2.0 since v12.0 (MPL-2.0 before) [V: 32] | reference for narrow-band tracking, level-set filters, CSG, `volumeToMesh`, `meshToLevelSet` [V: 26–31] |
| fast-surface-nets-rs | MIT OR Apache-2.0 [V: 37] | ~300-line chunked SN with SIMD, seam convention, gradient normals |
| Transvoxel tables (EricLengyel/Transvoxel) | MIT [V: 40] | if LOD stitching is ever needed |
| godot_voxel | MIT [V: 79] | int16 SDF channel, block pipeline, threading and locking lessons [V: 35, 36] |
| SculptGL | MIT (archived 2026) [V: 61] | SN-based voxel remesh with hole filling, Nomad's ancestor |
| Goxel | GPL-3 (check repo) [I] | COW block snapshots for undo [V: 57] |
| libigl | MPL-2.0 [I] | MC/dual contouring/signed-distance utilities for offline validation |
| Blender (intern/openvdb, remesh) | GPL-2+ [I] | how a sculptor wires OpenVDB remeshing and reprojection [V: 33, 34] |
| Dual Contouring reference (Ju/Schaefer) | papers [V: 41, 42, 43] | QEF, manifold criteria |
| scikit-image Lewiner MC | BSD [I] | MC33 table verification [V: 47] |
| Dexed | not identified — no voxel project of that name found; likely a mis-remembered name [I] | — |

---

## 3. 3D-Coat workflow summary (as a target UX reference)

1. **Start in voxels** from a primitive, imported closed mesh (voxelised; thin/open meshes must be thickened) or empty space; block out with Vox Clay, Grow, Build, Fill, Carve, Scrape, Pinch, Smudge, Sphere/Snake/Muscles primitives; booleans are free and robust [V: 6, 7, 8, 12].
2. **Raise resolution when the form is set**: Res+ (×2 per axis), or Resample to an exact value; the multiplier shows in the Sculpt Tree; duplicate first if you want to keep the earlier stage [V: 3, 4, 10]. Expect proportional slowdown [V: 13].
3. **Layer organisation**: each VoxTree layer has its own resolution and mode flag [V]/[S]; parts needing more detail are separate layers; Live Booleans define hierarchical unions/subtractions among voxel layers and bake watertight meshes [V: 1, 9, 10].
4. **Pose/large moves on a proxy**: cache the layer at 2–8× lower resolution, move, and uncache — changes transfer back [V: 4, 13].
5. **Finish in Surface mode**: switch per layer; use LiveClay/auto-subdivide for local detail and hard edges; Enter re-voxelises and returns to surface mode when topology needs cleaning; avoid going back to voxels (loses detail/sculpt layers) [V: 1, 2, 11].
6. **Output**: auto-retopo ("proprietary skinning algorithm" producing mostly quads) or export; .3b stores voxel+surface+paint data [V: 16, 17].

[I] What this teaches our design: per-layer uniform resolution with explicit ×2 steps is accepted by users; voxel mode is for mass and booleans, mesh mode for detail — we already own a strong mesh mode, so the voxel core must convert losslessly *to* the mesh pipeline and only approximately back.

---

## 4. Architecture comparison

Scoring 1 (poor) – 5 (excellent) for a desktop/tablet brush sculptor at ~1024³ effective resolution. Scores are [I] except where numbers are cited.

| Criterion | (1) Dense grid | (2) Sparse bricked narrow-band SDF | (3) Hierarchical/adaptive (VDB tree / octree / ADF) | (4) Hybrid voxel→mesh (any of 1–3 for edit, mesh for display/export) | (5a) Ray-marched SDF, no mesh | (5b) SDF edit-list (Dreams/Clayxels) | (5c) Mesh dyntopo "surface mode" (3D-Coat LiveClay; our dyntopo) |
|---|---|---|---|---|---|---|---|
| Brush latency | 4 (edit O(stencil); but mesh of dirty cells also local) | 5 (edit ~10⁵ voxels ≈ 0.1–0.3 ms; remesh ~100–200 bricks ≈ <1 ms on 4 threads) | 3 (neighbour lookups, node splits; VDB accessors mitigate) | inherits 1–3 + per-brick remesh | 4 (edit only; render cost per pixel) | 2 (re-evaluate all edits each frame; Dreams 10–100 M voxels/s on PS4 [V: 24]) | 5 today in our app (1.4 ms/frame at 10 M verts) |
| Surface reconstruction cost | 4 (local MC/SN; dense iteration wasteful) | 5 (only dirty bricks; SN 20 M tri/s/core [V: 37]) | 3 (adaptive meshing needs DC/MDC to avoid cracks [V: 41, 42]) | same as source | n/a (no mesh), but ray-march per pixel each frame | 3 (GPU MC per block [V: 24]) | n/a |
| Memory as detail grows | 1 (1024³ int16 = 2 GiB; 4096³ impossible) | 4 (≈ surface area × band; ~100–200 MB at 1024³ for a bust, est.) | 5 (VDB 1 GB for 228 M active voxels [V: 27]; ADF detail-directed [V: 50]) | adds mesh (~3–7 M verts at 1024³) | same as grid used | 5 (edits only; tiny files) | 3 (dense triangles where detailed) |
| CPU/GPU use | CPU-friendly, trivially SIMD | CPU-friendly, SIMD per brick; GPU-friendly if needed (pointer-free bricks like NanoVDB [V: 28]) | CPU; GPU only as read-only snapshot [V: 28] | CPU edit, GPU raster of mesh (our current path) | GPU heavy; CPU only edits | GPU required [V: 24, 62] | CPU |
| Multithreading | 5 (disjoint regions) | 5 (bricks are natural jobs; OpenVDB ~8× on 8 cores [V: 27]) | 3 (tree mutation needs care; NanoVDB is read-only [V: 28]) | 5 | 4 | 4 (embarrassingly parallel evaluation [V: 24]) | 4 (ours) |
| Dynamic resolution | 2 (resample whole grid) | 4 (resample bricks in parallel; per-layer res) | 5 (local refinement in principle) but no shipping sculptor does it | as source | as source | 5 (resolution-free) | 4 (local tessellation) |
| Implementation complexity | 1 (simplest) | 2 (brick pool + directory + band maintenance) | 4 (tree, tiles, pruning, adaptive meshing) | +1 over source (seams, node ranges) | 3 (renderer rewrite, AO/lighting, no export path) | 4 (evaluator/culling is the hard part [V: 24]) | done |
| Undo efficiency | 3 (copy touched region) | 5 (COW bricks, ~1 KiB each [V: 57 analog]) | 3 (node-level snapshots) | same | same | 5 (edit list diff) | ours exists |
| Mesh quality for downstream (retopo, export) | SN/MC output: uniform, manifold-ish quads | same; quad-dominant uniform mesh (Nomad/Blender-like) [V: 60, 33] | adaptive meshes need MDC for manifoldness [V: 42] | the mesh *is* the deliverable; can feed our dyntopo/remesher | must mesh at export anyway | must mesh at export (Clayxels freeze) [V: 62] | sculpted mesh, non-uniform |

**Discussion.** Dense grids fail only on memory, but they fail hard at the resolutions users expect (3D-Coat users report 32–128 M triangles [V: 14], which implies ~2048³–4096³ effective lattices [I]). Hierarchical structures win on memory per active voxel and asymptotics, but every production sculptor that reports its internals picked flat bricks in a hash/table (Medium, Dreams, godot_voxel, Goxel) — the two-level "chunk directory + 8³ brick" is already a shallow VDB without its generality, and NanoVDB's own authors note topology mutation is the hard part of hierarchical layouts [V: 28]. Adaptive resolution (octree/ADF) has not shipped in a brush sculptor; Kizamu's own authors document the neighbour-search and regeneration costs [V: 51]. Pure ray-marched display would discard our fastest asset (the mesh path) and Medium explicitly rejected it on performance grounds [V: 21]. Edit lists are perfect for primitive-based modelling and animation (Dreams, Womp) but a brush sculptor generates tens of thousands of dabs per minute and needs a stored field [I]. Mesh dyntopo is what we already have; the question is only how to add a volumetric mode that interoperates with it. Hence option (4) built on (2), i.e. "sparse bricked narrow-band SDF edited on CPU, Surface-Nets meshed per brick into our node-range display path", is the recommendation.

---

## 5. Recommendation for our app

### 5.1 Representation
- **Narrow-band SDF in 8³ bricks**, each brick = 512 × int16 fixed-point distance in voxel units, stored contiguously in a pooled slab (1 KiB per brick, 16 cache lines). Reasons: matches Medium/Dreams/VDB leaf size [V: 21, 24, 26]; small enough that a brush of radius 16–64 voxels touches 100–1 000 bricks (good job granularity, little wasted work at the stencil boundary) [I]; 16-bit avoids the shading banding and vertex-placement error of int8 (godot_voxel's 8-bit step is 0.078 units [V: 35]) while halving float memory [I].
- **Fixed point**: 1 voxel = 4096 units (2¹²), representable range ±8 voxels, precision 1/4096 voxel — far finer than needed; clamp stored values to ±(band + 1) [I]. (Alternative: fp16 as Dreams did [V: 24]; int16 is simpler for SIMD min/max in Odin and has uniform precision across the band [I].)
- **No stored apron**. Meshing and gradient reads fetch neighbour bricks through the directory; this avoids write amplification and apron-synchronisation races during parallel edits [I]. (godot_voxel instead locks 27 blocks per mesh update [V: 36]; OpenVDB uses accessors over neighbours [V: 26].) If profiling shows neighbour lookups dominate meshing, add a transient 10³ scratch copy per brick job (assembled from 27 bricks) rather than persistent aprons [I].
- **Directory**: two levels. Level 1: hash map keyed by 128³-voxel "chunk" coordinate (i32 ×3 → 64-bit key); each chunk holds a 16³ table of brick slots (u32 pool index or tile code INSIDE/OUTSIDE/EMPTY) = 16 KiB, plus a 4 096-bit occupancy mask. This is VDB's [hash, 4, 3] configuration [V: 26, 27] minus the 32³ level. Unbounded domain, 16 KiB per occupied 128³ chunk, O(1) average access, trivially serialisable [I].
- **Per-brick flags**: surface/inside/outside tile state, dirty-edit, dirty-mesh, version counter (for undo and async snapshots) [I].
- **Band half-width k = 3 voxels** (OpenVDB's recommendation [V: 26, 30]; Medium uses 2 [V: 21]; Dreams needed ≥1.5 [V: 24]). 3 gives headroom for the 5-point central-difference stencils used by curvature smoothing and for one or two voxels of interface motion per dab before the band must be dilated [I].
- **Layers**: each layer = its own grid with its own voxel size (3D-Coat/Modeler model [V: 4, 63]); booleans between layers are per-brick min/max after resampling the finer to the coarser or vice versa [I].

### 5.2 Memory estimate [I]
For a bust-like model at 1024³ effective resolution: surface ≈ 4π·(300)² ≈ 1.1 M voxel-cells per voxel layer of band; band of 6 layers ≈ 7 M active voxels; bricks intersecting the band ≈ 1.1 M/64 × ~2 ≈ 35 k bricks ≈ 35 MB of voxel data + directory (<2 MB) + mesh (≈1.1 M vertices × 32 B + indices ≈ 50 MB). At 2048³: ×4 → ~140 MB voxels, ~4.4 M vertices (comparable to the 10 M-vertex meshes we already handle). Dense equivalents: 2 GiB and 16 GiB. Sanity check against VDB's 228 M active voxels in 1 GB (~4.4 B/voxel) [V: 27]: our 2 B/voxel + ~10 % overhead is consistent.

### 5.3 Extraction
- **Naive Surface Nets per brick**: vertex at the mean of the edge zero-crossings of each surface cell; one quad (two triangles) per sign-changing edge; skip faces on the brick's +X/+Y/+Z boundary; read a 1-voxel apron from neighbours [V: 37]. Normal = normalised central-difference gradient of the int16 field at the vertex (trilinearly interpolated) [V: 37]; this gives smooth shading at any resolution and removes the per-frame normal recomputation we do for meshes today [I].
- **Ambiguity handling**: adopt OpenVDB's sign-correction of ambiguous faces to decide connectivity consistently between neighbouring cells, and flag cells where the SN vertex would be non-manifold; for display ignore, for export either (a) split the vertex per connected component of its fan, or (b) run our existing manifold-guaranteed MC table on flagged bricks [V: 31 for the technique; I for the fallback].
- **Why not MC**: ~2× triangles [V: 38], worse triangle shapes, and we would still want quad-ish output for retopo. **Why not DC/MDC**: QEF cost and self-intersection/escape failure modes [V: 41, 44, 45]; sharp features belong in the mesh "surface mode" anyway [I]. Keep MC33/our table as a validated fallback; watch arXiv 2604.00157 and Keeter's tetrahedralisation idea for later sharp-feature modes [V: 46, 45].
- **Output format**: per brick-group a vertex range + index range with capacity slack, exactly like our PBVH node ranges; one "node" = a 2×2×2 group of bricks (16³ voxels, ≈ 300–1 000 triangles typical [I]) so node count stays near our current ~1024-tri nodes and GPU upload granularity is unchanged.

### 5.4 Incremental pipeline (per frame while a stroke is active)
1. Dab → brush AABB in voxel space → list of touched bricks (allocate new surface bricks from the pool as the surface grows; convert tiles to bricks lazily) [I].
2. **Edit phase** (parallel, one job per brick, no locks: each job writes only its brick): evaluate brush SDF/stamp at 512 voxel centres, apply operator (min/max/smin/offset/clip/blend with alpha), clamp to ±(k+1), update brick min/max to detect tile collapse; mark brick + 26 neighbours mesh-dirty [I].
3. **Band maintenance**: after every N dabs or at stroke end, run 1–2 Gauss–Seidel Eikonal sweeps over dirty bricks + 1-brick halo (reading neighbours), i.e. OpenVDB `normalize` with `normCount` 1–2 [V: 30 for the operation; I for the schedule]; at stroke end run a full 8-direction fast sweep over the dirty region and re-tile bricks that are uniformly inside/outside [V: 55; I].
4. **Mesh phase** (parallel per dirty node group, read-only on voxels): SN + gradient normals into the node's vertex/index arrays; if capacity overflows, reallocate that node's range (same mechanism as our dyntopo growth) [I].
5. **Upload**: only dirty node ranges (existing path) [V: our app].
6. Budget target: step 2 ≈ 0.1–0.5 ms for 10⁵–10⁶ voxels (int16 min/max is memory-bound; ~1 GB/s per core is conservative); step 4 ≈ 100–1 000 bricks × ~10 µs / 4 threads ≈ 0.25–2.5 ms; total <3 ms for brush radii up to ~48 voxels at 4 threads [I]. Beyond that (very large brushes, global ops), move to the async path.
- **Synchronous vs asynchronous**: brush-local edits synchronous within the frame (guaranteed latency, no hitching because work scales with brush footprint, which we can cap per frame by splitting a dab into brick batches) [I]; global operations (resample, layer boolean, whole-model smooth, mesh→SDF, SDF→mesh conversion) on the job pool across frames with a preview (Medium's two-phase approach [V: 23]) and a per-brick version check so a brush edit landing on a brick during an async op is either queued or the op is restarted for that brick [I].

### 5.5 Threading model
Reuse the job pool: per-brick jobs for edit, per-node-group jobs for mesh, barrier between the phases; no mutexes on voxel data because phase 1 writes are disjoint and phase 2 is read-only [I]. Directory mutation (allocating bricks/chunks) happens in a short single-threaded pre-pass that computes the touched set (allocation is rare per dab and cheap) [I]. For async global ops, take a copy-on-write snapshot of the affected bricks (same mechanism as undo) so the UI thread never waits [V: 57 pattern]. Medium's lesson — bounded hand-off with a fixed per-frame copy budget — maps to our upload step [V: 23].

### 5.6 Undo model
Per stroke: the set of touched brick ids plus their pre-stroke 1 KiB contents (copy-on-write: the first edit to a brick in a stroke copies it to the stroke's undo buffer) and directory deltas (bricks created/collapsed) [V: 57 pattern; I]. 1 000 bricks/stroke ≈ 1 MB; optional LZ4/XOR-RLE compression for history depth [V: 76 idea]. Redo stores the post-stroke contents on undo. Mesh is regenerated from bricks on undo (no mesh snapshots). This is structurally identical to our per-node undo [I].

### 5.7 Converting to and from our triangle mesh
- **SDF → mesh ("convert to surface mode", export)**: run SN over all surface bricks in parallel, weld seam-duplicate vertices (identical positions by construction), build our PBVH, optionally run our tangential relax; the SN mesh is uniform and quad-dominant, which our dyntopo and remesher handle well [I]. If a strictly manifold mesh is required, use the manifold-MC fallback per flagged brick [I].
- **Mesh → SDF (voxelise a layer, DynaMesh-like "re-voxelise", Medium-style Move tool)**: our ray-crossing voxeliser already gives exact inside/outside on a lattice; add exact unsigned distance within the band by rasterising each triangle's AABB inflated by k voxels (Medium's method [V: 22]); sign from parity; then fast-sweep to fill the band [I]. Requires closed meshes; for open meshes use the multi-axis voting trick [V: 22].
- **Lossiness**: both directions lose sub-voxel detail (Medium: "not perceptible" in practice [V: 22]); 3D-Coat advises not going back to voxels [V: 11]. UI should present voxel mode as the mass/boolean stage and mesh mode as the detail stage, with resolution guidance (Res+ shown in the Sculpt Tree) [I].

### 5.8 Dynamic resolution
Uniform per layer; **Res+ = ×2 per axis**: tricubic (or trilinear + renormalise) resample of each brick into 8 child bricks in parallel, then fast-sweep; **Res− = ÷2**: average 2³ → 1 then renormalise, or go via mesh (Medium's reasoning about clamped bands [V: 22]); report the multiplier in the layer list as 3D-Coat does [V: 4]. No local refinement in v1 [I].

### 5.9 File storage (.sculpt extension)
Per layer: header {voxel size, transform, band k, quantisation scale, version}; chunk table (chunk coords, 16³ slot table as u8 tile codes + brick indices); brick blob in Morton order of brick coordinates, int16 little-endian, compressed per 64-brick page with a general LZ (zstd/LZ4) — narrow-band int16 compresses well because clamped values repeat [I]. Do not store the mesh. Interop: optional export to OpenVDB `.vdb` (float grid, class LEVEL_SET) for Houdini/Blender users [V: 26 for the class; I].

### 5.10 GPU offload policy
CPU-first as today. Candidates to measure later: whole-layer smoothing/resample on SDL_GPU compute (large uniform work, result stays on GPU for display if we mesh on GPU too) and a read-only linearised brick snapshot for a ray-marched preview mode (NanoVDB pattern [V: 28]). Per-dab GPU edits are not expected to win given dispatch + fence + readback latency [I; V: 49 shows full-volume GPU MC at tens of ms for 256³, i.e. only wins for big batches].

---

## 6. Minimal vertical slice and acceptance targets

**Slice contents**
1. Brick pool + chunk directory + tile states; int16 band k=3; brick allocation/collapse.
2. Primitives: sphere/box/capsule by direct SDF evaluation; mesh→SDF via the existing voxeliser + band distance.
3. Brushes: Add (union), Subtract (max with negated), Smooth (mean filter + renormalise), Inflate/Grow (offset), Flatten (plane clip) — the five that cover 3D-Coat's Vox Clay/Grow/Smooth/Scrape/Carve roles [V: 7].
4. Band maintenance: local Eikonal iterations per N dabs; fast sweep at stroke end; |∇d| diagnostic overlay.
5. Surface Nets per 2×2×2 brick group with gradient normals, seam convention, ambiguous-cell handling; node ranges → existing GPU upload.
6. Undo/redo per stroke via COW brick snapshots.
7. Res+ (×2) and Res− (÷2) as async jobs with preview.
8. Convert layer → triangle mesh (into existing PBVH) and mesh → voxel layer.
9. Save/load of voxel layers in .sculpt.
10. Benchmark harness: scripted strokes on a 1024³-effective bust at brush radii 8/16/32/64 voxels, 1 and 4 threads.

**Measurable acceptance targets** [I — chosen to match the ~4 ms brush-to-screen goal and our mesh-path numbers]
- Brush radius ≤ 32 voxels at 1024³ effective: edit + band fix + remesh + upload ≤ 3.0 ms CPU on 4 threads (≤ 2.0 ms at radius 16), 99th percentile frame ≤ 8 ms during a 10 s stroke; no frame > 16 ms (no hitch).
- Radius 64: ≤ 6 ms, or automatically split across two frames with no visible lag beyond one frame.
- Memory at 1024³ bust: voxel data ≤ 150 MB, mesh ≤ 100 MB; at 2048³ ≤ 600 MB total on desktop; tablets capped at 1024³ by default.
- Mesh: zero cracks at brick/node seams (edge-count check: every boundary edge has exactly one partner after welding); non-manifold vertices ≤ 0.1 % and all flagged; triangle count ≤ 1.1× of what SN produces for a sphere of the same resolution.
- SDF validity: after each stroke, 99 % of band voxels have |∇d| ∈ [0.9, 1.1]; no stale band after 1 000 dabs (verified by a full rebuild diff ≤ 0.05 voxel RMS).
- Undo: ≤ 2 MB per typical stroke, undo latency ≤ 1 frame for ≤ 2 000 bricks.
- Res+ 512³→1024³ on a bust ≤ 1 s on 4 threads, async, with a continuous preview; shape error ≤ 0.25 voxel RMS versus the analytic sphere.
- Round trip mesh→SDF→mesh at 1024³: Hausdorff error ≤ 1 voxel; watertight output.
- Save/load: 1024³ bust ≤ 40 MB on disk, load ≤ 300 ms.

---

## 7. Risks and mitigations

| Risk | Evidence | Mitigation |
|---|---|---|
| Band corruption from min/max/clip brushes accumulating into visible artifacts | OpenVDB's whole tracker exists for this [V: 30]; Medium's clamped values "become meaningless" [V: 22] | periodic local Eikonal iterations, full sweep at stroke end, diagnostics overlay; cap operator radii at k−1 unless band is dilated first |
| Thin features vanish, "3D jaggies" at low res | [V: 6, 22, 45] | Res+ guidance in UI; per-layer resolution; recommend mesh mode for detail |
| Non-manifold SN vertices break downstream tools | [V: 38, 60] | ambiguous-face sign correction, flagged-cell MC fallback, weld + validate on export |
| Seams between bricks / node groups | [V: 38 comments] | positive-boundary rule + apron reads; automated seam test |
| Memory blow-up at high res or many layers | 3D-Coat/Nomad reports [V: 14, 59] | tile collapse, int16, zstd on disk, resolution caps per device, estimate shown before Res+ |
| Hitches from variable per-node triangle counts (reallocation) | our dyntopo experience; godot upload stalls [V: 36] | capacity slack per node, bounded per-frame upload budget (Medium's 2 ms rule [V: 23]) |
| Normal/shading banding from quantisation | godot 8-bit "blocky appearance" [V: 35] | int16 at 1/4096 voxel; central differences over 2 voxels |
| Smooth brush shrinks volume | curvature flows shrink [V: 2.5] | compensating offset / Taubin-like alternation; expose "preserve volume" |
| Async global ops racing brush edits | godot's 27-lock issue [V: 36] | brick version counters, COW snapshots, per-brick re-queue |
| Android memory/thermal limits | tablets later | default 512³–1024³, int16, lazy brick allocation; measure |
| Patent/licence | Transvoxel patent-free, tables MIT [V: 39, 40]; MC patent expired [V: 38]; OpenVDB Apache-2.0 [V: 32] | SN and MC are free to implement; cite if copying tables |
| Unknown 3D-Coat internals | nothing public [I] | design from Medium/VDB/Dreams evidence instead |

---

## 8. Sources

1. https://3dcoat.com/documentation/?p=2336 — 3D-Coat manual, Surface mode: voxel vs surface definitions, [V] toggle, Enter re-voxelises, hardware cost of voxels.
2. https://3dcoat.com/documentation/?p=2334 — 3D-Coat manual, Voxel mode: voxels for organic/blocking, surface mode for hard edges, faceting without normals, closed volumes, conversion dialog.
3. https://3dcoat.com/documentation/?p=2607 — 3D-Coat Sculpt menu: Res+, Resample, resolution shown in Sculpt Tree, Surface-only multires.
4. https://3dcoat.com/documentation/?p=2332 — 3D-Coat density/resolution and proxy/cache: Res+ doubles voxel count, caching 2×/4×/8×, legacy proxy disabled by default.
5. https://3dcoat.com/documentation/?p=2545 — 3D-Coat "Density vs Resolution": definitions, measurement units (voxels per unit), Clone and degrade, Res+ "up to 256x" anecdote.
6. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/pure-voxel-sculpting/ — values [0..1] in a cubic grid, 0.5 threshold, "3D jaggies", thin surfaces limitation.
7. https://3dcoat.com/documentation/?p=2361 — Voxel Tools list (Vox Clay, Grow, Build, Fill, Carve, Scrape, Pinch, Smudge, …), deprecated 4.9 brushes.
8. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/voxel-mode/voxel-objects-tools/ — Primitives, Import (closed meshes), Split, Clone, Cut & Clone, Vox Layer, Snake, Muscles, etc.
9. https://3dcoat.com/documentation/manual/workspaces-rooms/sculpt/live-booleans/ — Live Booleans voxel-only, union/subtract via Shift/Ctrl, watertight bake, instancing limits.
10. https://3dcoat.com/documentation/?p=2256 — Sculpt Tree/layers: voxel volumes don't support Sculpt Layers, Res+ advice, right-click voxel functions.
11. https://3dcoat.com/articles/sculpt-in-3d-coat/ — Pilgway article: voxel mode has no polygons, uniform density, LiveClay adds polygons as needed, don't convert surface→voxel.
12. https://3dcoat.com/documentation/?p=2264 — Pilgway FAQ-style page: voxels as volumetric pixels, booleans "flawless", millions of polys per object at high res; links to voxel subpages.
13. https://cgpress.org/archives/cgreviews/3d_coat_review/2 — CGPress 3D-Coat 3.5 review: density vs levels, slowdown at high density, Res+ doubles resolution, downgrade/proxy, boolean primitives, limits.
14. https://polycount.com/discussion/comment/2770300 (and comments 2770303/2770301) — Polycount thread (via search summaries): 3DCoat 2024.13 at 32 M tris slight lag, 128 M hard to use; "absurdly high voxel densities" explanation.
15. https://polycount.com/discussion/comment/2650086 — Polycount: voxels more memory-intensive than ZBrush's approach (forum opinion).
16. https://en.wikipedia.org/wiki/3D-Coat — developer Pilgway, voxel + dynamic patch tessellation sculpting, auto-retopology "proprietary skinning algorithm".
17. https://www.cgtrader.com/blog/3d-file-formats — .3b contains voxel and surface data, paint layers, UVs; also https://3dcoat.com/files/docs/classRegisterVoxHelper.html (developer docs exist; unread).
18. https://www.cgchannel.com/2025/06/pilgway-releases-3dcoat-2025-and-3dcoattextura-2025/ — 3DCoat 2025: Soft Booleans in voxel mode, node-based sculpting.
19. https://www.cgchannel.com/2024/02/pilgway-releases-3dcoat-2024-and-3dcoattextura-2024/ — 3DCoat 2024: new Live Booleans, vector displacement brushes.
20. https://3dcoat.com/release_note/v202310/ — 3DCoat 2023: Res+ subdivision 5× faster in Surface mode.
21. https://developers.meta.com/horizon/blog/medium-under-the-hood-part-1-developing-the-move-tool/ — Medium: SDF, ±2 band clamp, 8×8×8 blocks in hash table, Transvoxel, triangles not ray-march, Move-tool prototypes.
22. https://developers.meta.com/horizon/blog/medium-under-the-hood-part-2-move-tool-implementation/ — Medium: mesh→SDF via rasterised fragment spans + per-triangle band distance, lossy but imperceptible, Decrease Resolution via mesh, thin-feature loss.
23. https://developers.meta.com/horizon/blog/medium-under-the-hood-part-3-move-tool-and-asynchronous-operations-/ — Medium: ISPC multithreading, FIFO with 2 ms/frame budget, async commit, hourglass after 1 s, latency numbers.
24. https://advances.realtimerendering.com/s2015/AlexEvans_SIGGRAPH-2015-sml.pdf — Alex Evans, "Learning from Failure" (Dreams): edit lists (1–100 000 edits), 8³ fp16 blocks + compute MC, hierarchical evaluator, soft_min formula, 10–100 M voxels/s on PS4, bricks engine, splats, DC experiments.
25. https://www.mediamolecule.com/blog/article/siggraph_2015 — Media Molecule blog announcing the talk and linking the slides.
26. https://www.openvdb.org/documentation/doxygen/overview.html — OpenVDB overview: Tree4<float,5,4,3>, 8³ leaves, tiles, active states, narrow band ~3 voxels, accessors per thread.
27. https://www.museth.org/Ken/Publications_files/Museth_TOG13.pdf — Museth, "VDB: High-Resolution Sparse Volumes with Dynamic Topology" (TOG 2013): bit masks, O(1) access, 1 GB vs 14 TB example, leaf-size rationale, level-set rebuild (dilate/renormalise/trim), CSG, Enright timings and 8-core scaling.
28. https://research.nvidia.com/labs/prl/nanovdb/nanovdb2021.pdf — Museth, NanoVDB (SIGGRAPH 2021 Talks): linearised 32 B-aligned nodes, pointer-free, GPU APIs, faster random access than OpenVDB on CPU, bit quantisation 4–6× memory savings, no topology modification.
29. https://openvdb.org/documentation/doxygen/LevelSetFilter_8h_source.html — LevelSetFilter: meanCurvature, laplacian, gaussian, mean, median, offset, fillet, masks, TBB cook.
30. https://openvdb.org/documentation/doxygen/LevelSetTracker_8h_source.html — LevelSetTracker: track/normalize (Eikonal)/dilate/erode/resize/prune, defaults HJWENO5 + TVD_RK1, half width, grain size.
31. https://www.openvdb.org/documentation/doxygen/VolumeToMesh_8h_source.html — volumeToMesh internals: edge-group table, mean-of-crossings vertex, ambiguous sign correction, non-manifold test, adaptivity by normal deviation, TBB.
32. https://phoronix.com/news/ASF-OpenVDB-12.0 — OpenVDB 12.0 relicensed from MPL-2.0 to Apache-2.0.
33. https://lists.blender.org/pipermail/bf-blender-cvs/2019-March/120919.html — Blender voxel remesher initial commit: OpenVDB level set at voxel size, "all quads manifold mesh".
34. https://docs.blender.org/manual/en/latest/sculpt_paint/sculpting/tool_settings/remesh.html — Blender manual Remesh: Voxel Size, Adaptivity, Fix Poles, Preserve Volume, reprojection, limitations.
35. https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/ — godot_voxel smooth terrain: SDF 8/16/32-bit (16-bit default, ranges/steps), clamping, Transvoxel, LOD seams, normals.
36. https://voxel-tools.readthedocs.io/en/latest/performance/ — godot_voxel performance: thread pool, 8 ms main-thread budget, block sizes 16/32, uniform blocks store no data, 27-lock mesh update, spatial lock.
37. https://github.com/bonsairobo/fast-surface-nets-rs — fast-surface-nets: ~20 M triangles/s single core, positive-boundary face skipping, 16³+padding chunks, gradient normals, MIT/Apache-2.0.
38. https://0fps.net/2012/07/12/smooth-voxel-terrain-part-2/ — Lysenko: MC vs MT vs Surface Nets vs DC, vertex/face counts, timings, non-manifold SN caveat, chunk seam comments.
39. https://transvoxel.org/ — Transvoxel: transition cells (512 cases/73 classes), patent-free, dissertation reference.
40. https://github.com/EricLengyel/Transvoxel — Transvoxel lookup tables, MIT.
41. https://www.cs.wustl.edu/~taoju/research/dualContour.pdf — Ju, Losasso, Schaefer, Warren, "Dual Contouring of Hermite Data" (SIGGRAPH 2002).
42. https://people.engr.tamu.edu/schaefer/research/dualsimp_tvcg.pdf — Schaefer, Ju, Warren, "Manifold Dual Contouring".
43. https://people.engr.tamu.edu/schaefer/research/dmc.pdf — Schaefer & Warren, "Dual Marching Cubes"; non-manifold edge caveats via search.
44. https://www.mattkeeter.com/blog/2023-04-23-adversarial/ — Keeter: adversarial DC configurations, vertices escaping cells, self-intersections, scale invariance.
45. https://mattkeeter.com/blog/2026-07-03-meshing — Keeter: Manifold DC self-intersections/thin features; proposed point-then-tetrahedralise meshing.
46. https://arxiv.org/abs/2604.00157 — "Reconstructing Surfaces from Discrete Distance Fields" (2026): DC extension with quadratic optimisation on sampled SDF values.
47. https://www.cin.ufpe.br/~sbm/CGartigos/marching_cubes_jgt.pdf and https://en.wikipedia.org/wiki/Marching_cubes — Lewiner et al. MC33 implementation (730 subcases), Chernyaev MC33, later corrections, patent expiry.
48. https://diglib.eg.org/handle/10.2312/CGF.v27i8pp2028-2039 — Dyken et al., "High-speed Marching Cubes using HistoPyramids".
49. https://arxiv.org/pdf/2009.03254 — Usher & Pascucci (LDAV 2020): serial vs Vulkan/WebGPU MC timings (Fuel 64³ 2 ms, Bonsai/Skull 256³ 49–70 ms, Plasma 512³ 322 ms on RTX 2070), 137.5 M-tri isosurface in 526 ms.
50. https://shadow.merl.com/publications/docs/TR2000-15.pdf — Frisken et al., "Adaptively Sampled Distance Fields" (SIGGRAPH 2000): octree ADFs, 1 713 vs 23 573 cells example.
51. https://www.merl.com/publications/docs/TR2001-08.pdf — Perry & Frisken, "Kizamu" (SIGGRAPH 2001): level-12 ADF 124 MB, generation 20× speedup (2 s level-9, 7.6 s level-12), 200 k triangles in 0.37 s, idle-time distance correction.
52. http://maverick.inria.fr/Publications/2009/CNLE09/ (copies at https://publications.graphics.tudelft.nl/papers/423) — Crassin et al., GigaVoxels: brick octree with GPU node/brick pools and unified cache.
53. https://nvidia.com/docs/io/88972/nvr-2010-001.pdf — Laine & Karras, Efficient Sparse Voxel Octrees.
54. https://studenttheses.uu.nl/handle/20.500.12932/20460 — van Wingerden, "Real-time Ray tracing and Editing of Large Voxel Scenes" (Utrecht 2015): editable layered grids ("brickmap" lineage).
55. https://users.math.msu.edu/users/qian/papers/ZhangZhaoQian.pdf and https://repository.lib.ncsu.edu/server/api/core/bitstreams/eab073e1-a2ad-49fa-9596-4e0d2df49c5c/content — fast sweeping O(N) vs fast marching O(N log N); empirical comparisons (Gremaud & Kuster).
56. https://iquilezles.org/articles/smin/ — Quilez: smooth-minimum variants, normalisation so k = blend thickness, bounds.
57. https://github.com/sariug/goxel/blob/master/INTERNALS.md — Goxel internals: 16³ blocks, reference-counted copy-on-write, cheap layer snapshots for undo.
58. https://developer.blender.org/rBc5feb4e6fe27 — Blender sculpt undo documentation: delta-based steps, fixed-size memory blocks for diffing.
59. https://forum.nomadsculpt.com/t/high-resolution-voxel-remesh/4349 — Nomad developer: 1200 resolution cap, "9 billions cells … no hierarchical support", reprojection memory peaks, ~5.5 M verts max.
60. https://stephaneginier.com/ — Nomad feature list: voxel remeshing uses SurfaceNets (quad-only).
61. https://github.com/stephomi/sculptgl — SculptGL: MIT, archived Jan 2026.
62. https://80.lv/articles/clayxels-for-unity-released/ and https://itch.io/profile/clayxelfan — Clayxels: voxel-generated point cloud, compute shader core, freeze to mesh.
63. https://helpx.adobe.com/substance-3d-modeler/desktop/organize-your-scene/layers.html and https://helpx.adobe.com/substance-3d-modeler/desktop/technical-support/how-does-modeler-work.html — Substance 3D Modeler: SDF voxel grid, per-layer resolution, 8× voxels per doubling, improved up-res algorithm.
64. https://all3dp.com/4/even-potato-computers-can-run-this-new-3d-modeling-software/ and https://gamefromscratch.com/womp-3d-modelling-app/ — Womp: SDF on a 3D grid, cloud rendering, export formats.
65. https://help.maxon.net/zbp/en-us/Content/html/5_sculpting-and-painting_dynamesh-sculpting-essentials.html — ZBrush DynaMesh for low/mid resolution stages (plus ZBrushCentral threads on scale dependence).
66. https://help.maxon.net/zbr/en-us/Content/html/zbrushcore/modeling-methods/modeling-methods.html.md — Sculptris Pro dynamic tessellation adds/removes polygons as needed.
67. https://www.sidefx.com/forum/topic/89598/ — Houdini SDF boolean modelling: VDB Smooth SDF modes, Reshape SDF, Combine; interactive at voxel size 0.02.
68. https://forums.unrealengine.com/t/voxel-plugin/98080 — Unreal Voxel Plugin: MC + Transvoxel LODs, background threads, edit rates.
69. https://x.com/SebAaltonen/status/863853165212512258 — Aaltonen: "Dreams geom is SDF based, but converted to point cloud for render."
70. https://jyx.jyu.fi/handle/123456789/79364 — Jyväskylä thesis: naive surface nets slightly outperform MC on noise terrain.
71. https://people.compute.dtu.dk/janba/gallery/polygonization.html — DTU notes: MC awkward triangles, DC nicer meshes depending on vertex placement.
72. https://news.ycombinator.com/item?id=27351951 — HN discussion of Dreams' compute-generated splats (secondary).
73. https://lesterbanks.com/2011/10/mesh-resolution-and-voxel-sculpting-in-3dcoat/ — 2011 overview of mesh resolution vs voxel sculpting in 3D-Coat (secondary).
74. https://research.chalmers.se/publication/?id=240766 — Sparse Voxel DAGs (shared subtrees).
75. https://github.com/AcademySoftwareFoundation/openvdb/discussions/1549 — OpenVDB: voxels beyond the band receive constant background values.
76. https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9129416 — patent describing per-chunk XOR + RLE undo compression.
77. https://developers.meta.com/horizon/blog/ (series index) — "Medium Under the Hood" series landing (navigation only).
78. https://steamcommunity.com/app/100980/discussions/0/412448158150293431 — 3D-Coat out-of-memory crashes on the 32-bit build (2016).
79. https://github.com/Zylann/godot_voxel — godot_voxel repository (MIT; smooth terrain with Transvoxel; 8/16-bit channels).
