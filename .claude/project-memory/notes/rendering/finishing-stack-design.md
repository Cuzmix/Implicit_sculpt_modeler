# Stage 1: the finishing stack (design)

Stage 1 of "One Render" (https://claude.ai/artifact/PPSMxjSsYTUZfkVnufnTdL). Bolt approved the plan 2026-10-28
("yes to all start"). Two PRs. Everything is GLSL (the Vulkan/Slang thread ports it), lives in `src/render`, adds passes
and targets only (no change to pipeline creation or to `Viewport_Target`), and lands after the GPU-boundary PR.

## What exists when done
While the Render switch is on (Preview or Full), the viewport shows a finished image, as a camera would: a tone curve
(Neutral, AgX or ACES), white balance, contrast and saturation, lift/gamma/gain, vignette, film grain (1a), then bloom,
sharpen and chromatic aberration (1b). They sit under Render > Finish, are remembered settings with script `set` keys,
and show in the panel, screenshots, the time-lapse, turntables and scene previews (all read `viewport_shown`). With
every control at its neutral value (the default) the pass does not run, so today's images stay bit-identical.

## Sources: what we take, what we avoid, what we do better
| From | Take | Avoid | Better |
|---|---|---|---|
| Marmoset Toolbag (Camera > Post) | every effect on the camera, live in the viewport, one place | sharpen as plain unsharp mask (halos) | AMD CAS (MIT), contrast-adaptive, no halos |
| Blender (Color management, EEVEE Next) | AgX as the filmic curve; white balance (4.3); looks as contrast and saturation | EEVEE Next moved bloom out of the viewport into the compositor | bloom stays live in the viewport |
| Unreal 5 | physical order: CA, bloom, vignette, white balance, contrast, saturation in linear light before the curve; energy-conserving bloom (lerp) | ACES as the default (hue skews: bright blues go purple, reds orange) | Neutral stays default; ACES offered, AgX recommended for filmic |
| Unity HDRP / CoD AW (Jimenez 2014) | dual-filter bloom chain: 13-tap downsample with Karis average on the first level, 3x3 tent upsample; threshold 0 by default | single Gaussian with a hard threshold (EEVEE Legacy: flicker, pops) | soft-knee threshold only under More, off by default |
| Resolve, film | grain strongest in midtones, lift/gamma/gain in display space | flat white noise (digital look, greys the blacks) | grain fixed per pixel: deterministic, and a still view stays still |

## Where it runs
- New `render/finish.odin` with `Finish` (pipelines, an RGBA8 `shown` target, the bloom chain, a key) and
  `finish_frame(r, f, cmd, vt, source, linear, settings) -> bool`, `finish_texture`, `finish_destroy`.
- App: `finish_view_frame` runs after `live_ao_view_frame` (main.odin), on what `viewport_shown` would show, only
  while the Render switch is on and the pass is Shaded and the main view is not lent to a pane. `viewport_shown`
  returns finish's output when it ran, so every consumer gets it without change. A key (source texture, its
  sample count or frame key, settings, size) skips the pass when nothing changed, so a still view costs nothing.
- Input: the sources are RGBA8 display values made with PBR Neutral. The pass turns them back into exposed linear
  light with Neutral's exact inverse (it is invertible piecewise: the toe, the shoulder and the desaturation), then
  applies the chain. Full render has true linear radiance, so there `path_display` writes exposed linear light into
  an RGBA16F target instead (render_display.frag compiled a second time with LINEAR_OUT) and the pass reads that:
  exact curves and bloom on the final render. When the Vulkan backend gives the viewport an HDR scene target
  (stage 3/4 need one anyway), only the decode function changes.
- Order in finish.frag: CA (radial, five spectral taps) -> bloom mix -> vignette -> white balance (von Kries in LMS,
  kelvin from the lights' Planckian code) -> contrast (log2 about 0.18) -> saturation (Rec.709 luminance) -> curve ->
  lift/gamma/gain -> sRGB encode -> grain -> the 4x4 ordered dither clear.frag uses. Sharpen (1b) is a second pass
  after the curve, as CAS expects, and takes the grain and dither when it runs. Alpha passes through unchanged.
- Curves: Neutral (display.glsl's); AgX from Blender's definition (inset matrix, log2 over -12.47..4.03 EV, the
  base sigmoid as a polynomial fit, outset); ACES as Hill's fit of the RRT+ODT (MIT). No copied code, nothing neural.
- Bloom (1b): from linear light at half size, down to about 16 px (at most 6 levels), R11G11B10_UFLOAT where the
  device has it, else RGBA16F. Controls: Bloom (strength), Size (levels used), Threshold under More.

## Controls (Render > Finish, after the quality's own)
Tone curve tabs [Neutral, AgX, ACES]; sliders Contrast, Saturation, Temperature, Vignette, Grain (1a), Bloom,
Sharpen, Aberration (1b); More: Tint, Lift, Gamma, Gain, Vignette softness, Grain size, Bloom size, Bloom threshold;
command "Reset finish". Settings and script keys `finish_curve`, `finish_contrast`, ... (remembered, as exposure is;
no scene version change). Exit stats `finish=on|off finish_curve=...`.

## Cost
One full-screen pass (two with sharpen) plus the bloom chain at half size: about 0.1-0.3 ms on a desktop GPU at
1440p, about 1-2 ms on a tablet at 2.5K (estimate; gpubench gains a row with finishing on). Nothing runs when off or
still.

## Checks
- Off: 0 px against base in four scenes. Forced on with every control neutral: within one 8-bit step of off (proves
  the inverse), both through a script setting a near-zero value.
- CPU mirrors of the curves and the inverse in finish.odin with tests (round trip, monotonic, white and black
  points); images of each effect described; touch scenario for the section; full gate.
