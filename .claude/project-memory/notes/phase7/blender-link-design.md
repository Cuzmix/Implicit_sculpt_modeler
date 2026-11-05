# 7.5 Live link with Blender: design

The roadmap item is "Live link with Blender" (N022, Z103). The model is GoZ: one action sends the selected objects to the other app, and the other app sends them back, with no file dialogs. The links in ZBrush (GoZ) and Nomad 2.9 ("Link") are the references.

## What exists
- Export writes the shown level's own vertex and triangle order: PLY (binary, exact floats), OBJ (6 decimals), glb and usda.
- Import reads OBJ and PLY and makes a new object.
- `sculpt.sculptor_project(s, next, colors, strength)` moves every vertex to `next` as one undo step (Project detail uses it). It goes through the sanctioned path (stroke_begin, record_hit, nodes_moved) and respects the mask.
- `object_remesh` and its siblings rebuild an object with new topology as a swap entry (`history_snapshot` / `history_record_swap`).
- bpy 5.2.3 runs here (`build/export-tools/venv`, from `scripts/export_check.py --setup`). I checked a Blender round trip: Blender's binary PLY keeps the vertex count, the vertex order and the face list, and only the moved vertex differs. OBJ keeps the order too, but rounds positions to 6 decimals.

## What it does
**Sculpt to Blender.** A new command, **Send to Blender** (File menu, and Search; `send_to_blender` in scripts), writes the selected objects to the link folder:
- Each object's shown level goes to `<id>.ply`, binary, with vertex colours when it has paint.
- `link.txt` is rewritten whole and durably (write_durably):
  ```
  sculpt_link 1
  sent <seq>
  object <id> <name escaped> <id>.ply <vertices> <triangles> <px> <py> <pz> <rx> <ry> <rz> <scale>
  ```
  `<seq>` is a counter kept in the folder, which rises with each send.
- A note says "Sent 2 objects to Blender (Get from Sculpt in Blender's Sculpt panel)".

**Blender add-on.** `tools/blender/sculpt_link.py` is a single-file add-on, written so it also loads as a Blender 4.2+ extension through a manifest beside it. It adds a Sculpt tab to the 3D view's sidebar with:
- **Link folder**: the default is the app's folder on that OS (below).
- **Get from Sculpt**: reads `link.txt`. For each object it makes or updates a mesh object with the custom property `sculpt_id`:
  - if the vertex and face counts match, it sets positions in place, which keeps the mesh's UVs, modifiers and materials;
  - otherwise it rebuilds the mesh.
  - Placement comes from the transform, converted from the app's Y-up axes to Blender's Z-up.
- **Send to Sculpt**: writes the selected mesh objects as `<sculpt_id or "new-N">.ply` plus `blender.txt` (`blender_link 1`, `sent <seq>`, then one `object` line each).
  - Objects are triangulated on a copy, since the app is triangles only. A mesh that came from Sculpt is already triangles, so its order is kept.
  - Modifiers are not applied, so the topology stays matchable. A checkbox "Apply modifiers" turns that on, at the cost of a topology swap on return.
- **Auto get**: a `bpy.app.timers` check every second on `link.txt`'s sequence number. It is off by default.

Nothing is executed across apps: it is files in a folder.

