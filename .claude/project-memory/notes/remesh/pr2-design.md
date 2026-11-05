# PR 2 design: AutoRemesher as the Quad Remesh engine (`src/quadmesh`)

Part of the Remesh and Quad Remesh plan (report https://claude.ai/artifact/Y7oLGn8QV2MmegNP2uYWgV, PR 1 = #358).

## Request
Add AutoRemesher's core (github.com/huxingyi/autoremesher, commit 4a49f82f, MIT) as a pinned, source-built
dependency behind a small C ABI, and an Odin package `src/quadmesh` that turns a triangle mesh into a polygon mesh
of (nearly all) quads through it, with progress and cancel. No command, no panel, no threading in the app, no
symmetry, no output validation beyond counts: PR 3 adds the Quad Remesh command and the validate/repair/refuse step,
PR 4 the options. Desktop only in this PR (Windows, Linux, macOS, `AVAILABLE`); Android and iOS compile the
package with `AVAILABLE` false (the proc refuses), and their builds take the C++ sources in PR 3 or later.

## Current state (verified in the clone and the repo)
- AutoRemesher core: `src/AutoRemesher/*.cpp` (12 files) + headers under `include/AutoRemesher/` (extension-less,
  `#include <AutoRemesher/…>`) and `src/AutoRemesher/*.h`; `thirdparty/isotropicremesher/*.cpp` (3, MIT),
  `thirdparty/meshoptimizer/src/{simplifier,indexgenerator}.cpp` (MIT), `thirdparty/eigen` (header-only; only
  `IncompleteLUT.h` is LGPL and it is not used, so `EIGEN_MPL2_ONLY` holds), TBB only as `parallel_for`,
  `blocked_range`, `parallel_sort`, `combinable` (included, unused) and `mutex`. Qt only in the GUI/CLI.
  `meshseparator.cpp` lacks `<cstdint>` (force-included). API: `AutoRemesher(vertices, triangles)`,
  `setTargetTriangleCount(2·quads)`, `setScaling`, `setGradientAdaptivity`, `setSharpEdgeDegrees`, `setAnisotropy`,
  `setSmoothNormalDegrees`, `setProgressHandler(void(*)(void*, float, const char*))`, `setTag`, `remesh() -> bool`,
  `remeshedVertices()`, `remeshedQuads()` (polygons of any size). `remesh()` validates empty input and a zero target
  (`autoremesher.cpp:548-563`) and reports the reason through the handler with progress 1.0. No cancel.
- Repo patterns: `scripts/build_luau.py` (C++ from source: clone at a tag, clang++/cl /MT /EHsc /std:c++17, one static
  library, stamp file, parallel compile) and `scripts/build_ufbx.py` (our shim compiled with the source; stamp names
  the shim's hash); `src/luau/luau.odin:14,68-73` (`AVAILABLE`, `foreign import` under `when`, `system:stdc++`);
  `src/fbx/fbx.odin:30-52` (shim C ABI, the C side holds the big structs). `scripts/versions.env` holds the pins.
  Package lists: `build.sh:144,151`, `build.bat` (check and test lines), `.vscode/tasks.json:275`,
  `scripts/boundary_check.py`, AGENTS.md's map, section 3 and section 5 (allowed imports), sm-lint's import list.
  Licence texts live in `assets/licenses/` (README line 190).
- Measured (report): 99.5–100 % quads and 95–100 % valence-4 on our fixtures; 0.4 s for 2k quads from a 20k sphere;
  bit-identical reruns; 20 s / 1.5 GB on 3.8M dirty triangles; a 956k-triangle non-manifold input never finished.

## Design
### Files
- `scripts/versions.env`: `AUTOREMESHER_COMMIT=4a49f82f720f647691c09a7d8a16fa63be208aad` (no tag points at it).
- `scripts/build_autoremesher.py`: shallow-fetches that commit into `deps/autoremesher-src` (`git init`,
  `fetch --depth 1 origin <sha>`, `checkout FETCH_HEAD`, a `commit.txt` stamp), compiles the 17 sources above plus
  `src/quadmesh/quadmesh_shim.cpp` in parallel with `-std=c++17 -O2 -fPIC -w -DEIGEN_MPL2_ONLY -DEIGEN_DONT_PARALLELIZE
  -include cstdint` (cl: `/MT /EHsc /O2 /std:c++17 /W0 /FIcstdint`), include dirs `include`, `src`,
  `thirdparty/eigen`, `thirdparty/isotropicremesher`, `thirdparty/meshoptimizer/src` and `src/quadmesh/shim`, into
  `deps/autoremesher/libautoremesher.a` (`autoremesher.lib`); stamp = commit + the shim sources' hash. Run by
  `setup_deps.sh/.bat` after `build_ufbx.py`; `build.sh`/`build.bat` refuse to link the app without the library,
  as they do for Luau and ufbx.
- `src/quadmesh/shim/tbb/{blocked_range,parallel_for,parallel_sort,combinable,mutex}.h`: stand-ins. `parallel_for`
  cuts the range into `quadmesh_threads` equal chunks (set once per call from `Params.threads`, 1 to 16), each on a
  `std::thread`; the calling thread only joins; a nested call (a `thread_local` depth) and a range under 4096 run
  serially on the caller. Every body AutoRemesher passes writes its own elements, so the result does not depend on
  the cut or the timing. `parallel_sort` is `std::sort`. `combinable.h` is empty (unused), `mutex` is `std::mutex`.
- `src/quadmesh/quadmesh_shim.h/.cpp`, the C ABI (`extern "C"`, no exceptions cross it):
  ```c
  typedef struct Qm_Params { uint32_t quads; float adaptivity, sharp_degrees, anisotropy, scaling; uint32_t threads; } Qm_Params;
  typedef bool (*Qm_Progress)(void* tag, float fraction, const char* stage);   /* false asks to stop */
  typedef struct Qm_Result Qm_Result;
  Qm_Result* qm_remesh(const float* positions, uint32_t vertices, const uint32_t* triangles, uint32_t triangle_count,
                       const Qm_Params* params, Qm_Progress progress, void* tag, char* error, size_t error_size);
  void qm_counts(const Qm_Result*, uint32_t* vertices, uint32_t* faces, uint32_t* corners);
  void qm_copy(const Qm_Result*, float* positions, uint32_t* first, uint32_t* corners);   /* first has faces + 1 entries */
  void qm_free(Qm_Result*);
  ```
  `qm_remesh` builds the double `Vector3`s and `vector<vector<size_t>>` triangles, sets every option, runs
  `remesh()` inside `try`, and returns NULL with `error` filled on: `remesh()` false (the last status string the
  handler saw, AutoRemesher's own reason), a cancel ("cancelled"), `std::bad_alloc` ("out of memory") or any other
  exception. Cancel: the handler the shim installs calls the Odin callback; when that returns false on the thread
  that called `qm_remesh`, it throws `Qm_Cancel`, caught in `qm_remesh`. The main thread calls the handler only
  between phases and in serial island loops (never while the shim's worker threads run, since the caller never
  executes a chunk), so unwinding meets only RAII state (the raw `new`s are the isotropic remesher's and the bounding-box tree's nodes, deleted by their owners' destructors; the solvers hold `unique_ptr`s). One `catch (...)` round an island's parameterization swallows the first throw; the sticky cancel throws again at the next progress call. Worker-thread callbacks only report.
- `src/quadmesh/quadmesh.odin`:
  ```odin
  AVAILABLE :: (ODIN_OS == .Windows || ODIN_OS == .Linux || ODIN_OS == .Darwin) && ODIN_PLATFORM_SUBTARGET != .Android && ODIN_PLATFORM_SUBTARGET != .iPhone
  Params :: struct { quads: int, adaptivity: f32, sharp_degrees: f32, anisotropy: f32, scaling: f32, threads: int }
  DEFAULT_PARAMS :: Params{quads = 4000, adaptivity = 0, sharp_degrees = 90, anisotropy = 0, scaling = 0, threads = 1}  // AutoRemesher's own defaults, adaptivity 0 since the report found 1 lands 3× under the count
  Polygon_Mesh :: struct { positions: []geom.Vec3, first: []u32, corners: []u32 }   // polygon p = corners[first[p]:first[p+1]], counter-clockwise outward
  Report :: struct { faces, quads, triangles, ngons: int, ms: f64 }
  Error :: enum u8 { None, Unavailable, Refused, Cancelled, Failed }
  remesh :: proc(positions: []geom.Vec3, indices: []u32, params: Params, progress: ^jobs.Progress = nil, allocator := context.allocator) -> (out: Polygon_Mesh, report: Report, err: Error, reason: string)
  polygon_mesh_destroy :: proc(m: ^Polygon_Mesh, allocator := context.allocator)
  polygon_share :: proc(m: Polygon_Mesh) -> (quads, triangles, ngons: int)
  ```
  `reason` is AutoRemesher's or the shim's message copied to `context.temp_allocator` (empty on success). Indices
  out of range or `quads == 0` are `.Refused` before the call (our own meshes should never send them, but the input
  may come from a file, so no assert). The progress callback is `proc "c"` with `context = runtime.default_context()`,
  mapping AutoRemesher's 0–1 onto `progress_set(p, 0, 1, f)` and returning `!progress_cancelled(p)`. Output
  copied into `allocator` slices; the C result freed before return. Under `!AVAILABLE` the proc returns `.Unavailable`.
- `src/quadmesh/quadmesh_test.odin`: (1) `icosphere(4)` at 1500 quads: `err == .None`, ≥ 99 % quads, every edge in
  two polygons with opposite direction (closed, consistently wound), outward (polygon normal · centroid > 0),
  ≥ 95 % of vertices in four polygons, every vertex within 0.02 of the unit sphere; (2) the same with `threads = 1`
  and `threads = 4` is bit-identical; (3) empty input, `quads = 0` and an index past the end are `.Refused` with a
  reason; (4) a progress that cancels on its first callback returns `.Cancelled` in well under the full time, no
  leak on the Odin side. Each test skips (passes with a log line) when `!AVAILABLE`.
- Lists and docs: `quadmesh` added to `build.sh` check/test lists, `build.bat`, `.vscode/tasks.json`,
  `scripts/boundary_check.py` (`quadmesh` imports only `core:`, `geom` and `jobs`; imported only by `app`),
  AGENTS.md (map row, section 3 test list, section 5 boundaries), sm-lint's import list and sm-cad's "what exists"
  (then `agents_sync.py`); `assets/licenses/AutoRemesher-LICENSE.txt`, `Eigen-LICENSE.txt` (MPL 2.0),
  `isotropicremesher-LICENSE.txt`, `meshoptimizer-LICENSE.txt`; README: "Pinned versions" and a "Quad Remesh engine"
  paragraph under Retopology saying what is built, from where, and that the command arrives next.

### Ownership, threading, failure
- The C result lives only inside `remesh`; the Odin slices are the caller's (`allocator`). Nothing temp is stored.
- Threads: AutoRemesher's own, through the shim, `Params.threads` of them (PR 3 passes the long job's pool size);
  never `jobs` (one pool job at a time, and the job thread that calls `remesh` is itself a pool-side thread).
- `.Refused` and `.Failed` carry a reason for the caller's `report(...)`; `.Cancelled` is silent; a GPU-less
  package, so nothing returns false for the frame.

## Boundary check
`quadmesh` → `core:`, `../geom` (Vec3), `../jobs` (Progress): the same edges `sculpt` has. `app` → `quadmesh` in
PR 3. No `render`, `ui`, SDL. The C++ is reached only through the `foreign` block under `when AVAILABLE`.

## Alternatives rejected
- Port AutoRemesher to Odin (10.7k lines of frame fields, MILS and quad extraction with Eigen): months, and the
  report chose the hybrid.
- Link real TBB: a 2021-era CMake dependency for three templates; the shim is 60 lines.
- Hand the Odin `jobs` pool to the shim's `parallel_for`: the pool holds one job at a time and the remesh already
  runs inside one; nested dispatch is forbidden (sm-odin).

## Risks
- Memory and time on large or dirty input (1.5 GB at 3.8M triangles; a non-manifold 956k never finished): the
  package only exposes counts; PR 3 caps the triangles it sends (decimate first) and refuses non-manifold input
  with numbers. Caught by PR 6's `remesh_check.py` corpus; here test (1)'s time is logged.
- Cancel by exception through AutoRemesher's frames: a leak of its raw allocations would be invisible to the Odin
  tracker. Mitigation: grep every `new` in the core in step 1 and note the result in the shim's comment; cancel is
  rare and the job's thread ends with the process otherwise.
- Determinism across thread counts: test (2); AutoRemesher's own `std::unordered_map`s are seeded by content, not
  time, and its island order is preserved by index (`autoremesher.cpp:605-612`).
- Output polygons that are not quads (3- and 5-gons, 0.5 % on our fixtures): kept as polygons in `Polygon_Mesh`;
  PR 3 stores them as `Polys` (the general side table PR 1 draws) rather than `Quad_Faces`.
- Windows: `cl` with `/EHsc` and `/MT` as Luau; `/FIcstdint` for the missing include; Eigen's templates compile
  slowly (minutes) once. Bolt's Windows run is the check.

## Plan
1. `build_autoremesher.py` + the TBB shim + the C ABI shim + licences + setup/build hooks (~250 lines of script
   and C++). Evidence: the library builds here with clang++; `nm` shows the `qm_*` symbols.
2. `src/quadmesh` binding and tests (~250 lines). Evidence: `build.sh check`, the four tests, `test_only.py
   quadmesh` timings logged, `build.sh` links the app.
3. Lists, AGENTS/skills/README, `agents_sync.py`, `gate.py --fast` (check, test, debug build, iphonecheck,
   wincheck, androidcheck show `AVAILABLE` false compiles).

## Open questions (defaults taken)
1. Pin the commit, not a release tag (none points at the measured commit). Default: the commit.
2. macOS desktop in `AVAILABLE` though untested here. Default: yes, `build.sh` on a Mac builds it the Linux way.
3. `adaptivity` default 0 (count honoured within 20 %) or AutoRemesher's 1 (3× under). Default: 0 in
   `DEFAULT_PARAMS`; PR 4's option exposes it.

## Review (sm-architect, 2026-10-30) and as built
Verdict: minimal and sound; required: exceptions in workers carried to the caller (parallel_for), `quadmesh_threads`
thread-local (the test runner runs a package's tests on one thread per core, so a global clobbered the determinism
test), the cancel comment corrected (one `catch (...)` swallows the first throw), only AutoRemesher's own reasons
(progress 1.0) as the failure reason, the Input tests workflow caching and building `deps/autoremesher`. All done.
The std::cerr capture became one process-wide locked sink after a crash: two concurrent tests swapping
`std::cerr`'s buffer in and out left one writing to the other's dead buffer. Determinism is claimed per build, not
across platforms (unordered_map order in quadextractor.cpp): never put quadmesh output in a parity comparison.
