# Help and gestures: cheat sheet and glossary from the data (UX roadmap phase 3): design

Base: odin-sculpt 7878356 (PR #63). Source: 12_Product_Roadmap.md phase 3 ("Help & gestures: glossary + cheat sheet generated from bindings", done when the cheat sheet regenerates from data); 08_Information_Architecture.md §6 (glossary); Nomad N022.
Problem: nothing in the app lists the keys or the touch gestures; README "Controls" is the only list, and it drifts from the code. Tablet users cannot find the gestures at all.

## What exists when done
- **Opening Help:** a Help window opens from Menu > Help, from F1 (new command `.Help`), and from the palette ("Help: Keys", "Help: Touch", "Help: Glossary").
- **Window layout:** it is a `Kit_Window` like Settings, 400 pt wide, top right, with tabs over a scrolling body. Its position is remembered, and Escape, Back and Close close it.
- **Keys tab:** generated from `DEFAULT_BINDINGS`.
  - Grouped by command group: File, Edit, Tools and brush, Object, Scene, View, App.
  - One row per command and argument, with every chord bound to it. For example, Redo shows "Ctrl+Shift+Z, Ctrl+Y", and each axis view is its own row.
  - Then a short fixed "Mouse" group: right drag orbits, Alt + left drag orbits, middle or Shift + right drag pans, the wheel zooms, Ctrl + drag masks, Shift + drag smooths, Ctrl + Shift + drag runs the "Hide, clip and slice" tool. These are not commands; the rows come from a `MOUSE_HELP` table.
- **Touch tab:** generated from the Touch settings as they are now, so a gesture that is off is not listed. Its rows are:
  - every command with a `command_gesture` (Undo, Redo, Focus, Frame all, size and strength, mask taps), with the command's label;
  - and a `TOUCH_HELP` table of the gestures that are not commands, each with a `when` proc on `Nav_Prefs`:
    - one finger on empty space turns the view;
    - two fingers pan, pinch and twist (each only when its setting is on);
    - the edge band turns the view;
    - lifting one of two fingers turns the view;
    - a double tap on the model pins the pivot;
    - holding two fingers still repeats undo;
    - a long press shows a control's name or its second action;
    - the modifier rail;
    - the pen, with palm rejection;
    - a right tap or Space opens the brush pie.
  - A footer line says "Change these in Settings > Touch", with a button that opens that tab.
- **Glossary tab:** a `GLOSSARY` table, as in 08 §6. Each row gives our word, the words other apps use, and what it means: Object, Group, Mask, Hide, Layer, Level, Remesh, Brush.
  - Ghost and Preset are left out until they exist.
  - The other apps' words are also added to `SEARCH_WORDS` where they are missing, so the palette and the glossary agree. A test checks that each glossary row's other names find its word in the palette.
- **Palette:** a new kind `.Help_Tab` with entries "Help: Keys", "Help: Touch" and "Help: Glossary" and synonyms ("shortcuts cheat sheet keyboard", "gestures fingers", "terms words").

## Code
- **New `src/app/kit_help.odin`, about 250 lines:**
  - the row builders `help_key_rows()` and `help_touch_rows(app)` as pure procs returning `[]Help_Row{group, what, how}` in temp memory, which the tests read;
  - `kit_help(app) -> raised`, the window, copying `kit_settings`' scroll structure;
  - the `MOUSE_HELP`, `TOUCH_HELP` and `GLOSSARY` tables;
  - `command_group(id)`, using enum ranges in a switch over `Command_Id`. A test checks that every command is in a group, so a new command placed outside the ranges fails.
- **Changes elsewhere:**
  - `Kit_Window.Help`, `KIT_WINDOW_ORDER`, kit_layout's loop, and the exit stats' window names (`help`). The settings `window` lines already loop over every Kit_Window.
  - Kit_State gains `help: bool`, `help_tab`, `help_scroll`.
  - The command `.Help` (F1, which nothing uses yet) and a Menu > Help row.
  - Escape and Back close Help after any popover, as Settings does.
- **Rows:** `ui.value_row(label, keys)` in each group, under `ui.caption` group headings. Glossary rows use a label plus a paragraph.

## Tests
- **Unit:**
  - every `DEFAULT_BINDINGS` row appears in `help_key_rows()`, with its chord text;
  - every command with a gesture under the default settings appears in `help_touch_rows()`;
  - with `tap_history` off, the Undo tap row is gone;
  - every command is in a group;
  - each glossary row's other names find the palette entry for its word.
- **touch_check (desktop simulation):**
  - F1 opens Help (`window_help` open);
  - Escape closes it;
  - a palette "glossary" + Enter opens the Glossary tab (stat `help_tab`);
  - a finger drags its body to scroll it (`help_scroll` > 0).
- **Screenshots:** each tab at 1600×900, and Keys at 820×640.

## Not in this step
- Rebinding.
- The gesture map editor (phase 4).
- First-run coach marks.
- Generating README "Controls" from the same tables. README stays hand-written, but its Controls section points to Help.

## Size
About 400 lines with tests. There is no History, Scene_Command, GPU or file-format change. The settings file only gains a `window help` line, through the existing loop.

## After the sm-architect review (built this way)
- Help and Settings share the inspector's place, one at a time (`side_panel_open`/`side_panel_close`); the inspector hides while either is open.
- The tab is "Gestures", not "Touch", so "touch" still finds Settings: Touch. No new palette kind: `.Help` is a command with a `Help_Tab` argument, so the palette lists "Help: Keys/Gestures/Glossary" by itself, with per-tab words (`HELP_SEARCH_WORDS`).
- One row shape, `Help_Line{group, what, how, command, arg, show: proc(^App) -> bool}`, for VIEWPORT_KEYS, MOUSE_HELP and TOUCH_HELP; command lines take their gesture from `command_gesture`, and a test fails any gesture missing from TOUCH_HELP. Mouse and touch rows corrected against navigate.odin, gated by the tool, the rail and the orbit style.
- `command_group` is a complete switch over enum ranges, which the compiler checks. `command_chords` lists every chord.
- Settings > Camera's hand-written mouse paragraph became a button to Help > Keys.
- Glossary rows name the commands the palette must find for the other apps' names (`searches`/`finds`); Layer and Brush have none.
- The scroll body, copied in the inspector and Settings, became `kit_scroll_begin/end`, used by all three.
