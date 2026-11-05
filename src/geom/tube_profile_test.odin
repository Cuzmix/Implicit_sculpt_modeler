package geom

import "core:math/linalg"
import "core:testing"

// Whether `o` is the same either side of x = 0, pair by pair.
@(private = "file")
mirrored :: proc(o: Tube_Outline) -> bool {
	for i in 0 ..< o.count {
		a, b := o.points[i], o.points[profile_partner(o, i)]
		if linalg.length(a.p - [2]f32{-b.p.x, b.p.y}) > 1e-5 do return false
	}
	return true
}

// Every preset is mirrored; its samples keep its corners and run counterclockwise.
@(test)
profile_presets_mirror_and_keep_corners :: proc(t: ^testing.T) {
	for kind in Tube_Profile {
		o := profile_preset(kind)
		testing.expectf(t, o.count >= 3 && mirrored(o), "%v is not mirrored", kind)
		ring := profile_sample(o, 16)
		testing.expectf(t, len(ring) >= 16, "%v: %d samples", kind, len(ring))
		area: f32
		for p, i in ring {
			q := ring[(i + 1) % len(ring)]
			area += p.x * q.y - q.x * p.y
		}
		testing.expectf(t, area > 0, "%v runs clockwise", kind)
		for q in o.points[:o.count] {
			found := false
			for r in ring do if linalg.length(r - q.p) < 1e-5 do found = true
			testing.expectf(t, found, "%v lost its point %v", kind, q.p)
		}
	}
}

// With Mirror, a point added on one side gets its partner on the other, a moved one moves
// its partner, and deleting takes both; a point on the line stays.
@(test)
profile_mirror_edits_pairs :: proc(t: ^testing.T) {
	o := profile_preset(.Square)
	n := o.count
	at := profile_insert(&o, 0.5)
	testing.expect(t, at >= 0, "nothing added")
	testing.expect_value(t, o.count, n + 2)
	testing.expect(t, mirrored(o), "an added pair is not mirrored")
	o.points[at].p += {0.1, 0.2}
	profile_mirror_from(&o, at)
	testing.expect(t, mirrored(o), "a moved point's partner did not follow")
	testing.expect(t, !profile_delete(&o, 0), "a point on the mirror line went")
	testing.expect(t, profile_delete(&o, at))
	testing.expect_value(t, o.count, n)
	testing.expect(t, mirrored(o), "deleting broke the mirror")
	o.mirror = false
	testing.expect(t, profile_delete(&o, 0))
	testing.expect_value(t, o.count, n - 1)
}
