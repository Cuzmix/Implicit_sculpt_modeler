# P5 Export presets and checks: design (2026-10-30)

The mock is panels3.js `S.mExport`. It covers five things: presets first, Last time, options for the preset, a preview before export, and checks for a print.

The Export sheet already exists (round 2, PR 11b, `src/app/lens_export.odin`). It lists the formats down its side, shows the chosen format's options, and has a foot with the file name and size. P5 turns it into a sheet that starts from presets. Every preset still runs the export commands that already exist, so no file format changes.

## P5a: presets, Last time, preview (this PR)

### Presets

`Export_Preset` has six values: Print, Game, Blender, Turntable, Picture and Formats. The mock's five presets come first. The sixth, "Any format", keeps every plain format reachable from the sheet, as the old side list did.

| Preset | Formats | First format |
|---|---|---|
| 3D print | STL (sized) and OBJ (sized) | STL |
| Game engine | glTF and OBJ | glTF |
| Blender | Live link (desktop only) and USD | Live link where it exists, otherwise USD |
| Turntable | the frames | |
| Picture | the screenshot | |
| Any format | Sculpt scene, OBJ, PLY, STL, glTF and USD | |

- `Export_Format` gains two values, Print_OBJ and Link. They go at the end so the names saved in old settings files still read.
- Print_OBJ is new. It writes the 3D print's millimetres and Z up as OBJ, with the polypaint as vertex colours, which Bambu and Prusa slicers read.
- `object_export(print=true)` accepts .obj as well as .stl.
- The print dialog offers the one format that was picked.

### State and settings

- The sheet keeps the preset and the format.
- The pick within each preset is remembered while the app runs.
- The last export that ran is `last_preset` and `last_format`, with `ran` saying whether one has. These are kept in the settings file.
- The sheet opens on the last export that ran. Its head says "Last time: glTF for the game engine".
- An older settings file has only `export_format`. Its format settles into the first preset that holds it.

### Layout

- The sheet is up to 940 points wide.
- The head row has the Export title, the Last time text and Close.
- Next comes a row of six preset cards: an icon, a name, and a description on up to two lines. The lit card is ringed in the accent.
- Below that are two columns of a fixed height, so the sheet does not jump between presets:
  - Left, Options: format tabs when the preset has more than one format, then that preset's options:
    - 3D print: Scene > 3D print's unit and sizes.
    - Game engine: the object and what the format carries.
    - Blender: what the link does, or why it cannot run.
    - Turntable: the frames and Without background.
    - Picture: the Render switch, Quality and Without background.
    - Any format: the old per-format options.
  - Right, the preview:
    - A picture: the object's thumbnail, or the view for Picture and Turntable.
    - The file name, in bold.
    - What goes in: the object, the scene's objects, the view's size or the frames.
    - The triangles and the size estimate.
    - For a print, its size in millimetres.
- The foot says "Exports a copy; the scene is not changed." Save as instead says that the new file becomes the scene's own, and the live link says that it sends a copy. Then come Cancel and Export.

## P5b: checks before a print

Under "Before it prints", for the 3D print preset:

- **Watertight**: every edge has two faces, from `geom.mesh_check_indices`.
- **Holes**: the count of boundary loops, with a Repair button that runs Repair > Close holes as one undo step.
- **Thinnest wall**: rays cast inward from a few thousand sampled vertices against the object's BVH. The shortest hit, in mm, is compared with a minimum wall of 1.0 mm (a setting).
- **Fits the bed**: the print's size against a bed size setting. The default is 220 × 220 × 250 mm, a common printer. It is set in the sheet and kept in settings.

Each check shows a tick, or a warning with the reason. The results are cached by the object's mesh edits and the scale, and they run when the sheet shows the preset. A mesh over the cap shows "Too big to check here".

## P5c: for this file only

- **Only the selected objects (N)**: a print takes every selected object, at the scene's one print scale, as one file. Off, it takes every shown object.
- **3MF**: written with `zip.write` and holding one object per part, in millimetres. Slicers keep the parts apart.
- **Decimate for this file only**: the file's triangles are cut to a budget with `geom.mesh_decimate` on a copy, so the scene keeps its mesh. This applies to Game engine and to 3D print.
- **Hollow**: a print gets an inner wall of a chosen thickness. The object is voxelised (as voxel remesh does), the surface is offset inward, and the inner shell is added flipped. This also applies to the copy only.

Each of these options says on its row that it changes only the file.
