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
    python scripts/touch_check.py 'long_press*'   # every scenario whose name matches
    python scripts/touch_check.py --jobs=1        # one at a time (default: one per CPU)
    python scripts/touch_check.py --screens       # also write build/touch/<name>.png
The window is 1600 x 900 points, the default layout; positions below are in points.
"""
import concurrent.futures
import fnmatch
import math
import os
import queue
import shutil
import subprocess
import sys
import threading
import time

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
    "tab_object": (1432, 152), "tab_brush": (1338, 152), "status": (1510, 870),
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

    def press(self, key, mods=()):
        """A key pressed and let go with `mods` (ctrl, shift, alt) held around it."""
        for m in mods:
            self.add(f"key:{m}")
        self.add(f"key:{key}")
        self.wait(1)
        self.add(f"keyup:{key}")
        for m in mods:
            self.add(f"keyup:{m}")
        self.wait(3)

    def spec(self):
        return ";".join(self.events)


def line(a, b, steps):
    return [(a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps) for i in range(steps + 1)]


SLOP = 10  # theme.slop at UI scale 1
UI_DT = 1 / 60  # --ui-dt: seconds the interface's clock moves a frame
LONG_PRESS_FRAMES = 30  # theme.long_press (0.45 s) is 27 frames of UI_DT; a few more


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
    s.fdrag(line((1430, 334), (1435, 114), 22))
    return s, [], camera_still({"dabs": near(0), "brush_radius_px": near(60), "brush_strength": near(0.5),
                                "inspector_scroll": lambda v: float(v) > 100})


@scenario
def slider_drag_sideways():
    """A sideways finger drag on the inspector's Strength slider sets it, without orbiting or scrolling."""
    s = Script()
    s.fdrag(line((1430, 387), (1520, 389), 12))
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


@scenario
def keys_undo_and_redo():
    """Ctrl+Z undoes a stroke, Ctrl+Shift+Z redoes it, and Ctrl+Z again undoes it (the command registry)."""
    s = Script()
    s.mouse_drag(line((760, 430), (860, 470), 10))
    s.press("z", ("ctrl",))
    s.press("z", ("ctrl", "shift"))
    s.press("z", ("ctrl",))
    return s, [], {"undo_steps": near(0), "redo_steps": near(1)}


@scenario
def keys_size_and_strength():
    """] makes the brush a sixth bigger and Shift+] 0.05 stronger; Ctrl+] is no shortcut and changes nothing."""
    s = Script()
    s.press("]")
    s.press("]", ("shift",))
    s.press("]", ("ctrl",))
    return s, [], {"brush_radius_px": near(70, 0.01), "brush_strength": near(0.55, 1e-3)}


@scenario
def keys_axis_views():
    """The keypad's 1 looks from the front; Ctrl with the keypad's 3 from the left."""
    s = Script()
    s.press("Keypad 1")
    s.wait(2)
    s.press("Keypad 3", ("ctrl",))
    return s, [], {"camera_pitch": near(0, 1e-3), "camera_yaw": lambda v: abs(abs(wrap(float(v))) - math.pi / 2) < 1e-3}



TOAST_UNDO = (880, 790)  # the Undo of "Deleted Sphere 1", above the dock


@scenario
def toast_undo_after_delete():
    """Del removes the sphere and a toast offers Undo; clicking it brings the sphere back as Ctrl+Z would."""
    s = Script()
    s.add(f"move:{MODEL[0]},{MODEL[1]}")
    s.press("Delete")
    s.wait(30)
    s.mouse_drag([TOAST_UNDO])
    return s, [], {"objects": near(1), "undo_steps": near(0), "redo_steps": near(1)}


@scenario
def toast_undo_goes_stale():
    """After Ctrl+Z and a new stroke, the Delete toast's Undo is gone: a click where it was takes back
    nothing (with the toast narrower, it lands on the sphere and sculpts a dab)."""
    s = Script()
    s.add(f"move:{MODEL[0]},{MODEL[1]}")
    s.press("Delete")
    s.wait(10)
    s.press("z", ("ctrl",))
    s.mouse_drag(line((760, 430), (860, 470), 10))
    s.mouse_drag([TOAST_UNDO])
    return s, [], {"objects": near(1), "undo_steps": lambda v: int(v) >= 1, "redo_steps": near(0)}

def on_screen(stats, p, yaw=0.6, pitch=0.35, roll=0.0, distance=3.5, target=(0.0, 0.0, 0.0)):
    """Where the world point p appears in a perspective view, as tangents right and up of the
    view direction; with no camera given, the default camera's view. As camera.orbit_view:
    the turn is yaw about y, then -pitch about x, then roll about z."""
    if stats is not None:
        yaw, pitch, roll, distance = (float(stats[k]) for k in ("camera_yaw", "camera_pitch", "camera_roll", "camera_distance"))
        target = tuple(float(v) for v in stats["camera_target"].split(","))

    def mul(a, b):
        return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    cy, sy, cp, sp, cr, sr = math.cos(yaw), math.sin(yaw), math.cos(-pitch), math.sin(-pitch), math.cos(roll), math.sin(roll)
    r = mul(mul([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]], [[1, 0, 0], [0, cp, -sp], [0, sp, cp]]), [[cr, -sr, 0], [sr, cr, 0], [0, 0, 1]])
    eye = [target[i] + distance * r[i][2] for i in range(3)]
    local = [sum(r[i][j] * (p[i] - eye[i]) for i in range(3)) for j in range(3)]
    return local[0] / -local[2], local[1] / -local[2]


def pivot(stats):
    return tuple(float(v) for v in stats["orbit_pivot"].split(","))


@scenario
def orbit_turns_about_the_last_stroke():
    """After a stroke off the middle, an orbit on empty space turns about the stroke, which stays put on screen."""
    s = Script()
    s.fdrag(line((950, 300), (1000, 330), 20))
    s.wait(4)
    s.fdrag(past_slop((250, 400), (450, 400), 20))
    return s, ["--orbit-style=turntable"], {
        "dabs": lambda v: int(v) > 0, "pivot_source": lambda v: v == "stroke",
        "camera_yaw": near(wrap(0.6 - 200 * 0.008), 2e-3), "camera_distance": near(3.5),
        "camera_target": lambda v: v != "0.0000,0.0000,0.0000",
        # On the sphere's near side, up and to the right.
        "@pivot_on_model": lambda st: 0.9 < math.dist(pivot(st), (0, 0, 0)) < 1.2 and pivot(st)[1] > 0.2,
        "@pivot_stays_put": lambda st: math.dist(on_screen(st, pivot(st)), on_screen(None, pivot(st))) < 2e-3}


