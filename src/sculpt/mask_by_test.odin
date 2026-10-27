package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
by_sphere :: proc(s: ^Sculptor, m: ^geom.Mesh, subdiv: int, pool: ^jobs.Pool) {
	m^ = geom.icosphere(subdiv)
	sculptor_init(s, m, pool, 64)
}

// The vertex of `s` nearest `p`.
@(private = "file")
nearest :: proc(s: ^Sculptor, p: Vec3) -> u32 {
	best, d := u32(0), max(f32)
	for q, v in s.mesh.positions {
		if e := linalg.length2(q - p); e < d do best, d = u32(v), e
	}
	return best
}

// A Draw dab raises a peak and a Crease dab cuts a valley: Peaks masks the peak and not
// the valley, Curvature both more than the smooth far side, Smoothness the far side more;
// each is one undo step.
@(test)
mask_by_peaks_curvature_and_smoothness :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	by_sphere(&s, &m, 4, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	TOP :: Vec3{0, 0, 1}
	VALLEY :: Vec3{1, 0, 0}
	_ = apply_dab(&s, {kind = .Draw, radius = 0.25, strength = 1}, TOP)
	_ = apply_dab(&s, {kind = .Crease, radius = 0.25, strength = 1}, VALLEY)
	sculptor_flush(&s)
	top, valley, far := nearest(&s, TOP * 1.05), nearest(&s, VALLEY * 0.97), nearest(&s, {0, 0, -1})
	o := MASK_BY_DEFAULT
	testing.expect(t, sculptor_mask_by(&s, .Peaks, o))
	testing.expectf(t, s.mask[top] > s.mask[far] && s.mask[valley] == 0, "peaks: top %d valley %d far %d", s.mask[top], s.mask[valley], s.mask[far])
	testing.expect(t, sculptor_undo(&s))
	for k in s.mask do testing.expect_value(t, k, 0)
	testing.expect(t, sculptor_mask_by(&s, .Curvature, o))
	testing.expectf(t, s.mask[top] > s.mask[far] && s.mask[valley] > s.mask[far], "curvature: top %d valley %d far %d", s.mask[top], s.mask[valley], s.mask[far])
	testing.expect(t, sculptor_mask_by(&s, .Smoothness, o))
	testing.expectf(t, s.mask[far] > s.mask[valley], "smoothness: valley %d far %d", s.mask[valley], s.mask[far])
}

// Depth masks the near side fully and the far side not at all; Facing away the other way.
@(test)
mask_by_depth_and_facing_away :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	by_sphere(&s, &m, 4, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	near, far := nearest(&s, {0, 0, 1}), nearest(&s, {0, 0, -1})
	o := MASK_BY_DEFAULT
	o.view = {eye = {0, 0, 5}, toward = {0, 0, 2}}
	testing.expect(t, sculptor_mask_by(&s, .Depth, o))
	testing.expect_value(t, s.mask[near], 255)
	testing.expect_value(t, s.mask[far], 0)
	o.view.parallel = true
	testing.expect(t, sculptor_mask_by(&s, .Facing_Away, o))
	testing.expect(t, s.mask[near] < 3 && s.mask[far] > 252, "facing away is off")
}

// The colour kinds read the polypaint: none at first, then a red dab masks by its hue and
// not a blue one's; a grey reference has no hue to go by.
@(test)
mask_by_color :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	by_sphere(&s, &m, 4, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	o := MASK_BY_DEFAULT
	o.hue = {220, 20, 20}
	testing.expect(t, !sculptor_mask_by(&s, .Color_Hue, o), "masked by colour with no paint")
	TOP :: Vec3{0, 0, 1}
	_ = apply_dab(&s, {kind = .Paint, radius = 0.3, strength = 1, color = {200, 10, 10}}, TOP)
	_ = apply_dab(&s, {kind = .Paint, radius = 0.3, strength = 1, color = {10, 10, 200}}, -TOP)
	red, blue := nearest(&s, TOP), nearest(&s, -TOP)
	testing.expect(t, sculptor_mask_by(&s, .Color_Hue, o))
	testing.expect_value(t, s.mask[red], 255)
	testing.expect_value(t, s.mask[blue], 0)
	testing.expect(t, sculptor_mask_by(&s, .Color_Saturation, o))
	testing.expect(t, s.mask[red] > 200 && s.mask[blue] > 200, "saturation misses the paint")
	o.hue = {128, 128, 128}
	testing.expect(t, !sculptor_mask_by(&s, .Color_Hue, o), "a grey reference masked")
}

