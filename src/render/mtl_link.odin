#+build darwin
package render

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:sync"
import "core:thread"
import "core:time"
import NS "core:sys/darwin/Foundation"
import CA "vendor:darwin/QuartzCore"

// Display-link pacing (native GPU plan 1.7b, notes/native-gpu/display-link-design.md): a
// CAMetalDisplayLink on the window's layer hands the app each drawable when the display
// wants the next frame, with a frame latency of one, so the frame reads its input as late
// as it can and still be shown at the next refresh. It is a trial, off unless asked for
// (renderer_set_display_link, Settings > System > Frame rate), and used only while one
// frame is in flight under vsync; otherwise the acquire takes nextDrawable as before.
//
// The link runs on a thread of its own, whose run loop the main thread never blocks: SDL's
// UIKit pump runs the main run loop only inside PollEvent, so an acquire waiting on the
// main thread would never see a link added there. Its delegate keeps only the newest
// update (an older drawable goes back to the layer), and pauses the link after a few
// refreshes nobody took, so a resting app does not wake at every refresh. Nothing in the
// Odin bindings names the link, so it is reached through the Objective-C runtime, every
// selector checked first: on any miss the window stays unlinked and the log says which.

foreign import core_foundation "system:CoreFoundation.framework"

@(private = "file", default_calling_convention = "c")
foreign core_foundation {
	CFRunLoopGetCurrent :: proc() -> rawptr ---
	CFRunLoopStop :: proc(rl: rawptr) ---
}

@(private = "file", objc_class = "CAMetalDisplayLink")
Ca_Metal_Display_Link :: struct {
	using _: NS.Object,
}

// Refreshes the delegate lets go by with no acquire before it pauses the link.
@(private = "file")
MTL_LINK_IDLE_PAUSE :: 8

// How long an acquire waits for the link before taking nextDrawable instead: two refreshes
// at 60 Hz, past any refresh the link might miss as it starts or resumes.
@(private = "file")
MTL_LINK_WAIT :: 34 * time.Millisecond

Mtl_Link :: struct {
	window:   ^Mtl_Window, // the window whose layer the link drives
	thread:   ^thread.Thread,
	run_loop: rawptr, // the link thread's CFRunLoop, for waking it
	link:     ^Ca_Metal_Display_Link,
	delegate: NS.id,
	started:  sync.Sema, // posted once the thread made the link, or failed to
	ok:       bool, // the link was made and added (read after `started`)
	quit:     bool, // atomic: the thread invalidates the link and ends
	resume:   bool, // atomic: an acquire wants a paused link running again
	lock:     sync.Mutex,
	ready:    sync.Cond, // signalled when a drawable comes while the slot was empty
	// The newest update's drawable, retained, until an acquire takes it or a newer one
	// replaces it.
	drawable: ^CA.MetalDrawable,
	idle:     int, // updates since the last acquire
	paused:   bool,
	// Whether the delegate keeps the newest drawable for the next acquire; false while
	// acquires take nextDrawable (two frames in flight, the link turned off, no vsync), so
	// the link never holds a drawable nextDrawable would then wait for.
	keep:     bool,
	taken:    u64, // drawables acquires took from the link
}

// The delegate's class, registered once: an NSObject whose one method is the link's
// callback, and whose extra bytes hold the Mtl_Link it serves.
@(private = "file")
mtl_link_delegate_class: NS.Class

@(private = "file")
mtl_link_needs_update :: proc "c" (self: NS.id, cmd: NS.SEL, link: NS.id, update: NS.id) {
	context = runtime.default_context()
	NS.scoped_autoreleasepool()
	l := (^^Mtl_Link)(NS.object_getIndexedIvars(self))^
	if l == nil || update == nil do return
	drawable := intrinsics.objc_send(^CA.MetalDrawable, (^NS.Object)(update), "drawable")
	sync.guard(&l.lock)
	l.idle += 1
	if l.keep {
		old := l.drawable
		l.drawable = drawable
		if drawable != nil do NS.retain(drawable)
		if old != nil do NS.release(old)
		if old == nil && drawable != nil do sync.cond_signal(&l.ready)
	}
	if l.idle >= MTL_LINK_IDLE_PAUSE && !l.paused {
		intrinsics.objc_send(nil, l.link, "setPaused:", NS.BOOL(true))
		l.paused = true
		// The drawable kept for nobody goes back to the layer while the link rests.
		if l.drawable != nil {
			NS.release(l.drawable)
			l.drawable = nil
		}
	}
}

