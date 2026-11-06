# Materials UI: one Material card, live material balls, imported materials, the Render card (design, 2026-11-06)

Bolt's ask (through the coordinator): "refactor the render card and overall just refactor how we see materials, how
we can preview materials like metal, glossy, glass, similar to Substance Painter. Refactor those key pieces and make it
clean and concise. I have objects I exported from Blender that have materials, but I can't see them in my app."

Phase 1 is design only, and it ends when Bolt picks one of the three mocks beside this note:
`a-shelf.html`, `b-scene-first.html`, `c-studio.html` (`index.html` links them).

## What is wrong today (read from the code and Bolt's screenshot `look-card-now.png`)
1. **Three UIs for one thing.** Materials show up in three places:
   - the Look card's Material section (`lens_materials.odin`), which mixes Materials, Matcaps and Environment as tabs;
   - the Shading menu (`kit_shading_menu` → `shading_options`, `passes.odin`), which repeats the looks (Clay, Lit, Full,
     Flat) and a second MatCap picker as rows of word tabs;
   - the pass chip's list, which repeats the same looks under RECENT and SHADING.
   The MatCap is picked in two places that mean different things. The Material card sets an object's matcap
   (`Material.matcap`), while the Shading menu sets the Clay look's matcap (`View_Shading.matcap`).
2. **Controls repeated across cards.** The Look section's Key light, Ambient, Shadow, Shadow softness and Occlusion
   are "the control of the same name" in Lights and Render's Fast. Its own paragraph says so.
3. **The Render card is two controls for one choice.** A Render switch sits beside Fast/Full tabs, which makes four
   states for three outcomes. It also has a paragraph of prose per quality and no place for E's output, passes and
   size work.
4. **Imported materials are lost.** `geom.mesh_parts_paint` (called from `files.odin:983`) bakes each glTF, FBX or USD
   material's base colour and texture into the vertex colours, then drops the materials. Metallic, roughness and every
   layer are thrown away, so a Blender export arrives as polypaint on Clay. This is why Bolt "can't see" them.
5. **The balls are not the material.** `ui.fill_ball` is a flat 2D shaded disc in the material's colour, so Chrome,
   Steel and Ceramic all read as grey discs, and glass, skin and velvet could never read at all.

## What stays (shared by all three directions)
- **The Material card is the one material UI.** It holds the library shelf, the scene's materials and the editor. The
  rail's Material button, `Open_Section .Material`, the object menu and Search all open it.
- **Shading menu = how the view looks.** It keeps the four looks and, for Clay, its MatCap as one row of picture discs.
  MatCaps leave the Material card: a MatCap is a view-locked light, which is how Blender and ZBrush for iPad use them.
  Per-object MatCaps are ZBrush's 1999 "material = picture" (see "Push back" below). The menu's RECENT and INSPECT
  repeats of the looks go; INSPECT stays the pass chip's.
- **The Look card becomes Light.** Its sections are Lights, Environment, Background and Floor, plus a "Viewport style"
  fold holding Cavity, Ridge, Rim, Underside and Live occlusion. Today's Look section is dissolved: each slider stays
  only where it is the real control.
