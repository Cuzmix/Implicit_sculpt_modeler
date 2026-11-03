package sculpt

import "core:math/linalg"
import "core:testing"

import "../geom"
import "../jobs"

@(test)
cloth_volume_measures_a_sphere :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	v: Cloth_Volume
	testing.expect(t, cloth_volume_build(&v, m, nil))
	defer cloth_volume_destroy(&v)
	for dir in ([?]Vec3{{1, 0, 0}, {0, 1, 0}, linalg.normalize(Vec3{1, 1, 1}), linalg.normalize(Vec3{-1, 0.3, 0.5})}) {
		for r in ([?]f32{0.95, 1, 1.05}) {
			d, grad := cloth_volume_sample(&v, dir * r)
			testing.expectf(t, abs(d - (r - 1)) < 0.01, "at %v the distance is %v, not %v", dir * r, d, r - 1)
			testing.expectf(t, linalg.dot(grad, dir) > 0.9, "at %v the gradient is %v", dir * r, grad)
		}
	}
	// Far outside and deep inside, past the band, read as the band either way.
	d, _ := cloth_volume_sample(&v, {5, 0, 0})
	testing.expect_value(t, d, v.band)
	d, _ = cloth_volume_sample(&v, {0.1, 0, 0})
	testing.expect_value(t, d, -v.band)
}

// A sphere hanging under gravity over the whole mesh (pinned nowhere but by `mask`), with
// whatever `with` and `settings` say it collides with.
@(private = "file")
collide_run :: proc(pool: ^jobs.Pool, with: Cloth_Collisions, settings: Cloth_Settings, steps: int, mode := Cloth_Mode.Push) -> (m: geom.Mesh) {
	m = geom.icosphere(4)
	s: Sculptor
	sculptor_init(&s, &m, pool, 64)
	defer sculptor_destroy(&s)
	sculptor_stroke_begin(&s)
	_ = sculptor_cloth_begin(&s, {kind = .Cloth, radius = 0.6, strength = 0 if mode == .Push else 1}, {0, 0, 1}, mode, settings)
	sculptor_cloth_collide(&s, with)
	for _ in 0 ..< steps do _ = sculptor_cloth_step(&s, {}, {0, -1, 0})
	sculptor_cloth_end(&s)
	_ = sculptor_stroke_end(&s)
	return
}

@(test)
cloth_rests_on_the_floor_and_on_other_objects :: proc(t: ^testing.T) {
	set := CLOTH_DEFAULTS
	set.region, set.gravity, set.floor = .Whole, 1, true
	// Without collisions the whole sphere sags past y = -0.95; with the floor there,
	// nothing goes below it by more than a hair.
	free := collide_run(nil, {}, set, 60)
	defer geom.mesh_destroy(&free)
	low := f32(1e9)
	for p in free.positions do low = min(low, p.y)
	testing.expectf(t, low < -1.1, "gravity alone should sag the sphere below the floor and into the ball, lowest %v", low)
	held := collide_run(nil, {floor = true, floor_at = {0, -0.95, 0}, floor_up = {0, 1, 0}, gap = 0.001}, set, 60)
	defer geom.mesh_destroy(&held)
	low = 1e9
	for p in held.positions do low = min(low, p.y)
	testing.expectf(t, low > -0.951, "the floor should hold the cloth up, lowest %v", low)

	// Another object: a sphere of radius 0.5 just under it, as a volume.
	ball := geom.icosphere(4)
	defer geom.mesh_destroy(&ball)
	for &p in ball.positions do p = p * 0.5 + {0, -1.55, 0}
	v: Cloth_Volume
	testing.expect(t, cloth_volume_build(&v, ball, nil))
	defer cloth_volume_destroy(&v)
	with := Cloth_Collisions{gap = 0.001}
	append(&with.colliders, Cloth_Collider{volume = &v, to_volume = 1, scale = 1})
	defer delete(with.colliders)
	sat := collide_run(nil, with, set, 60)
	defer geom.mesh_destroy(&sat)
	inside := 0
	for p in sat.positions do if linalg.length(p - {0, -1.55, 0}) < 0.495 do inside += 1
	testing.expectf(t, inside == 0, "%d vertices went into the ball", inside)
}

@(test)
cloth_self_collision_keeps_folds_apart :: proc(t: ^testing.T) {
	// A hard pinch crushes the cloth into tight folds; self collision keeps them apart.
	nearest :: proc(m: geom.Mesh) -> f32 {
		near := f32(1e9)
		for p, i in m.positions {
			if p.z < 0.6 do continue
			for k in i + 1 ..< len(m.positions) {
				q := m.positions[k]
				if q.z < 0.6 do continue
				near = min(near, linalg.length(p - q))
			}
		}
		return near
	}
	set := CLOTH_DEFAULTS
	set.firmness = 0
	crushed := collide_run(nil, {}, set, 80, .Pinch)
	defer geom.mesh_destroy(&crushed)
	set.self_collide = true
	kept := collide_run(nil, {}, set, 80, .Pinch)
	defer geom.mesh_destroy(&kept)
	a, b := nearest(crushed), nearest(kept)
	testing.expectf(t, b > a, "self collision should keep vertices further apart: %v against %v", b, a)
}

@(test)
cloth_collisions_serial_and_parallel_agree :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	set := CLOTH_DEFAULTS
	set.region, set.gravity, set.self_collide = .Whole, 1, true
	with := Cloth_Collisions{floor = true, floor_at = {0, -0.95, 0}, floor_up = {0, 1, 0}}
	a := collide_run(nil, with, set, 20)
	defer geom.mesh_destroy(&a)
	b := collide_run(&pool, with, set, 20)
	defer geom.mesh_destroy(&b)
	for p, i in a.positions do if b.positions[i] != p {
		testing.expectf(t, false, "vertex %d differs", i)
		break
	}
}
