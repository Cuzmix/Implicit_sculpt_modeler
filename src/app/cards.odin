package main

import "core:fmt"
import "core:strings"

import "../sculpt"
import "../ui"

// Cards (Panels v2): every control the docks do not hold lives on one card, and every
// card is a task: Tool, Layers, Scene, Mesh, Mask, Deform, Paint, Colours, Symmetry, Material, Light,
// Render, History and Details. The sections the three palettes once had are folds inside them, each in exactly
// one card, so a control has one home and Search's Show where opens that card on it
// (card_reveal). A card opens beside the dock button that asked for it, in the column on
// that side of the screen (column.odin); nothing else shows a card's controls.

// The cards, in the order Search and the Library list them.
Card :: enum u8 {
	Tool,
	Layers,
	Scene,
	Mesh,
	Mask,
	Deform,
	Paint,
	Colours,
	Symmetry,
	Material,
	Light,
	Render,
	History,
	Details,
	References,
	Stack,
}

@(rodata)
CARD_NAMES := [Card]string {
	.Tool     = "Tool",
	.Layers   = "Layers",
	.Scene    = "Scene",
	.Mesh     = "Mesh",
	.Mask     = "Mask",
	.Deform   = "Deform",
	.Paint    = "Paint",
	.Colours  = "Colours",
	.Symmetry = "Symmetry",
	.Material = "Material",
	.Light    = "Light",
	.Render   = "Render",
	.History  = "History",
	.Details  = "Details",
	.References = "References",
	.Stack    = "Live stack",
}

@(rodata)
CARD_ICONS := [Card]rune {
	.Tool     = ui.ICON_BRUSH,
	.Layers   = ICON_LAYERS,
	.Scene    = ui.ICON_SHAPES,
	.Mesh     = ICON_SUBDIVIDE,
	.Mask     = ICON_MASK,
	.Deform   = ui.ICON_WAND,
	.Paint    = ui.ICON_PAINTBRUSH,
	.Colours  = ICON_COLOUR,
	.Symmetry = ICON_SYMMETRY,
	.Material = ICON_MATERIAL,
	.Light    = ui.ICON_SUN,
	.Render   = ICON_RENDER_PREVIEW,
	.History  = ui.ICON_HISTORY,
	.Details  = ui.ICON_ACTIVITY,
	.References = ICON_REFERENCES,
	.Stack    = ICON_LIVE_STACK,
}

// The cards that draw their whole body themselves, each with a scroll and controls of its
// own that stay put under it (the Colours card's tabs along its foot, the History list's
// rows drawn only where they show, the Details card's Simple and Advanced tabs over its
// numbers), so the card's body does not scroll them.
OWN_BODY_CARDS :: bit_set[Card]{.Colours, .History, .Details, .References}

// How wide card `c` is at first, and at least: the Colours card seven touch-sized swatches
// across, the History card what its rows of controls need, every other card the same. Its
// corner makes it wider (card_width, card_size.odin).
card_width_base :: proc(c: Card) -> f32 {
	#partial switch c {
	case .Colours: return COLORS_CARD_W
	case .History: return KIT_HISTORY_CARD_W
	case .Details: return DETAILS_CARD_W
	case .References: return REFS_CARD_W
	}
	return CARD_W
}

// The cards whose every section works on the selected object, which say so once at their
// top while none is selected.
OBJECT_CARDS :: bit_set[Card]{.Mesh, .Mask, .Deform, .Paint, .Stack}

