# Starter scenes (UX roadmap phase 3, P18 second half): design

Base: odin-sculpt 6154cbd (PR #68). Sources: 11 blueprint ("New ▸ starter scenes: sphere, head, bust, body, hand, creature base, hard-surface block; our own meshes, licence-clean"), 07 finding 12, 08 IA ("App menu ▸ File ▸ New ▸ starter scenes"), 10 ("+ New ▸ starter scenes").

## What exists when done
- Five starter blockouts besides the sphere and the existing primitives: **Head**, **Bust**, **Figure**, **Hand**, **Creature**. Each is a fused, closed, manifold base mesh made in code from oriented ellipsoids (no files, no licences), voxel-merged into one surface and relaxed so the joins blend.
- **Scene tab > Add object** offers them in its shape list after the primitives; **Insert** offers them too (they are geom.Primitive values, so every place that lists shapes gets them, and the settings rows that store a shape by name keep reading).
- Added at a size of N vertices, a starter is built at about N / 4^k vertices (k as large as keeps the base at 10k or more, at most 3) and Loop-subdivided k times, so it arrives with subdivision levels, as ZBrush's base meshes do: step down for big changes of form, up for detail. (The cube/cylinder/cone/torus/sphere stay as they are.)
- **Menu > New scene**: a "NEW SCENE" block in the app menu with six buttons (Sphere, Head, Bust, Figure, Hand, Creature). It replaces the scene with that one object at the Scene tab's Add size, frames it and forgets the scene's file path (Ctrl+S then asks where), and clears the History, as opening a scene does.
  - Guard: when the scene has work to lose (any History step, or more than one object), the first tap arms that button (it turns red and reads "Discard scene?") and a second tap within 4 s goes ahead; anything else disarms it. The palette's rows run through the same command, so they need the second run too, and say so in a note.
- Registry: `.New_Scene` (arg: the geom.Primitive; only Sphere and the starters are offered in the menu, every shape is runnable), group File; palette words "new start starter base mesh template blockout".
- Applied as a new Scene_Command kind `.New` at the start of the next frame (as Add is), so nothing the interface holds outlives it.
- README: Interface/Scene tab, Menu, Insert; exit stat `starter_levels` is not needed (levels and vertices already print).

## Geometry (src/geom/starters.odin, about 150 lines)
- `Starter_Part :: struct {center: Vec3, axis: Vec3, radii: Vec3}`: a geodesic sphere (frequency 24 for big parts, 12 for small ones) scaled by radii and turned so its z goes along `axis`. Limbs are rows of spheres with a tapering radius (smooth tubes).
- One table per starter (`STARTER_PARTS[Primitive]`, empty for the old shapes), in a unit-ish box, facing +Z (front), up +Y, symmetric across X where the subject is (so X symmetry works on them).
  - Head: cranium, face, jaw, chin, nose, brow, two ears, neck stub.
  - Bust: the head moved up and smaller, neck, chest and shoulders, a cut base (flat ellipsoid).
  - Figure: head, neck, chest, belly, pelvis, upper and lower arms and legs, hands and feet as small ellipsoids (A-pose).
  - Hand: palm, four fingers in three segments, thumb in two, wrist stub.
  - Creature: a four-legged body: torso, head, snout, neck, four legs in two segments, tail in three.
- Build: concatenate the parts into one Mesh, `remesh_voxel` to the count (Merge keeps what is inside any part: a union), then `relax` a few Taubin passes (λ 0.5, μ −0.53, uniform weights, positions only, parallel over vertices with jobs, serial and parallel bit-identical since each pass reads one buffer and writes another), then centre on its bounds and scale into the unit sphere as the other primitives are. Normals zero, for the sculptor to compute.
- Tests (geom): every starter is closed, consistently wound and outward (mesh_check as primitives_are_closed_and_outward does), within 25% of the asked count, inside the unit sphere and reaching past 0.9; symmetric across X within 0.03 (all but the Hand); serial and parallel builds bit-identical.

## App
- `scene_add_primitive`: for a starter, the base count and k as above, then `sculpt.levels_subdivide` k times through the same path the Subdivide command takes (factored out of the Scene_Command .Subdivide case so both share the checks and the upload).
- `.New` in scene_apply: stroke_finish, leave HD, WaitForGPUIdle, free every object, history_clear, scene_path cleared, add the starter (or sphere) at {0}, select it, frame it (as Frame all), stats reset as scene_open does. A note: "New scene: Head, 4 levels, 1.0M vertices".
- Kit_State: `new_armed: int` (the shape + 1 that is armed, 0 none) and `new_armed_at: f64`.
- touch_check (desktop simulation): Menu > New scene > Head on an untouched scene replaces it at once (`objects=1`, a level count of k+1, `undo_steps=0`); after a stroke, one tap arms and changes nothing (`dabs` kept, `objects=1`, the old vertex count), a second tap replaces; Insert with Hand inserts a fused hand.
- Screenshots: each starter at 1600×900, Studio render off, front and three-quarter view; described in the PR.

## Cost
Building a starter: one voxel remesh at ≤ 40k-ish base vertices plus Loop subdivision of the levels; at 1M about the time Remesh + Subdivide take today (measured and reported in the PR: `remesh_ms`-style log line).

## Not in this step
File-based starter packs (content packs, 11 blueprint §8), hard-surface block (the cube is there), thumbnails in the menu, a Home screen.

## Size
About 400 lines with tests. One new Scene_Command kind (`.New`), no History format change (it clears as opening does), no GPU or file-format change; settings rows that store a Primitive by name read the new values.

## After the sm-architect review (applied)
- One minimum: `geom.STARTER_MIN_VERTICES` (15k); `starter_levels` picks k (at most 3) so the base stays at or above it.
- Thin parts: the fused pass runs at a third of the thinnest part's radius, the final remesh never coarser than half of it.
- `scene_replace` is shared by Open and New: the new object is built (`object_make_primitive`, outside the scene) before anything old is freed; ids keep growing; it stops replay, the timeline's play and scrub and a time-lapse; New clears the scene path.
- Starters added anywhere (Add object, New scene, `--shape`) come with their levels; Insert uses the plain starter mesh.
- The guard lives in `.New_Scene`'s run (`new_armed`, `NEW_SCENE_ARM_TIME` 4 s), with a warning note on arming; the arming tap keeps the menu open; `command_label` and `palette_arg_name` know the command; the palette lists only Sphere and the starters (the argument indexes `NEW_SCENE_SHAPES`).
- Normals are zeroed on return; the view of a new scene is the starting view.
