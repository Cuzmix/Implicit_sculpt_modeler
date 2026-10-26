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
    python scripts/touch_check.py --screens       # also write build/touch/<name>.png (of the last run)
    python scripts/touch_check.py x --screen-run=2  # ...of run 2 instead, to look at a middle state
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
    "search": (1468, 36), "palette_row1": (1280, 146), "palette_row2": (1280, 192),
    "earlier_save2": (100, 160),
    "page_shape": (1326, 252), "page_select": (1397, 252), "page_surface": (1467, 252), "page_build": (1538, 252),
}
# Menu rows at 1600x900, from kit_menu's order (new_ui.odin): add a FILE row here, not to
# every coordinate under it. Rows are 44 points apart; a divider and caption take 69.
MENU_FILE_ROWS = ["open", "save", "save_as", "save_copy", "earlier_saves", "last_autosave", "import", "export", "screenshot"]
_file_y = {name: 116 + 44 * i for i, name in enumerate(MENU_FILE_ROWS)}
_grid_y = _file_y[MENU_FILE_ROWS[-1]] + 69
UI.update({
    "menu_earlier_saves": (85, _file_y["earlier_saves"]),
    "new_sphere": (58, _grid_y), "new_head": (145, _grid_y), "new_hand": (145, _grid_y + 48),
    "menu_settings": (85, _grid_y + 48 + 69 + 44),
})
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
        down, up = {"left": ("down", "up"), "middle": ("mdown", "mup"), "right": ("rdown", "rup")}[button]
        self.add(down)
        for x, y in path[1:]:
            self.wait(1)
            self.add(f"move:{x:g},{y:g}")
        self.wait(1)
        self.add(up)
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

    def type(self, text):
        """Types `text` a letter a frame, each as a keyboard sends it: the key, and the
        letter as text (which the app takes only while a text field has the keys)."""
        for ch in text:
            name = "Space" if ch == " " else ch
            self.add(f"key:{name}")
            self.add(f"text:{ch}")
            self.wait(1)
            self.add(f"keyup:{name}")
        self.wait(2)

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
    s.fdrag(line((1430, 433), (1520, 435), 12))
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
    s.ftap(*UI["menu_settings"])
    s.wait(16)
    s.ftap(*{"interface": (1241, 158), "camera": (1315, 158), "touch": (1388, 158), "keys": (1462, 158), "performance": (1535, 158)}[tab])
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
    s.ftap(*UI["menu_settings"])
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
        s.ftap(*UI["menu_settings"])
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


# The Mask section's More options row on the Object tab's Select page at 1600 x 900.
MASK_MORE = (1330, 750)


def select_page(s):
    s.ftap(*UI["tab_object"])
    s.wait(6)
    s.ftap(*UI["page_select"])
    s.wait(10)


@scenario
def more_options_open_and_fold():
    """A finger tap on the Mask section's More options opens it; a second tap folds it again, and nothing is sculpted."""
    s = Script()
    select_page(s)
    s.ftap(*MASK_MORE)
    s.wait(20)
    s.ftap(*MASK_MORE)
    s.wait(20)
    return s, [], camera_still({"dabs": near(0), "more": is_text("none"), "object_page": is_text("Select")})


@scenario
def more_options_show_the_rest():
    """With everything masked, a finger tap on the Mask section's More options opens it and leaves it open, the mask untouched."""
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(4)
    select_page(s)
    s.ftap(*MASK_MORE)
    s.wait(20)
    return s, [], camera_still({"dabs": near(0), "more": is_text("mask"), "masked": near(1)})


@scenario
def show_every_option_needs_no_fold():
    """With Show every option on, the Mask section has no More row: a tap where it would be leaves every fold shut."""
    with open(settings_file(), "w") as f:
        f.write("all_options 1\n")
    s = Script()
    select_page(s)
    s.ftap(*MASK_MORE)
    s.wait(10)
    return s, [f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "more": is_text("none"), "all_options": near(1)})


# The first-run tip's Skip tips button at 1600 x 900 (the card sits under the tool bar).
COACH_SKIP = (960, 106)


@scenario
def coach_tips_go_as_they_are_done():
    """With the first-run tips on, a finger stroke on the model, a finger drag on empty space and a two-finger pinch each do a tip, and the card goes."""
    s = Script()
    s.wait(4)
    s.fdrag(line((760, 430), (860, 470), 16))
    s.wait(6)
    s.fdrag(line(EMPTY, (EMPTY[0] + 120, EMPTY[1] + 40), 12))
    s.wait(6)
    s.fingers([(300, 600), (400, 600)], [(-60, 0), (60, 0)], 12)
    s.wait(6)
    return s, ["--coach"], {"coach": near(7), "coach_step": is_text("none"), "layout_coach": lambda v: v == "0,0,0,0"}


@scenario
def coach_tip_waits_for_its_turn():
    """A mouse drag on empty space turns the view before anything is sculpted: the turn tip counts, and the card still shows the first tip, to sculpt."""
    s = Script()
    s.wait(4)
    s.mouse_drag(line(EMPTY, (EMPTY[0] + 100, EMPTY[1]), 10))
    s.wait(6)
    return s, ["--coach"], {"coach": near(2), "coach_step": is_text("draw"), "dabs": near(0)}


@scenario
def coach_two_finger_tap_is_not_a_move():
    """A two-finger tap (undo) moves the fingers a little but is no pan or pinch: no tip counts."""
    s = Script()
    s.wait(4)
    s.fingers([(300, 600), (400, 600)], [(2, 1), (-1, 2)], 3)
    s.wait(8)
    return s, ["--coach"], {"coach": near(0), "coach_step": is_text("draw")}


@scenario
def coach_skip_ends_the_tips():
    """A finger tap on Skip tips ends them at once, sculpting nothing."""
    s = Script()
    s.wait(10)
    s.ftap(*COACH_SKIP)
    s.wait(6)
    return s, ["--coach"], camera_still({"coach": near(7), "coach_step": is_text("none"), "dabs": near(0)})


@scenario
def coach_tips_come_back_from_the_palette():
    """After skipping, the palette's Show the first-run tips starts them again from the first."""
    s = Script()
    s.wait(10)
    s.ftap(*COACH_SKIP)
    s.wait(6)
    s.press("k", ("ctrl",))
    s.type("first-run tips")
    s.press("Return")
    s.wait(10)
    return s, ["--coach"], {"coach": near(0), "coach_step": is_text("draw"), "palette": near(0)}


@scenario
def coach_card_clears_the_bars_on_a_narrow_window():
    """At 820 x 640 the tip keeps clear of the tool bar, the inspector and the sliders."""
    s = Script()
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.wait(12)
    return s, ["--coach", "--width=820", "--height=640"], {"coach_step": is_text("draw"),
                                                         "@layout": clear_of("coach", "tools", "inspector", "sliders", "top_right")}


PRESET_HEAD = (1430, 269)  # the Brush tab's Preset section, folded at first
PRESET_SAVE_NEW = (1357, 372)  # its Save as preset, on a plain brush
PRESET_NAME = (1430, 372)  # on a preset: its name field
PRESET_REVERT = (1505, 424)


def save_a_preset(s):
    s.ftap(*PRESET_HEAD)
    s.wait(8)
    s.ftap(*PRESET_SAVE_NEW)
    s.wait(8)


@scenario
def preset_saves_changes_and_reverts():
    """Save as preset puts the brush on "Draw 1"; Shift+] marks it changed, and Revert puts its strength back."""
    s = Script()
    save_a_preset(s)
    s.press("]", ("shift",))
    s.wait(4)
    s.ftap(*PRESET_REVERT)
    s.wait(6)
    return s, [], {"presets": near(1), "preset": near(1), "preset_name": is_text("Draw_1"), "preset_changed": near(0),
                   "brush_strength": near(0.5), "dabs": near(0)}


@scenario
def preset_renames_as_typed():
    """A tap on the preset's name field, typing and Enter rename it."""
    s = Script()
    save_a_preset(s)
    s.ftap(*PRESET_NAME)
    s.wait(4)
    s.type(" soft")
    s.press("Return")
    s.wait(6)
    return s, [], {"preset_name": is_text("Draw_1_soft"), "dabs": near(0)}


@scenario
def preset_left_gives_the_plain_brush_back():
    """A strength change on the preset stays with it: tapping Draw in the dock takes the brush off it, back to the plain Draw's 0.5."""
    s = Script()
    save_a_preset(s)
    s.press("]", ("shift",))
    s.wait(4)
    s.ftap(*UI["dock_draw"])
    s.wait(6)
    return s, [], {"preset": near(0), "presets": near(1), "brush_strength": near(0.5), "dabs": near(0)}


@scenario
def presets_come_back_from_settings():
    """A settings file's presets load, with the brush back on the one it names; closing writes them again."""
    s = Script()
    with open(settings_file(), "w") as f:
        f.write("brush Clay\nstrength Clay 0.7\n"
                "preset Soft%20clay Clay 0.2 0 0 0 0 0 - Stroke 0 Dots 12 0 0 0 Drag\nbrush_preset Soft%20clay\n")
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.wait(10)
    return s, [f"--settings-file={settings_file()}"], {"presets": near(1), "preset": near(1), "preset_name": is_text("Soft_clay"),
                                                       "brush_strength": near(0.2), "preset_changed": near(0)}


def new_scene_settings():
    """A settings file whose Add size is 500k, so a starter comes with three levels (16k base)."""
    with open(settings_file(), "w") as f:
        f.write("new_vertices 500000\n")
    return f"--settings-file={settings_file()}"


@scenario
def new_scene_starts_over_at_once():
    """On an untouched scene, Menu > New scene > Head replaces the sphere with a head at once: three levels, no undo step, the menu closed."""
    s = Script()
    s.ftap(*UI["menu"])
    s.wait(10)
    s.ftap(*UI["new_head"])
    s.wait(10)
    return s, [new_scene_settings()], {"objects": near(1), "selected_levels": near(3), "selected_name": is_text("Head_2"),
                                       "undo_steps": near(0), "menu": near(0), "dabs": near(0), **{k: near(v) for k, v in CAMERA0.items()}}


@scenario
def new_scene_after_a_stroke_asks_first():
    """After a stroke, one tap on Head only arms it: the sphere and its stroke stay and the menu stays open for the second tap."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    s.wait(4)
    s.ftap(*UI["menu"])
    s.wait(10)
    s.ftap(*UI["new_head"])
    s.wait(10)
    return s, [new_scene_settings()], {"objects": near(1), "selected_levels": near(1), "selected_name": is_text("Sphere_1"),
                                       "undo_steps": near(1), "new_armed": near(2), "menu": near(1)}


@scenario
def new_scene_second_tap_discards():
    """After a stroke, a second tap on Hand goes ahead: one hand, its levels, and an empty History."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    s.wait(4)
    s.ftap(*UI["menu"])
    s.wait(10)
    s.ftap(*UI["new_hand"])
    s.wait(6)
    s.ftap(*UI["new_hand"])
    s.wait(10)
    return s, [new_scene_settings()], {"objects": near(1), "selected_levels": near(3), "selected_name": is_text("Hand_2"),
                                       "undo_steps": near(0), "redo_steps": near(0), "new_armed": near(0), "menu": near(0)}


