# Settings > Keys and mouse presets (UX roadmap phase 4, item 4): design

Base: odin-sculpt 8522b57 (PR #73). Roadmap row: "Settings ▸ Keys and buttons (search, reset per binding), navigation presets ZBrush/Blender/Maya — done when presets switch cleanly". Evidence C005 (3DCoat's key editor), N003 (Nomad's settings for gestures and buttons).

## What exists when done
- **A Keys tab in Settings**, between Touch and Performance. It has two parts.
- **MOUSE BUTTONS: "Mouse like" ZBrush | Blender | Maya.** The setting is `Nav_Prefs.mouse_scheme` and the default is ZBrush, which is today's mapping. Under the tabs, value rows say what each drag does in the chosen scheme: Turn the view, Pan and Zoom.

  | Drag | ZBrush (now) | Blender | Maya |
  |---|---|---|---|
  | Right | Turn | Turn | Turn |
  | Shift+Right, Alt+Right | Pan | Pan | Pan for Shift, Zoom for Alt |
  | Ctrl+Right | Zoom | Zoom | Zoom |
  | Middle | Pan | Turn | Pan |
  | Shift+Middle | Pan | Pan | Pan |
  | Ctrl+Middle | Zoom | Zoom | Zoom |
  | Alt+Middle | Pan | Turn | Pan |
  | Alt+Left (no Ctrl) | Turn | Turn | Turn |

  - The wheel, the right tap that opens the brush pie, left drags on empty space, the safe zone, fingers and the pen are untouched. Those stay in the Camera and Touch tabs.
  - Switching takes effect on the next press. A drag in progress keeps its owner, so "presets switch cleanly".
- **KEYS: a search field** ("Find a command or key"). Under it are rows for every command the palette lists, as commands only, in registry order, under the Help > Keys group captions (VIEW, OBJECT...). Each row shows the label and, on the right, its keys or "No key".
  - Keys the user changed are drawn in the accent colour.
  - A tap on a row opens the existing Assign key popover beside it. It covers listening, conflicts, Remove key and Reset (that is, reset per binding). This works for disabled commands too, since the row is not the command's control: it calls `bind_open` directly, not `command_run`.
  - Search matches the label, its search words (palette_match) or the key text: "ctrl+z" finds Undo, and "q" finds Pie 1 and anything on Q. With nothing typed, every row is listed.
  - The list is long (about 150 rows). It sits in Settings' existing scroll, and only the rows inside the visible band are laid out. The rest are spacers of the row height, so the frame cost does not grow with the list.
- **"Reset Keys settings"** (the tab's usual Reset button) runs `bind_reset_all` and sets the scheme back to ZBrush. "Reset everything" includes it.
- **Help > Keys, MOUSE group:** the Turn, Pan and Zoom rows follow the scheme (one row per scheme with `show`).
- **Remembered:** a `mouse_scheme <ZBrush|Blender|Maya>` SETTINGS row. Key changes are already saved as `key` lines, at once.
- **Palette:** the "Settings: Keys" entry comes for free. Its SETTINGS_SEARCH_WORDS are "shortcuts hotkeys keymap bindings mouse buttons navigation blender maya zbrush".

## Code
- **kit_settings.odin:**
  - `Settings_Tab.Keys` and its name;
  - `settings_keys(app)`;
  - a `settings_reset` case.
  - Check that five tabs fit in 368 points. If not, the tabs row lets "Performance" cut. I'll look at a screenshot and pick shorter names if needed.
- **New `src/app/kit_keys.odin`** (about 200 lines):
  - `keys_rows(app, query) -> []Palette_Entry` (pure, tested);
  - `keys_match(app, e, query) -> bool`, which compares the folded query against `command_chords` text with spaces removed;
  - `settings_keys` drawing.
  - Each row is a `ui.menu_item` with a new `keys_accent` param, or else a `value_row` button. Its id is `label##keys row N`.
- **navigate.odin:**
  - `Mouse_Scheme :: enum u8 {ZBrush, Blender, Maya}` in Nav_Prefs, with its default in NAV_DEFAULT.
  - `drag_decide`'s button part moves into a pure `mouse_button_owner(scheme, held: bit_set, ctrl, shift, alt) -> (Drag_Owner, decided: bool)`, which is tested over the table above.
- **kit_help.odin:** MOUSE rows per scheme.
- **settings.odin:** a SETTINGS row for mouse_scheme.
- **README:** Settings tab list (Keys), Controls (mouse presets), Help mention.
- **sm-ui skill:** a row on the Keys tab listing commands by itself.

## Tests
- **Unit:**
  - `mouse_button_owner` over every row of the table for the three schemes;
  - `keys_rows` for "", "ctrl+z" (Undo), "wire" (Wireframe), "q" (Pie 1), and a key the user moved (after bind_assign, its old command no longer matches it);
  - the settings round trip of mouse_scheme.
- **touch_check (desktop simulation):**
  - With `mouse_scheme Blender` in the settings file, a middle drag turns the view (yaw changes) and Shift+middle pans. With ZBrush, a middle drag pans (yaw unchanged).
  - Settings > Keys, then a tap on the Wireframe row (after typing "wire"), opens Assign key for Wireframe; K assigns it.
  - Reset Keys settings after an override gives `key_overrides=0`.
- **Screenshots:** the Keys tab at 1600×900 and 800×640.

## Not in this step
- Key presets (Blender or Maya keymaps for commands). The roadmap's "navigation presets" are the mouse.
- Gesture remapping is item 5.
- Pen button remapping: SDL reports the pen's side button as a right click, which stays the brush pie.