@scenario
def orbit_about_the_centre_setting():
    """With Turn about set to the centre, an orbit after a stroke turns about the target, as before."""
    s = Script()
    s.fdrag(line((950, 300), (1000, 330), 20))
    s.wait(4)
    s.fdrag(past_slop((250, 400), (450, 400), 20))
    return s, ["--orbit-style=turntable", "--orbit-pivot=centre"], {
        "pivot_source": lambda v: v == "centre", "camera_target": lambda v: v == "0.0000,0.0000,0.0000",
        "camera_yaw": near(wrap(0.6 - 200 * 0.008), 2e-3)}


def zoomed_in(s):
    """Eight wheel notches in: the sphere fills the whole window, with no empty space left."""
    s.add("move:800,450")
    s.wait(1)
    s.add("wheel:8")
    s.wait(3)


def edge_drags(s):
    """A finger along the bottom edge and the pen along the top one, both over the model,
    where no panel is, each 200 points sideways."""
    zoomed_in(s)
    s.fdrag(past_slop((250, 868), (450, 868), 20))
    s.add("pnear")
    s.wait(1)
    s.add("pdown:260,30")
    for x, y in past_slop((260, 30), (460, 30), 20)[1:]:
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
    s.wait(1)
    s.add("pup")
    s.wait(2)
    s.add("pfar")
    s.wait(3)


@scenario
def edge_orbits_over_the_model():
    """Zoomed in until the model fills the view, a finger and the pen dragged in the safe zone turn the view and sculpt nothing."""
    s = Script()
    edge_drags(s)
    return s, ["--orbit-style=turntable"], {"dabs": near(0), "undo_steps": near(0),
                                            "camera_yaw": near(wrap(0.6 - 400 * 0.008), 3e-3),
                                            "camera_distance": near(3.5 * 0.88 ** 8, 1e-3)}


@scenario
def edge_off_sculpts():
    """With the safe zone off, the same drags at the edges sculpt the model and leave the view alone."""
    s = Script()
    edge_drags(s)
    return s, ["--orbit-style=turntable", "--no-edge-orbit"], {"dabs": lambda v: int(v) > 0, "undo_steps": near(2),
                                                               "camera_yaw": near(0.6)}


def sphere_normal_under(x, y, width=1600, height=900, yaw=0.6, pitch=0.35, distance=3.5, fov=math.radians(40)):
    """The unit sphere's normal where the ray through window point (x, y) meets it, with the
    default camera: what the brush ring should lie flat against there."""
    t = math.tan(fov / 2)
    d = [(2 * x / width - 1) * t * width / height, (1 - 2 * y / height) * t, -1.0]
    cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(-pitch), math.sin(-pitch)
    # The view's turn applied to d: about x by -pitch, then about y by yaw.
    d = [d[0], cp * d[1] - sp * d[2], sp * d[1] + cp * d[2]]
    d = [cy * d[0] + sy * d[2], d[1], -sy * d[0] + cy * d[2]]
    n = math.sqrt(sum(v * v for v in d))
    d = [v / n for v in d]
    back = [sy * cp, -sp, cy * cp]
    eye = [distance * v for v in back]
    b = sum(e * v for e, v in zip(eye, d))
    s = b * b - (sum(e * e for e in eye) - 1)
    hit = [e + (-b - math.sqrt(s)) * v for e, v in zip(eye, d)]
    return hit


def normal_near(want, degrees):
    def ok(v):
        got = [float(c) for c in v.split(",")]
        return sum(a * b for a, b in zip(got, want)) > math.cos(math.radians(degrees))
    return ok


@scenario
def ring_lies_on_the_surface():
    """The brush ring over the sphere's edge lies along the surface there; off the model it is flat."""
    s = Script()
    s.add("move:1110,330")
    s.wait(4)
    return s, [], {"cursor_hit": near(1), "cursor_normal": normal_near(sphere_normal_under(1110, 330), 8), "dabs": near(0)}


@scenario
def ring_off_the_model_is_flat():
    """With the pointer on empty space there is no surface under the ring: it is the flat circle."""
    s = Script()
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.wait(4)
    return s, [], {"cursor_hit": near(0), "dabs": near(0)}


# Each scenario has a settings file of its own, so scenarios running side by side never
# read or overwrite another's.
CURRENT = threading.local()


def settings_file():
    """The settings file of the scenario running on this thread."""
    return os.path.join(ROOT, "build", "touch", "settings", CURRENT.name + ".txt")


def saved(**want):
    """A check on the settings file the scenario's app wrote on closing Settings."""
    def ok(_):
        if not os.path.exists(settings_file()):
            return False
        lines = dict(l.split(" ", 1) for l in open(settings_file()).read().splitlines() if " " in l)
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
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    s = Script()
    open_settings(s, "camera")
    s.ftap(1549, 717)  # Edges always turn the view
    s.wait(4)
    s.fdrag(line((1300, 395), (1305, 95), 20))  # from the Orbit speed slider, upward
    s.wait(16)
    s.ftap(1481, 791)  # Done
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], camera_still({
        "dabs": near(0), "settings_open": near(0), "settings_scroll": lambda v: float(v) > 100,
        "@saved": saved(edge_orbit="0", zoom_speed="1", orbit_speed="1")})


@scenario
def settings_reset_everything():
    """Reset everything takes a second tap, then puts every category back."""
    s = Script()
    with open(settings_file(), "w") as f:
        f.write("orbit_speed 2\ninvert_wheel 1\nfinger_model orbit\nstats 1\n")
    open_settings(s, "touch")
    s.ftap(1294, 791)  # Reset everything: arms it
    s.wait(10)
    s.ftap(1294, 791)  # Tap again to reset all
    s.wait(4)
    s.ftap(1481, 791)  # Done
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], camera_still({
        "settings_open": near(0), "@saved": saved(orbit_speed="1", invert_wheel="0", finger_model="Sculpt", stats="0")})


