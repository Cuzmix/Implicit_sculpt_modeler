# First-run coach marks (UX roadmap phase 3, P18): design

Base: odin-sculpt 1aec2c0 (PR #67). Sources: 09_Interaction_Patterns.md P18 ("first run shows three dismissible hints in place: Draw on the model, Drag empty space to turn, Two fingers to move and zoom"), 11 blueprint ("each dismissed by doing it"), 07 finding 6 ("skippable and replayable"). Starter scenes are a separate, later PR.

## What exists when done
- On an interactive run, until done or skipped, a small card floats at the top middle under the tool bar with one tip at a time, an icon, "1 of 3" and a Skip tips button:
  1. Draw: how to sculpt.
  2. Turn: how to turn the view.
  3. Move and zoom: how to pan and zoom.
- Each tip is dismissed by doing it. Doing a later one first counts too. The card moves on to the next tip only once the gesture has ended (no stroke, no drag held), cross-fading with the panel motion token. After the third it fades out for good.
- The wording follows the input in use (`app.device.pointer`: mouse, finger or pen) and the settings that change it:
  - Draw: mouse "Left drag on the model to sculpt"; pen "Draw on the model with the pen to sculpt"; finger "Draw on the model with a finger to sculpt", or with Settings > Touch "one finger on the model: Turn" the pen wording plus "a finger turns the view".
  - Turn: mouse "Left drag on empty space, or right drag anywhere, turns the view" (or with Empty drag = Tool for the mouse "Right drag, or Alt + left drag, turns the view"); finger "Drag empty space with one finger to turn the view"; pen as its empty-drag setting says.
  - Move and zoom: mouse "Middle drag moves the view, the wheel zooms"; finger and pen "Two fingers move the view; pinch to zoom" (each part only while its setting is on; with both off the step counts as done).
- The card hides (without counting anything) while a menu, the palette, the pie, Settings or Help is open, and dims to 0.35 during a stroke or a drag like the action bar.
- Replayable: Help > Gestures gets a "Show the first-run tips again" button, and the palette a command (`.Coach_Tips`, "Show the first-run tips"). Both clear the progress and close what is open so the card shows.
- Remembered: SETTINGS row `coach` (i32 bit mask of done steps, 0..7; 7 = finished or skipped). A first run has no settings file, so it shows them; a run with an older settings file that has no `coach` line shows them once too.
- Scripted runs (`--frames`, `--no-settings`) never show the card, so existing scenarios and dumps are unchanged. A new flag `--coach` shows it from the start in any run, for tests and screenshots.
- Exit stats: `coach=<mask> coach_step=<draw|turn|move|none>` (the tip shown last, none when hidden).

## How a step is detected
- **Draw:** `app.stroke.active` was seen true. A stroke only starts on the model, so this is "drew on the model".
- **Turn:** camera_apply_input applied an orbit (orbit_drag, or touch_orbit, the one-finger empty drag). A pivot change, a double tap's framing and keypad views do not count.
- **Move and zoom:** camera_apply_input applied a pan, a zoom, a pinch or a wheel turn.
- camera_apply_input sets `app.coach_seen` bits. coach_update, at the end of the interface frame, folds them into `k.coach` and advances the card once `drag.owner == .None && !stroke.active`.

## Code
- New `src/app/kit_coach.odin`, about 160 lines:
  - `Coach_Step` enum and the text proc `coach_text(app, step) -> (glyph, text)`;
  - `coach_update`, `kit_coach` (an anchored "coach" container at .Center .Start below the tool bar, with icon, text, a `ui.label` step count and a Light "Skip tips" button) and `coach_restart`.
- App: `coach_seen: bit_set[Coach_Step]`, `coach_force` (the flag). Kit_State: `coach: i32`.
- commands.odin: `.Coach_Tips` (group Help, no key). kit_help.odin: the Gestures tab's button. main.odin: the flag, exit stats; settings.odin: the row; README: Interface paragraph, Help, flags, remembered settings.

## Tests
- Unit: `coach_text` returns a different text for each pointer kind and follows Finger_Model and Empty_Drag; the mask only grows and the shown step is the first not done; `.Coach_Tips` resets it.
- touch_check (desktop simulation, with `--coach`):
  - a finger stroke on the model, then a finger drag on empty space, then a two-finger pinch: `coach=7 coach_step=none`, the card gone;
  - a tap on Skip tips: `coach=7`, and nothing sculpted;
  - the card's rect does not meet the tool bar, the inspector or the status (layout check at 1600×900 and 820×640).
- Screenshots: the first tip with a mouse at 1600×900, the second with a finger at 820×640.

## Not in this step
Starter scenes (Menu > New and Add object starters: the next PR), empty-state copy changes, the hallway test (needs people).

## Size
About 300 lines with tests; one settings row and one flag; no History, Scene_Command, GPU or file-format change.

## After the sm-architect review (applied)
- Detection: the Shift-snapped orbit (pointer_route) counts as Turn; mouse paths count only with a delta; two-finger pan and pinch count only past the slop (a two-finger undo tap does not), with a pinch weighed as fingers 150 pt apart.
- The card shows on interactive runs only (frames 0 and remembering), or with --coach; scripted runs with --settings-file never see it.
- It moves on only once nothing holds the view: no stroke, no drag, no finger down, no tap waiting.
- It hides under everything Escape closes first (new helper kit_floating, shared with the Escape chain), under Settings and Help, and with tools other than Sculpt.
- Placement: centred under the tool bar when that clears the inspector, otherwise centred in the room left of it, at most 420 pt wide, text wrapping.
- Wording: Android starts on finger words; finger Turn with "finger on the model turns" reads "anywhere"; pen with empty drag = Tool turns from the edges; a pen with no touch screen seen gets the mouse's move words.
- Exit stats: coach, coach_shown, coach_step.
