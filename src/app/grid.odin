package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"

import "../camera"
import "../render"
import "../ui"

// The view grid (Camera > View grid, Lens): the viewport split into one to four panes by
// a tree of splits, as Blender's areas split, which the presets give in one tap and Lens's
// corner drags (lens_areas.odin) split, join, swap and dock. Pane 0 is the main view,
// where the camera, the tools and the heavy passes live; panes 1 to 3 are view panes,
// second views (thumbnail.odin) tiled beside it, each with its own camera and cheap pass,
// drawn only at rest so a big mesh is never drawn twice a frame while you work. A new
// preset's panes start as the partner a sculptor wants (front beside the perspective, the
// side beside the front) as Maya's and 3ds Max's four views do.

Grid_Preset :: enum u8 {
	Single,
	Side_By_Side,
	Stacked,
	One_Plus_Two, // a big pane on the left, two stacked on the right
	Four,
	Three_Across,
}

@(rodata)
GRID_NAMES := [Grid_Preset]string {
	.Single       = "Single",
	.Side_By_Side = "Side by side",
	.Stacked      = "Stacked",
	.One_Plus_Two = "One plus two",
	.Four         = "Four",
	.Three_Across = "Three across",
}

// The most panes the grid shows, and so view panes beside the main one.
GRID_PANES :: 4
GRID_VIEWS :: GRID_PANES - 1
// The nodes a tree of GRID_PANES leaves takes: every split joins two.
GRID_NODES :: 2 * GRID_PANES - 1

// Points between two panes, where the frame shows through as their divider.
GRID_GAP :: 2
// The least part of the room a pane keeps across and down, so no split hides one.
GRID_PANE_MIN :: 0.1

// A node of the grid's tree: a leaf showing a pane, or a split of its room in two.
Grid_Node :: struct {
	split:    bool,
	vertical: bool, // a split's cut runs up and down, `a` left of `b`; else `a` is above `b`
	share:    f32, // the part of a split's room `a` takes
	a, b:     u8, // a split's children
	pane:     u8, // a leaf's pane: 0 the main view, 1 to 3 the view panes
}

// The panes' layout. In its normal form (grid_tree_normal) node 0 is the root, the nodes
// run in depth-first order, the panes shown are 0 to n-1 and the view panes are numbered
// as they come in that order, so equal layouts are equal trees.
Grid_Tree :: struct {
	nodes: [GRID_NODES]Grid_Node,
	count: int,
}

// A layout step that Undo takes back (lens_areas.odin): the tree and the panes as they
// were, and when the step was made, which orders it among the scene's History steps.
Grid_Step :: struct {
	tree:  Grid_Tree,
	views: [GRID_VIEWS]Second_View,
	at:    time.Tick,
}

GRID_UNDO :: 16

Grid_Undo :: struct {
	back:   [GRID_UNDO]Grid_Step,
	back_n: int,
	ahead:   [GRID_UNDO]Grid_Step,
	ahead_n: int,
}

// The grid's choices, kept by workspaces (workspaces.odin): the tree and its view panes.
View_Grid :: struct {
	tree:      Grid_Tree,
	views:     [GRID_VIEWS]Second_View,
	maximised: int, // the view pane filling the grid (1 to 3), 0 for none; never kept
	// Counts every change to the tree, so what began on one layout (work in a pane) knows
	// it is gone; never kept.
	serial:    int,
	undo:      Grid_Undo, // never kept
	// Where the view panes' views moved last (grid_tree_set), for their pictures to follow
	// (grid_pictures_follow) before anything draws them; never kept.
	was:       [GRID_VIEWS]int,
	moved:     bool,
	areas:     Grid_Areas, // Lens's pane gestures (lens_areas.odin); never kept
	// This frame's layout, never kept: the main pane's rect in points, and each view
	// pane's picture size in pixels (zero for one not shown).
	main:      ui.Rect,
	px:        [GRID_VIEWS][2]u32,
	dragged:   int, // the divider held (1 + its node), 0 for none, for the exit stats
	drags:     int, // frames a divider moved, for the exit stats
	// Lens's dividers (lens_panes.odin): the last tap on one, the divider let go at the
	// edge would close the side beyond (1 + its node, 0 for none) and which side, and for
	// the exit stats how many closes and evens there were; never kept.
	tap:         Handle_Tap,
	closing:     int,
	closing_far: bool,
	closes:      int,
	evens:       int,
	// Work in any pane (grid_work): the view pane (1 to 3) the main view's role is lent to
	// while a gesture that began on it lasts, 0 for none, and on which layout; never kept.
	work:        int,
	work_serial: int,
	work_back:   camera.Orbit, // the main camera, given back when the gesture is over
	work_from:   camera.Orbit, // the pane's camera as it began, to tell whether it moved
	// This frame's start or end, for the copies and the resize after kit_frame
	// (grid_work_gpu), and what the main pane showed as it began, to keep still.
	work_began:  bool,
	work_ended:  int, // the view pane whose work ended this frame, 0 for none
	work_shown:  render.Texture,
	work_live:   render.Texture, // what the pane showed last as the work ended, for its picture
	last_place:  int, // where the last press went: 0 the main pane, else the view pane
	// For the exit stats: gestures worked in a view pane, and the dabs they laid.
	works:       int,
	work_dabs:   int,
	work_dabs_from: int,
}

// How many panes a preset shows.
grid_count :: proc(preset: Grid_Preset) -> int {
	switch preset {
	case .Single:                  return 1
	case .Side_By_Side, .Stacked:  return 2
	case .One_Plus_Two, .Three_Across: return 3
	case .Four:                    return 4
	}
	return 1
}

// How many panes the grid shows now.
grid_panes :: proc(g: ^View_Grid) -> int {
	return grid_tree_panes(&g.tree)
}

grid_tree_panes :: proc(t: ^Grid_Tree) -> int {
	n := 0
	for node in t.nodes[:t.count] do if !node.split do n += 1
	return max(n, 1)
}

// Adds a leaf showing `pane`, or a split of `a` and `b`, to a tree being built; the
// tree is put in its normal form once built.
grid_leaf :: proc(t: ^Grid_Tree, pane: int) -> u8 {
	t.nodes[t.count] = {pane = u8(pane)}
	t.count += 1
	return u8(t.count - 1)
}

grid_cut :: proc(t: ^Grid_Tree, vertical: bool, share: f32, a, b: u8) -> u8 {
	t.nodes[t.count] = {split = true, vertical = vertical, share = share, a = a, b = b}
	t.count += 1
	return u8(t.count - 1)
}

// `t` from node `root` in its normal form: what is no longer reached from the root goes.
grid_tree_normal :: proc(t: Grid_Tree, root: u8) -> (out: Grid_Tree) {
	src := t
	walk :: proc(src: ^Grid_Tree, n: u8, out: ^Grid_Tree) -> u8 {
		at := u8(out.count)
		out.count += 1
		node := src.nodes[n]
		if node.split {
			a := walk(src, node.a, out)
			b := walk(src, node.b, out)
			node.a, node.b = a, b
		}
		out.nodes[at] = node
		return at
	}
	_ = walk(&src, root, &out)
	return
}