@scenario
def settings_reset_needs_second_tap():
    """One tap on Reset everything changes nothing."""
    s = Script()
    with open(settings_file(), "w") as f:
        f.write("orbit_speed 2\ninvert_wheel 1\n")
    open_settings(s, "camera")
    s.ftap(1294, 791)
    s.wait(4)
    s.ftap(1481, 791)  # Done
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], {"@saved": saved(orbit_speed="2", invert_wheel="1")}


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
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    s = Script()
    open_settings(s, "touch")
    s.ftap(1483, 251)  # Turns the view
    s.wait(4)
    s.ftap(1481, 791)  # Done
    s.wait(10)
    s.fdrag(past_slop((760, 430), (860, 430), 20))
    return s, [f"--settings-file={settings_file()}", "--orbit-style=turntable"], {
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
    s.fdrag(line((1430, 384), (1435, 144), 20))
    return s, [], camera_still({"dabs": near(0), "inspector_scroll": lambda v: float(v) > 100, "selected": near(0)})


def saved_line(line):
    """A check that the settings file the app wrote holds `line` (for keys with several lines)."""
    def ok(_):
        return os.path.exists(settings_file()) and line in open(settings_file()).read().splitlines()
    return ok


# The inspector's title bar at 1600 x 900: its title, Minimise and Close.
INSPECTOR_TITLE, INSPECTOR_MINIMISE, INSPECTOR_CLOSE = (1340, 103), (1504, 103), (1554, 103)
# The Stats window's title, where it starts (Settings > Performance or F11 opens it).
STATS_TITLE = (200, 104)


@scenario
def window_minimise_folds_to_the_title_bar():
    """A tap on the inspector's Minimise folds it to its title bar; nothing else moves."""
    s = Script()
    s.ftap(*INSPECTOR_MINIMISE)
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "window_inspector": lambda v: v.startswith("1,1,")})


@scenario
def window_tap_on_folded_title_opens_it():
    """Folded, a tap on the inspector's title opens it again, and its first drag scrolls it as before."""
    s = Script()
    s.ftap(*INSPECTOR_MINIMISE)
    s.wait(4)
    s.ftap(*INSPECTOR_TITLE)
    s.wait(4)
    s.fdrag(line((1430, 334), (1435, 114), 22))
    return s, [], camera_still({"dabs": near(0), "window_inspector": lambda v: v.startswith("1,0,"),
                                "inspector_scroll": lambda v: float(v) > 100})


@scenario
def window_close_and_reopen():
    """Close hides the inspector; the Inspector button at the top right brings it back."""
    s = Script()
    s.ftap(*INSPECTOR_CLOSE)
    s.wait(10)
    s.ftap(1565, 36)
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "window_inspector": lambda v: v.startswith("1,0,")})


@scenario
def window_drag_by_title_is_remembered():
    """A finger drags the Stats window by its title to exactly under the finger, turning nothing; it is saved."""
    with open(settings_file(), "w") as f:
        f.write("stats 1\n")
    s = Script()
    s.fdrag(line(STATS_TITLE, (700, 300), 20))
    s.wait(4)
    # Grabbed 84 points in from its left and 36 down from its top.
    return s, [f"--settings-file={settings_file()}"], camera_still({
        "dabs": near(0), "window_stats": lambda v: v == "1,0,616,264",
        "@saved": saved_line("window Stats 1 Start Start 616 264 0")})


@scenario
def window_position_comes_back():
    """A remembered window position and fold come back on the next start."""
    with open(settings_file(), "w") as f:
        f.write("stats 1\nwindow Stats 1 Start Start 616 264 0\nwindow Inspector 0 Start Start 0 0 1\n")
    s = Script()
    s.add("move:800,450")
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], {"window_stats": lambda v: v == "1,0,616,264",
                                                     "window_inspector": lambda v: v.startswith("1,1,")}


@scenario
def small_window():
    """A 1280 x 800 window (a tablet's size): the inspector scrolls from the first touch and far-apart taps turn nothing."""
    s = Script()
    s.fdrag(line((1110, 334), (1115, 114), 22))
    s.ftap(200, 150)
    s.ftap(1000, 700)
    s.ftap(150, 650)
    return s, ["--width=1280", "--height=800"], camera_still({"dabs": near(0), "inspector_scroll": lambda v: float(v) > 50,
                                                            "brush_radius_px": near(60)})



# The modifier rail's buttons at the bottom left at 1600 x 900, and the finger that holds
# them: an id of its own, as a second hand's finger would have.
RAIL = {"smooth": (38, 808), "invert": (86, 808), "mask": (38, 860), "hide": (86, 860)}
RAIL_FINGER = 9


def pen_stroke(s, path):
    """The pen near, down along `path` one frame a point, up and away."""
    s.add("pnear")
    s.add(f"pdown:{path[0][0]:g},{path[0][1]:g}")
    for x, y in path[1:]:
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
    s.wait(1)
    s.add("pup")
    s.wait(2)
    s.add("pfar")
    s.wait(3)


def rail_tap(s, which):
    s.ftap(*RAIL[which], finger=RAIL_FINGER)


def rail_hold(s, which):
    x, y = RAIL[which]
    s.add(f"fdown:{RAIL_FINGER}:{x:g},{y:g}")
    s.wait(2)


def rail_lift(s):
    s.add(f"fup:{RAIL_FINGER}")
    s.wait(3)


def overlap(a, b):
    ax, ay, aw, ah = (float(v) for v in a.split(","))
    bx, by, bw, bh = (float(v) for v in b.split(","))
    return aw > 0 and bw > 0 and ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


def rail_clear(*others):
    """A check that the rail is shown and meets none of `others` (layout names)."""
    def ok(stats):
        rail = stats["layout_modifier_rail"]
        return float(rail.split(",")[2]) > 0 and not any(overlap(rail, stats[f"layout_{o}"]) for o in others)
    return ok


@scenario
def rail_hold_smooth_with_pen():
    """A finger held on Smooth while the pen strokes the model: the stroke smooths, and lifting latches nothing."""
    s = Script()
    rail_hold(s, "smooth")
    pen_stroke(s, line((760, 430), (860, 470), 20))
    rail_lift(s)
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1), "stroke_kind": lambda v: v == "smooth",
                                "rail_latched": lambda v: v == "none"})


