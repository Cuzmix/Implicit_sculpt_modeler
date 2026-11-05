# Phase 6 item 3: Selection model

Roadmap row: "Selection model: saved selections, mask ⇄ group ⇄ hide conversions, mask by cavity" (Z097, C026, Z037).
Research: one selection concept with three names (mask, group, hide) costs learnability (finding 23); 3DCoat makes them
fully interconvertible (C026); ZBrush 2027 has Selection Sets but they break on remesh (Z097).

## What exists
- Mask by cavity (`Mask_Command.Cavity`, PR #21): done, nothing to add.
- Mask → group: Group masked (`Group_Command.Masked`). Shown → group: Group visible.
- Group → mask: `sculptor_mask_group` (a tap on a group with the mask modifier). Group → hide: `sculptor_hide_group`.
- Hide: shapes (rectangle, lasso), Show all (Ctrl+H), Invert (Ctrl+Shift+H).

## What this adds (two PRs)

### PR A: the missing conversions (sculpt + commands, no new state)
- `Hide_Command.Masked` and `.Unmasked` (sculpt/hide.odin):
  - **Hide masked** hides every shown triangle whose three corners are masked at least half (≥ 128).
  - **Hide unmasked** hides every shown triangle with a corner under half, so the two are exact complements. Ctrl+Shift+H (Invert) flips between them.
  - Each is one undo step through the hide record path the shapes use.
  - Refused under dynamic topology, as the other hide commands are.
- `Mask_Command.Hidden` (sculpt/mask.odin): **Mask hidden** sets every corner of a hidden triangle fully masked and every other vertex unmasked.
  - One step through `mask_commit`.
  - The usual flow is hide a part, Mask hidden, then Show all, which leaves a mask of exactly that part.
  - This is the one mask command that writes hidden vertices; the others leave hidden vertices alone.
- Commands in the registry: Hide masked, Hide unmasked, Mask hidden. They have no default keys and get palette words ("freeze", "visibility", "isolate").
  - Hide masked and Hide unmasked go in the Visibility section; Mask hidden goes in the Masking section's More.
  - The contextual action bar shows Hide masked and Hide unmasked while a mask exists.
- Tests in `sculpt/hide_test.odin`:
  - the two hides are complements;
  - Mask hidden, then Show all, gives a mask equal to the hidden region;
  - undo puts back both the hide state and the mask;
  - dynamic topology refuses all three.
- Scenarios:
  - Mask a rectangle, then Hide masked: `hidden_tris` > 0, and one Ctrl+Z gives 0.
  - Hide a rectangle, then Mask hidden, then Show all: `masked` > 0.

### PR B: Selection sets (named, saved masks), revised after the architect review
- **Where.** `Level.sets` in the sculpt package (levels.odin), so `levels_destroy` frees them on every rebuild (remesh,
  decimate, mirror, slice, booleans) with no code per path; the app counts them first for the operation's note. Retopo
  and Extract leave the source alone, so its sets stay. Duplicate and swap undo carry them (both go through the file
  bytes). A stable `Set_Id` counter in `Levels` names each set (rename, menus) since indices shift on delete.
- **Encoding.** Per set: name (at most NAME_BYTES), id, the masked sum taken at Store (so "N% masked" never decodes),
  and the values in the level's canonical vertex order, either packed runs `{count: u32, value: u8}` (start implied by
  the running sum) when smaller, or raw bytes otherwise: never more than 1 byte a vertex. At most 16 sets an object.
  `levels_bytes` counts them.
- **Validity.** A set belongs to its level and is carried to the current one with the live mask's rule: move
  `levels_carry_mask`'s per-level step into a pure `mask_carry_level(src, dst, from, to, up)`. So a set restores on
  every level, as the mask does. `levels_dyn_enable` drops sets (dyntopo renumbers vertices; its swap undo restores
  them). Store and Restore are refused under dynamic topology and in HD. `levels_delete_lower` shifts the sets' level
  indices down and drops those on removed levels; `levels_delete_higher` drops those above. Each says how many went.
- **Restore** (replace), **Add** (max) and **Subtract** (min(mask, 255 - set)) are one mask undo step each through a new
  `sculptor_mask_values(s, values, mode)` and `mask_commit`; they leave hidden vertices alone, as every mask command but
  Mask hidden does. Store, Delete and Rename are not undo steps (as in ZBrush) and bump `app.scene_edits` for autosave.
- **Scene command.** A new `Scene_Command` kind `.Selection_Set` with the operation, set id, mode and name, so they apply
  at the start of a frame after autosave settles. Restore records through `history_record(.Mask)`.
- **File.** `levels_write` writes the sets after the quads under a new `LEVELS_SETS` flag, scattered through `canon[j]`
  as `write_mask` is, gathered back in `levels_read`; checks `w.abort`, runs serially with no pool. SCENE_VERSION 10;
  version 9 and older read with no sets. Refused unless each set's runs add to exactly the level's vertex count, there are
  at most 16 sets and each name fits. `object_put_estimate` counts the bytes.
- **UI.** Object tab > Select > Masking: a "Selection sets" block with one row per set (name; detail "N% masked"), a tap
  restores, a row menu (Add, Subtract, Store over, Rename, Delete) in `kit_floating` so Back closes it first, 48 dp rows,
  and "Store mask as set". Rename reuses the rename popover keyed by object id plus set id.
- **Commands.** Store mask as set; Restore selection set 1-9 (`command_arg_name` saves them as 1-9; `enabled` false
  for an empty slot). No default keys.
- **Stat.** `selection_sets=` on exit.
- **Tests.** Encoding round trips (empty, full, alternating, 10M zeros; raw chosen when smaller); restore modes; carry to
  another level; dropped on dyntopo enable and on delete lower/higher; survive swap undo, duplicate and a v10 file
  round trip; v9 reads with none; damaged counts refused.
- **Scenarios.** Store, clear, tap the set: the mask is back and Ctrl+Z clears it; after a remesh `selection_sets=0` and
  the note says the sets went.

## Not in this item
- Sets that hold hidden state or groups as well (3DCoat-style layer conversion), and pose selections (item 4, Posing, uses
  the mask as its selection).
- Carrying sets across a remesh (would need a projection like Project detail; revisit after Posing).