// After pane `closed` went, the last pane takes its number so the panes shown stay 0 to
// n-1, and `was` says where each view pane's view came from (the view pane now numbered
// i + 1 was `was[i]` + 1): every other pane keeps its number, its view and its colour.
grid_tree_fill :: proc(t: ^Grid_Tree, closed: int) -> (was: [GRID_VIEWS]int) {
	for i in 0 ..< GRID_VIEWS do was[i] = i
	last := 0
	for d in t.nodes[:t.count] do if !d.split do last = max(last, int(d.pane))
	if closed <= 0 || closed >= last do return
	if at := grid_tree_leaf(t, last); at >= 0 {
		t.nodes[at].pane = u8(closed)
		was[closed - 1], was[last - 1] = last - 1, closed - 1
	}
	return
}

// The tree a preset lays out, with its default splits.
grid_preset_tree :: proc(preset: Grid_Preset) -> Grid_Tree {
	t: Grid_Tree
	root: u8
	switch preset {
	case .Single:
		root = grid_leaf(&t, 0)
	case .Side_By_Side:
		l0 := grid_leaf(&t, 0)
		root = grid_cut(&t, true, 0.5, l0, grid_leaf(&t, 1))
	case .Stacked:
		l0 := grid_leaf(&t, 0)
		root = grid_cut(&t, false, 0.5, l0, grid_leaf(&t, 1))
	case .One_Plus_Two:
		l0, l1 := grid_leaf(&t, 0), grid_leaf(&t, 1)
		right := grid_cut(&t, false, 0.5, l1, grid_leaf(&t, 2))
		root = grid_cut(&t, true, 0.6, l0, right)
	case .Four:
		l0, l1 := grid_leaf(&t, 0), grid_leaf(&t, 1)
		top := grid_cut(&t, true, 0.5, l0, l1)
		l2, l3 := grid_leaf(&t, 2), grid_leaf(&t, 3)
		bottom := grid_cut(&t, true, 0.5, l2, l3)
		root = grid_cut(&t, false, 0.5, top, bottom)
	case .Three_Across:
		l0, l1 := grid_leaf(&t, 0), grid_leaf(&t, 1)
		rest := grid_cut(&t, true, 0.5, l1, grid_leaf(&t, 2))
		root = grid_cut(&t, true, 1.0 / 3, l0, rest)
	}
	return grid_tree_normal(t, root)
}

// Whether two trees split the same way, whatever their shares and panes.
grid_tree_same_shape :: proc(a, b: ^Grid_Tree) -> bool {
	if a.count != b.count do return false
	for i in 0 ..< a.count {
		x, y := a.nodes[i], b.nodes[i]
		if x.split != y.split || (x.split && (x.vertical != y.vertical || x.a != y.a || x.b != y.b)) do return false
	}
	return true
}

// The preset the grid's tree is laid out as, with `ok` false for a layout of its own.
grid_shape :: proc(g: ^View_Grid) -> (preset: Grid_Preset, ok: bool) {
	for p in Grid_Preset {
		t := grid_preset_tree(p)
		if grid_tree_same_shape(&g.tree, &t) do return p, true
	}
	return .Single, false
}

// The shape's name for menus and the exit stats: the preset's, or Custom.
grid_shape_name :: proc(g: ^View_Grid) -> string {
	p, ok := grid_shape(g)
	return fmt.tprint(p) if ok else "Custom"
}

// `r` cut at share `s` with `gap` between the parts: the left (or top) part, then the rest.
grid_cut_rect :: proc(r: ui.Rect, vertical: bool, s, gap: f32) -> (a, b: ui.Rect) {
	if vertical {
		w := r.w * s - gap * 0.5
		return {r.x, r.y, w, r.h}, {r.x + w + gap, r.y, r.w - w - gap, r.h}
	}
	h := r.h * s - gap * 0.5
	return {r.x, r.y, r.w, h}, {r.x, r.y + h + gap, r.w, r.h - h - gap}
}

// The panes' rects in `room` by pane, with `gap` between neighbours (the rest of the four
// are empty), and each node's room.
grid_tree_cells :: proc(t: ^Grid_Tree, room: ui.Rect, gap: f32 = GRID_GAP) -> (cells: [GRID_PANES]ui.Rect, rooms: [GRID_NODES]ui.Rect) {
	lay :: proc(t: ^Grid_Tree, n: u8, r: ui.Rect, gap: f32, cells: ^[GRID_PANES]ui.Rect, rooms: ^[GRID_NODES]ui.Rect) {
		rooms[n] = r
		node := t.nodes[n]
		if !node.split {
			cells[node.pane] = r
			return
		}
		a, b := grid_cut_rect(r, node.vertical, node.share, gap)
		lay(t, node.a, a, gap, cells, rooms)
		lay(t, node.b, b, gap, cells, rooms)
	}
	if t.count == 0 {
		cells[0] = room
		return
	}
	lay(t, 0, room, gap, &cells, &rooms)
	return
}

// The panes' rects as shares of a room one by one, without gaps, where edges compare.
grid_tree_unit :: proc(t: ^Grid_Tree) -> (cells: [GRID_PANES]ui.Rect, rooms: [GRID_NODES]ui.Rect) {
	return grid_tree_cells(t, {0, 0, 1, 1}, 0)
}

// Where split `n`'s cut lies across a room one by one, along its axis.
grid_tree_line :: proc(t: ^Grid_Tree, rooms: [GRID_NODES]ui.Rect, n: int) -> f32 {
	r := rooms[n]
	if t.nodes[n].vertical do return r.x + r.w * t.nodes[n].share
	return r.y + r.h * t.nodes[n].share
}

// The leaf showing `pane`, or -1.
grid_tree_leaf :: proc(t: ^Grid_Tree, pane: int) -> int {
	for node, i in t.nodes[:t.count] do if !node.split && int(node.pane) == pane do return i
	return -1
}

// The split whose child `n` is, or -1 for the root.
grid_tree_parent :: proc(t: ^Grid_Tree, n: int) -> int {
	for node, i in t.nodes[:t.count] do if node.split && (int(node.a) == n || int(node.b) == n) do return i
	return -1
}

// Whether node `n`'s part of the tree holds node `m`.
grid_tree_holds :: proc(t: ^Grid_Tree, n, m: int) -> bool {
	if n == m do return true
	node := t.nodes[n]
	return node.split && (grid_tree_holds(t, int(node.a), m) || grid_tree_holds(t, int(node.b), m))
}

// The pane under point `p` of a room one by one, or -1.
grid_tree_pane_at :: proc(t: ^Grid_Tree, p: [2]f32) -> int {
	cells, _ := grid_tree_unit(t)
	for i in 0 ..< grid_tree_panes(t) {
		c := cells[i]
		if p.x >= c.x && p.x <= c.x + c.w && p.y >= c.y && p.y <= c.y + c.h do return i
	}
	return -1
}