@(private = "file")
mtl_link_class :: proc() -> NS.Class {
	if mtl_link_delegate_class != nil do return mtl_link_delegate_class
	if found := NS.objc_lookUpClass("SculptDisplayLinkDelegate"); found != nil {
		mtl_link_delegate_class = found
		return found
	}
	class := NS.objc_allocateClassPair(NS.objc_lookUpClass("NSObject"), "SculptDisplayLinkDelegate", 0)
	if class == nil do return nil
	if protocol := NS.objc_getProtocol("CAMetalDisplayLinkDelegate"); protocol != nil do NS.class_addProtocol(class, protocol)
	NS.class_addMethod(class, NS.sel_registerName("metalDisplayLink:needsUpdate:"), auto_cast mtl_link_needs_update, "v@:@@")
	NS.objc_registerClassPair(class)
	mtl_link_delegate_class = class
	return class
}

// Whether `object` answers `selector`, logging the miss.
@(private = "file")
mtl_link_answers :: proc(object: ^NS.Object, selector: cstring) -> bool {
	if object != nil && bool(intrinsics.objc_send(NS.BOOL, object, "respondsToSelector:", NS.sel_registerName(selector))) do return true
	log.warnf("display link: no %s; the window stays unlinked", selector)
	return false
}

// The link thread: makes the link on the window's layer, adds it to this thread's run
// loop, and runs that loop until told to quit, then invalidates the link.
@(private = "file")
mtl_link_thread :: proc(data: rawptr) {
	l := (^Mtl_Link)(data)
	{
		NS.scoped_autoreleasepool()
		l.run_loop = CFRunLoopGetCurrent()
		l.ok = mtl_link_make(l)
	}
	sync.sema_post(&l.started)
	if !l.ok do return
	run_loop := intrinsics.objc_send(^NS.Object, NS.RunLoop, "currentRunLoop")
	for !sync.atomic_load(&l.quit) {
		NS.scoped_autoreleasepool()
		if sync.atomic_exchange(&l.resume, false) {
			sync.guard(&l.lock)
			if l.paused {
				intrinsics.objc_send(nil, l.link, "setPaused:", NS.BOOL(false))
				l.paused = false
			}
		}
		until := NS.Date_dateWithTimeIntervalSinceNow(0.25)
		_ = intrinsics.objc_send(NS.BOOL, run_loop, "runMode:beforeDate:", NS.DefaultRunLoopMode, until)
	}
	NS.scoped_autoreleasepool()
	intrinsics.objc_send(nil, l.link, "invalidate")
	NS.release(l.link)
	NS.release((^NS.Object)(l.delegate))
	l.link, l.delegate = nil, nil
}

@(private = "file")
mtl_link_make :: proc(l: ^Mtl_Link) -> bool {
	class := mtl_link_class()
	if class == nil {
		log.warn("display link: could not register the delegate class; the window stays unlinked")
		return false
	}
	allocated := intrinsics.objc_send(^Ca_Metal_Display_Link, Ca_Metal_Display_Link, "alloc")
	if allocated == nil {
		log.warn("display link: no CAMetalDisplayLink; the window stays unlinked")
		return false
	}
	if !mtl_link_answers(allocated, "initWithMetalLayer:") {
		NS.release(allocated)
		return false
	}
	link := intrinsics.objc_send(^Ca_Metal_Display_Link, allocated, "initWithMetalLayer:", l.window.layer)
	if link == nil do return false
	for selector in ([?]cstring{"setDelegate:", "setPreferredFrameLatency:", "setPaused:", "addToRunLoop:forMode:", "invalidate"}) {
		if !mtl_link_answers(link, selector) {
			NS.release(link)
			return false
		}
	}
	delegate := NS.class_createInstance(class, size_of(^Mtl_Link))
	if delegate == nil {
		NS.release(link)
		return false
	}
	(^^Mtl_Link)(NS.object_getIndexedIvars(delegate))^ = l
	l.link, l.delegate = link, delegate
	intrinsics.objc_send(nil, link, "setDelegate:", delegate)
	intrinsics.objc_send(nil, link, "setPreferredFrameLatency:", f32(1))
	run_loop := intrinsics.objc_send(^NS.Object, NS.RunLoop, "currentRunLoop")
	intrinsics.objc_send(nil, link, "addToRunLoop:forMode:", run_loop, NS.DefaultRunLoopMode)
	log.info("display link: pacing the window's frames")
	return true
}

