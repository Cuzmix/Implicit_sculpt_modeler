# Gesture map (UX roadmap phase 4, item 5): design

Base: odin-sculpt 6a792bd (PR #74). Roadmap row: "Gesture map editor with conflict detection — done when conflicts never silent". Evidence N003 (Nomad's gesture settings).

## What exists when done
- **Settings > Touch > GESTURE MAP** replaces the switches "Tap two fingers to undo" and "Hold two fingers to keep undoing". It has seven rows, each a select of what the gesture runs: Nothing, or one of about 30 commands that make sense without a keyboard.

  | Gesture | Default |
  |---|---|
  | Two-finger tap | Undo |
  | Three-finger tap | Redo |
  | Four-finger tap | Nothing |
  | Hold two fingers | Undo |
  | Hold three fingers | Redo |
  | Hold four fingers | Nothing |
  | Pen side button | Brush pie |

  - The commands to choose from are: Undo, Redo, Brush pie, Pie 1-4, Search, Inspector, Settings, Help, Stats, Frame all, Focus selected, Reset camera, Orthographic, Wireframe, Flat shading, Studio render, Screenshot, Symmetry X, Mask invert/clear/blur/grow, Show all, Invert hidden, Move tool and Sculpt tool.
- **A hold** fills its ring, then runs its command. Undo and Redo repeat while the fingers stay still, as now. Any other command runs once.
- **The pen side button** is a right click from the pen. It runs its command when it isn't the brush pie. The mouse's right click stays the brush pie.
- **New command `.Brush_Pie`** opens the brush pie at the pointer, or in the window's middle, in tap mode. It is in the palette and can go in a user pie.
- **Conflicts are never silent.** Under the map, notes in the warning colour say:
  1. What a four-finger gesture may be taken by the system: some tablets keep three- and four-finger touches (Windows' touch gestures, some Android skins). If it does nothing, turn the system's off.
  2. That with the pen side button on something else, the brush pie is reached by Space, the mouse's right click, Search or a pie.
  3. That a hold of a command other than Undo or Redo runs it once.
  4. That a command on two gestures shows on both.
  5. That a hold and "Lift one of two fingers to turn" share two still fingers: lifting one before the ring fills turns, and holding runs the command.

  A select never lets one gesture hold two commands, so there is no collision to resolve, only these overlaps to state.
- **Hints and Help:** command_gesture builds a command's gesture text from the map. "Two-finger tap, hold to repeat" stays for Undo, and Wireframe on a four-finger tap shows "Four-finger tap" in its tooltip, the palette and Help > Gestures. The brush pie's pen line follows the map.
- **Remembered:** `gesture <Slot> <command|none>` lines for slots that differ from the defaults. The old `tap_history 0` and `hold_history 0` lines still read, emptying the taps or the holds. The Touch tab's Reset puts the defaults back.

## Code
- **New `src/app/gesture_map.odin`** (about 180 lines):
  - `Gesture_Slot`, `GESTURE_NAMES`, `GESTURE_DEFAULTS`, `GESTURE_CHOICES`;
  - `gesture_run`, `gesture_repeats`, `gesture_text`, `gesture_notes`, `settings_gesture_map`.
- **navigate.odin:**
  - Nav_Prefs: `gestures: [Gesture_Slot]Pie_Slot` replaces `tap_history` and `hold_history`;
  - NAV_DEFAULT.
- **touch.odin:**
  - taps: `gesture_run` for 2, 3 and 4 or more fingers;
  - `touch_hold_history`: up to four fingers, any command, repeating only Undo and Redo.
- **pie.odin:** the pen's right tap runs the Pen_Button slot unless that slot is the brush pie. `pie_toggle_user` becomes `pie_toggle(app, which)`.
- **commands.odin:**
  - `.Brush_Pie`;
  - command_gesture joins `gesture_text` with its built-in cases.
- **Settings and help:**
  - settings.odin: `gesture` lines and the legacy lines;
  - kit_settings.odin: the map in Touch, and its reset;
  - kit_help.odin: the pen line's `show`, and rows for mapped commands that TOUCH_HELP does not list.
- **--ui-events:** `pright` (the pen's side button) for the scenario.

## Tests
- **Unit:**
  - gesture_text for the defaults and for Wireframe on a four-finger tap;
  - settings round trip, including the legacy lines;
  - the commands_test and help_test expectations, moved from switches to the map.
- **touch_check:**
  - a four-finger tap with Wireframe mapped turns wireframe on;
  - a two-finger hold mapped to Wireframe runs it once;
  - the pen side button mapped to Pie 1 opens Pie 1, and by default opens the brush pie;
  - the existing undo/redo tap and hold scenarios stay green.
