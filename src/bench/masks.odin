package bench

import "core:fmt"
import "core:slice"
import "core:time"

import "../geom"
import "../jobs"
import "../sculpt"

// --masks: at each size, every mask command on a sphere whose left half is masked,
// each undone before the next so they all start from the same mask. Clear and Invert
// are one pass over every vertex; the neighbourhood commands check every node once,
// then each step works only on the nodes around the mask's edge. Changed is how many
// vertices the command changed, flush ms the frame's upload preparation after it.
masks_header :: proc() {
	fmt.println("| Vertices | Command | Steps | Changed | Command ms | Flush ms | Undo MB | Undo ms |")
	fmt.println("| --- | --- | --- | --- | --- | --- | --- | --- |")
}

run_masks :: proc(target: int, pool: ^jobs.Pool) {
	sp := new(Sphere)
	defer free(sp)
	sp.mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(target), pool)
	defer geom.mesh_destroy(&sp.mesh)
	sculpt.sculptor_init(&sp.sculptor, &sp.mesh, pool, node_triangles)
	defer sculpt.sculptor_destroy(&sp.sculptor)
	free_all(context.temp_allocator)
	s := &sp.sculptor
	_ = sculpt.sculptor_mask_command(s, .Fill)
	for p, v in sp.mesh.positions do if p.x > 0 do s.mask[v] = 0
	sculpt.sculptor_clear_history(s)
	_ = sculpt.sculptor_flush(s)
	start := slice.clone(s.mask)
	defer delete(start)

	Case :: struct {
		command: sculpt.Mask_Command,
		steps:   int,
	}
	cases := [?]Case{{.Clear, 1}, {.Invert, 1}, {.Blur, 1}, {.Blur, 10}, {.Sharpen, 1}, {.Grow, 1}, {.Grow, 10}, {.Shrink, 1}}
	for c in cases {
		t0 := time.tick_now()
		_ = sculpt.sculptor_mask_command(s, c.command, c.steps)
		command_ms := time.duration_milliseconds(time.tick_since(t0))
		changed := 0
		for k, v in s.mask do if k != start[v] do changed += 1
		t1 := time.tick_now()
		_ = sculpt.sculptor_flush(s)
		flush_ms := time.duration_milliseconds(time.tick_since(t1))
		undo_mb := f64(sculpt.sculptor_undo_bytes(s)) / (1 << 20)
		t2 := time.tick_now()
		_ = sculpt.sculptor_undo(s)
		undo_ms := time.duration_milliseconds(time.tick_since(t2))
		_ = sculpt.sculptor_flush(s)
		sculpt.sculptor_clear_history(s)
		free_all(context.temp_allocator)
		fmt.printfln("| %s | %v | %d | %s | %.1f | %.2f | %.1f | %.1f |",
			thousands(len(sp.mesh.positions)), c.command, c.steps, thousands(changed), command_ms, flush_ms, undo_mb, undo_ms)
	}
}
