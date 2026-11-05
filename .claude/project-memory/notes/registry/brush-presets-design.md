# Brush presets and an editable dock (UX roadmap phase 4, first item): design

Base: odin-sculpt f3f2e7c (PR #69). Sources: 12 roadmap Phase 4 row 1 ("Brush presets: save, clone, revert, rename, thumbnail; dock slots user-editable"; done when "presets persist; dock long-press works"), findings N004 (Nomad's brush presets), C086 (Blender's brush assets).

## What exists when done
- A **preset** is a named brush: a base brush (sculpt.Brush_Kind) with its own strength, falloff, alpha (by name), alpha mode and angle, stroke kind (dots or drag rectangle), lazy mouse, paint colour and cloth mode. Size, the pen switches and curve, symmetry, front faces only and the dynamic topology detail stay global, as in ZBrush, so switching brushes never changes how big the brush is.
- Up to 24 presets (`MAX_PRESETS`). Picking one makes its base brush the brush and copies its settings in; from then on the brush is "on" that preset (`Brush_Settings.preset`, -1 when on a plain brush) until another brush or preset is picked.
- **Brush tab > Preset** section, first in the tab (at most five controls):
  - On a plain brush: "Save as preset" (makes "Clay 1"... from the current settings and goes on it) and "Reset brush" (the brush's strength and falloff back to a fresh install's; enabled only when they differ).
  - On a preset: its name as a text field (rename; empty or a duplicate name is refused with the old one kept), "Save changes" and "Revert" (both enabled only when the settings differ from the preset; the section's title then reads "Preset · changed"), "Save as new" (clone), and under More options "Delete preset".
- **Brush browser** (the grid button on the dock): under the brushes, a PRESETS block of the same tiles, the base brush's icon with the preset's name; tap picks, long press (or right-click) opens its settings, as brush tiles do. With none yet, one line says how to make one.
- **Editable dock**: its seven slots each hold a brush or a preset (`Kit_State.dock: [DOCK_SLOTS]Dock_Slot`). A long press (or right-click) on a dock tile opens a slot popover above it: "Brush settings" (what the long press did until now), then "Put here" with every brush and preset as small tiles, then "Reset dock". A deleted preset's slot falls back to its base brush.
- **Remembered** (settings.txt, no version bump: older files simply have none of these lines):
  - `preset <kind> <strength> <drawn> <c1x> <c1y> <c2x> <c2y> <alpha_mode> <alpha_angle> <stroke> <lazy_px> <r> <g> <b> <cloth_mode> <name...>`: the name is the rest of the line (spaces allowed, trimmed, at most 32 bytes);
  - `preset_alpha <name...>` after it when it has an alpha: matched by name against the alphas this run has (the built-in ones; a loaded image's name only matches when that image is loaded again), else round;
  - `dock <slot> brush <Kind>` / `dock <slot> preset <index>`;
  - `brush_preset <index>`, the preset the brush was on.
- **Commands**: `.Preset_Save_New` ("Save brush as preset"), `.Preset_Save` ("Save preset changes"), `.Preset_Revert` ("Revert preset"), `.Brush_Reset` ("Reset brush"), all in the palette with search words (preset, save brush, clone, revert, reset). Picking presets from the palette by name waits for the pies/favourites step, which also needs the palette to read names from the app.
- Exit stats: `presets=<n> preset=<index> preset_changed=<0|1> dock=<slot names, comma separated>`.

## Code
- New `src/app/presets.odin` (about 200 lines): `Brush_Preset` struct (name as a fixed `[32]u8` + length, so presets are plain values with no ownership), `preset_capture(b) -> Brush_Preset`, `preset_apply(app, i)`, `preset_changed(app) -> bool` (field compare, alpha by index), `preset_save_new`, `preset_save`, `preset_revert`, `preset_delete` (shifts later indices; fixes `brush.preset` and dock slots), `brush_reset`, `Dock_Slot` and `dock_slot_label/icon/run`.
- App: `presets: [dynamic]Brush_Preset` (or a fixed `[MAX_PRESETS]` array plus count, which keeps `App` copy-safe for tests: chosen). `Brush_Settings.preset: int`.
- Picking a plain brush (`.Brush` command) sets `preset = -1`; the `.Brush` command's checked state is "this kind and not on a preset".
- new_ui.odin: the dock loops over `k.dock`; the browser's PRESETS block; `kit_dock_popover`. kit_tool.odin: `.Preset` Kit_Section at the top of BRUSH_SECTIONS.
- settings.odin: the lines above; settings_test round trip.
- README: Interface (dock, browser), Brush tab, remembered settings; sm-ui skill row for the dock popover.

## Tests
- Unit: capture/apply round trip; changed after any one field moves, not after re-applying; delete fixes the preset index and the dock; settings save → load gives the same presets, dock and active preset (names with spaces; a damaged line is skipped).
- touch_check (desktop simulation): Save as preset from the Brush tab (presets=1, preset=0); long press a dock tile, tap the preset under Put here, then tap that slot (brush is on the preset, dock lists it); change strength → Revert puts it back; a settings file with two presets and a dock line loads into the dock.
- Screenshots: the Preset section changed, the browser with presets, the dock popover, at 1600×900.

## Not in this step
Rendered thumbnails (tiles show the base brush's icon; a later step can draw the alpha or a lit sphere dab), presets in the palette and pies (next item), per-preset size, sharing presets as files, the History or scene file (presets are settings, not scene data).

## Size
About 450 lines with tests. No History, Scene_Command, GPU or scene-file change; settings lines added; one new Kit_Section and popover.

## After the sm-architect review (applied)
- Split in two PRs: (1) presets, the Preset section, commands and settings; (2) the browser's presets and the editable dock with its popover (the long-press change to dock tiles, kit_floating and Escape, popovers that fit at 800×640).
- No overwrite of plain brushes: while on a preset the brush's slots hold its values and `Brush_Settings.plain` keeps the plain ones; `.Brush`, `--brush` and settings save restore them (`preset_leave`, `brush_plain`). A recorded brush is plain.
- Settings refer to presets by name (escaped, %20), the alpha on the `preset` line by name (built-ins resolved by ALPHA_SHAPE_NAMES order); `brush_preset` is resolved after the loop and re-applies the preset, so it never reads as changed.
- Names refuse brush names and duplicates, cut on a UTF-8 boundary; the name is edited in a Kit_State copy and renames on focus loss.
- `preset_changed` ignores colour except for Paint, cloth mode except for Cloth, alpha for Grab.
- Section title is a proc-built string with a fixed `##preset` id ("Preset: Soft clay · changed"); the section starts folded so the Brush tab moves down by one row only.
- New commands sit inside the Tools range; the section is tested at its widest (on a preset) for the five-control rule; exit stats use slugs.

## Step 2 as built (PR after #70)
- `src/app/dock.odin`: `Dock_Slot{kind, preset}` (preset from 1), `Kit_State.dock` from `DOCK_DEFAULT`, `dock_put`, `dock_slot_pick/settings/on/label`, `dock_preset_deleted` (called by `preset_delete`), `dock_names` for the exit stat `dock=`.
- One grid for both popovers (`kit_brush_grid`): 14 brushes, then PRESETS tiles (`name##preset i`), in a `kit_scroll_begin` body sized to the room above the dock; it scrolls to the lit tile on opening. Slot popover: Brush/Preset settings, the grid (tap puts), Reset dock. Dock tiles use `##slot i` ids.
- The ui kit: select lists taller than the room are cut to the window and scroll (fixes the Preset list with 24 presets); brush tiles cut long names with "..." and show them whole in the tooltip.
- Settings: `dock <slot> brush <Kind>` / `dock <slot> preset <escaped name>`, resolved after the loop; Settings > Interface reset puts the dock back.
- Screenshots: shots/dock-slot-menu.png, shots/browser-presets.png, shots/*-800x640.png (24 presets).
