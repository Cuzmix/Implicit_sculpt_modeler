package sculpt

import "../jobs"

// Paint layers: polypaint as a stack, as Substance's and Procreate's layers are, painted on
// a sculpt of any size with no UVs. Each layer is a colour and a coverage per vertex
// (Color, as polypaint has always been) with a name, an eye and an opacity, and what shows
// is the stack composited bottom up, each layer laid over the ones below as far as it
// covers times its opacity.
//
// The picked layer is the sculptor's polypaint: while a layer is picked its colours are
// Sculptor.color and its own array is nil, as a sculpt layer's mask is the sculptor's mask
// while picked (layer_masks.odin). So every tool that paints (the Paint brush, a sculpting
// brush's Colour channel, Blur, Fill, Clear, Gradient, Project), undo, the levels' carries
// and the files work on the picked layer as they worked on polypaint. What reads the paint
// as it shows (drawing, exports, the eyedropper, Mask by colour, rebuilds) reads
// sculptor_paint_shown, which is Sculptor.color itself while the stack is plain (one
// visible layer at full opacity), so a plain stack costs nothing over polypaint.
//
// The composite is kept per vertex in Paint_Layers.shown and brought up to date by
// sculptor_flush for the nodes whose paint changed (paint_touch, from mark_stale), or as a
// whole after a change of the stack. Each subdivision level keeps its own arrays and its
// own copy of the stack; a level change mirrors the current level's stack onto the level
// it goes to (levels_carry_color), so the stack is the same wherever it is looked at.

// How many paint layers one sculptor keeps.
MAX_PAINT_LAYERS :: 32

Paint_Layer :: struct {
	id:      u32, // from 1, kept through moves, so an undo step finds its layer (Undo_Step.paint_layer)
	name:    [32]u8, // zero-terminated
	visible: bool,
	opacity: f32, // 0 to 1
	// Per vertex, the layer's colour and coverage; nil until painted, and nil while the
	// layer is picked (its colours are then Sculptor.color).
	color:   []Color,
}

Paint_Layers :: struct {
	list:    [dynamic]Paint_Layer,
	picked:  u32, // the id of the layer whose colours are Sculptor.color; 0 for none
	next_id: u32, // the id the next new layer takes, less one
	named:   int, // layers named so far, for the next "Paint N"
	// The composite per vertex while the stack is not plain; nil while it is.
	shown:   []Color,
	// Per node: its paint changed since the composite was brought up to date (listed in
	// `dirty` once); nil while the stack is plain.
	marked:  []bool,
	dirty:   [dynamic]u32,
	whole:   bool, // every node is out of date
}

// A change of the stack, kept by its undo step. Undoing or redoing swaps what it holds with
// the live stack, so it is its own inverse: a layer put in or taken out (`toggle`, the step
// holding the layer while `held`), a layer's name, eye and opacity (`set`), two layers
// swapped (`move`), and a layer's colours as a whole (`colors_of`, Merge down's lower
// layer). `picked` is the layer picked on the other side of the step.
@(private)
Paint_Op :: struct {
	active:    bool,
	toggle:    bool,
	index:     int,
	held:      bool,
	layer:     Paint_Layer,
	set:       bool,
	set_index: int,
	name:      [32]u8,
	visible:   bool,
	opacity:   f32,
	move:      bool,
	a, b:      int,
	recolor:   bool,
	colors_of: int,
	colors:    []Color,
	picked:    u32,
}

sculptor_paint_layers :: proc(s: ^Sculptor) -> []Paint_Layer {return s.paint.list[:]}

// The picked layer's index, or -1.
sculptor_paint_picked :: proc(s: ^Sculptor) -> int {return paint_index(s, s.paint.picked)}

// The layer's name as a string (pointing into the layer).
sculptor_paint_layer_name :: proc(l: ^Paint_Layer) -> string {
	n := 0
	for n < len(l.name) && l.name[n] != 0 do n += 1
	return string(l.name[:n])
}

