package main

import "core:fmt"
import "core:log"
import sdl "vendor:sdl3"

import "../render"
import "../ui"

// How often the app draws (Settings > System > Frame rate). Match display waits for
// the screen's refresh (vsync), so it runs at whatever the screen runs at, 60, 120 or
// 144 Hz, and never draws a frame the screen would not show. Limit draws at most
// frame_limit frames a second, shown without waiting for the refresh (mailbox where the
// screen offers it), to save the battery or to steady an uneven rate. Unlimited draws
// as fast as it can, for benchmarks. The limiter waits where vsync would, before the
// frame reads its input, so a limited frame still shows the newest pointer position.
Frame_Rate :: enum u8 {
	Match_Display,
	Limit,
	Unlimited,
}

FRAME_RATE_NAMES := [Frame_Rate]string {
	.Match_Display = "Match display",
	.Limit         = "Limit",
	.Unlimited     = "Unlimited",
}

// How far the GPU may run behind the app (Settings > System > Frame rate). One frame in
// flight shows each frame a display period sooner (8.3 ms at 120 Hz) but lets no heavy
// frame overlap the next; two is the default. During strokes keeps one only while a stroke
// or a tool's drag is under way, where the pen's latency is felt (not while the camera
// moves), and only while those frames keep up with the screen (Latency_Guard); changing
// it costs a wait for the GPU.
Low_Latency :: enum u8 {
	During_Strokes,
	Always,
	Off,
}

LOW_LATENCY_NAMES := [Low_Latency]string {
	.During_Strokes = "During strokes",
	.Always         = "Always",
	.Off            = "Off",
}

// The frames in flight `choice` asks for now, given whether the pointer is at work and
// whether one frame in flight was lately too slow for the screen (During strokes then
// keeps two; Always is the user's explicit word and keeps one).
frames_wanted :: proc(choice: Low_Latency, working: bool, too_slow := false) -> u32 {
	switch choice {
	case .Always:         return 1
	case .During_Strokes: if working && !too_slow do return 1
	case .Off:
	}
	return render.FRAMES_IN_FLIGHT_DEFAULT
}

// The limits on offer: the common screen rates, and 30 for the battery.
FRAME_LIMITS := [?]i32{30, 60, 90, 120, 144, 165, 240}
FRAME_LIMIT_NAMES := [len(FRAME_LIMITS)]string{"30 fps", "60 fps", "90 fps", "120 fps", "144 fps", "165 fps", "240 fps"}
FRAME_LIMIT_DEFAULT :: 60
FRAME_LIMIT_MIN :: 15
FRAME_LIMIT_MAX :: 1000

// During strokes' check that one frame in flight keeps up. With one frame the CPU and the
// GPU take turns, so a heavy scene can run at half the rate or worse; a refresh saved per
// frame is not worth that. When most of the recent working frames took longer than one and
// a half display periods, two frames come back for LATENCY_REST, then one is tried again.
Latency_Guard :: struct {
	ones:       int, // consecutive frames paced at one frame in flight
	slow:       int, // of the counted frames since the last verdict, how many were slow
	counted:    int,
	rest_until: u64, // SDL ticks (ns) until which During strokes keeps two frames
}

LATENCY_SAMPLES :: 8 // frames per verdict
LATENCY_SLOW_OF :: 5 // slow frames of LATENCY_SAMPLES that make the verdict slow
LATENCY_REST :: u64(20e9)

// Feeds the guard the last frame's time (ms) and says whether During strokes should keep
// two frames now. `one_in_flight` is whether the last frame ran with one; the first frame
// after a change is skipped, as it holds the change's wait for the GPU.
latency_guard_step :: proc(g: ^Latency_Guard, working, one_in_flight: bool, last_frame_ms, period_ms: f64, now: u64) -> (too_slow: bool) {
	if now < g.rest_until do return true
	if !working || !one_in_flight {
		g.ones, g.slow, g.counted = 0, 0, 0
		return false
	}
	g.ones += 1
	if g.ones < 2 do return false
	g.counted += 1
	if last_frame_ms > period_ms * 1.5 do g.slow += 1
	if g.counted < LATENCY_SAMPLES do return false
	slow := g.slow >= LATENCY_SLOW_OF
	g.slow, g.counted = 0, 0
	if !slow do return false
	g.ones = 0
	g.rest_until = now + LATENCY_REST
	return true
}

// What frame_pace keeps between frames.
Frame_Pacer :: struct {
	applied: Maybe(Frame_Rate), // the choice the present mode was last set for
	next_ns: u64, // when the next limited frame may start (SDL ticks)
	// The Android window the display rate was last asked for, and the rate asked; a new
	// surface (back from the background) or another choice asks again.
	voted_window: rawptr,
	voted_rate:   f32,
	top_rate:     f32, // the highest rate the screen offers, as Android reports it (0: not known)
	// The present modes the window offers besides vsync, as last applied (present_offers).
	offers_mailbox, offers_immediate: bool,
	latency: Latency_Guard,
}

