# Brush icons: grey ball, coloured effect (2026-11-05)

19 brush icons, one per `sculpt.Brush_Kind`, in the style Bolt picked: a matte grey ball with
the brush's effect in its own glossy colour.

## Files
| File | What |
|---|---|
| `<brush>.png` | The 3D render, 384×384 with a transparent background. The thing to retouch in an image editor. |
| `<brush>.svg` | The icon as used: the PNG embedded, plus any vector marks drawn over it (Pinch's arrows, History's turn-back arrow). Open in Figma, Illustrator or Inkscape; the marks stay editable. |
| `glossy.png`, `sheet.html` | The contact sheet: all 18 large, at 20 and 26 pt, and on a mock of the shelf. |
| `ray2.py` | The renderer. Each brush is a signed distance field in `scene()`. |
| `glossy.js` | Builds the SVGs and the sheet from the PNGs, and holds the vector marks (`OVER`). |

Names: draw, clay, inflate, layer, clay_strips, crease, pinch, smooth, flatten, trim (Trim dynamic), tube,
grab, snake (Snake hook), elastic, cloth, mask, paint, history, morph.

## Changing an icon
- **Colour:** edit the brush's entry in `COL` in `ray2.py` (RGB, 0 to 1).
- **Shape:** edit the brush's branch in `scene()`. It returns the distance `d` and the colour weight `w`
  (0 = grey ball, 1 = effect colour). Helpers: `onball(x, y, h)` is a point on the ball's front, `cap`
  a capsule, `rcone` a tapered tube, `smin`/`smax` smooth union and cut, `cap_region` a round patch.
- **Light:** `Ld` in `render()` (now from the top left), the grey in `grey`, the gloss in `gloss`.
- **Framing:** `sc` (zoom) and the offsets in `render()`; the same framing for all, so Grab and
  Snake hook fit.

Re-render one or all (about 30 s each; they run in parallel):

    python3 ray2.py clay
    for n in draw clay inflate layer clay_strips crease pinch smooth flatten trim grab snake elastic cloth mask paint history morph; do python3 ray2.py $n & done; wait
    node glossy.js        # rebuild the SVGs and the sheet (needs Playwright for the sheet only)

`ray2.py` needs numpy and Pillow and writes into `/mnt/project-files/notes/icons/glossy/`; change the
path at its end to run it elsewhere.

## Known rough spots
- Trim dynamic looks like Flatten (one cut); it should show a ridge of two planes.
- On the shelf the balls are small, as the framing leaves room for Grab's and Snake hook's reach.
- The app cannot show these yet: icons are Lucide font glyphs today. Shipping them needs the PNGs
  packed into an atlas at startup (as the brush stroke pictures are), a short design first.
