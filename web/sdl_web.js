"use strict";
// The web version's platform (README "Web"): what SDL does for the app on the desktop,
// done with the browser, as the wasm imports src/app and src/render call. SDL's procs are
// the "sdl3" imports (vendor:sdl3 built with -define:SDL3_WASM_LIB=sdl3), the page's own
// are "sculpt_page" (src/app/web.odin), the files are "sculpt_fs" (core:os on js, from
// web/odin_overlay/core/os/file_js.odin) and FBX's are "sculpt_fbx" (src/fbx, which says
// it cannot read a file here).
//
// The canvas's pointer, wheel and key events become SDL events laid out as SDL_Event is on
// js_wasm64p32, queued for the app's own SDL_PollEvent loop: the mouse as the mouse, a
// pen as SDL's pen events plus the mouse marked SDL_PEN_MOUSEID, fingers as SDL's finger
// events. The files are kept here by path and saved in the browser's IndexedDB, so the
// settings, the library and the scenes saved stay between visits; Save and Export hand
// the file written to the browser's downloads, and Open reads one the person picks.
//
// Odin's int is 64 bits on js_wasm64p32 and pointers 32, so lengths and sizes cross as
// BigInt and pointers as numbers. Nothing here blocks: SDL's waits return at once, as
// the page calls the app once a frame (web.odin).