@scenario
def new_scene_from_the_palette():
    """The palette's New scene: Figure starts over too, as the menu does."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("new scene figure")
    s.press("Return")
    s.wait(10)
    return s, [new_scene_settings()], {"objects": near(1), "selected_levels": near(3), "selected_name": is_text("Figure_2"), "palette": near(0)}


@scenario
def object_pages_switch_and_stay():
    """A finger taps the Object tab, then its Build page; the Brush tab and back keep Build, and nothing is sculpted."""
    s = Script()
    s.ftap(*UI["tab_object"])
    s.wait(6)
    s.ftap(*UI["page_build"])
    s.wait(6)
    s.ftap(*UI["tab_brush"])
    s.wait(6)
    s.ftap(*UI["tab_object"])
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "inspector_tab": is_text("object"), "object_page": is_text("Build")})


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


def clear_of(name, *others):
    """A check that `name` (a layout name) is shown and meets none of `others`."""
    def ok(stats):
        r = stats[f"layout_{name}"]
        return float(r.split(",")[2]) > 0 and not any(overlap(r, stats[f"layout_{o}"]) for o in others)
    return ok


def rail_clear(*others):
    """A check that the rail is shown and meets none of `others` (layout names)."""
    return clear_of("modifier_rail", *others)


# The action bar's buttons at 1600 x 900: Invert in the Mask group alone, Show all in the
# Hidden group alone, on an 820 x 640 window the folded Mask button and the first row of
# its popover, and on a 1400 x 900 window with Settings open the folded Mask button.
BAR_MASK_INVERT = (595, 786)
BAR_SHOW_ALL = (788, 786)
BAR_NARROW_MASK = (357, 526)
BAR_NARROW_FIRST = (354, 164)
BAR_SETTINGS_MASK = (700, 786)


@scenario
def action_bar_finger_inverts_the_mask():
    """Ctrl+I masks everything and the bar offers the mask's next steps; a finger tap on its Invert empties the mask and the bar goes."""
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(8)
    s.ftap(*BAR_MASK_INVERT)
    s.wait(8)
    return s, [], camera_still({"masked": near(0), "action_bar": is_text("none"), "dabs": near(0), "undo_steps": near(2)})


@scenario
def action_bar_finger_shows_all():
    """With half the sphere hidden the bar offers Show all; a finger tap on it shows everything and the bar goes."""
    s = Script()
    s.wait(8)
    s.ftap(*BAR_SHOW_ALL)
    s.wait(8)
    # Nothing hidden is left: the exit's hide line (only printed for hidden triangles) is
    # gone, and with no mask either the bar has nothing to show.
    return s, ["--hide=x"], camera_still({"action_bar": is_text("none"), "dabs": near(0),
                                          "@shown": lambda stats: "hidden_triangles" not in stats})


@scenario
def action_bar_folds_on_a_narrow_window():
    """At 820 x 640 the groups fold to one button each; Mask opens its actions above it and the first, Invert, empties the mask."""
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(8)
    s.ftap(*BAR_NARROW_MASK)
    s.wait(12)
    s.ftap(*BAR_NARROW_FIRST)
    s.wait(8)
    return s, ["--width=820", "--height=640", "--hide=x"], camera_still({"masked": near(0), "action_pop": near(0),
                                                                         "action_bar": is_text("hidden"), "dabs": near(0)})


@scenario
def action_bar_escape_closes_its_popover():
    """With Settings open on a 1400 point window the bar folds; Escape closes Mask's popover first, and leaves Settings open."""
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(8)
    s.press("k", ("ctrl",))
    s.type("touch")
    s.press("Return")
    s.wait(12)
    s.ftap(*BAR_SETTINGS_MASK)
    s.wait(12)
    s.press("Escape")
    s.wait(4)
    return s, ["--width=1400", "--height=900"], {"action_pop": near(0), "masked": near(1), "action_bar": is_text("mask"),
                                                 "settings_open": near(1)}


@scenario
def action_bar_popover_goes_with_its_group():
    """An undo that takes the mask away while its popover is open closes the popover, and the bar folds to Hidden alone."""
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(8)
    s.ftap(*BAR_NARROW_MASK)
    s.wait(12)
    s.press("z", ("ctrl",))
    s.wait(8)
    return s, ["--width=820", "--height=640", "--hide=x"], camera_still({"action_pop": near(0), "masked": near(0),
                                                                         "action_bar": is_text("hidden"), "dabs": near(0)})


@scenario
def action_bar_clears_the_sliders_without_the_rail():
    """With the modifier buttons off on a short window, the bar keeps clear of the tall sliders as of the dock and the panels."""
    with open(settings_file(), "w") as f:
        f.write("modifier_rail Off\n")
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(12)
    return s, ["--width=760", "--height=600", f"--settings-file={settings_file()}"], {
        "action_bar": is_text("mask"), "@layout": clear_of("action_bar", "sliders", "inspector", "dock", "status")}


@scenario
def action_bar_clears_the_panels_on_a_narrow_window():
    """At 820 x 640 with a mask and hidden parts, the bar meets neither the inspector, the dock, the object's status, the rail nor the sliders."""
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(12)
    return s, ["--width=820", "--height=640", "--hide=x"], {"action_bar": is_text("mask+hidden"),
                                                          "@layout": clear_of("action_bar", "inspector", "dock", "status", "modifier_rail", "sliders")}


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
    """Mask latched: a finger dragged from empty space draws a mask rectangle over the model instead of turning the view
    (a finger's shape waits for Apply: Enter here)."""
    s = Script()
    rail_tap(s, "mask")
    s.fdrag(line((250, 150), (900, 600), 20))
    s.wait(4)
    s.press("Return")
    return s, [], camera_still({"dabs": near(0), "masked": near(1), "undo_steps": near(1), "rail_latched": lambda v: v == "mask"})


@scenario
def rail_hide_gesture():
    """Hide latched: a finger drags the hide rectangle over part of the model, and once applied (Enter) the rest is hidden."""
    s = Script()
    rail_tap(s, "hide")
    s.fdrag(line((250, 150), (800, 450), 20))
    s.wait(4)
    s.press("Return")
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
FOCUS_BUTTON, FRAME_ALL_BUTTON = (1358, 328), (1506, 328)  # the Move tool's tab, above the gizmo's settings
SCENE_TAB, SCENE_ROW = (1526, 152), (1430, 232)


@scenario
def long_press_a_button_shows_its_shortcut_and_gesture():
    """A long press on the Move tool's Frame all shows its tooltip, which has no shortcut but names its double tap, and does not frame."""
    s = Script()
    s.press("w")
    s.wait(4)
    long_press(s, *FRAME_ALL_BUTTON)
    return s, [], {"long_tip": is_text("Frame_all"), "long_tip_keys": is_text("Double_tap_empty_space,_nothing_selected"), "tool": is_text("move"), "framed": near(0)}


@scenario
def long_press_focus_shows_f_and_double_tap():
    """Focus selected's tooltip, by a long press, shows F and the double tap on empty space."""
    s = Script()
    s.press("w")
    s.wait(4)
    long_press(s, *FOCUS_BUTTON)
    return s, [], {"long_tip": is_text("Focus_selected"), "long_tip_keys": is_text("F_·_Double_tap_empty_space")}


@scenario
def gesture_hints_follow_the_settings():
    """With Double tap to frame or pin off in Settings, Focus selected's tooltip shows only F."""
    s = Script()
    write_settings("double_tap 0\n")
    s.press("w")
    s.wait(4)
    long_press(s, *FOCUS_BUTTON)
    return s, [f"--settings-file={settings_file()}"], {"long_tip_keys": is_text("F")}


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
def long_press_dock_tile_opens_its_slot_menu():
    """A long press on Smooth in the dock opens its slot menu; Brush settings there picks Smooth and turns the inspector to its settings, from the Object tab."""
    s = Script()
    s.ftap(*UI["tab_object"])
    s.wait(6)
    long_press(s, *UI["dock_smooth"])
    s.wait(10)
    s.ftap(*SLOT_SETTINGS)
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "brush_kind": lambda v: v == "smooth", "inspector_tab": lambda v: v == "tool",
                                "window_inspector": lambda v: v.startswith("1,0,"), "dock_menu": near(0)})


DEFAULT_DOCK = "Draw,Smooth,Clay,Flatten,Inflate,Grab,Mask"
# The slot menu over the dock's Smooth, and the brush browser, at 1600 by 900 with no
# preset or one: Brush settings, Pinch, the first preset and Reset dock in the menu; the
# first preset in the browser.
SLOT_SETTINGS, SLOT_PINCH, SLOT_PRESET, SLOT_RESET = (558, 476), (511, 583), (511, 735), (548, 786)
BROWSER_PRESET = (900, 780)


def one_preset_settings(extra=""):
    """A settings file with one preset, Soft clay, and `extra` lines."""
    with open(settings_file(), "w") as f:
        f.write("preset Soft%20clay Clay 0.2 0 0 0 0 0 - Stroke 0 Dots 0 0 0 0 Drag\n" + extra)
    return f"--settings-file={settings_file()}"


@scenario
def dock_slot_takes_a_brush():
    """Long press Smooth in the dock, tap Pinch in its slot menu: the slot holds Pinch, and a tap on it picks Pinch."""
    s = Script()
    long_press(s, *UI["dock_smooth"])
    s.wait(10)
    s.ftap(*SLOT_PINCH)
    s.wait(8)
    s.ftap(*UI["dock_smooth"])
    s.wait(4)
    return s, [one_preset_settings()], camera_still({"dabs": near(0), "dock": is_text("Draw,Pinch,Clay,Flatten,Inflate,Grab,Mask"),
                                                     "brush_kind": is_text("pinch"), "dock_menu": near(0), "preset": near(0)})


@scenario
def dock_slot_takes_a_preset():
    """Long press Smooth in the dock, tap the Soft clay preset in its slot menu, then tap the slot: the brush is on the preset."""
    s = Script()
    long_press(s, *UI["dock_smooth"])
    s.wait(10)
    s.ftap(*SLOT_PRESET)
    s.wait(8)
    s.ftap(*UI["dock_smooth"])
    s.wait(4)
    return s, [one_preset_settings()], camera_still({"dabs": near(0), "dock": is_text("Draw,Soft_clay,Clay,Flatten,Inflate,Grab,Mask"),
                                                     "preset": near(1), "brush_kind": is_text("clay"), "brush_strength": near(0.2)})


@scenario
def dock_reset_puts_the_brushes_back():
    """A settings file's dock (Cloth first, Soft clay last) loads; Reset dock in a slot menu puts a fresh install's back."""
    s = Script()
    long_press(s, *UI["dock_smooth"])
    s.wait(10)
    s.ftap(*SLOT_RESET)
    s.wait(6)
    return s, [one_preset_settings("dock 0 brush Cloth\ndock 6 preset Soft%20clay\n")], camera_still({"dabs": near(0), "dock": is_text(DEFAULT_DOCK), "dock_menu": near(0)})


