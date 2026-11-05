package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../send"
import "../ui"

// Send's interface: the Export sheet's Send preset, which lists the computers on the
// network (found while it shows) and takes a typed address; the pill under the top bar
// while a send runs (finding, pairing with its code, how far, Cancel) or while a device
// asks this desktop to pair (its code, Allow and Decline); and Settings > Files > Send
// scenes (Receive scenes, the paired devices with Forget). The threads only fill
// Send_Shared under its lock; everything here reads it once a frame.

// Lucide's send, monitor and tablet.
ICON_SEND :: rune(0xe156)
@(private = "file")
ICON_MONITOR :: rune(0xe121)
@(private = "file")
ICON_TABLET :: rune(0xe182)

Send_Phase :: enum u8 {
	Idle,
	Finding, // asking the network for the computer named
	Connecting,
	Pairing, // both screens show the code; the other side's person allows it
	Sending,
}

// The other side's person decides on a pairing.
Ask_Reply :: enum u8 {
	None,
	Allow,
	Decline,
}

// A device asking this desktop to pair, under the lock but for reply (atomic).
Send_Ask :: struct {
	on:    bool,
	name:  string, // owned
	code:  u32,
	reply: Ask_Reply,
}

// Sets what the send under way is doing, for the pill.
send_phase :: proc(sh: ^Send_Shared, phase: Send_Phase, peer: string, code: u32 = 0) {
	sync.lock(&sh.lock)
	defer sync.unlock(&sh.lock)
	sh.phase, sh.code = phase, code
	if peer != sh.peer {
		delete(sh.peer)
		sh.peer = strings.clone(peer)
	}
}

// Asks this desktop's person whether device name may pair, showing code, and waits for
// the answer, at most SEND_PAIR_WAIT: true for Allow. One ask at a time; another device
// asking meanwhile is declined.
send_ask :: proc(sh: ^Send_Shared, name: string, code: u32) -> bool {
	sync.lock(&sh.lock)
	if sh.asking.on {
		sync.unlock(&sh.lock)
		return false
	}
	delete(sh.asking.name)
	sh.asking = {on = true, name = strings.clone(name), code = code}
	sync.unlock(&sh.lock)
	defer {
		sync.lock(&sh.lock)
		sh.asking.on = false
		sync.unlock(&sh.lock)
	}
	start := time.tick_now()
	for time.tick_since(start) < SEND_PAIR_WAIT && !sync.atomic_load(&sh.quit) {
		switch sync.atomic_load(&sh.asking.reply) {
		case .Allow:   return true
		case .Decline: return false
		case .None:
		}
		// A person answers within seconds; a tenth of one is soon enough to notice.
		time.sleep(100 * time.Millisecond)
	}
	return false
}

// Keeps f in all when it is another device not listed yet; false leaves f to the caller
// to destroy.
send_found_keep :: proc(all: ^[dynamic]send.Found, f: ^send.Found, me: [16]u8) -> bool {
	if f.device == me do return false
	for o in all do if o.device == f.device do return false
	append(all, f^)
	return true
}

// How long one look round the network for the sheet's list takes: answers come within
// a fraction of a second, and a computer that started since shows by the next look.
@(private = "file")
SEND_BROWSE_LOOK :: 2 * time.Second

// Finds computers while the Export sheet shows Send: a thread looks round the network
// again and again and puts what it found in Send_Shared.computers, until the sheet closes.
send_browse_follow :: proc(app: ^App) {
	sh := app.send.shared
	if sh == nil do return
	s := &app.kit.export
	want := s.open && s.format == .Send
	if app.send.browse != nil && thread.is_done(app.send.browse) {
		thread.join(app.send.browse)
		thread.destroy(app.send.browse)
		app.send.browse = nil
	}
	sync.atomic_store(&sh.browse_stop, !want)
	if !want || app.send.browse != nil do return
	app.send.browse = thread.create_and_start_with_data(sh, proc(data: rawptr) {
		sh := cast(^Send_Shared)data
		arena: runtime.Arena
		context.temp_allocator = runtime.arena_allocator(&arena)
		defer runtime.arena_destroy(&arena)
		// The first look is short, so the list fills as soon as the sheet opens.
		look := SEND_BROWSE_LOOK / 4
		for !sync.atomic_load(&sh.browse_stop) && !sync.atomic_load(&sh.quit) {
			found := make([dynamic]send.Found)
			_, _ = send_find_run(sh, "", look, &sh.browse_stop, &found)
			look = SEND_BROWSE_LOOK
			sync.lock(&sh.lock)
			old := sh.computers
			sh.computers = found
			sync.unlock(&sh.lock)
			for &f in old do send.found_destroy(&f)
			delete(old)
			runtime.arena_free_all(&arena)
		}
	}, context, .Normal, name = "send browse")
}