@scenario
def finger_tap_with_invert_latched_dabs_inverted():
    """A quick finger tap on the model with Invert latched lays an inverted dab: the tap's release frame keeps the press's modifiers."""
    s = Script()
    rail_tap(s, "invert")
    s.wait(4)
    s.ftap(*MODEL, hold=2)
    s.wait(24)  # the dab waits out the double tap's gap
    return s, [], camera_still({"dabs": lambda v: int(v) >= 1, "undo_steps": near(1), "stroke_invert": near(1)})


@scenario
def rail_tap_latches_invert():
    """A quick tap on Invert latches it: a finger stroke after it is inverted."""
    s = Script()
    rail_tap(s, "invert")
    s.fdrag(line((760, 430), (860, 470), 20))
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1), "stroke_kind": lambda v: v == "draw",
                                "stroke_invert": near(1), "rail_latched": lambda v: v == "invert"})


@scenario
def rail_mask_paints_mask():
    """A finger held on Mask: another finger's stroke on the model paints the mask (the scripted pen has no pressure to mask with)."""
    s = Script()
    rail_hold(s, "mask")
    s.fdrag(line((760, 430), (860, 470), 20))
    rail_lift(s)
    return s, [], camera_still({"undo_steps": near(1), "stroke_kind": lambda v: v == "mask", "masked": near(1)})


@scenario
def rail_mask_shape_from_empty_space():
    """Mask latched: a finger dragged from empty space draws a mask rectangle over the model instead of turning the view."""
    s = Script()
    rail_tap(s, "mask")
    s.fdrag(line((250, 150), (900, 600), 20))
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "masked": near(1), "undo_steps": near(1), "rail_latched": lambda v: v == "mask"})


@scenario
def rail_hide_gesture():
    """Hide latched: a finger drags the hide rectangle over part of the model, and the rest is hidden."""
    s = Script()
    rail_tap(s, "hide")
    s.fdrag(line((250, 150), (800, 450), 20))
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "hidden_triangles": lambda v: int(v) > 0, "rail_latched": lambda v: v == "hide"})


@scenario
def rail_finger_survives_pen_down():
    """The pen landing never cancels a finger held on the rail: Invert holds through the pen's stroke."""
    s = Script()
    rail_hold(s, "invert")
    pen_stroke(s, line((760, 430), (860, 470), 20))
    rail_lift(s)
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1), "redo_steps": near(0),
                                "stroke_invert": near(1), "rail_latched": lambda v: v == "none"})


@scenario
def rail_mouse_click_latches():
    """The mouse clicks a rail button like any other: it latches, and sculpts nothing."""
    s = Script()
    s.mouse_drag([RAIL["invert"], RAIL["invert"]])
    s.mouse_drag([RAIL["smooth"], RAIL["smooth"]])
    return s, [], camera_still({"dabs": near(0), "rail_latched": lambda v: v == "smooth+invert"})


@scenario
def rail_finger_while_pen_near():
    """With the pen hovering, a finger on the rail is still the rail's (no palm), and its tap latches."""
    s = Script()
    s.add("pnear")
    s.wait(2)
    rail_tap(s, "invert")
    s.add("pfar")
    s.wait(3)
    return s, [], camera_still({"dabs": near(0), "rail_latched": lambda v: v == "invert"})


@scenario
def rail_finger_during_pinch():
    """A finger landing on the rail during a pinch is no third finger: the pinch zooms on and the brush keeps its size."""
    s = Script()
    starts, moves, frames = [(300, 300), (400, 300)], [(-100, 0), (100, 0)], 20
    for i, (x, y) in enumerate(starts):
        s.add(f"fdown:{i}:{x:g},{y:g}")
    s.wait(2)
    for k in range(1, frames + 1):
        if k == 5:
            s.add(f"fdown:{RAIL_FINGER}:{RAIL['smooth'][0]:g},{RAIL['smooth'][1]:g}")
        for i, ((x, y), (dx, dy)) in enumerate(zip(starts, moves)):
            s.add(f"fmove:{i}:{x + dx * k / frames:g},{y + dy * k / frames:g}")
        s.wait(1)
    for i in range(len(starts)):
        s.add(f"fup:{i}")
    s.wait(2)
    rail_lift(s)
    return s, [], {"camera_distance": near(3.5 / 3, 0.02), "dabs": near(0), "brush_radius_px": near(60),
                   "rail_latched": lambda v: v == "none"}


@scenario
def rail_lift_mid_stroke_keeps_mode():
    """Lifting the finger from Smooth halfway through the pen's stroke leaves it smoothing to the end, as one stroke."""
    s = Script()
    rail_hold(s, "smooth")
    s.add("pnear")
    path = line((760, 430), (860, 470), 20)
    s.add(f"pdown:{path[0][0]:g},{path[0][1]:g}")
    for k, (x, y) in enumerate(path[1:]):
        s.wait(1)
        s.add(f"pmove:{x:g},{y:g}")
        if k == 8:
            s.add(f"fup:{RAIL_FINGER}")
    s.wait(1)
    s.add("pup")
    s.wait(2)
    s.add("pfar")
    s.wait(3)
    return s, [], camera_still({"undo_steps": near(1), "stroke_kind": lambda v: v == "smooth", "rail_latched": lambda v: v == "none"})


@scenario
def rail_latched_edge_still_orbits():
    """Mask latched, a finger dragged from the safe zone's edge band still turns the view (only a held rail finger takes the band)."""
    s = Script()
    rail_tap(s, "mask")
    s.fdrag(past_slop((300, 860), (500, 860), 20))
    return s, [], {"camera_yaw": lambda v: abs(float(v) - 0.6) > 0.05, "dabs": near(0), "masked": near(0)}


@scenario
def rail_under_window_goes_to_window():
    """Where a window lies over the rail, a finger there is the window's: nothing latches."""
    with open(settings_file(), "w") as f:
        f.write("stats 1\nwindow Stats 1 Start Start 0 700 0\n")
    s = Script()
    rail_tap(s, "invert")
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], {"dabs": near(0), "rail_latched": lambda v: v == "none",
                                                     "window_stats": lambda v: v.startswith("1,")}