- **Material balls drawn by our renderer** (render worker's side; the card only shows atlas images):
  - each preset, scene material and pack material is a sphere rendered with the viewport's own PBR path, under the
    scene's environment, into a 160 px tile of one ball atlas;
  - E4-E6 give the raster path skin, coat, sheen and transmission, so Glass, Skin and Velvet read in their balls;
  - the editor's big preview ball is re-rendered while a value moves, so it is live;
  - a scrub over the balls still tries each one on the real objects (Nomad's), the best preview there is.
- **Imported materials are kept, not painted** (render worker's E8, extended to FBX and USD). The design asks E8 to land
  each imported material as one of the object's materials, with its values and maps. An object with several becomes
  one polygroup per material, each group with its `Group_Material` (the table exists, 15 a object; more than 15 merge
  by nearest values and say so in the import note). Paint-into-vertices becomes a choice ("Bake to paint") rather than
  the only path.
- **The layers as folds**, OpenPBR's order as Blender 4's Principled panels show them: Surface (always open: colour,
  roughness, metallic) → Subsurface → Coat → Sheen → Transmission → Glow, with Thin film under More. Each fold header
  has a switch (weight > 0) and a one-line summary when folded ("0.8 · 1.2 mm"). An open fold shows at most five
  controls (the kit rule).
- **Library categories** (KeyShot and Substance's split, cut to what a sculptor asks for): In this scene, Favourites,
  Clay, Metal, Glossy, Glass, Skin & wax, Fabric, Glow. "In this scene" groups the balls by object. A
  ball's corner badge counts the objects using it; the long-press menu offers "Select objects using it".
- **Render card refactor**:
  - one segmented control, Off | Fast | Full (it replaces the switch plus the tabs);
  - one progress line ("96 / 256 · 14 ms each") with a thin bar;
  - Quality as Draft | Good | Final, which sets samples and bounces (both exact values under More, with Denoise and
    Half resolution);
  - O1-O3 as folds: Output (size, transparent background, shadow catcher, Save image), Passes;
  - then the existing Lens, Finish, Camera, Turntable and 3D print folds, unchanged inside;
  - Fast's Occlusion, Shadow and Softness stay here only;
  - the prose shrinks to one line each, with the rest in Help.

## The three directions
| | A · Shelf | B · Scene first | C · Studio |
|---|---|---|---|
| Shape | one 312 pt card, like every card | one 312 pt card plus the Library sheet | one wide own-body card (≈ 600 pt), like Colours and History |
| Top of the card | the selected object's material as a big live ball, and Edit | the selected object's materials as rows (ball, name, values) | the scene's materials as a strip of balls |
| Browsing | category chips over a 4-across ball grid in the card | a "Replace…" button opens the Library sheet (categories down its side, big balls) | a category column and the grid on the left, the editor on the right, both always visible |
| Editing | Edit swaps the grid for the folds (one or the other) | the editor is always under the rows | always beside the grid |
| Imports | "In this scene", the first chip, groups by object | the rows are the import: one per material, with a "from file" tag and maps | the strip, with a per-object filter |
| Render | refactored card | refactored card, Save image as its one solid button | the render switch moves to a pill over the view (Off/Fast/Full, progress, Save); the card holds settings |
| Best at | browsing fast with a finger, Substance's shelf feel | many-material imports, exact values | desktop, seeing library and values at once |
| Weak at | editing and browsing are not both visible | browsing is one tap further (the sheet) | takes half a 1180 pt tablet view; new card kind |

**Recommendation: A (Shelf).**
- It answers both asks in one card the width of every other card.
- Browsing is the first thing you see, as in Substance's shelf, and with a finger the scrub-to-try works right there.
- Bolt's imports are the first chip, grouped per object, with their values one tap away.
- B is the better pick if many-material imports matter more than browsing, and its per-material rows can come to A
  later as the "In this scene" list view.
- C works best on desktop, but it breaks the tablet budget (half the view) and adds a new own-body card shape.

## Compare table
| Part | Taken from | Why it still holds | Avoided | Done better |
|---|---|---|---|---|
| Shelf of balls by category | Substance Painter's shelf, KeyShot's library | browsing by look beats reading names; categories match how people ask ("something glassy") | Substance's offline Iray thumbnails that go stale when an environment or value changes; a shelf the size of a window | balls rendered by our own viewport path under the scene's environment, re-rendered when it changes; 8 categories in one card |
| Scene materials first | Marmoset Toolbag's scene materials row, Blender's slot list | you edit what is on your model far more often than you browse | Blender's slot index per face, which is the dated per-face material index; Toolbag's shader-model dropdowns | one material per polygroup through the existing `Group_Material` table; no indices to manage |
| Layer folds | Blender 4 Principled panels, OpenPBR | the layering is the industry's model now (OpenPBR, glTF KHR_materials_*) | Toolbag's "module" dropdowns; Substance's per-channel tabs | a switch and summary on each header, folded when off, five controls at most |
| Try-on scrub | Nomad's material scrub (ours already) | the real model is the best preview; a finger slides | ZBrush's flyout that covers the view | kept, plus the live ball for the values the scrub cannot show |
| MatCap in the view | Blender's Solid MatCap, ZBrush for iPad | a view-locked light for sculpting is still the fastest read of form | ZBrush's MatCap-as-material (material = painted picture, 1999 palettes); our second MatCap picker | one MatCap picker, in the Clay look; objects keep real materials |
| Imports keep materials | glTF KHR_materials_*, Blender's export | the model arrives as it was made | today's bake to vertex colour that drops metal, roughness and layers | values and maps kept and listed per object; Bake to paint as a choice |
| Render card | Blender's render properties, Nomad's render toggle | Off/Fast/Full are three states of one thing | today's switch beside tabs (four states for three outcomes), and prose per mode | one segmented control, a progress line, Quality presets, the output folds |

## Budget (to be proved in phase 2 and by the render worker's ball pass)
- Ball atlas: 64 tiles of 160 × 160 RGBA8 = 6.5 MB on the device. Only what the card has shown is rendered.
- Rendering: one ball is a 160² draw of a 2.5k-triangle sphere on the viewport PBR path, which should be well under
  0.2 ms on the 890M. At most 4 balls a frame, and only while the view is still (the idle-cache rule): the whole shelf
  is ready in ≤ 16 frames. The live preview ball is one draw a frame while a value moves.
- Proven by `material_ball_ms` p50 and p99 and `material_balls_drawn` in the exit stats, plus `ui_ms` and
  `ui_vertices` against today's card. The card itself draws images, not discs, so `ui_vertices` should fall.
- Tablet fit: A and B keep the 312 pt card. C measures ≈ 600 pt of a 1180 pt view.

## Push back (sm-design 5)
- **"Matcaps as materials".** Today's Matcaps tab lets an object own a MatCap picture as its material. That is
  ZBrush's palette-era design: a picture stood in for lights the hardware could not run. We run real PBR. The need it
  met is "a fast, readable sculpting look", and the Clay look meets it already. So MatCaps live in the Shading menu
  only. Default: per-object matcaps go from the card. The field stays in the record (the render worker's) until it is
  removed with a file-format change.
- **"Like Substance Painter".** We take the shelf and the live balls. We do not take the texture-set and layer-stack
  painting model, which is the Paint card's job (`paint-layers`). A material here is a surface's values, not a stack.

## Open, each with the default I start on
1. MatCaps leave the Material card for the Shading menu. **Default: yes.**
2. Imports with more than 15 materials per object merge the extras by nearest values. **Default: yes, said in the
   import note.** The alternative is to split the object.
3. New presets for the new categories:
   - Glass, Frosted glass, Car paint (coat), Velvet, Satin, Neon (glow) and Soap film;
   - **default:** the render worker adds them with E5 and E6, beside Wax, Jade, Marble and Milk.
4. The Look card is renamed Light. **Default: yes.**

## Phase 2 sketch (after the pick; branch off the render worker's merged E-series)
1. Shading menu cut to the view, with the MatCap disc row; the Look card becomes Light (sections moved, Look section
   gone).
2. Material card: shelf, categories, In this scene grouped per object. The balls show as `fill_ball` until the atlas
   lands.
3. Layer folds wired to `Material.layers` (needs E5-E6 fields, which exist from E1a).
4. Render card refactor (needs O1-O3 for the Output and Passes folds; those folds come when O lands).
5. Ball atlas images in the card once the render worker exposes them.

Each step comes with `ui_shots.py` before and after, `ui_audit.py` and `touch_check.py` (the scrub and the folds).