// Whether a send is under way: started and not yet ended.
send_busy :: proc(app: ^App) -> bool {
	sh := app.send.shared
	if sh == nil || app.send.sender == nil do return false
	return !thread.is_done(app.send.sender)
}

// Where Send scene sends: the last place sent to.
send_can_send :: proc(app: ^App) -> bool {
	return SEND_AVAILABLE && app.send.shared != nil && !send_busy(app)
}

// The name the menu gives the last place sent to: a found computer's name, or the
// address typed.
send_last_name :: proc(app: ^App) -> string {
	last := app.send.last
	if i := strings.index_byte(last, '|'); i >= 0 do return last[i + 1:]
	return last[1:] if strings.has_prefix(last, "@") else last
}

// Sends to the place remembered as last: `address|name` for a computer found, or what
// was typed.
send_scene_last :: proc(app: ^App) -> bool {
	last := app.send.last
	if last == "" do return false
	if i := strings.index_byte(last, '|'); i >= 0 do return send_scene(app, last[:i], last[i + 1:])
	return send_scene(app, last)
}

// Remembers target as the last place sent to.
send_last_set :: proc(app: ^App, target: string) {
	if target == app.send.last do return
	delete(app.send.last)
	app.send.last = strings.clone(target)
}

// The pill under the top bar, under the long job's when both show: a pairing to allow
// on this desktop, else the send under way.
kit_send_pill :: proc(app: ^App) {
	sh := app.send.shared
	if sh == nil do return
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sync.lock(&sh.lock)
	asking, ask_name, ask_code := sh.asking.on, strings.clone(sh.asking.name, context.temp_allocator), sh.asking.code
	phase, peer, code := sh.phase, strings.clone(sh.peer, context.temp_allocator), sh.code
	done, total := sh.done, sh.total
	sync.unlock(&sh.lock)
	arrived := app.send.arrived.path != ""
	if !asking && !arrived && (phase == .Idle || !send_busy(app)) do return
	size, _ := ui.prev_layout(ctx, "send pill")
	if size == {} do size = {360, t.target + 8}
	area := ui.safe_area(ctx)
	below: f32 = t.target + 20 if app.long_job.on else 0
	pos := [2]f32{area.x + (area.w - size.x) * 0.5, area.y + kit_top() + 12 + below}
	ui.begin_at(ctx, "send pill", pos, {direction = .Row, gap = ui.SPACE_M, padding = ui.SPACE_S, radius = t.radius_large + 4, background = .Panel, center = true})
	defer ui.end(ctx)
	r := ui.place(ctx, {28, 28})
	if asking {
		ui.icon(ctx, ICON_TABLET, {r.x + 14, r.y + 14}, t.icon_size, t.accent)
		ui.label(ctx, fmt.tprintf("%s asks to send you scenes", ask_name), t.small_size, t.text, .Semibold)
		ui.label(ctx, fmt.tprintf("Code %s", send_code_text(ask_code)), t.small_size, t.text_secondary)
		if ui.button(ctx, "Decline##send ask", .Light) do sync.atomic_store(&sh.asking.reply, Ask_Reply.Decline)
		if ui.button(ctx, "Allow##send ask", .Solid, .Accent) do sync.atomic_store(&sh.asking.reply, Ask_Reply.Allow)
		return
	}
	if arrived && !send_busy(app) {
		a := app.send.arrived
		ui.icon(ctx, ICON_SEND, {r.x + 14, r.y + 14}, t.icon_size, t.accent)
		if a.conflict {
			ui.label(ctx, fmt.tprintf("Changed here too: %s sent its copy", a.from), t.small_size, t.text, .Semibold)
		} else {
			ui.label(ctx, fmt.tprintf("A scene from %s", a.from), t.small_size, t.text, .Semibold)
		}
		if ui.button(ctx, "Keep both##send arrived" if a.conflict else "Keep for later##send arrived", .Light) do send_arrival_answer(app, false)
		if ui.button(ctx, fmt.tprintf("Open %s's##send arrived", a.from) if a.conflict else "Open##send arrived", .Solid, .Accent) do send_arrival_answer(app, true)
		return
	}
	share := f32(done) / f32(max(total, 1)) if phase == .Sending else 0
	draw_progress_ring(ctx, {r.x + 14, r.y + 14}, 11, share, 3)
	switch phase {
	case .Idle:
	case .Finding:
		ui.label(ctx, fmt.tprintf("Looking for %s", peer if peer != "" else "a computer"), t.small_size, t.text, .Semibold)
	case .Connecting:
		ui.label(ctx, fmt.tprintf("Connecting to %s", peer), t.small_size, t.text, .Semibold)
	case .Pairing:
		ui.label(ctx, fmt.tprintf("Pairing with %s: allow %s there", peer, send_code_text(code)), t.small_size, t.text, .Semibold)
	case .Sending:
		ui.label(ctx, fmt.tprintf("Sending to %s", peer), t.small_size, t.text, .Semibold)
		ui.label(ctx, fmt.tprintf("%d%%", int(share * 100)), t.small_size, t.text_secondary)
	}
	if ui.button(ctx, "Cancel##send", .Light, glyph = ui.ICON_CLOSE) do sync.atomic_store(&sh.cancel, true)
}