// Puts tree `t` in place of the grid's, the view panes moving as `was` says (from
// grid_tree_fill; the pictures follow in grid_pictures_follow), and counts the change.
grid_tree_set :: proc(g: ^View_Grid, t: Grid_Tree, was: [GRID_VIEWS]int = {0, 1, 2}) {
	old := g.views
	for i in 0 ..< GRID_VIEWS do g.views[i] = old[was[i]]
	g.tree = t
	g.maximised = 0
	g.serial += 1
	if was != {0, 1, 2} do g.was, g.moved = was, true
}

// Splits pane `pane` in two across (a cut up and down with `vertical`) at share `share`
// of it, the new pane first (left or above) with `first`. The new pane, numbered after
// the others, shows `view`. Returns its number, or 0 when the grid has its four panes.
grid_split_pane :: proc(g: ^View_Grid, pane: int, vertical: bool, share: f32, first: bool, view: Second_View) -> int {
	n := grid_panes(g)
	at := grid_tree_leaf(&g.tree, pane)
	if n >= GRID_PANES || at < 0 do return 0
	t := g.tree
	old := grid_leaf(&t, pane)
	added := grid_leaf(&t, n)
	a, b := old, added
	if first do a, b = added, old
	t.nodes[at] = {split = true, vertical = vertical, share = clamp(share, GRID_PANE_MIN, 1 - GRID_PANE_MIN), a = a, b = b}
	g.views[n - 1] = view
	grid_tree_set(g, grid_tree_normal(t, 0))
	return n
}

// Joins pane `close` into pane `keep`, which grows over it, when they share a whole edge;
// the main view never closes.
grid_join :: proc(g: ^View_Grid, keep, close: int) -> bool {
	if !grid_joinable(g, keep, close) do return false
	cells, _ := grid_tree_unit(&g.tree)
	n := grid_panes(g)
	panes: [GRID_PANES]int
	rects: [GRID_PANES]ui.Rect
	m := 0
	for i in 0 ..< n {
		if i == close do continue
		r := cells[i]
		if i == keep {
			c := cells[close]
			x0, y0 := min(r.x, c.x), min(r.y, c.y)
			r = {x0, y0, max(r.x + r.w, c.x + c.w) - x0, max(r.y + r.h, c.y + c.h) - y0}
		}
		panes[m], rects[m] = i, r
		m += 1
	}
	t: Grid_Tree
	root, ok := grid_tree_from_rects(&t, panes[:m], rects[:m])
	if !ok do return false
	t = grid_tree_normal(t, root)
	grid_tree_set(g, t, grid_tree_fill(&t, close))
	return true
}

// How near two edges, as shares of the room, count as one: wider than the thousandths a
// layout keeps its shares in, so panes lined up stay lined up after a restart.
GRID_EDGE_NEAR :: 2e-3

// Whether pane `close` may join pane `keep`: two panes shown, not the main view closing,
// and their union a rectangle.
grid_joinable :: proc(g: ^View_Grid, keep, close: int) -> bool {
	n := grid_panes(g)
	if keep == close || close == 0 || keep < 0 || close < 0 || keep >= n || close >= n do return false
	cells, _ := grid_tree_unit(&g.tree)
	a, b := cells[keep], cells[close]
	same :: proc(x, y: f32) -> bool {return abs(x - y) < GRID_EDGE_NEAR}
	if same(a.y, b.y) && same(a.h, b.h) && (same(a.x + a.w, b.x) || same(b.x + b.w, a.x)) do return true
	if same(a.x, b.x) && same(a.w, b.w) && (same(a.y + a.h, b.y) || same(b.y + b.h, a.y)) do return true
	return false
}

// Builds a tree over panes laid out as `rects` (shares of a room one by one) by cutting
// where no rect crosses, up and down first. A join leaves at most three panes, which tile
// their room one way only, so the cut found is the only one.
@(private = "file")
grid_tree_from_rects :: proc(t: ^Grid_Tree, panes: []int, rects: []ui.Rect) -> (root: u8, ok: bool) {
	if len(panes) == 1 do return grid_leaf(t, panes[0]), true
	E :: GRID_EDGE_NEAR
	lo, hi := [2]f32{2, 2}, [2]f32{-1, -1}
	for r in rects {
		lo = {min(lo.x, r.x), min(lo.y, r.y)}
		hi = {max(hi.x, r.x + r.w), max(hi.y, r.y + r.h)}
	}
	for axis in 0 ..< 2 {
		for r in rects {
			cut := r.x + r.w if axis == 0 else r.y + r.h
			if cut >= hi[axis] - E do continue
			// Every rect lies wholly before or after the cut.
			fits := true
			for q in rects {
				start := q.x if axis == 0 else q.y
				end := q.x + q.w if axis == 0 else q.y + q.h
				if end > cut + E && start < cut - E do fits = false
			}
			if !fits do continue
			pa, pb: [GRID_PANES]int
			ra, rb: [GRID_PANES]ui.Rect
			na, nb := 0, 0
			for q, i in rects {
				start := q.x if axis == 0 else q.y
				if start < cut - E {
					pa[na], ra[na] = panes[i], q
					na += 1
				} else {
					pb[nb], rb[nb] = panes[i], q
					nb += 1
				}
			}
			a := grid_tree_from_rects(t, pa[:na], ra[:na]) or_return
			b := grid_tree_from_rects(t, pb[:nb], rb[:nb]) or_return
			share := (cut - lo[axis]) / max(hi[axis] - lo[axis], E)
			return grid_cut(t, axis == 0, share, a, b), true
		}
	}
	return 0, false
}

// Swaps panes `p` and `q`: each, its view and its colour, shows where the other was.
grid_swap :: proc(g: ^View_Grid, p, q: int) -> bool {
	n := grid_panes(g)
	if p == q || p < 0 || q < 0 || p >= n || q >= n do return false
	t := g.tree
	a, b := grid_tree_leaf(&t, p), grid_tree_leaf(&t, q)
	t.nodes[a].pane, t.nodes[b].pane = u8(q), u8(p)
	grid_tree_set(g, t)
	return true
}

// Grid_Edge: a side of a pane another is docked against.
Grid_Edge :: enum u8 {
	Left,
	Right,
	Top,
	Bottom,
}

// Moves pane `pane` out of where it is and docks it on `edge` of pane `target`, which
// gives it half its room; where it was, its neighbour grows over.
grid_dock :: proc(g: ^View_Grid, pane, target: int, edge: Grid_Edge) -> bool {
	n := grid_panes(g)
	if pane == target || pane < 0 || target < 0 || pane >= n || target >= n do return false
	t := g.tree
	at := grid_tree_leaf(&t, pane)
	parent := grid_tree_parent(&t, at)
	if parent < 0 do return false
	sibling := t.nodes[parent].b if int(t.nodes[parent].a) == at else t.nodes[parent].a
	t.nodes[parent] = t.nodes[sibling]
	t = grid_tree_normal(t, 0)
	into := grid_tree_leaf(&t, target)
	moved := grid_leaf(&t, pane)
	kept := grid_leaf(&t, target)
	vertical := edge == .Left || edge == .Right
	first := edge == .Left || edge == .Top
	t.nodes[into] = {split = true, vertical = vertical, share = 0.5, a = moved if first else kept, b = kept if first else moved}
	grid_tree_set(g, grid_tree_normal(t, 0))
	return true
}

