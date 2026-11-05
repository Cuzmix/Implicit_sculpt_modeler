# 13 · Our app today: what to improve, enhance or rewrite

Audit of `odin-sculpt` at commit `922f797` (PR #49 merged, 2026-10-25). Read alongside 07 (findings), 10 (redesign) and 12 (roadmap): every item here has an ID (`A-xx`) the roadmap refers to.

Scope: the interface, the input model, and the code structure for maintenance. The sculpt core's speed is not re-litigated here; it already beats the targets (10M at under 2 ms CPU, under 1 ms GPU on Bolt's RTX 3060 Ti).

## 1. What we have (the baseline the redesign builds on)

| Area | What exists | Where |
|---|---|---|
| Code size | ~39.6k lines of Odin in 142 files; `app` 10.4k, `sculpt` 12.9k, `geom` 7.7k, `ui` 3.6k, `render` 2.1k | `src/` |
| Interface | One touch-first kit drawn by our renderer (ImGui removed in `200bec1`); floating chrome over a full-window viewport; 48 pt hit areas everywhere; tokens + motion; 0.65 ms p50 UI per frame | `src/ui`, `src/app/new_ui.odin`, `kit_*.odin` |
| Layout | Top-left menu, undo/redo, History; top-middle tools (Move, Sculpt, Curve, Insert) + XYZ symmetry; top-right View menu + inspector; left Size/Strength sliders; bottom brush dock (7) + grid of all; right inspector with tabs Tool / Object / Scene | README "Interface" |
| Input | ZBrush-for-iPad routing: one owner per touch, finger/pen on model sculpts, on empty space orbits, 2-finger pan/pinch/twist, 3-finger size/strength, 2/3-finger tap undo/redo; mouse ZBrush map; Shift snaps views | `touch.odin`, `navigate.odin`, `device.odin` |
| Brushes | 14 kinds (Draw, Smooth, Clay, Flatten, Inflate, Pinch, Crease, Grab, Mask, Layer, Snake hook, Morph, Paint, Cloth), falloff curves, alphas, lazy mouse, pressure curve, tilt, drag-rectangle, stroke recorder, brush pie on Space | `sculpt/brush.odin`, `app/sculpt_tool.odin` |
| Geometry ops | Subdivision levels, HD windows, dyntopo, voxel remesh, decimate, retopo + UV + bake, project detail, live booleans, extract, slice/clip/hide, mirror/weld, curve + insert tools, cloth, sculpt layers, polypaint, polygroups, morph target | `sculpt/`, `geom/`, `app/` |
| History | Scene-wide `History` over per-level stroke undo plus swap snapshots for rebuilds; timeline scrub + time-lapse | `app/history.odin`, `app/timeline.odin` |
| Settings | Settings panel (Interface, Camera, Touch, Performance) + remembered brush/view state in a hand-written key-value file | `app/settings.odin`, `kit_settings.odin` |
| Tests | `odin test` on geom, camera, sculpt, jobs, gizmo, png_write, ui; 300-frame smoke under GPU validation; `touch_check.py` 36 scripted input scenarios | `build.sh test/smoke`, `scripts/` |

Strengths to keep: the hard separation (`ui` knows nothing of SDL or rendering; `camera`, `gizmo`, `geom`, `sculpt` are pure), the agent skills and lint gate, the scripted-input test harness, and a UI that is already cheaper per frame than ImGui was.

## 2. UX gaps found in our own app (measured against what 03-05 show the three products do)

