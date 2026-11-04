package main

import "core:fmt"
import "core:math"

import "../sculpt"
import "../ui"

// How big a mesh this device should make, and how much of it the History may keep
// (Settings > Performance > Mesh size, and the History's Automatic budget). Automatic takes
// its numbers from the device's memory, because a fixed one suits nobody: what a 32 GB PC
// remeshes without trouble ended the app on an 8 GB iPad once the History held a second
// copy, and Nomad's own advice is 10 to 12M on a 16 GB iPad.

// The choices of Largest remesh and Largest subdivision level, in vertices; 0 is
// Automatic, from the device's memory, and the last one leaves only the memory check.
MESH_LIMITS := [?]i32{0, 2_000_000, 5_000_000, 10_000_000, 15_000_000, 25_000_000, 50_000_000, MESH_NO_LIMIT}
MESH_LIMITS_NAMES := [?]string{"Automatic", "2M", "5M", "10M", "15M", "25M", "50M", "No limit"}
#assert(len(MESH_LIMITS) == len(MESH_LIMITS_NAMES))
// No limit, as a count past any mesh (the settings file reads its bounds as f32).
MESH_NO_LIMIT :: 1_000_000_000

// The share of the device's memory one remesh's peak may take on Automatic: about 12M on
// an 8 GB iPad and 25M on 16 GB, with the scene, the History and the system beside it.
MESH_REMESH_SHARE :: 0.35
// The share a new subdivision level may take on Automatic (the fixed 12 GB cap before
// was half a 24 GB machine and more than all of an iPad's).
MESH_SUBDIVIDE_SHARE :: 0.5
// When the device does not say how much memory it has, the fixed caps of before.
MESH_SUBDIVIDE_BYTES_UNKNOWN :: 12 << 30

GB :: 1 << 30

// The largest remesh this run makes, in vertices: the setting, or on Automatic what the
// device's memory holds at the measured peak cost a vertex (memory_check.odin), rounded as
// the presets read; never above what Rebuild's Density slider offers.
mesh_remesh_most :: proc(app: ^App) -> int {
	if app.remesh_most > 0 do return min(int(app.remesh_most), REBUILD_MAX_VERTICES)
	return mesh_remesh_automatic(platform_ram())
}

// Automatic's largest remesh on a device of `ram` bytes; Rebuild's largest when the device
// does not say.
mesh_remesh_automatic :: proc(ram: int) -> int {
	if ram <= 0 do return REBUILD_MAX_VERTICES
	per_vertex := max(MEMORY_REMESH_BYTES, MEMORY_OBJECT_BYTES + MEMORY_READY_BYTES)
	most := memory_round_down(int(MESH_REMESH_SHARE * f64(ram)) / per_vertex)
	return clamp(most, REBUILD_MIN_VERTICES, REBUILD_MAX_VERTICES)
}

// Whether a new level of `vertices` taking `bytes` may be made: within Largest
// subdivision level when it is set, else within Automatic's share of the device's memory.
mesh_subdivide_fits :: proc(app: ^App, vertices, bytes: int) -> bool {
	if app.subdivide_most > 0 do return vertices <= int(app.subdivide_most)
	return bytes <= mesh_bytes_most()
}

// The most bytes one new level, a merged object or an applied skin may take on this
// device (subdivide's, Merge's and Apply's refusals).
mesh_bytes_most :: proc() -> int {
	ram := platform_ram()
	if ram <= 0 do return MESH_SUBDIVIDE_BYTES_UNKNOWN
	return int(MESH_SUBDIVIDE_SHARE * f64(ram))
}

// Holds a remesh to Largest remesh: a count above it becomes it, and a cell size that would
// make more widens until it does not, with a note saying where the limit is set. A script
// or a replay is held as well, since the limit is the device's and not the person's.
mesh_remesh_limit :: proc(app: ^App, cmd: ^Scene_Command) {
	if cmd.kind != .Remesh do return
	obj := selected_object(app)
	if obj == nil || obj.voxel != nil || obj.curve != nil do return
	most := mesh_remesh_most(app)
	made := memory_remesh_count(app, obj, cmd^)
	if made <= most do return
	if cmd.remesh.cell > 0 {
		cmd.remesh.cell *= f32(math.sqrt(f64(made) / f64(most)))
	} else {
		cmd.vertices = most
	}
	app.mesh_limited += 1
	file_note(app, false, "Remeshed to %s, the largest set for this device (Settings > Performance > Mesh size)", memory_count_label(most))
}