// Every section, grouped by the card that holds it and in the order it shows there
// (section_card). Files and scripts name a section by its name, never by number.
Section :: enum u8 {
	// The Tool card: the brush (or the tool held), then the brush's sections, those it is
	// changed by most first (section_group's Common) and the rest under More.
	Brush,
	Stroke,
	Falloff,
	Alpha,
	Paint_Color,
	Recall,
	Preset,
	Samples,
	Pen,
	Options,
	Recorder,
	// The cards with one section each.
	Layers,
	Scene,
	Symmetry,
	Colours,
	History,
	Details,
	References,
	Stack,
	Material,
	// Mesh, in four groups (section_group): Resolution, Rebuild, Combine and Surface.
	Levels,
	Hd,
	Topology,
	Remesh,
	Voxels,
	Booleans,
	Extract,
	Mirror,
	Uvs,
	Retopo,
	Project,
	// Mask.
	Mask,
	Sets,
	Groups,
	Visibility,
	// Deform.
	Transform,
	Morph,
	Deform,
	Physics,
	Deformers,
	// Paint.
	Paint,
	Textures,
	// Light: the lights, what surrounds the scene, and how the viewport draws forms.
	Lights,
	Environment,
	Floor,
	Background,
	Style,
	// Render.
	Render,
	Lens,
	Finish,
	Camera,
	Turntable,
	Print,
}
// A bit_set of them stays one u64.
#assert(len(Section) <= 64)

// The card that holds section `sec`.
section_card :: proc(sec: Section) -> Card {
	switch sec {
	case .Brush ..= .Recorder:     return .Tool
	case .Layers:                  return .Layers
	case .Scene:                   return .Scene
	case .Symmetry:                return .Symmetry
	case .Colours:                 return .Colours
	case .History:                 return .History
	case .Details:                 return .Details
	case .References:              return .References
	case .Stack:                   return .Stack
	case .Material:                return .Material
	case .Levels ..= .Project:     return .Mesh
	case .Mask ..= .Visibility:    return .Mask
	case .Transform ..= .Deformers: return .Deform
	case .Paint, .Textures:        return .Paint
	case .Lights ..= .Style:       return .Light
	case .Render ..= .Print:       return .Render
	}
	return .Tool
}

// The group a long card's section `sec` belongs to, named over the first of its sections
// shown, or "" for a section in none. The Tool card's are Common and More; the Mesh card's eleven sections fall into what changes
// the mesh's resolution, what rebuilds it, what joins or splits it and what lays a surface
// over it.
section_group :: proc(sec: Section) -> string {
	#partial switch sec {
	// The brush with its size and strength, its stroke, falloff and alpha are what a brush
	// is changed by most; a painting brush's colour and the History brush's step join them
	// while they show, as those brushes ask for nothing sooner.
	case .Brush, .Stroke, .Falloff, .Alpha, .Paint_Color, .Recall: return "COMMON"
	case .Preset, .Samples, .Pen, .Options, .Recorder:            return "MORE"
	case .Levels, .Hd, .Topology:        return "RESOLUTION"
	case .Remesh, .Voxels:               return "REBUILD"
	case .Booleans, .Extract, .Mirror:   return "COMBINE"
	case .Uvs, .Retopo, .Project:        return "SURFACE"
	}
	return ""
}

// The sections a fresh layout shows folded: on each card all but the first few, so a card
// opens short and says how the rest are set.
CARDS_SHUT_DEFAULT :: bit_set[Section]{
	.Preset, .Paint_Color, .Samples, .Pen, .Options, .Recorder,
	.Hd, .Topology, .Remesh, .Mirror, .Voxels, .Uvs, .Retopo, .Booleans, .Extract, .Project,
	.Sets, .Groups, .Visibility,
	.Morph, .Deform, .Physics, .Deformers,
	.Textures,
	.Environment, .Floor, .Background, .Style,
	.Lens, .Finish, .Camera, .Turntable, .Print,
}

// The brush's own sections, which the Tool card shows while the brush is the tool.
BRUSH_ONLY_SECTIONS :: bit_set[Section]{.Preset, .Stroke, .Paint_Color, .Recall, .Falloff, .Samples, .Alpha, .Pen, .Options, .Recorder}

