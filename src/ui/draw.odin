package ui

import "core:math"
import "core:math/linalg"
import "core:slice"

// One corner of a UI triangle: a position in physical pixels, a texture coordinate
// and a colour. With the atlas bound the coordinate is in atlas pixels (the shader
// divides by the atlas size, so coordinates stay right if the atlas grows during the
// frame); with an image bound it runs 0 to 1 across the image. Matches ui.vert.
Vertex :: struct {
	pos:   [2]f32,
	uv:    [2]f32,
	color: [4]u8,
}

// What a draw command samples: the font atlas (whose white texel colours the solid
// shapes) or an image the app registered, such as the viewport.
Texture :: enum u8 {
	Atlas,
	Image,
}

// A run of indices drawn with one texture and one clip rectangle.
Draw_Cmd :: struct {
	first_index: u32,
	index_count: u32,
	clip:        Rect, // physical pixels
	texture:     Texture,
	image:       u64, // the app's id for the image, when texture is .Image
}

// The frame's triangles, ready to upload: what ui.tessellate returns.
Draw_List :: struct {
	vertices: [dynamic]Vertex,
	indices:  [dynamic]u32,
	cmds:     [dynamic]Draw_Cmd,
	// Commands below this index keep their state even while empty: an open container
	// will put its background into one of them.
	keep:     int,
}

// The atlas texel fontstash fills white (its first 2 x 2 rectangle), sampled by
// solid shapes so text and shapes share one draw.
WHITE_UV :: [2]f32{1, 1}

// Antialiasing fringe width, in physical pixels.
FRINGE :: f32(1)

draw_list_clear :: proc(dl: ^Draw_List) {
	clear(&dl.vertices)
	clear(&dl.indices)
	clear(&dl.cmds)
}

draw_list_destroy :: proc(dl: ^Draw_List) {
	delete(dl.vertices)
	delete(dl.indices)
	delete(dl.cmds)
	dl^ = {}
}

// Starts a new command when the texture or clip rectangle changes; otherwise the
// next triangles extend the current one.
@(private)
draw_set_state :: proc(dl: ^Draw_List, texture: Texture, image: u64, clip: Rect) {
	if n := len(dl.cmds); n > 0 {
		last := &dl.cmds[n - 1]
		if last.texture == texture && last.image == image && last.clip == clip do return
		if last.index_count == 0 && n - 1 >= dl.keep {
			last.texture, last.image, last.clip = texture, image, clip
			return
		}
	}
	append(&dl.cmds, Draw_Cmd{first_index = u32(len(dl.indices)), clip = clip, texture = texture, image = image})
}

// Moves the triangles added since index `from` (the last command's) back to index
// `mark`, the end of command `cmd`, so they draw under everything added after `mark`.
// Containers use it to put their background under content drawn before its size was
// known. Command `cmd` must have the moved triangles' state.
@(private)
draw_move_under :: proc(dl: ^Draw_List, mark, cmd, from: int) {
	n := len(dl.indices) - from
	if n == 0 || mark == from do return
	slice.rotate_right(dl.indices[mark:], n)
	dl.cmds[len(dl.cmds) - 1].index_count -= u32(n)
	dl.cmds[cmd].index_count += u32(n)
	for &c in dl.cmds[cmd + 1:] do c.first_index += u32(n)
}

@(private)
draw_add_indices :: proc(dl: ^Draw_List, indices: ..u32) {
	append(&dl.indices, ..indices)
	dl.cmds[len(dl.cmds) - 1].index_count += u32(len(indices))
}

@(private)
color_alpha :: #force_inline proc(c: [4]u8, a: f32) -> [4]u8 {
	return {c.r, c.g, c.b, u8(f32(c.a) * clamp(a, 0, 1) + 0.5)}
}