// The History's budget for rebuild copies on Automatic (History may use), by the device's
// memory: an 8 GB iPad keeps 1 GB of them, a 16 GB machine 1.5 GB, 24 GB and more 3 GB.
history_swap_automatic :: proc(ram: int) -> int {
	switch {
	case ram <= 0:       return SWAP_LIMIT_BYTES
	case ram < 6 * GB:   return 512 << 20
	case ram < 12 * GB:  return 1 * GB
	case ram < 24 * GB:  return SWAP_LIMIT_BYTES
	}
	return 3 * GB
}

// Each level's own budget for its strokes on Automatic: 512 MB a level on 12 GB and more,
// half that below, a quarter below 6 GB, since an iPad's five levels at 512 MB each were a
// third of what it gives the app.
history_level_automatic :: proc(ram: int) -> int {
	switch {
	case ram <= 0 || ram >= 12 * GB: return sculpt.UNDO_LIMIT_BYTES
	case ram >= 6 * GB:              return sculpt.UNDO_LIMIT_BYTES / 2
	}
	return sculpt.UNDO_LIMIT_BYTES / 4
}

// What the rebuild copies may take before the oldest go: the test's own, or the device's.
history_swap_limit :: proc(h: ^History) -> int {
	return h.swap_limit if h.swap_limit > 0 else history_swap_automatic(platform_ram())
}

// The system said memory runs low (SDL's LOW_MEMORY: iOS's memory warning, Android's
// onLowMemory): the oldest steps go until the History holds none
// but the newest step's, which the next Undo may want. Run by history_cap once nothing is
// under way, since the warning comes between frames and a stroke may be open.
history_low_memory :: proc(app: ^App) {
	app.memory_low = false
	h := &app.history
	before := h.swap_bytes
	dropped := 0
	for h.swap_bytes > 0 && history_step_count(h.done[:]) > 1 {
		n := history_drop_unmarked(app, 1)
		if n == 0 do break
		dropped += n
	}
	app.memory_low_warnings += 1
	if dropped == 0 do return
	file_note(app, true, "Memory is low: dropped the %d oldest step%s (%s) of the History", dropped, "" if dropped == 1 else "s", bytes_label(before - h.swap_bytes))
}

// Settings > Performance > Mesh size: Largest remesh and Largest subdivision level, each
// Automatic from the device's memory or a count, with what Automatic comes to here.
kit_mesh_size :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ram := platform_ram()
	pick :: proc(ctx: ^ui.Context, label: string, value: ^i32, automatic: string) {
		chosen := 0
		for v, i in MESH_LIMITS do if v == value^ do chosen = i
		names := MESH_LIMITS_NAMES
		names[0] = automatic
		ui.label(ctx, label)
		if picked := ui.select(ctx, label, names[:], chosen); picked >= 0 do value^ = MESH_LIMITS[picked]
	}
	pick(ctx, "Largest remesh", &app.remesh_most, fmt.tprintf("Automatic (%s here)", memory_count_label(mesh_remesh_automatic(ram))))
	pick(ctx, "Largest subdivision level", &app.subdivide_most, fmt.tprintf("Automatic (up to %s)", bytes_label(mesh_bytes_most())))
	device := fmt.tprintf("this device's %s", bytes_label(ram)) if ram > 0 else "this device's memory"
	ui.paragraph(ctx, fmt.tprintf("Automatic sizes both from %s, so a remesh and the copy the History keeps of the mesh before it fit together. A remesh past the limit is made at the limit, with a note; Rebuild's Density slider stops there. Before a step the memory check still asks when what is left would not hold it.", device))
}