// Layer `index`'s colours wherever they are: the sculptor's while it is picked; nil when
// it has none.
sculptor_paint_layer_colors :: proc(s: ^Sculptor, index: int) -> []Color {
	l := s.paint.list[index]
	return s.color if l.id == s.paint.picked else l.color
}

// Whether the stack shows as the picked layer alone: no layers, or one shown at full
// opacity. Its composite is then Sculptor.color itself.
paint_plain :: proc(s: ^Sculptor) -> bool {
	list := s.paint.list[:]
	return len(list) == 0 || (len(list) == 1 && list[0].visible && list[0].opacity >= 1 && list[0].id == s.paint.picked)
}

// The paint as it shows, per vertex (colour and coverage over the clay): the composite of
// every layer, or the picked layer's colours while the stack is plain; nil with no paint.
// What drawing, exports and every reader of the surface's look take.
// Brings the composite up to date first when something changed since the last flush, so it
// must not run in a job while paint is pending.
sculptor_paint_shown :: proc(s: ^Sculptor) -> []Color {
	if paint_plain(s) do return s.color
	if s.paint.whole || len(s.paint.dirty) > 0 || s.paint.shown == nil do paint_flush(s)
	return s.paint.shown
}

// Whether any paint shows (sculptor_has_color says only that the picked layer has colours).
sculptor_paint_shows :: proc(s: ^Sculptor) -> bool {return sculptor_paint_shown(s) != nil}

// The index of the layer with id `id`, or -1.
@(private)
paint_index :: proc(s: ^Sculptor, id: u32) -> int {
	if id == 0 do return -1
	for l, i in s.paint.list do if l.id == id do return i
	return -1
}

// The colours of the layer with id `id` wherever they are (nil when it is gone or has none):
// where an undo step that painted it finds them.
@(private)
paint_colors_by_id :: proc(s: ^Sculptor, id: u32) -> []Color {
	if id == 0 || id == s.paint.picked do return s.color
	i := paint_index(s, id)
	return s.paint.list[i].color if i >= 0 else nil
}

// Puts the picked layer's colours back in it, picking none. Returns the id it was.
@(private)
paint_unpick :: proc(s: ^Sculptor) -> u32 {
	id := s.paint.picked
	if i := paint_index(s, id); i >= 0 {
		s.paint.list[i].color = s.color
		s.color = nil
	}
	s.paint.picked = 0
	return id
}

// Picks the layer with id `id` (none when it is not in the stack): its colours become the
// sculptor's. The caller unpicked first.
@(private)
paint_pick_id :: proc(s: ^Sculptor, id: u32) {
	assert(s.paint.picked == 0 && s.color == nil, "unpick first")
	i := paint_index(s, id)
	if i < 0 do return
	s.color, s.paint.list[i].color = s.paint.list[i].color, nil
	s.paint.picked = id
}

// Makes a layer named "Paint N" (not yet in the stack).
@(private)
paint_layer_make :: proc(s: ^Sculptor) -> Paint_Layer {
	s.paint.next_id += 1
	s.paint.named += 1
	l := Paint_Layer{id = s.paint.next_id, visible = true, opacity = 1}
	copy(l.name[:len(l.name) - 1], "Paint ")
	digits: [8]u8
	k, n := len(digits), s.paint.named
	for {
		k -= 1
		digits[k] = u8('0' + n % 10)
		n /= 10
		if n == 0 || k == 0 do break
	}
	copy(l.name[6:len(l.name) - 1], digits[k:])
	return l
}

// Gives a sculptor without paint layers its first, picked, for the first paint laid on it
// (color_ensure): polypaint's colours are that layer's. Not an undo step, as an empty
// layer shows nothing.
@(private)
paint_first_layer :: proc(s: ^Sculptor) {
	if len(s.paint.list) > 0 do return
	append(&s.paint.list, paint_layer_make(s))
	s.paint.picked = s.paint.list[0].id
}

