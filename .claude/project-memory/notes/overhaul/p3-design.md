# P3 Objects outliner (panels round, mock S.mObjects in round3/panels3.js)

Split in two PRs.

## P3a (this PR): the Scene card becomes the outliner
- Head: Find an object (always shown) + Add, a popover: the mesh shapes at the Add object
  size (Starters folded), Voxel sphere, Cage primitives (folded), Sun / Point / Spot light.
- Kind chips with counts (All, Meshes, Voxels, Cages, Lights), only the kinds present, the
  row only when two or more kinds are present. Kit state, not saved.
- Object rows: picture, name with badges (L<n> when the object has levels, HD), the kind
  and size under it (Mesh 81k tris, Voxel clay 128 across, Cage 6 faces), eye, lock, and a
  ⋯ toggle that opens the object menu under it (the same menu as a right click).
- Lights: one foldable Lights row after the objects (folded by default, open under the
  Lights chip) holding a row per light: kind icon, name, kind and colour temperature and
  what it moves with, an eye (one undo step through light_drag_changed), ⋯ opens the
  Lights section; a tap picks the light.
- Foot: Group, Duplicate, Delete on the selection. New folder (Ctrl+G) now takes every
  selected object, as Blender and Photoshop group.

## P3b: Spaces dots
- Per-object Sculpt/Model/Render visibility, a byte in the scene file (next version),
  object_flags hides an object in a space it is off in; the dots open a three-check menu
  (touch-safe, the 7 pt dots alone are too small for a finger).

## As built
- P3a #361. P3b: Object.spaces_off (bit_set[Space; u8]) in the view byte's bits 4-6, scene
  version 33; object_flags folds it in; View_Change Space_Hide/Space_Show with
  Scene_Command.space; ui.Thumb_Row.dots + dotted, kit_scene_spaces_menu (Show in, stays
  open). Mesh rows' detail is now only the triangle count (room for the dots).
  Layer masks (P2) therefore take scene version 34.