// The cards' state in Kit_State: the columns they open in (column.odin), the sections
// folded on every card, the section Show where opened last (scrolled to on its card's next
// frame), whether a card's content is being drawn (where Show where's mark is looked for),
// and for the exit stats, how often cards opened, folded, pinned and closed.
Cards :: struct {
	columns:  [Column_Side]Column,
	shut:     bit_set[Section],
	reveal:   Maybe(Section),
	revealed: Maybe(Section),
	// Frames the reveal has been tried: the section it unfolds lengthens the card only in
	// the next frame's layout, so the scroll may not reach it on the first one.
	reveal_tries: int,
	drawing:  bool,
	// Each card's scrolling body as last laid out, and how far it can scroll.
	bodies:   [Card]struct {
		at:    ui.Rect,
		limit: f32,
	},
	// The floating cards (card_float.odin): which float, where each window is, and how far
	// each body is scrolled.
	floats:        bit_set[Card],
	windows:       [Card]ui.Window,
	float_scrolls: [Card]f32,
	// Each card's size as its corner set it (card_size.odin): its width, 0 for its own
	// (card_width_base), and its body's height while it floats, 0 to fit the window.
	sizes:         [Card][2]f32,
	// The card whose corner is dragged, its size and the pointer at the press, a double tap
	// on a corner, and the drags that changed a size, for the exit stats.
	sizing:        Maybe(Card),
	sizing_from:   [2]f32,
	sizing_press:  [2]f32,
	sizing_was:    [2]f32,
	sizing_tap:    Handle_Tap,
	resizes:       int,
	opens:    int,
	folds:    int,
	pins:     int,
	closes:   int,
	floated:  int, // cards torn out of a column
	returned: int, // floating cards put back in a column
	set:      bool, // cards_default has set it up (a Kit_State nothing has set up is a test's)
	single:   bool, // a column shows one card (columns_split), as the pointer last said with nothing pressed
}

// The cards as a fresh layout has them: none open, the usual sections folded.
cards_default :: proc(k: ^Kit_State) {
	k.cards.columns = {}
	k.cards.floats = {}
	k.cards.shut = CARDS_SHUT_DEFAULT
	k.cards.reveal, k.cards.revealed = nil, nil
	k.cards.set = true
}

// Its title, as its header and Search say it.
card_title :: proc(c: Card) -> string {
	return CARD_NAMES[c]
}

// Its icon, as its header and its button on a dock show it; the Tool card's is the tool's.
card_icon :: proc(app: ^App, c: Card) -> rune {
	if c == .Tool && app.tool != .Brush do return TOOL_ICONS[app.tool]
	return CARD_ICONS[c]
}

// Its word in a layout line and the exit stats.
card_word :: proc(c: Card) -> string {
	return fmt.tprint(c)
}

// The card a word names, any case; false for one this build does not know.
card_from_word :: proc(word: string) -> (Card, bool) {
	for c in Card do if strings.equal_fold(word, fmt.tprint(c)) do return c, true
	return .Tool, false
}

// The section a word names, any case.
section_from_word :: proc(word: string) -> (Section, bool) {
	for s in Section do if strings.equal_fold(word, fmt.tprint(s)) do return s, true
	return .Brush, false
}

// What a section is called: its fold's title and its name in Search.
section_title :: proc(sec: Section) -> string {
	#partial switch sec {
	case .Brush:    return "Brush"
	case .Symmetry: return "Symmetry"
	case .Colours:  return "Colours"
	case .History:  return "History"
	case .Details:  return "Details"
	case .References: return "References"
	}
	for s in BRUSH_SECTIONS do if s.section == sec do return s.title
	for s in OBJECT_SECTIONS do if s.section == sec do return s.title
	for s in SCENE_SECTIONS do if s.section == sec do return s.title
	return ""
}

