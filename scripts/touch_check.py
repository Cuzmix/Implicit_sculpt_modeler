#!/usr/bin/env python3
"""Touch, pen and mouse regression scenarios for the sculpt app (skill sm-touch-testing).

Each scenario drives the debug app through --ui-events (scripted SDL events: the mouse,
fingers on a touch screen and the pen take the same path real ones do), lets it exit
after a fixed number of frames and checks the key=value stats it prints: where the
camera ended up, how many dabs were laid, the undo steps, the brush size. A scenario
fails on a wrong value, a crash, a GPU validation error or a leak (the debug build exits
1 on one).

This is a simulation on the desktop, not a tablet: it proves the routing (who owns a
touch, the slop, the gesture arena, cancels) but not a real screen's timing, palm
detection or pen hardware. Report it as such.

Usage (after ./build.sh or build.bat):
    python scripts/touch_check.py                 # every scenario
    python scripts/touch_check.py --list
    python scripts/touch_check.py tap_ui pinch    # only these
    python scripts/touch_check.py --screens       # also write build/touch/<name>.png
The window is 1600 x 900 points, the default layout; positions below are in points.
"""
import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "build", "sculpt.exe" if os.name == "nt" else "sculpt")
START = 12  # the first frame events go in: anchored panels are placed by then

# The default camera (camera.orbit_default) and where things are at 1600 x 900.
CAMERA0 = {"camera_yaw": 0.6, "camera_pitch": 0.35, "camera_roll": 0.0, "camera_distance": 3.5}
MODEL = (800, 450)  # the sphere's middle; it reaches about 368 points out
EMPTY = (250, 150)  # viewport with nothing on it
UI = {
    "menu": (36, 36), "undo": (93, 36), "history": (188, 36),
    "tool_move": (603, 36), "tool_sculpt": (692, 36), "sym_x": (948, 36),
    "view": (1516, 36), "size_slider": (36, 440), "strength_slider": (84, 450),
    "dock_smooth": (638, 855), "dock_draw": (574, 855), "browser": (1028, 855),
    "tab_object": (1432, 98), "tab_brush": (1338, 98), "status": (1510, 870),
}
ORBIT_TURN = 2 * math.pi / 0.008  # points of drag that turn the view once (ORBIT_SPEED)


class Script:
    """Builds a --ui-events list frame by frame."""

    def __init__(self):
        self.events, self.frame = [], START

    def at(self, frame=None):
        return self.frame if frame is None else frame

    def add(self, text, frame=None):
        self.events.append(f"{self.at(frame)}:{text}")

    def wait(self, frames):
        self.frame += frames

    def ftap(self, x, y, finger=0, hold=2, gap=4):
        self.add(f"fdown:{finger}:{x:g},{y:g}")
        self.wait(hold)
        self.add(f"fup:{finger}")
        self.wait(gap)

    def fdrag(self, path, finger=0, step=1, lift=True):
        """Finger down at path[0], moving through the rest one frame each."""
        x, y = path[0]
        self.add(f"fdown:{finger}:{x:g},{y:g}")
        for x, y in path[1:]:
            self.wait(step)
            self.add(f"fmove:{finger}:{x:g},{y:g}")
        self.wait(1)
        if lift:
            self.add(f"fup:{finger}")
            self.wait(3)

    def fingers(self, starts, moves, frames, lift=True):
        """Several fingers down together, each moving by its `moves` over `frames`."""
        for i, (x, y) in enumerate(starts):
            self.add(f"fdown:{i}:{x:g},{y:g}")
        self.wait(2)
        for k in range(1, frames + 1):
            for i, ((x, y), (dx, dy)) in enumerate(zip(starts, moves)):
                self.add(f"fmove:{i}:{x + dx * k / frames:g},{y + dy * k / frames:g}")
            self.wait(1)
        if lift:
            for i in range(len(starts)):
                self.add(f"fup:{i}")
            self.wait(3)

    def mouse_drag(self, path, button="left", keys=()):
        for k in keys:
            self.add(f"key:{k}")
        x, y = path[0]
        self.add(f"move:{x:g},{y:g}")
        self.wait(1)
        if button == "left":
            self.add("down")
        for x, y in path[1:]:
            self.wait(1)
            self.add(f"move:{x:g},{y:g}")
        self.wait(1)
        if button == "left":
            self.add("up")
        for k in keys:
            self.add(f"keyup:{k}")
        self.wait(3)

    def spec(self):
        return ";".join(self.events)


