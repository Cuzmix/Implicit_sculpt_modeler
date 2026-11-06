package main

// What the hands are doing, which the tool in hand decides: sculpting (the brushes, Curve
// and Insert), modelling (the Model tool) or looking (the Look tool). The Move tool keeps
// the hands it was picked with. The hands, never the layout in front, decide what the
// dial's sectors do, which verbs the object menu offers first and what the offer line
// asks, so a layout of the person's own works the same whatever it was made from.

Hands :: enum u8 {
	Sculpt,
	Model,
	Look,
}

@(rodata)
HANDS_NAMES := [Hands]string {
	.Sculpt = "Sculpt",
	.Model  = "Model",
	.Look   = "Look",
}

// The hands tool `tool` puts to work; `ok` false for Move, which keeps the hands it found.
hands_of :: proc(tool: Tool) -> (h: Hands, ok: bool) {
	switch tool {
	case .Brush, .Curve, .Insert: return .Sculpt, true
	case .Model:                  return .Model, true
	case .Look:                   return .Look, true
	case .Move:
	}
	return
}

// Follows the tool in hand; a change of hands lets go of the dial's latches the new
// hands' dial holds no sector for.
hands_update :: proc(app: ^App) {
	h, ok := hands_of(app.tool)
	if !ok || h == app.kit.hands do return
	app.kit.hands = h
	dial_latches_keep(app)
}

// Puts hands `h` to work with its tool: the Brush (keeping a brush, Curve or Insert in
// hand), the Model tool or the Look tool, as their commands pick them.
hands_pick :: proc(app: ^App, h: Hands) {
	if now, ok := hands_of(app.tool); ok && now == h do return
	switch h {
	case .Sculpt: command_run(app, .Tool_Sculpt)
	case .Model:  command_run(app, .Tool_Model)
	case .Look:   command_run(app, .Tool_Look)
	}
	hands_update(app)
}