// Picks layer `index` for painting (-1 for none): every paint tool then paints it. Not an
// undo step, as the layer's mask pick is not; ends the stroke under way.
sculptor_paint_pick :: proc(s: ^Sculptor, index: int) {
	_ = sculptor_stroke_end(s)
	id := s.paint.list[index].id if index >= 0 && index < len(s.paint.list) else 0
	if id == s.paint.picked do return
	paint_unpick(s)
	paint_pick_id(s, id)
	paint_changed(s)
}

// Adds an empty layer above the picked one (on top with none) and picks it, as an undo
// step. Returns its index, or -1 when there are MAX_PAINT_LAYERS or dynamic topology is on.
sculptor_paint_add :: proc(s: ^Sculptor) -> int {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || len(s.paint.list) >= MAX_PAINT_LAYERS do return -1
	index := sculptor_paint_picked(s) + 1 if s.paint.picked != 0 else len(s.paint.list)
	l := paint_layer_make(s)
	sculptor_stroke_begin(s)
	s.history.current.paint_op = {active = true, toggle = true, index = index, held = true, layer = l, picked = l.id}
	paint_op_swap(s, &s.history.current.paint_op)
	_ = sculptor_stroke_end(s)
	return index
}

// Takes layer `index` out as an undo step; the layer below it is picked if it was.
sculptor_paint_remove :: proc(s: ^Sculptor, index: int) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || index < 0 || index >= len(s.paint.list) do return false
	picked := s.paint.picked
	if s.paint.list[index].id == picked {
		picked = 0
		if index > 0 do picked = s.paint.list[index - 1].id
		else if len(s.paint.list) > 1 do picked = s.paint.list[1].id
	}
	sculptor_stroke_begin(s)
	s.history.current.paint_op = {active = true, toggle = true, index = index, picked = picked}
	paint_op_swap(s, &s.history.current.paint_op)
	_ = sculptor_stroke_end(s)
	return true
}

// Sets a layer's eye and opacity. Part of the step being recorded when that is this
// layer's (a slider drag calls it each frame, and the caller ends the step on release),
// else a step of its own. Returns false when dynamic topology is on.
sculptor_paint_set :: proc(s: ^Sculptor, index: int, visible: bool, wanted: f32) -> bool {
	if s.dyn != nil || index < 0 || index >= len(s.paint.list) do return false
	h := &s.history
	op := &h.current.paint_op
	if h.recording && !(op.active && op.set && op.set_index == index) do _ = sculptor_stroke_end(s)
	l := &s.paint.list[index]
	opacity := clamp(wanted, 0, 1)
	if l.visible == visible && l.opacity == opacity do return true
	if !h.recording {
		sculptor_stroke_begin(s)
		h.current.paint_op = {active = true, set = true, set_index = index, name = l.name, visible = l.visible, opacity = l.opacity, picked = s.paint.picked}
	}
	l.visible, l.opacity = visible, opacity
	paint_touch_layer(s, index)
	return true
}

// Swaps layers `index` and `index + 1` (moves one up), as an undo step.
sculptor_paint_move :: proc(s: ^Sculptor, index: int) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || index < 0 || index + 1 >= len(s.paint.list) do return false
	sculptor_stroke_begin(s)
	s.history.current.paint_op = {active = true, move = true, a = index, b = index + 1, picked = s.paint.picked}
	paint_op_swap(s, &s.history.current.paint_op)
	_ = sculptor_stroke_end(s)
	return true
}

