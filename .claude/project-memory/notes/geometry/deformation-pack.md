# Gap list 14a: deformation sliders (design)

Goal: ZBrush's Deformation sub-palette, merged with Blender's mesh filters (Transform, To Sphere,
Shear, Randomize, Push/Pull) and Nomad's live filters. The Object palette's Deformation section
gains one slider per operation, with the mask respected and Repeat on the others.

## What the person sees (Object > Deformation)
- **Kind**: a list field. Offset, Rotate, Size, Skew, S bend, Squeeze, Noise, Inflate, Spherize,
  Gravity, Polish, Relax. Smooth stays as it is (Smooth all with its steps).
- **Axes**: X, Y and Z toggles, shown only for the kinds that use them. Offset, Rotate and Size can
  take several axes at once; Skew, S bend, Squeeze and Gravity take one.
- **Amount**: a drag slider that springs back to 0 on release, as Deformers' Amount does.
  - Closed-form kinds deform live while dragging. They run as a pose: begun on press, set again
    from the start positions each frame, and one undo step on release. That matches Nomad's live
    filters, and is better than ZBrush, which only shows the result on release.
  - Polish and Relax are neighbour iterations. They run once on release, with steps set by the
    amount, as ZBrush does.
- **More**: Repeat on the others, which applies the last deformation to every other shown object
  (each over its own free part), chained as one undo step. Smooth all's GPU, steps and strength
  options are also here.

## Maths
All of it is in the object's own space, over the free part's bounds (`sculptor_free_bounds`),
with centre c and size L (the largest extent). w is the vertex's shield (0 to 1). A is
amount / 100.

| Kind | What it does | Range |
|---|---|---|
| Offset | `a + w·A·L·axes` | ±100 % of the size |
| Rotate | Turns about c by the angle about each chosen axis, X then Y then Z; a half-free vertex turns w of the angle | ±180° |
| Size | Scales about c by `1 + w·A` on the chosen axes | −95 % to +200 % |
| Skew | Leans along axis i over the up axis j (X and Z lean over Y; Y leans over X): `a[i] += w·tan θ·(a[j] − c[j])` | ±60° |
| S bend | `a[i] += w·A·L/2·sin(2π t)`, where t runs 0 to 1 along j | ±100 % |
| Squeeze | Scales the two axes across i about c by `1 − w·A·sin(π t)`, where t runs along i; positive pinches the middle, negative bulges it; the factor is at least 0.05 | ±100 % |
| Noise | Along the start normal by `w·A·L·0.05·n(p)`, where n is value noise with 8 cells across L, hashed from position (deterministic, and the same in serial and parallel) | ±100 % |
| Inflate | Along the start normal by `w·A·L·0.1` | ±100 % |
| Spherize | Blends toward `c + normalize(a − c)·R` by w·A, where R is the mean of the half extents | 0 to 100 % |
| Gravity | Down the chosen axis by `w·A·L·0.5·(r/R)²`, where r is the distance from the axis line through c and R is the largest r; outer parts droop, like a soft drape | ±100 % |
| Polish | Taubin λ/μ steps (λ 0.5, μ −0.53) of the Smooth step: smooths without shrinking | 1 to 20 steps |
| Relax | The Smooth step with its normal component removed (tangential only): evens the spacing and keeps the shape | 1 to 20 steps |

Noise and Inflate need the start normals. The pose captures them on its first apply (nothing has
moved yet), in a `[]Vec3` kept beside the saved node positions and freed when the pose ends.

## Code
- `sculpt/deform.odin`: Deform_Kind gains the ten closed-form kinds, with `axes: bit_set[Axis]` and
  a plan per kind. `deform_at(p, a, n, w)` gets the start normal.
- `sculpt/pose.odin`: `Pose_State.normals`, filled on the first `.Deform` apply whose kind needs
  normals.
- `sculpt/smooth_all.odin`: `sculptor_polish` (Taubin) and `sculptor_relax` (tangential), reusing the
  weights and the stroke saving of `sculptor_smooth_all`, with a mode in `smooth_vertex`'s loop.
  CPU only.
- `app/deformation.odin` (new): the panel state, the drag (reusing `deform_drag_*` with a second
  panel, or generalised), Repeat on the others, and `kit_deformation`.
- Adjust last re-runs the last one. Scripts get `deformation KIND AMOUNT [axes]`.
- Not in HD or with dynamic topology, as Deformers.

## Tests
- Each kind on an icosphere:
  - amount 0 changes nothing;
  - a masked vertex stays put;
  - serial and parallel runs give the same bits;
  - Offset moves the bounds by A·L;
  - Size scales the extent;
  - Spherize at 100 % leaves every free vertex at radius R;
  - Polish keeps the volume within 1 % while Smooth shrinks it.
- An undo after a drag restores the bits.
- Touch scenario: a finger drag on Amount deforms, and one undo step.
