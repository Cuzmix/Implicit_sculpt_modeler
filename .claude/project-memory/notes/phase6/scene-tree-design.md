# Phase 6 item 2: Scene tree (groups, parenting, solo, ghost, column drag, multi-select transform)

Roadmap row: "Scene tree: groups, parenting, solo, ghost, column drag, multi-select transform" (A-09 · N006, C010, Z160),
done when "50-object scene stays manageable". Audit A-09: "No scene hierarchy beyond a flat object list (no
folders/groups, no instance, no visibility-per-group)", `kit_scene.odin`.

## What exists
- `Scene{objects: [dynamic]^Object, selected: int (index), next_id}`. `Object{id, name (owned, "" = "Sphere <id>"),
  transform (world), file, levels, gpu, hd_gpu, boolean}`. There are no visibility flags at all: every object is always
  drawn and pickable.
- The Scene tab lists every object as a `ui.list_row` (click selects, right-click or long-press opens the object menu:
  focus, duplicate, delete), then Duplicate and Delete buttons, then the Add / Material / Studio / Camera sections.
- Every consumer treats `obj.transform` as the world transform: brush (`to_local`), raycasts (`scene_raycast`,
  `scene_raycast_surface`), the gizmo, booleans, project detail, retopo's other objects, the draw list, files.
- Scene file version 7 (`files.odin`). Swap undo snapshots hold an object as `object_put` writes it, plus its index.

## Design: three PRs

### PR 1: groups, visibility, ghost, solo, rename (the tree itself)
- **Data.**
  - `Object` gains `group: int` (a group id, 0 for none), `hidden: bool`, `ghost: bool` (drawn, never picked).
  - `Scene` gains `groups: [dynamic]Group` with `Group{id, name: string (owned), open: bool, hidden: bool,
    ghost: bool}` and `next_group_id`. Groups are one level deep, as ZBrush's SubTool folders: enough to keep 50 parts
    in a handful of named rows; nesting adds drag-target and indent complexity for little gain on a tablet.
  - An object's members stay in `scene.objects` order. A group's members are contiguous in that list (kept so by
    every operation that changes groups or order), so the tree is drawn by walking the list once and no second order
    exists to drift.
- **Shown and pickable.** `object_shown(app, obj)` = not hidden, its group not hidden, and not solo'd away.
  `object_pickable` = shown, not ghost, group not ghost. These two procs are the only places that read the flags:
  - the draw list skips objects that are not shown; a ghost is drawn in the idle colour at 45% (alpha via the existing
    colour), never selected-coloured;
  - `scene_raycast`, `scene_raycast_surface` and the Move tool's select skip objects that are not pickable;
  - the selected object stays selected when hidden (its panels still work), but brushes refuse to start on it
    (`sculpt_frame` already needs a raycast hit, so this falls out);
  - booleans, Project detail and retopology's "other objects" keep using all objects (hiding a cutter must not change
    the result silently); the Booleans section says when a marked object is hidden.
  - The idle cache keys on the draw list, so hiding or ghosting changes it without new invalidation code (to verify).
