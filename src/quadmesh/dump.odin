package quadmesh

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

// Params.dump: each stage of each island written to a folder as an OBJ file, for looking at
// a stage on its own (scripts/quadmesh_view.py draws a cover with its grid lines and folds;
// the app's --import shows the rest): island<i>_1_thin.obj (the island the isotropic remesh
// gets, its feature edges as lines), island<i>_2_isotropic.obj (the triangles the cover is
// solved on, feature edges as lines), island<i>_3_cover<k>.obj (cover k of the landing: the
// isotropic mesh with each corner's UV, the singular vertices as points, its scaling and
// cells in the header) and island<i>_4_quads.obj (the quads, the island's checks in the
// header), and island<i>_checks.txt (the checks line). A file that cannot be written is
// skipped: the dump is a looking aid and never fails a remesh.

@(private)
dump_thin :: proc(folder: string, island: int, before, after: Island) {
	if folder == "" do return
	b := dump_begin()
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "# quadmesh stage 1, thin: %d triangles in, %d out, %d feature edges", len(before.triangles), len(after.triangles), len(after.features))
	dump_mesh(&b, after.positions, after.triangles)
	for e in after.features do fmt.sbprintfln(&b, "l %d %d", e[0] + 1, e[1] + 1)
	dump_write(folder, island, "1_thin", b)
}

@(private)
dump_isotropic :: proc(folder: string, island: int, iso: Isotropic) {
	if folder == "" do return
	b := dump_begin()
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "# quadmesh stage 2, isotropic: %d triangles, mean edge %.6g", len(iso.triangles), iso.mean_edge)
	dump_mesh(&b, iso.positions, iso.triangles)
	if len(iso.corner_feature) == 3 * len(iso.triangles) {
		for t, f in iso.triangles do for k in 0 ..< 3 {
			a, c := t[k], t[(k + 1) % 3]
			if iso.corner_feature[3 * f + k] != 0 && a < c do fmt.sbprintfln(&b, "l %d %d", a + 1, c + 1)
		}
	}
	dump_write(folder, island, "2_isotropic", b)
}

@(private)
dump_cover :: proc(folder: string, island, pass: int, iso: Isotropic, cover: Cover, scaling, cells, wanted: f64) {
	if folder == "" do return
	b := dump_begin()
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "# quadmesh stage 3, cover %d: scaling %.9g, cells %.1f off the caps, wanted %.1f, %d singular vertices", pass + 1, scaling, cells, wanted, len(cover.singular))
	for p in iso.positions do fmt.sbprintfln(&b, "v %.9g %.9g %.9g", p.x, p.y, p.z)
	for t in cover.uvs do for k in 0 ..< 3 do fmt.sbprintfln(&b, "vt %.17g %.17g", t[k][0], t[k][1])
	for t, f in iso.triangles do fmt.sbprintfln(&b, "f %d/%d %d/%d %d/%d", t[0] + 1, 3 * f + 1, t[1] + 1, 3 * f + 2, t[2] + 1, 3 * f + 3)
	for s in cover.singular do fmt.sbprintfln(&b, "p %d", s + 1)
	dump_write(folder, island, fmt.tprintf("3_cover%d", pass + 1), b)
}

@(private)
dump_quads :: proc(folder: string, island: int, q: Quads, checks: Checks) {
	if folder == "" do return
	line := checks_line(checks)
	b := dump_begin()
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "# quadmesh stage 4, quads: %s", line)
	for p in q.positions do fmt.sbprintfln(&b, "v %.9g %.9g %.9g", p.x, p.y, p.z)
	for f in 0 ..< max(len(q.first) - 1, 0) {
		strings.write_string(&b, "f")
		for k in q.first[f] ..< q.first[f + 1] do fmt.sbprintf(&b, " %d", q.corners[k] + 1)
		strings.write_byte(&b, '\n')
	}
	dump_write(folder, island, "4_quads", b)
	c := dump_begin()
	defer strings.builder_destroy(&c)
	strings.write_string(&c, line)
	strings.write_byte(&c, '\n')
	dump_write(folder, island, "checks", c, ".txt")
}

@(private = "file")
dump_begin :: proc() -> strings.Builder {
	return strings.builder_make(runtime.heap_allocator())
}

@(private = "file")
dump_mesh :: proc(b: ^strings.Builder, positions: [][3]f64, triangles: [][3]u32) {
	for p in positions do fmt.sbprintfln(b, "v %.9g %.9g %.9g", p.x, p.y, p.z)
	for t in triangles do fmt.sbprintfln(b, "f %d %d %d", t[0] + 1, t[1] + 1, t[2] + 1)
}

@(private = "file")
dump_write :: proc(folder: string, island: int, name: string, b: strings.Builder, extension := ".obj") {
	path := fmt.tprintf("%s/island%d_%s%s", folder, island, name, extension)
	_ = os.write_entire_file(path, b.buf[:])
}
