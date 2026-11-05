# Phase 7 item 1: command scripts (`--run`), retire the tool-mirroring flags

Roadmap row: "Command scripts (`--run`), retire tool-mirroring flags · A-24 · C050 · M · done when benches and touch_check use scripts". Blueprint §12: one command a line, run by `--run file` (later the palette), replacing the flags, so the tests drive exactly the path users would script.

## What exists when this is done

- `--run=FILE` runs a command script at start-up; `--script=TEXT` runs one given inline (the touch scenarios and tests use this; `;` separates statements). A script is checked whole before anything runs: a bad line refuses the run with `script: <where>:<line>: <message>` and exit code 2, never an assert.
- A statement is a registry command by name (`remesh_to 200000`, `brush clay`, `mask invert`, `view_axis front`), a remembered setting (`set orbit_style turntable`, `set radius_px 80`), or one of a few script verbs (`wait 3`, `select 2`, `rotate 0,45,0`). Everything a statement does goes through the same procedures the interface calls (command_run, the settings table, object_remesh...).
- About 55 start-up flags that mirror tools are gone (list below); the ones that set up a measurement or the environment stay. `scripts/touch_check.py`, `gate.py` and the benches use `--script`.
- README gets a "Command scripts" section listing the statements; the flags paragraph shrinks.

## Language

```
# A comment runs to the end of the line.
statement := name { argument }              (one a line, or `;` between them)
argument  := word | number | "quoted text" | number,number[,number] | key=value
```

Names are the registry's `Command_Id` in snake_case, matched case-insensitively with `-` and `_` the same (`Remesh_To`, `remesh-to`, `remesh_to`). This is the same name `settings.txt` uses for key bindings (`command_name`), lowercased, so one spelling covers keymaps, macros (item 2) and scripts.

### 1. Commands

`<command>` runs a command that takes no argument; `<command> <choice>` one that does, the choice by its name as `command_arg_name` gives it (`brush clay`, `view_axis front`, `deformer lattice`) or by number from 0. A command that is disabled when its turn comes (`enabled` false) is a run-time error (below). `Remesh_To` and `Decimate_To` take a vertex count, as their keymap form already does, but exactly rather than the nearest preset (see Values).

### 2. Values

Some commands need a number the registry's `args: int` cannot carry (a remesh of 200,000 vertices, Smooth all 5 steps). The registry gets one optional field:

```odin
Command :: struct {
	...
	value: Command_Value, // a number the command can take in place of a choice, for scripts and macros
}
Command_Value :: struct {
	run:    proc(app: ^App, v: f64) -> bool, // nil: takes none
	lo, hi: f64,
	name:   string, // what it is, for errors: "vertices", "steps"
}
```

Given to: `Remesh_To` (vertices), `Decimate_To` (vertices), `Smooth_All` (steps), `Subdivide` (times), `Retopologize` (quads), `Extract_Masked` (thickness), `Level_Up`/`Level_Down`? no: a new `Level` value command (`level 1`). Each `run` calls what the command's own run does with the value instead of the preset.

### 3. Settings

`set <key> <value>` writes a `SETTINGS` row (settings.odin) through the same parse-and-clamp the file reader uses (one shared `setting_parse`), so a script and `settings.txt` cannot disagree. Enums by name, bools as on/off/true/false/1/0. Settings that are not table rows but have flags today (brush, material, symmetry, falloff, alpha, paint colour, cloth mode, studio samples, HD window, detail) become rows or script verbs, whichever already fits: per-brush values (falloff, alpha) are verbs on the held brush.

### 4. Script verbs

For what is neither a command nor a setting today. Each is a short procedure in `script.odin` calling the existing code:

| Verb | Replaces | Does |
|---|---|---|
| `wait N` | – | lets N frames pass (queued scene commands and files apply, the view draws) |
| `select N` | – | selects object N (from 1, scene order) |
| `rotate X,Y,Z` | `--rotate` | turns the selected object, as Transform does |
| `mirror [-]x\|y\|z` | `--mirror` | Mirror and weld |
| `slice x\|y\|z`, `hide [-]x\|y\|z` | `--slice`, `--hide` | the plane through the bounds' middle, as the flags do |
| `groups creases\|visible\|masked` | `--groups` | |
| `boolean union\|subtract\|intersect` | `--boolean` | marks and overlaps every object but the first |
| `curve tube\|stitches\|zipper`, `insert <shape>` | `--curve`, `--insert` | across / at the middle of the view |
| `project` | `--project` | first object's detail onto the selected |
| `paint_color R,G,B`, `falloff <preset>`, `alpha <name\|file> [mode] [angle]`, `material <name>`, `symmetry xz`, `cloth <mode>`, `studio [samples]` | the flags of those names | |
| `shape <primitive>` | `--shape` | replaces the starting spheres |
| `hd N`, `hd_open` | `--hd`, `--hd-open` | |

Commands that exist already cover the rest: `subdivide`, `level`, `dyntopo_toggle`, `morph_store`, `layer`... (a `New_Layer` command is added if missing), `fill`: `paint fill`, `make_boolean`, `ortho_toggle`, `flat_shading`, `wireframe`, `polygroups`, `studio_render`, `reduce_motion`, `front_only`, `lock_plane`, `connected`.

### 5. When statements run

Start-up flags today run synchronously in a fixed order before the first frame. Scripts run at the start of frames, where `Scene_Command`s and file requests already apply: the runner runs statements one after another in the same frame until one queues work that applies next frame (a scene command, a file request, `wait`), then yields. A script of plain commands therefore finishes before the first frame draws, as the flags did.

`--frames` and the frame numbers of `--ui-events` count from the frame the script finishes, so a scenario's events are where it put them however many frames its script took. (Without `--run`/`--script` nothing changes.)

### 6. Errors

- Parse time (whole script, before any statement runs): unknown name, wrong argument count or kind, a choice not among the command's, a value out of `lo..hi`, an unknown setting or enum value. Exit 2 with every error listed (at most 20).
- Run time: a disabled command, an operation that refuses (`object_remesh` false, nothing selected). Scripted runs (with `--frames`) exit 2 with `script: <where>:<line>: <command> did nothing: <reason>`; an interactive run shows it as a warning note and stops the script.
- The exit stats gain `script_statements=N script_frames=N`.

### 7. Flags kept and retired

Kept (measurement, environment, files on exit, test drivers): frames, no_settings, settings_file, gpu_debug, subdiv, vertices, spheres, threads, width, height, no_cache, no_cull, no_partial, no_simplify, no_vsync, time_gpu, orbit, ui_dt, ui_events, coach, dump_screen, dump_viewport, check_mesh, bench_* (stroke, samples, lifts, loops, tilt), gpubench, gpubench_frames, compute_bench, open, import, export, save, bake, bake_size, autosave*, check_autosave, crash_after_autosave, bench_after_autosave, timelapse*, load_strokes, replay_shift, instant_replay, record_strokes, save_strokes, density_preview (a held-slider state no command has), gpu_smooth (a trial switch), plus `run`, `script`.

Retired (≈55): orbit_style, orbit_pivot, flat_ring, no_edge_orbit, reduce_motion, shape_apply, finger_orbits, shape, subdivide, level, hd, hd_open, hd_window, brush, cloth, stroke, front_only, lock_plane, connected, stroke_line, stroke_join, symmetry, material, studio, studio_samples, flat, ortho, view, wireframe, falloff, rotate, mirror, slice, hide, store_morph, decimate, remesh, dyntopo, detail, tilt_strength, alpha, alpha_mode, alpha_angle, smooth_all, groups, show_groups, paint_color, fill_paint, layer, retopo, boolean, live_boolean, make_boolean, extract, project, curve, insert.

One trap: `--subdivide`, `--level` and `--hd` apply to every starting sphere (`--spheres=N`); as statements they apply to the selected object. Scenarios that need several subdivided spheres use `select` in a loop, or the gpubench keeps its own set-up (it does not use the flags).

## Split