send_code_text :: proc(code: u32) -> string {return fmt.tprintf("%03d %03d", code / 1000, code % 1000)}

// Settings > Files > Send scenes: Receive scenes on a desktop, this device's name, and
// the devices paired with it, each with Forget.
send_settings_rows :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	sh := app.send.shared
	if sh == nil {
		ui.paragraph(ctx, "This run keeps no settings, so it has no send folder." if SEND_AVAILABLE else "The web version cannot send scenes.", color = t.text_secondary)
		return
	}
	when !MOBILE {
		_ = ui.switch_row(ctx, "Receive scenes", &app.send_receive)
		if app.send.receive && !app.send_receive do ui.paragraph(ctx, "This run receives anyway: it was started with --receive.", color = t.text_secondary)
	}
	sync.lock(&sh.lock)
	ui.value_row(ctx, "This device", sh.me.name)
	Shown :: struct {
		device: [16]u8,
		name:   string,
	}
	pairs := make([]Shown, len(sh.pairs), context.temp_allocator)
	for p, i in sh.pairs do pairs[i] = {p.device, strings.clone(p.name, context.temp_allocator)}
	sync.unlock(&sh.lock)
	if len(pairs) == 0 {
		ui.paragraph(ctx, "No device is paired yet: the first send between two devices pairs them, with the same six digits on both screens.", color = t.text_secondary)
	}
	for p, i in pairs {
		row := ui.list_row(ctx, fmt.tprintf("%s##send pair %d", p.name, i), "Forget", glyph = ICON_TABLET if MOBILE else ICON_MONITOR)
		if row.clicked {
			send_pair_drop(app, p.device)
			file_note(app, false, "Forgot %s: the next send between you pairs again", p.name)
		}
	}
	when MOBILE {
		ui.paragraph(ctx, "Send the scene from Menu > Export... > Send to a computer running Sculpt with Receive scenes on, on the same Wi-Fi. While Sculpt is open here, a computer you paired with can send the scene back.")
	} else {
		ui.paragraph(ctx, "With Receive scenes on, a tablet on the same Wi-Fi finds this computer and sends it the scene, which opens here; the first time, both screens show the same six digits and you allow it here. Menu > Send to then sends it back to the tablet while Sculpt is open there. Nothing goes to the internet.")
	}
}