const SculptWeb = (() => {

const UNWIND = { unwind: "the app's run leaves to the page's frame loop (web.odin)" };

// SDL_EventType values the page sends.
const EV = {
	QUIT: 0x100, WILL_ENTER_BACKGROUND: 0x103, DID_ENTER_BACKGROUND: 0x104,
	WILL_ENTER_FOREGROUND: 0x105, DID_ENTER_FOREGROUND: 0x106,
	WINDOW_SHOWN: 0x202, WINDOW_EXPOSED: 0x204, WINDOW_RESIZED: 0x206, WINDOW_PIXEL_SIZE_CHANGED: 0x207,
	WINDOW_MOUSE_ENTER: 0x20c, WINDOW_MOUSE_LEAVE: 0x20d, WINDOW_FOCUS_GAINED: 0x20e, WINDOW_FOCUS_LOST: 0x20f,
	WINDOW_DISPLAY_SCALE_CHANGED: 0x214,
	KEY_DOWN: 0x300, KEY_UP: 0x301, TEXT_INPUT: 0x303,
	MOUSE_MOTION: 0x400, MOUSE_BUTTON_DOWN: 0x401, MOUSE_BUTTON_UP: 0x402, MOUSE_WHEEL: 0x403,
	FINGER_DOWN: 0x700, FINGER_UP: 0x701, FINGER_MOTION: 0x702, FINGER_CANCELED: 0x703,
	PEN_PROXIMITY_IN: 0x1300, PEN_PROXIMITY_OUT: 0x1301, PEN_DOWN: 0x1302, PEN_UP: 0x1303,
	PEN_BUTTON_DOWN: 0x1304, PEN_BUTTON_UP: 0x1305, PEN_MOTION: 0x1306, PEN_AXIS: 0x1307,
	DROP_FILE: 0x1000,
	USER: 0x8000,
};
const EVENT_SIZE = 128;
const WINDOW_ID = 1;
const WINDOW_HANDLE = 0x10; // an address the app only compares, never reads
const MOUSE_ID = 1;
const PEN_MOUSEID = 0xfffffffe;
const PEN_ID = 1;
const TOUCH_ID = 1n;

// SDL keycodes and scancodes by the DOM's KeyboardEvent.code.
const SCANCODE_MASK = 0x40000000;
const KEYS = {};
function key(code, scancode, keycode, name) { KEYS[code] = { scancode, keycode: keycode ?? (scancode | SCANCODE_MASK), name }; }
for (let i = 0; i < 26; i++) { const c = String.fromCharCode(65 + i); key("Key" + c, 4 + i, 97 + i, c); }
for (let i = 1; i <= 9; i++) key("Digit" + i, 29 + i, 48 + i, String(i));
key("Digit0", 39, 48, "0");
key("Enter", 40, 0x0d, "Return"); key("Escape", 41, 0x1b, "Escape"); key("Backspace", 42, 0x08, "Backspace");
key("Tab", 43, 0x09, "Tab"); key("Space", 44, 0x20, "Space"); key("Minus", 45, 0x2d, "-"); key("Equal", 46, 0x3d, "=");
key("BracketLeft", 47, 0x5b, "["); key("BracketRight", 48, 0x5d, "]"); key("Backslash", 49, 0x5c, "\\");
key("Semicolon", 51, 0x3b, ";"); key("Quote", 52, 0x27, "'"); key("Backquote", 53, 0x60, "`");
key("Comma", 54, 0x2c, ","); key("Period", 55, 0x2e, "."); key("Slash", 56, 0x2f, "/"); key("CapsLock", 57, undefined, "CapsLock");
for (let i = 1; i <= 12; i++) key("F" + i, 57 + i, undefined, "F" + i);
key("PrintScreen", 70, undefined, "PrintScreen"); key("ScrollLock", 71, undefined, "ScrollLock"); key("Pause", 72, undefined, "Pause");
key("Insert", 73, undefined, "Insert"); key("Home", 74, undefined, "Home"); key("PageUp", 75, undefined, "PageUp");
key("Delete", 76, 0x7f, "Delete"); key("End", 77, undefined, "End"); key("PageDown", 78, undefined, "PageDown");
key("ArrowRight", 79, undefined, "Right"); key("ArrowLeft", 80, undefined, "Left"); key("ArrowDown", 81, undefined, "Down"); key("ArrowUp", 82, undefined, "Up");
key("NumLock", 83, undefined, "Numlock"); key("NumpadDivide", 84, undefined, "Keypad /"); key("NumpadMultiply", 85, undefined, "Keypad *");
key("NumpadSubtract", 86, undefined, "Keypad -"); key("NumpadAdd", 87, undefined, "Keypad +"); key("NumpadEnter", 88, undefined, "Keypad Enter");
for (let i = 1; i <= 9; i++) key("Numpad" + i, 88 + i, undefined, "Keypad " + i);
key("Numpad0", 98, undefined, "Keypad 0"); key("NumpadDecimal", 99, undefined, "Keypad .");
key("ContextMenu", 101, undefined, "Menu");
key("ControlLeft", 224, undefined, "Left Ctrl"); key("ShiftLeft", 225, undefined, "Left Shift"); key("AltLeft", 226, undefined, "Left Alt"); key("MetaLeft", 227, undefined, "Left GUI");
key("ControlRight", 228, undefined, "Right Ctrl"); key("ShiftRight", 229, undefined, "Right Shift"); key("AltRight", 230, undefined, "Right Alt"); key("MetaRight", 231, undefined, "Right GUI");
const BY_KEYCODE = new Map(Object.values(KEYS).map((k) => [k.keycode >>> 0, k]));
const BY_NAME = new Map(Object.values(KEYS).map((k) => [k.name.toLowerCase(), k]));
// SDL_Keymod bits.
const KMOD = { ShiftLeft: 0x1, ShiftRight: 0x2, ControlLeft: 0x40, ControlRight: 0x80, AltLeft: 0x100, AltRight: 0x200, MetaLeft: 0x400, MetaRight: 0x800 };
const KMOD_CAPS = 0x2000;
const MAC = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

class Web {
	constructor(canvas, memory, failure) {
		this.canvas = canvas;
		this.memory = memory;
		this.failure = failure; // (message) => void, shows the page's failure note
		this.exports = null;
		this.queue = [];
		this.error = "";
		this.hints = new Map();
		this.props = new Map();
		this.nextProps = 1;
		this.statics = new Map();
		this.watches = [];
		this.nextUserEvent = EV.USER;
		this.held = new Set(); // DOM codes of keys held
		this.caps = false;
		this.buttons = 0; // SDL button mask of the mouse
		this.textInput = false;
		this.clipboard = "";
		this.ended = false;
		this.ios = new Map();
		this.nextIo = 1;
		this.textRing = [];
		this.textNext = 0;
		this.cssSize = [1, 1];
		this.pixelSize = [1, 1];
		this.dpr = 1;
		this.pen = { near: false, down: false, pressure: 0, tiltX: 0, tiltY: 0 };
		this.fs = new Files();
	}

	// Memory ----------------------------------------------------------------------------

	view() { return new DataView(this.memory.buffer); }
	bytes() { return new Uint8Array(this.memory.buffer); }
	string(ptr, len) { return new TextDecoder().decode(this.bytes().subarray(ptr, ptr + Number(len))); }
	cstring(ptr) {
		if (!ptr) return "";
		const b = this.bytes();
		let end = ptr;
		while (b[end]) end++;
		return new TextDecoder().decode(b.subarray(ptr, end));
	}
	alloc(size) { return this.exports.sculpt_web_alloc(BigInt(size)); }
	free(ptr) { if (ptr) this.exports.sculpt_web_free(ptr); }
	// A C string the caller frees with SDL_free.
	newCstring(text) {
		const data = new TextEncoder().encode(text);
		const ptr = this.alloc(data.length + 1);
		const b = this.bytes();
		b.set(data, ptr);
		b[ptr + data.length] = 0;
		return ptr;
	}
	// A C string the page keeps, one for each text, as SDL keeps the strings it hands out.
	staticCstring(text) {
		let ptr = this.statics.get(text);
		if (ptr === undefined) {
			ptr = this.newCstring(text);
			this.statics.set(text, ptr);
		}
		return ptr;
	}
	// The text of a text input event, in one of a few buffers used in turn, as SDL's last
	// until the next events are polled.
	eventText(text) {
		const data = new TextEncoder().encode(text).subarray(0, 255);
		if (this.textRing.length === 0) for (let i = 0; i < 16; i++) this.textRing.push(this.alloc(256));
		const ptr = this.textRing[this.textNext++ % this.textRing.length];
		const b = this.bytes();
		b.set(data, ptr);
		b[ptr + data.length] = 0;
		return ptr;
	}
	call(fn, ...args) { return this.exports.__indirect_function_table.get(fn)(...args); }

	// Events ----------------------------------------------------------------------------

	ticks() { return BigInt(Math.round(performance.now() * 1e6)); }
	event(type) {
		const e = new Uint8Array(EVENT_SIZE);
		const v = new DataView(e.buffer);
		v.setUint32(0, type, true);
		v.setBigUint64(8, this.ticks(), true);
		return [e, v];
	}
	push(e) { this.queue.push(e); }
	windowEvent(type, d1 = 0, d2 = 0) {
		const [e, v] = this.event(type);
		v.setUint32(16, WINDOW_ID, true);
		v.setInt32(20, d1, true);
		v.setInt32(24, d2, true);
		this.push(e);
	}
	mods(e) {
		let m = 0;
		for (const code of this.held) m |= KMOD[code] || 0;
		if (e) {
			if (e.shiftKey && !(m & 0x3)) m |= 0x1;
			if (e.ctrlKey && !(m & 0xc0)) m |= 0x40;
			if (e.altKey && !(m & 0x300)) m |= 0x100;
			if (e.metaKey && !(m & 0xc00)) m |= 0x400;
			this.caps = e.getModifierState ? e.getModifierState("CapsLock") : this.caps;
		}
		// On a Mac, Cmd is the shortcut key, which the app reads as Ctrl on every platform
		// but macOS (device.odin's KMOD_SHORTCUT).
		if (MAC && (m & 0xc00)) m |= 0x40;
		if (this.caps) m |= KMOD_CAPS;
		return m;
	}

	// The canvas's size: CSS pixels are SDL's window coordinates, and the drawing buffer is
	// that times the device pixel ratio, as a high pixel density window is.
	layout(announce) {
		const dpr = window.devicePixelRatio || 1;
		const rect = this.canvas.getBoundingClientRect();
		const css = [Math.max(1, Math.round(rect.width)), Math.max(1, Math.round(rect.height))];
		const px = [Math.max(1, Math.round(rect.width * dpr)), Math.max(1, Math.round(rect.height * dpr))];
		const dprChanged = dpr !== this.dpr;
		const cssChanged = css[0] !== this.cssSize[0] || css[1] !== this.cssSize[1];
		const pxChanged = px[0] !== this.pixelSize[0] || px[1] !== this.pixelSize[1];
		this.dpr = dpr;
		this.cssSize = css;
		this.pixelSize = px;
		if (pxChanged) {
			this.canvas.width = px[0];
			this.canvas.height = px[1];
		}
		if (!announce) return;
		if (dprChanged) this.windowEvent(EV.WINDOW_DISPLAY_SCALE_CHANGED);
		if (cssChanged) this.windowEvent(EV.WINDOW_RESIZED, css[0], css[1]);
		if (pxChanged) this.windowEvent(EV.WINDOW_PIXEL_SIZE_CHANGED, px[0], px[1]);
	}

	at(e) {
		const r = this.canvas.getBoundingClientRect();
		return [e.clientX - r.left, e.clientY - r.top];
	}
	static sdlButton(button) { return [1, 2, 3, 4, 5][button] ?? 1; }
	static sdlButtons(buttons) {
		// DOM: 1 left, 2 right, 4 middle, 8 back, 16 forward; SDL: 1 << (button - 1).
		return (buttons & 1 ? 1 : 0) | (buttons & 4 ? 2 : 0) | (buttons & 2 ? 4 : 0) | (buttons & 8 ? 8 : 0) | (buttons & 16 ? 16 : 0);
	}
	mouseMotion(which, x, y, dx, dy) {
		const [e, v] = this.event(EV.MOUSE_MOTION);
		v.setUint32(16, WINDOW_ID, true);
		v.setUint32(20, which, true);
		v.setUint32(24, this.buttons, true);
		v.setFloat32(28, x, true); v.setFloat32(32, y, true);
		v.setFloat32(36, dx, true); v.setFloat32(40, dy, true);
		this.push(e);
	}
	mouseButton(which, button, down, clicks, x, y) {
		const [e, v] = this.event(down ? EV.MOUSE_BUTTON_DOWN : EV.MOUSE_BUTTON_UP);
		v.setUint32(16, WINDOW_ID, true);
		v.setUint32(20, which, true);
		v.setUint8(24, button);
		v.setUint8(25, down ? 1 : 0);
		v.setUint8(26, clicks);
		v.setFloat32(28, x, true); v.setFloat32(32, y, true);
		this.push(e);
	}
	penEvent(type, x, y, extra) {
		const [e, v] = this.event(type);
		v.setUint32(16, WINDOW_ID, true);
		v.setUint32(20, PEN_ID, true);
		if (type !== EV.PEN_PROXIMITY_IN && type !== EV.PEN_PROXIMITY_OUT) {
			v.setUint32(24, this.pen.down ? 1 : 0, true);
			v.setFloat32(28, x, true); v.setFloat32(32, y, true);
			if (extra) extra(v);
		}
		this.push(e);
	}
	penAxis(axis, value, x, y) {
		this.penEvent(EV.PEN_AXIS, x, y, (v) => { v.setInt32(36, axis, true); v.setFloat32(40, value, true); });
	}
	finger(type, e, prev) {
		const [ev, v] = this.event(type);
		const [x, y] = this.at(e);
		const [w, h] = this.cssSize;
		v.setBigUint64(16, TOUCH_ID, true);
		v.setBigUint64(24, BigInt(e.pointerId), true);
		v.setFloat32(32, x / w, true); v.setFloat32(36, y / h, true);
		v.setFloat32(40, prev ? (x - prev[0]) / w : 0, true); v.setFloat32(44, prev ? (y - prev[1]) / h : 0, true);
		v.setFloat32(48, type === EV.FINGER_UP || type === EV.FINGER_CANCELED ? 0 : (e.pressure || 1), true);
		v.setUint32(52, WINDOW_ID, true);
		this.push(ev);
	}

	listen() {
		const c = this.canvas;
		const last = new Map(); // pointer id -> [x, y]
		const clicks = { at: 0, count: 0, button: -1 };
		const pen = (e) => {
			const [x, y] = this.at(e);
			if (!this.pen.near) {
				this.pen.near = true;
				this.penEvent(EV.PEN_PROXIMITY_IN, x, y);
			}
			if (e.pressure !== this.pen.pressure) {
				this.pen.pressure = e.pressure;
				this.penAxis(0, e.pressure, x, y);
			}
			if (e.tiltX !== this.pen.tiltX) { this.pen.tiltX = e.tiltX; this.penAxis(1, e.tiltX || 0, x, y); }
			if (e.tiltY !== this.pen.tiltY) { this.pen.tiltY = e.tiltY; this.penAxis(2, e.tiltY || 0, x, y); }
			return [x, y];
		};
		c.addEventListener("pointerdown", (e) => {
			e.preventDefault();
			c.setPointerCapture(e.pointerId);
			c.focus();
			const at = this.at(e);
			if (e.pointerType === "touch") {
				this.finger(EV.FINGER_DOWN, e);
			} else {
				const button = Web.sdlButton(e.button);
				const eraser = e.pointerType === "pen" && (e.button === 5 || (e.buttons & 32) !== 0);
				if (e.pointerType === "pen") {
					const [x, y] = pen(e);
					if (e.button === 0 || eraser) {
						this.pen.down = true;
						this.penEvent(EV.PEN_DOWN, x, y, (v) => { v.setUint8(36, eraser ? 1 : 0); v.setUint8(37, 1); });
					} else {
						this.penEvent(EV.PEN_BUTTON_DOWN, x, y, (v) => { v.setUint8(36, button === 3 ? 1 : 2); v.setUint8(37, 1); });
					}
				}
				const now = performance.now();
				clicks.count = now - clicks.at < 400 && clicks.button === button ? clicks.count + 1 : 1;
				clicks.at = now; clicks.button = button;
				this.buttons = Web.sdlButtons(e.buttons);
				this.mouseButton(e.pointerType === "pen" ? PEN_MOUSEID : MOUSE_ID, button, true, clicks.count, at[0], at[1]);
			}
			last.set(e.pointerId, at);
		});
		const move = (e) => {
			const events = e.getCoalescedEvents ? e.getCoalescedEvents() : [];
			for (const one of events.length ? events : [e]) {
				const at = this.at(one);
				const prev = last.get(e.pointerId);
				if (e.pointerType === "touch") {
					if (!prev) continue;
					this.finger(EV.FINGER_MOTION, one, prev);
				} else {
					if (e.pointerType === "pen") {
						const [x, y] = pen(one);
						this.penEvent(EV.PEN_MOTION, x, y);
					}
					this.buttons = Web.sdlButtons(e.buttons);
					this.mouseMotion(e.pointerType === "pen" ? PEN_MOUSEID : MOUSE_ID, at[0], at[1], prev ? at[0] - prev[0] : 0, prev ? at[1] - prev[1] : 0);
				}
				last.set(e.pointerId, at);
			}
		};
		c.addEventListener("pointermove", move);
		const up = (e, canceled) => {
			const at = this.at(e);
			if (e.pointerType === "touch") {
				if (last.has(e.pointerId)) this.finger(canceled ? EV.FINGER_CANCELED : EV.FINGER_UP, e, last.get(e.pointerId));
				last.delete(e.pointerId);
				return;
			}
			const button = Web.sdlButton(e.button);
			if (e.pointerType === "pen") {
				const [x, y] = pen(e);
				if (this.pen.down && (e.button === 0 || e.button === 5 || canceled)) {
					this.pen.down = false;
					this.penEvent(EV.PEN_UP, x, y, (v) => { v.setUint8(36, e.button === 5 ? 1 : 0); v.setUint8(37, 0); });
				} else if (e.button > 0) {
					this.penEvent(EV.PEN_BUTTON_UP, x, y, (v) => { v.setUint8(36, button === 3 ? 1 : 2); v.setUint8(37, 0); });
				}
			}
			this.buttons = Web.sdlButtons(e.buttons);
			this.mouseButton(e.pointerType === "pen" ? PEN_MOUSEID : MOUSE_ID, canceled ? 1 : button, false, clicks.count, at[0], at[1]);
			last.set(e.pointerId, at);
		};
		c.addEventListener("pointerup", (e) => up(e, false));
		c.addEventListener("pointercancel", (e) => up(e, true));
		c.addEventListener("pointerleave", (e) => {
			if (e.pointerType === "pen" && this.pen.near) {
				this.pen.near = false;
				const [x, y] = this.at(e);
				this.penEvent(EV.PEN_PROXIMITY_OUT, x, y);
			}
			if (e.pointerType === "mouse") this.windowEvent(EV.WINDOW_MOUSE_LEAVE);
		});
		c.addEventListener("pointerenter", (e) => { if (e.pointerType === "mouse") this.windowEvent(EV.WINDOW_MOUSE_ENTER); });
		c.addEventListener("contextmenu", (e) => e.preventDefault());
		c.addEventListener("wheel", (e) => {
			e.preventDefault();
			// SDL's wheel steps: a notch is 1; pixels as the desktop's smooth wheels give them.
			const scale = e.deltaMode === 1 ? 1 / 3 : e.deltaMode === 2 ? 1 : 1 / 100;
			const [x, y] = this.at(e);
			const [ev, v] = this.event(EV.MOUSE_WHEEL);
			v.setUint32(16, WINDOW_ID, true);
			v.setUint32(20, MOUSE_ID, true);
			v.setFloat32(24, e.deltaX * scale, true);
			v.setFloat32(28, -e.deltaY * scale, true);
			v.setUint32(32, 0, true);
			v.setFloat32(36, x, true); v.setFloat32(40, y, true);
			v.setInt32(44, Math.trunc(e.deltaX * scale), true);
			v.setInt32(48, Math.trunc(-e.deltaY * scale), true);
			this.push(ev);
		}, { passive: false });
		// Safari's own pinch would zoom the page.
		for (const name of ["gesturestart", "gesturechange", "gestureend"]) c.addEventListener(name, (e) => e.preventDefault());
		// Files dropped on the page reach the app as SDL's drop events: a picture goes on the
		// References board, a mesh is imported, a scene opens (file_drop).
		c.addEventListener("dragover", (e) => e.preventDefault());
		c.addEventListener("drop", (e) => {
			e.preventDefault();
			const r = c.getBoundingClientRect();
			for (const file of e.dataTransfer ? e.dataTransfer.files : []) this.dropFile(file, file.name, e.clientX - r.left, e.clientY - r.top);
		});

		const keyEvent = (e, down) => {
			const k = KEYS[e.code];
			if (!k) return false;
			if (down) this.held.add(e.code); else this.held.delete(e.code);
			const [ev, v] = this.event(down ? EV.KEY_DOWN : EV.KEY_UP);
			v.setUint32(16, WINDOW_ID, true);
			v.setUint32(20, 1, true);
			v.setInt32(24, k.scancode, true);
			v.setUint32(28, k.keycode >>> 0, true);
			v.setUint16(32, this.mods(e), true);
			v.setUint8(36, down ? 1 : 0);
			v.setUint8(37, e.repeat ? 1 : 0);
			this.push(ev);
			return true;
		};
		window.addEventListener("keydown", (e) => {
			if (document.activeElement && document.activeElement !== c && document.activeElement !== document.body) return;
			keyEvent(e, true);
			const shortcut = e.ctrlKey || e.metaKey;
			if (this.textInput && e.key.length === 1 && !shortcut) {
				const [ev, v] = this.event(EV.TEXT_INPUT);
				v.setUint32(16, WINDOW_ID, true);
				v.setUint32(20, this.eventText(e.key), true);
				this.push(ev);
			}
			// The app has the keys: the browser's own shortcuts (save, find, zoom, back) and
			// Tab's focus moves would take them. Copy, cut and paste stay the browser's while
			// text is typed, so the clipboard events below come.
			// Paste always stays the browser's too, as only its event carries a picture copied
			// elsewhere, which then goes on the References board.
			const clip = shortcut && (e.code === "KeyV" || (["KeyC", "KeyX"].includes(e.code) && this.textInput));
			if (!clip && !(e.code === "F5" || e.code === "F12" || (shortcut && e.code === "KeyR"))) e.preventDefault();
		});
		window.addEventListener("keyup", (e) => { if (keyEvent(e, false)) e.preventDefault(); });
		window.addEventListener("blur", () => {
			for (const code of [...this.held]) {
				const k = KEYS[code];
				this.held.delete(code);
				const [ev, v] = this.event(EV.KEY_UP);
				v.setUint32(16, WINDOW_ID, true);
				v.setInt32(24, k.scancode, true);
				v.setUint32(28, k.keycode >>> 0, true);
				this.push(ev);
			}
			this.windowEvent(EV.WINDOW_FOCUS_LOST);
		});
		window.addEventListener("focus", () => this.windowEvent(EV.WINDOW_FOCUS_GAINED));
		window.addEventListener("paste", (e) => {
			// A picture pasted outside a text field is dropped on the app as a file is.
			const items = e.clipboardData ? [...e.clipboardData.items] : [];
			const picture = items.find((i) => i.kind === "file" && i.type.startsWith("image/"));
			const file = picture && !this.textInput ? picture.getAsFile() : null;
			if (file) {
				this.dropFile(file, "Pasted picture." + (picture.type.split("/")[1] || "png"), 0, 0);
				e.preventDefault();
				return;
			}
			const text = e.clipboardData ? e.clipboardData.getData("text/plain") : "";
			if (!text) return;
			this.clipboard = text;
			if (this.textInput) {
				const [ev, v] = this.event(EV.TEXT_INPUT);
				v.setUint32(16, WINDOW_ID, true);
				v.setUint32(20, this.eventText(text), true);
				this.push(ev);
			}
			e.preventDefault();
		});
		new ResizeObserver(() => this.layout(true)).observe(c);
		window.addEventListener("resize", () => this.layout(true));
		document.addEventListener("visibilitychange", () => {
			// SDL's background and foreground events: the app saves its settings and holds its
			// frames while the tab is hidden (idle.odin), and draws again when it is back.
			const hidden = document.visibilityState === "hidden";
			const types = hidden ? [EV.WILL_ENTER_BACKGROUND, EV.DID_ENTER_BACKGROUND] : [EV.WILL_ENTER_FOREGROUND, EV.DID_ENTER_FOREGROUND];
			for (const type of types) {
				const [ev] = this.event(type);
				this.watch(ev);
				this.push(ev);
			}
			if (hidden) this.fs.flush();
		});
		this.layout(false);
	}

	// File `file` (a Blob) handed to the page, put in its Uploads folder as `name` and sent as
	// SDL's drop event at (x, y), which the app reads through SDL_LoadFile.
	async dropFile(file, name, x, y) {
		const path = "/Uploads/" + name.replace(/[\\/]/g, "_");
		this.fs.mkdirs("/Uploads");
		this.fs.put(path, new Uint8Array(await file.arrayBuffer()), false);
		const [ev, v] = this.event(EV.DROP_FILE);
		v.setUint32(16, WINDOW_ID, true);
		v.setFloat32(20, x, true); v.setFloat32(24, y, true);
		v.setUint32(28, 0, true);
		v.setUint32(32, this.eventText(path), true);
		this.push(ev);
	}
	// The References card's Paste: the browser reads its clipboard only asynchronously, so
	// the picture it finds there comes back as a drop (dropFile) a moment later.
	clipboardPicture() {
		if (!navigator.clipboard || !navigator.clipboard.read) return;
		navigator.clipboard.read().then(async (items) => {
			for (const item of items) {
				const type = item.types.find((t) => t.startsWith("image/"));
				if (!type) continue;
				this.dropFile(await item.getType(type), "Pasted picture." + (type.split("/")[1] || "png"), 0, 0);
				return;
			}
		}).catch(() => {});
	}

	// SDL's event watches see an event as it is sent, before the queue (the app's
	// lifecycle_watch, idle.odin).
	watch(ev) {
		if (!this.exports || this.watches.length === 0) return;
		const ptr = this.scratchEvent || (this.scratchEvent = this.alloc(EVENT_SIZE));
		for (const [fn, data] of this.watches) {
			this.bytes().set(ev, ptr);
			this.call(fn, data, ptr);
		}
	}

	// File dialogs ----------------------------------------------------------------------

	// The extensions of SDL_DialogFileFilter[n] ("sculpt;obj", "*" for any), for an input's accept.
	accept(filters, n) {
		const v = this.view();
		const out = [];
		for (let i = 0; i < n; i++) {
			const pattern = this.cstring(v.getUint32(filters + 8 * i + 4, true));
			if (pattern === "*") return "";
			for (const ext of pattern.split(";")) if (ext) out.push("." + ext);
		}
		return out.join(",");
	}
	// Answers a dialog: `paths` picked (none for a cancel), or null for a failure with SDL_GetError.
	answer(callback, userdata, paths, filter) {
		if (paths === null) {
			this.call(callback, userdata, 0, filter);
			return;
		}
		const list = this.alloc(4 * (paths.length + 1));
		const v = this.view();
		paths.forEach((p, i) => v.setUint32(list + 4 * i, this.newCstring(p), true));
		v.setUint32(list + 4 * paths.length, 0, true);
		this.call(callback, userdata, list, filter);
		const v2 = this.view();
		for (let i = 0; i < paths.length; i++) this.free(v2.getUint32(list + 4 * i, true));
		this.free(list);
	}
	openDialog(callback, userdata, filters, n) {
		const input = document.createElement("input");
		input.type = "file";
		input.accept = this.accept(filters, n);
		let done = false;
		input.addEventListener("change", async () => {
			done = true;
			const file = input.files && input.files[0];
			if (!file) { this.answer(callback, userdata, [], -1); return; }
			const path = "/Uploads/" + file.name.replace(/[\\/]/g, "_");
			this.fs.mkdirs("/Uploads");
			this.fs.put(path, new Uint8Array(await file.arrayBuffer()), false);
			this.answer(callback, userdata, [path], -1);
		});
		input.addEventListener("cancel", () => { if (!done) { done = true; this.answer(callback, userdata, [], -1); } });
		input.click();
	}
	// A browser asks where to save as the download starts, so the app writes into the
	// page's Downloads folder, and each file written there goes to the browser's downloads
	// once its writes stop (Files.downloaded).
	saveDialog(callback, userdata, filters, n, location) {
		let name = location ? this.cstring(location).split(/[\\/]/).pop() : "";
		const v = this.view();
		const first = n > 0 ? this.cstring(v.getUint32(filters + 4, true)).split(";")[0] : "";
		if (!name) name = "Untitled" + (first && first !== "*" ? "." + first : "");
		this.fs.mkdirs("/Downloads");
		this.answer(callback, userdata, ["/Downloads/" + name], 0);
	}

	// The imports ----------------------------------------------------------------------

	imports() {
		const self = this;
		const fsImports = this.fs.imports(this);
		return {
			sculpt_page: {
				sculpt_page_unwind() { throw UNWIND; },
				sculpt_page_canvas_size(w, h) {
					const v = self.view();
					v.setUint32(w, self.pixelSize[0], true);
					v.setUint32(h, self.pixelSize[1], true);
				},
				sculpt_page_ended(code) {
					self.ended = true;
					if (code !== 0 && !self.failed) self.failure("Sculpt stopped. The browser's console says why.");
				},
				sculpt_page_args(buf, cap) {
					const parts = [];
					for (const [k, val] of new URLSearchParams(location.search)) parts.push(val === "" ? `--${k}` : `--${k}=${val}`);
					const data = new TextEncoder().encode(parts.map((p) => p + "\0").join(""));
					if (buf && Number(cap) >= data.length) self.bytes().set(data, buf);
					return BigInt(data.length);
				},
			},
			sculpt_fs: fsImports,
			sculpt_fbx: {
				sculpt_fbx_load(data, size, error, errorSize) {
					const text = new TextEncoder().encode("FBX files open in the desktop and tablet apps; the browser version reads OBJ, STL, PLY, glTF and USD\0");
					if (error && Number(errorSize) > 0) self.bytes().set(text.subarray(0, Number(errorSize) - 1), error);
					return 0;
				},
				sculpt_fbx_part_count: () => 0n, sculpt_fbx_rig() {}, sculpt_fbx_material_count: () => 0n, sculpt_fbx_material() {},
				sculpt_fbx_texture_file_count: () => 0n, sculpt_fbx_texture_file() {}, sculpt_fbx_part_size() {},
				sculpt_fbx_part_folders: () => 0n, sculpt_fbx_part_folder() {}, sculpt_fbx_part_fill: () => 0, sculpt_fbx_free() {},
			},
			sdl3: this.sdl(),
		};
	}

	sdl() {
		const self = this;
		const ok = 1;
		return {
			SDL_Init: () => ok,
			SDL_Quit() {},
			SDL_SetHint(name, value) { self.hints.set(self.cstring(name), self.cstring(value)); return ok; },
			SDL_GetHint(name) { const h = self.hints.get(self.cstring(name)); return h === undefined ? 0 : self.staticCstring(h); },
			SDL_GetError: () => self.staticCstring(self.error),
			SDL_SetError(fmt, args) { self.error = self.format(self.cstring(fmt), args); return 0; },
			SDL_GetPlatform: () => self.staticCstring("Web"),
			SDL_GetSystemRAM: () => Math.round((navigator.deviceMemory || 4) * 1024),
			SDL_GetSystemTheme: () => (matchMedia("(prefers-color-scheme: dark)").matches ? 2 : 1),
			SDL_free(ptr) { self.free(ptr); },
			SDL_GetTicksNS: () => self.ticks(),
			SDL_DelayNS() {},
			SDL_DelayPrecise() {},
			SDL_TimeToDateTime(ticks, dt, local) {
				const d = new Date(Number(ticks / 1000000n));
				const v = self.view();
				const fields = local
					? [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds(), Number(ticks % 1000000000n), d.getDay(), -d.getTimezoneOffset() * 60]
					: [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(), d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), Number(ticks % 1000000000n), d.getUTCDay(), 0];
				fields.forEach((x, i) => v.setInt32(dt + 4 * i, x, true));
				return ok;
			},

			// The window is the canvas.
			SDL_CreateWindow(title, w, h, flags) {
				if (self.window) { self.error = "a browser tab has one window"; return 0; }
				self.window = true;
				document.title = self.cstring(title) || document.title;
				self.listen();
				return WINDOW_HANDLE;
			},
			SDL_DestroyWindow() {},
			SDL_HideWindow: () => ok,
			SDL_GetWindowID: (w) => (w === WINDOW_HANDLE ? WINDOW_ID : 0),
			SDL_GetWindowFlags: () => BigInt((1 << 5) | (1 << 13) | (document.hasFocus() ? 1 << 9 : 0) | (1 << 10) | (document.visibilityState === "hidden" ? 1 << 2 : 0)),
			SDL_GetWindowFromEvent(ev) { return self.view().getUint32(ev + 16, true) === WINDOW_ID ? WINDOW_HANDLE : 0; },
			SDL_GetWindowSize(win, w, h) { const v = self.view(); if (w) v.setInt32(w, self.cssSize[0], true); if (h) v.setInt32(h, self.cssSize[1], true); return ok; },
			SDL_GetWindowSizeInPixels(win, w, h) { const v = self.view(); if (w) v.setInt32(w, self.pixelSize[0], true); if (h) v.setInt32(h, self.pixelSize[1], true); return ok; },
			SDL_GetWindowPixelDensity: () => self.dpr,
			SDL_GetWindowDisplayScale: () => self.dpr,
			SDL_GetWindowSafeArea(win, rect) {
				const v = self.view();
				[0, 0, self.cssSize[0], self.cssSize[1]].forEach((x, i) => v.setInt32(rect + 4 * i, x, true));
				return ok;
			},
			SDL_GetDisplayForWindow: () => 1,
			SDL_GetCurrentDisplayMode() {
				if (!self.mode) self.mode = self.alloc(40);
				const v = self.view();
				const m = self.mode;
				v.setUint32(m, 1, true); v.setUint32(m + 4, 0, true);
				v.setInt32(m + 8, Math.round(screen.width * self.dpr), true); v.setInt32(m + 12, Math.round(screen.height * self.dpr), true);
				v.setFloat32(m + 16, self.dpr, true); v.setFloat32(m + 20, 60, true);
				v.setInt32(m + 24, 60, true); v.setInt32(m + 28, 1, true); v.setUint32(m + 32, 0, true);
				return m;
			},
			SDL_ShowSimpleMessageBox(flags, title, message) {
				const text = self.cstring(title) + ": " + self.cstring(message);
				console.error(text);
				if (flags & 0x10) { self.failed = true; self.failure(self.cstring(message)); }
				return ok;
			},

			// Events.
			SDL_PumpEvents() {},
			SDL_PollEvent(ev) {
				if (!ev) return self.queue.length > 0 ? 1 : 0;
				const e = self.queue.shift();
				if (!e) return 0;
				self.bytes().set(e, ev);
				return 1;
			},
			SDL_WaitEventTimeout(ev) {
				// A page never waits: an empty queue is the timeout.
				if (!self.queue.length) return 0;
				if (ev) self.bytes().set(self.queue.shift(), ev);
				return 1;
			},
			SDL_PushEvent(ev) {
				const e = self.bytes().slice(ev, ev + EVENT_SIZE);
				self.watch(e);
				self.push(e);
				return ok;
			},
			SDL_PeepEvents(events, n, action, min, max) {
				const b = self.bytes();
				if (action === 0) { // ADDEVENT
					for (let i = 0; i < n; i++) self.push(b.slice(events + EVENT_SIZE * i, events + EVENT_SIZE * (i + 1)));
					return BigInt(n);
				}
				let count = 0;
				for (let i = 0; i < self.queue.length && count < n;) {
					const e = self.queue[i];
					const type = new DataView(e.buffer).getUint32(0, true);
					if (type >= min && type <= max) {
						if (events) b.set(e, events + EVENT_SIZE * count);
						count++;
						if (action === 2) { self.queue.splice(i, 1); continue; } // GETEVENT
					}
					i++;
				}
				return BigInt(count);
			},
			SDL_RegisterEvents(n) { const first = self.nextUserEvent; self.nextUserEvent += n; return first; },
			SDL_AddEventWatch(fn, data) { self.watches.push([fn, data]); return ok; },
			SDL_RemoveEventWatch(fn, data) { self.watches = self.watches.filter(([f, d]) => f !== fn || d !== data); },

			// Keys and text.
			SDL_GetModState: () => self.mods(null),
			SDL_GetKeyName(k) { const e = BY_KEYCODE.get(k >>> 0); return self.staticCstring(e ? e.name : k > 32 && k < 127 ? String.fromCharCode(k).toUpperCase() : ""); },
			SDL_GetKeyFromName(name) { const e = BY_NAME.get(self.cstring(name).toLowerCase()); return e ? e.keycode : 0; },
			SDL_GetScancodeFromKey(k, mod) { if (mod) self.view().setUint16(mod, 0, true); const e = BY_KEYCODE.get(k >>> 0); return e ? e.scancode : 0; },
			SDL_HasKeyboard: () => (matchMedia("(pointer: fine)").matches ? 1 : 0),
			SDL_HasScreenKeyboardSupport: () => (matchMedia("(pointer: coarse)").matches ? 1 : 0),
			SDL_ScreenKeyboardShown: () => 0,
			SDL_TextInputActive: () => (self.textInput ? 1 : 0),
			SDL_StartTextInputWithProperties() { self.textInput = true; return ok; },
			SDL_StopTextInput() { self.textInput = false; return ok; },
			SDL_SetTextInputArea: () => ok,
			SDL_GetTouchDeviceType: () => 0, // SDL_TOUCH_DEVICE_DIRECT
			SDL_SetClipboardText(text) {
				self.clipboard = self.cstring(text);
				if (navigator.clipboard) navigator.clipboard.writeText(self.clipboard).catch(() => {});
				return ok;
			},
			SDL_GetClipboardText: () => self.newCstring(self.clipboard),
			// A picture asked for starts the clipboard's asynchronous read, which drops what it
			// finds (clipboardPicture); none is there at once.
			SDL_HasClipboardData(mime) {
				if (self.cstring(mime) === "image/png") self.clipboardPicture();
				return 0;
			},
			SDL_GetClipboardData: () => 0,

			// Properties.
			SDL_CreateProperties() { const id = self.nextProps++; self.props.set(id, new Map()); return id; },
			SDL_DestroyProperties(id) { self.props.delete(id); },
			SDL_SetStringProperty(id, name, value) { self.props.get(id)?.set(self.cstring(name), self.cstring(value)); return ok; },
			SDL_SetNumberProperty(id, name, value) { self.props.get(id)?.set(self.cstring(name), value); return ok; },
			SDL_SetBooleanProperty(id, name, value) { self.props.get(id)?.set(self.cstring(name), !!value); return ok; },
			SDL_GetStringProperty(id, name, def) {
				const value = self.props.get(id)?.get(self.cstring(name));
				return typeof value === "string" ? self.staticCstring(value) : def;
			},

			// Files, through the page's own (Files).
			SDL_GetPrefPath(org, app) {
				const path = `/home/${self.cstring(org)}/${self.cstring(app)}`;
				self.fs.mkdirs(path);
				return self.newCstring(path + "/");
			},
			SDL_LoadFile(path, size) {
				const data = self.fs.get(self.cstring(path));
				if (!data) { self.error = "no such file " + self.cstring(path); return 0; }
				const ptr = self.alloc(data.length + 1);
				const b = self.bytes();
				b.set(data, ptr);
				b[ptr + data.length] = 0;
				if (size) self.view().setBigUint64(size, BigInt(data.length), true);
				return ptr;
			},
			SDL_IOFromFile(path, mode) {
				const p = self.cstring(path);
				if (!self.cstring(mode).startsWith("r")) { self.error = "the page opens files to read only through SDL"; return 0; }
				if (!self.fs.get(p)) { self.error = "no such file " + p; return 0; }
				const id = self.nextIo++;
				self.ios.set(id, { path: p, at: 0 });
				return id;
			},
			SDL_ReadIO(id, ptr, size) {
				const io = self.ios.get(id);
				const data = io && self.fs.get(io.path);
				if (!data) return 0n;
				const n = Math.min(Number(size), data.length - io.at);
				self.bytes().set(data.subarray(io.at, io.at + n), ptr);
				io.at += n;
				return BigInt(n);
			},
			SDL_CloseIO(id) { self.ios.delete(id); return ok; },
			SDL_ShowOpenFileDialog(cb, data, win, filters, n) { self.openDialog(cb, data, filters, n); },
			SDL_ShowSaveFileDialog(cb, data, win, filters, n, location) { setTimeout(() => self.saveDialog(cb, data, filters, n, location)); },
			SDL_ShowOpenFolderDialog(cb, data) {
				setTimeout(() => {
					self.error = "a browser cannot hand a folder over; pick its files instead";
					self.answer(cb, data, null, -1);
				});
			},
		};
	}

	// SDL_SetError's printf: %s, %d, %i, %u, %x, %f and %%, with the arguments as C passes
	// them on wasm32 (pointers and ints 4 bytes, doubles 8, each at its own alignment).
	format(fmt, args) {
		const v = this.view();
		let at = args;
		const next = (size) => { at = Math.ceil(at / size) * size; const p = at; at += size; return p; };
		return fmt.replace(/%(-?\d*)(l{0,2}|z)([sdiuxf%])/g, (_, width, long, kind) => {
			if (kind === "%") return "%";
			if (kind === "s") return this.cstring(v.getUint32(next(4), true));
			if (kind === "f") return String(v.getFloat64(next(8), true));
			const wide = long === "ll" || long === "z";
			const x = wide ? v.getBigInt64(next(8), true) : v.getInt32(next(4), true);
			return kind === "x" ? x.toString(16) : kind === "u" && !wide ? String(x >>> 0) : String(x);
		});
	}
}

// The page's files: each path's bytes in memory, kept in IndexedDB between visits. The
// Downloads folder is where Save and Export write (Web.saveDialog), and a file there goes
// to the browser's downloads once its writes stop; Uploads holds the files picked to open;
// tmp is not kept.
class Files {
	constructor() {
		this.entries = new Map([["/", { dir: true, mtime: Date.now() }]]);
		this.dirty = new Set();
		this.timer = 0;
		this.downloads = new Map();
		this.db = null;
	}
	static norm(path) {
		const parts = [];
		for (const p of path.replace(/\\/g, "/").split("/")) {
			if (p === "" || p === ".") continue;
			if (p === "..") parts.pop(); else parts.push(p);
		}
		return "/" + parts.join("/");
	}
	static parent(path) { const i = path.lastIndexOf("/"); return i <= 0 ? "/" : path.slice(0, i); }
	get(path) { const e = this.entries.get(Files.norm(path)); return e && !e.dir ? e.data.subarray(0, e.size) : null; }
	put(path, data, keep = true) {
		path = Files.norm(path);
		this.entries.set(path, { dir: false, data, size: data.length, mtime: Date.now() });
		if (keep) this.changed(path);
	}
	mkdirs(path) {
		path = Files.norm(path);
		let at = "";
		for (const p of path.split("/").slice(1)) {
			at += "/" + p;
			if (!this.entries.has(at)) { this.entries.set(at, { dir: true, mtime: Date.now() }); this.changed(at); }
		}
	}
	kept(path) { return !(path === "/tmp" || path.startsWith("/tmp/") || path.startsWith("/Uploads/")); }
	changed(path) {
		if (this.kept(path)) this.dirty.add(path);
		if (path.startsWith("/Downloads/") && this.entries.get(path) && !this.entries.get(path).dir) {
			clearTimeout(this.downloads.get(path));
			this.downloads.set(path, setTimeout(() => this.download(path), 400));
		}
		if (!this.timer) this.timer = setTimeout(() => this.flush(), 1000);
	}
	download(path) {
		this.downloads.delete(path);
		const data = this.get(path);
		if (!data) return;
		const a = document.createElement("a");
		a.href = URL.createObjectURL(new Blob([data]));
		a.download = path.split("/").pop();
		document.body.appendChild(a);
		a.click();
		a.remove();
		setTimeout(() => URL.revokeObjectURL(a.href), 10000);
	}

	// IndexedDB: one record a path, read whole before the app starts.
	async open() {
		if (!("indexedDB" in window)) return;
		try {
			this.db = await new Promise((ok, fail) => {
				const r = indexedDB.open("sculpt-files", 1);
				r.onupgradeneeded = () => r.result.createObjectStore("files");
				r.onsuccess = () => ok(r.result);
				r.onerror = () => fail(r.error);
			});
			const all = await new Promise((ok, fail) => {
				const t = this.db.transaction("files", "readonly").objectStore("files");
				const out = [];
				const c = t.openCursor();
				c.onsuccess = () => { const cur = c.result; if (!cur) { ok(out); return; } out.push([cur.key, cur.value]); cur.continue(); };
				c.onerror = () => fail(c.error);
			});
			for (const [path, v] of all) {
				this.entries.set(path, v.dir ? { dir: true, mtime: v.mtime } : { dir: false, data: new Uint8Array(v.data), size: v.data.byteLength, mtime: v.mtime });
			}
		} catch (e) {
			console.warn("Sculpt: the browser keeps no files for this page (" + e + "); nothing is saved between visits");
			this.db = null;
		}
	}
	flush() {
		this.timer = 0;
		if (!this.db || this.dirty.size === 0) { this.dirty.clear(); return; }
		const t = this.db.transaction("files", "readwrite").objectStore("files");
		for (const path of this.dirty) {
			const e = this.entries.get(path);
			if (!e) t.delete(path);
			else if (e.dir) t.put({ dir: true, mtime: e.mtime }, path);
			else t.put({ dir: false, data: e.data.slice(0, e.size).buffer, mtime: e.mtime }, path);
		}
		this.dirty.clear();
	}

	imports(web) {
		const fs = this;
		const path = (ptr, len) => Files.norm(web.string(ptr, len));
		const parentOk = (p) => { const e = fs.entries.get(Files.parent(p)); return e && e.dir; };
		return {
			sculpt_fs_kind(p, l) { const e = fs.entries.get(path(p, l)); return e ? (e.dir ? 2 : 1) : 0; },
			sculpt_fs_size(p, l) { const e = fs.entries.get(path(p, l)); return BigInt(e && !e.dir ? e.size : 0); },
			sculpt_fs_mtime(p, l) { const e = fs.entries.get(path(p, l)); return e ? e.mtime : 0; },
			sculpt_fs_read(p, l, offset, buf, n) {
				const e = fs.entries.get(path(p, l));
				if (!e || e.dir) return -1n;
				const at = Number(offset);
				const count = Math.max(0, Math.min(Number(n), e.size - at));
				if (count > 0) web.bytes().set(e.data.subarray(at, at + count), buf);
				return BigInt(count);
			},
			sculpt_fs_write(p, l, offset, buf, n) {
				const name = path(p, l);
				const e = fs.entries.get(name);
				if (!e || e.dir) return -1n;
				const at = Number(offset), count = Number(n);
				const end = at + count;
				if (end > e.data.length) {
					const grown = new Uint8Array(Math.max(end, e.data.length * 2, 64));
					grown.set(e.data.subarray(0, e.size));
					e.data = grown;
				}
				e.data.set(web.bytes().subarray(buf, buf + count), at);
				if (at > e.size) e.data.fill(0, e.size, at);
				e.size = Math.max(e.size, end);
				e.mtime = Date.now();
				fs.changed(name);
				return BigInt(count);
			},
			sculpt_fs_create(p, l, truncate) {
				const name = path(p, l);
				const e = fs.entries.get(name);
				if (e && e.dir) return -1;
				if (!e && !parentOk(name)) return -1;
				if (!e || truncate) { fs.entries.set(name, { dir: false, data: new Uint8Array(64), size: 0, mtime: Date.now() }); fs.changed(name); }
				return 0;
			},
			sculpt_fs_truncate(p, l, size) {
				const e = fs.entries.get(path(p, l));
				if (!e || e.dir) return -1;
				const n = Number(size);
				if (n > e.data.length) { const g = new Uint8Array(n); g.set(e.data.subarray(0, e.size)); e.data = g; }
				if (n > e.size) e.data.fill(0, e.size, n);
				e.size = n;
				fs.changed(path(p, l));
				return 0;
			},
			sculpt_fs_mkdir(p, l) {
				const name = path(p, l);
				if (fs.entries.has(name)) return 1;
				if (!parentOk(name)) return -1;
				fs.entries.set(name, { dir: true, mtime: Date.now() });
				fs.changed(name);
				return 0;
			},
			sculpt_fs_remove(p, l) {
				const name = path(p, l);
				const e = fs.entries.get(name);
				if (!e || name === "/") return -1;
				if (e.dir) for (const k of fs.entries.keys()) if (k.startsWith(name + "/")) return -2;
				fs.entries.delete(name);
				fs.changed(name);
				return 0;
			},
			sculpt_fs_rename(a, al, b, bl) {
				const from = path(a, al), to = path(b, bl);
				const e = fs.entries.get(from);
				if (!e || !parentOk(to)) return -1;
				const moves = [[from, to]];
				if (e.dir) for (const k of fs.entries.keys()) if (k.startsWith(from + "/")) moves.push([k, to + k.slice(from.length)]);
				for (const [x, y] of moves) { fs.entries.set(y, fs.entries.get(x)); fs.entries.delete(x); fs.changed(x); fs.changed(y); }
				return 0;
			},
			sculpt_fs_list(p, l, buf, cap) {
				const name = path(p, l);
				const e = fs.entries.get(name);
				if (!e || !e.dir) return -1n;
				const prefix = name === "/" ? "/" : name + "/";
				const names = [];
				for (const k of fs.entries.keys()) if (k !== name && k.startsWith(prefix) && !k.slice(prefix.length).includes("/")) names.push(k.slice(prefix.length));
				names.sort();
				const data = new TextEncoder().encode(names.map((x) => x + "\0").join(""));
				if (buf && Number(cap) >= data.length) web.bytes().set(data, buf);
				return BigInt(data.length);
			},
		};
	}
}

return { Web, Files, UNWIND };
})();
