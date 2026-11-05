# Lens P1-8: wipe compare and proportion guides

Spec: Lens report P1 item 8 ("Wipe compare and proportion guides: both cheap; strong for likeness and symmetry checks"), the mock's notes: "Wipe compare inside one pane: drag the handle to sweep Studio against Normals. Both are cheap passes, so one draw can pick per pixel by screen position" and "Proportion guides: dashed lines at the same model heights across both ortho panes (brow, nose base, chin). Drag one to move it in every ortho pane", and the mock's look (wipe: a 2 px light line with a 28 px round knob holding the split icon, the two passes' names in the top corners; guides: 1 px dashed amber lines with a small label at the right end).

Two PRs: 8a wipe (touches the mesh shaders and the material uniforms, so it is reviewed first), 8b guides.

## 8a Wipe compare
- **Command `View_Wipe`** (toggle; Shading menu's Pass row and the pass chip's popover gain "Wipe compare"; key W if free, else none; Search "wipe compare split"). Scripts `view_wipe`.
- While on, the main view shows the **current pass left of a vertical line and the other pass right of it**. The other pass is the pass chip's last other pass (as a peek uses), Normals when there is none; picking a pass in the popover while wiping sets the left side, as now, and the right side stays.
- **The handle**: a 2 pt line in `Theme.text` across the main pane with a 28 pt round knob in its middle (hit area 48 pt) holding Lucide's square-split-horizontal; a drag on the knob or anywhere on a 16 pt strip along the line moves it, kept within 5%..95% of the pane. Labels with each side's pass name sit in the pane's top corners, clear of the top bar and the brush bar. A press on the handle is the interface's (it is a ui root), never a stroke or an orbit.
- **One draw**: `Material_Uniforms` gains `vec4 wipe` after `pass`: x the right side's pass (render.View_Pass), y the line's x in target pixels, z 1 while on. `mesh_shading.glsl`'s pass branch first picks `view_pass = (wipe.z > 0.5 && gl_FragCoord.x >= wipe.y) ? int(wipe.x + 0.5) : int(pass.x + 0.5)`; nothing else in the shader changes. `textured.frag` takes the same. Block 896 -> 912; asserts move.
- `Draw_Item.wipe: [4]f32` joins both per-item `Keyed` tuples, so the idle cache and partial redraw see a move of the line (a moved line redraws everything, as a change of pass does).
- **What stays the left pass's**: the background (paper for Silhouette, black for Depth) and the floor follow the left pass; live AO runs when either side is AO or Shaded with AO on (the AO pass on the right needs the buffer); the traced studio and render mode pause while wiping, as for any pass other than Shaded (`pass_shaded` false while on). Depth's near/far are shared.
- Never part of a layout, never saved, never an undo step; a workspace switch or Single->grid keeps it (the main view is still the main view). View panes do not wipe (later).
- Exit stats: `wipe= wipe_at= wipe_right= wipe_drags=`.
- Tests: the uniform layout asserts; `wipe_uniform` (off: z 0; on: y = origin-free pane pixels × fraction); touch: View_Wipe on, a drag on the knob moves `wipe_at`, nothing sculpted; a dumped viewport with Shaded | Normals shows clay left of the line and a blue normal colour right of it (pixel checks either side).

## 8b Proportion guides
- **Command `View_Guides`** (toggle; Camera menu row "Proportion guides"; Search "guides proportion lines heights"). Scripts `view_guides`.
- **Three guides**: Brow, Nose base, Chin, horizontal planes at world heights, seeded the first time they are shown in a scene from the visible objects' bounds by the classic face thirds (Chin at the bottom, Nose base a third up, Brow two thirds up).
- **Drawn in every side-on orthographic view**: the main view when the camera is orthographic and level (pitch and roll within 0.5°), and each view pane looking from Front, Back, Left or Right: a dashed 1 pt line in `Theme.warning` (amber) across the pane at the guide's height, its name at the right end. Top, Bottom, Free, Linked and Mirrored (perspective or tilted) show none.
- **Dragging a guide** (a 16 pt strip along its line, in any pane that shows it) moves its height in every pane at once; the pane's projection turns the pointer's y into a world height. A double tap on a guide's label puts all three back to the seeded heights.
- **Saved in the scene** (they belong to the model): scene version 24 stores on/off and the three heights; older files read as off with no heights (seeded when first shown).
- Not an undo step (it never changes the model), as the camera is not.
- Exit stats: `guides= guide_heights= guide_drags=`.
- Tests: seeding from bounds; world-height to pane-y and back for an orthographic view; scene v24 round trip and v23 reading as off; touch: Four with Front/Right/Top shows guides in Front and Right only (a dashed amber pixel row in both at the same height, none in Top), a drag moves the height in both.

## After review (sm-architect)
- Wipe packs into the unused `pass.w` (0 off, else `1 + right_pass + 8 * line_px`), so every path that resets `pass` (view panes, thumbnail, nav head, the final `pass_items(.Shaded)`) drops it, the block stays 896 and the keys already hash it. `pass_items` takes an optional wipe and computes near/far when either side is Depth.
- The line is a fraction of the main pane; its pixel x is `round(fraction * target width)` (the target keeps its size, stretched, during a divider drag).
- Live AO blurs over the whole image: the line and which side gets AO go into `Blur_Uniforms.params.zw` (unused), so a Normals | AO wipe darkens only the AO side.
- A wipe drag counts as the view moving (LOD) while it moves; with the line still, strokes keep partial redraws.
- Off while recording; a peek is ignored while wiping. No key (W is Move).
- Guides: scene v24 after `print_scale`: a flags byte (shown, seeded; refuse > 3) and three finite heights; reset in the new-scene path. Not a Scene_Command; `view_edits` bumped on toggle and drag release only. Pure `camera.orbit_level_height(c, y_frac)` and inverse; "level" from the view matrix, applied to each pane's orbit (Linked/Mirrored of a level ortho main view show them too). Pictures remember the orbit they were drawn with; guides draw and drag through it. Seed once when turned on (selection's bounds, else visible, else a unit box). "Reset guides" command instead of a double tap. The thumbnail window shows them too.
