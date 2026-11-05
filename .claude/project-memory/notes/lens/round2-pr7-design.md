# Lens round 2, PR 7: corner drag and pane gestures

Screens `split3` and `areaGest`. Lens chrome only: Classic keeps its preset menu and plain dividers, but the layout
model underneath changes for both, because there is one `View_Grid`.

## What exists when done

- The view grid is a **split tree** of at most four panes. The six presets are trees, and the View layout menu still
  gives them in one tap.
- **Corner handles** (Lens): every pane corner has a small rounded bracket. On touch and pen it always shows; with a
  mouse it shows when the pointer is within reach of it. The hit area is a 44 pt square inside the pane at its
  visible corner (clamped into the free area, so not under the top bar, the rail, the island or the dial). Handles
  are off while a stroke is active and for 0.4 s after one, and drawn first, so the pane head chips win where they
  overlap.
- **Split**: drag a corner inward. Past 14 pt the dominant axis picks the cut and locks it: sideways gives left and
  right, up or down gives top and bottom. A live line, the share pill ("Split · 43 / 57"), the new part tinted with
  "New pane · copies Front", and the hint "Back to the corner cancels · into the next pane joins" follow the finger.
  Ctrl snaps the share to ¼, ⅓, ½, ⅔ or ¾. Each part keeps at least a tenth of the room. The new pane is the part on
  the corner's side and copies the pane it was cut from (a view pane's camera and pass; for the main view an
  independent camera where the main view is now and the main pass where a view pane can show it, else Shaded). A
  fifth pane is refused: the handle shakes and the pill says "Up to four panes".
- **Join**: in the same gesture, carry on out of the pane into a neighbour. The neighbour must share a whole edge with
  the pane (their union is a rectangle). The pane dragged from brightens and the neighbour dims with "Let go to join".
  The main view never closes: dragging into it says "The main view stays", and a pane that does not line up says
  "These panes don't line up". Back to the corner, Esc, or a second finger cancels.
- **Swap and move**: a view pane's camera chip drags its pane (a tap still opens the list). Over another pane five
  targets show at its centre. The centre third of the pane swaps the two (no view is lost; the main view can be
  swapped into another place this way). The four triangles between the diagonals dock the pane on that edge, half of
  the target pane, and the preview tints where it will go.
- **Dividers**: each split is a divider. Dragging one keeps the dividers inside it where they are (three across moves
  only the one held). Ctrl snaps; Shift moves every divider lined up with it. Double tap evens it (a run of same-way
  splits gets equal shares, so three across goes to thirds). PR 6's drag to the far edge closes the side beyond,
  unless the main view is there. Right click or long press opens a menu: Split here (cuts the pane on the pressed
  side across, through the pressed point), Join (keep one side, only when both sides are single panes; the main view
  is always the one kept), Swap (the two sides trade places) and Even out.
- **Undo**: every pane gesture (split, join, swap, dock, close, divider drag, the divider menu, choosing a preset)
  is a layout step that Ctrl Z takes back and Ctrl Shift Z does again, in order with the scene's steps.
- The main view's chips (camera, pass, object) stand at the top of the main pane wherever it now is.

## Model

```odin
Grid_Node :: struct {
	split:    bool, // false: a leaf showing pane `pane`
	vertical: bool, // a split's cut runs up and down: `a` is left of `b`; else `a` is above `b`
	share:    f32,  // the part of the split's room `a` takes
	a, b:     u8,   // a split's children, indices into the tree's nodes
	pane:     u8,   // a leaf's pane: 0 the main view, 1 to 3 view panes
}
Grid_Tree :: struct {
	nodes: [GRID_PANES * 2 - 1]Grid_Node, // node 0 is the root
	count: u8,
}
```

- Invariants after every operation (`grid_tree_normal`): the nodes are compact in depth-first order, the panes shown
  are 0 to n-1, and the view panes are numbered in depth-first order. Renumbering returns a permutation that moves
  `g.views` and `app.panes` (the pictures) with their panes, so nothing redraws needlessly.
- `View_Grid` keeps `tree` and `views: [GRID_VIEWS]Second_View` (no longer one set per preset); `preset` and `split`
  go. `grid_panes(g)` replaces `grid_count(g.preset)`. `grid_shape(g)` names the preset a tree matches by structure
  (shares and pane order aside) for the menu's check, the `View_Grid` command's `checked` and the stats (`grid=Four`,
  or `Custom`).
