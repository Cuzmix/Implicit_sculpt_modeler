---
name: sculpt-phase7
description: UX roadmap Phase 7 (pipeline and automation): command scripts, macros, glTF/USD export, content packs; design decisions and PRs
metadata:
  type: project
---

Phase 7 of /mnt/project-files/notes/ux-research/12_Product_Roadmap.md, worked autonomously while Bolt is away (self-merge into odin-sculpt). Follows [[sculpt-depth-phase6-later]]. Designs with adopted architect reviews live in /mnt/project-files/notes/phase7/.

- Item 1 command scripts DONE (#106, #108, #109, #111); a start-up script counts as set-up (History cleared).
- Item 2 macros DONE (#113, #117, #118): 16 slot files in macros/ beside settings, Menu > Macros panel.
- Item 3 export with layers DONE: #115 .glb (layers as shape keys; scripts/export_check.py with validator + Blender), #119 .usda (geom.mesh_write_usda; Blender names keys by blendShapes tokens, clamps keys to 0-1, needs frame_set(1)). Dev tools in scratchpad venv: SCULPT_BPY_PYTHON, SCULPT_NODE_PATH. 10M export: glb 6.8 s, usda ~24 s on the VM.
- Item 4 content packs: design content-packs-design.md (packs are .sculptpack ZIPs of data only: pack.txt, brushes.txt, alphas/, meshes/, later materials/matcaps; library/<id>/ beside settings, "mine" for the user's own; alphas referenced by `id/stem`, index only a cache; install off the frame on a worker; Android picker uses `*` filter + ZIP signature). Split: a1 zip+file_read_any, a2 library + "mine" alphas kept across restarts, a3 install/remove + Library panel + pack alphas, a4 pack presets + dock, 7.4b meshes + Make a pack, 7.4c materials + matcaps (shader design first).
- Item 4 DONE via PRs #120 (zip), #122 (library, mine alphas), #124 (install/remove, Library panel), #130 (pack presets), #137 (pack meshes), #142 (Make a pack), #146 (matcaps + materials, scene v16 refs by name).
- Item 5 Blender live link DONE: PR #152 merged 2026-10-27 (app link.odin + add-on tools/blender/sculpt_link + scripts/link_check.py real-bpy round trip; scene v17 = link token; taken.txt in link folder; commands only in Settings > System and Search, since the Menu is full at 900 px: adding a File row pushes app rows off screen). Paint back from Blender not done. Design: notes/phase7/blender-link-design.md.
- Item 6 (sandboxed script plugins) SKIPPED by Bolt 2026-10-27 (decision card; Lua 5.4 was the recommended option; vendor lua has no Windows/Android libs and lua.org/GitHub tarballs are 403 via proxy). Phase 7 closed; roadmap phases 0-7 complete. Same day Bolt asked about Wasmtime and Luau and asked why Lua was assumed: comparison doc https://claude.ai/artifact/4PvNYm71dnNZ3PGJyAnw6K recommends Luau (sandbox, text plugins, C++ builds with cl/clang/NDK), Wasmtime as a later per-vertex tier; Bolt chose "Luau, desktop first" 2026-10-27 08:21Z: design + architect review, then build and self-merge. Network: git clone from GitHub, cargo and crates.io work; only GitHub release assets and archive tarballs are 403.
- Flake seen once: touch autosave_crash_then_recover (@same mesh) under gate load, not reproduced; root cause unknown.
- Item 6 DONE: PR #161 merged into odin-sculpt 2026-10-27. Luau 0.744 is built from source by scripts/build_luau.py (setup_deps runs it; Windows must re-run setup_deps.bat). Plugins are .luau files in the plugins folder, one sandboxed VM each (64 MB cap, 5M/50M step budgets), and they act only via sculpt.run command scripts. The Macros panel has a PLUGINS section. Desktop only, never Android. Not verified: the Windows cl build and longjmp across Odin frames. Design: notes/phase7/script-plugins-design.md.
