# Command palette (UX roadmap phase 3, first item): design

Base: odin-sculpt 40234e4 (PR #61). Source: 08_Information_Architecture.md §5; findings on discoverability (scorecard "find a command" 2/10).
Problem: about 70 commands live in menus, the inspector, the pie and keys; nothing lets you find one by name, and on a tablet with no keyboard there is no shortcut at all.

## What exists when done
- **Open:** Ctrl+K or `/` (new command `.Command_Palette`, bound to both), or a Search button (Lucide `search`, 0xe155) first in the top-right bar, for touch and the pen. The button shows "Ctrl+K" in its tooltip.
- **The popover:** below the Search button (`.Below_End`), 420 pt wide. It holds:
  - a text field that has the keys as soon as it opens, which turns on text input and a tablet's keyboard;
  - up to 8 result rows;
  - the highlighted row's help sentence;
  - "N more: keep typing" when results were cut.
- **Rows:** each is `ui.menu_item` with the label, icon, shortcut and checked state from the registry. A disabled command shows dimmed and does not run. A kit change adds a `highlight` parameter to `menu_item`, which draws the hover fill for the keyboard selection.
- **Keys while open:**
  - Up and Down move the highlight, wrapping.
  - Enter runs the highlighted row.
  - Escape closes (it joins kit_frame's "close what floats" list).
  - Typing filters.
  - The palette reads Up, Down and Enter from `app.device` keys, so `ui` gains no SDL. `commands_handle_keys` already stops while typing, so `/` typed in the field is text, not a shortcut.
- **Pointer:** a tap or click on a row runs it. A press outside closes the palette, as other popovers do.
- **After a run:** the palette closes, and the entry goes to the front of the recents.

## What is searched (`Palette_Entry`)
- Every `Command_Id` except None and `.Command_Palette`.
  - A command with args is listed once per arg, labelled by `command_label` (brushes "Clay brush", views "Front view", masks, paint, groups, Remesh/Decimate to sizes).
- Each Settings tab, as "Settings: Touch and pen", and so on. It opens Settings on that tab (kind `.Settings_Tab`).
  - Help topics come with the cheat sheet, the third item of this phase, as another kind.
- Words searched: the label, plus a `SEARCH_WORDS` table of synonyms and other names from other apps:
  - Remesh "dynamesh voxel"; Mask "freeze"; Group "polygroup"; Retopologize "zremesher quads retopo"; Add_Object "subtool primitive append"; Duplicate_Object "subtool copy"; Delete_Object "subtool remove";
  - Subdivide "divide smooth level"; Hd_* "hd geometry"; Decimate_To "decimation master reduce"; Mirror_Weld "symmetrize mirror";
  - Studio_Render "bpr render"; Screenshot "png capture"; Frame_All "fit zoom extents home"; Focus_Selected "frame zoom"; Ortho_Toggle "orthographic perspective";
  - Make_Boolean "live boolean subtract union"; Extract_Masked "extract shell"; Morph_* "morph target";
  - Undo "back"; Redo "forward"; Inspector "panel properties"; Stats "performance fps".
- The help sentence is not searched: it would match too much.

## Ranking: pure `palette_rank`, unit tested
- Matching is case-insensitive, ASCII-folded, on words split at spaces and punctuation. The query splits into words too.
- **Tiers, best first:**
  - 0: the label equals the query.
  - 1: the label starts with the query.
  - 2: every query word prefixes some label word ("inv mask" matches "Invert mask").
  - 3: every query word prefixes a label or synonym word ("dynamesh" matches Remesh).
  - 4: fuzzy: the query's letters appear in order in the label. The score is the number of gaps, then where the first letter falls ("wfr" matches "Wireframe").
- **Within a tier:** recent first (most recent best), then enabled before disabled, then the shorter label, then table order.
  - No map decides order, so the order is deterministic.
- **An empty query** lists the recents, then the rest in table order (File, Edit, Tools, ...), enabled first.

## Recents
- `Kit_State.palette_recent: [8]Palette_Entry` holds the most recent first.
- Remembered in settings.txt as one hand-written line: `palette_recent Remesh Brush:3 View_Axis:0 Settings_Tab:Touch`.
  - It is written by enum name, so a renamed or removed command is skipped on read and never misread as another.
  - The value is clamped to the command's args.
- Only interactive runs read or write it, as with every setting. No frequency count: recency covers it, and counts would need a decay rule.

## Code
- **New `src/app/palette.odin`, about 260 lines:**
  - `Palette_Entry{kind, id, arg}`;
  - `palette_entries`, built once into Kit_State at kit_init, about 110 entries;
  - `SEARCH_WORDS`;
  - `palette_rank(query, entries, recent, enabled_of) -> []Palette_Hit`, in temp memory;
  - `palette_run`;
  - `kit_palette(app, anchor)`.
- **Changes elsewhere:**
  - commands.odin: `.Command_Palette` and its two bindings;
  - new_ui.odin: the Search button, the call after kit_view_menu, and Escape;
  - widgets.odin: `menu_item(..., highlight := false)` and `text_field(..., focus := false)`, which gives the field the keys at once;
  - settings.odin: the recents line;
  - ICON_SEARCH.
- **Tests:**
  - **`palette_test.odin` (app):**
    - the tiers in order;
    - multi-word queries;
    - synonyms (dynamesh, freeze, polygroup, zremesher, subtool);
    - fuzzy gaps;
    - recents first within a tier;
    - disabled after enabled;
    - empty query order;
    - the recents line round trip, including unknown names.
  - **ui_test:**
    - `text_field` focus;
    - `menu_item` highlight drawing does not change its hit area.
  - **touch_check scenarios** (desktop simulation; key events already script):
    - `palette_ctrl_k_wire_enter_toggles_wireframe`: stat `wireframe=1`;
    - `palette_slash_opens_and_escape_closes`: stat `palette=0` and no command run;
    - `palette_arrow_down_picks_the_second`;
    - `palette_tap_search_button_and_row`: finger taps only, with the text field given by key events;
    - `palette_disabled_row_does_nothing`: Delete object with nothing selected;
    - `palette_slash_while_typing_stays_text`.
  - Typing in scenarios: `key:w`, `key:i`, ... reach the field as SDL text events only with text input on. If the scripted key path pushes no TEXT_INPUT event, a new event kind `text:STRING` pushes one.
  - New exit stats: `palette` (open 0/1) and `palette_runs` (commands run from it).
- **Docs:**
  - README Controls: Ctrl+K and `/`, and the Search button;
  - sm-ui: the recipe for adding search words when adding a command;
  - sm-touch-testing: the text event.

## Not in this step
- Gestures on each row (two-finger tap, and so on) come with the next item, "shortcut and gesture hints", which adds a gesture column to the registry that the palette, menus and tooltips all read.
- Brush presets do not exist yet. Settings rows by name ("Turn about") need the settings table to carry labels, which is the cheat sheet step.

## Size
About 450 lines with tests. No History, Scene_Command, GPU or file-format change.