// Each section's icon, for its button on a dock and its tile in the Library: the look's
// own where a card shows it, else the nearest of the interface's glyphs (Lucide's
// download, camera, video and printer by their code points).
@(rodata)
SECTION_ICONS := [Section]rune {
	.Brush       = ui.ICON_BRUSH,
	.Preset      = ICON_BOOKMARK,
	.Stroke      = ui.ICON_SPLINE,
	.Paint_Color = ICON_COLOUR,
	.Recall      = ui.ICON_HISTORY,
	.Falloff     = ICON_CIRCLE_DASHED,
	.Samples     = ui.ICON_ACTIVITY,
	.Alpha       = ui.ICON_IMAGE,
	.Pen         = ui.ICON_PENCIL,
	.Options     = ui.ICON_SETTINGS,
	.Recorder    = ui.ICON_RECORD,
	.Layers      = ICON_LAYERS,
	.Scene       = ui.ICON_SHAPES,
	.Symmetry    = ICON_SYMMETRY,
	.Colours     = ICON_COLOUR,
	.History     = ui.ICON_HISTORY,
	.Details     = ui.ICON_ACTIVITY,
	.References  = ICON_REFERENCES,
	.Stack       = ICON_LIVE_STACK,
	.Levels      = ICON_SUBDIVIDE,
	.Hd          = ui.ICON_ZOOM_IN,
	.Topology    = ICON_DYNTOPO,
	.Remesh      = ICON_REMESH,
	.Mirror      = ICON_SYMMETRY,
	.Voxels      = ICON_VOXEL_CLAY,
	.Uvs         = rune(0xe4ee), // scissors-line-dashed: seams
	.Retopo      = ICON_RETOPO,
	.Booleans    = ICON_BOOLEAN,
	.Extract     = ICON_SPLIT,
	.Project     = rune(0xe0b6), // download
	.Mask        = ICON_MASK,
	.Sets        = ui.ICON_TAG,
	.Groups      = ui.ICON_GRID,
	.Visibility  = ui.ICON_EYE,
	.Transform   = ui.ICON_MOVE,
	.Morph       = ICON_FLIP_VIEW,
	.Deform      = ui.ICON_WAND,
	.Physics     = rune(0xe1ca), // shirt, as the Cloth brush
	.Deformers   = ui.ICON_ROTATE_3D,
	.Paint       = ui.ICON_PAINTBRUSH,
	.Textures    = ICON_FILL_GRADIENT,
	.Material    = ICON_MATERIAL,
	.Lights      = ui.ICON_SUN,
	.Environment = ui.ICON_IMAGE,
	.Floor       = ICON_FLOOR,
	.Background  = ui.ICON_FRAME,
	.Style       = ICON_SHADING,
	.Render      = ICON_RENDER_PREVIEW,
	.Lens        = rune(0xe068), // camera
	.Finish      = ICON_SPARKLES,
	.Camera      = ICON_CAMERA,
	.Turntable   = rune(0xe1a5), // video
	.Print       = rune(0xe145), // printer
}

// Lucide's icons the cards use that the kit does not name already.
ICON_CONTRAST :: rune(0xe0a1) // half filled: inverting
ICON_SPARKLES :: rune(0xe417)
// Lucide's images: the References card, a stack of pictures.
ICON_REFERENCES :: rune(0xe5c9)
// Lucide's layers-3: the Live stack card, rows over the object.
ICON_LIVE_STACK :: rune(0xe52f)
ICON_MINUS :: rune(0xe120)
ICON_CIRCLE_DASHED :: rune(0xe4b5) // a hole's open border
ICON_MASK :: rune(0xe2aa) // venetian-mask: the one glyph of masking, on the brush, the card and the history
ICON_SCAN_EYE :: rune(0xe53b) // facing the eye: masking by angle, a step's tint

// Whether card `c` shows section `sec` now: the brush's own sections while the brush is
// the tool (the History brush's only on it), every other section always.
section_offered :: proc(app: ^App, sec: Section) -> bool {
	if sec not_in BRUSH_ONLY_SECTIONS do return true
	if app.tool != .Brush do return false
	for s in BRUSH_SECTIONS do if s.section == sec do return s.shown == nil || s.shown(app)
	return false
}

// The sections card `c` shows now, in order.
card_sections :: proc(app: ^App, c: Card) -> []Section {
	out := make([dynamic]Section, 0, len(Section), context.temp_allocator)
	for s in Section do if section_card(s) == c && section_offered(app, s) do append(&out, s)
	return out[:]
}

// How many sections card `c` holds in all, whatever the tool.
card_sections_count :: proc(c: Card) -> int {
	n := 0
	for s in Section do if section_card(s) == c do n += 1
	return n
}