- **Solo.** `Solo` command (and a row action): shows only the selected object (or the selected group's members);
  running it again, or Solo off, puts back exactly the visibility there was. Stored as `scene.solo: int` (object id, or
  -group id, 0 off) rather than by rewriting flags, so leaving solo cannot lose a hidden flag.
- **Tree panel** (replaces the flat list in the Scene tab, same place):
  - A new `ui.tree_row(ctx, name, label, detail, depth, selected, open: ^bool (nil for a leaf), toggles: []Row_Toggle)`
    in `src/ui`: indent by depth, a disclosure chevron for groups, the label and detail, and trailing icon toggles (eye,
    ghost) each a full touch target (48 pt), returning clicked / menu (right click, long press) / which toggle flipped.
    Tested in `ui` like the other widgets (hit areas, toggles do not select the row).
  - Group rows show the member count and total vertices; folded groups hide their members.
  - Row menu (long press / right click), objects: Focus, Rename, Duplicate, Delete, Move to group > (each group, New
    group, No group), Solo. Groups: Rename, Solo, Select members (PR 3), Ungroup, Delete group and its objects.
  - Rename: a text field in a popover over the row (as the value entry), Enter applies.
  - With more than ~12 rows the list scrolls inside the tab like the rest of the inspector; nothing new.
- **Commands** (registry, palette words, help rows): Group selected (Ctrl+G), Ungroup, Hide object (H), Show all
  objects (Alt+H), Solo (/ is taken by the palette: Shift+S), Ghost, Rename object. Exact keys checked against the
  keymap for clashes before building.
- **Undo.** Arrangement changes are undoable as one step each: a new `History_Kind.Arrange` entry holding an owned
  `^Scene_Layout{order: []int (object ids), groups: []Group (names cloned), membership: []int}` before and after,
  freed by drop_redo / forget-all like swap snapshots. Rename, group, ungroup, move to group and (PR 2) reorder record
  it. Visibility, ghost and solo are view state: not undo steps (as Blender's eye and ZBrush's SubTool eye), but saved and
  counted in `scene_edits` for autosave.
- **Files.** SCENE_VERSION 8: after each object, its group id and flags; after the objects, the groups (id, name, open,
  hidden, ghost) and the solo id. Version 7 and older read with no groups and everything shown. A group id an object
  names that is not in the list (a damaged file) becomes 0, never an assert. `object_put` writes the flags so swap
  snapshots keep them.
- **Stats:** `groups`, `objects_hidden`, `objects_ghost`, `solo`, `tree_rows`.

### PR 2: drag to reorder, column drag
- Dragging a row by its body (mouse: past 4 px; finger and pen: a long press then drag, since a plain finger drag
  scrolls the inspector) lifts it; a drop line shows between rows; dropping onto a group row puts it in that group,
  between rows of another group moves it there. One Arrange undo step.
- Column drag (N006): a press on an eye (or ghost) toggle that then slides up or down the column sets every row it
  crosses to the state the first toggle took, as Nomad does; one pass, view state, not undone.
- Order matters for booleans (the base is the first unmarked object) and the tree says so on the base row ("base").

### PR 3: multi-select and transform together (the "parenting" of this item)
- `Scene.selected` stays the primary (index; every existing panel keeps working on it). `Scene.also: [dynamic]int`
  holds extra selected object ids. Ctrl or Shift + click on a row (and a Select toggle in the row menu for touch)
  adds or removes; a group row's Select members selects them all with the first as primary.
- The gizmo transforms every selected object together about the primary's gizmo centre (or the pivot): each member's
  new transform is computed from its own start transform with the same delta (`turn_about` / `scale_about` /
  translation), and the drag records one undo step made of chained `.Transform` entries (the existing `chain` flag).
- Selecting a group and dragging the gizmo moves the group: this is the parenting the roadmap asks for. A true
  transform hierarchy (child transforms relative to a parent) is left out on purpose: about 40 call sites read
  `obj.transform` as the world transform (brush, raycasts, booleans, project, retopo, files, the gizmo), a hierarchy
  would make each of them ask for a computed world transform, and a group transformed as a set gives the same result for
  blockout and posing without that risk. Revisit if posing needs per-part pivots that follow a parent.
- Viewport: Ctrl + click on an object with the Move tool adds it to the selection; the others are tinted between the
  idle and selected colours.

## Tests
- ui: `tree_row` hit areas (a toggle never selects, a chevron folds), depth indent.
- app: visibility rules (`object_shown`, `object_pickable` with group flags and solo, solo restore), raycast skipping
  hidden and ghost objects, Arrange undo/redo of group/ungroup/rename/move-to-group with interleaved strokes and swaps,
  file round trip v8 and reading v7, a damaged group id, multi-select transform as one chained step (PR 3).
- Touch scenarios (desktop simulation): hide via the eye (draw count and pick miss), ghost cannot be selected by a tap,
  solo and back, group then fold, rename by long press, (PR 2) drag a row into a group with a finger, column drag over
  four eyes, (PR 3) Ctrl+click two rows and move both with the gizmo, one undo.
- Perf: a 50-object scene (`--objects=50` flag, small spheres) – tree layout time in `ui_ms_p50`, frame time with 25
  hidden; the PNG of the tree with two groups, one folded.

## Not in this item
- Instances and clones (finding 78), repeaters (82), per-object boolean badges beyond what Booleans shows.
- Nested groups.

## Architect review (2026-10-26): approve with changes
Required changes, all taken:
1. Ghost is an opaque tint in this item (idle colour darkened, never picked): the mesh pipeline has no blending and
   mesh.frag writes alpha 1, so see-through ghosts need their own pipeline and design.
2. Autosave writes only the header and each `object_put_bytes`: folders and solo go in `scene_header_put`, the
   per-object folder id and flags inside `object_put_bytes`, read by `object_get` from version 8.
3. Arrange entries are freed in `history_clear`, `history_drop_redo` and the swap-limit trim, stepped before
   `entry_sculptor`, labelled in `history_next_label` and coloured in `KIND_COLORS`.
4. Applying a layout tolerates missing and extra objects (reorder listed ids, keep the rest in place, remap selected by
   id); one `scene_folders_normalize` keeps members contiguous and drops unknown folder ids, called after a layout,
   a file open and a swap, with a test-only invariant check. Deleting a folder with its objects records Arrange first.
5. Duplicate and Slice place the new object right after its source in its folder (`scene_insert`).
6. Undoing a swap keeps the live object's view flags and folder.
7. Hiding the selected object selects the next shown one, or nothing; focus, frame all and the double tap frame shown
   objects only.
8. Hidden objects are still uploaded (only the draw is skipped); the live boolean preview is not drawn when its base is
   hidden; the list marks the boolean base, and the Booleans section says when it is hidden.
9. Hide, ghost, solo, show all, rename, folder and move-to-folder are Scene_Commands (rename with a fixed buffer).
10. A solo id whose object or folder is gone counts as off.
11. PR 2: the row menu owns the long press, so reordering uses a grip on the row and column drag claims the press
    before the inspector scrolls.

Names: "Folders" (as ZBrush), because Group means polygroups here; the per-object flag is `off`, because hidden means
hidden triangles. Show all objects is Alt+H beside Ctrl+H (show hidden triangles); both say what they show.

Split: PR 1a (eye, ghost, solo, show all, file v8, base badge, no undo), PR 1b (folders, Arrange undo, tree_row), PR 2,
PR 3. PR 3 notes: one shared clamped scale factor, every moving member live, typed values and the inspector act on all
selected, `Scene.also` pruned on delete, swap and replace.
