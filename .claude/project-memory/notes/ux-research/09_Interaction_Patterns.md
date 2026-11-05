# 09 · Interaction Patterns

A pattern library distilled from the three products, each written as a spec we can build. Status: ✓ we have it, ◐ partly, – not yet. Timings marked *(tune)* are starting values to validate on Bolt's OnePlus tablet (`sm-touch-testing` checklist).

## A. Pattern catalogue

### P1. Sticky modifier button (tap = latch, hold = momentary)
- **Problem:** touch has no Ctrl/Shift/Alt, and modal toggles cause "forgot it was on" errors.
- **Solution:** a button that latches on tap and acts only while held on press-and-hold. The brush cursor shows the active mode.
- **Seen in:** Nomad Sub/Smooth/Mask/Hide/Gizmo (N004); 3DCoat sticky keys (C004); ZBrush iPad wheel is hold-only (Z023).
- **Spec:** hold threshold 250 ms *(tune)*; latched state shows filled accent; released after a stroke if held; a latched Invert stays until tapped again. Applies to Smooth, Invert, Mask, Hide on the left rail. Keyboard modifiers still work and light the same buttons.
- **Status:** –. Code: new rail in `kit_layout`; mode resolution in `sculpt_tool.odin` already handles Shift/Ctrl (route both through one `Modifiers` set).

### P2. Start location chooses the target
- **Problem:** many actions per modifier without more buttons.
- **Solution:** with Mask active, drag on model = paint mask; drag off model = mask shape; tap off model = invert; tap masked = blur; tap unmasked = sharpen; drag off model without shape = clear.
- **Seen in:** Z061, N004 (hold Mask + tap).
- **Spec:** "tap" = under slop (10 pt) and under 250 ms; feedback toast names the action ("Mask inverted", with Undo).
- **Status:** ◐ (Ctrl+drag off model draws a mask shape).

### P3. Long press = secondary (right-click on desktop)
- **Problem:** every control needs options without more UI.
- **Solution:** long press on any control opens its options or actions; right-click does the same on desktop; a short haptic confirms.
- **Seen in:** Z032 (directory), N002 (bottom bar), Z151 (haptics).
- **Spec:** 450 ms *(tune)*; never also triggers the tap action; a ring fills during the press. Directory: brush slot → change/remove; brush → preset menu; Symmetry → radial/mirror; Undo → history; object chip → object actions; any slider → reset/type value; any command → bind key / add to favourites / help.
- **Status:** ◐ (scene list right-click menu).

### P4. Two-phase commit (draw, then confirm)
- **Problem:** shapes drawn on touch are imprecise; the view often needs to change before applying.
- **Solution:** draw the shape; it stays editable; ✓ applies, ✕ cancels; optional auto-apply.
- **Seen in:** N004 (green ✓, auto-validate); Z040 (staged commit); C021 (Enter).
- **Status:** – (our shapes apply on release). Add an "Auto-apply" setting, default on for mouse, off for touch.

### P5. Quasi-mode secondary brush
- **Problem:** switching brushes for smoothing breaks flow.
- **Solution:** Shift (or the Smooth button) temporarily swaps to a chosen smooth brush with its own size/strength memory.
- **Seen in:** Z121, C020, N002.
- **Status:** ◐ (Shift smooths; fixed brush, shared settings).

### P6. Relative scrub
- **Problem:** small sliders are hard to hit precisely on touch.
- **Solution:** slider values follow finger movement from where it lands (not jump to the touch point); long-press-drag on any value or icon scrubs it.
- **Seen in:** Z032.
- **Status:** ✓ for Size/Strength rail; extend to all inspector values.

### P7. Pivot by double-tap, with visible pivot dot
- **Problem:** "getting lost" orbiting around the wrong point.
- **Solution:** double-tap on model sets the pivot there; on background frames the selection; a dot shows the pivot while orbiting.
- **Seen in:** N012; C005 (F picks pivot).
- **Status:** – (F frames).

### P8. Orbit fallback when no background is visible
- **Solution:** two fingers down then lift one continues as orbit (N012); right-drag (desktop); a small on-screen orbit puck (accessibility, N003).
- **Status:** ◐ (right-drag on desktop).

### P9. Command palette with in-place binding
- **Solution:** see 08 §5. Each result: name, icon, shortcut, gesture, and a ⋯ menu (bind key, add to dock/pie, help).
- **Seen in:** Z033, C008, C073, N003.
- **Status:** –.

### P10. Bind where you see it
- **Solution:** desktop: hover any control and press a chosen bind key (3DCoat uses END) to capture a shortcut; touch: long press → "Assign key / gesture". Conflicts shown inline with Replace / Keep both (stacked: repeat press cycles) / Cancel.
- **Seen in:** Z071, C004, Z152.
- **Status:** –. Depends on the command registry (A-20).

### P11. Contextual action bar
- **Solution:** see 08 §4.
- **Seen in:** N004 (per-tool top toolbar), C002 (contextual top bar).
- **Status:** –.

### P12. Adjust last operation
- **Solution:** after a parameterised command (remesh, decimate, retopo, smooth all, mirror, extract), the action bar shows "Adjust…"; changing a value re-runs it from the pre-op snapshot. Strokes: "Adjust last stroke strength" slider.
- **Seen in:** Z123.
- **Status:** –. Our `History` swap snapshot already holds the pre-op object.