@scenario
def dock_comes_back_from_settings():
    """A settings file's dock loads: Snake hook first, the Soft clay preset last, a slot naming a missing preset unchanged."""
    s = Script()
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.wait(10)
    extra = "dock 0 brush Snake_Hook\ndock 6 preset Soft%20clay\ndock 2 preset Missing\n"
    return s, [one_preset_settings(extra)], {"dock": is_text("Snake_hook,Smooth,Clay,Flatten,Inflate,Grab,Soft_clay")}


@scenario
def browser_picks_a_preset():
    """The brush browser lists the presets under the brushes; a tap on Soft clay puts the brush on it and closes the browser."""
    s = Script()
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(*BROWSER_PRESET)
    s.wait(6)
    return s, [one_preset_settings()], camera_still({"dabs": near(0), "preset": near(1), "preset_name": is_text("Soft_clay"), "browser": near(0)})


# The Assign key popover under the inspector button, at 1600 by 900: Use it here and Keep
# it there on a conflict; the palette's Star, Put in a pie and Assign key with "wire"
# typed (two rows), and its first row with nothing typed under the STARRED caption.
BIND_USE_HERE, BIND_KEEP = (1345, 201), (1506, 201)
PALETTE_STAR, PALETTE_PIE, PALETTE_ASSIGN = (1145, 319), (1281, 319), (1419, 319)
PALETTE_FIRST_STARRED = (1148, 170)
# The pie editor opened from the palette: Pie 1's first slot and Pie 3's.
EDITOR_PIE1_FIRST, EDITOR_PIE3_FIRST = (1104, 182), (1104, 350)
# A user pie opened with its key over the middle of the window: its right slice (slot 3).
PIE_MIDDLE, PIE_RIGHT = (800, 450), (900, 450)


def bind_inspector(s):
    """Ctrl+Alt+click on the inspector button: the Assign key popover for Inspector."""
    s.add("key:ctrl")
    s.add("key:alt")
    s.add(f"move:{INSPECTOR_BUTTON[0]},{INSPECTOR_BUTTON[1]}")
    s.wait(2)
    s.add("down")
    s.wait(1)
    s.add("up")
    s.wait(1)
    s.add("keyup:alt")
    s.add("keyup:ctrl")
    s.wait(10)


@scenario
def bind_ctrl_alt_click_gives_a_key():
    """Ctrl+Alt+click on the inspector button opens Assign key without hiding the inspector; K is its key now, so after Escape K hides it and Tab does not."""
    s = Script()
    bind_inspector(s)
    s.press("k")
    s.press("Escape")
    s.press("Tab")
    s.press("k")
    s.wait(6)
    return s, [], camera_still({"key_overrides": near(1), "bind_open": near(0), "bind_command": is_text("Inspector"), "bind_state": is_text("assigned"),
                                "window_inspector": lambda v: v.startswith("0,")})


@scenario
def bind_conflict_moves_the_key():
    """Ctrl+Z pressed in Assign key for Inspector asks first (it runs Undo); Use it here moves it, so Ctrl+Z then hides the inspector."""
    s = Script()
    bind_inspector(s)
    s.press("z", mods=("ctrl",))
    s.wait(4)
    s.ftap(*BIND_USE_HERE)
    s.wait(4)
    s.press("Escape")
    s.press("z", mods=("ctrl",))
    s.wait(6)
    return s, [], camera_still({"key_overrides": near(1), "bind_state": is_text("assigned"), "window_inspector": lambda v: v.startswith("0,")})


@scenario
def bind_conflict_can_keep_the_key():
    """Keep it there leaves Ctrl+Z with Undo and listens again."""
    s = Script()
    bind_inspector(s)
    s.press("z", mods=("ctrl",))
    s.wait(4)
    s.ftap(*BIND_KEEP)
    s.wait(4)
    return s, [], camera_still({"key_overrides": near(0), "bind_open": near(1), "bind_state": is_text("listening")})


@scenario
def bind_refuses_space():
    """Space cannot be a command's key (it opens the brush pie): the popover says so and nothing changes."""
    s = Script()
    bind_inspector(s)
    s.press("Space")
    s.wait(4)
    return s, [], camera_still({"key_overrides": near(0), "bind_open": near(1), "bind_state": is_text("refused")})


@scenario
def bind_from_the_palette():
    """The palette's Assign key gives the picked command (Wireframe) a key, by touch."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(8)
    s.type("wire")
    s.wait(6)
    s.ftap(*PALETTE_ASSIGN)
    s.wait(10)
    s.press("k")
    s.wait(4)
    return s, [], camera_still({"key_overrides": near(1), "bind_open": near(1), "bind_command": is_text("Wireframe"), "bind_state": is_text("assigned")})


@scenario
def pie_key_opens_and_runs():
    """Q over the model opens Pie 1 there; a tap on its right slice runs Wireframe and closes it, and sculpts nothing."""
    s = Script()
    s.add(f"move:{PIE_MIDDLE[0]},{PIE_MIDDLE[1]}")
    s.wait(4)
    s.press("q")
    s.wait(4)
    s.ftap(*PIE_RIGHT)
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "pie_open": near(-1), "pie_runs": near(1), "wireframe": near(1)})


@scenario
def pie_escape_closes_only_the_pie():
    """With Help open, Shift+Q opens Pie 2 and Escape closes the pie alone: nothing runs and Help stays."""
    s = Script()
    s.add(f"move:{PIE_MIDDLE[0]},{PIE_MIDDLE[1]}")
    s.wait(4)
    s.press("F1")
    s.wait(10)
    s.add(f"move:{PIE_MIDDLE[0] - 200},{PIE_MIDDLE[1]}")
    s.wait(4)
    s.press("q", mods=("shift",))
    s.wait(4)
    s.press("Escape")
    s.wait(6)
    return s, [], camera_still({"pie_open": near(-1), "pie_runs": near(0), "help_open": near(1)})


@scenario
def pie_from_palette_stays_open():
    """Pie 1 run from the palette with one tap opens in the window's middle and stays open; a tap over the dock then picks the slice that way (Orthographic), not the dock's brush."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(8)
    s.type("pie 1")
    s.wait(6)
    s.ftap(1148, 146)
    s.wait(6)
    s.ftap(*UI["dock_smooth"])
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "pie_open": near(-1), "pie_runs": near(1), "ortho": near(1), "brush_kind": is_text("draw")})


@scenario
def pie_held_open_after_palette_tap():
    """A click on the palette whose press and release come in one frame (a slow frame) opens Pie 2 and picks nothing from it: the pie is still open after."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(8)
    s.type("pie 2")
    s.wait(6)
    s.add("move:1148,146")
    s.wait(2)
    s.add("down")
    s.add("up")
    s.wait(8)
    return s, [], camera_still({"pie_open": near(2), "pie_runs": near(0)})


@scenario
def star_puts_a_command_first():
    """The palette's Star on Wireframe; reopened with nothing typed, its first row is Wireframe, and a tap on it runs it."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(8)
    s.type("wire")
    s.wait(6)
    s.ftap(*PALETTE_STAR)
    s.wait(4)
    s.press("Escape")
    s.wait(6)
    s.ftap(*UI["search"])
    s.wait(8)
    s.ftap(*PALETTE_FIRST_STARRED)
    s.wait(6)
    return s, [], camera_still({"favourites": near(1), "wireframe": near(1), "palette": near(0)})


@scenario
def put_in_a_pie_from_palette():
    """Put in a pie on Wireframe opens the pie editor; a tap on Pie 3's first slot puts it there."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(8)
    s.type("wire")
    s.wait(6)
    s.ftap(*PALETTE_PIE)
    s.wait(8)
    s.ftap(*EDITOR_PIE3_FIRST)
    s.wait(6)
    return s, [], camera_still({"pie_editor": near(1), "pie3": lambda v: v.startswith("Wireframe,empty")})


@scenario
def pie_editor_long_press_empties():
    """A long press on Pie 1's first slot in the pie editor empties it."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(8)
    s.type("wire")
    s.wait(6)
    s.ftap(*PALETTE_PIE)
    s.wait(8)
    long_press(s, *EDITOR_PIE1_FIRST)
    s.wait(4)
    return s, [], camera_still({"pie_editor": near(1), "pie1": lambda v: v.startswith("empty,Frame_All")})


@scenario
def pies_come_back_from_settings():
    """A settings file's pie and favourite lines load; a damaged one is skipped."""
    s = Script()
    with open(settings_file(), "w") as f:
        f.write("pie 2 0 Wireframe\npie 2 1 Nothing\nfavourite Remesh\nfavourite Bogus\n")
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.wait(6)
    return s, [f"--settings-file={settings_file()}"], {"favourites": near(1), "pie3": lambda v: v.startswith("Wireframe,empty")}


# Settings > Keys at 1600 by 900: its search field, and the first row under the first
# caption (with "wire" typed, Wireframe; with nothing, New scene: Sphere).
KEYS_SEARCH, KEYS_FIRST_ROW = (1388, 497), (1388, 573)


def mouse_scheme_settings(scheme):
    with open(settings_file(), "w") as f:
        f.write(f"mouse_scheme {scheme}\n")
    return f"--settings-file={settings_file()}"


@scenario
def mouse_blender_middle_turns():
    """With the Blender mouse, a middle drag turns the view and pans nothing."""
    s = Script()
    s.mouse_drag(line((800, 450), (900, 450), 10), button="middle")
    return s, [mouse_scheme_settings("Blender")], {"camera_yaw": lambda v: abs(float(v) - CAMERA0["camera_yaw"]) > 0.05, "camera_target": lambda v: v == "0.0000,0.0000,0.0000"}


@scenario
def mouse_blender_shift_middle_pans():
    """With the Blender mouse, Shift + middle drag pans: the target moves and the view does not turn."""
    s = Script()
    s.mouse_drag(line((800, 450), (900, 450), 10), button="middle", keys=("shift",))
    return s, [mouse_scheme_settings("Blender")], {"camera_yaw": near(CAMERA0["camera_yaw"]), "camera_target": lambda v: v != "0.0000,0.0000,0.0000"}


@scenario
def mouse_zbrush_middle_pans():
    """With the ZBrush mouse (the default), a middle drag pans and does not turn."""
    s = Script()
    s.mouse_drag(line((800, 450), (900, 450), 10), button="middle")
    return s, [], {"camera_yaw": near(CAMERA0["camera_yaw"]), "camera_target": lambda v: v != "0.0000,0.0000,0.0000"}


@scenario
def mouse_maya_alt_right_zooms():
    """With the Maya mouse, Alt + right drag zooms rather than pans."""
    s = Script()
    s.mouse_drag(line((800, 450), (800, 350), 10), button="right", keys=("alt",))
    return s, [mouse_scheme_settings("Maya")], {"camera_distance": lambda v: abs(float(v) - CAMERA0["camera_distance"]) > 0.05, "camera_target": lambda v: v == "0.0000,0.0000,0.0000"}


@scenario
def keys_tab_row_assigns_a_key():
    """Settings > Keys: typing "wire" finds Wireframe, a tap on its row opens Assign key beside it, and K becomes its key."""
    s = Script()
    open_settings(s, "keys")
    s.ftap(*KEYS_SEARCH)
    s.wait(4)
    s.type("wire")
    s.wait(6)
    s.ftap(*KEYS_FIRST_ROW)
    s.wait(8)
    s.press("k")
    s.wait(4)
    return s, [], camera_still({"bind_open": near(1), "bind_command": is_text("Wireframe"), "bind_state": is_text("assigned"), "key_overrides": near(1), "settings_open": near(1)})