// A filled convex polygon (points clockwise or counter-clockwise), its edges
// feathered over FRINGE pixels so they look smooth without multisampling.
draw_convex :: proc(dl: ^Draw_List, points: [][2]f32, color: [4]u8) {
	n := len(points)
	if n < 3 || color.a == 0 do return
	base := u32(len(dl.vertices))
	// Which way the points turn decides which side of each edge is outside.
	area: f32
	for i in 0 ..< n {
		a, b := points[i], points[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	}
	side: f32 = 1 if area > 0 else -1
	clear_color := color_alpha(color, 0)
	for i in 0 ..< n {
		prev, p, next := points[(i + n - 1) % n], points[i], points[(i + 1) % n]
		n0 := edge_normal(prev, p) * side
		n1 := edge_normal(p, next) * side
		m := miter(n0, n1) * (FRINGE * 0.5)
		append(&dl.vertices, Vertex{p - m, WHITE_UV, color}, Vertex{p + m, WHITE_UV, clear_color})
	}
	for i in 2 ..< n do draw_add_indices(dl, base, base + u32(i - 1) * 2, base + u32(i) * 2)
	for i in 0 ..< n {
		j := (i + 1) % n
		a_in, a_out := base + u32(i) * 2, base + u32(i) * 2 + 1
		b_in, b_out := base + u32(j) * 2, base + u32(j) * 2 + 1
		draw_add_indices(dl, a_in, b_in, b_out, a_in, b_out, a_out)
	}
}

// A line through `points` `thickness` pixels wide, feathered at its sides; `closed`
// joins the last point back to the first.
draw_polyline :: proc(dl: ^Draw_List, points: [][2]f32, color: [4]u8, thickness: f32, closed := false) {
	n := len(points)
	if n < 2 || color.a == 0 do return
	// Lines thinner than a pixel draw a pixel wide, fainter, which reads as thinner.
	color := color
	half := thickness * 0.5
	if thickness < 1 {
		color = color_alpha(color, thickness)
		half = 0.5
	}
	inner := max(half - FRINGE * 0.5, 0)
	outer := half + FRINGE * 0.5
	clear_color := color_alpha(color, 0)
	base := u32(len(dl.vertices))
	for i in 0 ..< n {
		p := points[i]
		n0, n1: [2]f32
		if closed {
			n0 = edge_normal(points[(i + n - 1) % n], p)
			n1 = edge_normal(p, points[(i + 1) % n])
		} else {
			n0 = edge_normal(points[max(i - 1, 0)], points[max(i, 1)])
			n1 = edge_normal(points[min(i, n - 2)], points[min(i + 1, n - 1)])
		}
		m := miter(n0, n1)
		append(&dl.vertices,
			Vertex{p + m * outer, WHITE_UV, clear_color},
			Vertex{p + m * inner, WHITE_UV, color},
			Vertex{p - m * inner, WHITE_UV, color},
			Vertex{p - m * outer, WHITE_UV, clear_color},
		)
	}
	segments := n if closed else n - 1
	for i in 0 ..< segments {
		a := base + u32(i) * 4
		b := base + u32((i + 1) % n) * 4
		for k in u32(0) ..< 3 do draw_add_indices(dl, a + k, b + k, b + k + 1, a + k, b + k + 1, a + k + 1)
	}
}

// A textured rectangle: glyphs (atlas pixels) or an image (0 to 1), no feathering.
draw_quad :: proc(dl: ^Draw_List, r: Rect, uv0, uv1: [2]f32, color: [4]u8) {
	base := u32(len(dl.vertices))
	append(&dl.vertices,
		Vertex{{r.x, r.y}, uv0, color},
		Vertex{{r.x + r.w, r.y}, {uv1.x, uv0.y}, color},
		Vertex{{r.x + r.w, r.y + r.h}, uv1, color},
		Vertex{{r.x, r.y + r.h}, {uv0.x, uv1.y}, color},
	)
	draw_add_indices(dl, base, base + 1, base + 2, base, base + 2, base + 3)
}

// The outline of a rectangle with corners rounded by `radius`, as points, appended
// to `out`; a radius of 0 gives the four corners.
rounded_rect_path :: proc(out: ^[dynamic][2]f32, r: Rect, radius: f32) {
	rad := min(radius, r.w * 0.5, r.h * 0.5)
	if rad <= 0.5 {
		append(out, [2]f32{r.x, r.y}, [2]f32{r.x + r.w, r.y}, [2]f32{r.x + r.w, r.y + r.h}, [2]f32{r.x, r.y + r.h})
		return
	}
	// Enough segments that a corner looks round at its size, and few on small ones.
	steps := clamp(int(rad * 0.75), 3, 16)
	corners := [4][3]f32 {
		{r.x + rad, r.y + rad, math.PI},
		{r.x + r.w - rad, r.y + rad, math.PI * 1.5},
		{r.x + r.w - rad, r.y + r.h - rad, 0},
		{r.x + rad, r.y + r.h - rad, math.PI * 0.5},
	}
	// A pill (radius half a side) has sides of no length, where one corner ends on the
	// point the next begins; a repeated point has no edge direction and folds the
	// feathered outline over, so it is left out.
	start := len(out)
	for c in corners {
		for s in 0 ..= steps {
			a := c[2] + f32(s) / f32(steps) * math.PI * 0.5
			p := [2]f32{c[0] + math.cos(a) * rad, c[1] + math.sin(a) * rad}
			if len(out) > start && linalg.length2(p - out[len(out) - 1]) < 1e-4 do continue
			append(out, p)
		}
	}
	if len(out) - start > 1 && linalg.length2(out[len(out) - 1] - out[start]) < 1e-4 do pop(out)
}

// A circle's outline as points, appended to `out`.
circle_path :: proc(out: ^[dynamic][2]f32, center: [2]f32, radius: f32) {
	steps := clamp(int(radius * 0.8), 12, 64)
	for s in 0 ..< steps {
		a := f32(s) / f32(steps) * math.TAU
		append(out, center + [2]f32{math.cos(a), math.sin(a)} * radius)
	}
}

@(private)
edge_normal :: #force_inline proc(a, b: [2]f32) -> [2]f32 {
	d := linalg.normalize0(b - a)
	return {d.y, -d.x}
}

// The offset direction at a corner between two edges with normals n0 and n1, long
// enough that the offset lines stay `1` from both edges, clamped at sharp corners.
@(private)
miter :: #force_inline proc(n0, n1: [2]f32) -> [2]f32 {
	m := n0 + n1
	d := linalg.dot(m, m) * 0.5
	if d < 1e-6 do return n0
	return m / max(d, 0.25)
}
