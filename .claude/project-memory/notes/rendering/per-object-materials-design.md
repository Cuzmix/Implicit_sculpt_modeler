# Per-object materials (roadmap 2.2): design

## What exists after
- Each object has its own material: a preset (classic, physically based or MatCap) or its own Custom values.
- The Scene palette's Material section edits the selected object's material, and every object in a multi-selection with it.
- A new object (Add object, import, a starter scene) takes the material last picked: today's global `app.material`/`app.custom`, still a remembered setting.
- An object made from another (duplicate, slice, extract, mirror, Insert, booleans' result) takes its source's.
- "Dim the others" is a switch under the Material section's More options, on by default.
  - On: unselected objects draw in their own material's muted `idle` colour, as every object does today.
  - Off: they draw in their own colours.
- `.sculpt` scenes store each object's material, as SCENE_VERSION 13. An older scene opens with every object in the current default material, which is what it showed before.

## Data
- `Object.material: Material`: the full values, never a reference.
  - `label` points at the preset's static label, or at "Custom".
  - A zero `label` means "not set yet". `scene_append` fills it from the default, so creation paths that do not care need no change.
  - Paths that copy from a source set it before appending.
- `object_material(app, obj) -> Material` is what drawing uses.
- `App.dim_others: bool` (settings row `dim_others`, default true).
- `current_material(app)` stays as the default for new objects. The section's dropdown shows the selected object's material. Picking or editing also updates the default, so the next new object matches what was last picked; this is ZBrush's behaviour.

## File (object_put / object_get_fields, version >= 13)
- Fields, after `vis_off`:
  - label (string)
  - selected.rgb, idle.rgb, shading (4 f32), metallic, roughness (f32)
  - matcap (i32)
- Reading:
  - A label that names a preset takes the preset's static label pointer. Anything else becomes "Custom".
  - Values are checked: finite, colours 0 to 1, roughness 0 to 1, a matcap of 0 to len(MATCAP_RECIPES) or MATCAP_IMAGE. Anything else makes `r.ok = false`, so a damaged file is refused.
  - A MATCAP_IMAGE object with no image loaded falls back to the lights, as `material_matcap` already does.
- History swap snapshots use `object_put`, so remesh, rebuild, undo and redo keep the material without other changes. The same goes for autosave.

## Undo
- A material change is not a History step, as in ZBrush, where materials are outside Undo History.
- It bumps `app.scene_edits`, so the title shows unsaved and autosave sees it.
- Slider drags therefore make no history entries.

## Drawing
- In main.odin's per-object loop, `current_material(&app)` becomes `object_material(&app, obj)`.
- The colour is `m.selected` for the selected object.
- For the others it is `m.idle` when `dim_others`, otherwise `m.selected`. Chosen objects use the same lerp as today.
- The boolean preview uses the base's material.
- Draw_Item already carries every material field, and frame and static keys hash them, so the idle cache and partial redraw invalidate on their own. There is no render or shader change.

## Script and settings
- `set material NAME` is the settings row: it sets the default and the selected object's material.
- `matcap FILE` makes the default and the selected object's material Custom with that image.
- New: `set dim_others off`.

## Tests
- Round trip of per-object materials through object_put/get, including Custom and MatCap.
- A version 12 scene reads with the default material.
- Damaged values are refused.
- Duplicate keeps the material.
- Picking in the section changes only the selection.
- dim_others off draws unselected objects in their own colour (a Draw_Item colour check).
- Section control counts stay within five.

## Review (sm-architect): approved with changes, all taken
1. `object_get` fills the default for version < 13, and `scene_new`/`scene_replace` paths get it that way; `object_material` falls back to `current_material` on a nil label, so a missed path shows the default, never black.
2. `scene_add_mesh` and `add_made_object` take a `material`; slice, split, extract, retopology and Insert of an object pass the source's. Merge visible takes the selected object's (the one the merge is named after).
3. `history_swap` carries `material` across with off, ghost, folder and vis_off: it is not part of the step.
4. Panel edits go through a `Scene_Command` (`.Material`, carrying the Material value); it applies to the selection and the default and bumps `scene_edits` (which ends Adjust last, as any scene edit does).
5. File checks: metallic and roughness 0 to 1, colours 0 to 1, shading finite and non-negative, alpha restored as 1; the label string read from the file is mapped to the static label and deleted on every path.
6. MATCAP_IMAGE is one app-wide image, not stored in the scene: loading another changes every object using it, and another machine shows its own. Documented in README.