// Applies the frame rate choice before the frame acquires its swapchain texture: the
// present mode (which recreates the swapchain), the rate Android is asked to run the
// screen at, then the limiter's wait. Called where the frame waits for the display.
frame_pace :: proc(app: ^App, window: ^sdl.Window) {
	p := &app.pacer
	if applied, ok := p.applied.?; !ok || applied != app.frame_rate {
		p.applied = app.frame_rate
		log.infof("frame rate: %v", app.frame_rate)
		// Where the screen offers only vsync (many Android drivers), Limit still limits
		// and Unlimited runs at the refresh rate; the panel says which mode is in use.
		_ = render.renderer_set_vsync(&app.renderer, app.frame_rate == .Match_Display)
		p.offers_mailbox, p.offers_immediate = render.renderer_present_offers(&app.renderer)
		log.infof("present mode: %s; offered besides vsync: %s", render.renderer_present_name(&app.renderer), present_offers(app))
	}
	frame_rate_vote(app, window)
	// Only a tool's drag: a camera drag is not work the pen's latency is felt in, and one
	// frame in flight would make orbiting a heavy scene wait for the GPU every frame, which
	// is what During strokes exists to avoid.
	working := app.stroke.active || app.drag.owner == .Tool || app.drag.owner == .Shape
	too_slow := false
	if app.low_latency == .During_Strokes {
		hz := f64(app.frame_limit) if app.frame_rate == .Limit else f64(display_refresh(window))
		period_ms := 1000 / (hz if hz > 0 else 60)
		r := app.stats.frame_ms
		last_ms := f64(r.values[(r.head + HISTORY - 1) % HISTORY]) if r.count > 0 else 0
		one := render.caps(&app.renderer).frames_in_flight == 1
		too_slow = latency_guard_step(&p.latency, working, one, last_ms, period_ms, sdl.GetTicksNS())
	}
	_ = render.renderer_set_frames_in_flight(&app.renderer, frames_wanted(app.low_latency, working, too_slow))
	render.renderer_set_display_link(&app.renderer, app.display_link)
	if app.frame_rate != .Limit {
		p.next_ns = 0
		return
	}
	period := u64(1e9) / u64(clamp(app.frame_limit, FRAME_LIMIT_MIN, FRAME_LIMIT_MAX))
	now := sdl.GetTicksNS()
	if p.next_ns > now {
		sdl.DelayPrecise(p.next_ns - now)
		p.next_ns += period
	} else if now - p.next_ns < period {
		// A little late: keep the beat, so the rate averages out at the limit.
		p.next_ns += period
	} else {
		// Far behind (a slow frame, or the first): start the beat again from now.
		p.next_ns = now + period
	}
}

// The refresh rate of the screen the window is on, in Hz, 0 when SDL does not know.
display_refresh :: proc(window: ^sdl.Window) -> f32 {
	display := sdl.GetDisplayForWindow(window)
	if display == 0 do return 0
	mode := sdl.GetCurrentDisplayMode(display)
	return mode.refresh_rate if mode != nil else 0
}