// The Export sheet's Send options: the computers found on the network, or an address to
// type, and what sending does.
export_send_options :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	sh := app.send.shared
	if sh == nil {
		ui.paragraph(ctx, "This run keeps no settings, so it cannot send." if SEND_AVAILABLE else "The web version cannot send scenes.")
		return
	}
	targets, backs := send_targets(sh)
	typed := string(app.send.address[:])
	if i := strings.index_byte(typed, 0); i >= 0 do typed = typed[:i]
	ui.caption(ctx, "ON THIS NETWORK")
	if len(targets) == 0 do ui.paragraph(ctx, "Looking for computers running Sculpt with Receive scenes on...", color = t.text_secondary)
	for f, i in targets {
		other := f.protocol != send.PROTOCOL
		detail := "another version" if other else ("sent here" if i < backs else ("paired" if send_paired(sh, f.device) else ""))
		glyph := ICON_TABLET if i < backs else ICON_MONITOR
		row := ui.list_row(ctx, fmt.tprintf("%s##send computer %d", f.name if f.name != "" else "Sculpt", i), detail, selected = typed == "" && app.send.pick == i, glyph = glyph)
		if row.clicked {
			app.send.pick = i
			app.send.address = {}
		}
	}
	ui.text_field(ctx, "send address", app.send.address[:], hint = "Or type the computer's address")
	ui.paragraph(ctx, "Sends the whole scene; the computer opens it. The first send to a computer pairs the two: both show six digits, and you allow it there.", color = t.text_tertiary)
}

// What the Export sheet's Send lists, copied under the lock with names in the temp
// memory: the devices that sent here first (backs of them), then the computers found, at
// most three in all, none twice.
@(private = "file")
send_targets :: proc(sh: ^Send_Shared) -> (list: []send.Found, backs: int) {
	sync.lock(&sh.lock)
	defer sync.unlock(&sh.lock)
	out := make([dynamic]send.Found, 0, 3, context.temp_allocator)
	for f in sh.backs do if len(out) < 3 do append(&out, f)
	backs = len(out)
	outer: for f in sh.computers {
		if len(out) >= 3 do break
		for g in out do if g.device == f.device do continue outer
		append(&out, f)
	}
	for &f in out do f.name = strings.clone(f.name, context.temp_allocator)
	return out[:], backs
}

// Whether device is paired with this one.
@(private = "file")
send_paired :: proc(sh: ^Send_Shared, device: [16]u8) -> bool {
	sync.lock(&sh.lock)
	defer sync.unlock(&sh.lock)
	for p in sh.pairs do if p.device == device do return true
	return false
}

// Where the Export sheet's Send goes: the address typed, else the computer picked, as
// `address|name`; "" when there is none.
export_send_target :: proc(app: ^App) -> string {
	typed := string(app.send.address[:])
	if i := strings.index_byte(typed, 0); i >= 0 do typed = typed[:i]
	typed = strings.trim_space(typed)
	if typed != "" do return typed
	sh := app.send.shared
	if sh == nil do return ""
	targets, _ := send_targets(sh)
	if app.send.pick < 0 || app.send.pick >= len(targets) do return ""
	f := targets[app.send.pick]
	if f.protocol != send.PROTOCOL do return ""
	a := f.addresses[0]
	return fmt.tprintf("%d.%d.%d.%d:%d|%s", a[0], a[1], a[2], a[3], f.port, f.name)
}

// The Export sheet's preview lines for Send: what goes, and to whom.
export_send_lines :: proc(app: ^App, lines: ^[dynamic]string) {
	n := len(app.scene.objects)
	append(lines, fmt.tprintf("%d %s, as Save writes the scene", n, "object" if n == 1 else "objects"))
	target := export_send_target(app)
	if target == "" {
		append(lines, "Pick a computer, or type its address")
		return
	}
	name := target[strings.index_byte(target, '|') + 1:] if strings.contains_rune(target, '|') else target
	append(lines, fmt.tprintf("To %s", name))
}
