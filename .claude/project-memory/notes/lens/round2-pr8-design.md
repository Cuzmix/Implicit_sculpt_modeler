# Round 2, PR 8: Focus, Menu and Search (design)

Screens `focus2`, `menu2` and `search2` of the approved round 2 mock. Lens chrome only; Classic draws what it drew.

## What exists when this is done

- **Focus in Lens.** A layout that hides the view bar (the built-in Focus workspace hides the brush bar, the view bar and the action bar) is "focused" in Lens (`lens_focus`). The top bar is then three floating islands instead of the glass band:
  - left: Menu, Undo, Redo;
  - centre: the workspace chip ("Focus ⌄", which opens the switcher's menu) and the Symmetry X chip (lit while X symmetry is on; a tap toggles it);
  - right: Search (icon), View layout, Passes, History.
  The view chips, the object chip and the view rail do not show. The off-hand island (Size and Strength) and the dial stay: they are what a sculptor reaches for with the other hand while focused. The shelf shows at most seven tiles and All, without the page names under it.
- **The Lens menu** (`kit_menu_lens`), the mock's list: Home; New ›; Open…; Open recent ›; Save; Save as…; Save a copy…; Earlier saves…; Import ›; Export ›; Screenshot; Turntable video…; 3D print…; Workspaces ›; Customise…; Settings; Help and shortcuts; More ›. Rows that open a submenu carry a chevron; a tap (or, with a mouse, resting on the row) opens the submenu to the row's right, mirrored for left-handed. Submenus:
  - New: the starter shapes and each content pack's meshes, armed the same way as today (a first tap on a scene with work asks "Discard?").
  - Open recent: the recent scenes (up to eight) with when each was saved, then Open last autosave. A missing file says so and leaves Recent; a scene with work to lose arms first, as Home's tiles do.
  - Import: Import mesh…, Get from Blender (desktop builds with the link), Import workspace…
  - Export: Export mesh…, Transparent screenshot, Send to Blender, Export workspace…
  - Workspaces: each workspace (ticked when current) and Workspace options…, which opens the switcher's menu.
  - More: Stats, Macros, Library, Reduce motion.
- **The Lens search** (`kit_palette` in Lens): wider (520), centred under the top bar, grouped while something is typed into COMMANDS, BRUSHES and PANELS AND SETTINGS (rank kept inside each group). Each row has two lines: the name, and where it lives ("Object palette › Mask", "Shelf · Sculpt", "View rail", "Menu › Export", "Top bar", "Settings", "Panel · Layers card"). The picked row carries its shortcut and a "Put on a bar" button. The footer reads "↵ run · Tab show where it lives · Ctrl ↵ put on a bar", with Star, Put in a pie and Assign key as icon buttons at its right, so nothing Classic's palette offers is lost.
  - New entries: the tray's sections (`Palette_Kind.Section`), found by name ("Layers", "Remesh", "Lights"): running one opens the tray on it (in Lens the stack card that holds it).
  - Tab (as well as Shift+Enter, a long press and a right click) shows where it lives; Ctrl+Enter puts the pick on a bar.
  - Put on a bar: a brush goes at the end of the shelf page it belongs on (the page shown when it is on none), anything else at the end of the view rail. Already there: a note says so and nothing changes. A full bar refuses with the note bar_insert gives.

## Where it lives

`palette_where(app, e) -> string`, first match wins:
1. Settings tab: "Settings".
2. Section: "Panel · <card> card" for one with a stack card of its own (Layers, Scene), else "<Palette> palette".
3. Brush: "Shelf · <page>" when on a shelf page, else "Brush picker".
4. COMMAND_HOMES: "<Palette> palette › <Section>".
5. On the view rail: "View rail"; on a shelf page: "Shelf · <page>"; on the brush pie: "Brush pie".
6. In the Lens menu (the one table `LENS_MENU` the menu draws from): "Menu" or "Menu › <submenu>".
7. Top bar (Undo, Redo, History, Settings, Search, workspaces): "Top bar".
8. Otherwise "" (a key or a gesture runs it; the second line is left out).

The group (`palette_group`): Brush → Brushes; Settings tab, Section, Settings, Help → Panels and settings; the rest Commands.

## State and stats

- `Kit_State.menu_sub: Lens_Submenu` (None, New, Recent, Import, Export, Workspaces, More), `menu_sub_at: ui.Rect`, `menu_rest` (the hover timer). The submenu closes with the menu; a press outside both closes both.
- Exit stats: `lens_focus=`, `menu_sub=`, `palette_bar_puts=`, `palette_groups=` (the groups shown last frame, as `Commands,Brushes`).
- No scene file change, no settings change and no new commands: the menu and search reuse the existing ones.

## Tests

- `palette_where_names_each_home`: a brush on the shelf, a command on the view rail, a COMMAND_HOMES command, a menu row, a Settings tab and a section.
- `palette_groups_keep_rank_inside_each`.
- `put_on_a_bar_goes_where_it_belongs`: a brush to its shelf page, a command to the view rail, again says already there.
- touch_check: `lens_focus_draws_islands` (Focus workspace: the islands' rects, no view chips), `lens_menu_recent_opens_sideways`, `lens_search_groups_and_puts_on_a_bar`.

## As built

- Sections were already in search as Show section (one per section). Lens shows them by the section's own name, with "Panel · <card> card" or "Panel · <palette> palette" under it, and groups them, with Pin section, Settings and Help, under PANELS AND SETTINGS. There is no new palette entry kind.
- Put on a bar puts a brush on the shelf page shown, not on the page it belongs on: the page shown is the one the person is looking at.
- A recent scene that is gone leaves Recent, and the submenu stays open so the person sees that it went.
- The pick's help is kept, as up to three lines under the results, without the "In the tray..." sentence, which the row's second line now says.
- The Search popover's anchor runs from its left edge to the Search button, so a tap on Search closes it rather than closing and opening it again.
- Screens: notes/lens/screens/round2/pr8-focus.png, pr8-menu-recent.png, pr8-search.png.
