---
name: sm-lint
description: Judgment review of your own sculpt-modeler diff before you call it done — what build.bat check cannot catch: invented core, vendor or kit names, package-boundary leaks, allocator and lifetime bugs across jobs threads, nondeterminism between serial and parallel, mesh mutations that bypass the sculptor, GPU buffers freed in flight, non-undoable edits, stale README, leftover debug output and unverified claims. Load for ANY "is it done?", "review this change", "before I commit" or end-of-task moment, after build.bat check and build.bat test are green. Requires sm-build.
---

# Review your diff (after `check` and `test` are green)

Run `git diff` (and `git status` for new files) and go through every item. Fix what you find, then run `build.bat
check` and `build.bat test` again. Report the items you could not verify.

## 1. Does everything you called exist?
- Every `core:`/`vendor:` name: grep the pinned install under `deps/odin`, not memory; every `ui.*` name: grep `src/ui`.
  The compiler proves the code type-checks, not that you used a proc the way its comment says.
- Every build mode or `--flag` you mention in docs or messages exists in `build.bat`, `build.sh` and `Options`
  (`src/app/main.odin`).

## 2. Boundaries (the `import` lines)
- `geom` imports only `core:` and `../jobs`; `camera`, `gizmo` and `jobs` import nothing of ours; `zip` imports only `core:` (its tests use `../png_write` to deflate); `sculpt` and `voxel` import `geom`
  and `jobs`; `render` imports `geom` and is, with `app`, the only package importing `vendor:sdl3`; `bench` imports `camera`, `geom`, `jobs`, `sculpt`, `voxel` and never `render` or `app`; `sdf_trial` stands
  alone; `ui` imports only `core:`, `vendor:fontstash` and `vendor:stb/truetype`, never SDL or `render`. No new package without a design (AGENTS.md).
- No new package-level mutable state; no second way to do something that already has a way.

## 3. Lifetimes and memory
- Every `make`/`new` has its `delete`/`free` (destroy procs end with `p^ = {}`); strings and slices kept beyond a call
  are cloned; nothing from `context.temp_allocator` outlives the frame or sits in a struct; the slices `sculptor_flush`
  and `sculptor_lod_update` return are used before the next call.
- Per-job scratch uses `runtime.heap_allocator()` for both make and delete (sm-odin's trap table says why).
- `WaitForGPUIdle` before destroying any buffer or texture that may be in flight; `viewport_target_resize` only where
  the frame loop does it; every `sdl.*GPU*` result consumed.

## 4. Behaviour
- Serial and parallel give identical bits: run the comparing tests, and give new parallel code one. No map iteration
  decides any order in output.
- Mesh positions change only through `apply_dab`, `sculptor_grab_move`, `sculptor_nodes_moved` or a full sculptor
  rebuild, and the mask only through `mask_dab` or `sculptor_mask_command`; every brush weight goes through `shield`
  (mask and HD fade). Triangles change only under dynamic topology inside a stroke; any other topology change ends the
  stroke, leaves HD, clears the history, drops the levels, the mask and dynamic topology, and recreates the GPU buffers
  through `object_release_mesh` + `object_build_from` (sm-cad). Every upload passes the sculptor's `mask`.
- A dynamic object's mesh has unused slots: counts come from `object_vertex_count`/`sculptor_vertex_count`, checks from
  `sculptor_compact_mesh`, never from `len(mesh.positions)`.
- Anything the user can do is undoable (a stroke, a mask command, or a designed history entry; Remesh and turning
  dynamic topology on or off are the known exceptions, and they clear the object's history); anything that frees scene state is a
  `Scene_Command` applied at the next frame start; `Draw_Item.model` stays a similarity (rotation, translation, uniform scale);
  `viewport_invalidate` when what is drawn changed without a version bump.
- Error paths return errors (`false`, or `log.warn` and `return true` for a refused user action); programmer errors assert.

## 5. Residue
- No `fmt.print*` outside `bench`, `sdf_trial` and the app's exit stats; no probe flags, commented-out code or stray
  files; no TODO or FIXME (the repo has none: write it, or design it in AGENTS.md's terms).
- Comments say what the code cannot (why, invariants); constants carry their reason; no narration or history.

## 6. Docs and evidence
- README "App flags", "Controls", the panel descriptions and the "Layout" table are updated for anything they describe;
  it is the only doc. `python scripts/agents_sync.py` was run if a skill or agent changed.
- Your report lists the evidence per rung (check, build, test, smoke, a run with a described PNG or the exit stats, bench
  A/B ranges) and says plainly what you did not verify.
