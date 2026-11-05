# Phase 7 item 4: content packs

Roadmap row: "Content packs (brushes, alphas, matcaps, base meshes) · C083 · M · Store-safe on Android". 3DCoat's `.3dcpack` and ZBrush's ZPlugins bundle brushes, materials and scripts; Nomad has nothing. Today:

- Brush presets live in the settings file (`preset` lines). A preset's alpha is stored by name, and only the six built-in alphas exist at every start, so a preset that uses a loaded image comes back round after a restart.
- Loaded alphas (Load image) are kept in memory only. They are gone at the next start.
- Materials are a fixed table (`MATERIALS`) plus one Custom.
- There are no matcaps.
- New scene offers six generated shapes (`NEW_SCENE_SHAPES`); Import adds any OBJ or PLY.

## What will exist

1. **A library**: a folder `library/` beside the settings file (the app's private storage on Android and iPad, since `SDL_GetPrefPath` is that). Each installed pack is a subfolder `library/<id>/`. The user's own content is the pack `library/mine/`. At start, the app reads every pack. A damaged or unknown file is skipped with one note naming it, and never asserted on.
2. **A pack file** `.sculptpack`: a ZIP archive, so that anyone can make one with any zip tool. Entries are stored or deflated. Contents:
   - `pack.txt` — `name`, `author`, `version`, `description`, one `key value` line each. This is the only required entry.
   - `brushes.txt` — `preset` lines in the settings file's own format (same escaping). A preset's alpha may name an alpha of the pack (`pack:<file stem>`), a built-in, or `-`.
   - `alphas/*.png|jpg|jpeg|bmp|tga|qoi` — brush alphas.
   - `meshes/*.obj|ply` — base meshes.
   - `materials.txt` — `material <name> r g b metallic roughness` lines (7.4c).
   - `matcaps/*.png|jpg` — matcap images (7.4c).
   - Nothing else is read. Macros and scripts are deliberately excluded: store rule 2.5.2 / Play device-abuse says no downloaded code, and a pack must stay data only. A pack carrying `macros/` or any other folder installs without it and the install note says what was left out.
3. **Install pack…** (Menu > Library, or Search) picks a `.sculptpack` (or `.zip`) through the system picker. On Android that path is a `content://` URI, read through `SDL_IOFromFile` (a new `file_read_any`). The pack is checked and unpacked into `library/<id>/` (id = the sanitised name, de-duplicated), and is usable at once. Reinstalling a pack with the same name and author replaces it, after a second tap.
   - Checks before anything is written:
     - at most 4096 entries and 512 MB unpacked in total; each entry's declared size is checked before inflating, and the inflated size must match (zip bombs);
     - names relative, no `..`, no absolute paths or drive letters, no backslashes (zip slip), UTF-8;
     - only the folders and extensions above;
     - every image and mesh must decode, and `brushes.txt` lines are parsed as the settings parser does (bad lines are skipped and counted).
   - Unpacking goes into `library/.incoming` and is renamed into place, so an interrupted install leaves nothing half there.
4. **The Library panel** (Menu > Library…, a side panel like Settings, Help and Macros) lists each pack with its name, author, version and counts ("12 brushes, 30 alphas, 3 meshes"), and has:
   - Install pack…
   - Remove (second tap) — not on "mine";
   - Make a pack… — writes "mine" (or a picked subset in 7.4b) as a `.sculptpack` through the save dialog, so a person can share their brushes.
5. **Where packs show:**
   - **Brush presets.** A pack's presets join the preset list under the pack's name, read-only. Using one copies its values, as picking a preset does today; saving changes makes a preset in "mine". `MAX_PRESETS` stays for the user's own; pack presets have their own list of up to 256 a pack.
   - **Alphas.** The Alpha section's grid shows built-ins, then "mine", then each pack, with a header per pack. Load image now also copies the image into `library/mine/alphas/`, so it and any preset that uses it survive a restart. Presets refer to alphas by `pack/stem`, and settings lines from before keep working by built-in name.
   - **Base meshes.** New scene lists the six shapes, then each pack's meshes by name. Scene > Add object gets the same list. A mesh opens as Import does: cleaned, centred, sized.
   - **Materials and matcaps (7.4c).** Pack materials extend the material list. A matcap is a new shading mode: the view-space normal looks up the image, and the cavity, wireframe and paint layers stay on top. This is a fragment shader change, with its own small design and review before building.
6. **Script verbs** for tests and set-up: `install_pack PATH`, `pack_mesh NAME`, `set alpha pack/stem`. `--library=DIR` points a run at another library (touch_check gives each scenario its own, as it does settings).
7. **Exit stats**: `packs`, `pack_presets`, `pack_alphas`, `pack_meshes`, `pack_skipped`.

## Store rules (sm-store)

- No network: packs come only through the system picker or Make a pack. No downloads and no store integration (selling packs would need In-App Purchase / Play Billing: not in scope).
- No broad storage permission. The library lives in the app's private folder. Android reads the picked URI once.
- Data only: images, meshes and text in fixed formats, each parsed by our own readers with limits. Nothing is executed and nothing is interpreted as commands.
- The iPad backup note in sm-store applies to `library/` too: user content should be backed up, so it stays out of Caches (unlike autosaves).

## Phasing (each its own PR, each with tests, touch scenarios and README)

- **7.4a**:
  - ZIP reader (`geom` stays geometry; a new `src/app/zip.odin`, plus `core:compress/zlib` `inflate_raw`) with its limits and tests on hand-made archives: stored, deflated, a bomb, a slip, bad CRC.
  - The library folder and its reading at start.
  - Install and Remove; the Library panel.
  - Alphas from packs, with Load image keeping a copy in "mine"; presets by `pack/stem`.
  - Brush presets from packs.
- **7.4b**: base meshes (New scene, Add object, `pack_mesh`); Make a pack (ZIP writer, stored entries, our CRC32).
- **7.4c**: materials and matcaps (shader; its own design note first).

## Open questions (defaults taken)

- Should packs be able to replace the built-in alphas or brushes? **No:** packs only add.
- What is the ZIP64 limit? It is not supported. A pack over 4 GB or 65,535 entries is refused (limits are far below that anyway).
- Should an installed pack update in place? Yes: the same name and author replace it after a second tap. Presets in "mine" that used its alphas keep working when the stems stay.

## Architect review (adopted, 2026-10-27)

Verdict: approve with changes. These changes are adopted.

1. **Alphas are referenced by name, not by index.** `Preset_Values` and the brush keep the alpha as a `pack/stem` reference string; the index into `app.alphas` is only a cache, recomputed when the library changes. The library is read before the settings, or else references resolve after load (main.odin settings_load runs before alphas_init). Removing a pack drops the brush to round, with a note counting the user's presets that used it. A reinstalled pack brings them back.
2. **One reference syntax.** Inside a pack, a preset names its own alphas relatively (`stem`), and these are resolved at install. Outside, references are `id/stem`. Scripts use the existing `alpha NAME` verb (not `set alpha`). A `/` reference is tried as a library name before a path.
3. **Pack presets and brush state.** What `b.preset` holds while a pack preset is in use must be defined before a4. Dock slots holding pack presets reset on removal, as `dock_preset_deleted` does.
4. **Zip bombs and entry checks.** Inflate through an allocator capped near the declared size (done in the a1 draft). Refuse encryption and methods other than 0 and 8. Take sizes from the central directory, not the local headers.
5. **Install runs off the frame loop.** A worker thread uses the heap allocator and a nil pool, shows progress, and hands its result back like a `file_take` request.
6. **The library follows the settings.** It is read only when settings are remembered, and its folder is derived from `--settings-file` the way `macros_folder` is.
7. **Name collisions.** Refuse names that differ only by case and duplicate names. Reserve the id `mine`, and refuse Windows reserved names and trailing dots or spaces. Sort pack ids and entry names.
8. **Android picker.** Use the `*` filter, because SDL turns `sculptpack;zip` into `application/zip` and hides `.sculptpack` files. Detect a ZIP by its signature, since `content://` paths have no extension.
9. **Replacing a pack.** Move the old folder aside, rename the new one in, then delete the old one. At start, clear `.incoming` and any moved-aside folders, and skip dot-folders.
10. **Should items:**
    - The ZIP reader becomes its own pure package, `src/zip`.
    - `file_read_any` is used for Import, Alpha and Open too.
    - Only the Load image dialog copies an image into "mine" (de-duplicated by content), never a script or macro.
    - The user's presets stay in settings.txt.
    - Pack meshes get a new command or file request, not wider `New_Scene` args (needs its own design step).
    - Add a `license` key to pack.txt, shown in the panel.
    - iPad needs an exported UTType (unverified).
    - Selling packs is In-App Purchase or Play Billing only.

**New split:**
- a1: `src/zip` with hand-made archive tests, and `file_read_any`.
- a2: the library folder with "mine" alphas kept across restarts and alphas referenced by name (this fixes today's lost-alpha bug).
- a3: Install and Remove, the Library panel, and pack alphas.
- a4: pack presets and the dock.
- 7.4b: meshes and Make a pack.
- 7.4c: materials and matcaps.

## a4 as built: pack presets and the dock

- `brushes.txt` holds `preset` lines exactly as settings.txt writes them. One parser (`preset_parse`) and one writer (`preset_line`) serve both. Its alpha field is `-`, a built-in's name, or the stem of an alpha in the same pack. Install checks every line on the worker; bad lines, duplicate names, a brush's own name, or an alpha the pack lacks are skipped and counted in the note. At most 256 presets a pack. What is written to the library is the normalised lines, so the file read at start is always well formed.
- Pack presets live in `Library.presets` (`Pack_Preset`: the preset and its pack's id) and are tombstoned like alphas (`gone`). An index into that list never changes during a run.
- **What `b.preset` holds (review item 3):** 0 is the plain brush; 1 to `preset_count` is the person's own preset, from 1; `PACK_PRESET + j` is library preset j. `Dock_Slot.preset` uses the same numbering. `preset_at(app, n)` resolves either kind. Using a pack preset copies its values into the brush, as picking one of your own does. Save changes, Rename and Delete are not offered on a pack preset. Save as new makes one of your own, named after it.
- **Removal and replace:** removing a pack marks its presets gone. `pack_presets_retarget` then moves the brush and every dock slot on a gone preset to the non-gone preset with the same pack id and name, which a replaced pack has. Otherwise the brush leaves the preset (keeping the plain values), and the slot falls back to its brush, as `dock_preset_deleted` does.
- **settings.txt:** `brush_pack_preset <id> <name>` and `dock <slot> pack_preset <id> <name>` sit beside the old lines. Older versions skip both.
- **Scripts:** a new `preset NAME` verb takes your own preset's name, `PACK/NAME`, or `none`.
- **Exit stats:** `pack_presets` counts the presets installed now.

## 7.4b split and b1 design: pack meshes

7.4b is two PRs: **b1** pack meshes, then **b2** Make a pack (a ZIP writer: stored entries, our CRC32; writes `mine` as a pack through the save dialog).

b1 design:
- **Install.** `meshes/<name>.obj|.ply`, right in `meshes/`, at most 64 a pack. On the install worker each one is parsed and cleaned with a nil pool (`geom.mesh_read_obj/ply` and `mesh_clean`, serial). One that fails refuses the pack with its error and line, as a bad alpha does. The file is written unchanged to `library/<id>/meshes/`, and its vertex and triangle counts are kept for the listing. Case-insensitive duplicate stems are left out and counted.
- **Library.** Add `Library.meshes: [dynamic]Pack_Mesh{pack, stem, file (full path), vertices, triangles, gone}`, tombstoned like presets. `Pack.meshes` counts them. At start, `library_load` lists `meshes/` without parsing anything: install already checked the files, and reading 64 meshes at start would be slow. A file that fails later is reported by the import itself.
- **Add object.** Scene > Add object's shape list gains each pack mesh after the primitives ("Boulder (Rock Set)"). When one is picked, the size list hides and the button reads "Add Boulder". `Kit_State.add_mesh` (a library mesh index + 1, 0 for a primitive) sits beside `add_shape`. The existing `Add_Object` command, on a pack mesh, posts `file_post(.Import, mesh.file)`, so the mesh opens exactly as Import does: cleaned, centred, sized, one undo step (history_record_added), named after its stem. This needs no new Scene_Command kind.
- **New scene.** Menu > NEW SCENE gains a row per pack ("ROCK SET": its meshes, three to a row, the same armed "Discard?" second tap; arming uses `new_armed = len(NEW_SCENE_SHAPES) + 1 + j`). A new `File_Kind.New_From_Mesh` carries the path. Applied at the frame start, it reads the mesh as Import does (scene_import split into `mesh_file_load` → mesh, placement and note, then add), and replaces the scene as `scene_new` does (scene_replace, a default camera, no file path, History cleared). New scene stays a command with fixed args for the six shapes; the pack meshes are interface rows and a script verb, not commands, because a command's args count is fixed.
- **Scripts.** `pack_mesh PACK/NAME` adds the mesh as an object (in place, like `install_pack`, so the next line sees it). `new_scene` remains start-up only and shapes only.
- **Removal.** Removing a pack marks its meshes gone. An `add_mesh` pointing at one goes back to the primitive. Objects already made from a mesh are scene data and stay.
- **Exit stats:** `pack_meshes`.
- **Limits:** the archive's 512 MB total already bounds the meshes. Each mesh is also held to the import limits (the readers' own).

### b1 architect review (adopted)
1. Add and New go through `Scene_Command` with a new `mesh: int` field (library mesh index + 1) on `.Add` and `.New`, not through `file_post`. The single pending file slot drops what was there, and a dialog answer in the same frame overwrites it. `.Add` keeps the below-selection placement, the in-place script apply and `macro_settle`. No `File_Kind.New_From_Mesh`.
2. New from a mesh builds the object first (id = next_id + 1, at the origin), then runs `scene_replace` and `scene_new`'s tail: remember no path, `autosave_scene_saved`. Set the file stats after `scene_replace`, which zeroes stats.
3. Install writes a normalised `meshes.txt` (stem, file, vertices, triangles); start reads it, so the counts survive without parsing.
4. Macros: a pack-mesh add records `pack_mesh id/stem`, not `new_shape`.
5. `add_mesh` is never saved as an index. On replace it is retargeted by pack id + stem, as presets are; on removal it resets.
6. Worker parsing calls `geom` directly with a nil pool, through a pure helper shared with Import that picks the format by extension or bytes. `scene_import` is not reused on the worker.
7. `NEW_ARMED_MESH` and `new_mesh_armed(app, j)` are named helpers, disarmed when the mesh goes gone. Arming happens only with `scene_has_work`.
8. `pack_mesh id/stem` is matched ignoring case, runs in place as a Scene_Command, and records `history_record_added`.
9. Tests: install (OBJ, binary PLY, a bad OBJ naming its line, case duplicates, the 64 cap, `meshes/sub` left out), restart counts, removal, Add undo, New clearing History (a failed parse leaves the scene), nil-pool vs pooled parse being bit-identical, a touch scenario, and the `pack_meshes` stat.

## b2 design: Make a pack
- `zip.write(files: []zip.File, allocator) -> []u8` writes stored entries with `core:hash` crc32: local headers, central directory, end record. No deflate keeps `zip` pure; PNG alphas are compressed already. `zip.entries`/`zip.read` round-trip it in tests.
- The Library panel's "Make a pack..." (command `Save_Pack`, since the script verb is `make_pack` and command names may not clash with verbs) opens a save dialog for `.sculptpack` (`File_Kind.Make_Pack`). The pack's name is the file's stem ("Bolt clay.sculptpack" → "Bolt clay"), so no name field is needed. The pack holds:
  - every alpha in `mine/`, under `alphas/` with its file name;
  - every one of the person's presets, in `brushes.txt` through `preset_line`. The alpha word is the stem for a `mine/` alpha, the name for a built-in, and `-` for an alpha of another pack (not ours to pass on). The note counts the presets that lost one.
- Script verb `make_pack PATH`. Round-trip test: make, then install into a fresh library; the presets' values and alphas match.
- The note reads "Made Bolt clay.sculptpack: 3 alphas and 4 presets" and names how many presets went round.

### b2 as built
- As designed, with the command named `Save_Pack` (label "Make a pack...") so it does not clash with the `make_pack` verb. It sits beside Install pack as a button pair at the top of the Library panel, disabled with nothing of the person's own. The writer uses a fixed 1980 DOS date so the same input gives the same bytes, sets the UTF-8 flag, and refuses unsafe or case-duplicate names as the reader does. Verified by `zip.writes_what_it_reads`, `pack_make_round_trips` (make, remove nothing, install into a fresh library, compare values and alphas), and an archive checked by Python's zipfile and `unzip -t`.

## 7.4c design: pack matcaps and materials

What exists: `Material` (material.odin) has `matcap: int` (0 lights, 1..6 built-in, `MATCAP_IMAGE` the one loaded image); `app.material` indexes `MATERIALS` or is `CUSTOM_MATERIAL`; `material_matcap` turns a material into a texture; settings keep `material <label>`, `custom_material r g b metallic roughness matcap` and `matcap_image <path>`. Library loads before settings; `matcaps_create` runs before both.

**Pack contents.**
- `matcaps/<name>.png|jpg|jpeg|bmp|tga|qoi`, right in `matcaps/`, at most 32 a pack, each at most 2048 x 2048 (VRAM: 16 MB at that size). Checked on the install worker as alphas are: it must decode and convert through `image_rgba8`. A bad one refuses the pack with why. A second image of the same stem is left out and counted, as meshes are.
- `materials.txt`: `material <name> <r> <g> <b> <metallic> <roughness> <matcap>`, the name escaped as preset names are, the colour in linear light as `custom_material` holds it, metallic 0..1, roughness 0.04..1, and the matcap `-` (the lights), a built-in matcap's label in lower case with dashes (`red-wax`, `clay`, `grey`, `skin`, `pearl`, `toon`), or the stem of one of the pack's own matcaps. At most 64 lines; a damaged line, a repeated name, a built-in material's name, or a matcap the pack lacks is skipped and counted, as `brushes.txt` lines are. Install writes it back normalised.
- A matcap that no line names becomes a material by itself: its stem, white, shaded by it. So a folder of matcap images is a pack with no text file, as alphas are.

**Library.** `Library.matcaps: [dynamic]Pack_Matcap{pack, stem, file, texture, gone}` and `Library.materials: [dynamic]Pack_Material{pack, name, material: Material, gone}`, tombstoned like presets and meshes. `Material.matcap` gains a third range, `PACK_MATCAP + k` (k into `Library.matcaps`, `PACK_MATCAP :: 1 << 16`), and `app.material` a third, `PACK_MATERIAL + j` (`1 << 16`). `current_material` and `material_matcap` resolve both. A label is a `cstring` today; a pack material's is cloned to a C string it owns and freed when its pack goes.

**Textures are made when used, at the start of a frame.** `pack_matcaps_settle(app)` runs where the frame applies requests: it makes the texture of the matcap that the current material or Custom uses when it has none (`render.matcap_create`, then `render.viewport_invalidate`). A library of many large matcaps therefore costs VRAM only for the one in use, starting needs no GPU work for packs, and the app's tests stay GPU-free. Until it exists (one frame) `material_matcap` returns nil and the lights shade, which the shader already handles. Textures of a pack's matcaps are released on removal through `render.matcap_destroy` (which waits for the GPU) and on exit.

**Interface.** The Material section's list gains each pack's materials after Custom, as "Name (Pack name)"; `ui.select` takes the longer list. Moving a slider on one copies it into Custom as on any preset, and Custom then keeps `PACK_MATCAP + k`. The Library panel's counts add materials ("3 materials"), `pack_holds` gains the field. The README's MatCaps paragraph says where pack matcaps show.

**Settings.** Never an index: `material` stays a built-in label (Clay when a pack material is in use, so an older version starts on Clay) and a `pack_material <id> <name>` line follows it; `custom_material` writes matcap 0 for a pack matcap and a `custom_pack_matcap <id> <stem>` line follows. Both are applied after the library has loaded, as `brush_pack_preset` is. Older versions skip both lines.

**Scripts.** `set material NAME` takes `PACK/NAME` too (the setting's parser gets the app, or the pack form is matched in the script verb before the setting); `matcap FILE` stays the loaded-image path.

**Replace and removal.** `pack_materials_retarget` moves `app.material` and Custom's matcap to the pack material or matcap with the same pack id and name in the replacing pack; otherwise the material goes back to Clay and Custom's matcap to 0 (the lights, its colour kept), with a note when that changed what is on screen.

**Make a pack.** Out of 7.4c: the person's own matcap image and Custom could go in later as `matcaps/` and a `materials.txt` line, which is why the formats match what settings already hold.

**Exit stats:** `pack_matcaps`, `pack_materials`.

**Tests.** Install a pack with two matcaps (one 16-bit grey PNG) and a materials.txt with good and bad lines (counts and note); a matcap-only pack makes a material per image; a too-big or broken image refuses the pack; restart keeps both lists; settings round-trip `pack_material` and `custom_pack_matcap`; replace keeps the material, removal falls back to Clay; `set material rock-set/wet stone` from a script; a touch scenario that installs a pack, opens View > Material, picks the pack material and dumps the viewport.

**Size and review.** About 450 lines, a new GPU texture lifetime (lazy, per matcap), and new settings lines: this goes to `sm-architect` before code.

### 4c architect review (adopted)
Verdict: approve with changes. No shader or buffer layout change is needed, because render already binds `item.matcap` or `no_matcap`.

Must-fix:
1. **Where settle runs.** `pack_matcaps_settle` runs after `draw_viewport_overlay` and before the frame's command buffer is acquired, not where requests are applied. A pick made in the panel or a script then shows in the same frame. `texture_upload` uses its own fenced command buffer, so this is legal in SDL_GPU. Prove it with `build.bat smoke`.
2. **Invalidate the cache.** The frame key already holds `item.matcap`, but call `viewport_invalidate` on both create and destroy, because a freed address can be reused.
3. **No retries.** A `failed` flag on `Pack_Matcap` stops retrying: one note, then the lights. Skip settle when there is no GPU device, so tests stay GPU-free.
4. **Bound VRAM.** When settle makes a texture, it releases the pack textures that neither the current material nor Custom uses.
5. **Resolve the new ranges everywhere.** `current_material`, `material_matcap` and `matcap_label` handle them. `kit_material` maps names to numbers as `kit_preset` does, skipping gone entries.
6. **Settings and macros.** The `material` setting's `text` returns `id/name`, because macros record it. `settings_save` special-cases it: it writes `material Clay`, then `pack_material <id> <name>`. `custom_material` writes matcap 0 for a pack matcap, then `custom_pack_matcap <id> <stem>`.
7. **When pack lines apply.** They are applied at the end of `settings_load`, so their order in the file does not matter. `custom_pack_matcap` sets `idle = MATCAP_IDLE`.
8. **`set material PACK/NAME` in scripts.** The value is resolved when the statement runs, not when it is parsed, as `.Preset` is. Error: "no content pack has a material named %q".
9. **Names.** `Pack_Material` keeps `name: string`, and `Material.label` stays nil for pack materials. Names are freed only in `library_destroy`, since tombstones keep their strings.

Should:
- Matcap-only materials are written into the normalised `materials.txt` at install.
- A pack's own matcap stem wins over a built-in word, and `Custom` is reserved.
- Defaults: `idle` is MATCAP_IDLE under a matcap, otherwise 0.42/0.42/0.44; `shading` is {}.
- Matcaps are capped at 1024 x 1024.
- Removal releases only textures that exist.
- Exit stat `pack_matcap_textures`; `pack_holds` gains materials.
- More tests: a name-only retarget whose matcap is gone; a broken file at start (one note, no retry); the macro round-trip; older settings still read.

### 4c rebased on per-object materials (#136, merged 2026-10-27)
#136 changed what the design above sits on: each object now has its own `Material` (`obj.material`, label nil means "none yet", which `materials_settle` fills from the default), the Material section edits the selection through a `.Material` Scene_Command (`material_set`), and scenes are version 14 with `material_put`/`material_get`, which refuses a matcap above `MATCAP_IMAGE`. So:
1. **Which material it is.** `Material` gains `pack: int` (a `Library.materials` index + 1, 0 for none) beside `matcap = PACK_MATCAP + k`. `material_index` returns `PACK_MATERIAL + pack - 1` when `pack > 0`, so the list shows it. The label stays non-nil (nil means unset): it is a C string the library owns, cloned at load and freed only in `library_destroy`, so tombstones and copies in objects never dangle during a run.
2. **Scene file v15.** After the matcap, `material_put` writes two references, each `""` for none: the pack material as `id/name` and the pack matcap as `id/stem`, and the i32 matcap is 0 for a pack matcap so the v14 bounds check still holds. Reading resolves both against the library. When a pack is not installed, the object keeps its colours, metallic and roughness, the label becomes "Custom", and the matcap is 0 (the lights). One note counts those objects: "2 objects use materials from packs that are not installed (Rock Set) and show the lights". Files of v14 and older read as before.
3. **Autosave.** The references are turned into strings on the main thread when the snapshot is taken, never read from the library on the autosave thread.
4. **Which textures stay.** The keep set is every matcap used by an object's material, by Custom and by the default, not only the current one. When settle makes a texture, it releases the rest.
5. **Removal and replace.** These also walk the objects: each pack material or matcap moves to the same id and name in the new pack, or falls back as a scene read does. That bumps `scene_edits`, and History is untouched, since materials are outside it.
6. **Export.** A pack matcap exports as the loaded image does (mid grey tinted by the colour), named after its label.
7. **Scripts.** `set material PACK/NAME` runs `material_set` on the selection, as the panel does.
8. **Tests also cover:** the v15 round trip with a pack material and a pack matcap; a v15 scene opened without the pack (the note and the lights); v14 still reads; removing a pack while an object uses its material; export of a pack matcap.

### 4c delta review (adopted)
Must-fix:
1. **Autosave references.** `autosave_start` builds each object's `id/name` and `id/stem` references on the main thread, on the heap, and `job_free` frees them. `object_put_bytes(…, refs)` and `material_put(out, m, refs)` never touch `app.library`. The retarget walk calls `autosave_settle` before it writes `obj.material`.
2. **Custom made from a pack material.** `material_set` clears `pack` when the label is Custom, because moving a slider on a pack material makes a Custom.
3. **`object_get` has other callers.** History restore and duplicate also use it, so only the scene read counts the objects whose packs are missing (`missing: ^int`, nil elsewhere).
4. **v15 reading.** `material_get` takes the app and the version. A non-empty reference with an empty id or name refuses the file, and so does a matcap reference whose i32 matcap is not 0. A well-formed reference to a pack that is not installed falls back. Add "15: …" to the SCENE_VERSION comment. Writing a 0 matcap is what makes the fallback show the lights (older versions refuse v15 files anyway).
5. **Export.** `export_material` gets a pack-matcap case beside `MATCAP_IMAGE`.
6. **This overrides must-fix 9 of the earlier review.** Pack material labels are library-owned C strings, cloned at install and at load, and freed only in `library_destroy`. That is safe: nothing reads a label after `library_destroy` (exit order checked). A comment in main.odin says `library_destroy` stays after `settings_save`.

Should:
- Macros do not record `material`; the setting's `text` still returns `id/name` for settings and scripts.
- `set material PACK/NAME` carries a string in parse and resolves it in apply.
- Notes count the affected objects.
- `.Material` may carry a gone `pack`: `material_set` and `material_matcap` treat a gone entry as the fallback, and settle never builds a gone matcap.

### 4c as built
- What the design and both reviews describe is built, with two simplifications:
  - **Settings lines.** There are no separate `pack_material` or `custom_pack_matcap` lines. The `material` line itself holds `<id>/<name>`, which older versions fail to parse and so skip, starting on Clay. The `custom_material` line's matcap field holds the escaped `<id>/<stem>`, which older versions read as 0, the lights. `settings_load` looks both up in the library, which loads first.
  - **Script lookup.** `set material PACK/NAME` keeps the name in the statement's `text` and looks it up when the line runs. An unknown name fails with "no content pack has a material named …".
- **materials.txt as install writes it.** It holds `matcap <stem> <file>` lines first, then the materials. Materials that exist only because of a matcap get roughness 0.5, so the line passes the 0.04..1 check; the picture holds the sheen anyway.
- **New exit stats:** `pack_materials`, `pack_matcaps`, `pack_matcap_textures` and `selected_material`.
- **Tests:**
  - `pack_materials_install_and_follow`: install, the line counts, the scene v15 round trip with and without the pack, damaged references, v14 still reading, settings, the script, replace and removal.
  - Touch scenario `pack_materials_shade_and_stay`.
- **Rebased on per-group materials (#144).** That change took scene version 15 for its group table, so the pack references are version 16. `material_get` reads them only from version 16. `group_materials_put` and `group_materials_get` pass references and the version through. `object_material_refs` gives the object's reference and then one per group; the autosave job keeps a heap copy of that list for each object.
- **Group materials and packs.** Groups can still only pick a lit preset or Custom, never a pack material. One copied from a pack material the object uses becomes Custom and has `pack` cleared in `group_material_set`. On replace or removal, `pack_materials_retarget` also walks the group tables.