// Closes split `n`'s side `b` (or `a`), the other growing over it; never the main view's.
grid_close_side :: proc(g: ^View_Grid, n: int, close_b: bool) -> bool {
	t := g.tree
	if n < 0 || n >= t.count || !t.nodes[n].split do return false
	node := t.nodes[n]
	closed, kept := node.b if close_b else node.a, node.a if close_b else node.b
	if grid_tree_holds(&t, int(closed), grid_tree_leaf(&t, 0)) do return false
	// The panes on the closed side go, the last ones shown taking their numbers.
	gone: [GRID_PANES]int
	m := 0
	for d, i in t.nodes[:t.count] do if !d.split && grid_tree_holds(&t, int(closed), i) {
		gone[m] = int(d.pane)
		m += 1
	}
	t.nodes[n] = t.nodes[kept]
	t = grid_tree_normal(t, 0)
	// Highest first, so a number filled is never one still to go.
	slice.reverse_sort(gone[:m])
	was := [GRID_VIEWS]int{0, 1, 2}
	for p in gone[:m] {
		step := grid_tree_fill(&t, p)
		was = {was[step[0]], was[step[1]], was[step[2]]}
	}
	grid_tree_set(g, t, was)
	return true
}

// Whether closing split `n`'s side `b` (or `a`) would leave the main view: not when the
// main view is on that side.
grid_side_closes :: proc(t: ^Grid_Tree, n: int, close_b: bool) -> bool {
	if n < 0 || n >= t.count || !t.nodes[n].split do return false
	side := t.nodes[n].b if close_b else t.nodes[n].a
	return !grid_tree_holds(t, int(side), grid_tree_leaf(t, 0))
}

// Split `n`'s sides trade places.
grid_swap_sides :: proc(g: ^View_Grid, n: int) -> bool {
	t := g.tree
	if n < 0 || n >= t.count || !t.nodes[n].split do return false
	node := &t.nodes[n]
	node.a, node.b = node.b, node.a
	node.share = 1 - node.share
	grid_tree_set(g, grid_tree_normal(t, 0))
	return true
}

// Evens out split `n` and the run of splits the same way inside it, so each pane along it
// gets as much: three across goes to thirds.
grid_even :: proc(g: ^View_Grid, n: int) {
	t := &g.tree
	if n < 0 || n >= t.count || !t.nodes[n].split do return
	along :: proc(t: ^Grid_Tree, n: u8, vertical: bool) -> int {
		node := t.nodes[n]
		if !node.split || node.vertical != vertical do return 1
		return along(t, node.a, vertical) + along(t, node.b, vertical)
	}
	even :: proc(t: ^Grid_Tree, n: u8, vertical: bool) {
		node := &t.nodes[n]
		if !node.split || node.vertical != vertical do return
		a, b := along(t, node.a, vertical), along(t, node.b, vertical)
		node.share = f32(a) / f32(a + b)
		even(t, node.a, vertical)
		even(t, node.b, vertical)
	}
	even(t, u8(n), t.nodes[n].vertical)
	g.serial += 1
}

// How far split `n`'s cut may go across a room one by one: each pane keeps `least` of it,
// with the cuts the same way inside it staying where they are.
grid_divider_range :: proc(t: ^Grid_Tree, n: int, least: f32 = GRID_PANE_MIN) -> (lo, hi: f32) {
	_, rooms := grid_tree_unit(t)
	node := t.nodes[n]
	r := rooms[n]
	lo = (r.x if node.vertical else r.y) + least
	hi = (r.x + r.w if node.vertical else r.y + r.h) - least
	for d, i in t.nodes[:t.count] {
		if i == n || !d.split || d.vertical != node.vertical do continue
		line := grid_tree_line(t, rooms, i)
		if grid_tree_holds(t, int(node.a), i) do lo = max(lo, line + least)
		if grid_tree_holds(t, int(node.b), i) do hi = min(hi, line - least)
	}
	return
}

// Moves split `n`'s cut to `line` across a room one by one (within grid_divider_range),
// keeping the cuts the same way inside it where they were.
grid_move_divider :: proc(t: ^Grid_Tree, n: int, line: f32, least: f32 = GRID_PANE_MIN) {
	if n < 0 || n >= t.count || !t.nodes[n].split do return
	lo, hi := grid_divider_range(t, n, least)
	if lo > hi do return
	_, rooms := grid_tree_unit(t)
	lines: [GRID_NODES]f32
	for d, i in t.nodes[:t.count] do if d.split do lines[i] = grid_tree_line(t, rooms, i)
	vertical := t.nodes[n].vertical
	set :: proc(t: ^Grid_Tree, rooms: [GRID_NODES]ui.Rect, i: int, line: f32) {
		r := rooms[i]
		start, size := r.y, r.h
		if t.nodes[i].vertical do start, size = r.x, r.w
		t.nodes[i].share = clamp((line - start) / max(size, 1e-4), GRID_PANE_MIN, 1 - GRID_PANE_MIN)
	}
	set(t, rooms, n, clamp(line, lo, hi))
	// The nodes run in depth-first order, so each is put back after the splits around it.
	for i in n + 1 ..< t.count {
		d := t.nodes[i]
		if !d.split || d.vertical != vertical || !grid_tree_holds(t, n, i) do continue
		_, rooms = grid_tree_unit(t)
		set(t, rooms, i, lines[i])
	}
}

// The splits whose cuts line up with split `n`'s, the same way and on the same line, `n`
// among them: what Shift moves together.
grid_lined_up :: proc(t: ^Grid_Tree, n: int) -> (out: [GRID_NODES]bool) {
	_, rooms := grid_tree_unit(t)
	line := grid_tree_line(t, rooms, n)
	for d, i in t.nodes[:t.count] {
		if d.split && d.vertical == t.nodes[n].vertical && abs(grid_tree_line(t, rooms, i) - line) < 1e-3 do out[i] = true
	}
	return
}

// The view panes a preset starts with: the partner a sculptor wants beside the main view.
grid_views_default :: proc(preset: Grid_Preset) -> (views: [GRID_VIEWS]Second_View) {
	for &v in views do v.pass = .Shaded
	switch preset {
	case .Single:
	case .Side_By_Side, .Stacked:
		views[0].camera = .Front
	case .One_Plus_Two, .Three_Across:
		views[0].camera, views[1].camera = .Front, .Right
	case .Four:
		views[0].camera, views[1].camera, views[2].camera = .Front, .Right, .Top
	}
	return
}

