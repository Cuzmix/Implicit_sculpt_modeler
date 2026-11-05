# 5a Samples: design note (2026-10-29)

Goal: ZBrush's Samples sub-palette for our brushes, a new Brush palette section "Samples" with three controls:
Stabilize orientation, Sample radius and Accumulate. Each makes a stroke behave the same on rough ground and over
itself, which is most of ZBrush's "it does what I meant" feel.

## Stabilize orientation (0 to 100%, default 0)
- Today each dab takes the area normal and plane centre (job_area) over the whole radius afresh, so on a rough
  surface Clay and Flatten wobble and Draw's direction follows every bump. ZBrush averages the stroke's normals;
  Blender's Plane brush keeps a rolling mean of the last normals and centres.
- An exponential mean over the stroke, in the stroke's own (first symmetry image's) space as Lock plane is:
  n_k = normalize(lerp(n_area, n_{k-1}, s)), c_k = lerp(c_area, c_{k-1}, s), s = the slider (at most 0.95), reset at
  each stroke begin. Lock plane stays as the end stop (s = 1: the first dab's for the whole stroke) and wins when on.
- `sculpt.Brush.stabilize: f32`, kept in `Sculptor.steady` (as `locked`), applied by the same path as
  lock_plane_apply for the kinds that read the area (brush_locks_plane's kinds, and Inflate is not one).

## Sample radius (25% to 100%, default 100%)
- The share of the radius job_area samples the normal and centre over (ZBrush's Sample Radius, Blender's
  normal_radius_factor 0.5). Smaller follows a narrow ridge's top; 100% is today's behaviour, kept as the default so
  nothing changes until asked. `sculpt.Brush.sample_radius`.

## Accumulate (per brush; Draw off, the rest on, as Nomad's Brush and Clay)
- Off: a stroke going over itself does not build up past what one pass lays: each vertex keeps the height the stroke
  has added to it so far (Layer's per-vertex Layer_Height, keyed by the stroke number, 8 bytes a vertex, made on first
  use) and a dab raises it to max(height, the dab's own height there) along the vertex normal, instead of adding.
  Nomad and SculptGL measure from the stroke's start positions; the height cap gives the same result for a push along
  the normal at no extra copy.
- For Draw and Inflate (the kinds that push along the normal; Layer never accumulates; the plane kinds Clay and
  Flatten converge on their plane anyway). Draw starts with it off: a Draw stroke scribbled over itself is one height,
  as ZBrush's and Nomad's.
- `Brush_Settings.accumulate: [Brush_Kind]bool` (per brush, as strengths), `sculpt.Brush.accumulate`.

## App
- New Brush palette section Samples (after Falloff): Stabilize orientation and Sample radius sliders, Accumulate
  switch (greyed where it does nothing, saying why).
- Settings `stabilize`, `sample_radius`, `accumulate <brush> 0|1`; presets as named values (`stabilize=`,
  `sample_radius=`, `accumulate=`); `.strokes` version 25. README and glossary.

## Tests
- Stabilize: Clay along a ridged strip: the normals the dabs used vary less with it (sculpt test on the normals
  returned through a test hook) and serial == parallel.
- Sample radius: on a ridge, a dab at 25% takes the ridge top's normal (dot with the ridge normal > that at 100%).
- Accumulate off: a Draw stroke that passes the same place three times raises it as one pass does (within 1%); on,
  about three times. Undo restores.
- Touch: a scribbled Draw stroke over itself, screenshot with Accumulate off and on.