// Lays layer `index` over the one below it as it shows (both opacities and eyes taken in)
// and takes it out, as one undo step: the lower layer then holds what the two showed, at
// full opacity. Returns false when there is no layer below or dynamic topology is on.
sculptor_paint_merge_down :: proc(s: ^Sculptor, index: int) -> bool {
	_ = sculptor_stroke_end(s)
	if s.dyn != nil || index < 1 || index >= len(s.paint.list) do return false
	picked := s.paint.picked
	if s.paint.list[index].id == picked do picked = s.paint.list[index - 1].id
	n := len(s.mesh.positions)
	merged := make([]Color, n, s.history.allocator)
	pair := [2]int{index - 1, index}
	Job :: struct {
		s:      ^Sculptor,
		layers: [2][]Color,
		weight: [2]f32,
		count:  int,
		out:    []Color,
	}
	job := Job{s = s, out = merged}
	for k in 0 ..< 2 {
		l := s.paint.list[pair[k]]
		w := l.opacity if l.visible else 0
		colors := sculptor_paint_layer_colors(s, pair[k])
		if w <= 0 || colors == nil do continue
		job.layers[job.count], job.weight[job.count] = colors, w
		job.count += 1
	}
	jobs.parallel_ranges(s.pool, n, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for v in lo ..< hi do job.out[v] = paint_composite(job.layers[:job.count], job.weight[:job.count], u32(v), job.s.mesh.positions[v])
	}, 1 << 14)
	sculptor_stroke_begin(s)
	s.history.current.paint_op = {active = true, toggle = true, index = index, recolor = true, colors_of = index - 1, colors = merged, picked = picked}
	op := &s.history.current.paint_op
	paint_op_swap(s, op)
	// The lower layer shows at full opacity now: its old opacity and eye are the step's to
	// give back. Merge sets them after the swap, so undo restores them through `set`.
	lower := &s.paint.list[index - 1]
	op.set, op.set_index, op.name, op.visible, op.opacity = true, index - 1, lower.name, lower.visible, lower.opacity
	lower.visible, lower.opacity = true, 1
	_ = sculptor_stroke_end(s)
	return true
}

// Trades what a stack step holds with the live stack: undo and redo alike. The picked
// layer's colours go back in it first, and the step's other pick is picked after.
@(private)
paint_op_swap :: proc(s: ^Sculptor, op: ^Paint_Op) {
	if !op.active do return
	picked := paint_unpick(s)
	list := &s.paint.list
	// Undo applies a step's parts in the reverse of redo's order: `set` and `recolor` name
	// the layer below a merged one, whose index the toggle does not change.
	if op.set {
		l := &list[op.set_index]
		l.name, op.name = op.name, l.name
		l.visible, op.visible = op.visible, l.visible
		l.opacity, op.opacity = op.opacity, l.opacity
	}
	if op.recolor {
		l := &list[op.colors_of]
		l.color, op.colors = op.colors, l.color
	}
	if op.move do list[op.a], list[op.b] = list[op.b], list[op.a]
	if op.toggle {
		if op.held {
			inject_at(list, op.index, op.layer)
			op.layer = {}
		} else {
			op.layer = list[op.index]
			ordered_remove(list, op.index)
		}
		op.held = !op.held
	}
	paint_pick_id(s, op.picked)
	op.picked = picked
	paint_changed(s)
}

// The stack changed as a whole: everything is composited and uploaded again, and a level
// change carries it.
@(private)
paint_changed :: proc(s: ^Sculptor) {
	s.paint.whole = true
	s.paint_stamp += 1
	s.color_edited = true
}

// Notes that node `id`'s paint changed, for the composite (called by mark_stale).
@(private)
paint_touch :: #force_inline proc(s: ^Sculptor, id: u32) {
	if s.paint.marked == nil || s.paint.marked[id] do return
	s.paint.marked[id] = true
	append(&s.paint.dirty, id)
}