@scenario
def rail_fits_a_large_interface():
    """At interface size 1.5 on a 1280 x 800 window the rail meets neither the sliders nor the dock."""
    with open(settings_file(), "w") as f:
        f.write("ui_scale 1.5\n")
    s = Script()
    s.add("move:640,400")
    s.wait(6)
    return s, ["--width=1280", "--height=800", f"--settings-file={settings_file()}"], {"@layout": rail_clear("sliders", "dock")}


@scenario
def rail_fits_portrait():
    """In a portrait 800 x 1280 window the rail clears the dock and the sliders."""
    s = Script()
    s.add("move:400,640")
    s.wait(6)
    return s, ["--width=800", "--height=1280"], {"@layout": rail_clear("sliders", "dock")}


@scenario
def rail_on_the_right_clears_the_panels():
    """Put on the right, the rail sits above the object's status, clear of the inspector and the dock."""
    with open(settings_file(), "w") as f:
        f.write("modifier_rail Right\n")
    s = Script()
    s.add("move:640,400")
    s.wait(6)
    return s, [f"--settings-file={settings_file()}"], {"@layout": rail_clear("status", "inspector", "dock", "sliders")}


def long_press(s, x, y, finger=0, frames=LONG_PRESS_FRAMES):
    """A finger held still on (x, y) long enough to be a long press, then lifted."""
    s.add(f"fdown:{finger}:{x:g},{y:g}")
    s.wait(frames)
    s.add(f"fup:{finger}")
    s.wait(4)


INSPECTOR_BUTTON = (1565, 36)
SCENE_TAB, SCENE_ROW = (1526, 152), (1430, 232)


@scenario
def long_press_shows_the_tooltip_and_does_not_tap():
    """A long press on the Inspector button shows its tooltip and leaves the inspector open; nothing is sculpted."""
    s = Script()
    long_press(s, *INSPECTOR_BUTTON)
    return s, [], camera_still({"dabs": near(0), "long_tip": lambda v: v == "Inspector",
                                "window_inspector": lambda v: v.startswith("1,0,")})


@scenario
def long_press_a_scene_row_opens_its_menu():
    """A long press on an object in the Scene tab opens its menu (Focus, Duplicate, Delete), as a right-click does."""
    s = Script()
    s.ftap(*SCENE_TAB)
    s.wait(10)
    long_press(s, *SCENE_ROW)
    return s, [], camera_still({"dabs": near(0), "object_menu": near(1), "selected": near(0)})


@scenario
def slow_tap_on_a_folded_title_still_opens_it():
    """A long press on a folded window's title, which has no tooltip and no other action, is still a tap."""
    s = Script()
    s.ftap(*INSPECTOR_MINIMISE)
    s.wait(4)
    long_press(s, *INSPECTOR_TITLE)
    return s, [], camera_still({"dabs": near(0), "window_inspector": lambda v: v.startswith("1,0,"), "long_tip": lambda v: v == "none"})


@scenario
def a_press_short_of_long_still_taps():
    """A finger held 0.3 s on the Inspector button is still a tap: no tooltip, and the inspector closes."""
    s = Script()
    x, y = INSPECTOR_BUTTON
    s.add(f"fdown:0:{x:g},{y:g}")
    s.wait(18)
    s.add(f"fup:0")
    s.wait(4)
    return s, [], camera_still({"long_tip": lambda v: v == "none", "window_inspector": lambda v: v.startswith("0,")})


STATUS_CHIP = (1510, 864)


@scenario
def long_press_undo_opens_history():
    """After a stroke, a long press on Undo opens the History panel and undoes nothing."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    long_press(s, *UI["undo"])
    return s, [], camera_still({"undo_steps": near(1), "redo_steps": near(0), "window_history": lambda v: v.startswith("1,")})


@scenario
def right_click_undo_opens_history():
    """The desktop twin: a right-click on Undo opens the History panel; a left click still undoes."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    s.add("move:{:g},{:g}".format(*UI["undo"]))
    s.wait(3)
    s.add("right")
    s.wait(4)
    return s, [], camera_still({"undo_steps": near(1), "window_history": lambda v: v.startswith("1,")})


@scenario
def long_press_dock_brush_opens_its_settings():
    """A long press on Smooth in the dock picks it and turns the inspector to its settings, from the Object tab."""
    s = Script()
    s.ftap(*UI["tab_object"])
    s.wait(6)
    long_press(s, *UI["dock_smooth"])
    return s, [], camera_still({"dabs": near(0), "brush_kind": lambda v: v == "smooth", "inspector_tab": lambda v: v == "tool",
                                "window_inspector": lambda v: v.startswith("1,0,")})


@scenario
def long_press_size_slider_resets_it():
    """The size slider dragged up, then a long press on it: the brush is back to 60 px."""
    s = Script()
    x, y = UI["size_slider"]
    s.fdrag(line((x, y), (x, y - 80), 10))
    long_press(s, x, y)
    return s, [], camera_still({"dabs": near(0), "brush_radius_px": near(60)})


@scenario
def size_slider_drag_still_slides():
    """A drag on the size slider (the control check for the reset above) changes the size and sculpts nothing."""
    s = Script()
    x, y = UI["size_slider"]
    s.fdrag(line((x, y), (x, y - 80), 10))
    return s, [], camera_still({"dabs": near(0), "brush_radius_px": lambda v: float(v) > 80})


@scenario
def status_chip_tap_and_long_press():
    """A tap on the object's status shows the Object tab; a long press on it opens the object menu."""
    s = Script()
    s.ftap(*STATUS_CHIP)
    s.wait(6)
    long_press(s, *STATUS_CHIP)
    return s, [], camera_still({"dabs": near(0), "inspector_tab": lambda v: v == "object", "object_menu": near(1)})

# Touch step 3: double tap, lifting one of two fingers, holding fingers for undo.

def double_tap(s, x, y, gap=6):
    """Two quick finger taps at one place, `gap` frames apart (DOUBLE_TAP_GAP is 18)."""
    s.ftap(x, y, hold=2, gap=gap)
    s.ftap(x, y, hold=2, gap=4)


def strokes(s, n):
    """`n` finger strokes across the model, each an undo step."""
    for i in range(n):
        s.fdrag(line((700, 380 + 30 * i), (860, 400 + 30 * i), 12))
        s.wait(2)


