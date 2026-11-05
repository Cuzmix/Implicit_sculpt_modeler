---
name: sculpt-polish-oct25
description: Thread "Improve sculpt while Bolt is away" (2026-10-24/25): PRs #15-#31 merged into odin-sculpt, what each adds, limits, lessons
metadata:
  type: project
  modified: 2026-10-25T01:20:49.517Z
---

Bolt went away ~10 h on 2026-10-24 23:39 UTC asking for things to add/fix/update; this thread self-merges into odin-sculpt. Follows [[sculpt-brushes]], [[sculpt-remesh]], [[sculpt-dyntopo]]. None of #15-#31 tried on Windows or with a real pen yet.
- #15 S / U modal brush size/strength, [ ] steps, strength per brush.
- #16 undo for remesh, dyntopo toggle, level deletes, add/import/delete (Delete key): `History_Entry.swap` = object as .sculpt stores it; 1.5 GB cap; HD detail not kept.
- #17 Mirror and weld (geom.mesh_symmetrize), Duplicate (Ctrl+Shift+D).
- #18 per-brush falloff curve editor (sculpt.Falloff 257-entry table).
- #19 object rotation (Euler degrees, scene file v2).
- Remesh "project detail" tried and dropped: gained nothing.
- #20 mask rectangle/lasso (Ctrl+drag empty space; Ctrl+Alt unmasks).
- #21 Mask cavities; View > Material presets (src/app/material.odin); wireframe Shift+F.
- #22 orthographic (P / keypad 5; LOD off in ortho), keypad 1/3/7 axis views; pixel sizes via camera.orbit_world_per_px / orbit_toward.
- #23 primitives cube/cylinder/cone/torus (geom.primitive; `--shape=`).
- #24 Layer brush (key 0) and Snake hook (no key, app hook_follow).
- #25 Decimate selected (geom.mesh_decimate: simplify strict mode + parallel cell rounds keeping 1/4 each with shifted cells; 10M->100k 12 s VM). Lesson: one aggressive cell round leaves dense border rows the final pass can't clean.
- #26 PNG screenshots (F12; own encoder src/png_write since core:image/png only reads; build scripts list 10 packages).
- #27 Morph target (Tools > Morph target Store/Delete, per level, memory only, not with dyntopo) + Morph brush (no key).
- #28 remembered settings (src/app/settings.odin, SDL pref folder settings.txt; only interactive runs read/write it, not --frames/bench/--no-settings; flags win).
- #29 Front faces only (Brush.facing ramp; mask shapes Front_Only; Grab ignores; --front-only).
- #30 Drag rectangle stroke (sculptor_stroke_restore redoes one dab per frame; not with dyntopo/Grab/Snake hook; --stroke=drag_rect).
- #31 Clip (Ctrl+Shift drag a line, Alt flips; sculpt.sculptor_clip flattens onto the plane, mirrors, leaves mask, not with dyntopo). Large undo saves (64k+ verts a dab) share one block + parallel copy; 10M half-clip ~150-250 ms on VM, mostly page faults.
- Testing trick: drive the app on Xvfb :99 with xdotool (keydown/keyup ~150 ms gaps), screenshots via ImageMagick `import -window root`; panel radio positions from a screenshot.
