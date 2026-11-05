# PR 9: the tray and the stack's leftovers go (sections as cards, pins and columns folded in)

Round 3 design.md §6 revised order 9 ("Tray and stack removal"), with §2.4's goal (one type over
every panel body) and §6's ruling that "docked columns and pinned panels (panels.odin) fold into
floating groups". Built on what PR 4, 5a and 5b actually built (pr5a-design.md, pr5b-design.md "as
built"): a group is a run in `Lens_Stack.order`, the host carries the card's state, `s.joined`,
`s.shown`, `s.beside`, the density strip. Nothing here touches undo, the History, scene files,
strokes or the GPU. Architect format (sm-architect); every `path:line` below was opened for this
note.

## 1. Request

When PR 9 is done the palette tray is gone: every tray section is a card of the panel stack (a
palette of its own that groups, floats, folds and shows as an icon like any card), a pinned
section is simply a card kept in the stack, and the two docked columns are gone: the stack docks
on the right or left edge (or floats) on its own, and the other windows float. It is not the
docks rewrite of §2.3 (user docks stay as they are), not new drag targets (5b's stand), and not a
change to what any section draws.

## 2. Current state (cited)

- **Two panel identities.** `Stack_Card` (lens_stack.odin:22-33: Brush, Symmetry, Layers, Scene,
  Tools, Palettes, Lights, Material, Environment) indexes every per-card array of `Lens_Stack`
  (lens_stack.odin:73-149: `order`, `open`, `floated`, `hidden`, `windows`, `heights`, `sizes`,
  `scrolls`, `joined`, `shown`, `beside`, the drop rects). `Kit_Section` (new_ui.odin:514-568)
  names the tray's 45 sections (`TRAY_SECTIONS`, kit_tray.odin:14) and the Stats panel's 4.
  `Panel_Kind :: union {Stack_Card, Kit_Section}` (panel_kind.odin:14-17) with `panel_body`
  (panel_kind.odin:51-70) draws either; layout names are `card:X` / `section:X`
  (panel_kind.odin:73-92), and `stack_group_read` passes sections over today
  (stack_groups.odin:465-466: "Groups hold cards only; sections come with PR 9").
- **The tray.** The Palettes card's body is `kit_tray_select` then `kit_tool_tab` /
  `kit_object_tab` / `kit_scene_tab` by `k.tab` (lens_stack.odin:451-457; kit_tray.odin:212-239),
  one section at a time from `k.section[tab]` (new_ui.odin:39-45, `tray_section`
  kit_tray.odin:55-59, `tray_pick` :100-104). `tray_open` (kit_tray.odin:107-112) picks the section
  for the tray and `stack_reveal`s its card (lens_stack.odin:244-261), whose card is
  `stack_card_of` (lens_stack.odin:229-239: Layers, Objects→Scene, Lights, Material, Environment
  have cards; brush sections the Brush card under the Brush tool; the rest Palettes). Show where
  is `tray_show` + `tray_mark` (kit_tray.odin:192-208) over `COMMAND_HOMES` (:119-187).
  `lens_show_section` (lens_studio.odin:158-165) is the look cards' "All light/material settings"
  (lens_stack.odin:787-794). The object palette's head (name, counts) is drawn by
  `kit_object_tab` (kit_object.odin:30-52), which also sets `k.object_page`.
- **Readers of the tray's choice.** `lights_section_shown` (light_markers.odin:58-61) and
  `focus_marker_shown` (lens.odin:68-72) test `k.tab == .Scene && tray_section(...) == X`; the
  exit stats `inspector_tab=` and `tray_section=` print `k.tab` (main.odin:1657, 1712);
  `tool_settings_open`/`brush_settings_open` set `k.tab = .Tool` (dock.odin:112-116,
  new_ui.odin:1680-1685); `palette_where` names "Object palette" (lens_search.odin:76-86).
- **Entry points into a section.** Show_Section (commands.odin:1899-1911, arg a `Kit_Section`,
  saved by name: keymap.odin:254), bar buttons holding a section open the bar popover
  (bars.odin:508-512 → kit_bars.odin:242-281, with its Pin at :256-259), the object chip's tap
  and long press (object_chip.odin:148-150), the object menu's Material row and Layers quick
  button (object_menu.odin:204, 258), the rail's Lights and light placing
  (light_markers.odin:272-276), Sets (lens_scene.odin:144), Paint colour (kit_colors.odin:398),
  Objects card (kit_objects_card.odin:132), Preset (dock.odin:60), Deformers/Deform
  (commands.odin:1319, 1330).
- **Pins and columns** (panels.odin). `Panel_Ref :: union {Kit_Window, Kit_Section}` (:30-33);
  `Panels` (:71-97) holds `columns[Column_Side]`, `pins[Kit_Section]` (`Pinned`, :52-56), `seen`,
  `scroll`, `rect`, the drag, the narrow pops. `panels_default` docks only the Inspector, right
  (:127-137). `panel_begin` (:683-766) is a window or, docked, a root in its column;
  `kit_columns` (:549-595) water-fills the height (:394-410) at `column_place` (:416-437).
  `panel_pin_toggle` (:254-264), `kit_pinned` (:1000-1024), `kit_panel_menu` (:870-924),
  `panels_save`/`panels_load_line` (:928-988) write and read `column` and `pinned` lines, both in
  the settings (settings.odin:804-805, 1124) and in layouts (workspaces.odin:157, 219-220). Narrow
  windows: `columns_narrow` (:454-456, `COLUMNS_MIN_W` 1180 kit_tray.odin:18),
  `columns_pop_update` (:496-519), `kit_column_tab` (:524-545); the Palettes command pops the
  tray's column there (commands.odin:1884-1891). Readers of `k.panels.rect` keep clear of the
  columns: lens_chrome.odin:296-297, lens_view.odin:56-58, grid.odin:806-814, guides.odin:108,
  lens_arrange.odin:95-97. Arrange's drawer places panels Hidden/Left/Right/Float
  (arrange.odin:28-62). `stack_docked_right` asks the Inspector's column (stack_groups.odin:110-113).
- **Floating stack cards are session-only**: no layout line keeps `s.floated` or `s.windows`
  (lens_stack.odin:172-184 "floating cards dock again when a layout is put in place";
  lens_resize.odin:71-74).
- **Layout lines today**: `stack` (lens_stack.odin:175-219; bare card names, `-` left out, `+`
  open, written only when it differs from a fresh layout's), `stack_size` (lens_resize.odin:75-104,
  bare `%v` names), `stack_density`, `stack_group` (`card:`/`section:` names, `|`, `*`),
  `stack_beside`, `column`, `pinned`, `window` (workspaces.odin:136-173, 178-247). Built-ins name
  Palettes (workspaces.odin:258, 264). Versions: `SETTINGS_VERSION :: 8` (settings.odin:50),
  `WORKSPACE_FILE_VERSION :: 1` (workspace_file.odin:25), and a newer workspace file is refused
  (workspace_file.odin:48).

## 3. What exists when PR 9 is done (user terms)

- **Every tray section is a card.** Mask, Remesh, Polypaint, Camera, Turntable, Background and the
  rest each are a palette of their own: a card with the stack's header (grip, chevron, icon, title,
  summary, Float, More) over exactly the controls the tray showed under that section (with the
  object's name in the header line for the object's sections, which replaces the Object palette's
  head). They join groups, take a second column, float, show as icons and resize as cards do.
  A fresh layout has the same visible cards as today minus Palettes: Brush, Symmetry, Layers,
  Scene, Tools (and Render's Lights, Material, Environment).
- **How a section is reached.**
  - *Show section* (Search "Object: Mask", keys, scripts `show_section mask`) opens the section
    where it lives: a brush section unfolds its group on the Brush card (as today); Layers, Objects,
    Lights, Material and Environment open their cards (as today); any other section opens as **the
    visiting card**, one at a time, at the foot of the docked stack where Palettes stood (or from its
    icon in the strip). The next section opened takes the visit's place, as the tray's one section
    did. The visit is no part of the layout, so opening sections never lights the workspace's dot.
  - *Pin to the stack* (today's Pin as a panel: the visit's More, the bar popover's pin button, the
    shelf's quick settings, Search `Pin_Section`) keeps a section's card in the stack for good
    (part of the layout); a second Pin (Unpin) leaves it out again. Carrying, joining, floating or
    resizing the visit also keeps it.
  - *Search's Show where* (Shift+Enter, a long press on a row) opens the section **as the tray
    drew it** and rings the control: brush sections on the Brush card, every other home as its
    section's card (for Layers, Lights, Material and Objects that is the full section: "Layer
    settings", "Light settings", "Material settings", the Objects tree), with More options open.
    The help line says "Mask card" / "Brush card · Stroke" / "Symmetry tab of Brush".
  - *Bar buttons with a section* keep their popover beside the button (bar_slot_run); its pin button
    becomes Pin to the stack.
  - *The object chip's Material row* and Layers quick button run Show section as today: the Material
    and Layers cards. The chip's long press opens the Scene card as today.
  - *The Lights and Material cards' More*: All light settings / All material settings open the full
    section as the visit (was: under Palettes).
  - *The Palettes button* (rail, command `Inspector`) shows or hides the stack as today.
- **Pins** are cards kept in the stack. An old file's docked pins join the stack's foot, open, in
  their column order; its floating pins come back docked there too (floating cards last a session).
- **Columns** are gone. The stack docks on the right (default) or the left edge, or floats as one
  window, from its More's "Where the stack goes": Dock on the right, Dock on the left, Float; the
  Library's Panels tab has the same choice. Stats, History, the Objects card, the Colors card and
  the Thumbnail float (their Panel options keep Fold and Close; Dock on the left/right and Move
  up/down go). An old file's column holding the Inspector sets the stack's side; windows it held
  float where their `window` line puts them.
- **Narrow windows** (under 1180 points, `column_popovers` on): the column popover becomes **the
  stack's own popover**: the docked stack is put away with the same tab at its top beside its bar,
  a tap on the tab, the Palettes button, opening or revealing a card (Show section, Show where,
  Pin) pops it over the view, and a press on the view, Escape or Android back puts it away without
  sculpting. Settings > Interface's switch reads "Panels pop over a narrow window" (key
  `column_popovers` unchanged). Windows float over a narrow window as they do on a wide one.

## 4. Design

### 4.1 The type: `Panel_Kind` becomes the one enum (PR 9a)

§6 renamed §2.4's `Palette` to `Panel_Kind` because `palette_*` and `Palette_Group` are Search's
(lens_search.odin:15, palette.odin). So the one type is `Panel_Kind`, an enum replacing both the
union (panel_kind.odin:14-17) and `Stack_Card` (renamed in place; 147 references in 12 files, a
mechanical rename in its own commit):

```odin
// Every panel body the stack can hold: the cards, then one per tray section, in
// Kit_Section's order. Appended, never reordered within a release (exit stats and tests
// name them; files name them by panel_kind_name, never by number).
Panel_Kind :: enum u8 {
	// Cards.
	Brush, Symmetry, Layers, Scene, Tools, Palettes /* deleted in 9c */, Lights, Material, Environment,
	// Sections (the Brush palette's, the Object palette's, the Scene palette's).
	Preset, Stroke, Paint_Color, Recall, Falloff, Samples, Alpha, Pen, Options, Recorder,
	Transform, Levels, Hd, Topology, Mask, Sets, Visibility, Paint, Groups, Morph,
	Layer_Settings, // section Layers: the full section, beside the Layers card
	Deform, Deformers, Remesh, Mirror, Voxels, Retopo, Textures, Project, Booleans, Extract,
	Objects, Add, Look,
	Material_Settings, Light_Settings, // sections Material and Lights, beside their cards
	Render, Lens, Finish, Camera, Turntable, Print, Floor, Background,
}
#assert(len(Panel_Kind) <= 64) // bit_set[Panel_Kind] stays one u64 (52 cases: 8 bytes, checked)

// The palette that draws section `sec` exactly as the tray did; Environment's is its card,
// which draws the same proc (lens_stack.odin:449-450). Stats sections have none.
PANEL_OF_SECTION: [Kit_Section]Maybe(Panel_Kind) // rodata table
panel_of_section :: proc(sec: Kit_Section) -> (Panel_Kind, bool)
panel_section    :: proc(p: Panel_Kind) -> (Kit_Section, bool) // its inverse; cards but Environment: false
panel_is_section :: proc(p: Panel_Kind) -> bool
```

- `panel_kind_title`, `_icon`, `_summary`, `panel_body`, `panel_kind_name`, `panel_kind_from_name`
  switch on the enum: a card as today; a section through `panel_section` and `bar_section` (titles:
  `tray_section_title`, except "Layer settings", "Light settings", "Material settings").
  `panel_body` of an object section sets `k.object_page` (as kit_object.odin:46 did) and its open
  line (stack_open_line) is the object's label, so the Object palette's head is not lost.
- File names do not change: a card is written bare in `stack` and `stack_size` lines (as older
  builds read them) and `card:X` in `stack_group`; a section is always `section:<Kit_Section>`
  (`section:Layers` is `Layer_Settings`). `panel_kind_from_name` accepts both; older builds pass
  over `section:` words in `stack`/`stack_size` (no card matches) and already in `stack_group`.
- `STACK_HIDDEN_DEFAULT` grows by every section palette. Odin refuses `.A ..= .B` in a bit_set
  literal (checked against the pin), so `stack_hidden_default() -> bit_set[Panel_Kind]` builds it
  with a loop. `stack_layout_save` writes only members that are shown plus the hidden *cards*, so a
  fresh layout's line is unchanged and an older reader leaves unnamed sections hidden (its
  "unnamed keep their fresh state", lens_stack.odin:193-195).
