# Basic / More disclosure per inspector section (UX roadmap phase 3, P19): design

Base: odin-sculpt 6c4120f (PR #66). Source: 09_Interaction_Patterns.md P19 ("each inspector section has Basic (≤5 controls) and a More fold; experts can pin always show more"), 12_Product_Roadmap.md phase 3 ("Basic ≤ 5 controls").

## Problem
The inspector's sections carry up to ten controls each (Mask 10, Transform 7, Recorder 7, Retopology 7 with UVs, Project 6, Polygroups 6, Material 6, Camera 6). A tablet user scrolls past rarely used ones to reach the common ones.

## What exists when done
- Every inspector section (Brush, Object and Scene tabs, including the Curve and Insert tool tabs) shows at most five controls by default. Where it has more, the rest sit under a "More options" row at the end of the basic part; a tap opens them below (the row then reads "Fewer options"), growing in with the section motion token (instant under Reduce motion).
- Settings > Interface: "Show every option" (off by default, remembered, SETTINGS row `all_options`): every section shows everything and no More row is drawn.
- The More state is per section (`Kit_State.more: [Kit_Section]bool`), per session, as the sections' own open state is.
- Exit stats: `more=<sections with More open, '+' joined, or none>` and `all_options=<0|1>`.

## What a control is, and how it is held to five
- `ui.Context.controls` counts every interactive widget laid out (button, icon button, chip, toggle, tabs, switch, slider, vertical slider, list row, menu item, select, brush tile, modifier button, drag value, text field, area), disabled ones included. A colour (three sliders) counts three; a pair of buttons two.
- The More row itself is not counted: it is the way to the rest.
- Lists that are the section's content rather than its options (alpha thumbnails, a layer's row) are drawn in the test's fixture state (no layers; the alpha grid is counted out by the test, which subtracts len(alphas) + 1).
- App test `sections_show_at_most_five_controls`: lays out every section of `BRUSH_SECTIONS`, `OBJECT_SECTIONS` and `SCENE_SECTIONS` headlessly (ui.init, a GPU-free test object) with every More folded and asserts ≤ 5; and asserts that with More open, a section with a More row shows more than without (the fold hides something).

## Which controls go under More
| Section | Basic | More |
|---|---|---|
| Stroke | Size, Strength, cloth mode (Cloth only) | Lazy mouse, Dots / Drag rectangle |
| Stroke recorder | Record, Replay (Stop) | Recorded brushes, Instant, Save, Load, Clear |
| Transform | Position X/Y/Z, Scale | Turn about X/Y/Z |
| Mask | Clear, Invert, Mask all, Cavities, shape tabs | Blur, Sharpen, Grow, Shrink, Steps (the action bar offers these while masked) |
| Polygroups | Group visible, Group masked, Show polygroups | Crease angle, Groups by creases, Clear groups |
| Retopology and baking | Quads, Retopologize, Bake from, Bake maps, New UVs | Bake size, Reach |
| Project detail | Source, Reach, Strength, Project | Polypaint too, As placed |
| Booleans | Mode, Live boolean, Make | Live vertices, Result vertices |
| Material | Material | Colour, Metallic, Roughness (the Custom sliders) |
| Camera | Orthographic, the six views, Reset, Focus | Distance |
| others | already ≤ 5 | none |

Paragraphs that explain a More control move with it.

## Code
- `src/ui/widgets.odin`: `more(ctx, name, open: ^bool, always: bool) -> bool` and `more_end(ctx)`. It shares the section's growing, clipped body (factored into a private `fold_body`); with `always` it draws no row and returns true with a plain body, so a caller always pairs a true return with `more_end` even if the setting flips mid-frame.
- `src/app`: `kit_more(app, sec) -> bool` / `kit_more_end(app)` wrap it with `k.more[sec]` and `k.all_options`.
- `kit_brush_tab`'s and `kit_scene_tab`'s sections move into tables (`BRUSH_SECTIONS {section, title, draw, shown}`, `SCENE_SECTIONS`) as the Object tab's already are, so the test walks them.
- Settings row `all_options`, the Interface switch, its reset; README (Interface paragraph, Settings list); sm-ui skill row.

## Tests
- Unit: the five-controls test above; `ui` test that `more` with `always` draws no row and a folded `more` returns false without a body.
- touch_check (desktop simulation): a finger tap on Mask's More shows `more=mask`; a second tap folds it (`more=none`); with `all_options 1` in the settings file there is no More row (`more=none`, Steps reachable: a tap where it sits in the full layout moves nothing else). Existing scenarios that tap inspector controls get new coordinates where the basic layout moved them.
- Screenshots: Object tab Select page folded and open at 1600×900.

## Not in this step
Presets section (10 §Inspector), per-control pinning, remembering More per section across runs.

## Size
About 300 lines with tests. No History, Scene_Command, GPU, file or package change; one settings row.

## After the sm-architect review (applied)
- Only sections over five controls fold: Stroke (5 at most, Lazy mouse stays) and Booleans (5) have no More.
- Mask keeps Steps in the basic part (the action bar's step buttons and the Mask taps read it); Mask cavities moves under More with Blur, Sharpen, Grow and Shrink.
- Material keeps its colour in the basic part; only Metallic and Roughness fold.
- "Last: ..." lines stay outside the folds.
- The test counts every section in its widest state: a selected object with one layer (its row's four controls not counted) and UVs, a second object, the built-in alphas with one in use (thumbnails not counted), every brush kind.
- Settings needs no version bump: settings_load skips keys it does not know. Escape never folds a More (it is not floating).