- Choosing a preset builds its tree with default shares. Panes already shown keep their views; added ones start as
  `new_panes` says. Choosing the shape already shown does nothing. (The old "each preset keeps its splits and panes
  while the app runs" goes: the tree is the one layout.)
- Operations, pure on `View_Grid` and unit tested: `grid_split_pane`, `grid_join` (union of unit rects, then the
  tree is rebuilt from the rects by guillotine cuts; with at most four panes the result is always a guillotine and
  unambiguous), `grid_swap`, `grid_dock` (remove the pane, its sibling takes the parent's place, then split the
  target), `grid_close_side`, `grid_swap_sides`, `grid_even`, `grid_move_divider` (keeps same-way descendants'
  absolute lines, clamped so every pane keeps a tenth of the room).
- Each operation bumps `g.serial`; work in a pane ends when the serial changes (replacing `work_preset`).

## Files

- `grid.odin`: the tree, layout of cells and dividers from it, preset trees, layout lines, the reading of old lines.
- `lens_areas.odin` (new): corner handles, the corner gesture, the chip drag and its targets, the divider menu,
  Shift and Ctrl on dividers, and the layout undo.
- `lens_panes.odin`: the PR 6 close and even move onto the tree operations; `grid_close_target` and its preset
  table go.

## Layout lines (workspaces)

- New: `panes v600 0 h500 1 2`, the tree in prefix order: `v` or `h` with the share in thousandths for a split, the
  pane number for a leaf. Then the `pane <1-3> <camera> <pass>` lines as before. Nothing for one pane.
- Old: `grid <preset> <x> <y>` still reads, as the preset's tree with those splits (three across's second split was
  a share of the whole room and is converted). A word that does not parse leaves the grid as it was.
- Workspace files and the settings file keep reading every older version. The `.sculpt` scene file stores no grid,
  so `SCENE_VERSION` does not change.

## Undo

- `Grid_Undo` in `View_Grid`: up to 16 steps back and forward, each the tree and views before the step, and how long
  the scene History's done list was when it was made (`done`).
- The Undo command takes back the layout step first when the newest layout step's `done` is at least the length of
  the History's done list (nothing newer happened to the scene since); else the scene's. Redo prefers a layout step
  whose `done` equals the current length, so a mixed sequence comes back in its order.
- A new scene step clears the layout redo list (one call in `history_push`); a new layout step clears it too. A
  workspace switch or layout reset clears the layout steps, since they name another layout.
- Nothing else in the History changes; the History panel's timeline shows scene steps only.

## Stats and tests

- Exit stats: `grid_tree=` (the layout line), `grid_splits= grid_joins= grid_swaps= grid_docks= grid_undos=
  grid_refused=`; `grid=` becomes the shape name.
- Unit tests: presets as trees tile the room; split, join (siblings and the four-pane column case), swap, dock,
  close, even and divider moves keep the invariants and the main view; old `grid` lines read; the layout line round
  trips; undo and redo interleave with scene steps in order.
- Touch scenarios: corner drag splits, a fifth split is refused, a drag into a neighbour joins, back to the corner
  cancels, a chip drag swaps and docks, Shift moves lined-up dividers, the divider's long press menu, Ctrl Z takes a
  split back.

## Changes after the architect review (as built)

- Undo order uses time ticks, not the done list's length: a layout step stores `time.tick_now()` and is undone first
  when it is newer than the History's last done entry's `at`, redone first when older than the next undone entry's
  `at`. Trimming, scrubbing and the cap no longer confuse it. `history_drop_redo` (every new scene step) clears the
  layout's redo list. Only the Undo and Redo commands interleave; the timeline, adjust-last and stroke cancel stay
  scene-only. Their `enabled` checks both lists.
- Pane numbers are stable: no depth-first renumbering. A split's new pane takes the next number; when panes close,
  the highest-numbered pane takes the freed number (`grid_tree_fill`), its view and picture moving with it as whole
  structs (`grid_pictures_follow`). Untouched panes keep their colours.
- Gestures queue a `Grid_Op` applied at the start of `kit_grid`, never in the middle of a layout, and never while a
  view pane holds the main view's role (`grid_work`).
- Edges compare within 2e-3 (wider than the thousandths saved), and dividers keep 120 pt as well as a tenth of the room.
- Old `grid` lines in saved workspaces are rewritten as `panes` lines once on load (`grid_layout_upgrade`), so the
  modified dot does not show after the upgrade; `kit_layout_put` resets the tree and clears the layout steps.
- `grid=` keeps the preset spellings (`Side_By_Side`), or `Custom`; `grid_split=` gives the first two splits' shares.
- Corner handles are off while a pane is maximised. The render preview's Single to Side by side goes through
  `grid_choose`, so it is a layout step; the view window default reads `views[0]`.
- Kept from the plan against the review's advice to cut: docking, Shift on dividers and the divider menu's Split here
  and Swap sides. Each is small on top of the tree operations.