- `Float_Ref :: union {Kit_Window, Kit_Section, Panel_Kind}` until 9d drops `Kit_Section`;
  `k.order` capacity `len(Kit_Window) + TRAY_SECTIONS + len(Panel_Kind)` (new_ui.odin:257).
- `Kit_Section` stays: it is Show_Section's and Pin_Section's argument (saved by name), the key of
  `k.more`/`k.open`, `COMMAND_HOMES`, `section_palette` (still the "Object:" word in Search labels).
- 9a changes no behaviour: no section can be in the stack yet except through a layout naming it,
  which no build writes.

### 4.2 Sections open as their own cards (PR 9b)

```odin
Lens_Stack :: struct {
	...
	visit:    Maybe(Panel_Kind), // the section card opened last by Show section, not (yet) kept
	revealed: Kit_Section,       // the section stack_reveal or Show where opened last (stats, the Lights card's markers)
	visits:   int,               // exit stat
}
stack_card_of   :: proc(app: ^App, sec: Kit_Section) -> Panel_Kind // cards for Layers/Objects/Lights/Material/Environment, Brush for brush sections under Brush, else panel_of_section
stack_reveal    :: proc(app: ^App, sec: Kit_Section, exact := false) // exact: the section as the tray drew it (Show where)
stack_visit     :: proc(k: ^Kit_State, p: Panel_Kind)  // puts p in at the docked foot (before Palettes while it exists), the old visit back out
stack_visiting  :: proc(s: ^Lens_Stack, p: Panel_Kind) -> bool // p is the visit and still a docked group of one: what the layout writes as left out
stack_keep      :: proc(k: ^Kit_State, p: Panel_Kind, on: bool) // Pin to the stack / Unpin
palette_on_screen :: proc(app: ^App, p: Panel_Kind) -> bool // shown in the open stack, its tab the shown one, floating, or the strip's open tab
```