// Where each command's control is on the cards, for Search's Show where: the section
// that shows it (with every option, since Show where opens the section's More). Commands
// not here have no control on a card, or only one that comes and goes with the brush (the
// History brush's steps), or live on the docks alone.
@(rodata)
COMMAND_HOMES := #partial [Command_Id]Maybe(Section) {
	.Front_Only            = .Options,
	.Lock_Plane            = .Options,
	.Connected             = .Options,
	.Preset_Save_New       = .Preset,
	.Brush_Reset           = .Preset,
	.Reset_Transform       = .Transform,
	.Subdivide             = .Levels,
	.Level_Up              = .Levels,
	.Level_Down            = .Levels,
	.Delete_Lower_Levels   = .Levels,
	.Delete_Higher_Levels  = .Levels,
	.Hd_Divide             = .Hd,
	.Detail_Skin           = .Hd,
	.Skin_Apply            = .Hd,
	.Skin_Squeeze          = .Hd,
	.Hd_Delete             = .Hd,
	.Dyntopo_Toggle        = .Topology,
	.Rebuild               = .Remesh,
	.Mirror_Weld           = .Mirror,
	.Close_Holes           = .Mirror,
	.Delete_Hidden         = .Mirror,
	.Weld_Points           = .Mirror,
	.Check_Mesh            = .Mirror,
	.Fix_Mesh              = .Mirror,
	.Delete_Half           = .Mirror,
	.Unwrap                = .Uvs,
	.Straighten            = .Uvs,
	.Texel_Density         = .Uvs,
	.Mask                  = .Mask,
	.Store_Selection_Set   = .Sets,
	.Group                 = .Groups,
	.Polygroups            = .Groups,
	.Show_All              = .Visibility,
	.Invert_Hidden         = .Visibility,
	.Hide_Masked           = .Visibility,
	.Hide_Unmasked         = .Visibility,
	.Grow_Visible          = .Visibility,
	.Shrink_Visible        = .Visibility,
	.Grow_All_Visible      = .Visibility,
	.Outer_Ring            = .Visibility,
	.Grow_To_Groups        = .Visibility,
	.Show_Masked           = .Visibility,
	.New_Layer             = .Layers,
	.Layer_Edit            = .Layers,
	.New_Paint_Layer       = .Layers,
	.New_Texture_Layer     = .Layers,
	.Export_Paint_Maps     = .Layers,
	.Paint_Layer_Edit      = .Layers,
	.Paint                 = .Paint,
	.Morph_Store           = .Morph,
	.Morph_Delete          = .Morph,
	.Smooth_All            = .Deform,
	.Make_Boolean          = .Booleans,
	.Extract_Masked        = .Extract,
	.Convert_To_Mesh       = .Voxels,
	.Convert_To_Voxels     = .Voxels,
	.Voxel_Res_Up          = .Voxels,
	.Voxel_Res_Down        = .Voxels,
	.Duplicate_Object      = .Scene,
	.Delete_Object         = .Scene,
	.Studio_Render         = .Render,
	.Live_Occlusion        = .Style,
	.Render_Mode           = .Render,
	.Pick_Focus            = .Lens,
	.History_Find          = .History,
	.Place_Light           = .Lights,
	.Focus_Pivot           = .Lens,
	.Finish_Reset          = .Finish,
	.Ortho_Toggle          = .Camera,
	.View_Axis             = .Camera,
	.Focus_Selected        = .Camera,
	.Reset_Camera          = .Camera,
	.Record_Turntable      = .Turntable,
	.Export_Print          = .Print,
	.Floor_Grid            = .Floor,
	.Screenshot_Transparent = .Background,
}

// Opens the card that holds section `sec` on the pen side (or where it shows already),
// unfolds the section and scrolls to it on the card's next frame. A brush section switches
// the tool to the brush first, as only the brush has them.
card_reveal :: proc(app: ^App, sec: Section) {
	k := &app.kit
	if !k.cards.set do cards_default(k)
	if sec in BRUSH_ONLY_SECTIONS && app.tool != .Brush do command_run(app, .Tool_Sculpt)
	card_open(app, section_card(sec))
	k.cards.shut -= {sec}
	k.cards.reveal, k.cards.revealed = sec, sec
	k.cards.reveal_tries = 0
}

