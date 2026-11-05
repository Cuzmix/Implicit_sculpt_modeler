# Physics PR 1: the cloth solver (built)

- `src/sculpt/cloth.odin` is the one solver. `Cloth_Settings` (region, stiffness, firmness, damping, gravity, keep_area, allow_shrink, allow_expand), `CLOTH_DEFAULTS` = the old behaviour.
- Modes: Drag, Push, Pinch, Pinch_Line, Inflate, Expand, Twist, Wind. Gravity mode retired: gravity is a setting of every mode. Invert flips each mode (Drag: gravity rises); the app no longer swaps Pinch/Expand.
- Regions: Local (old), Follows (re-gathered when the brush, start + offset, moves half a radius; kept vertices carry pos/prev/rest/base), Whole (all leaves, pin = 1 - shield).
- Symmetry: union region; per vertex `turn` (falloff-weighted blend of image turns) and `focus` (blended image centres); targets are worked in the brush's frame and turned by `turn`; Twist angle times det(turn) so it fades at a mirror plane.
- Bend links (far corner across each edge) only gathered when the stroke starts with firmness > 0.5; firmness 0..0.5 scales the old displacement-evening term, 0.5..1 fades in the links. Default cost = old cost.
- Substeps: pointer moved > one mean link -> up to 4 substeps with max(5/sub, 2) rounds each (small steps); forces * dt^2, damping^dt.
- Link building: one pass a chunk into chunk-local heap lists, prefix sum, one parallel copy.
- Timing, 4 threads, -o:speed, Drag 60 steps: icosphere 2.6M (37.6k simulated) step 3.0 -> 3.3 ms, setup 17 -> 25 ms; single thread at 655k equal (1.7-2.4 vs 1.95-2.0 ms).
- Hook for PR 2: targets per vertex are not in yet; PR 2 adds `target`/`weight` arrays applied in the Jacobi round.
- .strokes v31 adds [4]u8 region/keep/shrink/expand + [4]f32 stiffness/firmness/damping/gravity per brush; presets add cloth_* key=value words.
