---
name: sculpt-import-formats
description: Import series (thread "Import vertex colours, glTF, USD and FBX", 2026-10-29): vertex colours, multi-part import, glTF/FBX/USD readers; decisions and PR status
metadata:
  type: project
  modified: 2026-10-29T21:30:00.000Z
---

Bolt 2026-10-29: imported vertex colours didn't show; add glTF, USD and FBX import. Design + adopted architect review:
/mnt/project-files/notes/import/design.md. Defaults announced (no objection yet): several meshes a file -> objects in a
folder named after the file (Nomad/Blender), transforms baked, materials/`g` -> polygroups, ufbx for FBX, own Odin USD
reader (usda, usdc crate, usdz via src/zip), texture/material colour -> polypaint as the last PR.

- #308 merged: OBJ `v x y z r g b` + ZBrush `#MRGB`, PLY red/green/blue -> polypaint (geom.Vertex_Color, mesh_clean carries colours).
- #313 merged: geom.Mesh_Part, OBJ `o`/`g`, glTF reader (geom/gltf_read.odin), mesh_parts_normalize (per-axis origin rule keeps a shared symmetry plane), MESH_PARTS_MAX 256 -> merge with a group each, one undo step (chained swaps + history_record_arrange(chain=true)), drag-and-drop import + `--ui-events` `FRAME:drop:PATH`.
- Bolt's Female expression6.obj (project files) has NO vertex colours (only mtllib/UVs): its colour is in materials/textures -> needs the texture PR.
- #321 merged: own USD reader, package src/usd (usda, usdc crate, usdz), displayColor, materialBind subsets -> groups; no composition followed.
- #324 merged: material colours/textures -> polypaint (geom/mesh_look.odin: glTF baseColor factor+texture, OBJ mtllib/usemtl/Kd/map_Kd; baked before mesh_clean; a part of one grey + no image keeps clay; usemtl -> groups when no g). USD materials not read.
- #329 merged: FBX via ufbx v0.23.1 (Bolt approved on the card 2026-10-29 20:33): src/fbx (fbx_shim.c includes ufbx.c; scripts/build_ufbx.py -> deps/ufbx; Android CMake + build.sh ios compile the shim; file_format forced to FBX since ufbx also reads OBJ). Full gate green on the series 2026-10-29. Old 5800/6100 FBX files may lack axis info, so Z-up Max files can come in lying down (ufbx's call, not ours). Awaits a Windows (cl build) and tablet try.
- Test files generator: scratchpad mk.py (head + two eyes as OBJ/GLB/GLTF); Xvfb :99 needed for runs (apt packages had to be installed for setup_deps: X11/wayland dev libs).