// Creases mask a cube's edges and not its faces' middles; Open borders mask the edge of
// the shown part once half is hidden, and the hidden half keeps its mask through a blur.
@(test)
mask_by_features :: proc(t: ^testing.T) {
	m, ok := geom.primitive(.Cube, 5000, nil)
	testing.expect(t, ok)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	sculptor_recompute_all(&s)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	lo, hi := m.positions[0], m.positions[0]
	for p in m.positions do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	middle := nearest(&s, {(lo.x + hi.x) / 2, (lo.y + hi.y) / 2, hi.z})
	edge := nearest(&s, {(lo.x + hi.x) / 2, hi.y, hi.z})
	o := MASK_BY_DEFAULT
	testing.expect(t, sculptor_mask_by(&s, .Creases, o))
	testing.expect_value(t, s.mask[edge], 255)
	testing.expect_value(t, s.mask[middle], 0)
	testing.expect(t, !sculptor_mask_by(&s, .Group_Borders, o), "masked by groups with none")

	sm: geom.Mesh
	ss: Sculptor
	by_sphere(&ss, &sm, 4, nil)
	defer {sculptor_destroy(&ss); geom.mesh_destroy(&sm)}
	clip: matrix[4, 4]f32
	clip[0, 0], clip[1, 1], clip[2, 2], clip[3, 3] = 1, 1, 0.1, 1
	_ = sculptor_hide_shape(&ss, clip, {{0, -10}, {10, -10}, {10, 10}, {0, 10}}, .Hide)
	o.blur = 2
	testing.expect(t, sculptor_mask_by(&ss, .Open_Borders, o))
	border, inside := nearest(&ss, {0, 0, 1}), nearest(&ss, {-1, 0, 0})
	testing.expect(t, ss.mask[border] > 0, "the shown part's edge is not masked")
	testing.expect_value(t, ss.mask[inside], 0)
	for k, v in ss.mask do if vertex_hidden(&ss, u32(v)) do testing.expect_value(t, k, 0)
}

// Mask region fills the smaller side of a closed ring of mask, and with no closed outline
// changes nothing; Mask adjust reshapes the mask through its curve.
@(test)
mask_region_and_adjust :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	by_sphere(&s, &m, 5, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	mask_ensure(&s)
	for p, v in s.mesh.positions do if abs(p.z - 0.5) < 0.06 do s.mask[v] = 255
	testing.expect(t, sculptor_mask_command(&s, .Region))
	for p, v in s.mesh.positions {
		if p.z > 0.6 do testing.expectf(t, s.mask[v] == 255, "the cap at z %v is not filled", p.z)
		if p.z < 0.4 do testing.expectf(t, s.mask[v] == 0, "the far side at z %v was filled", p.z)
	}
	testing.expect(t, sculptor_undo(&s))
	// A gap in the ring leaves one unmasked part: nothing to fill.
	for p, v in s.mesh.positions do if p.x > 0.5 && abs(p.y) < 0.2 do s.mask[v] = 0
	testing.expect(t, !sculptor_mask_command(&s, .Region), "a ring with a gap was filled")

	slice.fill(s.mask, 128)
	// Above the diagonal: half masked comes out more than half.
	testing.expect(t, sculptor_mask_adjust(&s, {{0, 0.6}, {0.4, 1}}, 0))
	for k in s.mask do testing.expect(t, k > 128)
}

// Every kind, with a blur, gives the same mask bit for bit in parallel as on one thread.
@(test)
mask_by_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for by in Mask_By {
		result: [2][]u8
		for p, i in ([2]^jobs.Pool{nil, &pool}) {
			m: geom.Mesh
			s: Sculptor
			by_sphere(&s, &m, 5, p)
			_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1}, {0, 0, 1})
			_ = apply_dab(&s, {kind = .Paint, radius = 0.4, strength = 0.7, color = {200, 60, 10}}, {0, 0.6, 0.8})
			sculptor_flush(&s)
			_ = sculptor_group_command(&s, .Creases, 20)
			o := MASK_BY_DEFAULT
			o.blur = 2
			o.hue = {220, 40, 10}
			o.view = {eye = {1, 2, 5}, toward = {0.2, 0.4, 1}}
			_ = sculptor_mask_by(&s, by, o)
			result[i] = slice.clone(s.mask, context.temp_allocator)
			sculptor_destroy(&s)
			geom.mesh_destroy(&m)
		}
		testing.expectf(t, slice.equal(result[0], result[1]), "%v in parallel differs from serial", by)
	}
}