### P13. Live preview before commit
- **Solution:** density checkerboard while dragging remesh size (N007); boolean ghost; retopo wireframe preview on a draft pass (C035 Draft quality).
- **Status:** ◐ (live booleans).

### P14. Undo toast instead of confirm dialog
- **Solution:** destructive actions run at once and show "Deleted Sphere 2 · Undo" for 5 s.
- **Seen in:** modern practice; N022 shows confirm fatigue ("reflexive tapping").
- **Status:** ◐ (Reset everything uses tap-twice).

### P15. Colour-coded cursor
- **Solution:** brush outline colour encodes mode: accent = sculpt, blue = smooth, amber = mask, red = hide/cut, green = show; dashed when the brush can't act (e.g. dyntopo incompatible).
- **Seen in:** Z023, Z077, Z088.
- **Status:** –.

### P16. Tree column drag
- **Solution:** in the Objects list, drag down the eye column to hide/show many; down the select column to multi-select; long press a row to reorder or parent.
- **Seen in:** N006.
- **Status:** –.

### P17. Hold to repeat
- **Solution:** two/three-finger tap undoes/redoes; keeping the fingers down repeats every 150 ms *(tune)*; Undo button hold does the same.
- **Seen in:** N003, N019.
- **Status:** ◐ (tap only).

### P18. Coach marks and empty states
- **Solution:** first run shows three dismissible hints in place: "Draw on the model", "Drag empty space to turn", "Two fingers to move and zoom". Empty panels explain themselves.
- **Seen in:** N002 (first page tutorial), C063 (missions).
- **Status:** –.

### P19. Progressive disclosure per panel
- **Solution:** each inspector section has Basic (≤5 controls) and an "More" fold; experts can pin "always show more".
- **Seen in:** N003 (Expand list), C030 (show/hide focal shift).
- **Status:** ◐ (sections fold).

### P20. Stroke offset
- **Solution:** optional offset of the brush centre from the finger, for phones and small tablets.
- **Seen in:** N013.
- **Status:** –.

### P21. Right-drag size/strength (desktop)
- **Solution:** with a modifier (e.g. hold Space or the pen's barrel button) drag horizontally = size, vertically = strength; mirrors the three-finger touch gesture.
- **Seen in:** C020.
- **Status:** – (right-drag is orbit, so bind to Space+drag or pen button).

### P22. Camera history
- **Solution:** "previous view / next view" commands and a gesture (two-finger long-press *(tune)*), separate from model undo.
- **Seen in:** Z110, N019.
- **Status:** –.

### P23. Assistive navigation
- **Solution:** optional on-screen orbit/pan/zoom puck for users who can't multitouch, and for pen-only tablets.
- **Seen in:** N003.
- **Status:** –.

## B. Unified input map (target)

One table per input device; every row is a registry command, so all are rebindable.

### Touch (finger)
| Gesture | On model | On empty space | On UI |
|---|---|---|---|
| 1 finger drag | Sculpt (or turn view, setting) | Turn view | Control / scroll |
| 1 finger tap | With Mask/Hide held: P2 taps | With Mask held: invert; else deselect | Press |
| 1 finger long press | – | – | Secondary (P3) |
| Double tap | Set pivot (P7) | Frame selection | – |
| 2 finger drag / pinch / twist | Pan / zoom to fingers / roll | same | – |
| 2 down, lift 1 | Continue as orbit (P8) | same | – |
| 2 / 3 finger tap | Undo / redo (hold repeats) | same | – |
| 3 finger drag | Size (vertical) / strength (horizontal) | same | – |
| 4 finger tap | Hide all UI | same | – |

### Pen
| Action | Result |
|---|---|
| Tip on model | Sculpt with pressure (and tilt if on) |
| Tip on empty space | Turn view (or wait for model, setting) |
| Barrel button 1 + drag | Size / strength (P21) |
| Barrel button 2 | Bindable (default: Smooth momentary) |
| Hover | Brush footprint preview |
| Pen near | Single fingers ignored (palm) |

### Mouse + keyboard
Keep ZBrush map (README "Controls"): left drag sculpt / off-model orbit, right drag orbit, Alt or Shift+right pan, Ctrl+right zoom, wheel zoom, Shift snap, Ctrl invert, Shift smooth, Ctrl+drag off-model mask shape, Ctrl+Shift drag gesture tool. Add: right-click on any control = secondary (P3); Space hold = pie; Space+drag = size/strength (P21); Ctrl+K or `/` = search; hover + bind key = bind (P10).

## C. Anti-patterns to avoid (each documented as harmful)

| Anti-pattern | Evidence |
|---|---|
| A mode that silently changes what the next stroke does (drop-to-canvas, sticky conditions) | Z107, C023 |
| A key whose meaning depends on object state | Z069, Z063 |
| Mid-drag modifier release chords | Z018 |
| Modifier timing before vs after click | Z141 |
| Hover-only affordances | Z153, C033 |
| Implicit parameters from unrelated state (boolean op from visibility, protect from shading toggles) | N006, N013 |
| Per-tool copies of global state (symmetry) | N004 |
| Confirm dialogs that train reflexive tapping | N022 |
| Saving that looks finished before it is | C059 |
