# Area lights, per-light shadows and highlights: design note (PR3+4)

## What exists when done

- A fourth light kind, **Area**: a rectangle (or a disc, Shape switch) with a width and height,
  shining from one face. Placed and aimed as a spot is (Place highlight, Aim at the selected
  object). Soft highlights and soft falloff, the look of a studio softbox.
- Per light: **Shadows** on or off (Studio's shadow rays and the path tracer skip a light with
  shadows off), and **Highlight** 0 to 2 (how much specular it gives, 1 as now; 0 makes a
  fill light that adds no shine).
- Export: USD `RectLight`/`DiskLight`; glTF has no area light, so it goes out as a spot with
  the same aim and a 90 degree cone; the Blender link sends an Area light with its size.
- Scene file: the new fields at the end of each light inside the `SCEN` chunk's lights; older
  apps step over them; older files read with Shadows on, Highlight 1, no area kind.

## GPU layout

`render.Lights` grows from 560 to 816 bytes: two more `[LIGHT_COUNT][4]f32`:
- `axis`: an area light's first edge direction (unit, view space) with its half width in w.
- `extra`: x highlight factor, y shadows (1 or 0), z an area's half height, w 1 for a disc.
The area's facing reuses `spot.xyz`. Every shader that declares the Lights block
(mesh_shading, render_trace, studio_weight, light_window, and `Shadow_Lights` in studio.odin)
takes the same two arrays at its end, so earlier offsets are unchanged; Material_Uniforms
offsets after Lights move by 256 bytes and their `#assert`s move with them.

## Shading

Raster (mesh_shading): an area light is shaded as a sphere light of the same solid angle for
diffuse (Karis's representative point toward the reflection ray, clamped into the rectangle),
which is what Unreal and Filament ship; specular uses the representative point with the
roughness widened by the solid angle (the energy fix the point lights' size already uses).
LTC (exact polygonal lights) is better but needs two 64x64 lookup textures and a new sampler
binding; I'd keep it for later if the cheap version looks wrong on a model.

Path tracer and Studio: sample a point on the rectangle or disc uniformly by area, with the
cosine at the light and the distance squared; shadow rays honour the Shadows switch.

## Cost

One more branch in the per-light loop; the representative point is about 20 ALU ops per area
light per pixel, only for lights of that kind. With no area lights the shader runs exactly as
now apart from reading `extra.x` for the highlight factor (one multiply). I'll measure
`--gpubench` and the 25M frame time before and after, with 0 and with 4 area lights.

## Tests

lights_test: CPU copies of the representative point (a pixel facing the light's middle gets
the full rectangle's solid angle; behind the light, nothing), the highlight factor scaling
specular only, the shadows bit reaching Shadow_Lights, the scene file round trip and an old
file reading the defaults. USD and glTF export checks (scripts/export_check.py). A dump of a
sphere lit by one area light beside one spot.