def line(a, b, steps):
    return [(a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps) for i in range(steps + 1)]


SLOP = 10  # theme.slop at UI scale 1


def past_slop(a, b, steps):
    """A drag from a by b - a that counts in full: its first move only crosses the slop.

    A finger or the pen turns nothing until it strays past the slop, and the move that
    crosses it is not counted either (the turn starts from where it is then), so the path
    first moves just past the slop and then the whole way."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = math.hypot(dx, dy)
    o = ((SLOP + 1) * dx / n, (SLOP + 1) * dy / n)
    return [a] + line((a[0] + o[0], a[1] + o[1]), (b[0] + o[0], b[1] + o[1]), steps)


def near(want, tol=1e-3):
    return lambda got: abs(float(got) - want) <= tol


def camera_still(extra=None):
    checks = {k: near(v) for k, v in CAMERA0.items()}
    checks["camera_target"] = lambda got: got == "0.0000,0.0000,0.0000"
    checks.update(extra or {})
    return checks


def wrap(a):
    return a - 2 * math.pi * math.floor((a + math.pi) / (2 * math.pi))


SCENARIOS = {}


def scenario(fn):
    SCENARIOS[fn.__name__] = fn
    return fn


@scenario
def tap_ui():
    """A finger tapping every major region of the interface never moves the camera or sculpts."""
    s = Script()
    for name in ["menu", "menu", "undo", "history", "history", "tool_move", "tool_sculpt", "sym_x", "sym_x",
                 "view", "view", "size_slider", "strength_slider", "dock_smooth", "dock_draw", "browser", "browser",
                 "tab_object", "tab_brush", "status"]:
        s.ftap(*UI[name])
    # Just past the drawn edge of the brush dock and the tools bar, inside their targets.
    s.ftap(574, 829)
    s.ftap(692, 14)
    return s, [], camera_still({"dabs": near(0)})


@scenario
def tap_viewport_far_apart():
    """Touching down far from where the last finger lifted is no drag (SDL's mouse jump bug)."""
    s = Script()
    s.ftap(*EMPTY)
    s.ftap(1250, 800)
    s.ftap(150, 820)
    s.ftap(*UI["menu"])
    s.ftap(1250, 120, hold=8)
    return s, [], camera_still({"dabs": near(0)})


@scenario
def first_touch_scrolls_inspector():
    """The first finger drag on the inspector's Size slider scrolls the inspector and changes nothing."""
    s = Script()
    s.fdrag(line((1430, 280), (1435, 60), 22))
    return s, [], camera_still({"dabs": near(0), "brush_radius_px": near(60), "brush_strength": near(0.5),
                                "inspector_scroll": lambda v: float(v) > 100})


@scenario
def slider_drag_sideways():
    """A sideways finger drag on the inspector's Strength slider sets it, without orbiting or scrolling."""
    s = Script()
    s.fdrag(line((1430, 333), (1520, 335), 12))
    return s, [], camera_still({"dabs": near(0), "brush_strength": lambda v: float(v) > 0.6, "inspector_scroll": near(0)})


@scenario
def finger_sculpts_model():
    """One finger on the model sculpts after the hold; the camera stays still."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def finger_orbits_empty_space():
    """One finger on empty space turns the view, and a stroke started there keeps turning over the model."""
    s = Script()
    s.fdrag(past_slop((250, 400), (650, 400), 20))
    return s, ["--orbit-style=turntable"], {"dabs": near(0), "camera_pitch": near(0.35),
                                            "camera_yaw": near(wrap(0.6 - 400 * 0.008), 2e-3)}


@scenario
def orbit_full_turns_free():
    """Free orbit: two full turns right then two left, and a full turn down, come back to the start."""
    s = Script()
    # Every drag starts on empty space (a finger on the model would sculpt) and keeps
    # turning the view as it crosses the model.
    for a, b in [((150, 120), (150 + ORBIT_TURN, 120))] * 2 + [((1150, 120), (1150 - ORBIT_TURN, 120))] * 2:
        s.fdrag(past_slop(a, b, 60))
    s.fdrag(past_slop((250, 80), (250, 80 + ORBIT_TURN), 60))
    return s, ["--orbit-style=free"], {"dabs": near(0)} | {k: near(v, 5e-3) for k, v in CAMERA0.items()}


@scenario
def orbit_full_turns_turntable():
    """Turntable: three turns right and one over the top come back to the start with no flip."""
    s = Script()
    for _ in range(3):
        s.fdrag(past_slop((150, 120), (150 + ORBIT_TURN, 120), 60))
    s.fdrag(past_slop((250, 80), (250, 80 + ORBIT_TURN), 60))
    return s, ["--orbit-style=turntable"], {"dabs": near(0)} | {k: near(v, 5e-3) for k, v in CAMERA0.items()}


@scenario
def pinch_zoom():
    """Two fingers spreading three times apart zoom three times closer."""
    s = Script()
    s.fingers([(300, 300), (400, 300)], [(-100, 0), (100, 0)], 20)
    return s, [], {"camera_distance": near(3.5 / 3, 0.02), "dabs": near(0), "camera_yaw": near(0.6), "camera_pitch": near(0.35)}


@scenario
def two_finger_pan():
    """Two fingers moving together pan the view and never turn it."""
    s = Script()
    s.fingers([(300, 300), (400, 300)], [(120, 60), (120, 60)], 20)
    return s, [], {"camera_distance": near(3.5), "camera_yaw": near(0.6), "camera_pitch": near(0.35),
                   "camera_target": lambda v: v != "0.0000,0.0000,0.0000", "dabs": near(0)}


@scenario
def second_finger_on_model_sculpts_nothing():
    """Two fingers landing on the model together navigate; nothing is sculpted first."""
    s = Script()
    s.fingers([(780, 440), (840, 460)], [(-60, 0), (60, 0)], 15)
    return s, [], {"dabs": near(0), "undo_steps": near(0)}


def twist(s, turn, frames=20):
    """Two fingers 100 points apart turning `turn` radians clockwise about their middle."""
    mid, r = (300, 300), 50
    for i in (0, 1):
        s.add(f"fdown:{i}:{mid[0] + (r if i else -r):g},{mid[1]:g}")
    s.wait(2)
    for k in range(1, frames + 1):
        a = turn * k / frames
        for i, sign in ((0, -1), (1, 1)):
            s.add(f"fmove:{i}:{mid[0] + sign * r * math.cos(a):g},{mid[1] + sign * r * math.sin(a):g}")
        s.wait(1)
    for i in (0, 1):
        s.add(f"fup:{i}")
    s.wait(3)


@scenario
def twist_rolls_free_only():
    """Twisting two fingers 45 degrees in Free rolls the view with them, less the 10 degree deadzone."""
    s = Script()
    twist(s, math.radians(45))
    return s, ["--orbit-style=free"], {"camera_roll": lambda v: math.radians(34) < float(v) < math.radians(45),
                                       "camera_distance": near(3.5, 0.05), "dabs": near(0)}


@scenario
def twist_wobble_rolls_nothing():
    """Two fingers turning less than the deadzone (a pinch's wobble) leave the roll alone."""
    s = Script()
    twist(s, math.radians(8))
    return s, ["--orbit-style=free"], {"camera_roll": near(0), "dabs": near(0)}


@scenario
def twist_rolls_nothing_in_turntable():
    """Turntable keeps the horizon level: a twist does not roll."""
    s = Script()
    twist(s, math.radians(45))
    return s, ["--orbit-style=turntable"], {"camera_roll": near(0), "dabs": near(0)}


@scenario
def finger_orbits_setting():
    """With one finger set to turn the view, a finger on the model orbits and the pen still sculpts."""
    s = Script()
    s.fdrag(past_slop((760, 430), (860, 430), 20))
    s.add("pnear")
    s.wait(1)
    s.add("pdown:760,430")
    for x, y in line((760, 430), (860, 470), 20)[1:]:
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
    s.wait(1)
    s.add("pup")
    s.wait(2)
    s.add("pfar")
    s.wait(3)
    return s, ["--finger-orbits", "--orbit-style=turntable"], {"camera_yaw": near(wrap(0.6 - 100 * 0.008), 2e-3), "dabs": lambda v: int(v) > 0, "undo_steps": near(1)}


@scenario
def second_finger_soon_after_sculpts_nothing():
    """A second finger landing a frame after the first, on the model, makes a gesture before any clay moves."""
    s = Script()
    s.add("fdown:0:780,440")
    s.wait(1)
    s.add("fdown:1:840,460")
    s.wait(1)
    for k in range(1, 16):
        s.add(f"fmove:0:{780 - 4 * k:g},440")
        s.add(f"fmove:1:{840 + 4 * k:g},460")
        s.wait(1)
    s.add("fup:0")
    s.add("fup:1")
    s.wait(3)
    return s, [], {"dabs": near(0), "undo_steps": near(0), "camera_distance": lambda v: float(v) < 3.4}


@scenario
def tap_history():
    """Two strokes; two two-finger taps undo both, a three-finger tap redoes one."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    s.wait(4)
    s.fdrag(line((760, 330), (860, 370), 20))
    s.wait(4)
    for fingers in (2, 2, 3):
        s.fingers([(300 + 100 * i, 300) for i in range(fingers)], [(0, 0)] * fingers, 1)
        s.wait(4)
    return s, [], {"undo_steps": near(1), "redo_steps": near(1), "camera_distance": near(3.5)}


@scenario
def two_finger_tap_on_panel_does_nothing():
    """A two-finger tap that starts on a panel is the panel's: no undo."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    s.wait(4)
    s.fingers([(1430, 600), (900, 300)], [(0, 0), (0, 0)], 1)
    return s, [], camera_still({"undo_steps": near(1), "redo_steps": near(0)})


@scenario
def three_finger_size():
    """Three fingers dragged up grow the brush."""
    s = Script()
    s.fingers([(300, 600), (380, 600), (460, 600)], [(0, -200)] * 3, 20)
    return s, [], {"brush_radius_px": lambda v: float(v) > 100, "camera_distance": near(3.5, 0.2), "dabs": near(0)}


@scenario
def palm_while_pen_near():
    """A lone finger while the pen hovers does nothing; the pen then sculpts."""
    s = Script()
    s.add("pnear")
    s.wait(2)
    s.fdrag(line((700, 600), (900, 620), 20))
    s.add("pdown:760,430")
    for x, y in line((760, 430), (860, 470), 20)[1:]:
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
    s.wait(1)
    s.add("pup")
    s.wait(2)
    s.add("pfar")
    s.wait(3)
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def pen_stroke_with_hand_resting():
    """A hand resting on the screen while the pen draws: the pen sculpts, the view stays put (SDL's pen stand-in finger is no finger)."""
    s = Script()
    s.add("pnear")
    s.wait(2)
    s.add("fdown:0:300,700")  # the side of the hand, on empty space
    s.wait(2)
    s.add("pdown:760,430")
    for k, (x, y) in enumerate(line((760, 430), (860, 470), 20)[1:]):
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
        s.add(f"fmove:0:{300 + k:g},700")  # the hand drifts a little
    s.wait(1)
    s.add("pup")
    s.add("fup:0")
    s.wait(2)
    s.add("pfar")
    s.wait(3)
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def pen_landing_cancels_finger_stroke():
    """A finger stroke under way when the pen lands is taken back, and the pen's own stroke is kept."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 12), lift=False)
    s.add("pnear")
    s.add("pdown:700,500")
    for x, y in line((700, 500), (800, 540), 12)[1:]:
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
    s.wait(1)
    s.add("pup")
    s.add("fup:0")
    s.wait(2)
    s.add("pfar")
    s.wait(3)
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1), "redo_steps": near(0)})


@scenario
def mouse_click_within_one_frame():
    """A mouse click whose press and release land in the same frame still lays a dab on the model."""
    s = Script()
    s.add("move:800,450")
    s.wait(2)
    s.add("down")
    s.add("up")
    s.wait(4)
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def cancelled_stroke_is_taken_back():
    """A finger stroke the system cancels is undone; Redo has it."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20), lift=False)
    s.add("fcancel:0")
    s.wait(4)
    return s, [], camera_still({"undo_steps": near(0), "redo_steps": near(1)})


@scenario
def pen_on_empty_space_orbits():
    """The pen dragged on empty space turns the view, as ZBrush's Pencil does."""
    s = Script()
    s.add("pnear")
    s.wait(1)
    s.add("pdown:250,400")
    for x, y in past_slop((250, 400), (450, 400), 20)[1:]:
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
    s.wait(1)
    s.add("pup")
    s.wait(3)
    return s, ["--orbit-style=turntable"], {"dabs": near(0), "camera_yaw": near(wrap(0.6 - 200 * 0.008), 2e-3)}


@scenario
def mouse_controls():
    """Desktop: a left drag on the model sculpts, on empty space orbits (no slop), right drag orbits, wheel zooms."""
    s = Script()
    s.mouse_drag(line((760, 430), (860, 470), 10))
    s.mouse_drag(line((250, 400), (350, 400), 10))
    s.add("move:300,300")
    s.wait(1)
    s.add("wheel:2")
    s.wait(3)
    return s, ["--orbit-style=turntable"], {"dabs": lambda v: int(v) > 0, "undo_steps": near(1),
                                            "camera_yaw": near(wrap(0.6 - 100 * 0.008), 2e-3),
                                            "camera_distance": near(3.5 * 0.88 ** 2, 1e-3)}


@scenario
def shift_snaps_orbit():
    """Shift while turning snaps to the nearest square view."""
    s = Script()
    s.mouse_drag(line((250, 400), (260, 405), 2), keys=("shift",))
    return s, [], {"camera_yaw": near(0, 1e-3), "camera_pitch": near(0, 1e-3), "camera_roll": near(0, 1e-3)}


SETTINGS_FILE = os.path.join(ROOT, "build", "touch_settings.txt")


def saved(**want):
    """A check on the settings file the scenario's app wrote on closing Settings."""
    def ok(_):
        if not os.path.exists(SETTINGS_FILE):
            return False
        lines = dict(l.split(" ", 1) for l in open(SETTINGS_FILE).read().splitlines() if " " in l)
        return all(lines.get(k) == v for k, v in want.items())
    return ok


def open_settings(s, tab):
    s.ftap(*UI["menu"])
    s.wait(10)
    s.ftap(85, 447)  # Menu > Settings...
    s.wait(16)
    s.ftap(*{"interface": (1250, 158), "camera": (1342, 158), "touch": (1433, 158), "performance": (1523, 158)}[tab])
    s.wait(10)


@scenario
def settings_scroll_and_persist():
    """Settings opens from the menu, a switch changes at a tap, the body scrolls from the first touch on a slider, and Done remembers it."""
    if os.path.exists(SETTINGS_FILE):
        os.remove(SETTINGS_FILE)
    s = Script()
    open_settings(s, "camera")
    s.ftap(1549, 690)  # Invert the mouse wheel
    s.wait(4)
    s.fdrag(line((1300, 645), (1305, 345), 20))  # from the Zoom speed slider, upward
    s.wait(16)
    s.ftap(1481, 791)  # Done
    s.wait(4)
    return s, [f"--settings-file={SETTINGS_FILE}"], camera_still({
        "dabs": near(0), "settings_open": near(0), "settings_scroll": lambda v: float(v) > 100,
        "@saved": saved(invert_wheel="1", zoom_speed="1", orbit_speed="1")})


@scenario
def settings_reset_everything():
    """Reset everything takes a second tap, then puts every category back."""
    s = Script()
    with open(SETTINGS_FILE, "w") as f:
        f.write("orbit_speed 2\ninvert_wheel 1\nfinger_model orbit\nstats 1\n")
    open_settings(s, "touch")
    s.ftap(1294, 791)  # Reset everything: arms it
    s.wait(10)
    s.ftap(1294, 791)  # Tap again to reset all
    s.wait(4)
    s.ftap(1481, 791)  # Done
    s.wait(4)
    return s, [f"--settings-file={SETTINGS_FILE}"], camera_still({
        "settings_open": near(0), "@saved": saved(orbit_speed="1", invert_wheel="0", finger_model="Sculpt", stats="0")})


@scenario
def settings_reset_needs_second_tap():
    """One tap on Reset everything changes nothing."""
    s = Script()
    with open(SETTINGS_FILE, "w") as f:
        f.write("orbit_speed 2\ninvert_wheel 1\n")
    open_settings(s, "camera")
    s.ftap(1294, 791)
    s.wait(4)
    s.ftap(1481, 791)  # Done
    s.wait(4)
    return s, [f"--settings-file={SETTINGS_FILE}"], {"@saved": saved(orbit_speed="2", invert_wheel="1")}


@scenario
def settings_scroll_right_after_opening():
    """The Settings body scrolls from the first touch the frame after its tab opens."""
    s = Script()
    s.ftap(*UI["menu"])
    s.wait(10)
    s.ftap(85, 447)
    s.wait(2)
    s.ftap(1433, 158)  # the Touch tab
    s.wait(1)
    s.fdrag(line((1300, 600), (1305, 300), 15))
    return s, [], camera_still({"dabs": near(0), "settings_open": near(1), "settings_scroll": lambda v: float(v) > 100})


@scenario
def settings_open_scroll_close_repeat():
    """Open Settings, scroll, close it with Done, three times over: it opens, scrolls and closes every time."""
    s = Script()
    for _ in range(3):
        s.ftap(*UI["menu"])
        s.wait(10)
        s.ftap(85, 447)
        s.wait(4)
        s.ftap(1433, 158)
        s.wait(2)
        s.fdrag(line((1300, 600), (1305, 300), 15))
        s.wait(4)
        s.ftap(1481, 791)  # Done
        s.wait(10)
    return s, [], camera_still({"dabs": near(0), "settings_open": near(0), "settings_scroll": lambda v: float(v) > 100})


@scenario
def changed_touch_setting_takes_effect():
    """Settings > Touch > On the model > Turns the view, then a finger on the model orbits and sculpts nothing; it is saved."""
    if os.path.exists(SETTINGS_FILE):
        os.remove(SETTINGS_FILE)
    s = Script()
    open_settings(s, "touch")
    s.ftap(1483, 251)  # Turns the view
    s.wait(4)
    s.ftap(1481, 791)  # Done
    s.wait(10)
    s.fdrag(past_slop((760, 430), (860, 430), 20))
    return s, [f"--settings-file={SETTINGS_FILE}", "--orbit-style=turntable"], {
        "dabs": near(0), "camera_yaw": near(wrap(0.6 - 100 * 0.008), 2e-3), "@saved": saved(finger_model="Orbit")}


@scenario
def rapid_taps():
    """Rapid taps, a frame down and a frame up, on empty space and on a toggle neither turn the view nor sculpt."""
    s = Script()
    for _ in range(10):
        s.ftap(*EMPTY, hold=1, gap=1)
    for _ in range(6):
        s.ftap(*UI["sym_x"], hold=1, gap=1)
    for x in range(200, 400, 20):
        s.ftap(x, 700 - x, hold=1, gap=1)
    return s, [], camera_still({"dabs": near(0), "undo_steps": near(0)})


@scenario
def inspector_tab_switch_then_scroll():
    """After switching the inspector to the Object tab, a first finger drag over its values scrolls it."""
    s = Script()
    s.ftap(*UI["tab_object"])
    s.wait(6)
    s.fdrag(line((1430, 330), (1435, 90), 20))
    return s, [], camera_still({"dabs": near(0), "inspector_scroll": lambda v: float(v) > 100, "selected": near(0)})


@scenario
def small_window():
    """A 1280 x 800 window (a tablet's size): the inspector scrolls from the first touch and far-apart taps turn nothing."""
    s = Script()
    s.fdrag(line((1110, 280), (1115, 60), 22))
    s.ftap(200, 150)
    s.ftap(1000, 700)
    s.ftap(150, 650)
    return s, ["--width=1280", "--height=800"], camera_still({"dabs": near(0), "inspector_scroll": lambda v: float(v) > 50,
                                                            "brush_radius_px": near(60)})


def run(name, screens):
    script, args, checks = SCENARIOS[name]()
    frames = script.frame + 10
    cmd = [EXE, f"--frames={frames}", f"--ui-events={script.spec()}"]
    if not any(a.startswith("--width") for a in args):
        cmd += ["--width=1600", "--height=900"]
    if not any(a.startswith("--settings-file") for a in args):
        cmd.append("--no-settings")
    cmd += args
    if screens:
        os.makedirs(os.path.join(ROOT, "build", "touch"), exist_ok=True)
        cmd.append(f"--dump-screen={os.path.join(ROOT, 'build', 'touch', name + '.png')}")
    env = dict(os.environ, SDL_ASSERT="abort")
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=600)
    stats = {}
    for out_line in proc.stdout.splitlines():
        for token in out_line.split():
            if "=" in token:
                k, v = token.split("=", 1)
                stats[k] = v
    failures = []
    if proc.returncode != 0:
        failures.append(f"exit code {proc.returncode}: {proc.stderr.strip().splitlines()[-3:]}")
    for key, ok in checks.items():
        if key.startswith("@"):
            if not ok(None):
                failures.append(f"{key} wrong")
        elif key not in stats:
            failures.append(f"{key} missing")
        elif not ok(stats[key]):
            failures.append(f"{key}={stats[key]}")
    return failures, stats


def main(argv):
    if "--list" in argv:
        for name, fn in SCENARIOS.items():
            print(f"{name:40s} {fn.__doc__}")
        return 0
    screens = "--screens" in argv
    names = [a for a in argv if not a.startswith("--")] or list(SCENARIOS)
    if not os.path.exists(EXE):
        print(f"{EXE} is missing: build the debug app first")
        return 1
    failed = 0
    for name in names:
        failures, stats = run(name, screens)
        cam = " ".join(f"{k}={stats.get(k, '?')}" for k in ("camera_yaw", "camera_pitch", "camera_roll", "camera_distance", "dabs", "undo_steps"))
        print(f"{'PASS' if not failures else 'FAIL'} {name:40s} {cam}")
        for f in failures:
            print(f"     {f}")
        failed += bool(failures)
    print(f"{len(names) - failed} of {len(names)} scenarios pass (desktop touch simulation, not a tablet)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
