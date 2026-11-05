# Bind where you see it (UX roadmap phase 4, item 2): design

Base: odin-sculpt 0120a37 (PR #71). Sources: 12 roadmap Phase 4 row 2 ("Bind where you see it (hover + bind key; long press → Assign) with conflict prompt"; done when "conflicts resolved inline"). Findings Z071 (ZBrush: Ctrl+Alt+click a button to bind), Z152 (ZBrush for iPad: a conflict prompt), C004 (3DCoat: END over a control), and Blender's right-click > Assign Shortcut.

## What exists when done
- **Ctrl+Alt+click** (or Ctrl+Alt+tap with a keyboard attached) on any control that runs a registry command opens an **Assign key** popover beside that control, instead of running it. This covers every button, menu row, switch, tab, the tool bar, the dock's brush tiles, the brush browser and the palette's rows.
- The command palette's help line gets a small **Assign key** button for the picked row. A tablet with a keyboard reaches it without Ctrl+Alt+tap, and so does anyone who doesn't know the gesture. Each control's tooltip does not grow; Help > Keys and the README say how.
- **The popover:**
  - It shows the command's label (`command_label`) and "Now: Ctrl+D", or "No key".
  - It then listens with "Press a key, with Ctrl, Shift or Alt if you like". The next non-modifier key that goes down, with the modifiers held, is the candidate.
  - **Free:** assigned at once, and the line reads "Ctrl+D now runs Duplicate" with Done. The popover stays open, so a mistake can be redone by pressing another key.
  - **Taken by another command** (the conflict, resolved inline): "Ctrl+D runs Focus selected." with **Use it here** (the other command loses that chord) and **Keep it there** (nothing changes; listen again).
  - **Reserved:** S and U (the adjust drags), Space (the pie), Escape, Enter, Backspace, Tab (the inspector), the arrow keys and Android's Back are refused, with the reason ("Space opens the brush pie").
  - Bare modifier keys are ignored while listening.
  - **Remove key** gives the command no key. **Reset** goes back to the default chords and is enabled only when the command has an override.
  - Escape (reserved, so it never binds) or a press outside closes it. While it is open, no shortcut, S/U adjust or pie runs (`typing(app)` is true).
- **What an assignment means:** a command the user gives a key has exactly that one chord. Redo's Ctrl+Shift+Z and Ctrl+Y both give way to the new one. Commands with no override keep their default chords, minus any chord an override took.
- **Everywhere reads the effective keymap:** shortcuts (`commands_handle_keys`), tooltips and hints, menu rows, Help > Keys, the palette's key column and the panels' paragraphs.
- **Remembered** in settings.txt (no version bump) as `key <command name> <chord|none>` lines:
  - the name is `Duplicate` or `Brush:Clay`, as the palette's recents name commands, but resolved for every command, not only listed ones;
  - the chord is written "Ctrl+Shift+D", with modifiers first and then SDL's key name (so a "+" key reads "Ctrl++");
  - unknown or damaged lines are skipped, and so is a chord that is now reserved or already taken by an earlier line.
- **Exit stats:** `key_overrides=<n> bind_open=<0|1> bind_command=<slug> bind_state=<listening|assigned|taken|reserved>`.

## Code
- **New `src/app/keymap.odin`** (about 250 lines):
  - `Key_Override{command, arg, chord, none}`, with `MAX_KEY_OVERRIDES :: 64` as a fixed array plus count on `App`, so App stays a plain value for tests.
  - The effective bindings: `App.bindings: [MAX_BINDINGS]Binding` plus `binding_count` and `bindings_built`. `keymap(app) -> []Binding` builds them on first use from DEFAULT_BINDINGS and the overrides, so a zero `App` in tests has the defaults. `keymap_rebuild` runs after every change.
  - `bind_chord_owner(app, chord) -> (id, arg, ok)`, `bind_reserved(chord) -> (reason, bool)`, `bind_assign(app, id, arg, chord)` (which removes the chord from any other command's override and leaves defaults filtered by the rebuild), `bind_remove`, `bind_reset`.
  - `chord_parse(text) -> (Chord, bool)`, the inverse of `chord_text`.
  - `command_name` / `command_from_name`, shared with the palette's recents. `palette_entry_from_name` keeps its listed-only check on top.
- **`command_keys` and `command_chords` take the app:** 16 call sites plus tests.
- **Interception:** `command_run` gets one check. When `app.kit.laying_out` is set (only during kit_layout) and this frame's left release, or a tap, came with exactly Ctrl+Alt held, it calls `bind_open(app, id, arg, ctx.last_rect)` and returns false. Keys run after the layout, so a Ctrl+Alt chord bound by the user still runs normally. Commands run by the palette's Enter are keys, not clicks, so they run.
- **Popover:** `kit_bind_popover` (keymap.odin), with state `Kit_State.bind{open, id, arg, at, state, candidate, other_id, other_arg}`. It is added to `kit_floating` and the Escape list. Capture reads `app.device.keys` in the layout, before `commands_handle_keys`, which is skipped while it is open.
- **Settings:** the `key` lines (after the loop, in file order) and settings_save writing every override.
- **Docs:** README (Controls: rebinding, the popover, reserved keys, remembered); sm-ui skill rows (keymap, interception).

## Tests
- **Unit:**
  - a zero App has the defaults;
  - an override replaces all of a command's chords;
  - taking a chord removes it from the default owner and from another override;
  - reserved chords are refused;
  - Remove and Reset work;
  - `command_hint` and Help follow overrides;
  - the settings round trip works, including `Brush:Clay`, `none`, a `+` key and damaged lines;
  - `chord_parse(chord_text(c)) == c` for every default chord.
- **touch_check (desktop simulation):**
  - Ctrl+Alt click the View menu's Wireframe opens the popover (`bind_open=1`, `bind_command=Wireframe`) and does not toggle it. Pressing K assigns it; after Escape, K toggles wireframe and Shift+F does not.
  - Ctrl+Alt click Undo, then press Ctrl+S, gives `bind_state=taken`; Use it here moves it (`key_overrides=1`), and Ctrl+S now undoes.
  - Space is refused (`bind_state=reserved`).
  - The palette's Assign key button opens it for the picked row.
  - A settings file's `key` lines load.
- **Screenshots** of the popover listening, assigned and on a conflict, at 1600×900 and 800×640.

## Not in this step
- Settings > Keys and buttons (a searchable list of every binding, with reset per binding and reset all) and navigation presets: item 4.
- Gestures: item 5.
- Long press → Assign on touch: a long press already means each control's secondary action or tooltip, and a tablet without a keyboard has no key to bind. The palette's button covers a tablet with a keyboard.
- Binding the pen's buttons or a gamepad.
- Two chords for one command chosen by the user.

## Size
About 500 lines with tests. No History, Scene_Command, GPU or scene-file change. It adds one popover, settings lines, and a signature change to command_keys/command_chords.

## After the sm-architect review (applied)
- Only controls that can run now bind by Ctrl+Alt+click (a disabled widget takes no click); the palette's Assign key reaches every command, disabled ones too. Scenarios use the Inspector button, not Undo.
- The interception needs a widget click this frame: `ui.Context.clicked_now/clicked_rect` (set in `interact`), Ctrl and Alt without Shift, during `kit_layout` (`Kit_State.laying_out`); the popover anchors at the clicked widget's own rect. The palette's Enter (no click) still runs.
- `bind_open` closes what floats (palette included); the popover is in `kit_floating`, the Escape list and `typing(app)`, and is laid out last.
- Reserved: Space, Escape, Back, Enter, Backspace with any modifier; bare S and U; modifier and lock keys, AltGr, unknown; a press with Cmd/Windows held. Tab and the arrows are not reserved.
- `keymap(app)` returns DEFAULT_BINDINGS while there are no overrides (no lazy build); a command that loses its only key to another is saved as `none`, and the popover says "X has no key now". Override chords run after the defaults in a frame (README says so).
- settings `key` lines read the chord as the rest of the line (key names with spaces: "Num 1", "Page Up").
- Tests: effective keymap unique and unreserved after moves; Help reads keymap; "Ctrl+Num 1" round trip.
- Screenshots: shots/bind-*.png.