@scenario
def keys_search_escape_keeps_settings():
    """Escape in Settings > Keys' search field lets the field go and leaves Settings open."""
    s = Script()
    open_settings(s, "keys")
    s.ftap(*KEYS_SEARCH)
    s.wait(4)
    s.type("undo")
    s.wait(4)
    s.press("Escape")
    s.wait(6)
    return s, [], camera_still({"settings_open": near(1), "settings_tab": is_text("Keys")})


@scenario
def keys_popover_closes_when_its_row_scrolls_away():
    """Assign key opened from a row of Settings > Keys closes once the wheel scrolls that row out of view."""
    s = Script()
    open_settings(s, "keys")
    s.ftap(*KEYS_FIRST_ROW)
    s.wait(8)
    s.add("move:1388,650")
    s.wait(2)
    for _ in range(6):
        s.add("wheel:-5")
        s.wait(2)
    s.wait(20)
    return s, [], camera_still({"bind_open": near(0), "settings_open": near(1), "key_overrides": near(0)})


@scenario
def keys_come_back_from_settings():
    """A settings file's key lines load: K hides the inspector, Tab (moved away) does not."""
    s = Script()
    with open(settings_file(), "w") as f:
        f.write("key Inspector K\nkey Undo none\nkey Bogus Ctrl+Q\n")
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.wait(4)
    s.press("Tab")
    s.press("k")
    s.wait(6)
    return s, [f"--settings-file={settings_file()}"], {"key_overrides": near(2), "window_inspector": lambda v: v.startswith("0,")}


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


def is_text(want):
    return lambda v: v == want


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
    """A settings file from before the gesture map with the holds off (hold_history 0): a still hold undoes nothing."""
    s = Script()
    write_settings("hold_history 0\n")
    strokes(s, 2)
    hold(s, 2, 45)
    return s, [f"--settings-file={settings_file()}"], camera_still({"undo_steps": near(2), "touch_repeats": near(0)})


@scenario
def hold_mapped_runs_once():
    """With Hold two fingers set to Wireframe in the gesture map, a long still hold turns wireframe on once and undoes nothing."""
    s = Script()
    write_settings("gesture_map Two_Hold Wireframe\n")
    strokes(s, 2)
    hold(s, 2, 70)
    return s, [f"--settings-file={settings_file()}"], camera_still({"undo_steps": near(2), "touch_repeats": near(1), "wireframe": near(1)})


@scenario
def four_finger_tap_runs_its_command():
    """With Four-finger tap set to Wireframe, a four-finger tap on the viewport turns it on and undoes nothing."""
    s = Script()
    write_settings("gesture_map Four_Tap Wireframe\n")
    strokes(s, 1)
    s.fingers([(300 + 100 * i, 300) for i in range(4)], [(0, 0)] * 4, 1)
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], {"undo_steps": near(1), "wireframe": near(1)}


@scenario
def pen_button_opens_the_brush_pie():
    """The pen's side button over the model opens the brush pie by default."""
    s = Script()
    s.add("pnear")
    s.add("pmove:800,450")
    s.wait(4)
    s.add("pright")
    s.wait(6)
    return s, [], camera_still({"pie_open": near(0), "dabs": near(0)})


@scenario
def pen_button_runs_its_command():
    """With the pen's side button set to Pie 1 in the gesture map, it opens Pie 1 instead."""
    s = Script()
    write_settings("gesture_map Pen_Button Pie:1\n")
    s.add("pnear")
    s.add("pmove:800,450")
    s.wait(4)
    s.add("pright")
    s.wait(6)
    return s, [f"--settings-file={settings_file()}"], camera_still({"pie_open": near(1), "dabs": near(0)})


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


@scenario
def palette_ctrl_k_type_enter_runs_it():
    """Ctrl+K opens the command palette; "wire" and Enter turn the wireframe on and close it, and the W typed never picks the Move tool."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("wire")
    s.press("Return")
    return s, [], {"palette": near(0), "palette_runs": near(1), "palette_last": is_text("Wireframe"), "tool": is_text("brush")}


@scenario
def palette_letters_right_after_opening_stay_text():
    """A letter typed the very frame after / opens the palette, before its field is shown, never runs its shortcut (W, the Move tool) or S's size adjust."""
    s = Script()
    s.add("key:/")
    s.wait(1)
    s.add("keyup:/")
    s.add("move:800,450")
    s.type("ws")
    s.wait(2)
    return s, [], {"palette": near(1), "palette_runs": near(0), "tool": is_text("brush"), "brush_radius_px": near(60, 0.01)}


@scenario
def palette_slash_then_escape_closes_it():
    """/ opens the palette; Escape closes it having run nothing, and leaves Settings closed."""
    s = Script()
    s.press("/")
    s.type("rem")
    s.press("Escape")
    return s, [], {"palette": near(0), "palette_runs": near(0), "settings_open": near(0), "objects": near(1)}


@scenario
def palette_finds_other_apps_names():
    """Typing ZBrush's "dynamesh" finds Remesh first; Enter runs it."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("dynamesh")
    s.press("Return")
    s.wait(30)
    return s, [], {"palette_last": is_text("Remesh"), "palette_runs": near(1)}


@scenario
def palette_down_picks_the_second():
    """"smooth" lists Smooth all then Smooth brush; Down then Enter picks the brush."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("smooth")
    s.press("Down")
    s.press("Return")
    return s, [], {"palette_last": is_text("Brush:Smooth"), "brush_kind": is_text("smooth"), "dabs": near(0)}


@scenario
def palette_settings_tab_then_escape_closes_only_the_palette():
    """"touch" and Enter open Settings on its Touch tab; opened again, Escape closes the palette and leaves Settings open."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("touch")
    s.press("Return")
    s.press("k", ("ctrl",))
    s.wait(2)
    s.press("Escape")
    return s, [], {"palette": near(0), "settings_open": near(1), "settings_tab": is_text("Touch")}


@scenario
def palette_finger_taps_search_and_a_row():
    """A finger taps Search, types "wire" on the tablet keyboard and taps the first row: the wireframe goes on, and nothing is sculpted."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(4)
    s.type("wire")
    s.wait(4)
    s.ftap(*UI["palette_row1"])
    s.wait(4)
    return s, [], {"palette": near(0), "palette_last": is_text("Wireframe"), "dabs": near(0), "undo_steps": near(0)}


@scenario
def help_f1_opens_keys_in_the_inspectors_place():
    """F1 opens Help on its Keys tab, at the right, where the inspector hides while it is open."""
    s = Script()
    s.press("F1")
    s.wait(8)
    # A hidden inspector is never laid out, so its place reads 0,0.
    return s, [], camera_still({"help_open": near(1), "help_tab": is_text("Keys"), "dabs": near(0),
                                "window_help": lambda v: v.startswith("1,0,") and not v.endswith(",0,0"),
                                "window_inspector": lambda v: v == "0,0,0,0"})


@scenario
def help_escape_closes_it_and_brings_the_inspector_back():
    """Escape closes Help (opened from the palette on its Glossary tab, which it keeps), and the inspector comes back."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("glossary")
    s.press("Return")
    s.wait(8)
    s.press("Escape")
    s.wait(8)
    return s, [], {"help_open": near(0), "help_tab": is_text("Glossary"), "settings_open": near(0),
                   "window_inspector": lambda v: v.startswith("1,0,") and not v.endswith(",0,0")}


@scenario
def help_palette_glossary_opens_its_tab():
    """"glossary" and Enter in the palette open Help on its Glossary tab."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("glossary")
    s.press("Return")
    s.wait(8)
    return s, [], {"palette": near(0), "help_open": near(1), "help_tab": is_text("Glossary"),
                   "palette_last": is_text("Help:Glossary")}


@scenario
def help_finger_scrolls_its_body():
    """A finger dragged up Help's list scrolls it; the view and the model stay as they were."""
    s = Script()
    s.press("F1")
    s.wait(8)
    s.fdrag(line((1388, 700), (1392, 300), 20))
    s.wait(16)
    return s, [], camera_still({"help_open": near(1), "help_scroll": lambda v: float(v) > 100, "dabs": near(0)})


@scenario
def help_gives_its_place_to_settings():
    """Settings opened from the palette while Help (on its Glossary tab) is open takes its place: Help closes."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("glossary")
    s.press("Return")
    s.wait(8)
    s.press("k", ("ctrl",))
    s.type("touch")
    s.press("Return")
    s.wait(8)
    return s, [], {"help_open": near(0), "help_tab": is_text("Glossary"), "settings_open": near(1),
                   "settings_tab": is_text("Touch"), "window_help": lambda v: v == "0,0,0,0",
                   "window_inspector": lambda v: v == "0,0,0,0"}


@scenario
def settings_gives_its_place_to_help():
    """F1 while Settings is open opens Help in its place: Settings closes."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("touch")
    s.press("Return")
    s.wait(8)
    s.press("F1")
    s.wait(8)
    return s, [], {"help_open": near(1), "settings_open": near(0), "settings_tab": is_text("Touch"),
                   "window_settings": lambda v: v == "0,0,0,0"}


@scenario
def palette_disabled_row_does_nothing():
    """With no object left, Enter on Duplicate object runs nothing and keeps the palette open, typing."""
    s = Script()
    s.press("Delete")
    s.wait(4)
    s.press("k", ("ctrl",))
    s.type("duplicate")
    s.press("Return")
    s.type(" x")
    return s, [], {"objects": near(0), "palette": near(1), "palette_runs": near(0)}


@scenario
def palette_recents_come_first_and_are_remembered():
    """A remembered recent (Clay brush) leads the empty list: Enter at once picks it."""
    s = Script()
    write_settings("palette_recent Brush:Clay Wireframe Teleport\n")
    s.press("k", ("ctrl",))
    s.wait(2)
    s.press("Return")
    return s, [f"--settings-file={settings_file()}"], {"palette_last": is_text("Brush:Clay"), "brush_kind": is_text("clay")}


class Steps(list):
    """Several runs of the app for one scenario, in order, each (script, args, checks): a
    crash, then the start after it. A run given --crash-after-autosave must end with exit
    code 3, as the crash it stands for; the rest must exit cleanly."""


def autosave_folder():
    """The autosave folder of the scenario running on this thread, empty when it starts."""
    return os.path.join(ROOT, "build", "touch", "autosave", CURRENT.name)


def run(name, screens, displays=None):
    CURRENT.name = name
    os.makedirs(os.path.dirname(settings_file()), exist_ok=True)
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    shutil.rmtree(autosave_folder(), ignore_errors=True)
    result = SCENARIOS[name]()
    steps = result if isinstance(result, Steps) else [result]
    failures, stats = [], {}
    for i, step in enumerate(steps):
        # `screens` is the run to picture (from 1; 0 the last), or None for none.
        f, stats = run_one(name, step, screens is not None and i == (screens - 1 if screens > 0 else len(steps) - 1), displays)
        failures += [f"run {i + 1}: {x}" for x in f] if len(steps) > 1 else f
        if f:
            break
    return failures, stats


