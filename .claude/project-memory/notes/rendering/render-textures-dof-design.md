# Render mode: texture maps and depth of field (design, 2026-10-27, for architect review)

Stage 4 is complete: render mode (#188, #192, #193, #195) path traces the scene with denoising, sampling the
environment by its brightness, and half resolution on tablets. Two gaps remain against Blender's rendered view,
KeyShot and ZBrush BPR:

1. A textured object (a retopologized object with baked or loaded maps, shown through its UVs while
   View > Textures is on) renders in its flat material colour.
2. There is no depth of field.

There are two PRs, textures first.

## A. Texture maps in render mode

### What exists after it
An object that the viewport shows textured renders with the same maps:
- **Textured view:** the base colour map times the item's colour, ORM's roughness and metallic, and the normal map
  in the frame the bake solved for (MikkTSpace; the quad normals and tangents `textured_vertices` uses).
- **Normal map view:** the normal map over the material.
- **UV checker view:** the checker, without the fade (render mode anti-aliases by jitter).
- **Occlusion:** ORM's occlusion is not applied. The path finds occlusion itself; Cycles also ignores a glTF
  occlusion map.
- **Denoiser:** its albedo guide takes the textured colour, so the denoiser keeps the maps sharp. The guide already
  demodulates by albedo.

### Data
- **The traced mesh stays the same.** It remains the sculpt mesh. `object_textured` requires the base level, whose
  vertices are the quads' vertices.
- **Corner records.** What render mode needs on top is one record per corner of each source triangle, in source
  triangle order: 4 words.
  - uv: 2 × f32;
  - normal: `Normal_Packed`;
  - tangent: snorm 4×8, xyz plus the w sign.
  - That is 48 B a triangle: 9.6 MB for 100k quads.
- **Building the corners (app).** The app builds them when it builds the preview's vertices, in
  `texture_preview_frame`, on the same stamps (shape, layout).
  - Each triangle's quad is the quad holding all three of its vertices, found through each vertex's quads.
  - Each corner takes that quad corner's UV and the same normal and tangent frame that `quad_mesh_split_uvs` gives
    the split vertex.
  - They live on the CPU in `Texture_Preview` (owned, heap). `Draw_Item` gets `corners: []render.Corner`, nil when
    the item is not textured this frame.
- **Upload (render).** `path_scene_build` appends an item's corners to the Attributes buffer after the paint. It
  sets `Item.offs.z` to the word where they start and the flag `ITEM_TEXTURED` (8). This stays at 7 storage
  buffers; the limit is 8.
- **Maps.** At most `RENDER_TEXTURED_MAX :: 3` textured items bind their maps: 3 × 3 samplers after the current 3,
  12 of the 16. Missing maps bind the textured draw's defaults.
  - `Item.offs.w` holds the item's map slot plus the view mode.
  - A further textured object renders in its material colour, and the Render section says so in one sentence.
- **Size limit.** Corner words count toward the tablet's 256 MB limit.

### Kernel
- **Map lookups.** `map_sample(slot, kind, uv)` is a switch over constant-indexed samplers. Arrays of samplers with
  non-uniform indices need descriptor indexing, which Android does not promise. It samples level 0; the jitter
  averages the aliasing away.
- **On a hit** with `ITEM_TEXTURED`:
  - interpolate the corners by the hit's barycentrics;
  - normal and tangent as textured.frag does (unnormalised interpolation, bitangent from the cross product times w),
    then the normal map;
  - turned toward the eye as now;
  - then albedo, roughness and metallic from the maps.
- **Polypaint and polygroups:** they do not show on a textured object, as in the viewport (`object_textured`
  refuses polygroup colours; paint was baked into the base colour).

### Checks
- Render mode off: 0 px against base, and render mode on a scene without textured objects: 0 px.
- A baked head (`--bake`) in render mode at 64 spp against the viewport's textured view: the same colours under an
  even light. An image is needed.
- A test for the corner records of a 2 × 2 quad grid with a seam: each triangle's corners have its quad's UVs,
  whichever diagonal the mesh has.
- `--gpu-debug` clean; the full gate including touch.

## B. Depth of field

### What exists after it
- **Controls:** a new **Lens** section in the Scene palette, after Render:
  - **Depth of field** (switch, remembered);
  - **Blur** (0 to 1, remembered): the lens radius as a share of a tenth of the scene's radius, so it reads the same
    for any model size. Scenes have no physical scale, so f-stops would mean nothing.
  - **Pick focus** (a command; key and palette, as KeyShot's "pick focus point" and Blender's focus eyedropper): the
    next tap or click on the model sets the focus point.
  - **Focus on the pivot** (a command): goes back to the default.
- **Focus point:** by default the camera's pivot, what the view turns about, so framing something focuses it (as
  Nomad does). A picked point is a world point: orbiting keeps it in focus. It is kept for the session, not saved.
  New scene and Open clear it.
- **Viewport marker:** while Pick focus waits and while the Lens section is open, a small focus marker shows in the
  viewport at the focus point, the light-marker style.
- **Script:** `set render_dof on`, `set render_blur 0.5`, `render_focus X Y Z` (world), `render_focus pivot`.