// Puts the grid back as a new user finds it: one view.
grid_reset :: proc(g: ^View_Grid) {
	g.tree, g.maximised = grid_preset_tree(.Single), 0
	g.views = grid_views_default(.Four)
	g.serial += 1
}

// A layout's grid lines (workspaces.odin): none for one pane, so every layout saved
// before the grid reads as it was; else the tree, then each view pane's camera and pass.
// A Free camera's turn is not kept, as the second view's is not.
grid_layout_lines :: proc(k: ^Kit_State) -> string {
	g := &k.grid
	n := grid_panes(g)
	if n == 1 do return ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "panes ")
	grid_tree_write(&b, &g.tree)
	strings.write_byte(&b, '\n')
	for v, i in g.views[:n - 1] do fmt.sbprintf(&b, "pane %d %v %v\n", i + 1, v.camera, v.pass)
	return strings.to_string(b)
}

// The tree in prefix order: `v` or `h` and the share in thousandths for a split (which
// reads back exactly, so the modified dot clears), the pane's number for a leaf.
grid_tree_write :: proc(b: ^strings.Builder, t: ^Grid_Tree) {
	walk :: proc(b: ^strings.Builder, t: ^Grid_Tree, n: u8, first: bool) {
		node := t.nodes[n]
		if !first do strings.write_byte(b, ' ')
		if !node.split {
			fmt.sbprintf(b, "%d", node.pane)
			return
		}
		fmt.sbprintf(b, "%c%d", 'v' if node.vertical else 'h', int(math.round(node.share * 1000)))
		walk(b, t, node.a, false)
		walk(b, t, node.b, false)
	}
	if t.count > 0 do walk(b, t, 0, true)
}

// Reads a tree written by grid_tree_write; `ok` false for words that are no such tree
// (a pane twice, more than four, none the main view, a share out of range).
grid_tree_read :: proc(words: []string) -> (t: Grid_Tree, ok: bool) {
	at := 0
	seen: bit_set[0 ..< GRID_PANES]
	read :: proc(words: []string, at: ^int, t: ^Grid_Tree, seen: ^bit_set[0 ..< GRID_PANES]) -> (n: u8, ok: bool) {
		if at^ >= len(words) || t.count >= GRID_NODES do return 0, false
		w := words[at^]
		at^ += 1
		if len(w) > 1 && (w[0] == 'v' || w[0] == 'h') {
			s := strconv.parse_int(w[1:]) or_return
			if s <= 0 || s >= 1000 do return 0, false
			// The split goes in before its children, as the normal form has it.
			me := grid_cut(t, w[0] == 'v', clamp(f32(s) / 1000, GRID_PANE_MIN, 1 - GRID_PANE_MIN), 0, 0)
			a := read(words, at, t, seen) or_return
			b := read(words, at, t, seen) or_return
			t.nodes[me].a, t.nodes[me].b = a, b
			return me, true
		}
		p := strconv.parse_int(w) or_return
		if p < 0 || p >= GRID_PANES || p in seen^ do return 0, false
		seen^ += {p}
		return grid_leaf(t, p), true
	}
	_ = read(words, &at, &t, &seen) or_return
	n := card(seen)
	if at != len(words) || 0 not_in seen do return {}, false
	for p in 0 ..< n do if p not_in seen do return {}, false
	return t, true
}

// The tree an old layout's `grid <preset> <x> <y>` line meant: the preset with its splits,
// where three across's second was a share of the whole room.
@(private = "file")
grid_tree_of_old :: proc(preset: Grid_Preset, s: [2]f32) -> Grid_Tree {
	t := grid_preset_tree(preset)
	switch preset {
	case .Single:
	case .Side_By_Side:
		t.nodes[0].share = s.x
	case .Stacked:
		t.nodes[0].share = s.y
	case .One_Plus_Two:
		t.nodes[0].share, t.nodes[2].share = s.x, s.y
	case .Four:
		t.nodes[0].share, t.nodes[1].share, t.nodes[4].share = s.y, s.x, s.x
	case .Three_Across:
		t.nodes[0].share = s.x
		t.nodes[2].share = clamp((s.y - s.x) / max(1 - s.x, 1e-3), GRID_PANE_MIN, 1 - GRID_PANE_MIN)
	}
	return t
}

// Reads a layout's panes, grid or pane line's words; a word naming nothing leaves what it
// named.
grid_layout_read :: proc(g: ^View_Grid, f: []string) {
	switch {
	case f[0] == "panes" && len(f) >= 2:
		t, ok := grid_tree_read(f[1:])
		if !ok do return
		g.tree, g.maximised = t, 0
		g.views = grid_views_default(.Four)
		g.serial += 1
	case f[0] == "grid" && len(f) >= 2:
		preset := Grid_Preset.Single
		for p in Grid_Preset do if strings.equal_fold(fmt.tprint(p), f[1]) do preset = p
		s := [2]f32{0.5, 0.5}
		if preset == .One_Plus_Two do s.x = 0.6
		if preset == .Three_Across do s = {1.0 / 3, 2.0 / 3}
		if len(f) >= 4 {
			x, okx := strconv.parse_int(f[2])
			y, oky := strconv.parse_int(f[3])
			if okx && oky && x > 0 && x < 1000 && y > 0 && y < 1000 do s = {clamp(f32(x) / 1000, 0.15, 0.85), clamp(f32(y) / 1000, 0.15, 0.85)}
		}
		g.tree, g.maximised = grid_tree_of_old(preset, s), 0
		// Its panes start as the preset's partners; the pane lines after it say otherwise.
		g.views = grid_views_default(preset)
		g.serial += 1
	case f[0] == "pane" && len(f) >= 4:
		i, ok := strconv.parse_int(f[1])
		if !ok || i < 1 || i > GRID_VIEWS do return
		v := &g.views[i - 1]
		for c in Second_Camera do if strings.equal_fold(fmt.tprint(c), f[2]) do v.camera = c
		for p in Second_Pass do if strings.equal_fold(fmt.tprint(p), f[3]) do v.pass = p
	}
}

