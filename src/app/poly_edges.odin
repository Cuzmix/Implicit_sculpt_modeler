package main

import "../render"
import "../sculpt"

// Polygon edges in the wireframe: an object whose shown level has polygons (a
// retopologized object's quads on its base level; a cage's polygons under a Catmull-Clark
// rule, on every level) shows their edges when the wireframe is on, instead of its
// triangles' edges with a diagonal across every quad, as ZBrush's PolyFrame shows the
// polygons. The edges go on the level's buffers as pairs (render.mesh_buffers_set_edges,
// the way a Model mode cage's go), made when the wireframe first asks for them and again
// only when the level's polygons change, which Object.poly_edges remembers per level.

// Whether the wireframe wants polygon edges on `obj` this frame: the Wireframe overlay's
// Lines on the active object (the overlay is its alone, as ZBrush's PolyFrame is), or the
// Wireframe shading mode on any; not a cage (whose edges are its own), a voxel or a
// dynamic object, and not while an HD window is open, since the base level around the
// window is drawn with the window's part hidden.
@(private = "file")
poly_edges_wanted :: proc(app: ^App, obj: ^Object) -> bool {
	return (app.wireframe && app.polyframe_lines && selected_object(app) == obj || shading_wire(app)) && obj.cage == nil && obj.voxel == nil && !object_in_hd(obj) && !object_dynamic(obj)
}

// Gives every shown object's shown level its polygon edges before the frame draws, when
// the wireframe wants them and they are not what the level's buffers hold: the Wireframe
// shading mode shows every object's, so an object not selected shows its quads too rather
// than its triangles. A failed upload leaves the
// level without edges, so its triangles' edges show, until its polygons change; a level
// whose polygons went loses its edges.
poly_edges_frame :: proc(app: ^App) {
	for obj in app.scene.objects {
		if !object_shown(app, obj) || !poly_edges_wanted(app, obj) do continue
		k := obj.levels.current
		gpu := &obj.gpu[k]
		// The level's buffers are made when it is first shown; until then there is
		// nothing to put the edges on.
		if gpu.positions == nil do continue
		source := sculpt.levels_polygon_source(&obj.levels, k)
		if source == obj.poly_edges[k] do continue
		pairs := sculpt.levels_polygon_edges(&obj.levels, k, context.temp_allocator)
		// Where the wireframe is drawn in the shading pass, the same edges per triangle
		// let it leave out the polygons' diagonals there instead of drawing every edge
		// again as a line.
		tri_edges: []u32
		if render.caps(&app.renderer).barycentric && len(pairs) > 0 do tri_edges = sculpt.levels_polygon_tri_edges(&obj.levels, k, pairs, context.temp_allocator)
		_ = render.mesh_buffers_set_edges(&app.renderer, gpu, pairs, tri_edges)
		obj.poly_edges[k] = source
	}
}

// Whether `obj` shows polygon edges this frame in place of its triangles' edges.
poly_edges_shown :: proc(app: ^App, obj: ^Object) -> bool {
	if !poly_edges_wanted(app, obj) do return false
	k := obj.levels.current
	return obj.poly_edges[k] != {} && obj.gpu[k].edges != nil
}
