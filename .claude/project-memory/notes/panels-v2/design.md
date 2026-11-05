# Panels v2: code design (PR 0)

Bolt approved the model on 2026-11-04 ("looks good proceed"): plan https://claude.ai/artifact/RsfEHZKMGNA5Awi5EA7fDm,
mock v7.2 https://claude.ai/artifact/1hGzEd2pmaZD6KULbE31LW (source mock.html beside this note).
Decided in the thread: docks stay movable anywhere (Affinity), the shelf too, any edge (top and bottom make a row),
today's soft alignment kept, a faint grip to move and a faint corner handle for lines.

## Baseline
`ui_ms_p50/p99` already exist (frame.odin times kit_frame..view_windows_layout). Each PR reports them on
`--vertices=500000 --frames=240` with the default layout and with two cards open, against odin-sculpt.

## Types (after PR A)
- `Card` (cards.odin): Tool, Layers, Scene, Mesh, Mask, Deform, Paint, Symmetry, Look, Render. Colours and History
  join when Kit_Window goes (PR C). One enum names a card everywhere: bar slots (Open_Card arg), layout lines, Search,
  scripts, exit stats (`card_word`).
- `Section` (cards.odin): the 42 sections the three palettes had, each in exactly one card (`CARD_SECTIONS`, a test
  checks every section has one home). Section draw procs stay where they are (kit_tool, kit_object, kit_scene).
- `COMMAND_HOMES: [Command_Id]Maybe(Section)` moves from kit_tray.odin to cards.odin; Show where =
  `card_reveal(app, section)`: opens the card on the pen side, unfolds the section, scrolls to and marks the control.
- `Column` (column.odin), one per side of the screen (`Kit_State.columns[Column_Side]`): `rest: Maybe(Card)` (pinned),
  `shown: Maybe(Card)` (opened over it, closes on a viewport press), `split: Maybe(Card)` (mouse only, below the
  pinned one), `anchor: ui.Rect` (the dock it opened from), `scroll`, `shut: bit_set[Section]` per card is global
  (`Kit_State.cards.shut`).
  Placement: beside the anchor dock on the side facing the window's middle; a flat dock (row) puts it below when the
  dock is in the upper half, above otherwise; the pen side's column stops above the palm zone on touch
  (lower 42% of the window on that side), never under the shelf.
- Floating cards (PR B): `Kit_State.cards.floats` (fixed array of Card + ui.Window), drawn in the float order with
  the other windows; head drag past the slop tears a card out of its column, a drop on a dock or a column returns it.

## What each PR deletes
- PR A (cards + column, merges plan PRs 1 and 2 since porting the stack to the new enum first would be thrown away):
  lens_stack.odin, stack_groups.odin, stack_carry.odin, card_pop.odin, kit_tray.odin, panel_kind.odin,
  rail_panels.odin, lens_resize.odin's stack parts, panels.odin's docked stack (Stack_Place, stack_room,
  stack_narrow/popped), `Kit_Tab`, `Panel_Kind`, `Pin_Section`, the Inspector ("Main palette") command,
  kit_objects_card.odin and `Kit_Window.Objects`. Layout line `stack*` replaced by `column left|right <card>`.
- PR B float; PR C sheets (Kit_Window gone: Settings/Help/Macros/Details sheets, History and Colours cards);
  PR D docks anywhere (shelf movable, flat docks on top/bottom, corner handle restyled faint, grip bar);
  PR E one layout per space; PR F platforms; PR G second view as a pane, docs and touch suite.

## Risks
- ~800 touch scenarios drive the stack by coordinates: each PR rewrites the ones it breaks, run by name here
  (offscreen); the full suite is left for Bolt's gate.
- App must stay under 256 KB (tests put it on the stack): Column state is small; floats are fixed arrays.
- No change to sculpting, the stroke path or the GPU.

## PR D: docks move anywhere, no Edit docks needed (2026-11-04)
What exists: docks (`docks.odin`: Offhand, Rail, Shelf, Dock_1..4) already take Left/Right (shelf Bottom) or Float,
with soft alignment (`dock_align`) and swap on an edge (`dock_place_set`), but only Edit docks (`lens_arrange.odin`)
shows the head that carries one and the curved corner that sets its lines.
- D1: every dock always carries a faint grip at its start (a short pill, the text_tertiary colour at ~35%, full on
  hover or press) and a faint corner on the side facing the view's middle. The grip's drag carries the dock exactly as
  Arrange's head does (outline, edge strips, soft alignment, swap); a tap opens the dock menu. The corner's drag sets
  the lines. Arrange's head and corner become these same two controls, so there is one way to move a dock; Edit docks
  keeps only what changes a dock's buttons (rings, +, New dock).
- D2: `Dock_Edge.Top`. Any dock takes Left, Right, Top, Bottom or Float; Top and Bottom lay its buttons in a row
  (lines become rows), centred along the edge at `along`. A top dock stands under the top bar; the columns start
  under it and stop above a bottom one. The shelf takes Top and Bottom (its tiles are a row) and Float.