# Two wheel notches in: empty space is still empty at EMPTY.
ZOOMED = 3.5 * 0.88 ** 2


def zoom_a_little(s):
    s.add("move:800,450")
    s.wait(1)
    s.add("wheel:2")
    s.wait(3)


def write_settings(text):
    with open(settings_file(), "w") as f:
        f.write(text)


@scenario
def double_tap_empty_frames_the_object():
    """Zoomed in, a double tap on empty space frames the selected object again and sculpts nothing."""
    s = Script()
    zoom_a_little(s)
    double_tap(s, *EMPTY)
    s.wait(4)
    return s, [], {"camera_distance": near(3.5), "framed": near(1), "dabs": near(0), "undo_steps": near(0)}


@scenario
def double_tap_too_slow_is_two_taps():
    """Two taps on empty space further apart than the gap frame nothing."""
    s = Script()
    zoom_a_little(s)
    double_tap(s, *EMPTY, gap=24)
    s.wait(4)
    return s, [], {"camera_distance": near(ZOOMED), "framed": near(0)}


@scenario
def double_tap_too_far_is_two_taps():
    """Two quick taps on empty space 80 points apart frame nothing."""
    s = Script()
    zoom_a_little(s)
    s.ftap(*EMPTY, hold=2, gap=6)
    s.ftap(EMPTY[0] + 80, EMPTY[1], hold=2)
    s.wait(4)
    return s, [], {"camera_distance": near(ZOOMED), "framed": near(0)}


@scenario
def double_tap_in_the_edge_band_does_nothing():
    """A double tap in the safe zone, beside the panels, frames nothing."""
    s = Script()
    zoom_a_little(s)
    double_tap(s, 250, 868)
    s.wait(4)
    return s, [], {"camera_distance": near(ZOOMED), "framed": near(0)}


@scenario
def double_tap_off_frames_nothing():
    """With Double tap to frame or pin off, a double tap on empty space does nothing."""
    s = Script()
    write_settings("double_tap 0\n")
    zoom_a_little(s)
    double_tap(s, *EMPTY)
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], {"camera_distance": near(ZOOMED), "framed": near(0)}


@scenario
def double_tap_model_pins_the_pivot():
    """Where one finger turns the view, a double tap on the model pins the pivot there: the next orbit turns about that point and the view does not jump."""
    s = Script()
    double_tap(s, *MODEL)
    s.wait(10)
    s.fdrag(past_slop(EMPTY, (EMPTY[0] + 100, EMPTY[1]), 10))
    def pivot_on_front(st):
        x, y, z = (float(v) for v in st["orbit_pivot"].split(","))
        return abs(math.sqrt(x * x + y * y + z * z) - 1) < 0.05
    return s, ["--finger-orbits", "--orbit-style=turntable"], {
        "pinned": near(1), "pivot_source": lambda v: v == "tapped", "@pivot": pivot_on_front,
        "dabs": near(0), "undo_steps": near(0), "camera_yaw": lambda v: abs(float(v) - 0.6) > 0.5}


@scenario
def pinned_pivot_ends_with_the_next_stroke():
    """A pin lasts until the next stroke ends: the pen's stroke on the model unpins it."""
    s = Script()
    double_tap(s, *MODEL)
    s.wait(6)
    pen_stroke(s, line((760, 430), (860, 470), 20))
    return s, ["--finger-orbits"], {"pinned": near(0), "undo_steps": near(1)}


@scenario
def double_tap_model_while_sculpting_pins_without_dabs():
    """Where one finger sculpts (the default), a double tap on the model pins the pivot and neither tap sculpts."""
    s = Script()
    double_tap(s, *MODEL)
    s.wait(24)
    return s, [], camera_still({"pinned": near(1), "pivot_source": lambda v: v == "tapped", "undo_steps": near(0), "dabs": near(0)})


@scenario
def single_tap_dab_lands_after_the_gap():
    """One finger tap on the model lays its dab once the double tap's gap ran out."""
    s = Script()
    s.ftap(*MODEL)
    s.wait(24)
    return s, [], camera_still({"pinned": near(0), "undo_steps": near(1), "dabs": lambda v: int(v) >= 1})


@scenario
def tap_dab_waits_for_nothing_else():
    """A tap's dab then an Undo tap on the panel straight after: the dab plays first, so Undo takes it back."""
    s = Script()
    s.ftap(*MODEL, gap=2)
    s.ftap(*UI["undo"])
    s.wait(24)
    return s, [], camera_still({"undo_steps": near(0), "redo_steps": near(1)})


@scenario
def tap_then_stroke_keeps_both():
    """A tap, then straight away a stroke starting where it was: the tap's dab and the stroke are two undo steps."""
    s = Script()
    s.ftap(*MODEL, gap=4)
    s.fdrag(line(MODEL, (MODEL[0] + 120, MODEL[1] + 30), 12))
    s.wait(6)
    return s, [], camera_still({"undo_steps": near(2), "pinned": near(0)})


@scenario
def tap_then_two_fingers_keeps_the_dab():
    """A tap, then two fingers pinching at once: the tap's dab lands where it was tapped and the pinch zooms."""
    s = Script()
    s.ftap(*MODEL, gap=3)
    s.fingers([(700, 450), (900, 450)], [(-60, 0), (60, 0)], 10)
    return s, [], {"undo_steps": near(1), "camera_distance": lambda v: float(v) < 3.4, "pinned": near(0)}


@scenario
def tap_then_palm_nearby_still_dabs():
    """A tap, then a finger resting beside it with the pen near (a palm, which the touch ignores): the tap's dab still lands."""
    s = Script()
    s.ftap(*MODEL, gap=2)
    s.add("pnear")
    s.add(f"fdown:3:{MODEL[0] + 20},{MODEL[1] + 10}")
    s.wait(30)
    s.add("fup:3")
    s.add("pfar")
    s.wait(4)
    return s, [], camera_still({"undo_steps": near(1), "pinned": near(0)})


@scenario
def double_tap_off_taps_dab_at_once():
    """With Double tap to frame or pin off, two quick taps on the model are two dabs, each laid as its finger lifts."""
    s = Script()
    write_settings("double_tap 0\n")
    double_tap(s, *MODEL)
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], camera_still({"pinned": near(0), "undo_steps": near(2)})


