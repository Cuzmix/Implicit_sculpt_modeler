# Operation results and Undo toasts: design (workstream 1, step 3)

Base: odin-sculpt 7c82df3 (registry PRs #50, #51 merged). Audit item A-25: one channel for what an operation did, which drives a toast (with Undo when it left an undo step), the section's "Last: …" line and nothing else; all `*_last` structs go.

## What exists
- `app.file_note: File_Note{text (owned), warning, at}` set by `file_note(app, warning, format, args)` from files.odin and alphas.odin (~30 calls). `kit_frame` shows a new note (`at` changed) as `ui.toast`. Nothing else reads it.
- Seven typed "last" structs in `app.ui` (ui.odin): `mask_last`, `clip_last`, `hide_last` (Mask_Done, Clip_Done), `smooth_last` (Smooth_Done, with the GPU timing), `retopo_last`, `project_last`, `bake_last`. Each is written by its operation and read only by one paragraph in its inspector section ("Last: Blur, 3 steps in 12 ms.").
- Destructive scene commands (Delete, Remesh, Decimate, Retopo, Symmetrize, Slice, Boolean, Extract, Delete higher/lower levels) give no feedback beyond the log; undo is only Ctrl+Z or the top bar button.
- `ui.toast` has no action.

## Design

### Kit (src/ui) — done in the branch
`toast(ctx, message, kind, action := "") -> Id` returns the toast's serial. With an action the toast draws a divider and the action in the accent colour at its right end, lives 6 s instead of 3.2 s, and the action's hit area is `hit_area` (48 pt). A press on it sets `ctx.toast_acted` and dismisses the toast; `toast_take_action(ctx) -> Id` returns and clears it. Test `a_toast_action_is_taken_once`.

### App: `results.odin` (new, package main)
```odin
Op_Result :: struct {
	text:    string,     // owned: one line, past tense, with how long it took
	detail:  string,     // owned: more for the section that ran it (the GPU's split), or ""
	from:    Command_Id, // the command it came from, so its section can show it; None for file notes
	flags:   Report_Flags,
	undo:    int,        // with Undo offered: len(app.history.done) just after it; else 0
	at:      time.Tick,
}
Report_Flag  :: enum u8 {Warning, Quiet, Undo} // Quiet: no toast (the change shows by itself)
Report_Flags :: bit_set[Report_Flag; u8]

report        :: proc(app: ^App, from: Command_Id, flags: Report_Flags, format: string, args: ..any)
report_detail :: proc(app: ^App, format: string, args: ..any) // on the result just reported
result_for    :: proc(app: ^App, from: ..Command_Id) -> (Op_Result, bool) // the section's "Last" line
results_destroy :: proc(app: ^App)
```
`app.file_note` becomes `app.result: Op_Result`; `file_note(app, w, …)` calls become `report(app, .None, {.Warning} or {}, …)`. `.Undo` in flags sets `undo = len(app.history.done)` (call it right after the history step is recorded).

Scene commands: the main loop calls `scene_run(app, cmd)` instead of `scene_apply`: it notes `len(history.done)`, the time and the selected object's label, runs `scene_apply` unchanged, and for the destructive kinds above, when the history grew, reports a default line ("Deleted Sphere 2", "Remeshed Sphere 1 to 1,002,113 vertices in 312 ms") unless the operation reported during the call (Retopo does, with quads and charts), then sets `undo` to the new history length. No `Scene_Command` change, no History change.

Who reports what:
| Operation | Toast | Undo | Section line |
|---|---|---|---|
| Delete, Remesh, Decimate, Retopo, Mirror and weld, Slice, Boolean, Extract, Delete higher/lower levels | yes | yes | Retopo, Slice show theirs |
| Smooth all | yes | yes | Deformation, with GPU detail |
| Project detail, Bake | yes | yes when recorded | their sections |
| Mask commands and shapes, mask group, hide shapes, isolate group, Clip | no (Quiet) | — | Mask / Visibility |
| File notes (open, save, import, export, screenshot, alpha) | yes, as today | — | — |

Undo from the toast: kit_frame keeps `{serial, undo}` of the last toast that offered Undo. When `toast_take_action` returns that serial and `len(app.history.done) == undo` (nothing done or undone since), it runs `command_run(app, .Undo)`; otherwise it does nothing (the toast was stale; the history moved on). Pressing Undo in a toast is exactly Ctrl+Z, so chained steps (Slice's two objects) undo together as today.

### Stats
The Advanced stats list gains "Last operation" with the result text, so timings that were only in a section stay one glance away.

## Behaviour changes
1. Toasts after the destructive operations above, with Undo. Masking, hiding and clipping stay silent (they show by themselves; a toast per drag would be noise).
2. The sections' "Last: …" paragraphs show only the latest result, and only if it came from that section (today each kept its own forever). The Slice timing paragraph reads `app.stats` and stays.

## Ownership, threading, failure
`app.result` strings are heap-owned, freed on the next report and in `results_destroy` (app teardown). Main thread only. A report while a toast with Undo is showing replaces the stored `{serial, undo}` only if it offers Undo itself.

## Tests
- ui: `a_toast_action_is_taken_once`.
- app: `report` copies and frees text, `.Undo` stores the history length, `result_for` matches only its commands; `scene_report_line` messages for each destructive kind (pure function of kind, label, counts, ms).
- touch_check: scenario `toast_undo_after_delete`: add, delete via Del, click the toast's Undo, check the object count is back (via the existing dump/stat hooks).
- smoke, check, wincheck, androidcheck.

Size: ~350 lines including tests; most of it moves existing lines.

## After the sm-architect review (applied)
1. Undo is tied to the step by `Undo_Mark{id, at}` (the newest entry's object and time), not a count: forgetting strokes, trimming, undo then a new step all handled (`undo_marks_follow_the_step_not_the_count`).
2. `scene_run` finishes any stroke first and reports only when the newest entry is a swap made during the call (`swap_since`).
3. Boolean names its base (`boolean_base`), not the selected cutter.
4. Results are keyed by inspector section (`Maybe(Kit_Section)`), not Command_Id, so gestures (mask/hide shapes, clip, slice) have a home; file notes have none.
5. A stale Undo is taken off the toast (`ui.toast_drop_action`) once its step is no longer newest.
6. Toasts stay inside the window, 16 pt in; the message is cut with "...", the action never.
7. README and the sm-ui skill updated; touch_check gains toast_undo_after_delete and toast_undo_goes_stale.
Not done (follow-up): refusal paths (Remesh on an open mesh, Boolean without a base...) still only log a warning; they could report `.Warning` so a tablet user sees why nothing happened.
