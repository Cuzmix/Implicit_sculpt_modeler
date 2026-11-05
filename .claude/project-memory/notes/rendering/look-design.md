# Sculpt studio look: design (2026-10-27, for architect review)

## Request
Bolt wants the default viewport to look like his five references of stylized grey sculpts. They show a soft grey surface, a key light from the upper front left, deep shade on the underside, soft cast shadows (hair onto the face, jaw onto the neck), crease occlusion, a light rim at silhouettes and a flat dark grey background. He also wants settings for how harsh the light and shadow are. Test model: `/mnt/project-files/Female expression6.obj` (3.8M triangles; the 500k retopologized copy is used for quick shots).

This is not a new renderer. It is a preset over what exists: classic shading, lights, cavity, live occlusion and the traced studio render. It adds two shading terms, an automatic studio render, and one panel section. The painted parts of the references (eyes, lashes) are polypaint's job.

## Measured
- **References** (grey levels): lit face 175-200, shaded neck 55-100, under the hair 2-30, background 43 (one is 142).
- **Today's default on the head:** lit 220 and shaded side 139+. It is too flat, warm (Clay), lifted by the fill and a gradient background, and has no cast shadows.
- **Prototype**, existing knobs plus two hard-coded shader terms:
  - Settings: grey 0.55, ambient 0.12, specular 0.10 at power 14, wrap 0.3. Key (-0.6, 0.65, 0.45) at 1.0, fill 0.06, rim light at 0.5. Background flat 0.165, cavity 0.7, ridge 0.3, live occlusion on.
  - Result: lit 190 and shaded side 120. With the traced studio render on, the jaw's shadow drops the neck to 57-70, which matches the references.
  - The cast shadows are what make the look, and only the studio render has them.

## Design
1. **Shading terms** (`mesh_shading.glsl`, classic path; the PBR path takes the ground term on its studio ambient only).
   - New `vec4 style` appended to `Material_Uniforms`:
     - x: rim strength.
     - y: ground, how much of the ambient light reaches surfaces facing straight down (1 is even, as today).
     - z: unused.
     - w: 1 to use x and y.
   - Draw_Item gets `style: [4]f32`, hashed into both frame keys like `look`. Zero keeps today's look bit for bit: rim 0.25 and an even ambient. Thumbnails, the navigation head and every existing path pass zero and are unchanged.
   - Ambient becomes `ambient * mix(ground, 1, 0.5 + 0.5 * dot(n, rig_up))`, with the rig's up axis taken from `light_y`, so it turns with the light rig.
   - Rim becomes `pow(1 - n.v, 4) * rim * mix(0.3, 1, sky)`, so the rim is mostly on the upper silhouettes, as in the references.
2. **Material preset "Studio grey"**, new first entry of MATERIALS (classic): selected and idle grey (0.55 and 0.42), shading {0.12, 0.10, 14, 0.3}.
   - It becomes the default material for new objects. FIRST_PBR and FIRST_MATCAP shift by one.
   - Materials are stored per object by label in scene files, so old scenes keep theirs.
   - `material_by_name("clay")` still finds Clay.
