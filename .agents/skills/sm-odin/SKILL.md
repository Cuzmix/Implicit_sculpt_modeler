---
name: sm-odin
description: Odin rules and house idioms for the sculpt modeler, pinned to deps/odin (dev-2026-10-nightly:84bc3fc) — the current core:os API, core:flags, allocators and the one temp free per frame, jobs worker threads and runtime.heap_allocator(), bit-identical serial and parallel results, vendor:sdl3's require_results GPU calls, plus the names LLMs get wrong from older Odin. Load for ANY task that writes, edits or reviews .odin code under src/ (geom, sculpt, render, app, bench, jobs, tests), e.g. "add a proc", "fix this compile error", "why does -vet complain", "add a flag", "write a test", "port this C function". No prerequisites; load it before anything else. The build, run and verify loop is sm-build.
---

# Odin in the sculpt modeler

## Ground truth beats memory
- `deps/odin/odin.exe root` prints the pinned install; grep there before using a `core:`/`vendor:` name
  (`rg -n "^read_entire_file" deps/odin/core/os`). Declarations are column-aligned (`nan_f32   :: proc`), so grep
  `^name\b`, not `^name ::`.
- The compiler is the fastest oracle, one package at a time: `deps\odin\odin.exe check src\<pkg> -no-entry-point
  -collection:deps=deps -vet -strict-style -warnings-as-errors` (what `build.bat check` runs on all fourteen packages).
- The pins are `scripts/versions.env` (README "Pinned versions"); `deps/` is ignored by git and never edited.

## Trap table (verified against the pin)
| Habit from older Odin / other languages | Correct here | Source |
|---|---|---|
| `data, ok := os.read_entire_file(p)` | `data, err := os.read_entire_file(p, context.temp_allocator)`: the allocator is required and the result `@(require_results)` | `core/os/file_util.odin:167`; `src/bench/main.odin` |
| `ok := os.write_entire_file(p, d)` | it returns an `Error`: `os.write_entire_file(path, bytes) == nil` | `core/os/file_util.odin:242`; `write_ppm` in `src/app/main.odin` |
| `import "core:os/os2"` or `core:os/old` | neither directory exists; `core:os` is the new API | `ls deps/odin/core/os` |
| a flag field `dump_viewport` is passed as `--dump_viewport` | `core:flags` maps `_` to `-`: `--dump-viewport=PATH`; bools are bare (`--gpu-debug`); parsed by `flags.parse_or_exit(&opts, os.args, .Unix)`; the `usage:"…"` tag is the help text | `core/flags/internal_rtti.odin:566`; `Options` in `src/app/main.odin` |
| ignoring the result of an `sdl.*GPU*` call | the whole GPU foreign block is `require_results`: `_ = sdl.WaitForGPUIdle(device)`, `_ = sdl.SubmitGPUCommandBuffer(cmd)` | `vendor/sdl3/sdl3_gpu.odin:819`; `src/app/scene.odin:94` |
| `make(...)` inside a `jobs` callback with the context allocator | workers are `thread.create`d without `init_context` (`src/jobs/jobs.odin:39`), so they run `runtime.default_context()`, while the debug main thread runs a `mem.Tracking_Allocator` (`src/app/main.odin:111-115`): memory made on one side and freed on the other is a bad free, and the app exits 1 on it (`main.odin:120-135`). Per-job lists take `runtime.heap_allocator()` for both make and delete | `src/sculpt/brush.odin:248-250`; the same in `levels.odin`, `hd.odin`, `lod.odin` |
| `import "core:mem"` used only under `when ODIN_DEBUG` | `-vet` fails the release build with an unused import: `@(require) import "core:mem"` | `src/app/main.odin:9` |
| `append(xs, x)`; `for i, v in xs`; mutating through `for p in m.positions` | `append(&xs, x)`; `for v, i in xs`; `for &p in m.positions` | `src/geom/mesh.odin:41` |
| `math.sqrt(5)` is an `f32` | untyped float constants are `f64`: `f32((1 + math.sqrt(f64(5))) / 2)` | `src/geom/icosphere.odin:12` |
| `linalg.normalize(v)` on a vector that can be zero | `linalg.normalize0` returns zero instead of NaN | `src/geom/mesh.odin:54` |
| a `[dynamic]T` local needs an allocator | `batch: [dynamic; 256]Planned` is a fixed-capacity dynamic array on the stack: no allocation, and `append` past 256 fails | `src/render/renderer.odin:502` |
| `resize` to grow scratch; zero-initialised scratch | `non_zero_resize` skips the zeroing; `scratch: [N]Vec3 = ---` skips it on the stack; scratch kept between calls avoids first-touch page faults | `src/sculpt/levels.odin:52-54`; `brush.odin:403` |
| the compiler may inline a shared helper differently per caller | `#force_no_inline` on `frame_at` and `frame_point`: every caller must decode the same bits | `src/sculpt/levels.odin:393-398` |
| a `switch` on `sdl.EventType` lists every case | `#partial switch e.type` | `src/app/main.odin:356` |
| `log.info` prints | the default logger is a no-op; `main` installs `log.create_console_logger` (Debug level in debug builds); the test runner installs its own | `src/app/main.odin:108` |
| keeping a `fmt.tprintf`/`ctprintf` result | temp memory lives until `free_all(context.temp_allocator)`, which only the frame loop (once a frame) and big setup paths call; package procs never do, and nothing temp is stored in a struct | end of the frame in `src/app/main.odin`; `object_build` in `scene.odin` |
| `assert` is stripped in release | the build scripts never pass `-disable-assert`: `assert` is for API misuse ("leave the HD window first", `src/sculpt/levels.odin:93`); a GPU failure is `log.errorf("…: %s", sdl.GetError())` and `return false` (`src/render/renderer.odin:169`); a refused user action is `log.warn` and `return true` (`scene_apply` in `src/app/scene.odin`) | |
| a `matrix[4,4]f32` literal is column-major | the literal reads row by row (`look_at`, `perspective`, `orthographic`), indexing is `m[row, col]`, storage is column-major, which the std140 `mat4` in `mesh.vert` expects | `src/camera/camera.odin`; `camera_test.odin` |
| `json.marshal(v)` returns a string; `json.parse_string` is strict JSON | `(data: []byte, err)`; the default spec is JSON5, pass `.JSON` | `core/encoding/json/marshal.odin:138`, `types.odin:49` |
| `core:odin/format`; `core:net/nbio` | deprecated and `#panic`s (formatting is OLS `odinfmt`); `core:nbio` | `core/odin/format/`, `core/nbio/` |
| `x := f() or_return_error`; `or_return` keeps the other named results | not Odin: `or_return` needs a bool, pointer or error last; with named results it sets only the last one | language |
| `a + b` joins any strings; `s[i:j]` slices a constant | `+` joins constants only (`strings.concatenate`, a builder); bind a constant to a variable before slicing | language |
| `assert(do_work())` as a must-run check; an unused `-define` is fine | `ensure` runs in every build; an unused define is an error (`-ignore-unused-defineables`) | `base/runtime`; `odin build -help` |