// Opens the card where command `id` (with `arg`) has its control and marks the control
// for a moment, with the section's More options open. False for a command with no home
// on a card.
card_show :: proc(app: ^App, id: Command_Id, arg := 0) -> bool {
	sec, ok := COMMAND_HOMES[id].?
	if !ok do return false
	k := &app.kit
	// The Layers card's tab that holds the command.
	#partial switch id {
	case .New_Layer, .Layer_Edit:             app.ui.layers_paint = false
	case .New_Paint_Layer, .New_Texture_Layer, .Paint_Layer_Edit: app.ui.layers_paint = true
	}
	card_reveal(app, sec)
	k.more[sec] = true
	k.pointed = {id, arg, k.ctx.time}
	return true
}

// Marks the next control as the one Show where points at when it runs command `id` with
// `arg` and a card's content is being drawn (command_hint calls it).
card_mark :: proc(app: ^App, id: Command_Id, arg: int) {
	k := &app.kit
	if k.cards.drawing && k.pointed.id == id && k.pointed.arg == arg do ui.mark_next(&k.ctx)
}

// What card `c` holds, in a few words, for its header: the brush and its size, the
// layers, the objects and the one selected, the axes, the first section's own line.
card_summary :: proc(app: ^App, c: Card) -> string {
	#partial switch c {
	case .Tool:
		if app.tool != .Brush do return kit_tool_name(app.tool)
		return fmt.tprintf("%s · %.0f px", brush_item_name(app, brush_item_current(app)), app.brush.radius_px)
	case .Scene:
		n := len(app.scene.objects)
		line := fmt.tprintf("%d object%s", n, "" if n == 1 else "s")
		if obj := selected_object(app); obj != nil do line = fmt.tprintf("%s · %s", line, object_label(obj))
		return line
	case .Symmetry:
		if app.brush.radial_on do return fmt.tprintf("radial %d", app.brush.radial_count)
		return "Local" if app.brush.sym_local else ""
	case .Stack:
		return stack_summary(selected_object(app))
	case .Mesh, .Mask, .Deform, .Paint:
		obj := selected_object(app)
		if obj == nil do return ""
		return fmt.tprintf("%s · %s vertices", object_label(obj), count_label(object_vertex_count(obj)))
	}
	for s in Section do if section_card(s) == c do return section_summary(app, s)
	return ""
}

// What section `sec` holds, in a few words, for its folded header.
section_summary :: proc(app: ^App, sec: Section) -> string {
	b := &app.brush
	obj := selected_object(app)
	#partial switch sec {
	case .Preset:
		p, on := brush_preset(app)
		if !on do return "none"
		return fmt.tprintf("%s%s", preset_name(p), " · changed" if preset_changed(app) else "")
	case .Stroke:
		line := STROKE_MODE_NAMES[b.stroke]
		if b.lazy_px >= 0.5 do line = fmt.tprintf("%s · lazy %.0f px", line, b.lazy_px)
		if n := steady_count(b.smoothing); n > 1 do line = fmt.tprintf("%s · smoothing %d", line, n)
		return line
	case .Paint_Color:
		return hex_text(b.color)
	case .Falloff:
		f := b.falloffs[b.kind]
		line := "Drawn curve" if f.drawn else "The brush's own"
		if f.focal != 0 do line = fmt.tprintf("%s · focal %.0f", line, f.focal)
		if f.hardness != 0 do line = fmt.tprintf("%s · hard %.0f%%", line, f.hardness * 100)
		if f.projected do line = fmt.tprintf("%s · projected", line)
		return line
	case .Samples:
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		if b.stabilize > 0 do append(&parts, fmt.tprintf("steady %.0f%%", b.stabilize * 100))
		if b.sample_radius > 0 && b.sample_radius < 1 do append(&parts, fmt.tprintf("sample %.0f%%", b.sample_radius * 100))
		if accumulate_applies(b.kind) do append(&parts, "builds up" if !b.no_accumulate[b.kind] else "one pass")
		if len(parts) == 0 do return "as it comes"
		return strings.join(parts[:], " · ", context.temp_allocator)
	case .Alpha:
		if b.alpha < 0 || b.alpha >= len(app.alphas) do return "Round"
		return app.alphas[b.alpha].name
	case .Pen:
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		p := brush_pressure(b, b.kind)
		if p.size do append(&parts, "size")
		if p.strength do append(&parts, "strength")
		own := " (own)" if b.pressures[b.kind].own else ""
		if len(parts) == 0 do return fmt.tprintf("pressure off%s", own)
		return fmt.tprintf("pressure → %s%s", strings.join(parts[:], ", ", context.temp_allocator), own)
	case .Options:
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		if b.front_only do append(&parts, "front faces")
		if b.lock_plane do append(&parts, "lock plane")
		if b.connected do append(&parts, "connected")
		if len(parts) == 0 do return "every face"
		return strings.join(parts[:], " · ", context.temp_allocator)
	case .Camera:
		return "Orthographic" if app.camera.ortho else "Perspective"
	case .Lights:
		n := int(app.scene.lights.count)
		return fmt.tprintf("%d light%s", n, "" if n == 1 else "s")
	case .Layers:
		if obj == nil || obj.voxel != nil do return ""
		n := sculpt.levels_layer_count(&obj.levels)
		return fmt.tprintf("%d layer%s", n, "" if n == 1 else "s")
	case .Levels:
		if obj == nil || obj.voxel != nil do return ""
		return fmt.tprintf("Level %d of %d", obj.levels.current + 1, len(obj.levels.levels))
	case .Topology:
		return "Dynamic on" if command_checked(app, .Dyntopo_Toggle, 0) else "Dynamic off"
	case .Material:
		// The card's own sphere and name say it already.
		return ""
	case .Render:
		if !render_switch_on(app) do return "Off"
		return "Full" if app.render_on else "Fast"
	case .Turntable:
		return fmt.tprintf("%d frames", int(app.turntable_frames))
	case .Print:
		return fmt.tprintf("%g mm a unit", print_scale(app))
	case .Floor:
		return "Grid on" if app.floor.on else "Grid off"
	case .Uvs:
		return uvs_summary(obj)
	}
	return ""
}

