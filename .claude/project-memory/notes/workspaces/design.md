# Workspaces: the user's own layouts replace the fixed spaces

Status: phase 1 (design and mock, no code), 2026-11-06, branch `claude/workspaces`. Reviewed as
sm-architect would (section 14). Mock: `notes/workspaces/index.html`.

## 1. What will exist
The top bar's middle shows the person's workspaces as tabs instead of the three fixed spaces. A
workspace is a named layout the person makes, renames, reorders, colours and deletes; changes to it
are kept as they work, its amber dot says it differs from where it started, and Reset layout puts
that back. The app ships Sculpt, Model, Paint and Render as starting workspaces, each editable and
deletable, and each tied to tools as the spaces are today, so picking the Model tool still brings the
Model layout. A workspace the person makes switches only from its tab unless they tie a tool to it.
The tool decides what the hands do; the workspace decides only the layout. Each workspace keeps a
desktop and a tablet layout. They are saved with the app's settings, never in `.sculpt` files. The
saved-layout stamps (#690) are gone.

History worth knowing: named workspaces existed once (#211, Focus/Inspect/Studio) and were removed in
#622 for "one layout per space". They were views posing as layouts and had no link to the tool; the
spaces won because the tool drives them. This design keeps that link (ties) and makes the spaces the
person's own, so it is the spaces made general, not the old workspaces back.

## 2. Where this design differs from the brief, and why
1. **Screen class is the device's kind, not a width.** The brief says "like today's bottom sheet under
   900 pt". An iPad Air in landscape is 1180 pt wide, so a 900 pt rule would give the iPad the
   desktop layout, which is the opposite of the need. Apple tells an iPad from a Mac by idiom, not
   by width; size classes only adapt within one. So: Tablet on iOS and Android, Desktop elsewhere,
   with a Settings override (Settings > Interface > "Layouts for": Automatic, Desktop, Tablet) for
   touch-screen PCs and for testing. The 900 pt bottom sheet stays what it is: an adaptation inside
   either class. Default: this; the width rule is the alternative (open question 1).
2. **Render's "a press turns the view" becomes a tool, Look.** Today it is the Render space's
   behaviour (`navigate.odin:695`). If the workspace decides only the layout, something else must
   decide that a press orbits: a new tool, Look (presses turn the view; lights, focus and the Live
   stack's handles keep their presses). Render is tied to it. This keeps Bolt's rule exact: every
   behaviour follows the tool (open question 2).
3. **Per-object "spaces off" goes.** `Object.spaces_off` (`scene.odin:96`) is stored in the scene file
   (`files.odin:2289`) by space index. Workspaces are the app's, not the file's, so a scene cannot
   name one. Its need, "leave this object out while I do X", is met by the stored visibilities V1 to
   V8 (`Visibility_Slot`, `scene_tree.odin:312`) and by Hide. Removing it bumps `SCENE_VERSION`,
   which happens several times a day anyway (61 now). Default: remove (open question 3).
4. **A tie fires when the tool's tie changes, not on every pick.** Otherwise a person sculpting in a
   workspace of their own would be thrown to Sculpt by every brush they tap. Move keeps the tie it
   was picked with, as it keeps the space today.

## 3. Compare table
Sources from their manuals as known to this session; not re-checked against the newest releases.

| Part | Taken from | Why it still holds | Avoided | Done better |
|---|---|---|---|---|
| Tabs in the top bar, one tap to switch | Blender's workspace tabs; 3D-Coat's room tabs | a tablet has no hover; the switch is the commonest layout action | Blender's tab row that scrolls sideways off a small screen | tabs give way to a chip and a menu at the top bar's existing fit steps (`kit_top_lens.odin:45`); every tab a 48 pt target |
| A workspace keeps changes as you work; Reset puts its start back | Photoshop's and Maya's workspaces (changes kept, "Reset <name>") | nobody wants a Save step for a panel moved | Photoshop's separate "save changes" choices; ZBrush's Store Config to a file | kept as you go, the amber dot on the tab shows a difference from its start, one Reset; no file to manage |
| Saved with the app, not the document | Photoshop, Substance 3D Painter (workspaces per user) | a scene shared or sent should not bring someone's panels | Blender's workspaces inside each .blend ("Load UI" toggle, a file opened brings its author's layout) | settings file only; sharing later through Send as its own payload |
| A tool brings its layout (ties) | Blender's workspace Mode (switching sets the object mode); 3D-Coat rooms (room = tools + layout) | the hand's choice (a brush, the Model tool) is the most frequent signal of intent on a tablet | Blender's link runs one way (picking Sculpt mode in Layout brings no Sculpting workspace); 3D-Coat locks tools to rooms | two-way: a tab gives back its tool, a tool brings its tab; ties editable per workspace, each tie held by one workspace; an untied workspace never moves |
| Starting workspaces, editable and deletable | Blender's + menu templates (General > Sculpting ...) | a fresh install must work at once | Blender's templates as a separate list from the tabs | the four starters are ordinary workspaces; New workspace's "Start from" brings any back |
| A layout per device kind | Apple's idiom split (iPad and Mac apps differ); Affinity's iPad studio differing from desktop | a 1600 pt desk with a mouse and an 1180 pt tablet with a palm want different docks | one layout stretched to every screen (Blender, Nomad) | two texts per workspace, chosen by device kind, kept apart, override in Settings |
| Reorder and rename on touch | browsers' tab drag; iPadOS long-press menus | fingers have no double-click or hover | Blender's double-click rename, hover X close buttons | long press opens the tab's menu; a drag after the long press (at once with a mouse) reorders; rename in the menu |
| Saved-layout stamps (#690) | our own | — | two things for one need (a stamp and a space) | removed: a workspace is the saved layout, so two stores and two menus for one need become one (one implementation per thing) |

## 4. The model

### 4.1 Types (in `src/app/workspaces.odin`, replacing `spaces.odin`)
```odin
WORKSPACE_SLOTS :: 12 // fixed slots, as macros and the stamps had, so a key, pie or gesture bound to one keeps it

Starter :: enum u8 {None, Sculpt, Model, Paint, Render} // the shipped layouts a workspace can start from

Tie :: enum u8 {Brushes, Paint_Brush, Curve, Insert, Model, Look} // what a tool in hand is, for ties

Layout_Class :: enum u8 {Desktop, Tablet}

Workspace :: struct {
	name:    string,                     // heap; "" = a free slot
	tint:    u8,                         // index into Theme.tints (4), its dot's colour
	starter: Starter,                    // its base is the starter's built-in layout; None = `base` below
	ties:    bit_set[Tie],               // tools that bring it; one workspace holds each tie
	kept:    [Layout_Class]string,       // heap; its layout as last left, "" = as its base
	base:    [Layout_Class]string,       // heap, only when starter == None: what Reset puts back
	tool:    Space_Tool,                 // the tool it was left with (today's Space_Tool, renamed Workspace_Tool)
	page:    Shelf_Page,                 // the shelf page it was left on (not layout: a page turn sets no dot)
}

Workspaces :: struct {
	list:     [WORKSPACE_SLOTS]Workspace,
	order:    [WORKSPACE_SLOTS]i8,       // slots in tab order, -1 after the last
	current:  int,                       // slot
	class:    Layout_Class,              // the class in place
	seen:     Maybe(Tie),                // the tie in hand as of last frame; Move leaves it
	switches: int,
	modified: bool,                      // the current layout differs from its base, as of this frame
}

Hands :: enum u8 {Sculpt, Model, Look}   // what the hands do, from the tool (Move keeps the last)
```
`Kit_State.layouts` and `Kit_State.spaces` merge into `Kit_State.workspaces`. Twelve workspaces of
small fixed fields keep `App` far under its 256 KB stack bound; the layout texts are on the heap.

### 4.2 Hands and the Look tool (`hands.odin`)
- `Tool` gains `Look`: a press on the view turns it (today's Render rule, `navigate.odin:695`, keyed
  on `app.tool == .Look`), lights' markers, focus picking and the Live stack's handles keep their
  presses. Its Tool card says so and has buttons that open the Material, Light and Render cards,
  the same cards their own buttons open (one implementation per thing, reached from here too). Its
  icon is Lucide's view, an eye in a frame, which no other control uses.
- `hands_of(tool) -> (Hands, bool)`: Brush, Curve, Insert are Sculpt; Model is Model; Look is Look;
  Move is none (keeps the last). `App.hands` is updated once a frame in `workspace_follow`.
- `tie_of(app) -> Maybe(Tie)`: the Brush tool with the Paint brush is `Paint_Brush`; Mask and Smooth,
  which both kinds of work use, are none (as `look_group_now` treats them, `shading.odin:325`), so
  Smooth or a layer mask's pick in Paint never throws you to Sculpt; any other brush is `Brushes`;
  Curve, Insert, Model, Look as named; Move none. A preset counts by its brush kind.
- `Tool_Look` is a new command (`TOOL_COMMANDS`, `dock.odin:112`): help, icon, palette words, the
  Library's tools (`kit_brushes.odin:326`), Help's gesture rows (`help_test.odin:39` loops every tool),
  `JOB_ALLOWED_COMMANDS` (`long_job.odin:146`). `look_group_now` keeps the last group under Look, so
  Render keeps showing the Paint look when it does today.
- What changes for a user in W1: Move picked in Render now selects and moves objects, where today a
  press in Render orbits whatever the tool. Every other press behaves as today.

### 4.3 Rules
- **Switch by tab** (`workspace_switch(app, slot)`): the workspace left keeps its tool, its shelf page
  and its layout (`kept[class]`); the new one's layout goes in place (`kept[class]`, else its base);
  views (Focus, Inspect) end; dial latches end as today. Its tool comes back only when it has ties
  and the tool in hand's tie is not among them: then its last tool if that is tied to it, else its
  first tie's tool (`Brushes` = Brush with its last brush). An untied workspace keeps the tool in hand.
- **First frame.** Start-up forces the Brush after the settings load (`main.odin:975`), so a restart
  into Model or Render would hold the wrong tool, and a plain "first frame records `seen`" would leave
  Render sculpting. `workspace_follow`'s first frame instead does the tab restore of the current
  workspace (the rule above), then sets `seen = tie_of(app)`. A unit test loads
  `workspace_current` = Render and expects `tool=look` after frame 1.
- **Follow by tie** (`workspace_follow`, once a frame where `space_follow` runs, `new_ui.odin:1411`):
  `t := tie_of(app)`; when `t` is set and differs from `seen`, and another workspace holds `t`,
  switch to it without restoring a tool. `seen` becomes `t` whenever `t` is set; a none (Move, Mask,
  Smooth) leaves `seen` as it was, including straight after a tab switch, which sets `seen` only when
  the tool in hand has a tie. A command that picks a tool needs no flag any more (`space_picked` is
  deleted): the tie changes or it does not.
- **Never mid-stroke.** Follow waits while a stroke or a stroke path is active (`curve_brush.odin:81`
  sets the Brush and starts a path); the switch, if still due, happens on the frame the stroke ends.
- **Presets on restore.** A tab restore with a preset in hand restores the preset kept in
  `Workspace.tool` when it has one, else `preset_leave` and the tied brush kind (Paint for
  `Paint_Brush`), so the lit tab and the brush never disagree (today's `spaces.odin:114` skips this).
- **Moving a tie** switches nothing, even when it is the tie in hand: the next change of tie decides.
- **Each tie is held by at most one workspace.** Tying a tie another holds moves it; the tie list
  shows where each one is now. **None tied** to a tool: picking it switches nothing.
- **Delete**: refused for the last workspace (Delete is dimmed). Deleting the current one first
  switches to its left neighbour (its right one if it is first) by the tab rule, so the neighbour's
  tool comes back when it is tied (deleting Sculpt with Model to its left hands you the Model tool,
  as a tap on Model would); the menu closes. Then the slot is freed; its ties go with it (the toast
  says which tools now bring nothing), and its keys, pie slots and gestures are forgotten
  (`command_slot_forget`, as `layout_delete` does at `layouts.odin:455`). The toast's Undo puts it
  back in its slot and place, not current, with the ties nobody took meanwhile; it is refused when
  the slot or the name was taken since (as `layout_undo`, `layouts.odin:483`). Forgotten bindings do
  not come back.
- **New workspace**: a name (default "Workspace N") and "Start from": This layout (a copy of the one
  in place, both classes, base = that copy) or a starter (its built-in layouts; it takes the
  starter's ties no other workspace holds, so a deleted Model comes back as it was). It goes after
  the current tab and becomes current. Twelve is the limit; the 13th says so.
- **Duplicate** is New with "This layout", named "<name> copy".
- **Reset layout** puts the current class's base back (starter's built-in, or `base`). The amber
  dot: the current layout differs from its base (per class; another workspace's from `kept`).
- **Class change** (the Settings override, or a future window move): like a switch within one
  workspace: the layout in place is kept as its old class's and the new class's goes in.
- **Rename** refuses an empty name, `##` (the kit's id separator), and a name another has (letter
  case aside); names are cut to `NAME_BYTES` (`scene_tree.odin:35`) and tabs end a long one in an
  ellipsis.
- **Saved at once**: New, Rename, Delete, Tie, Colour and Reorder write the settings file at once, as
  `layouts_store` does (`layouts.odin:497`), so a key bound to a slot never outlives it on disk.
- **Reorder** moves a slot in `order`; Ctrl+1..9 follow positions, bindings follow slots.

### 4.4 Starting workspaces
| Starter | Ties | Layout (both classes, as ships today plus Paint) | Shelf | Tint |
|---|---|---|---|---|
| Sculpt | Brushes, Curve, Insert | today's Sculpt (`built_in_layout`, `layouts.odin:219`) | Brushes, Move, Curve | tints[0] |
| Model | Model | `hidden Brush_Bar` | Model | tints[1] |
| Paint | Paint_Brush | brush bar shown, no card pinned (built: a pinned card took a finger's taps on a card opened over it, so Colours opens from the shelf's tile) | Paint, Brushes | tints[3] |
| Render | Look | `hidden Brush_Bar`, `column right Look` | Render | tints[2] |

The tablet class ships the same texts as desktop for now; they part as soon as the person changes
one. Paint's page leaves Sculpt's shelf, since Paint has its own workspace (Sculpt's keeps Brushes,
Move, Curve; a person who wants it back adds it from the page menu).

## 5. File format (settings file; current version only, no migration)
Written by `workspaces_save` where `layouts_save` is now (`settings.odin:1169`), read by
`workspaces_load_line` (`settings.odin:886`), put in place by `workspaces_loaded` (`settings.odin:1090`):
```
workspace <slot 1-12> <name, escaped> <tint 0-3> <starter none|sculpt|model|paint|render> <ties: a,b,c or ->
workspace_layout <slot> <desktop|tablet> <layout, escaped>   only where it differs from its base
workspace_base <slot> <desktop|tablet> <layout, escaped>     only for starter none
workspace_order <slot> <slot> ...
workspace_current <slot>
layout_class auto|desktop|tablet                             one SETTINGS row
```
- No `workspace` line accepted (a fresh install, or every line refused): the four starters. Any
  accepted: the list is exactly those, so a deleted starter stays deleted. A slot read twice, a name
  taken or holding `##`, a tie already held, an unknown word: the line is passed over.
  `workspace_layout`/`workspace_base` for a slot with no accepted `workspace` line are dropped; a
  starter-none workspace with no base takes its kept text (or Sculpt's built-in) as its base.
  `workspaces_loaded` repairs the rest: an order naming a free slot or a slot twice is cut, slots
  missing from it go at the end, and a `workspace_current` naming a free slot becomes the first tab.
- Reset all settings leaves the workspaces as they are, as it left the layouts (built: a reset of
  Settings > Interface throwing away the person's workspaces would cost more than it saves; the
  starters come back from New workspace's Start from).
- The `space_layout`, `space_current`, `layout_saved`, `dial_sector` and `dial_space` lines are
  deleted with their readers; a settings file from an earlier build loses them (passed over, never
  converted: AGENTS.md section 5). `dial <hands> <0-3> modifier <name> | command <name>` replaces the
  two dial lines (section 6, row 13).
- The shelf pages a workspace shows are a layout line, `shelf <page> <page> ...` by page key, so they
  live in its text and set its dot; the pages' tiles stay global settings lines (`shelf_pages_save`).
  The `shelf_extra <zone> <Space>` line (`lens_shelf.odin:292,308`) loses its space.
- Renamed tokens that are part of the format: the top dock's saved key `top_spaces` → `top_workspaces`
  (`bars.odin:83`), and the theme seed's `space_sculpt/model/render` keys (`theme_seed.odin:350-454`,
  whose keys are promised never to change, so the promise is broken once, before release, as the
  no-compatibility rule allows) become `tint_1` to `tint_4`, so Paint's fourth tint is themeable too.
- The scene file loses the three `spaces_off` bits (`files.odin:2289`, `2370`): `OBJECT_VIEW_BITS`
  drops to 15 and `SCENE_VERSION` goes up one.

## 6. Every reader of the current space, mapped
| # | Where | Today | Becomes |
|---|---|---|---|
| 1 | `spaces.odin` whole | `Space`, `Space_Tool`, `space_switch`, `space_follow`, `space_picked`, the tabs | `workspaces.odin`: `Workspace*`, `workspace_switch`, `workspace_follow`, tabs from `order`; Focus and Inspect move to `views.odin` unchanged |
| 2 | `layouts.odin` | `shipped`/`kept` per space; stamps; `kit_layout_menu`; `kit_space_chip` | layout text (`kit_layout_text`, `kit_layout_put`, `Zone`, `zone_hidden`, `rail_shown`) stays; per-workspace per-class texts move to `Workspace`; stamps deleted (section 7); the menu becomes the workspace menu (section 8) |
| 3 | `kit_top_lens.odin:184,280,333` | `.Space_Tabs` width, draw, Focus's chip | `.Workspace_Tabs`; width from the list; overflow (section 8) |
| 4 | `commands.odin:274,2495` | `Space_Switch` (arg a Space), Ctrl+1..3 (`:2930`) | `Workspace_Switch` (arg a slot, `args = WORKSPACE_SLOTS`, enabled when used); `Workspace_Tab` (arg a position, Ctrl+1..9) |
| 5 | `commands.odin:297,2678` | `Space_Tabs` (next space) | `Workspace_Tabs` (next tab in order) |
| 6 | `commands.odin:608-660,1024,1038` | tool commands call `space_picked` | the call goes (the tie decides); `Add_Cage`'s `space_switch(app, .Model)` becomes `app.tool = .Model` |
| 7 | `commands.odin:3144` | command label "Space: Sculpt" | "Workspace: <name>" (slot label as `layout_slot_label` did) |
| 8 | `keymap.odin:265` | arg's saved name `Sculpt` | the slot number, as `Layout_Load` saves its arg |
| 9 | `macros.odin:86`, `long_job.odin:158`, `bar_drag.odin:93`, `bars.odin:119` | lists naming `Space_Tabs`, `Layout_*` | renamed ids; `Layout_Save_As`, `Layout_Load` leave; `Workspace_New` joins macros' "not recordable" list |
| 10 | `palette.odin:254` | search words "spaces tabs sculpt model render" | "workspace tabs spaces layout sculpt model paint render"; each workspace listed by name through `Workspace_Switch` |
| 11 | `palette.odin:627` | "Sculpt's dial's top sector now runs X" | the hands' name: "Sculpting dial's ..." |
| 12 | `exit_stats.odin:572,588,597` | `layouts_changed`, `space=`, shelf pages of the space | `workspaces_changed=`, `workspace=<name> workspace_slot= hands= workspace_count= layout_class=`, pages of the workspace |
| 13 | `modifiers.odin:181,202,206`, `new_ui.odin:215`, `exit_stats.odin:473`, `settings.odin:1015-1024,1228` | dial per space | dial per `Hands` (`DIAL_DEFAULTS [Hands]`, Look's is Render's today); one `dial` settings line |
| 14 | `lens_arrange.odin:129,349` | "Editing Sculpt", "SCULPT DIAL SECTORS" | "Editing <workspace>", "<HANDS> DIAL SECTORS" |
| 15 | `lens_shelf.odin:146-235,419,773,811,836,887,905,1076` | pages belong to a space (`extra_in`) | pages a workspace shows are its layout's `shelf` line; New page adds to it; Delete page takes it from every workspace; `extra_in` and `shelf_page_space` go |
| 16 | `lens_search.odin:236` | shelf pin only in Sculpt | when the shelf shows a page that holds brushes (`shelf_holds_brushes`) |
| 17 | `navigate.odin:695` | Render: a press orbits | `app.tool == .Look` |
| 18 | `paint_toggle.odin:30` | colour island only in Sculpt | `app.hands == .Sculpt` (the brush test already there) |
| 19 | `offers.odin:33` | fit by space | fit by hands |
| 20 | `object_menu.odin:92-252` | verbs per space; another space's row runs `Space_Switch` | verbs per hands; another hands' row picks that hands' tool (the workspace follows by its tie) and is tagged with the workspace tied to it, or the hands' name when none is |
| 21 | `scene_tree.odin:58,85,285,294,322` | `Space_Hide`/`Space_Show`, off in the current space | deleted |
| 22 | `scene.odin:96,245` | `spaces_off`, `View_Change.space` | deleted |
| 23 | `files.odin:2289,2370` | the bits in the scene file | deleted, `SCENE_VERSION` + 1 |
| 24 | `lens_scene.odin:240,505-520` | the spaces dots and their menu on each row | deleted (the row keeps its eye, lock and menu) |
| 25 | `tour.odin:73` | the Spaces step lights the tabs | lights the workspace tabs; its words say workspaces |
| 26 | `new_ui.odin:220,1411`, `layer_masks.odin:72`, `model_tool.odin:537` | `space_tabs_at`, `space_follow`, `space_picked` | `workspace_tabs_at`, `workspace_follow`; the `space_picked` calls go |
| 27 | `settings.odin:886,1090,1169` | layout lines | workspace lines (section 5) |
| 28 | `script.odin:120,645` | `layout_save NAME` | `workspace_new NAME [from]`, `workspace NAME` (switch), `workspace_tie NAME tie`, `layout_class desktop|tablet` |
| 29 | `dock.odin:112,121`, `kit_tool.odin:16,29`, `overlay.odin:197`, `frame.odin:160`, `object_menu.odin:412` | complete switches on `Tool` | gain `.Look` |
| 30 | `panel_motion.odin:127,341,358,368-377`, `motion_prefs.odin:37,65` | `Motion_Kind.Spaces`, `space_frame`, `k.spaces.switches` | `Motion_Kind.Workspaces`, `workspace_frame` |
| 31 | `lens_shelf.odin:282,292,308,420,630` | `shelf_extra` line by space; `shelf_active_item` tests the page's space against Sculpt | `shelf_extra` without a space; the active item tests whether the page holds brushes |
| 32 | `bars.odin:49,83,119,182,207,230,348` | `Top_Spaces` and its key `top_spaces` | `Top_Workspaces`, `top_workspaces` |
| 33 | `src/ui/theme_seed.odin:350-454`, `exit_stats.odin:617` | tokens `Space_Sculpt/Model/Render` = `tints[0..2]` | `Tint_1..4`, all four tints |
| 34 | `exit_stats.odin:494-496` | `objects_spaces_off`, `scene_space_changes` | deleted (W2) |
| 35 | `long_job.odin:146-160` | `JOB_ALLOWED_COMMANDS` | gains `Tool_Look`, `Workspace_Switch`, `Workspace_Tab` |
| 36 | `tour.odin:44,52,111,123`, `settings_blocks.odin:92,232,524`, `lens_arrange.odin:94`, `palette.odin:235-236,306,319` | words and lists naming spaces | workspaces |
| 37 | `scripts/ui_shots.py:86-87` | taps `top bar/Model`, `top bar/Render` | the workspace tabs by name |
| 38 | `shading.odin:323` | non-Brush tools take the Sculpt look | Look keeps the last group |
| tests | `spaces_test`, `cards_test` (`:87` `built_in_layout(.Render)`), `lens_inspect_test`, `lens_scene_test`, `lens_shelf_test`, `offers_test`, `scene_tree_test`, `script_test` (`:183` `layout_save`), `object_menu_test` (`:11`), `lens_arrange_test` (`:16-19,59`), `help_test` (`:39`) | name `Space`/`spaces` | rewritten in the PR that changes what they test; `#assert(size_of(App) < 256 * 1024)` added beside the tests that put `App` on the stack |

## 7. The stamps' removal
Deleted: `LAYOUT_SLOTS`, `Saved_Layout`, `Layouts.saved/matching/more/naming/typing/name/undo/saves/loads`,
`layout_save`, `layout_load`, `layout_update`, `layout_rename`, `layout_delete`, `layout_find`,
`layout_fresh_name`, `layout_save_open`, `layout_slot_label`, `layout_undo*`, the `YOUR LAYOUTS`
rows of `kit_layout_menu`, `k.rename.layout`, commands `Layout_Save_As` and `Layout_Load`, the
`layout_saved` settings line, the `layout_save` script, exit stats `layouts_saved layout_loads
layout_matching`, scenarios `space_menu_lists_your_layouts`, `space_menu_loads_a_saved_layout`,
`space_menu_saves_a_layout` and their kin, README "Your layouts". What they did lives on: Save as is
New workspace (This layout), Load is a tab, Update is gone (changes are kept as you go), Rename and
Delete are the workspace's.

## 8. The interface (mock: `index.html`, directions A, B, C)
All directions share: the tabs live in the top bar's middle dock (`Top_Dock.Spaces`, renamed
Workspaces); the lit tab carries its tint dot and the amber dot when changed; tapping another tab
switches; the menu holds Reset layout; touch targets are 48 pt; every row runs a command so keys,
Search and pies reach it. They differ in where editing lives:
- **A. Tabs and one menu (recommended).** Tabs, then `+` (New workspace). A tap on the lit tab, a
  long press or right-click on any tab, opens that workspace's menu: Rename, Duplicate, Colour, Tie
  tools (a checklist of the six ties, each tagged with where it is now), Reset layout, Delete. The
  workspace list (from the overflow chevron or the narrow chip) reorders by dragging rows; on a wide
  bar the tabs themselves drag (a mouse at once, a finger after the long press, as `thumb_row` does).
  When tabs do not fit, the ones past the room fold into a chevron list, the current always shown;
  narrower still, the whole set becomes today's chip.
- **B. Browser tabs with a settings sheet.** Each tab is its own pill with a ⋯ on the lit one; `+` at
  the end; a double tap renames in place; tying, colour and delete are in a Workspace sheet (name,
  colour, ties, a schematic of both classes' layouts). Tabs scroll sideways when they overflow.
- **C. One chip and a switcher card.** The bar holds only the current workspace's chip (tint, name,
  dot); a tap opens a switcher of tiles, each a schematic picture of its layout drawn from its text
  (docks and cards as boxes), dragged to reorder, `+` tile first, a tile's ⋯ for the rest. Ctrl+1..9
  and a two-finger swipe on the chip switch without opening it.

Recommendation A: it is today's tabs and menu with the stamps' rows turned into workspaces, so no new
kind of control; one tap switches (C loses that); destructive actions stay off the bar (B's per-tab
⋯ and double-tap rename are mouse habits); overflow reuses the top bar's give-way steps. B's layout
schematic is worth taking into A's menu later if people ask what a workspace holds.

## 9. Budget
- A switch is one `kit_layout_text` and one `kit_layout_put`, as a space switch is now. Exit stat
  `workspace_switch_ms` (the longest): at most 1 ms on the 890M desktop build, 2 ms on the M2 iPad.
- Per frame: the dot needs the current text against its base once a frame, which `layouts_frame`
  already does (`layouts.odin:100`); no new per-frame text. `ui_ms` p50 and p99 unchanged (exit stats,
  A/B on release).
- Memory: at most 12 workspaces × 2 classes × (kept + base) × about 4 KB = under 200 KB heap.
- Settings file: about 4 KB more per changed workspace class.
- Sculpting: nothing on the stroke path; a tie switch happens on a tool change, never mid-stroke
  (tools do not change during a stroke).

## 10. PR split (each with `gate.py --changed`; the last the full gate; each PR carries its own scenarios)
| PR | What | Lines (est.) |
|---|---|---|
| W0 | The stamps removed against today's spaces (section 7), so nothing later reworks `Layout_Undo.space` | ~-250 |
| W1a | The Look tool and the first-frame restore: `Tool.Look` through every table and switch, `Tool_Look`, Help rows, Render's tab gives Look, rows 17, 29, 35 (Look), 38; the first-frame rule on today's spaces | ~300 |
| W1b | Hands: `hands.odin`, dial per hands with the `dial` line, rows 11, 13, 14, 16, 18-20 | ~250 |
| W2 | Spaces off removed: rows 21-24, 34, `SCENE_VERSION` + 1 | ~-180 |
| W3a1 | Shelf pages as a layout `shelf` line, replacing `extra_in`, `shelf_page_space` and the space in `shelf_extra` (rows 15, 31) | ~250 |
| W3a2 | Workspaces replace spaces with today's three layouts: `workspaces.odin`, slots, order, ties as data, the follow rule, commands, settings lines with their refusals and repair, the Settings block, saved at once, the tabs from the list, rows 1-10, 12, 25-28, 30, 32, 36, 37 | ~600 (one change: a list half made cannot be saved) |
| W3a3 | The Paint starter and its tie, the tint tokens (row 33), and the eight Paint-brush scenarios | ~200 |
| W3b | Layout classes and the Settings override | ~150 |
| W4 | The workspace menu: New (name, Start from), Rename, Duplicate, Colour, Delete with Undo, Reset | ~300 |
| W5 | Reorder by drag in the bar and the list, the tie checklist, overflow, Help glossary, README "Workspaces"; then one sm-ui-review round on the top bar and its menu and the full gate | ~250 |

## 11. Touch scenarios
Changed (by name and `SPACE_TABS`/`LAYOUT_ROWS` → `WORKSPACE_TABS`/`WORKSPACE_MENU`; checks `space`
→ `workspace`): `space_tab_switches_to_model` (→ `workspace_tab_switches_to_model`),
`space_lit_tab_and_chevron_open_the_menu`, `space_tab_gives_back_the_brush`,
`a_pinned_card_marks_the_layout_and_reset_puts_it_back`, `a_changed_layout_shows_its_mark`,
`a_press_in_render_turns_the_view` (and it checks `tool=look`), `render_exposure_chip_scrubs_the_exposure`,
`render_dial_places_a_highlight`, `model_dial_picks_select`, `settings_dial_is_the_spaces`
(→ `settings_dial_follows_the_hands`), `dock_stays_with_its_space`, `lens_arrange_place_stays_with_its_space`,
`each_space_keeps_its_layout_in_settings`, `render_pins_the_look_card`, `pen_roll_on_the_exposure_chip_steps_it`,
`floating_card_closes_from_its_dock_button`, `clean_view_keeping_the_shelf_hides_the_sides`,
`focus_moves_undo_and_search_to_the_top_bar`, `lens_shift_moves_lined_up_dividers`, `lens_focus_draws_islands`,
`lens_pass_popover_groups_the_passes`, `help_labels_kept_until_done`, `tour_moves_on_when_a_step_is_tried`,
`shading_chip_picks_flat_then_lit`, `pass_chip_picks_normals_from_its_list`, `paint_brush_keeps_its_own_look`,
`view_pane_shading_is_its_own`, `object_menu_lists_the_verbs_of_the_type_and_space`,
`object_menu_other_space_row_switches_and_runs`, `offer_line_makes_a_cage_sculptable`,
`offer_line_gives_a_mesh_a_cage_in_model`.

Changed once Paint holds the Paint brush's tie (W3a3), since picking the Paint brush now switches
to Paint: `colour_well_opens_the_picker`, `history_point_from_the_timeline`,
`history_step_menu_from_the_list`, `history_strip_menu_paint_back_and_delete_older`,
`lens_shelf_page_names_turn_the_page`, `shift_blurs_and_ctrl_erases_while_painting`,
`tour_finishes_with_paint`, `paint_brush_keeps_its_own_look`. Also `scripts/ui_shots.py`'s two taps.

Deleted: `space_menu_lists_your_layouts`, `space_menu_loads_a_saved_layout`, `space_menu_saves_a_layout`
and the other stamp scenarios after it (W0); `outliner_spaces_dots_leave_an_object_out` (W2).

New (W4-W6; desktop 1600 x 900 unless marked):
- `workspace_plus_makes_a_copy_and_switches` (finger): `+`, name typed, Save: 5 workspaces, the new one current, its layout the one copied.
- `workspace_new_from_a_starter_brings_its_ties`: delete Model, New from Model: the Model tool switches to it again.
- `workspace_long_press_opens_its_menu` (finger, tablet 1180 x 820): no switch, no stroke.
- `workspace_rename_by_its_menu`, `workspace_rename_refuses_a_taken_name`.
- `workspace_tabs_reorder_by_drag` (mouse at once; finger after the long press): order and Ctrl+1 follow.
- `workspace_delete_current_goes_left_and_undo_brings_it_back`; `workspace_last_cannot_be_deleted`.
- `workspace_tie_model_tool_brings_it` (tie moved from Model to a new workspace).
- `untied_workspace_keeps_its_brush_picks`: picking brushes and Move in an untied workspace switches nothing; the Model tool still goes to Model.
- `workspace_tabs_overflow_on_a_tablet` (1180 x 820, 7 workspaces): the current tab shows, the chevron lists the rest, every tab a 48 pt target.
- `tablet_and_desktop_layouts_kept_apart` (`--script=layout_class tablet`): a pin made in one class is not in the other.
- `restart_into_render_holds_the_look_tool` (two runs, one `--settings-file`): a press in Render still orbits after a restart.
- `smooth_in_paint_stays_in_paint`: Paint brush, then Smooth, then Paint again: no switch.
- `curve_path_switches_after_the_stroke`: Curve's tie moved to another workspace; the curve brush's path stroke ends before the switch.

Unit tests (`workspaces_test.odin`): settings round trip (write, read, same text), a passed-over line
of each refusal kind, every line refused gives the starters, the repair of order and current, the
follow rule table (tool sequences with Move, Mask, Smooth, presets → workspace), the first frame
after loading Render, delete's neighbour and Undo (refused when the name was taken), a tie held twice
is refused, the class switch keeps both texts, the base and dot rule, `workspaces_destroy` leaves no
leak under the tracking allocator.

## 12. README, Help, store
README: "Layout" (spaces → workspaces), "Interface" (top bar), "Controls" (Ctrl+1..9), "Settings"
(Layouts for), "Command scripts" (the new script words), and the per-object spaces removal. Help's
glossary: Workspace, Tie. sm-store: no permission, file, network or data change; targets 48 pt; the
settings file grows by kilobytes.

## 13. Open questions (each with the default this design builds)
1. Screen class: device kind with a Settings override (default) or the window's width under 900 pt.
2. Render's look-only presses: a Look tool (default) or a per-workspace "presses turn the view" switch.
3. Per-object spaces off: removed for the stored visibilities (default), or kept per hands (Sculpt,
   Model, Look) with no file change.
4. Paint's tie: the Paint brush only (default), or any brush while painting is on.
5. Twelve workspaces at most (default).
7. A deleted workspace's Undo brings it back not current (default) or current.
6. Paint's page leaves Sculpt's shelf (default) or stays on both.

## 14. Architect review (2026-11-06, a fresh agent acting as sm-architect)
Folded in above:
- Blockers: no first-frame rule (start-up forces the Brush at `main.odin:975`, so a restart into
  Render would sculpt there): the first frame now restores the current workspace's tool. An empty list
  from a file whose lines are all refused: zero accepted means the starters, and `workspaces_loaded`
  repairs order and current.
- Shoulds taken: Mask and Smooth have no tie (Paint no longer bounces to Sculpt); presets on restore;
  follow waits for a stroke to end (the Curve brush's path); the missing readers (rows 30-38: motion,
  `shelf_extra`, `top_spaces`, theme tint tokens, exit stats, job-allowed commands, tour and settings
  words, `ui_shots.py`, the look group); `Tool_Look` with Help rows; Reset all settings gets a
  workspaces block; saved at once; the eight Paint-brush scenarios; the PR split redone (stamps first,
  W1 and W3 split, scenarios shipped with each PR, W3a2's ~600 lines named as one change).
- Nits taken: three scene bits, not four; names capped and `##` refused; moving a tie switches nothing;
  delete's neighbour restore and Undo spelled out; W1's one user-visible change (Move in Render
  selects); `#assert(size_of(App) < 256 * 1024)`.
- Its open defaults adopted: Mask and Smooth neutral; Look keeps the last look group; Undo of a delete
  brings it back not current.
