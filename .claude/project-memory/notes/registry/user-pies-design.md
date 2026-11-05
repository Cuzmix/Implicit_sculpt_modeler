# User pies and favourites (UX roadmap phase 4, item 3): design

Base: odin-sculpt 5523d8f (PR #72). Sources: 12 roadmap Phase 4 row 3 ("User pies (4 × 8 slots) and favourites"; done when "editable from palette ⋯"). Findings Z039 (ZBrush for iPad's custom Quick Menu), C008 (3DCoat's spacebar quick menu with slots), C099 (radial menus), Blender's Q Quick Favourites; 10_Redesign_Proposal (pie slots point at command ids).

## What exists when done
- **Four user pies of eight slots each.** Each slot holds a registry command (with its argument) or is empty.
  - They open with the commands `.Pie` 0..3 ("Pie 1" ... "Pie 4"). Pie 1 is on Q and Pie 2 on Shift+Q, as Blender's Q is Quick Favourites; Pies 3 and 4 have no key until given one with Assign key. All four are in the palette.
  - A pie opens at the pointer when it is over the viewport, else in the viewport's middle. It opens in tap mode: tap or click a slice to run it; the middle, Escape, a right tap or the same key again closes it.
  - It works just as the brush pie does (`app.ui.pie`, now with `which`: 0 for the brushes on Space, 1..4 for the user pies). Its slices show the command's icon and its label, cut to fit. A slice whose command can't run now is dimmed and does nothing. An empty slice reads "Empty", and the middle says how to fill it.
  - Defaults:
    - Pie 1 holds view and object commands: Focus selected, Frame all, Wireframe, Flat shading, Orthographic, Studio render, Remesh, Search.
    - Pie 2 holds the mask commands: Clear, Invert, Blur, Sharpen, Grow, Shrink, Show all, Invert hidden.
    - Pies 3 and 4 start empty.
- **Favourites:** up to 16 commands the user stars. With nothing typed, the palette lists them first (under a FAVOURITES caption), then the recents, then everything. A starred row shows a star.
- **The palette's help line** gets three icon buttons for the picked command, replacing #72's Assign key text button: **Favourite** (a star, lit when starred), **Put in a pie** and **Assign key**. Their names show on hover and on a long press. The design calls this the palette ⋯.
- **Put in a pie** closes the palette and opens the **pie editor** popover. It has four rows, PIE 1 · Q to PIE 4, each with eight slot tiles showing the icon and a short label, or "+" when empty.
  - A tap puts the command in that slot, replacing what was there.
  - A long press (or right-click) on a filled slot empties it.
  - Reset pies puts back the defaults above.
  - The editor without a command (from Settings > Interface > Edit pies) only empties and resets.
  - The popover is 8 × 64 + padding = 532 points wide and about 380 high, so it fits 800×640.
- **Remembered** in settings.txt: `pie <1-4> <slot 1-8> <command name|empty>` lines, written only for pies that differ from their defaults (the whole pie then), and `favourite <command name>` lines in order. Unknown commands are skipped.
- **Exit stats:** `pie_open=<0-4|-1> pie_hover=<slot|-1> favourites=<n> pie1=<slugs,comma separated>`.

## Code
- **New `src/app/user_pies.odin`** (about 250 lines):
  - `Pie_Slot{id: Command_Id, arg: int}` (`.None` = empty), `USER_PIES :: 4`, `PIE_SLOTS :: 8`, `PIE_DEFAULTS`.
  - `App.pies: [USER_PIES][PIE_SLOTS]Pie_Slot`, initialised in kit_init, or settings-only like the dock: `Kit_State.pies` alongside `dock`.
  - `App.favourites: [16]Pie_Slot` plus count, in Kit_State.
  - `pie_open_user(app, n)`, `favourite_toggle/has`, `pie_put/clear/reset`, and `kit_pie_editor`.
- **pie.odin:**
  - `Pie.which`;
  - `pie_slice(d, scale, n)` takes the slice count;
  - `pie_pick` runs `.Brush` for which = 0, else the slot's command (`command_run`, which skips a disabled one);
  - opening from a command sets `center` from `app.ui.viewport_mouse` or the viewport's middle.
- **overlay.odin `draw_pie`:** loops over the slices of `which`. A brush slice keeps its number and name; a user slice shows an icon (`ui.icon`) over a label cut with `text_fit` (exported as `ui.fit`), dimmed when disabled.
- **commands.odin:** `.Pie` (args 4, label "Pie N"), `.Pie_Editor` (no args, "Edit pies"), with DEFAULT_BINDINGS Q and Shift+Q, plus SEARCH_WORDS (quick menu, radial, favourites, spacebar menu).
- **palette.odin:** the FAVOURITES group in `palette_rank` (favourites first when the query is empty) and the three icon buttons.
- **Settings > Interface:** an "Edit pies" button (`command_button(.Pie_Editor)`).
- **Docs:** README (Pen and brush pie becomes "Pies"; Command palette favourites; Controls Q, Shift+Q; remembered); the sm-ui skill row; Help Keys picks up Q from the bindings.

## Tests
- **Unit:**
  - default pies resolve;
  - put, clear and reset;
  - favourites toggle, cap at 16 and order;
  - the palette ranks favourites first only with an empty query;
  - the settings round trip, including a pie partly emptied and damaged lines;
  - `pie_slice` with 8 slices.
- **touch_check (desktop simulation):**
  - Q over the viewport opens Pie 1 (`pie_open=1`); a tap on the Wireframe slice runs it (wireframe on) and closes it.
  - Shift+Q then Escape closes it with nothing run.
  - In the palette, star Wireframe; reopen it, and its first row is Wireframe (the favourites stat is 1).
  - From the palette, put Remesh in Pie 3 slot 1; Pie 3 opens with it.
  - A long press in the pie editor empties a slot.
  - A settings file's pie and favourite lines load.
- **Screenshots:** Pie 1 open, the pie editor, and the palette's three buttons, at 1600×900 and 800×640.

## Not in this step
- Presets in pies (a preset is no command yet).
- Hold-to-pick for the user pies' keys (Space's brush pie keeps it).
- Renaming pies.
- A favourites bar on screen (the dock and the action bar hold that place).

## Size
About 550 lines with tests. No History, Scene_Command, GPU or scene-file change. It adds two commands, settings lines and one popover, and changes the pie code and the palette help line.