def lift_one(s, moves=((0, 0), (0, 0)), frames=4):
    """Two fingers on the model, `moves` apart over `frames`, then the second lifts and the
    first drags 150 points to the right."""
    s.fingers([(760, 430), (860, 470)], moves, frames, lift=False)
    s.add("fup:1")
    s.wait(2)
    x = 760 + moves[0][0]
    y = 430 + moves[0][1]
    for k in range(1, 16):
        s.add(f"fmove:0:{x + 10 * k:g},{y:g}")
        s.wait(1)
    s.add("fup:0")
    s.wait(4)


@scenario
def lift_one_finger_turns_the_view():
    """Two fingers down on the model, one lifted: the other turns the view and sculpts nothing."""
    s = Script()
    lift_one(s)
    return s, ["--orbit-style=turntable"], {"camera_yaw": lambda v: float(v) < 0.6 - 0.5, "dabs": near(0), "undo_steps": near(0), "redo_steps": near(0)}


@scenario
def lift_one_off_turns_nothing():
    """With Lift one of two fingers to turn off, the finger left does nothing."""
    s = Script()
    write_settings("lift_one_orbit 0\n")
    lift_one(s)
    return s, [f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "undo_steps": near(0)})


@scenario
def pinch_then_lift_turns_nothing():
    """After a pinch, the finger left rolling on turns nothing: only a pair that stayed still may orbit."""
    s = Script()
    lift_one(s, moves=((-60, -30), (60, 30)), frames=10)
    return s, ["--orbit-style=turntable"], {"camera_yaw": near(0.6), "camera_pitch": near(0.35), "camera_distance": lambda v: float(v) < 3.4, "dabs": near(0)}


def hold(s, n, frames, late=0, starts=((740, 430), (840, 450), (790, 520))):
    """`n` fingers down together (or the last `late` frames after), on the model unless
    `starts` says, held still for `frames`, then lifted."""
    starts = starts[:n]
    for i, (x, y) in enumerate(starts):
        if i == n - 1 and late:
            s.wait(late)
        s.add(f"fdown:{i}:{x:g},{y:g}")
    s.wait(frames)
    for i in range(n):
        s.add(f"fup:{i}")
    s.wait(4)


@scenario
def hold_two_fingers_repeats_undo():
    """After four strokes, two fingers held still for 0.75 s undo three of them (one at 0.45 s, then every 0.12 s)."""
    s = Script()
    strokes(s, 4)
    hold(s, 2, 45)
    return s, [], camera_still({"undo_steps": near(1), "redo_steps": near(3), "touch_repeats": near(3)})


@scenario
def hold_three_fingers_repeats_redo():
    """Two fingers held undo all four strokes; three held for 0.75 s then redo three."""
    s = Script()
    strokes(s, 4)
    hold(s, 2, 70)
    hold(s, 3, 45)
    return s, [], camera_still({"undo_steps": near(3), "redo_steps": near(1), "touch_repeats": near(7)})


@scenario
def hold_with_the_pen_near_does_nothing():
    """Two fingers held while the pen is near the screen undo nothing: a hand resting as it draws."""
    s = Script()
    strokes(s, 2)
    s.add("pnear")
    s.wait(2)
    hold(s, 2, 45)
    s.add("pfar")
    s.wait(2)
    return s, [], camera_still({"undo_steps": near(2), "touch_repeats": near(0)})


@scenario
def hold_with_a_late_finger_does_nothing():
    """A second finger landing 0.2 s after the first, as a palm's do, makes no hold."""
    s = Script()
    strokes(s, 2)
    # On empty space, where the first finger alone does nothing either.
    hold(s, 2, 45, late=12, starts=(EMPTY, (EMPTY[0] + 80, EMPTY[1] + 20)))
    return s, [], camera_still({"undo_steps": near(2), "touch_repeats": near(0)})


@scenario
def hold_off_undoes_nothing():
    """With Hold two fingers to keep undoing off, a still hold undoes nothing."""
    s = Script()
    write_settings("hold_history 0\n")
    strokes(s, 2)
    hold(s, 2, 45)
    return s, [f"--settings-file={settings_file()}"], camera_still({"undo_steps": near(2), "touch_repeats": near(0)})


@scenario
def slow_pinch_never_undoes():
    """Two fingers spreading slowly for a second, under the slop, zoom and never undo."""
    s = Script()
    strokes(s, 2)
    s.fingers([(760, 450), (840, 450)], [(-8, 0), (8, 0)], 60)
    return s, [], {"undo_steps": near(2), "touch_repeats": near(0), "camera_distance": lambda v: float(v) < 3.5}


# Start-location taps with Mask on (ZBrush's Ctrl click, Nomad's taps while Mask is held).

MASK_STROKE = line((760, 430), (860, 470), 20)
UNMASKED = (650, 600)  # on the model, away from MASK_STROKE


def masked_first(s):
    """Mask latched on the rail, then a finger stroke paints a band of mask."""
    rail_tap(s, "mask")
    s.wait(2)
    s.fdrag(MASK_STROKE)
    s.wait(2)


@scenario
def mask_tap_off_the_model_inverts():
    """With Mask latched, a tap on empty space inverts the mask, says so with Undo, and paints nothing."""
    s = Script()
    masked_first(s)
    s.ftap(*EMPTY)
    s.wait(4)
    return s, [], camera_still({"last_op": lambda v: v == "Invert_mask", "toast_undo": near(1), "undo_steps": near(2),
                                "mask_mean": lambda v: float(v) > 0.8})


@scenario
def mask_tap_on_the_mask_blurs():
    """With Mask latched, a tap on the masked band blurs the mask and paints no dot."""
    s = Script()
    masked_first(s)
    s.ftap(810, 450)
    s.wait(4)
    return s, [], camera_still({"last_op": lambda v: v == "Blur_mask", "toast_undo": near(1), "undo_steps": near(2)})


@scenario
def mask_tap_off_the_mask_sharpens():
    """With Mask latched, a tap on the model away from the mask sharpens it."""
    s = Script()
    masked_first(s)
    s.ftap(*UNMASKED)
    s.wait(4)
    return s, [], camera_still({"last_op": lambda v: v == "Sharpen_mask", "undo_steps": near(2)})