// Marks the nodes where layer `index` has any coverage as changed, for an eye or opacity
// change, which alters the composite only there.
@(private)
paint_touch_layer :: proc(s: ^Sculptor, index: int) {
	s.color_edited = true
	colors := sculptor_paint_layer_colors(s, index)
	if colors == nil do return
	if !paint_plain(s) && s.paint.shown == nil {
		s.paint.whole = true
		return
	}
	Job :: struct {
		s:      ^Sculptor,
		colors: []Color,
		covers: []bool,
	}
	job := Job{s, colors, make([]bool, len(s.nodes), context.temp_allocator)}
	jobs.parallel_ranges(s.pool, len(s.nodes), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		for id in lo ..< hi {
			n := job.s.nodes[id]
			for c in job.colors[n.vert_first:][:n.vert_count] {
				if c.a != 0 {
					job.covers[id] = true
					break
				}
			}
		}
	}, NODE_GRAIN)
	for c, id in job.covers do if c do mark_stale(s, u32(id), .Paint)
	// A stack that just stopped being plain composites everything at the next flush.
	if s.paint.marked == nil do s.paint.whole = true
}

// One vertex's composite of `count` layers listed bottom up, `weight` their opacities:
// Porter and Duff's over, worked front to back on premultiplied colour so it stops at the
// first layer that covers the vertex fully, which is most of a painted surface, and so one
// division ends it instead of one a layer.
@(private)
paint_composite :: #force_inline proc(layers: []([]Color), weight: []f32, v: u32, p: Vec3) -> Color {
	rgb: [3]f32
	a: f32
	for k := len(layers) - 1; k >= 0; k -= 1 {
		c := layers[k][v]
		if c.a == 0 do continue
		x := f32(c.a) * (1.0 / 255) * weight[k] * (1 - a)
		rgb += {f32(c.r), f32(c.g), f32(c.b)} * x
		a += x
		if a >= 1 do break
	}
	if a <= 0 do return {}
	return paint_quantize(rgb / a, min(a, 1), p)
}

// A composited colour as bytes, with an ordered dither so soft gradients of several 8-bit
// layers do not band. The dither's cell comes from the vertex's position, not its number,
// so the same surface composites to the same bytes however a build numbered it (a scene
// opened again). It stays inside ±0.47 of a step, so a value that is a whole step (one
// layer at full opacity) comes out exactly.
@(private)
paint_quantize :: #force_inline proc(rgb: [3]f32, a: f32, p: Vec3) -> Color {
	@(static, rodata)
	BAYER := [16]f32{0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5}
	bits := transmute([3]u32)p
	cell := (bits.x * 73856093 ~ bits.y * 19349663 ~ bits.z * 83492791) >> 28
	d := ((BAYER[cell] + 0.5) * (1.0 / 16) - 0.5) * 0.94
	out: Color
	for k in 0 ..< 3 do out[k] = u8(clamp(rgb[k] + d + 0.5, 0, 255))
	out.a = u8(clamp(a * 255 + d + 0.5, 0, 255))
	return out
}

// Brings the composite up to date, for sculptor_flush: drops it while the stack is plain,
// makes it (and composites everything) when the stack stops being plain, else composites
// the nodes whose paint changed. A new or dropped composite, or a whole one, bumps the paint
// stamp, so the GPU takes all of it.
@(private)
paint_flush :: proc(s: ^Sculptor) {
	p := &s.paint
	if paint_plain(s) {
		if p.shown != nil {
			delete(p.shown, s.history.allocator)
			delete(p.marked, s.history.allocator)
			p.shown, p.marked = nil, nil
			s.paint_stamp += 1
		}
		clear(&p.dirty)
		p.whole = false
		return
	}
	if p.shown == nil {
		p.shown = make([]Color, len(s.mesh.positions), s.history.allocator)
		p.marked = make([]bool, len(s.nodes), s.history.allocator)
		p.whole = true
	}
	if p.whole {
		clear(&p.dirty)
		for id in 0 ..< len(s.nodes) do append(&p.dirty, u32(id))
		s.paint_stamp += 1
	}
	if len(p.dirty) == 0 do return
	Job :: struct {
		s:      ^Sculptor,
		layers: [MAX_PAINT_LAYERS][]Color,
		weight: [MAX_PAINT_LAYERS]f32,
		count:  int,
	}
	job := Job{s = s}
	for l, i in p.list {
		w := l.opacity if l.visible else 0
		colors := sculptor_paint_layer_colors(s, i)
		if w <= 0 || colors == nil do continue
		job.layers[job.count], job.weight[job.count] = colors, w
		job.count += 1
	}
	verts: u32
	for id in p.dirty do verts += s.nodes[id].vert_count
	jobs.parallel_for(s.pool if verts >= PARALLEL_MIN_VERTS else nil, len(p.dirty), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		s := job.s
		n := s.nodes[s.paint.dirty[i]]
		for v in n.vert_first ..< n.vert_first + n.vert_count do s.paint.shown[v] = paint_composite(job.layers[:job.count], job.weight[:job.count], v, s.mesh.positions[v])
	})
	for id in p.dirty do p.marked[id] = false
	clear(&p.dirty)
	p.whole = false
}