def run_one(name, step, screens, displays):
    script, args, checks = step
    frames = script.frame + 10
    # A run with no events, such as one that only waits for an autosave, leaves the flag out:
    # the app refuses an empty value.
    spec = script.spec()
    cmd = [EXE, f"--frames={frames}"] + ([f"--ui-events={spec}"] if spec else [])
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
        # The exit stats are UTF-8 (a tooltip's "·") on every OS, whatever its code page.
        # A virtual display busy with other scenarios now and then refuses a window ("x11
        # not available"); that is the machine, not the scenario, so the run is tried again
        # rather than reported as a failure. Nothing has run by then, so nothing repeats.
        for attempt in range(3):
            proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=600)
            if proc.returncode == 0 or "SDL_Init failed" not in proc.stderr:
                break
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
    want_exit = 3 if "--crash-after-autosave" in args else 0
    if proc.returncode != want_exit:
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


# Autosave and crash recovery (autosave.odin): an interval of a second and a short rest,
# in a folder of the scenario's own, so the runs are quick and touch nothing else.
CARD = {"recover": (653, 198), "not_now": (800, 198), "discard": (946, 198)}


def autosave_args(*more):
    return ["--autosave=1", "--autosave-rest=0.2", "--check-autosave", f"--autosave-folder={autosave_folder()}", *more]


def autosave_files(ext=".sculpt"):
    folder = autosave_folder()
    return sorted(f for f in os.listdir(folder) if f.endswith(ext)) if os.path.isdir(folder) else []


def stroke_then_rest(s, frames=150):
    s.mouse_drag([(800, 450), (830, 465), (860, 480)])
    s.wait(frames)
    return s


def click(s, at):
    s.add(f"move:{at[0]},{at[1]}")
    s.wait(1)
    s.add("down")
    s.wait(1)
    s.add("up")
    s.wait(4)


@scenario
def autosave_after_rest():
    """A stroke, then a rest: one autosave, read with nothing changing under it; the clean
    exit keeps it, and the next start asks nothing."""
    first = (stroke_then_rest(Script()), autosave_args(), {"autosaves": near(1, 0), "autosave_torn": near(0, 0), "@one file": lambda _: len(autosave_files()) == 1})
    s = Script()
    s.wait(5)
    return Steps([first, (s, autosave_args(), {"recover_offers": near(0, 0), "autosaves": near(0, 0)})])


@scenario
def autosave_stops_for_a_stroke():
    """A stroke as an autosave starts reading a bigger scene stops it within a piece; the
    next rest writes it after all."""
    s = Script()
    s.mouse_drag([(800, 450), (830, 465)])
    # The interval runs out at frame 60, the rest 12 frames after the stroke.
    s.wait(60 - s.frame + 1)
    s.mouse_drag([(700, 400), (730, 410)])
    s.wait(200)
    return s, autosave_args("--vertices=500000"), {"autosave_aborts": lambda v: int(v) >= 1, "autosaves": lambda v: int(v) >= 1, "autosave_torn": near(0, 0)}


def crash_after_stroke():
    return (stroke_then_rest(Script(), 120), autosave_args("--crash-after-autosave"), {"@an autosave": lambda _: len(autosave_files()) == 1})


@scenario
def autosave_crash_then_recover():
    """After a crash, the next start's card offers the autosave, and Recover brings back
    the stroke exactly: the mesh exported after it is the one a run that never crashed
    exports."""
    control = os.path.join(autosave_folder() + "-control.ply")
    recovered = os.path.join(autosave_folder() + "-recovered.ply")
    after = Script()
    after.wait(10)
    click(after, CARD["recover"])
    same = lambda _: open(control, "rb").read() == open(recovered, "rb").read()
    return Steps([
        (stroke_then_rest(Script(), 5), [f"--export={control}"], {}),
        crash_after_stroke(),
        (after, autosave_args(f"--export={recovered}"), {"recovered": near(1, 0), "recover_offers": near(0, 0), "@same mesh": same}),
    ])


@scenario
def autosave_crash_then_discard():
    """Discard deletes the crashed run's autosave, and nothing is offered again."""
    after = Script()
    after.wait(10)
    click(after, CARD["discard"])
    gone = lambda _: [f for f in autosave_files() if f.startswith(crashed[0])] == []
    crashed = []
    def remember(_):
        crashed.append(autosave_files()[0].rsplit("-", 1)[0])
        return True
    crash = crash_after_stroke()
    crash[2]["@remember"] = remember
    again = Script()
    again.wait(5)
    return Steps([crash, (after, autosave_args(), {"recover_offers": near(0, 0), "@gone": gone}),
                  (again, autosave_args(), {"recover_offers": near(0, 0)})])


@scenario
def autosave_not_now_asks_again():
    """Not now keeps the autosave, so the next start asks again."""
    after = Script()
    after.wait(10)
    click(after, CARD["not_now"])
    again = Script()
    again.wait(5)
    return Steps([crash_after_stroke(), (after, autosave_args(), {"recover_offers": near(1, 0), "recovered": near(0, 0)}),
                  (again, autosave_args(), {"recover_offers": near(1, 0)})])


@scenario
def autosave_off_writes_nothing():
    """With Settings > System > Autosave set to Off, a stroke and a rest write nothing, at
    exit neither."""
    write_settings("autosave_minutes 0\n")
    return stroke_then_rest(Script()), [f"--settings-file={settings_file()}", f"--autosave-folder={autosave_folder()}", "--autosave-rest=0.2"], {
        "autosaves": near(0, 0), "@no files": lambda _: autosave_files() == []}



# Saving and its earlier versions (versions.odin): Ctrl+S on an opened file saves over
# it without a dialog, so the versions folder beside it can be counted.
def scene_file():
    return autosave_folder() + "-scene/head.sculpt"


def versions_of(path):
    folder = os.path.join(os.path.dirname(path), os.path.splitext(os.path.basename(path))[0] + " versions")
    return sorted(f for f in os.listdir(folder) if f.endswith(".sculpt")) if os.path.isdir(folder) else []


def ctrl_s(s):
    s.add("key:ctrl")
    s.wait(1)
    s.add("key:s")
    s.wait(1)
    s.add("keyup:s")
    s.add("keyup:ctrl")
    s.wait(3)


def first_save():
    path = scene_file()
    shutil.rmtree(os.path.dirname(path), ignore_errors=True)
    os.makedirs(os.path.dirname(path))
    s = Script()
    s.wait(2)
    return s, [f"--save={path}"], {"@saved": lambda _: os.path.exists(path)}


@scenario
def save_over_a_file_keeps_the_earlier_one():
    """Ctrl+S twice over an opened file, a stroke before each: each save keeps the file it
    replaced, so two versions sit beside it, and the file itself is the last save."""
    path = scene_file()
    s = Script()
    s.wait(5)
    for at in ((800, 450), (700, 400)):
        s.mouse_drag([at, (at[0] + 30, at[1] + 15)])
        s.wait(3)
        ctrl_s(s)
    return Steps([first_save(), (s, [f"--open={path}"], {"@two versions": lambda _: len(versions_of(path)) == 2, "@no partial": lambda _: not os.path.exists(path + ".partial")})])


def two_earlier_saves(control):
    """The first save (a plain sphere, exported to `control`), then a run that strokes
    and saves twice: the file's two earlier saves are that sphere and the first stroke."""
    path = scene_file()
    first, args, checks = first_save()
    s = Script()
    s.wait(5)
    for at in ((800, 450), (700, 400)):
        s.mouse_drag([at, (at[0] + 30, at[1] + 15)])
        s.wait(3)
        ctrl_s(s)
    return [(first, args + [f"--export={control}"], checks), (s, [f"--open={path}"], {"@two versions": lambda _: len(versions_of(path)) == 2})]


def open_earlier_saves(s):
    click(s, UI["menu"])
    s.wait(4)
    click(s, UI["menu_earlier_saves"])
    s.wait(4)


@scenario
def earlier_saves_open_the_oldest():
    """Menu > Earlier saves lists the file's two earlier saves; a tap on the older one,
    with nothing unsaved, opens it: the mesh is the first save's, bit for bit."""
    control, opened = autosave_folder() + "-v0.ply", autosave_folder() + "-v1.ply"
    s = Script()
    s.wait(5)
    open_earlier_saves(s)
    click(s, UI["earlier_save2"])
    s.wait(5)
    same = lambda _: open(control, "rb").read() == open(opened, "rb").read()
    return Steps(two_earlier_saves(control) + [(s, [f"--open={scene_file()}", f"--export={opened}"], {"@the first save": same})])


@scenario
def earlier_saves_ask_before_discarding():
    """With a stroke the file does not hold, the first tap on an earlier save only asks
    (the row turns red), the scene stays; a second tap opens it."""
    control = autosave_folder() + "-v0.ply"
    kept, opened = autosave_folder() + "-kept.ply", autosave_folder() + "-opened.ply"
    def taps(n):
        s = Script()
        s.wait(5)
        s.mouse_drag([(800, 450), (830, 465)])
        s.wait(3)
        open_earlier_saves(s)
        for _ in range(n):
            click(s, UI["earlier_save2"])
            s.wait(3)
        s.wait(5)
        return s
    differs = lambda _: open(control, "rb").read() != open(kept, "rb").read()
    same = lambda _: open(control, "rb").read() == open(opened, "rb").read()
    return Steps(two_earlier_saves(control) + [
        (taps(1), [f"--open={scene_file()}", f"--export={kept}"], {"@still the stroke": differs}),
        (taps(2), [f"--open={scene_file()}", f"--export={opened}"], {"@the first save": same}),
    ])


@scenario
def menu_scrolls_on_a_short_window():
    """On a 1280x720 window the menu is taller than the room under its button, so it
    scrolls instead of running off: the wheel brings Settings into reach, and a tap opens it."""
    s = Script()
    s.wait(3)
    click(s, UI["menu"])
    s.wait(4)
    s.add("move:120,400")
    s.add("wheel:-10")
    s.wait(1)
    s.add("wheel:-10")
    s.wait(20)
    click(s, (85, 600))
    s.wait(10)
    return s, ["--width=1280", "--height=720"], {"settings_open": near(1, 0)}


@scenario
def save_with_versions_off_keeps_none():
    """With Settings > System > Earlier saves set to Off, Ctrl+S saves over the file and
    keeps nothing beside it."""
    path = scene_file()
    write_settings("versions_kept 0\n")
    s = Script()
    s.wait(5)
    s.mouse_drag([(800, 450), (830, 465)])
    s.wait(3)
    ctrl_s(s)
    return Steps([first_save(), (s, [f"--open={path}", f"--settings-file={settings_file()}"], {"@none kept": lambda _: versions_of(path) == []})])


# Adjust last operation (adjust_last.odin): the bar's Adjust button with only the Remesh
# group showing, and the popover's controls, which sit at its foot just over the bar at
# 1600x900 whatever the lines above them say.
ADJUST_BUTTON = (826, 786)
ADJUST_SIZES = {"41k": (686, 722), "500k": (731, 722), "1M": (777, 722)}
ADJUST_AXES = {"X": (709, 680), "Y": (800, 680), "Z": (891, 680)}
ADJUST_STEPS_LEFT = (662, 664)  # the Steps slider's left end: 1 step
ADJUST_ONE_SLIDER = {"left": (662, 722), "middle": (800, 722)}  # Retopology's Quads, Extract's Thickness