// A layout's text with an old `grid` line written as the tree it reads as, a `panes`
// line; the rest as it was.
grid_layout_upgrade :: proc(text: string) -> string {
	if !strings.contains(text, "grid ") do return text
	b := strings.builder_make(context.temp_allocator)
	lines := strings.split_lines(text, context.temp_allocator)
	for line, i in lines {
		f := strings.fields(line, context.temp_allocator)
		if len(f) > 0 && f[0] == "grid" {
			g: View_Grid
			grid_layout_read(&g, f)
			if grid_panes(&g) > 1 {
				strings.write_string(&b, "panes ")
				grid_tree_write(&b, &g.tree)
			}
		} else {
			strings.write_string(&b, line)
		}
		if i + 1 < len(lines) do strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Shows the grid in `preset` with its default splits; panes already shown keep their
// views and the rest start as the preset's partners. The shape already shown stays as it
// is. A pane that filled the grid gives the room back.
grid_set :: proc(k: ^Kit_State, preset: Grid_Preset) -> (added: int, changed: bool) {
	g := &k.grid
	g.maximised = 0
	if p, ok := grid_shape(g); ok && p == preset do return 0, false
	had := grid_panes(g)
	g.tree = grid_preset_tree(preset)
	g.serial += 1
	partners := grid_views_default(preset)
	for i in had ..< grid_count(preset) do g.views[i - 1] = partners[i - 1]
	return had, true
}

// The grid's room in points: the whole window, the panes running under the panels.
view_grid_room :: proc(app: ^App) -> ui.Rect {
	win := app.kit.ctx.input.window
	return {0, 0, win.x, win.y}
}

// Where a docked left column ends, so a pane's head that would lie under it starts right of
// it instead while the panes run under the panels; 0 with none.
grid_left_column_edge :: proc(app: ^App) -> f32 {
	k := &app.kit
	edge: f32 = 0
	for side in Column_Side {
		c := k.panels.rect[side]
		if c.w > 0 && c.x + c.w * 0.5 < k.ctx.input.window.x * 0.5 do edge = max(edge, c.x + c.w + GRID_COLUMN_GAP)
	}
	return edge
}

// Points between a docked column and the grid.
GRID_COLUMN_GAP :: 8

// A divider: the gap it lies along, the split it moves, its direction and the split's room.
Grid_Divider :: struct {
	line:     ui.Rect,
	node:     int,
	vertical: bool,
	room:     ui.Rect,
}

// The tree's dividers, one a split, along its panes' gaps.
grid_dividers :: proc(t: ^Grid_Tree, rooms: [GRID_NODES]ui.Rect) -> (out: [GRID_PANES - 1]Grid_Divider, n: int) {
	for node, i in t.nodes[:t.count] {
		if !node.split do continue
		a, _ := grid_cut_rect(rooms[i], node.vertical, node.share, GRID_GAP)
		r := rooms[i]
		line := ui.Rect{a.x + a.w, r.y, GRID_GAP, r.h} if node.vertical else ui.Rect{r.x, a.y + a.h, r.w, GRID_GAP}
		out[n] = {line, i, node.vertical, r}
		n += 1
	}
	return
}

// Lays out the grid under every panel: the viewport's image in the main pane, each view
// pane with its picture, its camera and pass and Maximise, and the dividers. Sets where
// the main pane goes (k.grid.main) and each picture's size.
kit_grid :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	if g.tree.count == 0 do grid_reset(g)
	// What a gesture queued last frame, before anything is laid out from the tree.
	grid_op_apply(app)
	grid_pictures_follow(app)
	room := view_grid_room(app)
	cells, rooms := grid_tree_cells(&g.tree, room)
	n := grid_panes(g)
	if g.maximised >= n do g.maximised = 0
	// Each pane on whole pixels, so the main view's input size and its target's agree
	// exactly and its unsmoothed image never shimmers; a maximised pane's room too, since
	// the main view may be drawn there while it is worked in.
	if n > 1 {
		px := ctx.input.pixel_density
		snap :: proc(c: ui.Rect, px: f32) -> ui.Rect {
			x0, y0 := math.round(c.x * px) / px, math.round(c.y * px) / px
			x1, y1 := math.round((c.x + c.w) * px) / px, math.round((c.y + c.h) * px) / px
			return {x0, y0, x1 - x0, y1 - y0}
		}
		for &c in cells[:n] do c = snap(c, px)
		room = snap(room, px)
	}
	grid_work(app, n)
	g.main = cells[0]
	if g.work != 0 do g.main = room if g.maximised == g.work else cells[g.work]
	// While a view pane is worked in, the main pane holds the picture it showed as the
	// gesture began, and the main view is drawn in the view pane (kit_view_pane).
	if g.work == 0 do ui.image(ctx, g.main, KIT_VIEWPORT_IMAGE)
	else do ui.image(ctx, cells[0], KIT_WORK_STILL_IMAGE)
	// With other panes beside it, the main pane is outlined in the main camera's colour, the
	// colour of the dots of the panes linked to it: the pane the tools act in.
	if n > 1 && g.maximised == 0 {
		m := cells[0]
		ui.stroke_rect(ctx, {m.x + 1, m.y + 1, m.w - 2, m.h - 2}, 0, ctx.theme.camera[0], 2)
	}
	// What is drawn over the main view (overlay.odin) goes here, under the view panes; over
	// the view pane worked in instead, which marks it after its picture.
	if g.work == 0 {
		k.layer = ui.layer_mark(ctx)
		kit_wipe(app, g.main)
	}
	guides_frame(app)
	kit_guides(app, cells[0], main_camera(app), "main")
	// While a divider is dragged the pictures keep their size, stretched, as the main
	// view's does: each is drawn again at its new size once it is let go.
	resizing := g.dragged != 0
	if !resizing do g.px = {}
	d := ctx.input.pixel_density
	for i in 1 ..< n {
		if g.maximised != 0 && g.maximised != i do continue
		r := room if g.maximised == i else cells[i]
		if !resizing do g.px[i - 1] = {u32(r.w * d + 0.5), u32(r.h * d + 0.5)}
		kit_view_pane(app, i, r)
	}
	// The corner handles under the panes' heads, whose chips win where the two meet.
	if g.maximised == 0 do lens_pane_corners(app, cells, n)
	for i in 1 ..< n {
		if g.maximised != 0 && g.maximised != i do continue
		r := room if g.maximised == i else cells[i]
		lens_pane_head(app, i, grid_head_at(app, r), r, cells, n)
	}
	if g.maximised != 0 do return
	dividers, count := grid_dividers(&g.tree, rooms)
	was := g.dragged
	g.dragged = 0
	for div in dividers[:count] {
		i := div.node
		grab := div.line
		// The dividers are wide to hold, for a finger.
		span: f32 = GRID_GRAB_LENS
		if div.vertical do grab.x, grab.w = grab.x + grab.w * 0.5 - span * 0.5, span
		else do grab.y, grab.h = grab.y + grab.h * 0.5 - span * 0.5, span
		ui.begin_at(ctx, fmt.tprintf("grid divider %d", i), {grab.x, grab.y}, {width = grab.w, height = grab.h})
		a := ui.area(ctx, "grab", {grab.w, grab.h})
		if ui.secondary(ctx) do divider_menu_open(app, i, a.mouse)
		t := ctx.theme
		color := t.accent if a.held else t.border_strong if a.hovered else t.frame
		ui.fill_rect(ctx, div.line, 0, color)
		grid_divider_lens(app, div, a, cells)
		if a.held do grid_divider_drag(app, div, a.mouse, room, was == i + 1)
		ui.end(ctx)
	}
	// A drag let go that moved its divider is a layout step.
	if was != 0 && g.dragged == 0 && g.areas.held {
		g.areas.held = false
		if g.areas.held_step.tree != g.tree do grid_step_push(g, g.areas.held_step)
	}
	lens_areas_overlay(app, cells, n)
}

// Divider `div` held at `m`: its cut follows, the cuts inside it staying where they are,
// every pane keeping GRID_PANE_MIN of the room and GRID_PANE_MIN_PT. Ctrl snaps to a
// quarter, a third or a half of the split's room; Shift moves the dividers lined up with
// it together.
@(private = "file")
grid_divider_drag :: proc(app: ^App, div: Grid_Divider, m: [2]f32, room: ui.Rect, going: bool) {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	if !going {
		g.areas.held, g.areas.held_step = true, grid_step_now(g)
	}
	g.dragged = div.node + 1
	size := room.w if div.vertical else room.h
	start := room.x if div.vertical else room.y
	least := max(GRID_PANE_MIN, GRID_PANE_MIN_PT / max(size, 1))
	line := ((m.x if div.vertical else m.y) - start) / max(size, 1)
	if ctx.input.ctrl {
		r := div.room
		r0, rs := (r.x - start) / max(size, 1), r.w / max(size, 1)
		if !div.vertical do r0, rs = (r.y - start) / max(size, 1), r.h / max(size, 1)
		s := (line - r0) / max(rs, 1e-4)
		best: f32 = 0.5
		for f in ([]f32{0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75}) do if abs(f - s) < abs(best - s) do best = f
		line = r0 + best * rs
	}
	before := g.tree
	if ctx.input.shift {
		lined := grid_lined_up(&g.tree, div.node)
		lo, hi := f32(0), f32(1)
		for on, j in lined do if on {
			a, b := grid_divider_range(&g.tree, j, least)
			lo, hi = max(lo, a), min(hi, b)
		}
		line = clamp(line, lo, hi)
		for on, j in lined do if on do grid_move_divider(&g.tree, j, line, least)
	} else {
		grid_move_divider(&g.tree, div.node, line, least)
	}
	if g.tree != before do g.drags += 1
}

// Where a view pane's head stands in pane rect `r`: its top left corner, clear of the top
// bar, the brush bar and a docked left column.
grid_head_at :: proc(app: ^App, r: ui.Rect) -> [2]f32 {
	return {max(r.x, kit_left(app), grid_left_column_edge(app)) + 6, max(r.y, kit_top() - 8) + 6}
}

// A view pane at `r`: its picture, which a drag turns and the wheel zooms, and its guides.
@(private = "file")
kit_view_pane :: proc(app: ^App, i: int, r: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	g := &k.grid
	sv := &g.views[i - 1]
	ui.begin_at(ctx, fmt.tprintf("view pane %d", i), {r.x, r.y}, {width = r.w, height = r.h})
	a := ui.area(ctx, "picture", {r.w, r.h})
	working := g.work == i
	if working {
		ui.image(ctx, a.rect, KIT_VIEWPORT_IMAGE)
	} else {
		ui.fill_rect(ctx, a.rect, 0, t.pane)
		if app.panes[i - 1].shown != nil do ui.image(ctx, a.rect, KIT_PANE_IMAGE + u64(i - 1))
		second_view_input(app, ctx, k.scale, sv, a)
	}
	ui.end(ctx)
	if working {
		k.layer = ui.layer_mark(ctx)
		kit_guides(app, r, app.camera, fmt.tprintf("pane %d", i))
	} else if app.panes[i - 1].shown != nil {
		kit_guides(app, r, app.panes[i - 1].orbit, fmt.tprintf("pane %d", i))
	}
	// Its head comes after the corner handles (kit_grid: lens_pane_head).
}

// A view's camera dot and Camera select, in a view window's head row, in the interface
// `ctx` it is laid out in; `index` picks its own colour.
view_head_camera :: proc(app: ^App, ctx: ^ui.Context, sv: ^Second_View, index: int) {
	dot, ring := second_color(ctx.theme, sv, index)
	camera_dot(ctx, dot, ring)
	cameras := make([]string, len(Second_Camera), context.temp_allocator)
	for name, c in SECOND_CAMERA_NAMES do cameras[c] = name
	if picked := ui.select(ctx, "Camera", cameras, int(sv.camera), GRID_SELECT_W); picked >= 0 && Second_Camera(picked) != sv.camera {
		if Second_Camera(picked) == .Free do second_free(app, sv)
		else do sv.camera = Second_Camera(picked)
	}
}

// A view's Shows select.
view_head_pass :: proc(ctx: ^ui.Context, sv: ^Second_View) {
	passes := make([]string, len(Second_Pass), context.temp_allocator)
	for name, kind in SECOND_PASS_NAMES do passes[kind] = name
	if picked := ui.select(ctx, "Shows", passes, int(sv.pass), GRID_SELECT_W); picked >= 0 do sv.pass = Second_Pass(picked)
}

// A view's link button: links an independent view to the main camera, or lets a linked one go.
view_head_link :: proc(app: ^App, ctx: ^ui.Context, sv: ^Second_View) {
	linked := second_linked(sv)
	if ui.icon_button(ctx, "Unlink from the main camera" if linked else "Link to the main camera", ICON_LINK, selected = linked) do second_link_toggle(app, sv)
}

// Lucide's monitor-up: a view opened in a window of its own (view_window.odin).
ICON_VIEW_WINDOW :: rune(0xe427)

// A view pane's selects, in points: room for "Curvature" and "Mirrored".
GRID_SELECT_W :: 116

// Lucide's link: a view's camera tied to the main one.
ICON_LINK :: rune(0xe108)

// Draws each view pane shown whose picture is due, as the second view does (thumbnail.odin),
// but the one worked in, where the main view is drawn.
grid_frame :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item) {
	k := &app.kit
	for &pic, i in app.panes {
		size := k.grid.px[i]
		if k.home || size.x == 0 || size.y == 0 {
			pic.shown, pic.due = nil, false
			continue
		}
		if k.grid.work == i + 1 do continue
		picture_frame(app, cmd, draws, &k.grid.views[i], &pic, size, 1)
	}
}