@scenario
def mask_pen_tap_inverts_too():
    """The pen tapping empty space with Mask latched inverts the mask as a finger does."""
    s = Script()
    masked_first(s)
    s.add("pnear")
    s.wait(1)
    s.add(f"pdown:{EMPTY[0]},{EMPTY[1]}")
    s.wait(2)
    s.add("pup")
    s.wait(2)
    s.add("pfar")
    s.wait(3)
    return s, [], camera_still({"last_op": lambda v: v == "Invert_mask", "undo_steps": near(2)})


@scenario
def ctrl_click_off_the_model_inverts_the_mask():
    """The mouse: Ctrl and a click on empty space invert the mask (ZBrush's Ctrl click)."""
    s = Script()
    masked_first(s)
    rail_tap(s, "mask")  # let go of Mask: Ctrl alone
    s.mouse_drag([EMPTY, EMPTY], keys=("ctrl",))
    return s, [], camera_still({"last_op": lambda v: v == "Invert_mask", "undo_steps": near(2), "rail_latched": lambda v: v == "none"})


@scenario
def ctrl_click_on_the_model_still_sculpts_inverted():
    """Ctrl and a click on the model is still an inverted dab, not a mask command."""
    s = Script()
    s.mouse_drag([MODEL, MODEL], keys=("ctrl",))
    return s, [], camera_still({"stroke_invert": near(1), "undo_steps": near(1), "last_op": lambda v: v == "none"})


def run(name, screens, displays=None):
    CURRENT.name = name
    os.makedirs(os.path.dirname(settings_file()), exist_ok=True)
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    script, args, checks = SCENARIOS[name]()
    frames = script.frame + 10
    cmd = [EXE, f"--frames={frames}", f"--ui-events={script.spec()}"]
    if not any(a.startswith("--width") for a in args):
        cmd += ["--width=1600", "--height=900"]
    if not any(a.startswith("--settings-file") for a in args):
        cmd.append("--no-settings")
    # The interface's clock moves 1/60 s a frame, however fast frames come here, so a
    # finger held N frames is a long press (or not) on every machine.
    if not any(a.startswith("--ui-dt") for a in args):
        cmd.append(f"--ui-dt={UI_DT:g}")
    cmd += args
    if screens:
        os.makedirs(os.path.join(ROOT, "build", "touch"), exist_ok=True)
        cmd.append(f"--dump-screen={os.path.join(ROOT, 'build', 'touch', name + '.png')}")
    env = dict(os.environ, SDL_ASSERT="abort")
    display = displays.get() if displays else None
    try:
        if display:
            env.pop("WAYLAND_DISPLAY", None)
            env.update(DISPLAY=display, SDL_VIDEO_DRIVER="x11")
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=600)
    finally:
        if display:
            displays.put(display)
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
            # A check on files, or on several stats at once: it is given all of them.
            try:
                good = ok(stats)
            except (KeyError, ValueError):
                good = False
            if not good:
                failures.append(f"{key} wrong")
        elif key not in stats:
            failures.append(f"{key} missing")
        elif not ok(stats[key]):
            failures.append(f"{key}={stats[key]}")
    return failures, stats


def start_displays(count):
    """A virtual X display for each scenario running at once, on Linux when Xvfb is there.

    Windows sharing one display take the focus from each other as they open, and a window
    losing the focus forgets the fingers on it (touch.odin), so side by side scenarios each
    need a display of their own. Returns the servers and a queue of their names, or no
    queue when there is no Xvfb, or one job and a display already (the current one is used).
    """
    if os.name == "nt" or not shutil.which("Xvfb"):
        return [], None
    # One job on a desktop uses its display; with no display at all it gets a private one.
    if count < 2 and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return [], None
    servers, displays = [], queue.Queue()
    for i in range(count):
        # High numbers, clear of a desktop's :0 and xvfb-run's :99.
        name = f":{200 + os.getpid() % 500 * 8 + i}"
        servers.append(subprocess.Popen(["Xvfb", name, "-screen", "0", "1600x1400x24", "-nolisten", "tcp"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        displays.put(name)
    # Each server takes a moment to accept connections.
    for i in range(count):
        socket = f"/tmp/.X11-unix/X{200 + os.getpid() % 500 * 8 + i}"
        for _ in range(100):
            if os.path.exists(socket):
                break
            time.sleep(0.05)
    return servers, displays


def main(argv):
    if "--list" in argv:
        for name, fn in SCENARIOS.items():
            print(f"{name:40s} {fn.__doc__}")
        return 0
    screens = "--screens" in argv
    # Side by side only where each scenario can have a display of its own (start_displays).
    jobs = (os.cpu_count() or 1) if os.name != "nt" and shutil.which("Xvfb") else 1
    for a in argv:
        if a.startswith("--jobs="):
            jobs = max(1, int(a.split("=", 1)[1]))
    # A name may be a pattern: long_press* runs every long press scenario.
    patterns = [a for a in argv if not a.startswith("--")]
    names = [n for n in SCENARIOS if not patterns or any(fnmatch.fnmatchcase(n, p) for p in patterns)]
    unknown = [p for p in patterns if not any(fnmatch.fnmatchcase(n, p) for n in SCENARIOS)]
    if unknown:
        print(f"no scenario matches {', '.join(unknown)}: see --list")
        return 1
    if not os.path.exists(EXE):
        print(f"{EXE} is missing: build the debug app first")
        return 1
    # Each scenario is its own process with its own window, so they run side by side; the
    # results print in the scenarios' order, each as soon as it and those before it are done.
    failed = 0
    start = time.monotonic()
    servers, displays = start_displays(min(jobs, len(names)))
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = [pool.submit(run, name, screens, displays) for name in names]
            for name, future in zip(names, futures):
                failures, stats = future.result()
                cam = " ".join(f"{k}={stats.get(k, '?')}" for k in ("camera_yaw", "camera_pitch", "camera_roll", "camera_distance", "dabs", "undo_steps"))
                print(f"{'PASS' if not failures else 'FAIL'} {name:40s} {cam}", flush=True)
                for f in failures:
                    print(f"     {f}")
                failed += bool(failures)
    finally:
        for server in servers:
            server.terminate()
            server.wait()
    seconds = time.monotonic() - start
    print(f"{len(names) - failed} of {len(names)} scenarios pass in {seconds:.0f}s (desktop touch simulation, not a tablet)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