def palette_run(s, words):
    """Ctrl+K, the words, Enter: runs the palette's first match."""
    s.press("k", ("ctrl",))
    s.type(words)
    s.press("Return")
    s.wait(5)


def same_file(a, b):
    return lambda _: open(a, "rb").read() == open(b, "rb").read()


@scenario
def adjust_remesh_from_the_bar():
    """Ctrl+R remeshes; the action bar offers Remesh / Adjust..., and picking 500k there
    remeshes again from the sphere, as one undo step: the mesh is a straight 500k remesh's,
    bit for bit."""
    direct, adjusted = autosave_folder() + "-direct.ply", autosave_folder() + "-adjusted.ply"
    s = Script()
    s.wait(3)
    s.press("r", ("ctrl",))
    s.wait(5)
    click(s, ADJUST_BUTTON)
    s.wait(5)
    click(s, ADJUST_SIZES["500k"])
    s.wait(5)
    return Steps([
        (Script(), ["--remesh=500000", f"--export={direct}"], {}),
        (s, [f"--export={adjusted}"], {"adjust_op": is_text("remesh"), "adjusts": near(1, 0), "adjust_pop": near(1, 0),
                                       "undo_steps": near(1, 0), "redo_steps": near(0, 0), "@a straight remesh": same_file(direct, adjusted)}),
    ])


@scenario
def adjust_mirror_twice_is_not_stacked():
    """After a stroke and Mirror and weld across X, adjusting to Z and then to Y gives what
    adjusting straight to Y gives: each re-run starts from the stroke, not from the last
    mirror. The History holds the mirror alone, since a rebuild drops the strokes before it."""
    once, twice = autosave_folder() + "-once.ply", autosave_folder() + "-twice.ply"
    across_x = autosave_folder() + "-x.ply"
    def run(axes):
        s = Script()
        s.wait(3)
        s.mouse_drag(line((700, 380), (760, 420), 12))
        s.wait(3)
        palette_run(s, "mirror and weld")
        if axes:
            palette_run(s, "adjust last")
        for axis in axes:
            click(s, ADJUST_AXES[axis])
            s.wait(8)
        return s
    return Steps([
        (run([]), [f"--export={across_x}"], {"adjust_op": is_text("mirror")}),
        (run(["Y"]), [f"--export={once}"], {"adjusts": near(1, 0), "@not across X": lambda _: open(once, "rb").read() != open(across_x, "rb").read()}),
        (run(["Z", "Y"]), [f"--export={twice}"], {"adjust_op": is_text("mirror"), "adjusts": near(2, 0), "undo_steps": near(1, 0),
                                                "@as adjusting once": same_file(once, twice)}),
    ])


@scenario
def adjust_smooth_all_steps():
    """Smooth all, then Adjust last operation from the palette and a tap at the Steps
    slider's left end: let go, it smooths 1 step from the start, as --smooth-all=1 does."""
    direct, adjusted = autosave_folder() + "-direct.ply", autosave_folder() + "-adjusted.ply"
    s = Script()
    s.wait(3)
    palette_run(s, "smooth all")
    palette_run(s, "adjust last")
    click(s, ADJUST_STEPS_LEFT)
    s.wait(5)
    return Steps([
        (Script(), ["--smooth-all=1", f"--export={direct}"], {}),
        (s, [f"--export={adjusted}"], {"adjust_op": is_text("smooth_all"), "adjusts": near(1, 0), "undo_steps": near(1, 0),
                                       "@one step from the start": same_file(direct, adjusted)}),
    ])


@scenario
def adjust_decimate_refused_keeps_the_result():
    """Decimate a 500k sphere to 41k, then adjust it to 1M, more than the sphere has: the
    decimate refuses, so the 41k result comes back, still one step and still adjustable."""
    s = Script()
    s.wait(3)
    palette_run(s, "decimate to 41k")
    palette_run(s, "adjust last")
    click(s, ADJUST_SIZES["1M"])
    s.wait(5)
    return s, ["--vertices=500000"], {"adjust_op": is_text("decimate"), "adjusts": near(1, 0), "undo_steps": near(1, 0),
                                      "redo_steps": near(0, 0), "vertices": lambda v: int(v) < 60000}


@scenario
def adjust_ends_with_a_stroke():
    """A stroke after Ctrl+R is a newer step: the Adjust group goes from the bar and the
    palette's Adjust last operation is greyed."""
    s = Script()
    s.wait(3)
    s.press("r", ("ctrl",))
    s.wait(5)
    s.mouse_drag(line((700, 380), (760, 420), 8))
    s.wait(5)
    return s, [], {"adjust_op": is_text("none"), "action_bar": is_text("none"), "undo_steps": near(2, 0)}


@scenario
def adjust_remesh_keeps_to_the_state_before():
    """Adjusting a remesh made with dynamic topology on, on a lower subdivision level, or
    inside an HD window gives, bit for bit, what remeshing straight to that size from the
    same start gives: undoing the remesh brings back all of that state first."""
    steps = []
    for name, start in [("dyntopo", ["--dyntopo"]), ("level", ["--subdivide=1", "--level=1"]), ("hd", ["--hd=1", "--hd-open"])]:
        direct, adjusted = autosave_folder() + f"-{name}-direct.ply", autosave_folder() + f"-{name}-adjusted.ply"
        straight = Script()
        straight.wait(3)
        palette_run(straight, "remesh to 500k")
        s = Script()
        s.wait(3)
        s.press("r", ("ctrl",))
        s.wait(5)
        palette_run(s, "adjust last")
        click(s, ADJUST_SIZES["500k"])
        s.wait(5)
        steps += [(straight, start + [f"--export={direct}"], {}),
                  (s, start + [f"--export={adjusted}"], {"adjusts": near(1, 0), "undo_steps": near(1, 0), f"@{name}: a straight remesh": same_file(direct, adjusted)})]
    return Steps(steps)


@scenario
def adjust_retopo_and_extract():
    """Retopologize, then adjust Quads to the slider's left end (100): the quads are what
    --retopo=100 makes. Extract a masked patch, then adjust Thickness twice: still two
    objects and one Extract step, and the shell is what adjusting once makes."""
    direct, adjusted = autosave_folder() + "-retopo-direct.ply", autosave_folder() + "-retopo-adjusted.ply"
    retopo = Script()
    retopo.wait(3)
    palette_run(retopo, "retopologize")
    palette_run(retopo, "adjust last")
    click(retopo, ADJUST_ONE_SLIDER["left"])
    retopo.wait(5)
    once, twice = autosave_folder() + "-extract-once.ply", autosave_folder() + "-extract-twice.ply"
    def extract(at):
        s = Script()
        s.wait(3)
        s.press("9")
        s.mouse_drag(line((740, 380), (820, 420), 10))
        s.wait(3)
        palette_run(s, "extract masked")
        palette_run(s, "adjust last")
        for where in at:
            click(s, ADJUST_ONE_SLIDER[where])
            s.wait(5)
        return s
    return Steps([
        (Script(), ["--retopo=100", f"--export={direct}"], {}),
        (retopo, [f"--export={adjusted}"], {"adjust_op": is_text("retopology"), "adjusts": near(1, 0), "objects": near(2, 0),
                                           "@--retopo=100": same_file(direct, adjusted)}),
        (extract(["left"]), [f"--export={once}"], {"adjust_op": is_text("extract"), "objects": near(2, 0)}),
        (extract(["middle", "left"]), [f"--export={twice}"], {"adjusts": near(2, 0), "objects": near(2, 0), "undo_steps": near(2, 0),
                                                             "@as adjusting once": same_file(once, twice)}),
    ])


# Camera history (camera_history.odin): View menu rows at 1600x900.
VIEW_BACK, VIEW_FORWARD = (1400, 447), (1400, 491)
CAMERA_KEYS = ("camera_yaw", "camera_pitch", "camera_roll", "camera_distance", "camera_target")


def two_orbits(s):
    """Two orbit drags on empty space, each followed by a rest long enough to count as a view."""
    s.mouse_drag(line(EMPTY, (400, 200), 10))
    s.wait(40)
    s.mouse_drag(line(EMPTY, (250, 320), 10))
    s.wait(40)


@scenario
def camera_back_twice_is_the_start():
    """Two orbits, each left to rest, then Alt+Left twice: the view the app started with,
    and the History holds no step (the work is untouched)."""
    s = Script()
    s.wait(3)
    two_orbits(s)
    s.press("Left", ("alt",))
    s.press("Left", ("alt",))
    return s, [], camera_still({"camera_views": near(3, 0), "camera_view": near(1, 0), "camera_steps": near(2, 0), "undo_steps": near(0, 0)})


@scenario
def camera_back_and_forward_from_the_view_menu():
    """View > Previous view goes back one orbit and Next view comes forward again: the
    camera is where the two orbits alone leave it."""
    after = {}
    def remember(stats):
        after.update({k: stats[k] for k in CAMERA_KEYS})
        return True
    s = Script()
    s.wait(3)
    two_orbits(s)
    click(s, UI["view"])
    s.wait(5)
    click(s, VIEW_BACK)
    s.wait(5)
    click(s, VIEW_FORWARD)
    s.wait(5)
    orbits = Script()
    orbits.wait(3)
    two_orbits(orbits)
    return Steps([
        (orbits, [], {"@remember": remember}),
        (s, [], {"camera_steps": near(2, 0), "camera_view": near(3, 0),
                 "@as the orbits left it": lambda stats: all(stats[k] == after[k] for k in CAMERA_KEYS)}),
    ])


@scenario
def camera_back_keeps_an_unrested_view():
    """An orbit, then Alt+Left before it has rested: back at the start, and Alt+Right
    returns to the orbit, which going back kept first."""
    after = {}
    def remember(stats):
        after.update({k: stats[k] for k in CAMERA_KEYS})
        return True
    def orbit(s):
        s.wait(3)
        s.mouse_drag(line(EMPTY, (400, 200), 10))
        s.wait(2)
    back = Script()
    orbit(back)
    back.press("Left", ("alt",))
    forward = Script()
    orbit(forward)
    forward.press("Left", ("alt",))
    forward.press("Right", ("alt",))
    only = Script()
    orbit(only)
    return Steps([
        (back, [], camera_still({"camera_views": near(2, 0), "camera_view": near(1, 0)})),
        (only, [], {"@remember": remember}),
        (forward, [], {"camera_view": near(2, 0), "@the orbit": lambda stats: all(stats[k] == after[k] for k in CAMERA_KEYS)}),
    ])


# Two-phase shapes (shape_pending.odin): the mask rectangle a finger drags from (250,150)
# to (900,600) waits with its bar under it, Apply and Cancel at these points (1600x900).
SHAPE_FROM, SHAPE_TO = (250, 150), (900, 600)
SHAPE_APPLY, SHAPE_CANCEL = (484, 660), (672, 660)
SHAPE_MIDDLE, SHAPE_CORNER = (575, 375), (900, 600)


def finger_mask_shape(s):
    """Mask latched on the rail, then a finger drags the rectangle; it waits for Apply."""
    rail_tap(s, "mask")
    s.fdrag(line(SHAPE_FROM, SHAPE_TO, 20))
    s.wait(6)