// The frame rate choice and what the screen does with it, for Settings > System and,
// without the explanations, the Stats panel's Advanced view.
frame_rate_controls :: proc(app: ^App, explain := true) {
	ctx := &app.kit.ctx
	names: [len(Frame_Rate)]string
	for f in Frame_Rate do names[int(f)] = FRAME_RATE_NAMES[f]
	ui.label(ctx, "Frame rate")
	if picked := ui.tabs(ctx, "Frame rate", names[:], int(app.frame_rate)); picked >= 0 do app.frame_rate = Frame_Rate(picked)
	switch app.frame_rate {
	case .Match_Display:
		if explain do ui.paragraph(ctx, "Draws in step with the screen's refresh, as fast as the screen can show and no faster: no tearing, and no frames drawn that would never be seen.")
	case .Limit:
		chosen := -1
		for n, i in FRAME_LIMITS do if n == app.frame_limit do chosen = i
		if chosen < 0 do ui.value_row(ctx, "Limit now", fmt.tprintf("%d frames per second", app.frame_limit))
		if picked := ui.select(ctx, "Frames per second", FRAME_LIMIT_NAMES[:], max(chosen, 0)); picked >= 0 do app.frame_limit = FRAME_LIMITS[picked]
		if explain do ui.paragraph(ctx, "At most this many frames a second, to save the battery or to keep the rate even. Frames show as soon as they are ready, without tearing where the screen allows.")
	case .Unlimited:
		if explain do ui.paragraph(ctx, "As many frames as the computer can draw, for measuring speed. Most are never seen, and the battery and fans pay for them.")
	}
	ui.paragraph(ctx, frame_rate_status(app), color = ctx.theme.text_secondary)
	ui.label(ctx, "Low latency")
	low: [len(Low_Latency)]string
	for l in Low_Latency do low[int(l)] = LOW_LATENCY_NAMES[l]
	if picked := ui.tabs(ctx, "Low latency", low[:], int(app.low_latency)); picked >= 0 do app.low_latency = Low_Latency(picked)
	if explain do ui.paragraph(ctx, "Lets the GPU run one frame behind instead of two, so what you draw shows a refresh sooner (8 ms at 120 Hz). During strokes does it only while you draw or drag a tool, and only while those frames keep up with the screen, so orbiting or sculpting a heavy scene keeps its frame rate; Always does it all the time; Off keeps two. If the view lags or stutters, try Off. Under Metal it also holds one picture fewer for the screen, so the frame reads your pen nearer to when it shows.")
	if render.caps(&app.renderer).display_link {
		_ = ui.switch_row(ctx, "Pace with the display (trial)", &app.display_link)
		if explain do ui.paragraph(ctx, "While one frame is in flight, the screen hands each frame its picture when it wants the next one, so the frame reads your pen as late as it can and still shows at the next refresh. A trial until Pen to screen below shows it helps; off takes the next free picture, as before.")
	}
	frames := render.caps(&app.renderer).frames_in_flight
	if app.stats.display_ms.count > 0 {
		shown50, _ := ring_percentiles(app.stats.display_ms)
		ui.paragraph(ctx, fmt.tprintf("Frames in flight now: %d. Pen to screen while sculpting: %.1f ms typical.", frames, shown50), color = ctx.theme.text_secondary)
	} else {
		ui.paragraph(ctx, fmt.tprintf("Frames in flight now: %d.", frames), color = ctx.theme.text_secondary)
	}
}

// The modes the window offers besides vsync, as "mailbox,immediate" or "none". Temp-allocated.
present_offers :: proc(app: ^App) -> string {
	p := app.pacer
	switch {
	case p.offers_mailbox && p.offers_immediate: return "mailbox,immediate"
	case p.offers_mailbox:                       return "mailbox"
	case p.offers_immediate:                     return "immediate"
	}
	return "none"
}

// What the screen runs at and how frames reach it, in plain words. Temp-allocated.
@(private = "file")
frame_rate_status :: proc(app: ^App) -> string {
	hz := display_refresh(app.window)
	screen := fmt.tprintf("The screen refreshes at %.0f Hz", hz) if hz > 0 else "The screen does not report its refresh rate"
	when ODIN_PLATFORM_SUBTARGET == .Android {
		top := app.pacer.top_rate
		if top > 0 && top > hz + 0.5 do screen = fmt.tprintf("%s (up to %.0f Hz; the system picks)", screen, top)
	}
	shown: string
	switch app.renderer.present_mode {
	case .VSYNC:     shown = "frames wait for its refresh"
	case .MAILBOX:   shown = "frames show as soon as they are ready (mailbox)"
	case .IMMEDIATE: shown = "frames show as soon as they are ready, and may tear (immediate)"
	}
	return fmt.tprintf("%s; %s.", screen, shown)
}

when ODIN_PLATFORM_SUBTARGET == .Android {
	// android/app/jni/android_main.c: asks Android to run the screen at `rate` Hz for the
	// window (0: the highest the screen offers) and returns the highest it offers, 0 when
	// it cannot tell.
	@(default_calling_convention = "c")
	foreign {
		sculpt_android_frame_rate :: proc(native_window: rawptr, rate: f32) -> f32 ---
	}
}

// Android runs an app's screen at 60 Hz unless the app asks for more, even on a 120 Hz
// tablet; so Match display and Unlimited ask for the screen's highest rate, and Limit for
// the limit (a screen that can run slower saves power). Asked again whenever the window's
// surface is new. Elsewhere the system runs the screen at the rate it is set to.
@(private = "file")
frame_rate_vote :: proc(app: ^App, window: ^sdl.Window) {
	when ODIN_PLATFORM_SUBTARGET == .Android {
		p := &app.pacer
		native := sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_ANDROID_WINDOW_POINTER, nil)
		rate := f32(clamp(app.frame_limit, FRAME_LIMIT_MIN, FRAME_LIMIT_MAX)) if app.frame_rate == .Limit else 0
		if native == nil || (native == p.voted_window && rate == p.voted_rate) do return
		p.voted_window, p.voted_rate = native, rate
		p.top_rate = sculpt_android_frame_rate(native, rate)
		log.infof("frame rate: asked Android for %v Hz (the screen offers up to %.0f Hz)", rate if rate > 0 else p.top_rate, p.top_rate)
	} else {
		_, _ = app, window
	}
}