3. **Look preset** (new `src/app/look.odin`): `Look_Preset :: enum {Sculpt_Studio, Classic}` and `look_apply(app, preset)`. Applying a preset writes:
   - The material default, cavity and ridge.
   - The background (flat dark grey, or today's gradient).
   - `app.lights`, through Light_Set's existing fields only (agreed with the ZBrush layout thread):
     - Sculpt studio: key, fill 0.06, rim light on at 0.5 and ambient 1.
     - Classic: LIGHTS_DEFAULT.
   - The style terms: Sculpt studio rim 0.35, ground 0.15; Classic zero.
   - Live occlusion on, and studio-when-still on.

   It is one action ("Look: Sculpt studio" in the palette), not an undo step, like picking a material. Fresh installs start in Sculpt studio: the starting lights come from the preset (the one-line change in `lights_reset`/`LIGHTS_DEFAULT` the lights thread agreed to; `lights_test` and README follow).
4. **Studio when still.**
   - A remembered setting `studio_still` (default on) turns the studio render on whenever nothing has changed for one frame. It is the existing studio, which already shows the plain viewport while things change and builds up when still, so this is mostly making `studio_on` default on and remembered.
   - **Fix needed:** while the studio restarts, the viewport must show live occlusion, not the bare viewport. Today `live_ao_view_frame` is skipped whenever `studio_on`, so sculpting with the studio on loses all occlusion. The change: live AO runs on any frame the studio copies through (changed, or zero samples), the studio's copy-through takes live AO's image when there is one, and `viewport_shown` prefers studio only once it has samples.
   - Samples for the automatic run: the existing Samples slider (default 256). Idle rest (#173) already counts studio samples as activity, so the GPU rests once it converges.
5. **Shadow softness.** `STUDIO_KEY_SOFTNESS` (0.06 rad) becomes a parameter of `studio_frame`, set from a new remembered slider "Shadow softness" (0.02-0.4 rad). It defaults to 0.15 in Sculpt studio, since the references have soft shadow edges.
6. **Panel.** A "Look" section on the Scene palette, above Studio render:
   - Preset tabs: Sculpt studio | Classic.
   - Light: the key's Intensity.
   - Fill: `light_ambient`.
   - Softness: the current material's wrap, written as Custom like the Material sliders do.
   - Shadow: `studio_shadow`.
   - Shadow softness.
   - Occlusion: `studio_ao`.
   - Rim, and Underside (ground).
   - Background: brightness of the flat colour.

   Each is an existing field except rim, ground and shadow softness, which are new remembered settings. The ui keeps no state. Commands: `Look_Preset` with choices, plus palette words "look", "matcap", "shading", "style".

## Not changed
- Matcaps (they carry their own light) and PBR materials (they get the ground term only).
- The scene file: lights, as today, and per-object materials. There is no SCENE_VERSION bump, because style and softness are view settings, not scene data.
- Partial redraw: style is in the frame keys, so a change is a full redraw.

## Checks
- Classic preset: a 0-px diff against the base with the same lights, material and background. This shows zero style is bit-identical.
- Before/after shots of the head (retop and full) at the same camera, described and sent to Bolt, plus measured grey levels against the references.
- Live occlusion shows while sculpting with the studio on (bench stroke frames).
- Partial redraw equals `--no-partial` with the new look. gpu-debug smoke runs. The gate runs with touch (new panel controls).
- Cost: style adds about 6 ALU ops a pixel. The automatic studio costs nothing while working (it is the existing copy), and converges in about 4 s at 60 fps at 256 samples.

## Open questions (defaults taken)
1. Should Clay stay the default for existing users whose settings already chose a material? Default: a saved setting wins, so the new look reaches fresh installs and anyone who picks it.
2. Should the automatic studio be on for tablets too? Default: on. It runs only while still, rests when converged, and its traces are bounded by the 128 MB cap.

## Architect review applied (2026-10-27; overrides the above)
- Shader: new terms only under `style.w > 0.5`, existing lines verbatim otherwise (classic ambient and rim, PBR studio
  ambient). `style` appended after env_sh (Material_Uniforms 880 B), added to both Keyed structs.
- Live AO under the studio: drop `|| studio_on` from live_ao_view_frame; viewport_shown shows the studio only from
  STUDIO_SHOW_MIN (16) samples, live AO before that. No change to studio_frame's copy-through.
- Shadow softness: a studio_frame parameter; changing it resets the studio.
- `studio_still` is its own remembered setting; a device failure lives in Studio.failed only, never saved as "off".
  New settings are initialised before settings_load.
- Code defaults stay Classic (Clay, LIGHTS_DEFAULT, gradient, studio off), so scripted runs, smoke, touch and benches
  are unchanged. Sculpt studio is applied once when the settings file lacks the `look` key (a fresh install, or a file
  from before this change: Bolt asked for it as his default), never under --no-settings. LIGHTS_STUDIO in look.odin;
  lights.odin untouched.
- Studio grey is appended after Skin (FIRST_PBR 6, FIRST_MATCAP 14), picked by name; index 0 stays Clay.
- rebuild.odin's density preview must show with the studio on (it restarts the studio via the frame key).
- Partial vs --no-partial checked with the studio off (the studio never samples under --no-partial).
- PRs: (A) render style terms + softness + live AO under studio + rebuild fix; (B) preset, look.odin, Look section,
  first-run apply, README.