@scenario
def shape_finger_waits_for_apply():
    """A finger's mask rectangle waits with Apply, Flip and Cancel under it and masks
    nothing yet; a tap on Apply masks, as one undo step; a tap on Cancel masks nothing."""
    waits, applied, cancelled = Script(), Script(), Script()
    for sc in (waits, applied, cancelled):
        finger_mask_shape(sc)
    applied.ftap(*SHAPE_APPLY)
    applied.wait(4)
    cancelled.ftap(*SHAPE_CANCEL)
    cancelled.wait(4)
    return Steps([
        (waits, [], camera_still({"shape_pending": is_text("mask"), "shape_points": near(2, 0), "masked": near(0), "undo_steps": near(0)})),
        (applied, [], camera_still({"shape_pending": is_text("none"), "masked": near(1), "undo_steps": near(1)})),
        (cancelled, [], camera_still({"shape_pending": is_text("none"), "masked": near(0), "undo_steps": near(0)})),
    ])


@scenario
def shape_mouse_applies_at_once():
    """Ctrl and a mouse drag from empty space masks as it lets go, as before; with
    --shape-apply=confirm it waits, and Enter applies it."""
    def drag(s):
        s.wait(3)
        s.mouse_drag(line(SHAPE_FROM, SHAPE_TO, 10), keys=("ctrl",))
        s.wait(4)
    now, waits, entered = Script(), Script(), Script()
    for sc in (now, waits, entered):
        drag(sc)
    entered.press("Return")
    return Steps([
        (now, [], camera_still({"shape_pending": is_text("none"), "masked": near(1)})),
        (waits, ["--shape-apply=confirm"], camera_still({"shape_pending": is_text("mask"), "masked": near(0)})),
        (entered, ["--shape-apply=confirm"], camera_still({"shape_pending": is_text("none"), "masked": near(1), "undo_steps": near(1)})),
    ])


@scenario
def shape_handles_move_and_resize():
    """The middle handle moves the waiting rectangle, a corner resizes it (the pen's too),
    and Apply masks where it is then: another mask than the rectangle where it was drawn."""
    drawn = {}
    def remember(stats):
        drawn["mask_mean"] = float(stats["mask_mean"])
        return True
    as_drawn, moved, corner = Script(), Script(), Script()
    for sc in (as_drawn, moved, corner):
        finger_mask_shape(sc)
    as_drawn.press("Return")
    moved.fdrag(past_slop(SHAPE_MIDDLE, (SHAPE_MIDDLE[0] + 200, SHAPE_MIDDLE[1]), 10))
    moved.wait(4)
    moved_box = Script()
    moved_box.events, moved_box.frame = list(moved.events), moved.frame
    moved.press("Return")
    pen_stroke(corner, line(SHAPE_CORNER, (SHAPE_CORNER[0] - 300, SHAPE_CORNER[1] - 200), 10))
    return Steps([
        (as_drawn, [], {"masked": near(1), "@remember": remember}),
        (moved_box, [], camera_still({"shape_pending": is_text("mask"), "shape_box": lambda v: v.split(",")[0] != "250" and v.split(",")[1] == "150"})),
        (moved, [], camera_still({"masked": near(1), "@another mask": lambda stats: abs(float(stats["mask_mean"]) - drawn["mask_mean"]) > 1e-3})),
        (corner, [], camera_still({"shape_pending": is_text("mask"), "dabs": near(0), "shape_box": lambda v: v.split(",")[2] != "900" and v.split(",")[0] == "250"})),
    ])


@scenario
def shape_view_turns_under_it():
    """With a shape waiting, a finger dragged inside it away from its handles turns the
    view and leaves the shape where it is; two fingers pinching from a handle zoom and
    leave it too."""
    turn, pinch = Script(), Script()
    for sc in (turn, pinch):
        finger_mask_shape(sc)
    rail_tap(turn, "mask")  # unlatched, so empty space turns the view again
    turn.fdrag(past_slop((330, 220), (430, 260), 10))
    pinch.fingers([SHAPE_CORNER, (700, 450)], [(60, 40), (-60, -40)], 12)
    box = lambda v: v == "250,150,900,600"
    return Steps([
        (turn, [], {"shape_pending": is_text("mask"), "shape_box": box, "camera_yaw": lambda v: abs(float(v) - CAMERA0["camera_yaw"]) > 0.01}),
        (pinch, [], {"shape_pending": is_text("mask"), "shape_box": box, "camera_distance": lambda v: abs(float(v) - CAMERA0["camera_distance"]) > 0.01}),
    ])


@scenario
def shape_escape_closes_menus_first():
    """With a shape waiting and the menu open, Escape closes the menu only; a second
    Escape lets the shape go."""
    once, twice = Script(), Script()
    for sc in (once, twice):
        finger_mask_shape(sc)
        click(sc, UI["menu"])
        sc.wait(4)
        sc.press("Escape")
    twice.press("Escape")
    return Steps([
        (once, [], {"menu": near(0), "shape_pending": is_text("mask")}),
        (twice, [], {"menu": near(0), "shape_pending": is_text("none"), "masked": near(0)}),
    ])


@scenario
def shape_clip_line_waits():
    """With Clip as the Ctrl+Shift gesture, a finger's line (Ctrl+Shift held on the
    keyboard here) waits; Enter clips, one undo step."""
    write_settings("gesture clip\n")
    s = Script()
    s.wait(3)
    s.add("key:ctrl")
    s.add("key:shift")
    s.fdrag(line((700, 120), (760, 780), 20))
    s.add("keyup:shift")
    s.add("keyup:ctrl")
    s.wait(4)
    waits = Script()
    waits.events, waits.frame = list(s.events), s.frame
    s.press("Return")
    s.wait(4)
    return Steps([
        (waits, [f"--settings-file={settings_file()}"], {"shape_pending": is_text("clip"), "undo_steps": near(0)}),
        (s, [f"--settings-file={settings_file()}"], {"shape_pending": is_text("none"), "undo_steps": near(1)}),
    ])


# Object > Shape > Rebuild (rebuild.odin). The sections above it are folded first, so the
# section sits at the same place whatever they hold.
REBUILD_FOLD = [(1430, 299), (1430, 345)]  # Transform, then Subdivision levels under it
REBUILD_HEADER = (1430, 483)
REBUILD_GOALS = {"even": (1338, 528), "fewer": (1431, 528), "quads": (1525, 528)}
REBUILD_DENSITY = (1460, 586)  # on the Density slider's track
REBUILD_APPLY = (1431, 688)


def open_rebuild(s, goal=None, tap=click):
    s.wait(3)
    tap(s, UI["tab_object"])
    s.wait(6)
    tap(s, UI["page_shape"])
    s.wait(6)
    for at in REBUILD_FOLD:
        tap(s, at)
        s.wait(10)
    tap(s, REBUILD_HEADER)
    s.wait(10)
    if goal:
        tap(s, REBUILD_GOALS[goal])
        s.wait(6)


def ftap_at(s, at):
    s.ftap(*at)


@scenario
def rebuild_density_shows_the_cells():
    """A finger held on Rebuild's Density slider shows the remesh's cells on the sphere;
    they stay a moment after it lifts, then go; the Fewer goal never shows them. The held
    run is last, so --screens shows the cells."""
    lifted, gone, fewer, held = Script(), Script(), Script(), Script()
    for sc, goal in ((lifted, "even"), (gone, "even"), (fewer, "fewer"), (held, "even")):
        open_rebuild(sc, goal, ftap_at)
        x, y = REBUILD_DENSITY
        sc.fdrag([(x, y), (x - 40, y), (x - 60, y)], lift=sc is not held)
        sc.wait(20)
    gone.wait(100)  # past REBUILD_PREVIEW_HOLD (1.5 s at 60 frames a second)
    return Steps([
        (lifted, [], camera_still({"rebuild_preview": near(1), "dabs": near(0)})),
        (gone, [], camera_still({"rebuild_preview": near(0), "dabs": near(0)})),
        (fewer, [], camera_still({"rebuild_goal": is_text("fewer"), "rebuild_preview": near(0)})),
        (held, [], camera_still({"rebuild_goal": is_text("even"), "rebuild_preview": near(1), "rebuild_cell": lambda v: float(v) > 0, "dabs": near(0)})),
    ])


@scenario
def rebuild_even_is_a_straight_remesh():
    """Rebuild > Even > Remesh at its 500k gives, bit for bit, the mesh --remesh=500000
    gives, as one undo step: the preview's lattice is the remesh's."""
    direct, panel = autosave_folder() + "-direct.ply", autosave_folder() + "-panel.ply"
    s = Script()
    open_rebuild(s, "even")
    click(s, REBUILD_APPLY)
    s.wait(10)
    return Steps([
        (Script(), ["--remesh=500000", f"--export={direct}"], {}),
        (s, [f"--export={panel}"], {"undo_steps": near(1), "adjust_op": is_text("remesh"), "@a straight remesh": same_file(direct, panel)}),
    ])


@scenario
def rebuild_fewer_and_quads():
    """Fewer decimates the 500k sphere to its 100k; Quads makes a new object of quads."""
    fewer, quads = Script(), Script()
    open_rebuild(fewer, "fewer")
    click(fewer, REBUILD_APPLY)
    fewer.wait(10)
    open_rebuild(quads, "quads")
    click(quads, REBUILD_APPLY)
    quads.wait(10)
    return Steps([
        (fewer, ["--vertices=500000"], {"adjust_op": is_text("decimate"), "vertices": near(100_000, 5_000), "undo_steps": near(1)}),
        (quads, [], {"adjust_op": is_text("retopology"), "objects": near(2)}),
    ])


# The Move tool's gizmo on the starting sphere, seen from the starting camera: its centre,
# the middle of its X arm, its XY plane square, the front of its Y ring and the action
# bar's chips.
GIZMO_CENTER = (800, 450)
GIZMO_X_ARM = (838, 458)
GIZMO_XY_SQUARE = (829, 423)
GIZMO_Y_RING = (800, 481)
GIZMO_CHIPS = {"move": (694, 786), "turn": (759, 786), "scale": (823, 786), "snap": (888, 786), "pivot": (951, 786)}


def transform_is(test):
    """The selected object's transform (x, y, z, turn x, y, z, scale) passes `test`."""
    return lambda v: test(*[float(x) for x in v.split(",")])


def gizmo_mode(s, presses):
    """The Move tool (W), then W again `presses` times: Turn, then Scale."""
    for _ in range(presses + 1):
        s.press("w")


def gizmo_where(checks):
    """`checks`, and the gizmo drawn where the GIZMO_ points assume: a change to the starting
    camera or scene fails here rather than as a drag that missed its handle."""
    return dict(checks, gizmo_at=is_text(f"{GIZMO_CENTER[0]},{GIZMO_CENTER[1]}"))