- `tray_open(app, sec)` keeps its callers (12) and becomes: close side panels, `k.inspector =
  true`, `stack_reveal(app, sec)`. `stack_reveal` opens `stack_card_of`'s card as today
  (lens_stack.odin:244-261), visiting it first when it is a section card that is left out, and sets
  `s.revealed`. It still folds Brush (and Palettes while it exists) for another, scrolls to the
  top, and opens the strip's tab in Icons density.
- `tray_show` (Show where) calls `stack_reveal(exact = true)`: brush sections on the Brush card,
  every other home `panel_of_section(home)` (so New layer rings in Layer settings, Place light in
  Light settings), More open, `k.pointed` set; `tray_mark` is unchanged (`k.in_tray` is set by
  `panel_body`'s caller as `stack_card_body` does, lens_stack.odin:431).
- The visit is a normal member of `s.order` while it visits (so groups, the strip, carries and
  drops need no new case). A new visit or Leave out puts the old one back to hidden only while
  `stack_visiting` holds; once carried into a group, given a column, floated or resized, it is a
  kept card. `stack_layout_save` writes a visiting card as left out (unnamed), so a visit never sets
  the modified dot.
- Pin_Section (commands.odin:1912-1920): in 9b only the visit's More gains "Pin to the stack"
  (`stack_keep`); the command itself still pins until 9d.
- Readers: `lights_section_shown = palette_on_screen(.Light_Settings) || (s.revealed == .Lights &&
  palette_on_screen(.Lights))`; `focus_marker_shown`'s tray test becomes `palette_on_screen(.Lens)`.
  Render's default (Lights card open, nothing revealed) shows no markers, as today.
  `tool_settings_open`/`brush_settings_open` reveal the Brush card. Stats keep their keys:
  `inspector_tab=` is `section_palette(s.revealed)`, `tray_section=` is `s.revealed`; new
  `stack_visit=<kind>|none stack_visits=`.
- `palette_where` (lens_search.odin:76-86): Show_Section rows "Panel · Mask card" (cards and tabs
  as today); homes "Mask card", "Brush card · Stroke".

### 4.3 The tray goes (PR 9c)

- Deleted: `Panel_Kind.Palettes` and its body, summary, icon and name rows; `kit_tray_select`,
  `tray_sections`, `tray_section`, `tray_pick`, `palette_title`; `Kit_State.tab`, `.section`,
  `.list_scroll`, `.list_reveal`, `.tab_serial`; `kit_object_tab`'s and `kit_scene_tab`'s one-section
  loops (the section tables and draw procs stay; `kit_scene_objects` is the Objects palette's body);
  `lens_show_section` (its two menu rows call `stack_visit`); the `.Palettes` folds in
  `stack_reveal`. `kit_tray.odin` keeps `TRAY_SECTIONS`, `COMMAND_HOMES`, `section_palette`,
  `palette_name`, `tray_offers`, `tray_section_title`, `tray_open`, `tray_show`, `tray_mark`
  (renaming them is churn with no gain; its header comment is rewritten).
- Built-ins drop the word (workspaces.odin:258, 264): Model `stack Brush+ Layers Scene Symmetry
  -Tools`, Render `stack Lights+ Material+ Environment -Brush -Symmetry -Layers -Scene -Tools`.
- Old text: a `Palettes` word in `stack`, `stack_size`, or `card:Palettes` in `stack_group`, names no
  card and is passed over (the readers already do this for unknown names). `workspaces_loaded`
  upgrades every `saved`/`live` text that holds one through `workspace_layout_clean` (a fresh
  `Kit_State` put and written again, as imports are), next to `grid_layout_upgrade`, so the dot
  does not light on an unchanged workspace.
- `kit_panel_menu`'s Inspector row "Pin %s as a panel" (panels.odin:902-909) goes (there is no
  section shown by the tray to pin); `panel_title(.Inspector)` reads "Panels".

### 4.4 Pins are cards (PR 9d)

- `Pin_Section` runs `stack_keep(k, panel_of_section(sec), !kept)`; checked is "kept in the stack";
  label "Pin to the stack", search words gain "keep". Deleted: `Pinned`, `Panels.pins`,
  `panel_pin_toggle`, `panel_pinnable` (its "not Objects" rule goes: the Objects tree can be kept
  too), `kit_pinned`, `Panel_Ref`'s and `Float_Ref`'s `Kit_Section` cases, the pins' mirror loops
  (workspaces.odin:156-158, 240; new_ui.odin:1108), `panel_bit`'s section bits.
- Migration (`panels_old.odin`, new, ~80 lines; read by both `kit_layout_put` and `settings_load`):

  ```odin
  Panels_Old :: struct {
  	columns:  [Column_Side][dynamic; COLUMN_MAX]string, // the words of each `column` line, as read
  	pinned:   [dynamic; TRAY_SECTIONS]Kit_Section,      // `pinned` lines, in order
  	seen:     bool,
  }
  panels_old_line :: proc(old: ^Panels_Old, f: []string)      // replaces panels_load_line
  panels_old_settle :: proc(k: ^Kit_State, old: ^Panels_Old) // after the whole text, like stack_group_read
  ```
  `panels_old_settle` (9d part): each pinned section, in its column order (left column's, then
  right's, then those in no column), becomes `stack_keep(...)`, open unless its line said
  minimised, appended at the docked foot; a floating pin comes back docked (floating cards last a
  session). The window and Inspector words wait for 9e (9d still reads them into the columns).
- Exit stat `panel_pins=` is kept, computed: the kept section cards' `Kit_Section` names,
  lower case, in stack order (so scenarios reading it keep their checks).

### 4.5 Columns go (PR 9e)

```odin
Stack_Place :: enum u8 { Right, Left, Float } // layout terms (right-handed); Right is the zero value
Lens_Stack :: struct { ..., place: Stack_Place, popped: bool, pops: int }
stack_place_save :: proc(k: ^Kit_State, out: ^strings.Builder) // `stack_place left|float`, only when not Right
stack_place_read :: proc(k: ^Kit_State, f: []string)
stack_place_set  :: proc(app: ^App, p: Stack_Place)
stack_room       :: proc(app: ^App, side: Column_Side, width: f32) -> (offset, top, room: f32) // column_place, kept as it is
stack_narrow     :: proc(app: ^App) -> bool  // columns_narrow, for the stack
```

- `kit_inspector` lays the docked stack out itself as `panel_begin`'s docked bare branch did: root
  `"inspector"` anchored `.End`/`.Start` by side (mirrored by `ctx.mirror`), at `stack_room`, body
  `kit_scroll_begin(ctx, "panel body", &k.scroll, ...)`, so ids, the root name, hit tests and every
  pixel stay. It writes `k.panels.rect[side]` (and clears the other), which the five readers that
  keep clear of a column keep reading unchanged. Floating, it is today's window.
- `panel_begin`/`panel_end` keep only the window and card path, `panel_fade` and Panel options.
  Deleted: `Panels.columns`, `.at`, `.width`, `.laying`, `.drag`, `.drag_at`, `.open_last`,
  `.open_seen`, `.scroll`, `panel_water_fill`, `kit_columns`, `column_shown`, `column_visible`,
  `column_drop_at`, `column_zone`, `kit_column_drop`, `panel_dock`, `panel_float`, `panel_shift`,
  `panel_take`, `panel_undock`, `panel_drag_follow`, `panel_docked` (callers ask `k.stack.place`).
  `kit_column_tab` and `columns_pop_update` become the stack's (`kit_stack_pop_tab`,
  `stack_pop_update`): pops on the Palettes command, on `stack_reveal`/`stack_keep`, on the
  Inspector opening; a viewport press puts it away (swallowed, as now); `k.stack.popped` joins
  `kit_floating` and kit_frame's Escape list, so Android back closes it first (sm-store).
- `kit_panel_menu`: the Inspector keeps Dock on the left/right and Float (`stack_place_set`), Fold,
  Close; other windows Fold and Close. The stack's More "Where the stack goes..." opens it as now.
  Arrange's drawer (arrange.odin:28-62): the Inspector row Hidden/Left/Right/Float, the other
  windows Hidden/Shown.
- `panels_old_settle` (9e part): the side whose `column` line names `Inspector` sets `place`; a
  text with `column` lines none of which names it sets Float; windows named in a column float
  (their `window` lines already place them; a window never moved floats at its default).
  `settings_save` stops writing columns (settings.odin:1124); the top-level lines of an older
  file still read.
- Exit stats: `column_left= column_right=` go; `stack_place=right|left|float` new;
  `columns_narrow= column_popped= column_pops=` keep their names (the stack's side, or none);
  `layout_left_column= layout_right_column=` keep reading `panels.rect`.

### 4.6 Migration and versions

| Old line | Becomes (and where) |
|---|---|
| `stack ... Palettes[+] ...` | the word is passed over (9c) |
| `stack_group card:Brush card:Palettes` | Palettes passed over; one card left makes no group (9c) |
| `pinned <Section> m x y ox oy min` | `stack_keep(panel_of_section(S))` at the docked foot, folded if `min` (9d) |
| `column <side> ... section:<S> ...` | that section kept at the foot, in column order (9d) |
| `column <side> Inspector ...` | `stack_place` = side (9e) |
| `column <side>` without Inspector (some column line exists) | `stack_place float` (9e) |
| `column <side> Stats History Objects Colors Thumbnail` | those windows float (9e) |

- **`SETTINGS_VERSION` stays 8 (default; decision 5).** Every old form names itself (`column`,
  `pinned`, the `Palettes` word), and their absence means today's default in both builds, so no
  line's meaning needs the file's age; the versions so far were bumped only when a default changed
  under an absent line (settings.odin:41-49). A new file read by an older build: unknown lines and
  `section:` words are passed over; that build docks the stack right and shows no kept sections,
  and nothing is damaged.
- **`WORKSPACE_FILE_VERSION` stays 1.** A bump makes every older build refuse the file
  (workspace_file.odin:48), while its lines are all passed over gracefully; the `space` line set
  the precedent (workspace_file.odin:21-22). Version-1 files with `column`/`pinned`/`Palettes` import
  through `workspace_layout_clean`, which settles them.
- **Upgrade on load**: `workspaces_loaded` cleans every `saved` and `live` text that holds a
  `column `/`pinned ` line or the Palettes word (9c adds the word, 9d `pinned`, 9e `column`), so an
  unchanged workspace reads unmodified.
- **Round-trip tests** (unit, `panels_old_test.odin` and the existing files):
  - `built_in_workspaces_read_back_as_written` (exists) stays green each PR.
  - 9a `panel_kinds_read_back` grows: every `Panel_Kind` → name → kind; `PANEL_OF_SECTION` is a
    bijection onto the section palettes plus Environment; a layout naming `section:Mask+` in
    `stack` and `stack_size Mask=200` (as `section:Mask=200`) reads back; a fresh layout's text is
    byte-for-byte what 8b writes.
  - 9b `the_visit_is_no_part_of_the_layout` (layout text unchanged by Show section),
    `a_visit_gives_way_to_the_next`, `a_kept_visit_stays`, `a_visit_carried_into_a_group_is_kept`
    (with `stack_valid` after each, stack_carry_test.odin), `stack_card_of_routes_every_section`.
  - 9c `an_old_layout_with_palettes_reads_unmodified` (old Sculpt/Model/Render texts → clean →
    equal to the new built-ins; `workspaces_frame` leaves `modified` false).
  - 9d `pins_from_an_older_file_become_cards` (a v8 settings text with `column right Inspector
    section:Layers section:Camera` and two `pinned` lines → `Layer_Settings+`, `Camera+` at the
    foot, kept; written again: no `pinned`/section words in `column`; read again: equal text),
    `a_floating_pin_comes_back_docked`, `pin_section_keeps_and_unpins`.
  - 9e `old_column_lines_settle_the_stack_place` (left; right without Inspector → Float; windows
    float with their `window` places), `stack_place_reads_back` (both hands),
    `a_workspace_with_columns_reads_unmodified`, `a_workspace_file_with_columns_imports_clean`.

### 4.7 Ownership, threading, failures

All state is `Kit_State`'s fixed arrays and enums: no heap, no references kept between frames, no
jobs. A layout word naming nothing is passed over (as every layout reader does); a damaged layout
cannot assert: `panels_old_line` bounds-checks its fields like `panels_load_line`
(panels.odin:956-959, 973). The visit and Pin are Kit_State changes made during the layout, as
`stack_join` is, never a `Scene_Command`.

## 5. Boundary check

No new import edge. Everything stays in `src/app`; `src/ui` gains nothing (the narrow tab, the pop
and the menus use existing widgets). `scripts/boundary_check.py` unaffected.

## 6. Alternatives rejected

- **Every section opened stays in the stack** (no visit): ten searches leave ten cards and each
  lights the workspace's dot; the tray's "one section at a time" is what users have now.
- **Index the stack by `palette_index(Panel_Kind union) -> int`**: same churn as the enum, and
  `bit_set[0..<64]` of bare ints loses the type checking the enum gives.
- **Narrow windows show the stack as icons (the strip) instead of the pop**: cleaner, but moves the
  narrow and 1100-wide scenarios (`stack_beside_without_room_goes_below` taps the column tab) and
  changes what tablet users see in portrait; Icons density is one tap away for those who want it.

## 7. Risks (and what catches each)

- **Touch coordinates (about 46 scenarios).** Object and Scene sections lose the select row and the
  palette head above them, a constant per palette (Object: select + name + counts + spacer + title;
  Scene: select + title; Objects: select only). 9b moves them once: `palettes_only` writes `stack
  -Brush -Symmetry -Layers -Scene -Tools -Palettes` (so 9c moves nothing), and the constants move by
  `SECTION_DY["object"|"scene"|"objects"]`, measured once from `--screens`. Brush sections are on
  the Brush card and do not move. Caught by `touch_check.py` itself.
- **The modified dot after an upgrade** (layout text drift). Caught by the `*_reads_unmodified`
  tests and `a_changed_workspace_shows_its_mark`.
- **Show where on carded sections changes place** (New layer now rings in Layer settings, not on
  the Layers card). Kept on purpose so `show_where_finds_every_home` keeps its meaning; caught by
  that test (rewritten to draw `panel_body` of the revealed palette) and
  `long_press_a_search_row_shows_where`.
- **Light and focus markers** showing where they did not (Render shows the Lights card open).
  `palette_on_screen` plus `revealed` keeps Render's default unmarked: parity's `studio`,
  `render_*` and `thumbnail` dumps, `light_marker_dragged_in_the_viewport`,
  `place_highlight_lights_where_the_finger_taps`.
- **The docked stack placed differently in 9e** (a point off moves every right-side pixel and
  the free area). Same root name, anchors, `column_place` maths and scroll body; parity 19/19 plus
  a left-docked dump before/after; `layout_inspector=` in `rail_on_the_right_clears_the_panels`.
- **bit_set width**: 52 cases fit one u64 (measured: `size_of(bit_set[E])` 8 for 52 cases); the
  `#assert` stops a 65th.
- **10M-vertex cost**: none; loops over 52 members a frame are a few hundred ns. Undo, levels, HD,
  dirty ranges, GPU buffers: untouched.

## 8. Plan: five PRs, each green alone

Each runs `python scripts/gate.py` (check, test, build, smoke, touch, iphonecheck, wincheck,
androidcheck), updates README and sm-ui (sm-ui is at ~480 of 500 lines: 9c and 9e replace its tray
and columns bullets by shorter ones), runs `agents_sync.py`, and reports parity against the
previous merge.

### 9a. `Panel_Kind` is one enum (~300 lines, ~150 of them the rename)
- Files: panel_kind.odin, lens_stack.odin, stack_groups.odin, stack_carry.odin, lens_resize.odin,
  lens_panes.odin, new_ui.odin (Float_Ref, order), lens_search.odin, main.odin; tests
  panel_kind_test, lens_stack_test, stack_groups_test, stack_carry_test, stack_density_test,
  lens_studio_test (rename only).
- Touch: none change. New unit tests in §4.6 (9a).
- Parity: 19/19 screens and viewports identical.

### 9b. A section opens as its own card (~350 lines Odin, plus touch constants)
- Files: lens_stack.odin (visit, reveal, keep, `palette_on_screen`, header line), kit_tray.odin
  (`tray_open`, `tray_show`), panel_kind.odin (`object_page`), light_markers.odin, lens.odin,
  dock.odin, new_ui.odin, lens_search.odin, main.odin (stats), kit_tray_test.odin, lens_search_test.
- Touch, changed (coordinates by `SECTION_DY`, helpers `palettes_only`, `palettes_section`,
  `scene_args`/`scene_tab`, `select_page`, `open_sets`, `open_rebuild`): first_touch_scrolls_inspector,
  lights_added_and_switched_off_in_the_list, light_sphere_moves_and_flips_lights,
  place_highlight_lights_where_the_finger_taps, light_renamed_by_typing_is_one_step,
  more_options_open_and_fold, more_options_show_the_rest, show_every_option_needs_no_fold,
  mask_by_from_the_section, grow_visibility_from_the_section, layer_duplicate_from_the_section,
  selection_set_restores_by_finger, the 20 scene-tree scenarios (long_press_a_scene_row_opens_its_menu,
  scene_eye_hides_and_shows_an_object, scene_ghost_lets_a_click_through, solo_follows_the_row_picked,
  scene_row_of_a_hidden_object_brings_it_back, undo_keeps_an_object_hidden,
  ctrl_g_makes_a_folder_and_undo_takes_it_back, folder_chevron_folds_its_objects,
  folder_eye_hides_everything_in_it, delete_folder_and_undo_brings_both_back,
  folders_come_back_from_the_scene_file, grip_drag_moves_a_row_and_undo_puts_it_back,
  finger_drags_an_object_into_a_folder, column_drag_hides_every_row_it_crosses,
  finger_holds_a_ghost_then_slides_down_the_column, shift_click_rows_then_drag_moves_both,
  shift_click_objects_in_the_viewport, select_several_with_a_finger_then_delete_takes_both,
  duplicate_copies_the_whole_selection, folder_menu_selects_its_objects),
  transparent_screenshots_switch_in_the_background_section, turntable_frames_slider_by_finger,
  print_height_by_finger_and_inches, deformation_amount_by_finger,
  delete_hidden_then_close_holes_by_finger, rebuild_density_shows_the_cells,
  rebuild_even_is_a_straight_remesh, rebuild_fewer_and_quads, transform_values_undo_per_drag,
  deformers_from_the_palette (`DEFORM_AMOUNT`), small_window (the Mask visit at 1280 x 800).
  Why: the section's controls stand higher by the head they lost. Preset scenarios do not move
  (Brush card).
- Touch, stat only: stack_icons_show_where_opens_the_card (`stack_tab=Mask`, was Palettes).
  Unchanged checks that must stay green: show_where_marks_the_control,
  search_opens_a_section_by_name, long_press_a_search_row_shows_where,
  lens_object_chip_opens_the_scene_palette, status_chip_tap_and_long_press.
- New touch: `search_opens_a_section_as_its_own_card` (Polypaint then Mask: `stack_visit=Mask`,
  Paint left out, `workspace_modified=0`), `a_pinned_visit_stays_in_the_stack` (More > Pin to the
  stack, then another section: both shown; saved layout holds `section:Paint+`),
  `show_where_opens_the_light_settings` (Place highlight: `stack_visit=Light_Settings`,
  `tray_marked=1`), `a_section_card_joins_a_group_by_pen_left_handed`.
- Parity: identical (the default layout opens no section).

### 9c. The tray goes (~-300/+120 lines)
- Files: lens_stack.odin, kit_tray.odin, kit_object.odin, kit_scene.odin, lens_studio.odin,
  new_ui.odin (fields), panels.odin (menu row), workspaces.odin (built-ins, upgrade), README (the
  stack's Palettes bullet, the tray paragraph rewritten as "Sections", the Tools/Lights/Material
  mentions of Palettes), sm-ui.
- Touch: lens_studio_stack_shows_lights_material_environment (`stack=Lights+,Material+,Environment`);
  any `stack=` check ending in `,Palettes` (STACK_ICONS keeps its first five places).
  Unit: `tray_sections_match_their_palettes` becomes `every_tray_section_has_a_card`;
  lens_stack_test:60-63 and lens_studio_test's Palettes expectations.
- New: §4.6 (9c) test; touch `an_old_workspace_with_palettes_opens_unmodified` (import a v1 file
  with `stack ... Palettes+`: `workspace_modified=0`).
- Parity: viewports 19/19 identical; screens differ only in the folded Palettes header's rect at
  the stack's foot (under Tools, x 1288-1596 at 1600 x 900); the report gives the box, as 8b did.

### 9d. Pins are cards (~300 lines)
- Files: panels.odin, panels_old.odin (new), commands.odin (Pin_Section), kit_bars.odin (popover
  pin), lens_shelf.odin (quick settings label), arrange.odin (pinned rows), new_ui.odin
  (Float_Ref, mirror loop), workspaces.odin, settings.odin, main.odin (`panel_pins=` derived),
  palette.odin (search words), panels_test, workspaces_test:55-61, README, sm-ui.
- Touch, changed: pinned_sections_stack_in_the_right_column → `pinned_sections_join_the_stack`
  (`stack` ends `Layer_Settings+,Camera+`, `panel_pins=layers,camera`; `column_right=` dropped);
  narrow_window_opening_a_panel_pops_its_column keeps its checks (a kept card pops the stack's
  column). New: `bar_section_pin_keeps_it_in_the_stack` (the rail's Lights popover > pin),
  `old_pins_become_cards` (a settings file with `pinned` lines; `@saved` has no `pinned` line).
- Parity: identical.

### 9e. Columns go (~-500/+220 lines)
- Files: panels.odin (most of it deleted), new_ui.odin (`kit_inspector`, layout order, Escape),
  lens_stack.odin / stack_groups.odin (`place`, `stack_docked_right`), lens_panes.odin
  (`stack_strip_shown`), lens_chrome.odin (`lens_mini_reach`), kit_objects_card.odin, commands.odin
  (Inspector, Panels_Reset help), arrange.odin, settings_blocks.odin (switch label), main.odin
  (stats), workspaces.odin, settings.odin, panels_old.odin, README ("Panels and columns" becomes
  "Where the panels go"), sm-ui.
- Touch, removed (the feature goes): stats_dropped_on_the_right_column_docks_it,
  colors_card_docks_left_and_holds_still, colors_card_docks_right_and_holds_still (and
  `colors_docked_still`). Kept with their checks: narrow_window_puts_the_column_away,
  narrow_window_palettes_pops_the_column, narrow_window_opening_a_panel_pops_its_column,
  stack_beside_without_room_goes_below (the tab stays at `NARROW_TAB`'s place),
  a_stroke_under_the_tray_fades_it, every `window_inspector=` check.
- New touch: `stack_docks_left_from_its_options` (More > Where the stack goes > Dock on the left:
  `stack_place=left`, `layout_left_column` x within the left 400 points, a stroke on the model
  still sculpts), the same `_left_handed_by_pen`, `old_columns_float_their_windows` (settings file
  `column right Inspector Stats` / `column left Colors`: `window_stats=1,...`, `stack_place=right`),
  `narrow_window_escape_puts_the_stack_away`.
- Unit: §4.6 (9e); panels_test's column tests deleted (`a_column_shares_its_height...`,
  `panels_dock_float_and_move_within_their_columns`), `every_panel_has_its_own_bit` for windows only.
- Parity: 19/19 identical, plus the before/after dump of a left-docked stack and of a narrow
  (1024 x 768) window with the stack popped, identical.

## 9. Decisions taken (each with its default) and what needs Bolt

1. **Sections open as one visiting card**, kept by Pin to the stack (or by carrying it). Default:
   as described. *Worth Bolt's look*, since it is the one new behaviour a user meets; the
   alternative (every opened section stays) is a few lines.
2. **Windows no longer dock** (Stats, History, Objects, Colors, Thumbnail float; Colors' "Dock on
   the left/right" and its two scenarios go). Default: float, as §6 decided ("columns fold into
   floating groups"). *Flag for Bolt*: it removes a docking feature he may use for Colors.
3. **Floating pins come back docked** (floating cards are session-only today). Default: docked at
   the stack's foot; keeping cards floating across sessions is a later, separate line.
4. **Show where shows the full section** for Layers, Lights, Material and Objects (their
   "settings" cards), not the compact card. Default: full section (every home is found; the test
   keeps its meaning).
5. **No version bumps** (`SETTINGS_VERSION` 8, `WORKSPACE_FILE_VERSION` 1): old lines name
   themselves; a bump of the workspace file would make older builds refuse new files.
6. **Narrow windows pop the stack** (today's popover, for the stack alone) rather than switching
   to icons; Escape and Android back now put it away.
7. **Names**: the one type is `Panel_Kind` (§6), the full sections `Layer_Settings`,
   `Light_Settings`, `Material_Settings` (titles "Layer settings", "Light settings", "Material
   settings"); file names stay `section:<Kit_Section>`. `tray_open`/`tray_show`/`tray_width`/
   `tray_shown` keep their names (callers and sm-ui use them; renaming is churn).
8. **The Object palette's head** (name and counts) becomes the object section cards' header line.

UNVERIFIED: the exact pixel heights behind `SECTION_DY` (to be measured from `--screens` in 9b);
whether any Arrange scenario reads the columns' outlines by pixels (none reads them by stat).

## As built

- **9a, #338.** As designed. `STACK_CARDS` and `STACK_SECTION_PANELS` (the latter is `~STACK_CARDS`; a complement keeps to the enum's cases) and `panel_word`/`panel_from_word` name a panel in the stack, sizes and beside lines. A group line's `section:` words now read in as tabs.
- **9b.**
  - **Placing the visit.** `stack_visit` puts the visit directly into the order: before Palettes's group while it is docked, else after the last docked group. It does not go through `stack_move_to_k`, which would move Palettes into the visit's old slot and change the layout's text.
  - **Visit status.** `stack_visit_settle` (called each frame in `kit_stack`) clears `s.visit` once the visit is grouped, floated or resized, so a kept card stays kept.
  - **What the layout writes.** `stack_layout_save` leaves out the hidden sections and the visit, both when comparing with a fresh layout and when writing the line. Folding Brush for a visit still changes the layout, as folding it for Palettes always did.
  - **On screen and markers.** `palette_on_screen` checks the open group's shown tab, the second column, a floating group and the strip's tab. The Lights and Lens markers keep the old tray test, but only while the Palettes card is on screen (it goes in 9c).
  - **Panel bodies.** `panel_body` now sets `k.in_tray` (for Show where's ring) and `k.object_page`, and draws `kit_scene_objects` for `.Objects`. The Object sections' header line reads "Sphere 1 · 40k vertices".
  - **Light and Material cards' More.** The "All light settings" and "All material settings" rows open the full section with `tray_open(exact)`. `lens_show_section` is gone.
  - **Touch scenarios.**
    - `palettes_only` writes `stack section:X+ ... -Palettes`. For card sections it runs no `show_section` (`CARD_SECTIONS`); brush sections keep the Palettes path, which reveals the Brush card.
    - `SECTION_DY` is object −143, scene −85, objects −59, applied through `on_card()`. `LAYER_DUPLICATE` is now (1302, 448), measured on Layer settings.
  - **Found on the way.** `voxel_stroke_sculpts_the_clay_and_undoes` was broken by #335: the offer line replaces the note. It now checks `offer=Convert_To_Mesh`.
- **9c.**
  - **Gone:** the `Panel_Kind.Palettes` case, `Kit_State.tab`, `.section`, `.list_scroll`, `.list_reveal` and `.tab_serial`. Also gone: `kit_tray_select`, `tray_sections`, `tray_section`, `tray_pick`, `palette_title`, `kit_object_tab`, `kit_scene_tab`, `kit_brush_tab`, and the Inspector's "Pin as a panel" row.
  - **New helper:** `stack_reveal_card(app, c)` is shared by `stack_reveal` and by `tool_settings_open`/`brush_settings_open`, which now reveal the Brush card.
  - **Exit stats:** `inspector_tab=` is now `section_palette(s.revealed)` (Tool when nothing is revealed). `tray_section=` is `s.revealed`, or none.
  - **Old layouts:** `stack_layout_upgrade` (workspaces.odin) runs `workspace_layout_clean` on any saved or live text whose stack lines name Palettes.
  - **Touch:** for brush sections, `palettes_only` writes `stack Brush+ -Symmetry ...`; `SECTION_DY["brush"] = -60` is the folded Palettes header that used to stand above the Brush card.
  - **Parity:** viewports are identical in all 19 scenes. Six Render screens (studio, render_*, live_ao_msaa_off, thumbnail) differ only in the stack's 3-point scroll thumb at x 1540, which is longer now that there is no Palettes header.

## As built: 9d (#341) and 9e
- 9d: Pin to the stack = stack_keep(on) + stack_pop_open on narrow windows; Panel_Ref = Kit_Window only; old `pinned` lines and `section:` column words -> Panels_Old -> panels_old_settle (kept cards at the foot, folds kept). A floating pin comes back docked.
- 9e: `Lens_Stack.place: Stack_Place {Right, Left, Float}` (reset by stack_default, windows_reset docks right), layout line `stack_place left|float` (none for Right, so built-ins read unchanged). `stack_docked(k)` replaces panel_docked; `kit_stack_dock` replaces kit_columns (same stack_room maths, single allot = min(want, room)), pixel-identical: parity 19/19, left-docked dump and narrow popped dump identical to #341.
- Old `column` lines: the side naming Inspector sets place; a `column right` line without it sets Float; a left line alone leaves Right (panels_save only wrote columns that differed). stack_layout_upgrade also cleans texts with column/pinned lines.
- Gone: columns, drag-to-dock, water fill, panel_dock/float/shift/undock, the Colors card's docked branches and its two docking scenarios, stats_dropped_on_the_right_column_docks_it. Escape/Android back puts the popped stack away (not in kit_floats_close, so a card's More inside the popped stack keeps it open).
- Stats kept names columns_narrow= column_popped= column_pops=; column_left/right gone; stack_place= new.
