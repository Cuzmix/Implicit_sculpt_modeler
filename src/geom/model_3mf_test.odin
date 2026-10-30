package geom

import "core:strings"
import "core:testing"

import "../jobs"

// Each part is its own object of its vertices and triangles, every one placed by the
// build, its name escaped; the same parts make the same bytes with workers or without.
@(test)
model_3mf_holds_each_part :: proc(t: ^testing.T) {
	a := icosphere(1)
	defer mesh_destroy(&a)
	b := icosphere(2)
	defer mesh_destroy(&b)
	parts := []Model_Part{{"Head & <ears>", a.positions[:], a.indices[:]}, {"Base", b.positions[:], b.indices[:]}}
	out := make([dynamic]u8)
	defer delete(out)
	mesh_write_3mf_model(&out, parts)
	xml := string(out[:])
	testing.expect_value(t, strings.count(xml, "<object "), 2)
	testing.expect_value(t, strings.count(xml, "<item objectid="), 2)
	testing.expect_value(t, strings.count(xml, "<vertex "), len(a.positions) + len(b.positions))
	testing.expect_value(t, strings.count(xml, "<triangle "), (len(a.indices) + len(b.indices)) / 3)
	testing.expect(t, strings.contains(xml, `name="Head &amp; &lt;ears&gt;"`), "the name was not escaped")
	testing.expect(t, strings.contains(xml, `unit="millimeter"`))
	testing.expect(t, strings.has_suffix(xml, "</model>\n"))

	// A part bigger than a range, written serially and on workers.
	big := icosphere(7)
	defer mesh_destroy(&big)
	one := []Model_Part{{"Big", big.positions[:], big.indices[:]}}
	serial, parallel := make([dynamic]u8), make([dynamic]u8)
	defer delete(serial)
	defer delete(parallel)
	mesh_write_3mf_model(&serial, one)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	mesh_write_3mf_model(&parallel, one, &pool)
	testing.expect(t, string(serial[:]) == string(parallel[:]), "the workers wrote other bytes")
	free_all(context.temp_allocator)
}