// Whether a view pane waits to be drawn again, which keeps the frames coming.
grid_due :: proc(app: ^App) -> bool {
	for pic in app.panes do if pic.due do return true
	return false
}

grid_destroy :: proc(app: ^App) {
	for &pic in app.panes do picture_destroy(app, &pic)
	render.viewport_target_destroy(&app.renderer, &app.work_still)
}

// A point in window coordinates in the main pane's, as Viewport_Input has it.
viewport_point :: proc(app: ^App, p: [2]f32) -> [2]f32 {
	return p - app.ui.viewport_origin
}

// The image id of what the main pane showed as a view pane's work began (grid_work).
KIT_WORK_STILL_IMAGE :: KIT_PANE_IMAGE + GRID_VIEWS

// The main camera: the one the main view sees through, or while its role is lent to a view
// pane, the one it gives back, so the other views, the scene file and the guides in the
// main pane keep to it.
main_camera :: proc(app: ^App) -> camera.Orbit {
	if app.kit.grid.work != 0 do return app.kit.grid.work_back
	return app.camera
}

// Work in any pane (Settings > Interface, on by default): a press on a view pane's picture
// is the viewport's, as Blender's quad views each take the tools, seen through that pane's
// camera. For as long as the gesture lasts the main view's role is lent to the pane: its
// camera is the pane's, it is drawn there live (the one view drawn live this frame, as
// ever) and the main pane holds the picture it showed. Once the gesture is over the pane
// keeps what it did to its camera and the main camera comes back. Runs as the grid is
// laid out, before the viewport reads this frame's input.
grid_work :: proc(app: ^App, n: int) {
	k := &app.kit
	ctx := &k.ctx
	g := &k.grid
	g.work_began, g.work_ended = false, 0
	if g.work != 0 && (g.work >= n || g.serial != g.work_serial || grid_work_over(app)) do grid_work_end(app)
	if ctx.input.pressed == {} || ctx.active != 0 do return
	place := 0
	for i in 1 ..< n do if ctx.pointer_root == ui.id_of(ctx, fmt.tprintf("view pane %d", i)) do place = i
	// A press on a panel is not the viewport's at all.
	if place == 0 && !ctx.viewport_drag do return
	// A double tap is two taps in one view: a tap in another forgets the one before it,
	// whose place was in that view's coordinates.
	if place != g.last_place do app.double_tap.valid = false
	g.last_place = place
	if place != 0 && g.work == 0 && k.panes_work && grid_work_may_start(app) do grid_work_begin(app, place)
}

