# R4: reference planes in the scene, a design for review

Reference images R1, R2, R3, R5a and R6 are merged (#651, #653, #655, #656, #659). R4 puts a picture on a plane in the 3D scene, as Blender's view-aligned reference images and ZBrush's image planes do. It adds a shader, and AGENTS.md asks for a design review before any shader, so this note comes first.

## What the person gets

- **Making a plane.** The References card's edit row gets **In scene**, a menu with Front, Back, Right, Left and Top. It puts the picked picture on a plane facing that view, through the middle of the scene's bounds, as tall as the selected object. One undo step.
- **When a plane shows.** It shows only while the camera looks along its axis, within 10°. That is Blender's "only axis aligned" choice and it is on by default, so a front photo never cuts through a three-quarter view.
  - Pressing a view key (1, 3, 7 and the others) or using the view gizmo's snap shows the matching planes at once.
- **Behind or Through.**
  - **Behind** (the default): the plane is depth-tested like any object, so the model hides it where the model is in front.
  - **Through**: the plane is drawn over the model at its opacity with no depth test. This is the silhouette check.
- **The Scene card** lists planes in a References folder row. Each plane has an eye (show), a lock, and its view's name. Tapping a row picks the plane's place on the board.
- **Moving a plane.** While the References card is open, a plane is moved and sized with the existing Move gizmo, as an object would be.
  - Its rotation stays fixed to its axis, so it never leaves its view.
  - Gizmo moves are undo steps of the References kind.
- **Line-up (R5b, after this).** A plane gets Brow and Chin marks to drag onto the photo. The plane then scales and moves so they meet the scene's Proportion guides, so front and side line up in two drags.

## Data

New `Ref` fields:
- `plane: Ref_Plane`: None, Front, Back, Right, Left or Top.
- `plane_at: [3]f32`: the world centre.
- `plane_h: f32`: world height. The width comes from the place's shape.
- `through: bool`.

The REFS chunk carries these fields and `SCENE_VERSION` goes up one. The same picture texture serves the board, the overlay and the plane, with no second copy.

## Rendering

**A new pipeline in `src/render`: `ref_plane.vert.slang` and `ref_plane.frag.slang`.** Each plane is one quad of four vertices built in the vertex stage from push constants:
- the plane's centre, right and up vectors scaled to its size;
- the four corner texture coordinates (`ref_corners`, so crop, flip and turn apply);
- the opacity;
- a grey flag, which uses the grey copy when one is made.

The fragment stage samples the picture with a linear sampler and mips, and writes premultiplied colour times opacity. The pass is unlit, so a photo keeps its own colours. There are two pipeline states: depth test on with depth write off (Behind), and depth test off (Through). Both use the viewport's sample count. The committed `.spv`, `.msl` and `.wgsl` files and the `shaders_gen` description come with it. Nothing is hand-written per backend.

**Where it draws.** In the viewport pass:
- Behind planes draw after the floor grid and before the mesh items. The mesh's depth then hides them, and the plane writes no depth, so it never hides the floor's grid lines behind it wrongly.
- Through planes draw after the mesh items and before the brush ring.

**Idle cache and partial redraw.**
- `frame_key` gains the planes shown: their ids, places, opacity and the texture id. A change redraws, and an unchanged scene still rests.
- A partial redraw re-clears its scissor and redraws every item clipped to it. Planes are drawn as items in that list, so a stroke's dirty rectangle repaints the plane behind it correctly.

**The rejected choice.** Reusing `p.textured` (the textured-mesh pipeline) with a two-triangle mesh needs no new shader. But it lights the photo with the material and the lights, and it needs a mesh object with UVs for each plane. I recommend the new unlit pipeline. It is about 60 lines of Slang and 150 of render code.

## Cost

One draw and four vertices per plane shown. At most two or three planes show in an axis view. That is under 0.05 ms on the 3060 Ti, to measure with `--gpubench` before and after with a plane shown. The sculpt passes, culling and the GPU sculpting path do not change. With no planes, nothing is bound or drawn.

## Size and order

About 700 lines in one PR:
- the Slang shaders and generated files;
- the render pipeline and drawing;
- the app data, card menu, Scene card rows and gizmo hookup;
- the file fields, tests and README;
- a parity check: no change with no planes.

R5b (the Brow and Chin line-up) follows in its own PR.

## Questions with defaults

1. Planes show only in their axis view, by default. *Default: yes.* You can turn it off per plane to keep a plane always shown.
2. Through draws over the model with no depth. *Default: yes.* The alternative is a see-through blend only where the model hides the plane.