## Style (enforced by `-vet -strict-style -warnings-as-errors`)
- Tabs; attached braces; trailing commas in multi-line lists; `Ada_Case` types, `snake_case` procs and variables,
  `SCREAMING_CASE` constants, each constant with a comment giving its reason (`src/sculpt/brush.odin:23-32`).
- Procs are prefixed by their subject (`sculptor_*`, `levels_*`, `levels_hd_*`, `mesh_buffers_*`, `bvh_*`, `object_*`);
  worker callbacks are `job_*`; `x_init`/`x_destroy` pairs end with `p^ = {}` (`src/jobs/jobs.odin:46-56`);
  `allocator := context.allocator` is the last parameter (`src/geom/icosphere.odin:11`).
- `@(private)` or `@(private = "file")` unless another package needs it, test helpers included; `@(require_results)` on
  procs whose result must not be dropped; `@(rodata)` for constant tables.
- Comments are full sentences on declarations stating reasons and invariants, never narration or history. Test names
  are sentences (`cones_wait_for_the_end_of_a_stroke`).

## Memory, threads, determinism
- Pair every `make`/`new` with its `delete`/`free` and write the `defer` right after; destroy procs free every field.
  `defer` runs at the end of the enclosing scope, so inside a loop that is each iteration.
- `jobs.parallel_for(pool, count, data, fn)`: `data` points at a local struct, `fn` is a non-capturing proc that casts it
  back. A nil pool or `count == 1` runs on the caller (`src/jobs/jobs.odin:66-71`); callers gate on size:
  `pool if verts >= PARALLEL_MIN_VERTS else nil` (`src/sculpt/brush.odin:26`). Never dispatch from inside a job: the
  pool holds one job at a time.
- Workers write disjoint ranges; shared counters are `sync.atomic_*`. Results are bit-identical serial and parallel, and
  tests prove it with `jobs.pool_init(&pool, 3)` (`brush_test.odin`, `levels_test.odin`, `hd_test.odin`): parallel fills
  restore a canonical order (`vertex_faces_build` sorts each face list), dirty lists are sorted before use, and map
  iteration order never decides output (maps appear only in tests and the icosphere midpoint cache).
- Engine math is `f32`; untyped float constants default to `f64`.

## Tests
- `@(test) name :: proc(t: ^testing.T)`; `testing.expect`, `expect_value`, `expectf(t, cond, "%v", report)`; helpers take
  `loc := #caller_location` and pass `loc = loc`.
- `build.bat test` runs them package by package; the runner tracks memory, and a leak or a bad free fails the test.
  Scratch comes from `context.temp_allocator`; fixtures are `geom.icosphere(n)` and `geom.geodesic_sphere(f)`, and
  `geom.mesh_check` proves a mesh sound (sm-geom).
