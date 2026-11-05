---
name: lens-mock-layout
description: Building the Sculpt Workspace Directions option C layout (Lens) in the app; Classic removed 2026-10-29; round 2 PRs #227-#236; touch_check conventions after Classic
metadata:
  type: project
  modified: 2026-10-28T07:54:33.844Z
---

Bolt, 2026-10-28: make the app look and behave like the Sculpt Workspace Directions mock (option C, Lens), with today's layout kept as "Classic". Gap list and 9-PR order: /mnt/project-files/notes/lens/mock-layout-gaps.md. Design and per-PR notes: notes/lens/mock-layout-design.md.

- 2026-10-29 Bolt: Classic REMOVED (thread "Remove the Classic layout", PR #275 merged 2026-10-29): Lens is the only chrome, no `k.chrome`, `--chrome` or `Chrome_Classic`; an old settings file's `chrome classic` line is read and ignored. The containers keep their old names (island "brush bar", chips "points", rail "view bar", shelf "dock"). ui.vslider has `roll := true`; the island passes roll = false (it doubles size per quarter turn itself).
- touch_check: no LENS/--chrome. MIDDLE = (647, 432) at 1600x900. Old tray sections are reached with `palettes_only(section)` (a workspace with only the Palettes card), at the old tray coordinates +50 in y. The shelf's lift is `dock_lift(app)` (22, 0 in Focus), which the action bar, wheel and shape bar keep clear of.
- PR 1, the Lens top bar: **#226 merged** (kit_top_lens.odin; the file block via `app.saved_at`; the workspace pill laid inline; a `begin_at` inside the bar lost hits).
- 2026-10-28 07:35: Bolt asked for more planning before PRs 2-9:
  - a full-screen viewport with panels over it, as ZBrush has;
  - keep the shortcut dial (the modifier wheel);
  - question the shelf's Sculpt/Paint/Move/Curve segment;
  - a new mock, then a screen-by-screen design pass, keeping sculpting ergonomics in mind.
  The "Explore new UI direction in Figma" thread replanned it: 2026-10-28 Bolt approved all round 2 screens; new plan /mnt/project-files/notes/lens/round2-build-plan.md (11 PRs, replaces PRs 2-9) sent to the coordinator. See [[ui-screens-round2]].

- Round 2 build (this thread, "Build the Lens mock layout"): PR 1 full-window viewport **#227 merged** 2026-10-28 (lens_view.odin: `Orbit.shift` projection shift, `lens_free_area`, `view_fit_free`, Clean view on Tab in Lens via `keymap_lens`, panel fade under strokes). PR 2 **#228 merged** (lens_chrome.odin: off-hand island under the "brush bar" name, view chips under "points", view rail `Bar_Which.View_Rail` zone view_rail under "view bar", mini view = Lens thumbnail with tap-to-swap, nav head left of the rail). PR 3 **#229 merged** (lens_shelf.odin: shelf = "dock", pages `Bar_Which.Shelf_*` kept in settings but not workspace layouts, quick settings on long press, brush picker sheet, B = Brush_Picker in Lens). 4a panel stack **#230** (lens_stack.odin, layout line `stack`), 4b brush pie **#231** (`Bar_Which.Brush_Pie`), PR 5 resizable stack/cards **#232** (lens_resize.odin, layout line `stack_size`), PR 6 split views chrome **#233** (lens_panes.odin: chip heads, divider grip/double tap/edge close, `new_panes` setting, stack tab strip). PR 7 corner drag **#235 merged**: grid became a split tree (`Grid_Tree`, layout line `panes v600 0 h500 1 2`, old `grid` lines upgraded), gestures in lens_areas.odin, layout undo ordered against History by `at` ticks. PR 8 Focus/Menu/Search **#236 merged** (lens_menu.odin submenus, lens_search.odin palette_where/Put on a bar, lens_focus islands). PR 9 split into 9a Scene+Layers cards (object lock = 4th view bit, scene v25) and 9b Tools card; design notes/lens/round2-pr9-design.md. Design notes notes/lens/round2-prN-design.md; screens notes/lens/screens/round2/.
- Gate takes ~25 min; never edit the working tree while it runs (wincheck/android compile it): stage next PR in scratch files + apply.py.

**Why:** Bolt wants the mock's layout, not only its logic, but is refining the mock first.
**How to apply:** Lens is the only layout; never reintroduce a second chrome. See [[lens-p1-rounds]], [[ui-direction-lens]].