// Whether a press may take the main view's role into a view pane: not while something
// floats, whose closing press is swallowed, nor while the camera is moved by the app
// itself (a turntable, the timeline, a replay), which follows the main view.
@(private = "file")
grid_work_may_start :: proc(app: ^App) -> bool {
	ctx := &app.kit.ctx
	if kit_floating(app) || ctx.popup_open_prev != 0 || ctx.swallow || app.ui.pie.swallow do return false
	return !turntable_recording(app) && !timeline_busy(app) && !replay_busy(app)
}

// Whether the gesture worked in a view pane is over: nothing is down or held, no stroke
// goes on, and no tool, gizmo, light, pie or brush adjust waits on the pointer. A pinch lets
// the pointer go while its fingers still move the camera, so the fingers count too.
grid_work_over :: proc(app: ^App) -> bool {
	return !app.kit.ctx.viewport_drag && app.drag.owner == .None && app.touch.fingers.count == 0 && !app.stroke.active && !move_busy(app) && !app.ui.light_press.active && !app.ui.pie.open && app.ui.adjust.kind == .None
}

grid_work_begin :: proc(app: ^App, i: int) {
	k := &app.kit
	g := &k.grid
	sv := &g.views[i - 1]
	// What the main pane shows, taken while the main view is still its own: the studio
	// render or live occlusion pause while a view pane is worked in.
	g.work_shown = viewport_shown(app)
	if g.work_shown == nil do g.work_shown = app.target.color
	g.work_back = app.camera
	app.camera = second_orbit(app, sv)
	g.work, g.work_serial, g.work_from = i, g.serial, app.camera
	g.work_began = true
	g.works += 1
	g.work_dabs_from = app.stats.dabs_total
	// The press is the viewport's this very frame.
	k.ctx.viewport_drag, k.ctx.pointer_root = true, 0
}

// Gives the main view's role back: the pane keeps what the gesture did to the camera (a
// linked pane's is the main camera, a mirrored one's the main camera mirrored, any other
// becomes Free at the view it was left at), and the main camera comes back.
grid_work_end :: proc(app: ^App) {
	g := &app.kit.grid
	if g.serial == g.work_serial && app.camera != g.work_from {
		sv := &g.views[g.work - 1]
		#partial switch sv.camera {
		case .Follow:
			g.work_back = app.camera
		case .Mirror:
			g.work_back = camera.orbit_mirror_x(app.camera)
		case:
			sv.orbit, sv.camera = app.camera, .Free
		}
	}
	g.work_dabs += app.stats.dabs_total - g.work_dabs_from
	g.work_live = viewport_shown(app)
	if g.work_live == nil do g.work_live = app.target.color
	if g.serial == g.work_serial do g.work_ended = g.work
	app.camera = g.work_back
	g.work = 0
}

// After the interface on a frame a view pane's work began or ended: copies what the main
// pane showed into the still picture it holds meanwhile, or the pane's last live picture
// into its own picture so it is not drawn again, then sizes the viewport for where it is
// drawn now. Each copy is queued before the target is resized, and before anything this
// frame draws.
grid_work_gpu :: proc(app: ^App) -> bool {
	g := &app.kit.grid
	if !g.work_began && g.work_ended == 0 do return true
	w, h := app.target.width, app.target.height
	// A work begun on the frame the last one ended (a press the very frame after a release)
	// keeps the still picture it had: the target holds the other pane's view now.
	if g.work_began && g.work_ended == 0 {
		if !render.viewport_copy(&app.renderer, &app.work_still, g.work_shown, w, h) do log.warnf("work in a pane: no still picture of the main pane: %s", sdl.GetError())
	}
	if i := g.work_ended; i != 0 {
		pic := &app.panes[i - 1]
		sv := &g.views[i - 1]
		size := [2]u32{w, h}
		if size == g.px[i - 1] && render.viewport_copy(&app.renderer, &pic.view.target, g.work_live, w, h) {
			key, orbit := picture_key(app, sv, size, 1)
			pic.shown, pic.key, pic.at, pic.orbit = pic.view.target.color, key, time.tick_now(), orbit
			// A heavy pass reads the picture's own depth, which the copy did not bring: it is
			// drawn again at rest, the copy showing meanwhile.
			if second_pass_heavy(sv.pass) do pic.key = 0
		}
	}
	want := app.ui.viewport_request
	return msaa_viewport_resize(app, u32(want.x), u32(want.y))
}

// Lucide's monitor-play: the render preview pane.
ICON_RENDER_PREVIEW :: rune(0xe48a)

// The view pane (1 to 3) showing Render in the grid in use, 0 for none.
render_preview_pane :: proc(k: ^Kit_State) -> int {
	g := &k.grid
	for i in 1 ..< grid_panes(g) do if g.views[i - 1].pass == .Render do return i
	return 0
}

// The Render preview pane command, after Blender's second view in Rendered shading and the
// live render beside the work in Marmoset and Substance: the grid's first view pane (Side by
// side when the grid was Single) shows Render, linked to the main camera, so the path
// traced picture follows the view you sculpt in and builds up while you rest. Again, the
// pane goes back to Shaded and the grid stays as it is.
render_preview_toggle :: proc(app: ^App) {
	k := &app.kit
	g := &k.grid
	if i := render_preview_pane(k); i != 0 {
		g.views[i - 1].pass = .Shaded
		return
	}
	// From one view the grid goes Side by side first, a layout step Undo takes back.
	if grid_panes(g) == 1 do grid_choose(app, .Side_By_Side)
	sv := &g.views[0]
	sv.camera, sv.pass = .Follow, .Render
}