**Blender to Sculpt.**
- **Get from Blender** (command and script verb `get_from_blender`) reads `blender.txt` when its sequence number is newer than the last one taken. The app also checks by itself when its window regains focus, as GoZ does when you switch back, with no polling. Each object line is handled at the start of the next frame as a file request (`File_Kind.Link_Get`), never in the middle of a frame:
  - **Known id, same vertex and triangle count, identical triangle list** (checked against the shown level's indices): `sculptor_project` to the returned positions at strength 1 is one undo step, "From Blender". Levels above carry it as a stroke at that level does. Masked vertices keep their place, as for any deformation, and the note says how many. In HD or with dynamic topology on, this falls through to the swap below.
  - **Known id, other topology:** the object_remesh path, as one swap undo entry, "From Blender (new topology)". The stroke ends, HD is left, and the object is rebuilt from the mesh, which drops its levels, mask and layers. Its name, transform and material stay.
  - **Unknown id** (`new-N`, or an object deleted since it was sent): added as a new object beside the others, as Import does, named after the Blender object.
  - The transform comes back too. A changed one becomes the object's transform, in the same undo step.
- One note covers the whole get: "From Blender: Head (moved 1,204 vertices), Hat (new topology), Cube (new object)".

**The link folder.** It sits beside the settings, `link/`, like `library/` and `macros/`. `--link-folder` overrides it for tests. Settings > System shows its path, with **Copy path** (the clipboard through SDL) so it can be pasted into the add-on. The add-on's default guesses the same place: `%APPDATA%` on Windows, `~/.local/share` on Linux, as `settings_path` does. That needs checking against `settings_path`.

**Platforms.** Desktop only. On Android the commands are hidden and the script verbs refuse: there is no Blender to link with. Store rules: no network, no new permission, files only in the app's own data folder. On iPad later this needs a document-picker exchange, which is out of scope.

## Package boundaries and rules
- The new app file is `src/app/link.odin` (about 350 lines).
- The add-on is Python under `tools/blender/`, outside the Odin build. The build scripts ignore it and `agents_sync` is unaffected.
- PLY reading and writing reuse `geom` (`mesh_write_ply`, `mesh_read_ply`).
- No new Scene_Command kind: the get is a file request (`File_Kind.Link_Get`), applied at the start of the next frame like Import.
- Undo: same topology goes through `sculptor_project` (sanctioned); new topology copies `object_remesh` (stroke end, leave HD, rebuild, swap entry).

## Tests
- **Unit** (`link_test.odin`):
  - the manifest round trip (escape, damaged lines skipped);
  - same-topology return as one undo step that undoes back exactly;
  - a different triangle list making a swap entry, which undoes to the old levels;
  - an unknown id adding an object;
  - a sequence number already taken doing nothing;
  - a damaged PLY refused with a note and the scene unchanged.
- **Round trip with real Blender**: `scripts/link_check.py`, like export_check. It sends from the app (`--script=send_to_blender`, exit), runs the add-on's own functions in bpy (get, move a vertex, rename, add a cube, send), then runs the app with `--script=get_from_blender` and checks the exit stats (`link_moved`, `link_swapped`, `link_added`) and `--check-mesh`. It is skipped when bpy is missing. It does not go in the gate, as export_check doesn't.
- **Touch scenario**: Settings > System shows the link path, and Send to Blender writes `link.txt` (stat `link_sent`).

## Split
- **5a:** link.odin (send and get, manifests, undo paths, focus check), commands and verbs, Settings row, README, unit tests.
- **5b:** the Blender add-on, link_check.py, a README section on installing it, and the round trip verified in bpy.

## Open questions, with defaults
1. What goes: the shown level (GoZ sends the lowest). Default: the shown level, so what you see is what goes.
2. Masked vertices keep their place on return. Alternative: ignore the mask. Default: keep, as every deformation does, and say so in the note.
3. Paint goes out as vertex colours. Paint coming back: default yes when the counts match, through `sculptor_project`'s colours.

## Architect review (adopted, 2026-10-27)
The review asked for seven fixes; all are taken, and they replace the text above where the two differ.
1. **Local positions.** The link writes the shown level's own positions (scale 1, offset 0, never Object.file), so a return Blender left alone is bit-exact and `sculptor_project` records nothing. The manifest carries the object's Transform (the file placement is for exports only).
2. **Own reader.** Projection reads with `geom.mesh_read_ply` and a finite check only; the swap and add paths clean (`mesh_clean`) and turn closed inward meshes outward, but never normalize.
3. **HD.** A return in HD leaves HD and projects (as Project detail does); it never swaps.
4. **Level.** The manifest records the level sent; the get shows that level before comparing. A level that is gone makes the object come back as a new object.
5. **Scene token.** `link.txt` carries a token made per scene (new on every scene_replace); Blender echoes it. A wrong token makes every object new. File names must match `[A-Za-z0-9-]+\.ply`. Blender writes `blender-<id>.ply`, so the app's own files stay.
6. **No paint back in 5a.** Paint goes out; nothing of it comes back yet.
7. **Focus.** Focus sets a flag; the check runs at the start of a frame only when no request, dialog, save, stroke or drag, script or pack install is pending, and never in runs with --frames or a start-up script. It posts a request rather than applying, so it is never recorded into a macro.

Also adopted: voxel objects come back as a mesh (an explicit "converted to a mesh"); dynamic topology objects swap; layers carry across a swap (object_rebuild's layer_carry); the whole get is one undo step (first entry unchained, the rest `chain`, `history_record` gains `chain`); a big get shows a busy toast first (`SAVE_SHOW_FIRST`, through `app.saving`); a get warns when the object changed here since it was sent (a History entry of its id newer than the send); the folder is `link_folder(settings)` (`link` or `<stem>-link`), no new flag; hidden on Android.

## As built (5a and 5b in one PR)
- App: src/app/link.odin; File_Kind Link_Send/Link_Get (big ones through app.saving's busy toast); scene file v17 = link token (u64, made by the first send, view_edits); `taken.txt` in the folder notes the newest Blender send taken (persists across runs; reviewer blocker); focus check via file_post_when_idle, waits for timeline/replay/history/script/pack.
- Plan: id 0 / other token / deleted → Add; voxel or dynamic → Keep when identical to the `<id>.ply` sent, else Swap; level gone or renumbered (sent vertex count differs) → Add; same triangles → Project (one Deform entry, chained), else Swap. One undo step via `chain`.
- Add-on: tools/blender/sculpt_link (extension manifest, GPL-3.0-or-later), numpy PLY IO, Y-up→Z-up in matrix_world only, untouched placement echoed word for word, non-uniform/mirrored scale baked (mirror flips winding), Shift+D copies go as new, Auto get timer.
- Checks: link_test.odin (4 tests), touch scenarios blender_link_round_trip, blender_link_keeps_voxels_and_dynamic, settings_system_shows_the_link; scripts/link_check.py (real bpy round trip, 9 checks; --package writes build/sculpt_link.zip).
- Not done: paint coming back; iPad exchange; a real Blender GUI session (bpy module only).