// Starts a link on `w`'s layer, or returns nil (logged) where it cannot be made.
@(private = "file")
mtl_link_start :: proc(w: ^Mtl_Window) -> ^Mtl_Link {
	l := new(Mtl_Link)
	l.window = w
	l.thread = thread.create_and_start_with_data(l, mtl_link_thread)
	if l.thread == nil {
		free(l)
		return nil
	}
	sync.sema_wait(&l.started)
	if !l.ok {
		thread.join(l.thread)
		thread.destroy(l.thread)
		free(l)
		return nil
	}
	return l
}

// Stops the link and its thread and lets go of a drawable it kept.
mtl_link_stop :: proc() {
	l := mtl_state.link
	if l == nil do return
	mtl_state.link = nil
	sync.atomic_store(&l.quit, true)
	CFRunLoopStop(l.run_loop)
	thread.join(l.thread)
	thread.destroy(l.thread)
	if l.drawable != nil do NS.release(l.drawable)
	mtl_state.link_taken += l.taken
	free(l)
}

// Tells the link to keep no drawable, as acquires take nextDrawable for now, and gives back
// the one it kept.
@(private = "file")
mtl_link_unused :: proc() {
	l := mtl_state.link
	if l == nil do return
	sync.guard(&l.lock)
	l.keep = false
	if l.drawable != nil {
		NS.release(l.drawable)
		l.drawable = nil
	}
}

// The drawable the link handed over for `w`'s next frame (retained, as nextDrawable's is
// after the acquire retains it), or nil to take nextDrawable instead: the link is not
// wanted, not usable for this window, or gave nothing in time. With `wait` false only a
// drawable already waiting is taken, and `busy` says there is none yet, as a busy
// swapchain gives no texture.
mtl_link_drawable :: proc(w: ^Mtl_Window, wait: bool) -> (drawable: ^CA.MetalDrawable, busy: bool) {
	if !mtl_state.link_wanted || mtl_state.frames != 1 || w.present_mode != .VSYNC || mtl_state.link_failed {
		if mtl_state.link != nil && mtl_state.link.window == w do mtl_link_unused()
		return nil, false
	}
	if mtl_state.link != nil && mtl_state.link.window != w {
		// One link at a time, on the window that waits for the display: the main one.
		if !wait do return nil, false
		mtl_link_stop()
	}
	if mtl_state.link == nil {
		if !wait do return nil, false
		mtl_state.link = mtl_link_start(w)
		if mtl_state.link == nil {
			// Not offered here: the acquire keeps nextDrawable for the rest of the run.
			mtl_state.link_failed = true
			return nil, false
		}
	}
	l := mtl_state.link
	sync.guard(&l.lock)
	l.idle = 0
	l.keep = true
	if l.paused {
		sync.atomic_store(&l.resume, true)
		CFRunLoopStop(l.run_loop)
	}
	if l.drawable == nil && wait {
		deadline := time.tick_now()
		for l.drawable == nil {
			left := MTL_LINK_WAIT - time.tick_since(deadline)
			if left <= 0 || !sync.cond_wait_with_timeout(&l.ready, &l.lock, left) do break
		}
	}
	drawable = l.drawable
	l.drawable = nil
	if drawable != nil do l.taken += 1
	return drawable, drawable == nil && !wait
}

// Drawables acquires took from the link since the device was made.
mtl_link_frames :: proc() -> u64 {
	if mtl_state.link == nil do return mtl_state.link_taken
	sync.guard(&mtl_state.link.lock)
	return mtl_state.link_taken + mtl_state.link.taken
}
