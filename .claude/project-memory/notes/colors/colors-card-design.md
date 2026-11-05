# Colors card (Procreate names, ZBrush for iPad strengths)

Bolt, 2026-10-27: "add a color picker and make the pop up look like procreate ... take strengths of zbrush for ipad too but the name reference should be procreate". Rule: best of all worlds (design-best-of-all-apps).

## What exists
- Brush bar Colour button (kit_bars.odin) opens the tray's Colour section (kit_brush_colors) in a bar pop: channel tabs, `kit_color` (swatch + hex + R/G/B sliders), secondary colour and Swap under More options. Long press = Swap colours (ZBrush).
- `app.brush.color` / `color2` are sRGB display values; settings lines `paint_color`, `paint_color2`.
- Paint command: Fill / Clear (mask and hiding respected), one undo step.

## What it becomes
A **Colors card** (ui.card_begin, a Kit_Window like the Objects card), opened by the brush bar's Colour button, placed beside the brush bar (where ZBrush puts its Color card). It stays open while you paint (Procreate's Color Companion and ZBrush's card both persist); the dots drag it, holding the dots docks it back into the tray's Colour section.

| Part | From | Notes |
|---|---|---|
| Title "Colors", header row: main and secondary swatches, Swap, then Fill object, Fill gradient, Eyedropper, Close | ZBrush (swatch pair + swap + eyedropper + FillObject / FillObject Grad), Procreate (primary/secondary rectangles, tap to choose which one the pickers edit) | the edited swatch is outlined; long press a swatch = Swap |
| Tabs along the bottom: Disc, Classic, Harmony, Value, Palettes (icons + names) | Procreate, same names and order, remembered | `colors_tab` setting |
| Disc: hue ring round a saturation/brightness disc (square mapped into the disc, saturation across, brightness up) | Procreate's Disc; ZBrush's ring | reticles: the ring's and the disc's |
| Classic: saturation/brightness square, then Hue, Saturation, Brightness gradient sliders | Procreate Classic | |
| Harmony: mode (Complementary, Split Complementary, Analogous, Triadic, Tetradic) at the top left; hue/saturation disc (angle = hue, radius = saturation); Brightness slider under it; the scheme's colours also as a row of swatches | Procreate Harmony; the swatch row is ours (touch-sized targets beat 20 pt reticles) | tapping a secondary reticle or swatch makes it the colour; `colors_harmony` setting |
| Value: HSB / RGB segmented control, three gradient sliders with values (degrees, %, 0-255), Hexadecimal field | Procreate Value; ZBrush's RGB/HSV modifiers | hex parse already exists (3 or 6 digits) |
| History: last 10 colours, Clear, on Disc/Classic/Harmony/Value | Procreate | a colour joins when a pick ends (release, hex Enter, swatch tap, eyedropper), deduped; `color_history` setting |
| Default palette under the history | Procreate | |
| Palettes tab: built-in palettes (Skin, Creature, Clay and stone, Greys, Vivid) + your own (up to 8 x 32 swatches), + New palette, a check marks the default, menu: Set as default / Duplicate / Delete; tap an empty slot saves the current colour; long press a swatch: Set to current colour / Delete swatch; your palette's name is a text field | Procreate (Compact view only); skin/creature palettes are for sculptors | `color_palette` / `color_default` settings lines |
| Eyedropper: the button arms it, the next press on the model picks the colour under it (polypaint over the material, unlit), holding and dragging shows a loupe ring, top half the new colour and bottom half the current (Procreate), release picks. Shift+C picks under the pointer at once (ZBrush's C) | Procreate loupe, ZBrush pick | Escape cancels |
| Fill object / Fill gradient | ZBrush FillObject / FillObject Grad | Gradient: main colour at the object's top as seen to secondary at its bottom, mask and hiding respected, one undo step (`Paint` command arg Gradient) |

Every hit area stays 48 pt (sm-store): swatches are 8 to a row of a 408 pt card (48 pt cells); the card body scrolls when the window is short.

Not doing now: Procreate's Cards palette view, ColorDrop drag-to-fill, palette import from files/camera, per-channel number typing (hex covers exact entry), editing material/light/background colours in the card (they keep `kit_color`).

## Code
- `src/app/kit_colors.odin`: card, colour maths (HSV), harmony, history, palettes, eyedropper frame and loupe.
- `src/sculpt/paint.odin`: `Paint_Command.Gradient`, `sculptor_color_at`.
- `commands.odin`: `Colors_Card`, `Eyedropper` (Shift+C); `Paint` gains Gradient.
- `settings.odin`: `colors_tab`, `colors_harmony` (rows), `color_history`, `color_palette`, `color_default` (lines).