### Kernel
- **Thin lens:** the pixel's ray as now (perspective or orthographic) meets the focal plane, the plane through the
  focus point facing the camera.
  - The origin moves to a point on a disc of the lens radius across the camera's right and up (concentric mapping,
    from the sample's own random numbers).
  - The ray aims at that focal point.
- **Sample 0** keeps the lens centre, so the guides are a pinhole's.

### Denoiser with depth of field (open question 1)
- **The problem:** pinhole guides disagree with blurred light where things are out of focus. The edge-stopping
  weights then keep the noisy blurred edges.
- **Proposal:** with depth of field on, the guides are the mean over the samples. They become ping-pong pairs, like
  `accum`:
  - each sample reads the old mean (2 more samplers: 14 of 16) and writes the new one;
  - this costs 2 more RGBA16F images (16 MB at 1080p, 4 MB at tablet half size);
  - off, nothing changes.

### Checks
- Depth of field off: 0 px.
- On, three spheres at different depths, focus picked on the middle one: the middle one sharp, the near and far
  ones blurred, and an image is needed. Deterministic on llvmpipe.
- Pick focus is tested with `--ui-events`: a tap on a sphere sets the focus to its surface.
- `touch_check` passes: a new section, a command and a viewport tap mode.

## Best of each tool
- **Blender (Cycles):**
  - focus object or distance and an F-stop;
  - its glTF importer ignores the occlusion map in the path tracer.
- **KeyShot:** pick a focus point by clicking the model.
- **Nomad:** depth of field focused on what the camera turns about.
- **ZBrush BPR:** depth of field as a post effect. Rejected here: it halos at edges.
- **Marmoset:** the denoiser's guides average over the lens. That is our open question 1.

## Open questions for the review
1. Averaged guides with depth of field: is the ping-pong right, or should the guides be accumulated in one
   read-write image (simultaneous read-write storage, `COMPUTE_STORAGE_SIMULTANEOUS_READ_WRITE`, which tablets may
   lack)?
2. Corners in the Attributes buffer (7 buffers) or their own buffer (8, at the limit)?
3. Three textured items with maps in render mode: enough? The alternative is an atlas copy of the maps when render
   mode starts, which has no limit but needs a copy pass and memory.
4. Should the focus point be saved in the `.sculpt` scene file (version bump) rather than kept for the session?

## Architect review applied (2026-10-27; overrides the design above)
- **Corners:**
  - Triangles are matched to quad halves in the triangle's own index order. Each quad half from
    `quad_halves(q, k)` (with `across`) is found among the triangles round its first vertex (`sculptor.faces`) as a
    cyclic rotation.
  - This is done by `geom.quad_mesh_triangle_corners`. On a miss the item renders untextured, with a warning.
  - Tests in geom cover both diagonals and reversed winding.
- **GPU data:**
  - No CPU corners on `Draw_Item`. `Textured_Mesh` gains a `corners` buffer: 3 × u32 per base triangle, slots
    into its `vertices`, uploaded on the same stamp.
  - `path_scene_build` gpu-copies the `Textured_Vertex` array and the corners into an eighth storage buffer of
    their own. Attributes stays clear of Android's 128 MB a buffer.
  - The kernel reads the same i16 tangent and packed normal as the viewport.
- **Item record:** `Item_Record` gains `tex: [4]u32`:
  - x: the item's first triangle;
  - y: its corner base;
  - z: its textured-vertex base;
  - w: map slot | view << 4 | present-map bits << 8.
  - A missing ORM or normal map is flagged, never read from a default.
- **Textured items** clear paint, group and slot flags and copy no paint.
- **Kernel:**
  - `textureLod` with v flipped.
  - The front or back side is chosen from the geometric normal, flipping N, T and the mapped normal together.
  - A UV-space checker with fixed lines.
  - The bounce-0 lookup's mip comes from a ray cone (pixel spread × t over the triangle's UV density); later
    bounces use a coarse level.
  - Map slots are assigned in item order, at most 3.
- **Thin lens:** the eye frame comes from the uniforms (eye, right, up, forward, lens radius, focal distance D).
  - Rays are re-aimed from the eye plane and moved back to the original origin's plane, so this works for
    orthographic too.
  - D ≤ 0 turns depth of field off.
  - The lens numbers are drawn only when depth of field is on, after the jitter. When it is on, sample 0 samples
    the lens too.
- **Restart:** `render_frame` takes a `Lens` value and restarts when it changes, as with bounces and softness.
- **No halo:** with depth of field on, render mode lays itself over a background-only image (the clear pass, once a
  still view), never over the rasterized clay.
- **Guides with depth of field:**
  - running means over the samples that hit, ping-pong like `accum`;
  - atrous normalizes the mean normals;
  - atrous and display bind the current pair.
- **Pick focus:**
  - an armed flag and `focus_pick_frame` after `eyedropper_frame`'s pattern, using `scene_raycast_surface`;
  - the focus is session render state, cleared in `scene_replace`, not saved;
  - the pivot is `camera.target`;
  - the marker is drawn in the Overlay;
  - `Kit_Section.Lens`.
- **Size limits:** the textured buffers count toward `RENDER_SCENE_MAX` and `TRACE_BUFFER_MAX`.