// Frees every layer, the composite and the stack (sculptor_destroy, and dynamic topology,
// which drops paint). The picked layer's colours are Sculptor.color's to free.
@(private)
paint_layers_destroy :: proc(s: ^Sculptor) {
	a := s.history.allocator
	for l in s.paint.list do delete(l.color, a)
	delete(s.paint.list)
	delete(s.paint.shown, a)
	delete(s.paint.marked, a)
	delete(s.paint.dirty)
	s.paint = {}
}

// Frees what a stack step holds (a layer taken out, a merged layer's old colours).
@(private)
paint_op_free :: proc(h: ^Undo_History, op: ^Paint_Op) {
	if op.held do delete(op.layer.color, h.allocator)
	delete(op.colors, h.allocator)
	op^ = {}
}

// Bytes a stack step holds.
@(private)
paint_op_bytes :: proc(op: Paint_Op) -> int {
	n := len(op.colors) * size_of(Color)
	if op.held do n += len(op.layer.color) * size_of(Color)
	return n
}

// Gives level `dst` the stack of level `src` (names, eyes, opacities, order and the pick),
// keeping dst's own colours for the layers it has. Returns, per layer of the stack, whether
// dst lacked it and so needs its colours carried. Both levels' picked layers go back in
// their layers first and are picked again after.
@(private)
paint_mirror :: proc(src, dst: ^Sculptor, allocator := context.temp_allocator) -> []bool {
	src_picked := paint_unpick(src)
	_ = paint_unpick(dst)
	a := dst.history.allocator
	missing := make([]bool, len(src.paint.list), allocator)
	list := make([dynamic]Paint_Layer, 0, len(src.paint.list))
	for l, i in src.paint.list {
		mine := l
		mine.color = nil
		if j := paint_index(dst, l.id); j >= 0 {
			mine.color = dst.paint.list[j].color
			dst.paint.list[j].color = nil
		}
		missing[i] = mine.color == nil && l.color != nil
		append(&list, mine)
	}
	for l in dst.paint.list do delete(l.color, a)
	delete(dst.paint.list)
	dst.paint.list = list
	dst.paint.next_id, dst.paint.named = src.paint.next_id, src.paint.named
	paint_pick_id(src, src_picked)
	paint_pick_id(dst, src_picked)
	dst.paint.whole = true
	dst.paint_stamp += 1
	return missing
}

// Whether two stacks have the same layers in the same order (their colours aside).
@(private)
paint_same_stack :: proc(a, b: ^Sculptor) -> bool {
	if len(a.paint.list) != len(b.paint.list) || a.paint.picked != b.paint.picked do return false
	for l, i in a.paint.list {
		m := b.paint.list[i]
		if l.id != m.id || l.name != m.name || l.visible != m.visible || l.opacity != m.opacity do return false
	}
	return true
}

// The bytes the stack's layers other than the picked one hold, and the composite: for the
// memory count.
sculptor_paint_bytes :: proc(s: ^Sculptor) -> int {
	n := len(s.paint.shown) * size_of(Color)
	for l in s.paint.list do n += len(l.color) * size_of(Color)
	return n
}