@scenario
def gizmo_ring_turns_about_its_axis():
    """W twice gives the Turn gizmo; dragging the Y ring with the mouse turns the sphere
    about y only, the readout's step recorded as one undo step that Ctrl+Z takes back."""
    turned, undone = Script(), Script()
    for sc in (turned, undone):
        gizmo_mode(sc, 1)
        sc.mouse_drag(line(GIZMO_Y_RING, (GIZMO_Y_RING[0] + 60, GIZMO_Y_RING[1]), 6))
    undone.press("z", ("ctrl",))
    about_y = transform_is(lambda x, y, z, rx, ry, rz, sc: abs(ry) > 5 and abs(rx) < 0.01 and abs(rz) < 0.01 and (x, y, z, sc) == (0, 0, 0, 1))
    return Steps([
        (turned, [], camera_still(gizmo_where({"gizmo_mode": is_text("turn"), "gizmo_last": is_text("turn_y"), "gizmo_drags": near(1), "transform": about_y, "transform_undo": near(1), "undo_steps": near(1)}))),
        (undone, [], camera_still({"transform": is_text("0.0000,0.0000,0.0000,0.000,0.000,0.000,1.0000"), "transform_undo": near(0), "redo_steps": near(1)})),
    ])


@scenario
def gizmo_finger_scales_from_the_middle():
    """A finger on the Scale gizmo's middle scales the sphere up as it drags out, past the
    slop only, so the camera stays and nothing else moves."""
    s = Script()
    gizmo_mode(s, 2)
    s.fdrag(line((GIZMO_CENTER[0] + 4, GIZMO_CENTER[1]), (GIZMO_CENTER[0] + 94, GIZMO_CENTER[1]), 9))
    s.wait(4)
    grew = transform_is(lambda x, y, z, rx, ry, rz, sc: 1.5 < sc < 3 and (x, y, z, rx, ry, rz) == (0, 0, 0, 0, 0, 0))
    return s, [], camera_still({"gizmo_mode": is_text("scale"), "gizmo_last": is_text("scale"), "transform": grew, "dabs": near(0)})


@scenario
def gizmo_finger_sized_handles():
    """A finger lands 16 points below the X arm, where the mouse would miss it, and still
    drags along x only; a tap on the arm, within the slop, moves nothing."""
    near_arm, tap = Script(), Script()
    start = (GIZMO_X_ARM[0], GIZMO_X_ARM[1] + 16)
    gizmo_mode(near_arm, 0)
    near_arm.fdrag(line(start, (start[0] + 50, start[1] + 10), 8))
    gizmo_mode(tap, 0)
    tap.fdrag([GIZMO_X_ARM, (GIZMO_X_ARM[0] + 4, GIZMO_X_ARM[1] + 2)])
    along_x = transform_is(lambda x, y, z, rx, ry, rz, sc: x > 0.05 and (y, z, sc) == (0, 0, 1))
    return Steps([
        (near_arm, [], camera_still({"gizmo_last": is_text("x"), "transform": along_x, "undo_steps": near(1)})),
        (tap, [], camera_still(gizmo_where({"transform": is_text("0.0000,0.0000,0.0000,0.000,0.000,0.000,1.0000"), "undo_steps": near(0), "selected": near(0)}))),
    ])


@scenario
def gizmo_square_moves_in_its_plane():
    """The square between the X and Y arms moves the sphere in x and y; z stays."""
    s = Script()
    gizmo_mode(s, 0)
    s.mouse_drag(line(GIZMO_XY_SQUARE, (GIZMO_XY_SQUARE[0] + 40, GIZMO_XY_SQUARE[1] - 30), 6))
    in_plane = transform_is(lambda x, y, z, rx, ry, rz, sc: abs(x) > 0.05 and abs(y) > 0.05 and z == 0 and sc == 1)
    return s, [], camera_still({"gizmo_last": is_text("xy"), "transform": in_plane, "transform_undo": near(1)})


@scenario
def gizmo_ctrl_snaps_the_move():
    """Ctrl held through an X arm drag moves the sphere along x in whole steps of the grid;
    the same drag without it lands between them."""
    snapped, free = Script(), Script()
    for sc, keys in ((snapped, ("ctrl",)), (free, ())):
        gizmo_mode(sc, 0)
        sc.mouse_drag(line(GIZMO_X_ARM, (GIZMO_X_ARM[0] + 43, GIZMO_X_ARM[1] + 8), 6), keys=keys)

    # At the starting zoom the grid's step is 0.1: the free drag ends near 0.125.
    def on_grid(x, y, z, rx, ry, rz, sc):
        return x > 0.05 and abs(x * 10 - round(x * 10)) < 1e-3 and (y, z) == (0, 0)
    return Steps([
        (snapped, [], camera_still({"gizmo_last": is_text("x"), "transform": transform_is(on_grid)})),
        (free, [], camera_still({"gizmo_last": is_text("x"), "transform": transform_is(lambda *t: not on_grid(*t) and t[0] > 0.05)})),
    ])


@scenario
def gizmo_chips_switch_the_mode():
    """With the Move tool on, the action bar shows the gizmo's chips: Turn and Scale pick
    the mode, Snap latches."""
    turn, scale = Script(), Script()
    for sc, chip in ((turn, "turn"), (scale, "scale")):
        sc.press("w")
        click(sc, GIZMO_CHIPS[chip])
        click(sc, GIZMO_CHIPS["snap"])
    return Steps([
        (turn, [], camera_still({"action_bar": is_text("gizmo"), "gizmo_mode": is_text("turn"), "gizmo_snap": near(1)})),
        (scale, [], camera_still({"gizmo_mode": is_text("scale"), "gizmo_snap": near(1)})),
    ])


@scenario
def transform_values_undo_per_drag():
    """In the Object tab, a drag of Position X is one undo step however many frames it
    took, and Reset transform (with every option shown) one more; Ctrl+Z takes back
    the reset alone."""
    s = Script()
    write_settings("all_options 1\n")
    click(s, UI["tab_object"])
    s.mouse_drag(line((1431, 350), (1531, 350), 10))
    click(s, (1431, 794))
    s.press("z", ("ctrl",))
    dragged = transform_is(lambda x, y, z, rx, ry, rz, sc: abs(x - 0.5) < 0.02 and (y, z, sc) == (0, 0, 1))
    return s, [f"--settings-file={settings_file()}"], camera_still({"inspector_tab": is_text("object"), "transform": dragged, "undo_steps": near(1), "redo_steps": near(1), "transform_undo": near(1)})


def type_value(s, text):
    """Types `text` into the field that has the keys and presses Enter."""
    s.wait(2)
    s.type(text)
    s.press("Return")


@scenario
def gizmo_tap_types_a_value():
    """A click on the X arm that moves nothing opens its value: 0.5 and Enter put the
    sphere at x 0.5 as one undo step. On the Y ring, 90 turns it a quarter about y; Esc
    closes the entry and changes nothing."""
    arm, ring, escape = Script(), Script(), Script()
    gizmo_mode(arm, 0)
    click(arm, GIZMO_X_ARM)
    type_value(arm, "0.5")
    gizmo_mode(ring, 1)
    click(ring, GIZMO_Y_RING)
    type_value(ring, "90")
    gizmo_mode(escape, 0)
    click(escape, GIZMO_X_ARM)
    escape.wait(2)
    escape.type("3")
    escape.press("Escape")
    return Steps([
        (arm, [], camera_still({"transform": is_text("0.5000,0.0000,0.0000,0.000,0.000,0.000,1.0000"), "undo_steps": near(1), "gizmo_entry": is_text("none")})),
        (ring, [], camera_still({"transform": transform_is(lambda x, y, z, rx, ry, rz, sc: abs(ry - 90) < 0.01 and abs(rx) < 0.01 and abs(rz) < 0.01), "undo_steps": near(1)})),
        (escape, [], camera_still({"transform": is_text("0.0000,0.0000,0.0000,0.000,0.000,0.000,1.0000"), "undo_steps": near(0), "gizmo_entry": is_text("none")})),
    ])


@scenario
def gizmo_pivot_on_the_surface():
    """Pivot on the action bar, then a tap on the sphere left of its middle, moves the gizmo
    to that point of the surface and lets go of the latch, the selection kept; scaling by 2
    there (a typed value on the disc) moves the sphere a unit away from that point."""
    placed, scaled = Script(), Script()
    for sc in (placed, scaled):
        sc.press("w")
        click(sc, GIZMO_CHIPS["pivot"])
        sc.ftap(640, 450)
    scaled.press("w")
    scaled.press("w")
    click(scaled, (640, 450))
    type_value(scaled, "2")
    # On the sphere's surface: about a unit from its middle.
    left = lambda v: v != "none" and abs(math.dist([float(x) for x in v.split(",")], [0, 0, 0]) - 1) < 0.05
    return Steps([
        (placed, [], camera_still({"gizmo_pivot": left, "gizmo_pivot_latch": near(0), "selected": near(0), "undo_steps": near(0),
                                   "gizmo_at": lambda v: abs(float(v.split(",")[0]) - 640) < 3})),
        (scaled, [], camera_still({"gizmo_pivot": left, "gizmo_mode": is_text("scale"), "transform": transform_is(lambda x, y, z, rx, ry, rz, sc: sc == 2 and math.dist((x, y, z), (0, 0, 0)) > 0.9), "undo_steps": near(1)})),
    ])


@scenario
def gizmo_drag_cancels_back():
    """A second finger landing while one drags an arm makes a gesture: the sphere goes
    back where it was and nothing is recorded. Esc does the same for the mouse. The
    gizmo, back too, is drawn where every gizmo scenario expects it."""
    finger, escape = Script(), Script()
    gizmo_mode(finger, 0)
    finger.fdrag(line(GIZMO_X_ARM, (GIZMO_X_ARM[0] + 60, GIZMO_X_ARM[1] + 12), 6), lift=False)
    finger.add("fdown:1:300,600")
    finger.wait(3)
    finger.add("fup:1")
    finger.add("fup:0")
    finger.wait(4)
    gizmo_mode(escape, 0)
    escape.add(f"move:{GIZMO_X_ARM[0]},{GIZMO_X_ARM[1]}")
    escape.wait(1)
    escape.add("down")
    for p in line(GIZMO_X_ARM, (GIZMO_X_ARM[0] + 60, GIZMO_X_ARM[1] + 12), 6)[1:]:
        escape.wait(1)
        escape.add(f"move:{p[0]:g},{p[1]:g}")
    escape.wait(1)
    escape.add("key:Escape")
    escape.wait(1)
    escape.add("keyup:Escape")
    escape.wait(2)
    escape.add("up")
    escape.wait(4)
    home = is_text("0.0000,0.0000,0.0000,0.000,0.000,0.000,1.0000")
    return Steps([
        (finger, [], {"transform": home, "gizmo_drags": near(0), "undo_steps": near(0)}),
        (escape, [], camera_still(gizmo_where({"transform": home, "gizmo_drags": near(0), "undo_steps": near(0)}))),
    ])


def main(argv):
    if "--list" in argv:
        for name, fn in SCENARIOS.items():
            print(f"{name:40s} {fn.__doc__}")
        return 0
    screens = 0 if "--screens" in argv else None
    # Side by side only where each scenario can have a display of its own (start_displays).
    jobs = (os.cpu_count() or 1) if os.name != "nt" and shutil.which("Xvfb") else 1
    for a in argv:
        if a.startswith("--jobs="):
            jobs = max(1, int(a.split("=", 1)[1]))
        if a.startswith("--screen-run="):
            screens = max(1, int(a.split("=", 1)[1]))
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
