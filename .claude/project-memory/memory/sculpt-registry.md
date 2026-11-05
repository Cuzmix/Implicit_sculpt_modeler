---
name: sculpt-registry
description: Command registry work (workstream 1 of the UX plan): PR #50 and the remaining steps, decisions and test setup
metadata:
  type: project
---

Thread "Build command registry and touch controls" (2026-10-25). Bolt picked "Registry first, then touch" on the decision card.

- PR #50: src/app/commands.odin, COMMANDS (@(rodata) [Command_Id]Command) and DEFAULT_BINDINGS (exact-modifier chords, order meaningful); menus via command_menu_item; app tests in `build test`.
- Design note + sm-architect review: /mnt/project-files/notes/registry/command-registry-design.md. Review said: use @(rodata) not :: for tables; no app.bindings until rebinding (workstream 4).
- PR #51: inspector buttons through command_run.
- PR #52 merged 2026-10-25: results.odin, report(app, section, flags, ...), which drives the toast (Undo button), the section's "Last:" line and Stats > Last operation. *_last structs removed. Undo is tied to the step by Undo_Mark{id, at}, never by len(history.done): forgetting strokes shrinks the list. Design + review: /mnt/project-files/notes/registry/op-result-design.md.
- PR #53 merged: settings.odin SETTINGS table {key, offset in App, type, lo, hi}; plain fields are one row, compound values hand-written; file starts `version 1`; settings_test.odin checks each row's offset/type against App by reflection.
- PR #54 merged: brushes.odin BRUSHES [Brush_Kind]Brush_Info{name, help, icon, strength, flags Grab/Hook/Cloth/Paint/Mask}; BRUSH_NAMES/BRUSH_HELP/KIT_BRUSH_ICONS gone.
- Registry workstream (1) complete 2026-10-25; touch parity (2) complete 2026-10-26 (#55-#61). Phase 3 continues in [[sculpt-discoverability]].
- Touch step 1 merged 2026-10-25 as PR #55: modifier rail (modifiers.odin; Smooth/Invert/Mask/Hide, tap latches, hold momentary, finger owned by the rail in touch_event, press snapshot rail_press), coloured ring, Rail_Side setting (key modifier_rail), STROKES_VERSION 3. Design + review changes: /mnt/project-files/notes/registry/modifier-rail-design.md. Scripted pen has no pressure: mask scenarios use a finger stroke.
- Touch step 2 merged 2026-10-25: PR #56 (kit: ui.secondary after a widget, long press 0.45 s with ring, tooltip on unclaimed long press, right-click twin, vslider reset, --ui-dt fixed clock; touch_check passes --ui-dt=1/60) and PR #57 (directory: Undo/Redo → History, brush tiles → settings, sliders reset, status chip tap → Object tab / long press → object menu). Design: /mnt/project-files/notes/registry/long-press-design.md.
- PR #58 merged 2026-10-26: `python3 scripts/gate.py` runs the whole done gate (check, test, build, smoke, touch, wincheck, androidcheck; logs build/gate/), ~3 min; touch_check runs in parallel on private Xvfb displays and takes patterns; timed gestures use input_clock (fixed under --ui-dt). Use gate.py instead of chaining steps.
- PR #59 merged 2026-10-26 (touch 3a): finger double tap frames (empty) or pins pivot (model, only with Finger_Model.Orbit); lift one of two fingers orbits; hold 2/3 fingers repeats undo/redo; settings double_tap, lift_one_orbit, hold_history; fixed tap losing latched rail mods (Drag.mods). Design+review: /mnt/project-files/notes/registry/touch-gestures-design.md. 
- PR #60 merged 2026-10-26 (touch 3b): Dab_Wait defers a finger tap's dab 0.3 s so a double tap on the model pins the pivot in sculpt mode too; touch_check: single-tap scenarios must wait 24 frames. 
- PR #61 merged 2026-10-26: start-location mask taps (Mask on: tap off model invert, on mask blur, off mask sharpen; Ctrl+click off model invert; mask presses pending for all pointers). Touch parity workstream (2) complete.
- Container setup: scripts/setup_deps.sh needs apt packages from its header + xvfb; run smoke/touch_check under `xvfb-run -a -s "-screen 0 1600x1000x24"`.

**Why:** registry is the spine for search, rebinding, toasts, adjust-last ([[ux-research]]).
**How to apply:** new shortcuts/menu rows go through commands.odin; keep binding order meaningful.