// Card `c`'s content, `inner` wide: each section it shows, under a header that folds it
// (a card of one section shows it bare, and the Tool card's Brush always shows). `body` is
// where its scrolling body starts on screen and `scroll` how far it is scrolled, so the
// section Show where opened is scrolled to (returned, or -1 for none).
card_body :: proc(app: ^App, c: Card, inner: f32, body_y: f32, scroll: f32) -> (reveal_at: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	reveal_at = -1
	if !k.cards.set do cards_default(k)
	if c in OBJECT_CARDS && selected_object(app) == nil {
		ui.paragraph(ctx, "Add or select an object first.")
		return
	}
	k.cards.drawing = true
	defer k.cards.drawing = false
	hints := hints_push(app)
	defer ctx.hints = hints
	sections := card_sections(app, c)
	for sec, i in sections {
		if len(sections) == 1 {
			section_draw(app, sec, inner)
			continue
		}
		// A group's caption stands in for the divider over its first section, and inside
		// a group the sections part by a little space alone, so the caption reads as
		// heading all of them rather than the first.
		group := section_group(sec)
		switch {
		case group != "" && (i == 0 || section_group(sections[i - 1]) != group):
			if i > 0 do ui.spacer(ctx, ui.SPACE_S)
			ui.caption(ctx, group)
		case group != "":
			ui.spacer(ctx, ui.SPACE_XS)
		case i > 0:
			ui.divider(ctx, inner, across = true)
		}
		if sec == .Brush {
			section_draw(app, sec, inner)
			continue
		}
		open := sec not_in k.cards.shut
		g := ui.area(ctx, fmt.tprintf("%s##section", section_title(sec)), {inner, 36})
		if r, ok := k.cards.reveal.?; ok && r == sec do reveal_at = g.rect.y - body_y + scroll
		if g.hovered || g.held do ui.fill_rect(ctx, g.rect, t.radius_medium, t.fill_pressed if g.held else t.fill_hover)
		y := g.rect.y + g.rect.h * 0.5
		ui.icon(ctx, ui.ICON_CHEVRON_DOWN if open else ui.ICON_CHEVRON_RIGHT, {g.rect.x + 8, y}, t.icon_small - 2, t.text_secondary)
		ui.text(ctx, section_title(sec), g.rect.x + 22, y, t.text_size, t.text, .Semibold)
		used := 22 + ui.text_width(ctx, section_title(sec), t.text_size, .Semibold) + 12
		// The summary stands in for a folded section's controls; an open one shows them. A
		// colour's is its swatch, which reads at a glance where a hex code does not.
		if sec == .Paint_Color && !open {
			at := [2]f32{g.rect.x + g.rect.w - 6 - 7, y}
			ui.fill_circle(ctx, at, 8, t.border_strong)
			ui.fill_circle(ctx, at, 7, shade(app.brush.color))
		} else if line := section_summary(app, sec); !open && line != "" && g.rect.w - used > 24 {
			ui.text(ctx, ui.text_fit(ctx, line, t.small_size, g.rect.w - used - 6), g.rect.x + g.rect.w - 6, y, t.small_size, t.text_tertiary, align = .Right)
		}
		ui.tip(ctx, g.id, g.rect, "Fold" if open else "Unfold", label = false)
		if g.clicked {
			k.cards.shut ~= {sec}
			k.cards.folds += 1
		}
		if open do section_draw(app, sec, inner)
	}
	return
}