- **7.1a** Runner and language: `src/app/script.odin` (parse into `[]Script_Statement` with line numbers, run at frame start, yield rules, errors), `--run`/`--script`, the frame offset, `Command_Value` on the six commands, `set` over a shared `setting_parse`, verbs `wait` and `select`; app tests (parse errors, each statement kind, the yield, a remesh by value equals `object_remesh` directly) and one touch scenario that uses `--script`. README section. No flag removed yet.
- **7.1b** The verbs of §4, the flags of §7 retired, `touch_check.py`, `gate.py`, `build.sh`/`build.bat` bench lines and the sm-build, sm-touch-testing, sm-sculpt mentions moved to scripts; README flags paragraph rewritten. One commit per group of flags so the gate stays green at each.

## Not in this item

The command log and macros (item 2), the palette's "Run script..." (item 2, with macros), plugins (item 6).

## Architect review (2026-10-26), adopted

Must (all adopted):
1. A start-up script is set-up: when it ends, the History is cleared, `adjustable` reset, autosave's clean fingerprint and `saved_fp` taken of the scene as it stands, and `app.stats` reset; so `undo_steps` checks, autosave and New scene behave as with the flags.
2. One frame origin: `--frames`, `--ui-events`, `bench_frame`, `--load-strokes` and `--timelapse` all count from the frame the script ends.
3. The runner applies its own queued work in place (`scene_run`, `file_take` after each statement); only `wait` takes frames. The script starts once the viewport has its size (first `kit_frame`), so view-dependent statements see a real view.
4. (Folded into 3.)
5. The parsed script lives in heap memory (mesh operations `free_all` the temp allocator).
6. Choices by name only, never by number.

Should (adopted):
7. No `Command_Value`. Values go through `set` on the panel fields the commands already read: a script-only table (`SCRIPT_VALUES`, the same `Setting` rows, never saved) for smooth steps, mirror axis/side, extract thickness, HD window, live boolean...; `set rebuild_even 500000; rebuild` is the remesh. `Level` becomes a choice command named 1..N.
8. `setting_parse` is strict and side-effect free (bools on/off/true/false/1/0, numbers in range, enums by name); the file reader keeps its lenient read through the same rows.
9. Reuse: `group creases` exists; the hand-written settings lines that scripts need (brush, symmetry, paint_color, material) move out of `settings_load` into one table both use. Verbs that would share a SETTINGS key get other names (`draw_curve`, `insert_middle`).
10. Toggles take `on`/`off`: a command with `checked` and no choices runs only when the state differs.
11. "Did nothing" is concrete: `scene_apply` returns whether it changed the scene; a disabled command or an unchanged scene is a run-time error.
12. The exit code comes back from `run()`; `os.exit` after the leak report, never from inside.

Kept as scene construction (with `--vertices`, `--spheres`): `--shape`, `--subdivide`, `--level`, `--hd` (they apply to every object, opened scenes too, and build 10M-40M scenes in one upload). Translations of `objects[0]` flags start with `select 1`.

New split: **7.1a-i** parse, validate, `set` (pure, unit-tested, no frame loop); **7.1a-ii** the runner, the frame origin, the set-up rule, `--run`/`--script`, one touch scenario compared bit for bit with the flag run (`--export` + `same_file`); **7.1b** verbs and flag retirement, each group compared flag-run vs script-run before the flag goes.

## As built in 7.1b (2026-10-26)

- 7.1b-1 (PR #109): 42 flags retired; each group compared flag run against script run (exported PLY, saved `.sculpt`, settings file) and bit-identical. `New_Layer` command added.
- 7.1b-2: verbs act on the selected object, not "the first", so they compose with `select`: `move X Y Z`, `rotate X Y Z` (through the Transform panel's undo path), `boolean <mode>` (marks only; the overlap is a `move`), `slice`, `hide [-]axis`, `mask_rect L T R B` (view fractions from the top left; replaces the extract flag's hidden "mask the top third", so extraction is `mask_rect ...; extract_masked`), `project N` (from object N), `draw_curve`, `insert_middle`, `falloff`, `alpha`. Curve and insert use the laid-out viewport size, not the requested window size, so their meshes differ slightly from the old flags'; a slice made by script no longer reframes the start-up camera. Everything else matched bit for bit.
