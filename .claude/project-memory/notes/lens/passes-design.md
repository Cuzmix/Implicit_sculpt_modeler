# Lens P0-4: pass switcher and diagnostic passes

Spec: Lens report, "Passes are one tap and one hold away" (the pass chip opens a popover with one-key shortcuts, and holding it peeks at the last other pass) and roadmap item 4 (Normals, Depth, Curvature, AO-only and Silhouette; hold to peek; one-key shortcuts). Wipe compare and per-pane passes wait for P0-5.

## What exists when done
- **A pass chip in the top bar**, just before History: the pass's glyph and name ("Shaded", "Normals" and so on), accented while it is not Shaded.
  - A tap opens a popover listing the six passes, each with its key, and the current one checked.
  - A finger, pen or mouse held on the chip (past the hold delay, Settings > Touch) shows the last other pass for as long as it is held. Letting go brings the pass back. A hold with no other pass yet peeks at Normals.
- **Six passes** (`render.View_Pass`), which change only how the meshes are shaded. The wireframe, the floor (except in Silhouette), the gizmo, the cursor and the overlays draw as they do now.
  - **Shaded**: as now.
  - **Normals**: the view-space normal as a colour (`n * 0.5 + 0.5`, as Blender's and ZBrush's normal views show it), unlit and not tone mapped. Flat shading keeps its faceted normal.
  - **Depth**: near is white and far is black, across the scene's bounds as seen from the camera now (`near`/`far` from the visible objects' bounding sphere), on a black ground.
  - **Curvature**: the cavity's `curvature(n, p)` as a diverging ramp. Flat is mid grey, a crease goes toward blue and a crest toward orange, full at `CURVE_FULL`. It is unlit, so form never hides it.
  - **AO**: a plain light grey (0.8 albedo, unlit) with live AO forced on, whatever Settings say. It is the GTAO buffer alone, at the strength and reach in use.
  - **Silhouette**: every object flat near-black on the thumbnail's paper ground (`THUMBNAIL_PAPER`), with no floor. It is the thumbnail window's silhouette, full size.
- While a pass other than Shaded shows, the traced studio and render mode pause, keeping what they built. Their buttons still toggle them, and they carry on once Shaded is back.
- **Keys:** Alt+1 to Alt+6 pick a pass, and pressing the current pass's key goes back to the last one. A held backquote (`) peeks, as holding the chip does. These keys are free today.
- **Commands** (registry): `View_Pass` (arg: the pass, named `shaded`, `normals`, `depth`, `curvature`, `ao`, `silhouette` in keymaps and scripts), `View_Pass_Last` (back to the last one) and `View_Pass_Menu` (the popover). Search finds them with "pass", "normals", "depth", "curvature", "ao", "occlusion" and "silhouette". They are also offered in the Shading menu as a "Pass" row.
- **Workspaces** hold the pass: a `pass <name>` line in the layout text, written only when the pass is not Shaded, so the built-ins and older layouts read as Shaded. Changing the pass lights the dot, as the Lens report says ("each pane's camera, pass and overlays").
- **Peeking** is never part of the layout, never saved, and never an undo step.
- **Exit stats:** `pass= pass_peek= pass_switches=`.

## Code
- `render.View_Pass :: enum u8 {Shaded, Normals, Depth, Curvature, AO, Silhouette}`.
- `Draw_Item.pass: [4]f32` (x is the pass, y near, z far, w unused) goes into `Material_Uniforms` as a new `vec4 pass` after `style`. This is the only change to the uniform layout. It joins both per-item `Keyed` tuples, so the idle cache and partial redraw see a change of pass.
- `mesh_shading.glsl` gets one early branch after the normal and `bend` are known. Each pass writes `out_color` and returns, so Shaded costs one uniform compare. `textured.frag` takes the same body: Normals uses the normal map when the maps view shows it.
- The app keeps `App.pass` and `App.pass_last`, plus `App.pass_peek: bool` (a hold on the chip or the key), and `viewport_pass(app)` gives what shows now (the peeked one while held).
  - `viewport_style`'s neighbour `viewport_pass_uniform(app)` fills `Draw_Item.pass` for every viewport draw, the boolean preview included.
  - `background_frame` returns paper for Silhouette and black for Depth.
  - `floor_grid_frame` is off in Silhouette.
  - `studio_running`, `render_running` and `live_ao_view_frame` read `viewport_pass`.
  - Capture, the thumbnail, the navigation head and object thumbnails keep Shaded.
- The chip is `kit_pass_chip` in a new `src/app/passes.odin`, drawn by `kit_top_bar` before History when the bar has room (`PASS_CHIP_ROOM`). It uses `ui.button` plus a hold check like the bar's long-press buttons. On a narrow window Search still finds every pass.
- Tests:
  - `View_Pass` names round-trip;
  - the layout text writes `pass` only when it is not Shaded;
  - peeking leaves the layout unchanged;
  - Alt+N for the current pass goes back to the last one.
- Touch scenarios:
  - a tap on the chip opens the popover and Normals there switches;
  - a long press on the chip peeks and lifting returns;
  - a dumped viewport in each pass is checked for its expected colours (Normals: a blue-ish centre pixel; Silhouette: a near-black centre on paper corners; Depth: a brighter centre than the edges of the sphere).

## Not in this PR
Wipe compare between two passes, per-pane passes (P0-5), Wire and Groups as passes (they stay toggles), and a Passes panel.

## After review (sm-architect)
- One `pass_shaded(app)` gate: live AO runs when `(on && Shaded) || AO` (`live_ao_wanted`, also in `viewport_shown`); the AO entry is disabled where live AO is unsupported, and the AO pass uses strength 1 when the setting is 0. The studio and render mode do not keep their samples across a pass: back on Shaded they start over (a peek costs a restart; keeping samples would need a pass-free scene key, not worth it in P0). `render_mode_frame`, `render_busy`, `viewport_shown` and the idle check all read the gate, so a paused studio never keeps the frame loop busy; the Studio status says "paused while a pass shows".
- Capture, the thumbnail window and the navigation head set `pass` back to Shaded on their copies of the draws. Screenshots of the viewport as shown keep the pass (deliberate: a Normals screenshot is useful). The scene preview is only taken while Shaded; otherwise the last one stays.
- Depth and Silhouette clear `environment_look.background` as capture does; `background_frame` stays as it is and the override sits beside it in `main.odin`.
- The pass lives in `Kit_State` (`k.pass`, `k.pass_last`, `k.pass_peek`), so `kit_layout_put` sets it (Shaded without a `pass` line) and ends a peek; the workspaces header comment says the pass is part of a layout. It survives a restart through the live layout, as the rest of the layout does.
- Peeking by key: backquote by scancode, intercepted as Space is (`main.odin` ~750), skipped while typing, cleared on focus loss, and reserved in `chord_reserved`. Peeking by hold on the chip: a new `ui.long_held(ctx)` that stays true while the long-pressed widget is still pressed (finger, pen and mouse).
- Arg names are the enum's: `View_Pass:Normals`.
- Curvature takes its bend from `in_view_normal` even under flat shading.
- Uniforms: `pass` at offset 880, block 896; the `Keyed` asserts move to 768/776; the shader reads `int(pass.x + 0.5)`. Depth's near/far are snapped to the scene radius, as live AO does, so a stroke keeps partial redraws. Every pass writes alpha through `opacity()`.
- A `--pass=<name>` flag sets the starting pass for dumps and smoke runs (README).