| ID | Gap | Evidence in our code | Why it matters (see 07) |
|---|---|---|---|
| A-01 | **The Object tab is one long scroll of 18 folding sections** (Transform → Extract). Every geometry feature landed there. | `kit_object.odin:26-87` | Same failure as ZBrush's Tool palette (deep, flat, scroll-heavy). Nomad splits these across Topology / Scene / Layers / Material menus; 3DCoat across rooms. |
| A-02 | **No command registry.** Every shortcut is an `if key_pressed(...)` line; menus and inspector buttons call procs directly. | `shortcuts.odin` (hard-coded), `kit_menu`, `kit_object_menu` | Blocks: rebindable hotkeys (ZBrush Ctrl+Alt-click any button, 3DCoat hotkey on any item), a searchable command palette (ZBrush 2023+ has search), custom menus/pies, macros, scripting, and showing the shortcut next to every command. |
| A-03 | **Brush identity is scattered** in parallel tables: names and help text in `ui.odin`, icons in `new_ui.odin:312`, behaviour flags in `sculpt_tool.odin:242`, per-brush strength/falloff arrays in `Brush_Settings`, name parsing in `settings.odin`. Adding a brush touches 5-6 files. | `grep Snake_Hook` hits 6 files | No user brush presets (Nomad presets, ZBrush brush files, 3DCoat brush packs), no "duplicate and tweak a brush", no import/export of brushes. |
| A-04 | **Settings are serialised twice by hand**: a 58-case `switch` to read, 58 `fprintf` to write. | `settings.odin:32-240` | Drift between the two; each new remembered value costs two edits and is easy to forget. Use one field table (or Odin reflection over a tagged struct) for both directions. |
| A-05 | **~100 command-line flags mirror UI actions** for testing (`--remesh`, `--slice`, `--boolean`, `--curve` ...), each with its own start-up ordering rules ("after --retopo"). | `main.odin:24-130` `Options` | The flags are a second, unordered scripting language. With A-02 these become one `--run "remesh 200000; slice x; ..."` script over the same command registry the UI uses: fewer flags, ordering explicit, and the same path users would script. |
| A-06 | **`Ui_State` collects per-tool "last result" structs** (`mask_last`, `clip_last`, `smooth_last`, `retopo_last`, `bake_last`, `project_last` ...). | `ui.odin:15-50` | Each tool reports differently. A single result/toast channel (command → result {ms, changed, message}) gives consistent feedback and removes ~10 bespoke structs. |
| A-07 | **No search, no shortcut hints in menus, no first-run guidance.** The help is the README. | `kit_menu`, README | Discoverability is the weakest score for ZBrush and 3DCoat (06). Nomad's tooltips-on-long-press and ZBrush's Ctrl-hover help are the bar. |
| A-08 | **No custom layout / workspace.** One fixed layout (a deliberate Bolt decision: same UI everywhere). | `sm-store` rule, `kit_layout` | Keep the single layout; offer customisation inside it instead: pinnable brush dock slots, a user pie, a "favourites" row (Nomad's customisable shortcuts bar; ZBrush custom UI; 3DCoat custom rooms). |
| A-09 | **No scene hierarchy beyond a flat object list** (no folders/groups, no instance, no visibility-per-group). | `kit_scene.odin` | ZBrush folders of SubTools and Nomad's tree (groups, instances, repeaters) are how artists manage 50+ parts. |
| A-10 | **Gizmo is move-only**, rotate/scale through typed values. | `gizmo/`, `move_tool.odin` | ZBrush Gizmo 3D and Nomad's gizmo do move/rotate/scale with pivot editing in one handle; this is the core of blockout. |
| A-11 | **No selection tool other than mask/hide shapes**; polygroups exist but cannot be picked by tap to hide/isolate. | `mask_shape.odin`, `sculpt/groups.odin` | ZBrush's Ctrl+Shift-click a group to isolate is its single most-used visibility gesture. |
| A-12 | **No quick-access for masking modifiers on touch**: Ctrl/Shift/Alt only exist on keyboards. | `device.odin`, `touch.odin` | ZBrush for iPad and Nomad add on-screen modifier buttons (smooth, mask, invert toggles). Without them a tablet user cannot invert, smooth or mask mid-flow. |
| A-13 | **No onboarding or empty-state help**, no sample scenes. | – | Nomad's start scene and ZBrush's LightBox are what make first minutes productive. |
| A-14 | Tools and geometry ops have **no consistent "operation panel"** for parameters after running (redo-last with changed values). | each `kit_*_section` | Blender-style "adjust last operation" would let Remesh/Decimate/Retopo be tried without undo-and-redo cycles. |

## 3. Maintenance: what to rewrite, refactor or remove

Ranked by value for effort. "Rewrite" means replace the mechanism; "refactor" means move code without changing behaviour.

| ID | Change | Type | Effort | Value | Notes |
|---|---|---|---|---|---|
| A-20 | **Command registry** (`Command :: struct {id, label, help, icon, default_keys, run, enabled, checked}`) with every shortcut, menu row, pie slot and inspector button pointing at a command id | Rewrite of `shortcuts.odin`, menu code | M (≈600-900 lines touched) | Very high | Foundation for A-02, A-05, A-07, A-08, hotkey editor, command palette, macros, scripting. Needs an `sm-architect` design first (touches `Scene_Command`). |
| A-21 | **Brush descriptor table** (`Brush_Info{name, help, icon, flags, default strength/falloff/alpha}`) in `sculpt` or `app`, one row per kind, and a **brush preset** type layered on it | Refactor + small feature | S-M | High | Ends the 6-file edit per brush; enables user presets (A-03). |
| A-22 | **One settings schema** for load and save (table of `{key, ptr, kind, min, max}` or struct tags) | Rewrite of `settings.odin` | S | Medium | Removes ~250 lines of duplicated parse/print; version field for migrations. |
| A-23 | **Split the Object tab** by intent (see 10): *Shape* (levels, HD, dyntopo, remesh, decimate, mirror), *Select & hide* (mask, visibility, groups), *Surface* (layers, morph, paint), *Build* (booleans, extract, project, retopo/bake), each its own inspector page or context-sensitive panel | Refactor of `kit_object.odin` + `Kit_Section` | S | High | Pure UI move; sections are already separate procs. |
| A-24 | **Command scripts replace start-up flags** (`--run` with a tiny command language) | Rewrite of `Options` handling | M (after A-20) | Medium-high | Keep perf/diagnostic flags (`--vertices`, `--gpubench`, `--no-cull` ...); retire the ~50 that mirror tools. touch_check.py and benches switch to scripts. |
| A-25 | **Unified operation result + toast** (`Op_Result{ms, changed, message}` returned by every command) | Refactor | S | Medium | Replaces the `*_last` structs (A-06), feeds Stats and the History timeline labels. |
| A-26 | **Unit tests for `app` logic that does not need a window**: gesture classification in `touch.odin`, `navigate.odin` drag ownership, settings round-trip, history ordering | New tests | S-M | High | Today `app` is only covered by the smoke run and touch_check.py; the riskiest logic (input routing) is untested at unit level. |
| A-27 | **Split `main.odin` (1134 lines)**: options/start-up script, frame loop, exit stats | Refactor | S | Medium | Easier review; start-up order logic moves into the command script runner. |
| A-28 | **Move spikes out of `src/`** (`dart_trial`, `sdf_trial`) to `spikes/` or a branch | Housekeeping | XS | Low-medium | They are outside the build but read like product code to agents and reviewers. |
| A-29 | **Split the README** (492 lines, very long lines) into `docs/` pages per area with the README as an index | Docs | S | Medium | AGENTS.md says README is "the only document"; it has outgrown that. Keep one source of truth per feature. |
| A-30 | **Watch the two biggest sculpt files** (`dyntopo.odin` 1370, `brush.odin` 1299) | Refactor when next touched | S each | Medium | Split dab kernels per brush family (displace / smooth / grab-like / paint) to match A-21. |
| A-31 | Update stale project memory: `sculpt-new-ui.md` still lists ImGui "classic" panels that were removed in `200bec1` | Memory | XS | Low | Done in this thread. |

### Things that should NOT be rewritten

- The kit (`src/ui`): immediate mode, data-oriented and cheap (0.65 ms p50); extend it (focus navigation, text fields are already partly there) rather than replace it.
- The input routing model (one owner per touch, gesture arena): it is exactly the ZBrush for iPad model and passes 36 scripted scenarios. Tune it on a real tablet before changing it.
- The sculpt core, node split, partial redraw, idle cache: these are why we beat the perf targets.

## 4. Suggested order (feeds 12_Product_Roadmap)

1. A-28, A-31, A-22, A-21 (small, unblock presets).
2. A-20 command registry (design review first), then A-25, A-07 command palette + shortcut hints, A-02 hotkey editor.
3. A-23 Object tab split together with the IA in 08/10.
4. A-24 command scripts, A-26 app tests, A-27 main split.
5. Feature gaps A-10 gizmo, A-11 group isolate, A-12 touch modifier buttons, A-09 hierarchy, A-13 onboarding, A-14 adjust-last-operation.
