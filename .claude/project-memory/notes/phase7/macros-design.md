# Phase 7 item 2: macros from the command log

Roadmap row: "Macro recording from the command log · Z106 · S". Blueprint §12: "every executed command (id + args) is appended to an in-memory log … Macros: save a range of the command log as a script, bind it like any command." Builds on item 1 (command scripts, `src/app/script.odin`).

## What exists when this is done

- **Recording.** Record macro (a command: palette, Menu > Macros, a key or pie like any other; checked while on) starts recording. A red "Recording macro" chip shows at the top of the viewport with a Stop button. Stop opens a small popover: a name field ("Macro 1" by default), Save and Discard. Save writes the macro and shows a note ("Saved macro Inflate and remesh: 4 steps; strokes and view changes are not recorded").
- **What is recorded.** Every command run through `command_run` while recording, by any route (key, button, menu, palette, pie, gesture, bar, a running macro), written as a script statement:
  - a command with choices by its choice's name (`brush clay`, `mask invert`);
  - a toggle as the state it left (`wireframe on`), so a replay sets it rather than flips it;
  - a command that reads panel values gets `set` lines for them first, with their values when it ran (Rebuild: `rebuild_goal` and the goal's count; Smooth all: `smooth_steps`, `smooth_strength`; Mirror and weld: `mirror_axis`, `mirror_negative`; Retopologize: `retopo_quads`; Extract: `extract_thickness`); a `set` is written only when it differs from the macro's last one;
  - commands scripts refuse (open, save, export, screenshot, rename, the palette, pies; `script_allows`) are left out and counted in the save note.
  Strokes, camera moves, gizmo and transform drags, slider drags that are not commands and object clicks are not commands and are not recorded; a macro works on whatever is selected when it runs. That is the useful meaning (ZBrush's macros also act on the current tool) and it is what the note says.
- **Macros are commands.** `Run_Macro` with 16 slots (as the user pies and selection sets have numbered slots, so a key or pie bound to slot 3 stays bound when another is deleted). Its label is "Macro: <name>", it is enabled when the slot holds a macro and no script is running, and the palette, keys (Ctrl+Alt+click, Settings > Keys), pies, starring and the gesture map take it as they take any command. A new macro takes the first free slot; with all 16 full, Save says so and keeps the popover open.
- **Running.** A macro runs through the script runner, in the frame loop, as a person's work rather than as set-up: each statement is its own undo step as if done by hand, nothing is cleared, and a statement that does nothing stops it with a warning note naming the line. A finished run shows "Ran macro <name>: N steps". `wait` works (frames pass with the interface live). While a macro runs, Record macro, Run macro and Run script are disabled.
- **Run script….** A command (palette, Menu > Macros) that opens a file dialog for a `.cmd` file and runs it the same way (a person's work, not set-up). A file with errors runs none of it and shows the first errors in a note.
- **Macros window** (Menu > Macros…): Record / Stop at the top, then a row per slot in use: name, its key if any, Run, Delete (asks once), Open folder on desktop. Rename is retyping the name in the row's field.
- **Files.** Each macro is a plain command script in the app's data folder, `macros/macro-NN.cmd` (NN the slot), first line `# Macro: <name>`; edit it in any text editor and it is read again at the next start. On Android the folder is app-private storage, no permission (`sm-store`).

## How

- `src/app/macros.odin` (new): `Command_Log_Entry {id, arg, toggle, values: [MAX_READS]f64}`, the log as a ring of the last 256 entries in `App`, `macro_log` called from `command_run` after `c.run` (only when the command ran), `Macro_State {recording, start, slots: [MACRO_SLOTS]Macro}` where `Macro {name, text}` (heap), `macro_text(log range) -> string` (the script), `macros_load` / `macro_save` / `macro_delete` (files, atomically written as `durable save` does), `kit_macros` (window), the chip and popover.
- `Command` gains `reads: []string`: the SETTINGS / SCRIPT_VALUES keys whose values the command's `run` reads. A test checks every key names a row. The log stores their values as `setting_parse` reads them, and `macro_text` writes them with `setting_text`.
- Commands: `Macro_Record` (checked while recording; running it while recording is Stop), `Run_Macro` (args = MACRO_SLOTS, `command_arg_name` the slot number from 1), `Run_Script`. All three join `script_allows`' refusals, so no script or macro starts another (no recursion, no recording a recording).
- `File_Kind.Run_Script`: the dialog's path goes to `file_apply`, which reads and parses the file and starts the runner.
- `script.odin`: `Script_Run` gains `setup: bool`. `script_finish` does the set-up work (History, autosave fingerprints, stats, camera history, events offset) only when `setup`; otherwise it reports "Ran …". `script_fail` on a non-set-up run stops with a warning note and keeps everything done before it. `script_load` takes text from memory (macro) or a file (Run script) as now, plus a `setup` flag; the start-up path passes `setup = true`.
- The runner already runs at frame start, after scene commands and file requests, applying what each statement queues in place; it needs no change to run mid-session. The frame loop's `setting_up` gate stays tied to `setup`, so `--frames` and benches are unaffected by an interactive macro.
- Undo: no History change. Each command records its own steps as it does when clicked; a macro of four commands is four undo steps, as ZBrush's are.

## Tests

- app: the log records a command with its choice, a toggle with its new state, a Rebuild with its goal and count; `macro_text` of a log range is the expected script and parses back clean; refused commands are left out and counted; a recorded macro run on the same start gives the same scene fingerprint as the commands run directly; `setup = false` keeps the History; every `reads` key is a row; Run_Macro/Record/Run_Script refused in scripts.
- touch_check: record (palette "record macro"), Ctrl+R, Wireframe on, a brush tile, stop, name, save; undo back; run the macro from the palette: same export as the direct run (`same_file`), undo_steps as by hand; the chip and popover on a narrow window; a key bound to the macro runs it.

## Split

- **7.2a** command log, `reads`, `macro_text`, `Macro_Record` with chip + Stop popover + save, `Run_Macro` slots, runner `setup` flag, files, palette entries. README section "Macros". About 450 lines.
- **7.2b** Macros window (rename, delete, run, key shown), `Run_Script` with its file dialog, the touch scenarios for both.

## Not in this item

Editing a macro inside the app (the file is plain text), conditionals or loops (item 6, plugins), recording strokes (the Stroke recorder does that and replays where they were drawn).

## Architect review (2026-10-26), adopted

Must (all adopted):
1. A log entry is pending until what the command queued has applied: confirmed where the frame (or `script_step`) applies the Scene_Command, with the toggle state read after the apply; dropped when it changed nothing or raised a warning.
2. `New_Scene` is refused in runs that are not set-up (it would empty the History), and never recorded.
3. Runner for mid-session runs: `script_load` unloads any earlier script first; macros load with `scripted = false`; `script_fail` and `script_finish` do the set-up work only when `setup`; `setting_up` in main.odin becomes `running && setup`, so events, frame counts, benches and the exit files are untouched by a macro.
4. Reads live in a `COMMAND_READS` table in macros.odin (a proc per command taking the arg, so `mask clear` writes no `set mask_steps`): mask_steps (mask blur/sharpen/grow/shrink), crease_degrees (group creases), paint_color line (fill), add_shape and add_size (Add object; `add_size` and `boolean_vertices` become SCRIPT_VALUES rows), boolean_vertices (Make boolean), rebuild values, smooth, mirror, retopo, extract. The `set` lines are captured as text when the command runs (the panel cannot change between the run and the apply at the next frame's start), via `setting_text` for rows and a `text` proc on Setting_Line.
5. Deleting a macro clears every key, pie slot, star and gesture bound to its slot; a slot is taken while its file exists, even if it does not parse; files go through `write_durably`.
6. Labels: `command_label` stays App-free ("Macro 3"); an App-aware `command_title(app, id, arg)` gives "Macro: <name>" to the palette, Settings > Keys, pies and menus; the palette and Keys list only the slots in use.
7. Macros take no `wait` (refused when a run is not set-up), so a macro finishes in the frame it starts; Run script (7.2b) settles the autosave before each statement.

Should (adopted): Undo/Redo are not recorded, and an Undo while recording drops the newest recorded entry if it undid that entry's step (entries keep the History depth they made); interface-only commands (Inspector, Settings, Help, Stats, Coach_Tips, Deformer page, Adjust_Last, Reduce_Motion, View_Axis, Focus, Frame_All, Reset_Camera, View_Back/Forward) are not recorded and not counted as left out, nor are routes (palette, pies); Hd_Toggle is recorded as `hd_sculpt` / `hd_leave`; Run macro is disabled while recording, while a stroke, drag or move is in progress (`pie_busy`), while a save waits and while a file dialog is open; macros print their own exit stats (`macros_run`, `macro_steps`), leaving `script_*` to the start-up script; a recording is a heap `[dynamic]`, not a ring; an Adjust last re-run amends the newest entry's `set` lines; sm-store: macros are user-made lists of built-in commands (nothing downloaded, no new behaviour), Run script on Android opens `content://` through SDL_IOFromFile, and README says the files are editable on desktop only; the "one undo step a command" claim gets its caveat (selection sets, presets are not undo steps).

Paths that bypass `command_run` (gizmo cycle by key, dock presets, selection-set add/subtract, double-tap focus, timeline scrub, deformer tabs) are documented as not recorded.

New split: **7.2a-i** runner `setup` flag and exits, New scene and `wait` refused outside set-up, the new SCRIPT_VALUES rows and Setting_Line text, tests. **7.2a-ii** log with pending entries, Record/Stop chip, slots and files, labels, palette and Keys, README, touch scenarios. **7.2b** Macros window (names, rename, delete, keys), Run script.