// Section `sec`'s controls, `inner` wide.
section_draw :: proc(app: ^App, sec: Section, inner: f32) {
	ctx := &app.kit.ctx
	#partial switch sec {
	case .Brush:
		if app.tool == .Brush do card_brush(app, inner)
		else do kit_tool_tab(app)
		return
	case .Symmetry:
		symmetry_controls(app)
		return
	}
	_, draw, obj_draw, found := bar_section(app, sec)
	obj := selected_object(app)
	switch {
	case !found:
		ui.paragraph(ctx, "Nothing to show here.")
	case obj_draw != nil && obj == nil:
		ui.paragraph(ctx, "Add or select an object first.")
	case obj_draw != nil:
		obj_draw(app, obj)
	case:
		draw(app)
	}
}

// The Tool card's Brush: the brush's card (its stroke, name, family and whether its preset
// has changed, Favorite), then Size and Strength unless the off-hand dock holds both as
// sliders, when a line says how they are set.
@(private = "file")
card_brush :: proc(app: ^App, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	cur := brush_item_current(app)
	key := brush_item_key(app, cur)
	ui.begin(ctx, "card brush", {direction = .Row, gap = ui.SPACE_M, center = true, width = inner})
	r := ui.place(ctx, {44, 44})
	lens_stroke_preview(ctx, r, cur, app)
	// The picture, the name and the heart with the row's two gaps between them.
	text_w := inner - 44 - 2 * 10 - t.target
	ui.begin(ctx, "card brush name", {direction = .Column, gap = 0, width = text_w})
	ui.label(ctx, ui.text_fit(ctx, brush_item_name(app, cur), t.text_size, text_w, .Semibold), font = .Semibold)
	family := brush_item_family(app, cur)
	if preset_changed(app) do family = fmt.tprintf("%s · edited", family)
	ui.label(ctx, ui.text_fit(ctx, family, t.small_size, text_w), size = t.small_size, color = t.text_tertiary)
	ui.end(ctx)
	_, favourite := brush_favorite(&k.brushes, key)
	if ui.icon_button(ctx, "Favorite (on)##card" if favourite else "Favorite##card", ICON_HEART, selected = favourite) do brush_favorite_toggle(&k.brushes, key)
	ui.end(ctx)
	// With the brush bar's sliders in sight the card leaves Size and Strength to them (its
	// head already says the size); without them the card holds the sliders.
	if !island_has_size_strength(k) {
		strength := brush_strength(app)
		_ = ui.slider(ctx, "Size##card", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px))
		_ = ui.slider(ctx, "Strength##card", strength, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", strength^))
	}
}

// Whether the off-hand dock showed Size and Strength as sliders this frame or the last.
island_has_size_strength :: proc(k: ^Kit_State) -> bool {
	return k.island_frame >= k.frame - 1 && bit_set[Brush_Value]{.Size, .Strength} <= k.island_sliders
}

// The folded sections for the exit stats, by name, or none.
cards_shut_text :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for sec in Section {
		if sec not_in k.cards.shut do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprint(&b, sec)
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}
