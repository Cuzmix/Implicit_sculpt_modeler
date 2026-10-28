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
import ast
import concurrent.futures
import fnmatch
import math
import os
import queue
import shutil
import struct
import subprocess
import sys
import threading
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "build", "sculpt.exe" if os.name == "nt" else "sculpt")
START = 12  # the first frame events go in: anchored panels are placed by then

# The default camera (camera.orbit_default) and where things are at 1600 x 900.
CAMERA0 = {"camera_yaw": 0.6, "camera_pitch": 0.35, "camera_roll": 0.0, "camera_distance": 3.5}
MODEL = (800, 450)  # the sphere's middle; it reaches about 368 points out
EMPTY = (250, 150)  # viewport with nothing on it
UI = {
    "home": (26, 26), "menu": (74, 26), "save": (122, 26), "history": (1430, 26), "help": (1526, 26), "settings": (1574, 26),
    "brushes": (31, 143), "stroke": (31, 191), "colour": (31, 335), "channel": (31, 383),
    "focal": (31, 432), "size": (31, 480), "strength": (31, 528), "add": (31, 576), "subtract": (31, 624),
    "undo": (31, 673), "redo": (31, 721),
    # The navigation head (nav_head.odin), and the view bar under it.
    "nav_head": (1568, 88),
    "search": (1569, 155), "inspector": (1569, 203), "objects": (1569, 251),
    "shading": (1569, 317), "camera": (1569, 365), "studio": (1569, 413), "floor": (1569, 461),
    "sym_x": (1569, 509), "sym_local": (1569, 557), "wireframe": (1569, 653), "transparency": (1569, 701),
    "dock_draw": (426, 843), "dock_smooth": (490, 843), "browser": (872, 843), "gizmo": (933, 843),
    "remesh": (990, 843), "dyntopo": (1038, 843), "retopo": (1086, 843), "subdivide": (1134, 843),
    "live_boolean": (1182, 843), "dock_page1": (772, 888), "dock_page2": (800, 888), "dock_page3": (828, 888),
    "browser_curve": (860, 387), "browser_insert": (860, 723),
    "size_slider": (91, 663),  # in the popover the Size button opens
    # The tray's list of palettes and sections (kit_tray.odin), with the Brush palette open.
    "list_brush": (1116, 158), "list_object": (1116, 590), "list_scene": (1116, 638), "status": (69, 80),
    "palette_row1": (1327, 211), "palette_row2": (1327, 257),
    "earlier_save2": (138, 150),
}
# Menu rows at 1600x900, from kit_menu's order (new_ui.odin): add a FILE row here, not to
# every coordinate under it. Rows are 44 points apart; a divider and caption take 69.
MENU_FILE_ROWS = ["open", "save", "save_as", "save_copy", "earlier_saves", "last_autosave", "import", "export", "screenshot"]
_file_y = {name: 106 + 44 * i for i, name in enumerate(MENU_FILE_ROWS)}
_grid_y = _file_y[MENU_FILE_ROWS[-1]] + 69
# The menu's APP rows in order (new_ui.odin), under the New scene grid: a row added there is
# added here, and every tap on these rows follows.
MENU_APP_ROWS = ["reduce_motion", "settings", "stats", "help", "macros", "library"]
_app_y = {name: _grid_y + 48 + 69 + 44 * i for i, name in enumerate(MENU_APP_ROWS)}
# On a 1280x720 window, with the menu scrolled to its end, the last row's middle.
MENU_SHORT_LAST_Y = 688
UI.update({
    "menu_earlier_saves": (123, _file_y["earlier_saves"]),
    "new_sphere": (96, _grid_y), "new_head": (183, _grid_y), "new_hand": (183, _grid_y + 48),
    "menu_settings": (123, _app_y["settings"]), "menu_macros": (123, _app_y["macros"]), "menu_library": (123, _app_y["library"]),
})
# The Macros panel (kit_macros.odin) with two macros: each row's Run, Key, Rename and
# Delete, rows 52 points apart.
UI.update({f"macro{row + 1}_{part}": (x, 250 + 52 * row) for row in range(2)
           for part, x in (("run", 1350), ("key", 1398), ("rename", 1445), ("delete", 1494))})
ORBIT_TURN = 2 * math.pi / 0.008  # points of drag that turn the view once (ORBIT_SPEED)


class Script:
    """Builds a --ui-events list frame by frame."""

    def __init__(self):
        self.events, self.frame = [], START
        self.window = 0  # the view window the next events go to (FRAME:winN:...), 0 for the main one

    def at(self, frame=None):
        return self.frame if frame is None else frame

    def add(self, text, frame=None):
        win = f"win{self.window}:" if self.window else ""
        self.events.append(f"{self.at(frame)}:{win}{text}")

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
LONG_PRESS_FRAMES = 30  # Settings > Touch > Hold delay (0.25 s by default) is 15 frames of UI_DT; room for a longer one


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


def _no_twice_defined():
    """A second top-level def of one name silently replaces the first, so a spliced-in
    scenario or helper would hide another and its checks would never run: refuse to load."""
    seen, twice = {}, []
    for node in ast.parse(open(__file__, encoding="utf-8").read()).body:
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            if node.name in seen:
                twice.append(f"{node.name} (lines {seen[node.name]} and {node.lineno})")
            seen.setdefault(node.name, node.lineno)
    if twice:
        sys.exit("touch_check.py defines these twice, so the first is never run: " + ", ".join(twice))


_no_twice_defined()


def scenario(fn):
    SCENARIOS[fn.__name__] = fn
    return fn


@scenario
def tap_ui():
    """A finger tapping every major region of the interface never moves the camera or sculpts."""
    s = Script()
    for name in ["menu", "menu", "undo", "history", "history", "gizmo", "dock_draw", "sym_x", "sym_x",
                 "camera", "camera", "shading", "shading", "size", "size", "strength", "strength", "stroke", "stroke", "dock_smooth", "dock_draw",
                 "browser", "browser", "brushes", "brushes", "list_object", "list_brush", "objects", "objects", "status"]:
        s.ftap(*UI[name])
    # Just past the drawn edge of the brush dock and the top bar, inside their targets.
    s.ftap(490, 815)
    s.ftap(692, 4)
    return s, [], camera_still({"dabs": near(0)})


# The symmetry popover a long press on Symmetry opens at 1600 x 900: its X, Y, Z and Local;
# the Radial row's switch and axes; and the Copies slider's two ends.
SYMMETRY_AXES = {"x": (1325, 545), "y": (1377, 545), "z": (1429, 545), "local": (1489, 545)}
RADIAL_ROW = {"radial": (1333, 623), "x": (1393, 623), "y": (1445, 623), "z": (1497, 623)}
RADIAL_COPIES = ((1351, 687), (1530, 687))
# The Floor grid section's Back toggle, and the polyframe popover's Fill, beside the bar.
FLOOR_BACK = (1381, 609)
POLYFRAME_FILL = (1450, 686)
# The Camera menu's Field of view slider, under Orthographic.
FOV_SLIDER = (1300, 180)


@scenario
def bar_section_opens_beside_the_bar():
    """A tap on the brush bar's Stroke opens the Stroke section beside it; a second tap closes it; Focal shift then opens its slider."""
    s = Script()
    s.ftap(*UI["stroke"])
    s.wait(8)
    s.ftap(*UI["stroke"])
    s.wait(8)
    s.ftap(*UI["focal"])
    s.wait(8)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("focal")})


@scenario
def long_press_draw_size_opens_the_pen():
    """A long press on Draw size opens the Pen section (pressure and tilt) rather than its slider, and moves nothing."""
    s = Script()
    long_press(s, *UI["size"])
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("pen"), "brush_radius_px": near(60)})


def long_press_drag(s, x, y, dy, finger=0, steps=10, frames=LONG_PRESS_FRAMES):
    """A long press on (x, y), then, still held, a drag `dy` points down (negative: up) and a lift."""
    s.add(f"fdown:{finger}:{x:g},{y:g}")
    s.wait(frames)
    for k in range(1, steps + 1):
        s.add(f"fmove:{finger}:{x:g},{y + dy * k / steps:g}")
        s.wait(1)
    s.add(f"fup:{finger}")
    s.wait(4)


@scenario
def long_press_drag_draw_size():
    """A long press on Draw size dragged 150 points up (past the slop, which the drag starts from) about doubles the size, and opens nothing."""
    s = Script()
    long_press_drag(s, *UI["size"], -150 - 10)
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("none"), "brush_radius_px": lambda v: 105 < float(v) <= 120})


@scenario
def hold_delay_is_short_by_default():
    """Draw size held still 0.28 s, just past the default Hold delay of 0.25 s, is a long press: the Pen section opens, where the old 0.3 s would still have tapped."""
    s = Script()
    long_press(s, *UI["size"], frames=17)
    s.wait(8)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("pen"), "brush_radius_px": near(60)})


@scenario
def hold_delay_setting_goes_down_to_a_tenth():
    """With the Hold delay at its floor of 0.1 s, Draw size held still 0.13 s is already a long press: the Pen section opens."""
    s = Script()
    long_press(s, *UI["size"], frames=8)
    s.wait(8)
    return s, ["--script=set hold_delay 0.1"], camera_still({"dabs": near(0), "bar_pop": is_text("pen"), "brush_radius_px": near(60)})


@scenario
def drag_draw_size_at_once():
    """A finger on Draw size dragged straight up 160 points, with no hold first, about doubles the size, as a long press dragged does, and opens nothing."""
    s = Script()
    long_press_drag(s, *UI["size"], -150 - 10, frames=1)
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("none"), "long_tip": lambda v: v == "none", "brush_radius_px": lambda v: 105 < float(v) <= 120})


@scenario
def mouse_drags_strength_at_once():
    """The mouse pressed on Strength and dragged 70 points down lowers it, as a finger's long press dragged does, and opens nothing."""
    s = Script()
    x, y = UI["strength"]
    s.mouse_drag(line((x, y), (x, y + 70), 10))
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("none"), "brush_strength": lambda v: 0.28 <= float(v) <= 0.34})


@scenario
def hold_delay_setting_keeps_a_shorter_hold_a_tap():
    """With the Hold delay at 0.8 s, Draw size held 0.5 s is still a tap: its slider opens, not the Pen section."""
    s = Script()
    long_press(s, *UI["size"], frames=30)
    s.wait(8)
    return s, ["--script=set hold_delay 0.8"], camera_still({"dabs": near(0), "bar_pop": is_text("size"), "long_tip": lambda v: v == "none"})


@scenario
def hold_delay_setting_still_long_presses():
    """With the Hold delay at 0.8 s, Draw size held 0.9 s is a long press: the Pen section opens."""
    s = Script()
    long_press(s, *UI["size"], frames=54)
    s.wait(8)
    return s, ["--script=set hold_delay 0.8"], camera_still({"dabs": near(0), "bar_pop": is_text("pen"), "brush_radius_px": near(60)})


@scenario
def long_press_drag_strength_and_focal():
    """Dragged down, a long press on Strength lowers it; dragged up, one on Focal shift raises it; neither opens anything."""
    s = Script()
    long_press_drag(s, *UI["strength"], 60 + 10)
    long_press_drag(s, *UI["focal"], -60 - 10)
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("none"), "brush_strength": lambda v: 0.28 <= float(v) <= 0.34,
                                "brush_focal": lambda v: 30 <= float(v) <= 42})


@scenario
def cancelled_scrub_puts_the_size_back():
    """A long press on Draw size dragged up, then cancelled by the system, puts the size back and opens nothing."""
    s = Script()
    x, y = UI["size"]
    s.add(f"fdown:0:{x:g},{y:g}")
    s.wait(LONG_PRESS_FRAMES)
    for k in range(1, 11):
        s.add(f"fmove:0:{x:g},{y - 12 * k:g}")
        s.wait(1)
    s.add("fcancel:0")
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("none"), "brush_radius_px": near(60)})


@scenario
def long_press_focal_shift_opens_the_falloff():
    """A long press on Focal shift let go without dragging opens the Falloff section (the curve), and changes nothing."""
    s = Script()
    long_press(s, *UI["focal"])
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "bar_pop": is_text("falloff"), "brush_focal": near(0)})


@scenario
def symmetry_tap_and_long_press():
    """A tap on Symmetry turns X on; a long press opens the three axes, where a tap on Y adds it."""
    s = Script()
    s.ftap(*UI["sym_x"])
    s.wait(4)
    long_press(s, *UI["sym_x"])
    s.wait(8)
    s.ftap(*SYMMETRY_AXES["y"])
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "symmetry": is_text("xy"), "bar_pop": is_text("symmetry")})


@scenario
def local_symmetry_tap():
    """A tap on Local symmetry mirrors about the object's own middle, beside the X axis a tap
    on Symmetry turned on; a second tap puts the world's middle back."""
    s = Script()
    s.ftap(*UI["sym_x"])
    s.wait(4)
    s.ftap(*UI["sym_local"])
    s.wait(4)
    twice = Script()
    for _ in range(2):
        twice.ftap(*UI["sym_local"])
        twice.wait(4)
    return Steps([(s, [], camera_still({"dabs": near(0), "symmetry": is_text("x+local")})),
                  (twice, [], camera_still({"dabs": near(0), "symmetry": is_text("none")}))])


@scenario
def radial_symmetry_from_the_popover():
    """In the symmetry popover, Radial turns on copies round Y, a tap on Z turns them round
    Z, and dragging Copies to its end gives the most copies; with no mirror axis on, the
    Symmetry button still shows lit."""
    s = Script()
    long_press(s, *UI["sym_x"])
    s.wait(8)
    s.ftap(*RADIAL_ROW["radial"])
    s.wait(4)
    s.ftap(*RADIAL_ROW["z"])
    s.wait(4)
    (x0, y), (x1, _) = RADIAL_COPIES
    s.fdrag([(x0 + (x1 - x0) * i / 6, y) for i in range(7)])
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "symmetry": is_text("none+radial32z"), "bar_pop": is_text("symmetry")})


@scenario
def radial_stroke_lays_its_copies():
    """With Radial on from the popover, a short mouse stroke on the model lays its dab and
    the copies round Y, all in one undo step."""
    s = Script()
    long_press(s, *UI["sym_x"])
    s.wait(8)
    s.ftap(*RADIAL_ROW["radial"])
    s.wait(4)
    s.mouse_drag([(760, 200)])
    s.wait(4)
    s.mouse_drag([(760 + 8 * i, 200 + 4 * i) for i in range(8)])
    s.wait(4)
    return s, [], {"symmetry": is_text("none+radial8y"), "dabs": lambda v: int(v) > 0, "undo_steps": near(1)}


@scenario
def channel_button_paints_with_draw():
    """A tap on the brush bar's channel steps Sculpt only to Sculpt and paint: a Draw stroke
    then raises the model and paints it, as one undo step."""
    s = Script()
    s.ftap(*UI["channel"])
    s.wait(4)
    s.mouse_drag([(760 + 8 * i, 300 + 4 * i) for i in range(8)])
    s.wait(4)
    return s, [], {"paint_channel": is_text("both"), "dabs": lambda v: int(v) > 0, "undo_steps": near(1),
                   "painted_vertices": lambda v: int(v) > 0}


@scenario
def colour_long_press_swaps_colours():
    """A long press on the brush bar's Colour swaps the main and secondary colours and opens
    nothing; two taps on the channel make the brushes only paint, so a Draw stroke paints
    and leaves the model where it was."""
    s = Script()
    long_press(s, *UI["colour"])
    s.wait(8)
    paint = Script()
    paint.ftap(*UI["channel"])
    paint.ftap(*UI["channel"])
    paint.wait(4)
    paint.mouse_drag([(760 + 8 * i, 300 + 4 * i) for i in range(8)])
    paint.wait(4)
    return Steps([(s, [], camera_still({"paint_color": is_text("F2EBD9"), "paint_color2": is_text("BF3326"), "bar_pop": is_text("none"),
                                        "window_colors": lambda v: v.startswith("0,")})),
                  (paint, [], {"paint_channel": is_text("color"), "painted_vertices": lambda v: int(v) > 0, "undo_steps": near(1),
                               "bar_pop": is_text("none")})])


# The Colors card beside the brush bar at 1600 x 900: its header's buttons, its tabs, the
# first swatch of the default palette (Skin) under the Disc and the Value tab's hex field.
COLORS_CARD = {"main": (102, 173), "secondary": (150, 173), "swap": (198, 173), "fill": (246, 173), "gradient": (294, 173),
               "eyedropper": (342, 173), "close": (390, 173), "disc": (110, 760), "classic": (178, 760), "harmony": (246, 760),
               "value": (314, 760), "palettes": (381, 760), "skin": (102, 645), "hex": (353, 432)}


# The Colour section's well with the Paint brush (Brush > Colour in the tray), and the
# popover's first Skin swatch, left of it, at 1600 by 900.
COLOUR_WELL, POPOVER_SKIN = (1321, 315), (903, 806)


@scenario
def colour_well_opens_the_picker():
    """A tap on the Colour section's well opens the colour popover beside it, as
    Procreate's colour well does; a tap on a swatch in it sets the paint colour and puts it
    in the history, with the popover still open; a second tap on the well puts it away."""
    setup = "--script=brush paint; show_section paint_color"
    s = Script()
    s.ftap(*COLOUR_WELL)
    s.wait(10)
    s.ftap(*POPOVER_SKIN)
    s.wait(6)
    closed = Script()
    closed.ftap(*COLOUR_WELL)
    closed.wait(10)
    closed.ftap(*COLOUR_WELL)
    closed.wait(10)
    return Steps([(s, [setup], camera_still({"dabs": near(0), "color_popover": near(1), "paint_color": is_text("F8E1D4"), "color_history": near(1)})),
                  (closed, [setup], camera_still({"dabs": near(0), "color_popover": near(0)}))])


@scenario
def colour_well_in_a_bar_popover():
    """The Colour section opened from the brush bar (a long press on the paint channel)
    is a popover; a tap on its well opens the colour popover over it, and a tap on a
    swatch there sets the paint colour while both stay open."""
    s = Script()
    long_press(s, *UI["channel"])
    s.wait(10)
    s.ftap(160, 490)
    s.wait(10)
    s.ftap(290, 806)
    s.wait(6)
    return s, ["--script=brush paint"], camera_still({"dabs": near(0), "bar_pop": is_text("paint_color"), "color_popover": near(1),
                                                       "paint_color": is_text("F8E1D4")})


@scenario
def colors_card_picks_a_swatch():
    """A tap on the brush bar's Colour opens the Colors card; a tap on a palette swatch makes
    it the main colour and puts it in the history; Classic stays the tab picked; Close
    puts the card away; nothing is sculpted and the view stays."""
    s = Script()
    s.ftap(*UI["colour"])
    s.wait(10)
    s.ftap(*COLORS_CARD["skin"])
    s.wait(4)
    s.ftap(*COLORS_CARD["classic"])
    s.wait(4)
    closed = Script()
    closed.ftap(*UI["colour"])
    closed.wait(10)
    closed.ftap(*COLORS_CARD["close"])
    closed.wait(10)
    return Steps([(s, [], camera_still({"window_colors": lambda v: v.startswith("1,"), "paint_color": is_text("F8E1D4"), "color_history": near(1),
                                        "colors_tab": is_text("classic"), "dabs": near(0)})),
                  (closed, [], {"window_colors": lambda v: v.startswith("0,"), "dabs": near(0)})])


@scenario
def colors_secondary_swatch_takes_the_pick():
    """With the secondary swatch chosen, a palette swatch sets the secondary colour and leaves the main one."""
    s = Script()
    s.ftap(*UI["colour"])
    s.wait(10)
    s.ftap(*COLORS_CARD["secondary"])
    s.wait(4)
    s.ftap(*COLORS_CARD["skin"])
    s.wait(4)
    return s, [], {"paint_color": is_text("BF3326"), "paint_color2": is_text("F8E1D4"), "dabs": near(0)}


@scenario
def colors_eyedropper_picks_from_the_model():
    """Fill gradient paints the model as one undo step; the Eyedropper then waits for a finger on the
    model, whose drag and lift pick the paint under it, sculpting nothing and turning nothing."""
    s = Script()
    s.ftap(*UI["colour"])
    s.wait(10)
    s.ftap(*COLORS_CARD["gradient"])
    s.wait(4)
    s.ftap(*COLORS_CARD["eyedropper"])
    s.wait(4)
    s.fdrag([(800, 220)] + line((800, 240), (800, 260), 6))
    s.wait(4)
    return s, [], camera_still({"undo_steps": near(1), "dabs": near(0), "eyedropper": near(0), "color_history": near(1),
                                "paint_color": lambda v: v != "BF3326", "painted_vertices": lambda v: int(v) > 0})


@scenario
def colors_eyedropper_key_picks_under_the_pointer():
    """Shift+C over the model picks the colour under the pointer at once: unpainted, the clay's."""
    s = Script()
    s.add("move:800,300")
    s.wait(4)
    s.press("c", mods=("shift",))
    s.wait(4)
    return s, [], camera_still({"paint_color": lambda v: v != "BF3326", "color_history": near(1), "dabs": near(0), "eyedropper": near(0)})


@scenario
def render_switch_runs_one_quality():
    """The right bar's Render button turns the render on at Preview; Full render from search then takes over
    from Preview, so the one switch never runs both; the button again turns it off, keeping Full as the
    quality, and nothing is sculpted."""
    s = Script()
    s.ftap(*UI["studio"])
    s.wait(6)
    palette_run(s, "full render")
    s.wait(6)
    s.ftap(*UI["studio"])
    s.wait(6)
    return s, [], camera_still({"render_switch": near(0), "render_quality": is_text("full"), "studio": near(0), "render": near(0),
                                "dabs": near(0), "undo_steps": near(0)})


@scenario
def pick_focus_takes_the_point_from_the_model():
    """Pick focus from search waits for a finger on the model; its tap puts depth of field's focus on the
    sphere's surface, sculpting nothing and turning nothing."""
    s = Script()
    palette_run(s, "pick focus")
    s.wait(4)
    s.ftap(800, 240)
    s.wait(4)

    def on_the_sphere(v):
        x, y, z = (float(c) for c in v.split(","))
        return abs(math.sqrt(x * x + y * y + z * z) - 1) < 0.02 and y > 0.2

    return s, ["--script=set render_dof on"], camera_still({"focus_picked": near(1), "focus_armed": near(0), "render_dof": near(1),
                                                         "focus": on_the_sphere, "dabs": near(0), "undo_steps": near(0)})


@scenario
def colors_value_hex_sets_the_colour():
    """On the Value tab, typing a hex code and Enter sets the main colour."""
    s = Script()
    s.ftap(*UI["colour"])
    s.wait(10)
    s.ftap(*COLORS_CARD["value"])
    s.wait(6)
    s.ftap(*COLORS_CARD["hex"])
    s.wait(4)
    s.type("3A7")
    s.press("Return")
    s.wait(4)
    return s, [], {"paint_color": is_text("33AA77"), "color_history": near(1), "dabs": near(0)}


@scenario
def add_and_subtract_buttons():
    """Subtract on the brush bar latches the wheel's Invert, so brushes dig; Add lets it go."""
    s = Script()
    s.ftap(*UI["subtract"])
    s.wait(4)
    both = Script()
    both.ftap(*UI["subtract"])
    both.wait(4)
    both.ftap(*UI["add"])
    both.wait(4)
    return Steps([(s, [], camera_still({"brush_subtract": near(1), "rail_latched": is_text("invert")})),
                  (both, [], camera_still({"brush_subtract": near(0)}))])


@scenario
def floor_grid_tap_and_long_press():
    """A tap on Floor grid shows the grid; a long press opens its settings beside the bar,
    where a tap on Back adds the back wall to the floor."""
    s = Script()
    s.ftap(*UI["floor"])
    s.wait(4)
    long_press(s, *UI["floor"])
    s.wait(8)
    s.ftap(*FLOOR_BACK)
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "floor_grid": near(1), "floor_planes": is_text("011"), "bar_pop": is_text("floor")})


@scenario
def transparency_tap():
    """A tap on Transparency shows the other objects see-through; another puts them back."""
    s = Script()
    s.ftap(*UI["transparency"])
    s.wait(4)
    once = Script()
    once.ftap(*UI["transparency"])
    once.wait(4)
    once.ftap(*UI["transparency"])
    once.wait(4)
    return Steps([(s, [], camera_still({"transparent": near(1), "dabs": near(0)})),
                  (once, [], camera_still({"transparent": near(0), "dabs": near(0)}))])


@scenario
def polyframe_long_press_picks_fill():
    """A long press on Wireframe opens what the polyframe shows; Fill adds the polygroups'
    colours to the lines, and a tap on the button shows it."""
    s = Script()
    long_press(s, *UI["wireframe"])
    s.wait(8)
    s.ftap(*POLYFRAME_FILL)
    s.wait(4)
    s.ftap(*UI["wireframe"])
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "polyframe_fill": near(1), "polyframe_lines": near(1), "wireframe": near(1)})


@scenario
def field_of_view_from_the_camera_menu():
    """The right bar's Camera button opens the Camera menu, whose Field of view slider widens
    the lens; the eye comes in to keep the model's size, so the distance shrinks."""
    s = Script()
    s.ftap(*UI["camera"])
    s.wait(8)
    s.fdrag([(FOV_SLIDER[0] + 12 * i, FOV_SLIDER[1]) for i in range(11)])
    s.wait(4)
    return s, [], {"dabs": near(0), "@wider": lambda st: float(st["fov"]) > 50, "@nearer": lambda st: float(st["camera_distance"]) < 3.4}


@scenario
def gizmo_and_browser_tools():
    """The bottom bar's Gizmo picks the Move tool; in the brush browser, a long press on Curve picks Curve, closes the browser and shows its settings in the inspector's first tab."""
    s = Script()
    s.ftap(*UI["gizmo"])
    s.wait(4)
    s.ftap(*UI["list_object"])
    s.wait(4)
    s.ftap(*UI["browser"])
    s.wait(10)
    long_press(s, *UI["browser_curve"])
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "tool": is_text("curve"), "inspector_tab": is_text("tool"), "browser": near(0)})


@scenario
def browser_tap_picks_insert():
    """A tap on Insert in the brush browser picks the Insert tool and closes the browser."""
    s = Script()
    s.ftap(*UI["browser"])
    s.wait(10)
    s.ftap(*UI["browser_insert"])
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "tool": is_text("insert"), "browser": near(0)})


@scenario
def dock_pages_by_the_dots():
    """The second dot under the bottom bar shows the dock's second page, whose first slot picks Pinch; the first dot brings Draw back."""
    flip, back = Script(), Script()
    for s in (flip, back):
        s.ftap(*UI["dock_page2"])
        s.wait(6)
        s.ftap(*UI["dock_draw"])
        s.wait(4)
    back.ftap(*UI["dock_page1"])
    back.wait(6)
    return Steps([
        (flip, [], camera_still({"dabs": near(0), "dock_page": near(1), "dock_pages": near(3), "brush_kind": is_text("pinch"),
                                 "dock": is_text("Pinch,Crease,Layer,Snake_hook,Cloth,Morph,History")})),
        (back, [], camera_still({"dabs": near(0), "dock_page": near(0), "dock": is_text(DEFAULT_DOCK)})),
    ])


@scenario
def brush_key_brings_its_dock_page():
    """On the dock's second page with Pinch picked there, the 1 key (Draw) brings the first page, which holds Draw."""
    s = Script()
    s.ftap(*UI["dock_page2"])
    s.wait(6)
    s.ftap(*UI["dock_draw"])  # Pinch, the second page's first slot
    s.wait(4)
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.press("1")
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "dock_page": near(0), "brush_kind": is_text("draw")})


@scenario
def mesh_tools_on_the_bottom_bar():
    """The bottom bar's mesh tools: Dynamic topology and Live boolean turn on by a tap; Subdivide adds a level; a long press on Remesh opens its quick menu above the bar, and a tap on Retopologize opens its own."""
    toggles, divide, remesh, retopo = Script(), Script(), Script(), Script()
    toggles.ftap(*UI["dyntopo"])
    toggles.wait(8)
    toggles.ftap(*UI["live_boolean"])
    toggles.wait(4)
    divide.ftap(*UI["subdivide"])
    divide.wait(10)
    long_press(remesh, *UI["remesh"])
    remesh.wait(8)
    retopo.ftap(*UI["retopo"])
    retopo.wait(8)
    return Steps([
        (toggles, [], camera_still({"dabs": near(0), "dynamic": near(1), "live_boolean": near(1)})),
        (divide, [], camera_still({"dabs": near(0), "selected_levels": near(2)})),
        (remesh, [], camera_still({"dabs": near(0), "bar_pop": is_text("remesh_quick"), "undo_steps": near(0)})),
        (retopo, [], camera_still({"dabs": near(0), "bar_pop": is_text("retopo"), "undo_steps": near(0)})),
    ])


# Customise bars (bars.odin) at 1600x900: Arrange's Done (arrange.odin), the right column's + under its
# eleven buttons, a slot popover's Move earlier, Move later, Remove and Add after, opened
# on Ghost (its middle at 749), and the dock slot popover's "A command instead...", opened
# by a long press on Draw.
BARS_DONE = (881, 100)
SHORTCUT_ADD = (1569, 843)
SHORTCUT_MENU = {"up": (1306, 736), "down": (1359, 736), "remove": (1410, 736), "add": (1462, 736)}
GHOST = (1569, 749)
DOCK_A_COMMAND = (370, 236)


@scenario
def customise_bars_changes_the_right_bar():
    """Customise bars rings the bars' buttons, and a tap on one runs nothing: on Ghost it
    opens the slot's popover, whose Remove takes it off; the column's + then chooses a
    command in Search (Orthographic) for a new last button, and Done ends it. The settings
    file keeps the column, and a second start shows it so."""
    s = Script()
    s.wait(3)
    palette_run(s, "customise bars")
    s.wait(8)
    s.ftap(*GHOST)
    s.wait(8)
    s.ftap(*SHORTCUT_MENU["remove"])
    s.wait(6)
    s.ftap(SHORTCUT_ADD[0], SHORTCUT_ADD[1] - 48)  # one button fewer: the + moved up
    s.wait(8)
    s.type("orthographic")
    s.press("Return")
    s.wait(6)
    s.ftap(*BARS_DONE)
    s.wait(4)
    column = "Shading_Menu,Camera_Menu,Studio_Render,Floor_Grid,Symmetry_X,Local_Symmetry,Focus_Selected,Wireframe,Transparency,Solo_Object,Ortho_Toggle"
    again = Script()
    again.wait(5)
    return Steps([
        (s, [f"--settings-file={settings_file()}"], camera_still({"shortcuts": is_text(column), "bars_edit": near(0), "objects_ghost": near(0),
                                                                "ortho": near(0), "dabs": near(0), "@saved": saved_line("bar right_rail 10 Ortho_Toggle")})),
        (again, [f"--settings-file={settings_file()}"], {"shortcuts": is_text(column)}),
    ])


@scenario
def customise_bars_moves_a_shortcut_up():
    """While customising, Ghost's Move earlier puts it above Transparency."""
    s = Script()
    s.wait(3)
    palette_run(s, "customise bars")
    s.wait(8)
    s.ftap(*GHOST)
    s.wait(8)
    s.ftap(*SHORTCUT_MENU["up"])
    s.wait(4)
    return s, [], camera_still({"shortcuts": lambda v: ",Ghost_Object,Transparency," in v, "bars_edit": near(1), "bar_slot_menu": near(1)})


@scenario
def dock_slot_holds_a_command():
    """A long press on the dock's Draw, then "A command instead..." and Search's first
    match for "remesh": the slot holds Remesh, and a tap on it remeshes the sphere."""
    s = Script()
    s.wait(3)
    long_press(s, *UI["dock_draw"])
    s.wait(8)
    s.ftap(*DOCK_A_COMMAND)
    s.wait(8)
    s.type("remesh")
    s.press("Return")
    s.wait(6)
    s.ftap(*UI["dock_draw"])
    s.wait(10)
    return s, [f"--settings-file={settings_file()}"], camera_still({"dock": lambda v: v.startswith("Remesh,Smooth"), "undo_steps": near(1),
                                                                    "dabs": near(0), "@saved": saved_line("dock 0 command Remesh")})


@scenario
def dock_swipe_turns_the_page():
    """A finger swiping left over the dock's slots turns to the next page and picks no
    brush; swiping right turns back; a short drag turns nothing; the mouse wheel over the
    slots turns a page a notch."""
    left, back, short, wheel = Script(), Script(), Script(), Script()
    for sc in (left, back, short):
        sc.wait(3)
        sc.fdrag(line((700, 843), (450, 843), 8))
        sc.wait(10)
    back.fdrag(line((450, 843), (700, 843), 8))
    back.wait(10)
    short.fdrag(line((600, 843), (585, 843), 3))
    short.wait(10)
    wheel.wait(3)
    wheel.add("move:600,843")
    wheel.wait(2)
    wheel.add("wheel:-1")
    wheel.wait(10)
    return Steps([
        (left, [], camera_still({"dock_page": near(1), "dock": lambda v: v.startswith("Pinch"), "brush_kind": is_text("draw"), "dabs": near(0)})),
        (back, [], camera_still({"dock_page": near(0), "brush_kind": is_text("draw"), "dabs": near(0)})),
        (short, [], camera_still({"dock_page": near(1), "brush_kind": is_text("draw"), "dabs": near(0)})),
        (wheel, [], camera_still({"dock_page": near(1), "dabs": near(0)})),
    ])


@scenario
def narrow_dock_has_more_pages():
    """At 820 x 640 the dock shows fewer slots a page, on more pages, and the bottom bar stays clear of the modifier rail."""
    s = Script()
    s.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    s.wait(10)
    return s, ["--width=820", "--height=640"], {"dock_pages": lambda v: int(v) > 3, "@layout": rail_clear("dock", "dock_pages")}


@scenario
def look_switch_is_remembered():
    """Settings > Interface > Look > Graphite changes the colours at once and is saved."""
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    s = Script()
    open_settings(s, "interface")
    s.ftap(1454, 234)  # Graphite, right of Lens and Studio
    s.wait(4)
    s.ftap(1427, 766)  # Done
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], camera_still({"look": is_text("graphite"), "@saved": saved(look="Graphite")})


@scenario
def tap_viewport_far_apart():
    """Touching down far from where the last finger lifted is no drag (SDL's mouse jump bug)."""
    s = Script()
    s.ftap(*EMPTY)
    s.ftap(1196, 800)
    s.ftap(150, 820)
    s.ftap(*UI["menu"])
    s.ftap(1196, 120, hold=8)
    return s, [], camera_still({"dabs": near(0)})


@scenario
def first_touch_scrolls_inspector():
    """The first finger drag on the tray's Mask section (every option shown, taller than the tray) from its Steps slider scrolls the tray and changes nothing."""
    s = Script()
    write_settings("all_options 1\n")
    s.fdrag(line(MASK_STEPS, (MASK_STEPS[0] + 5, MASK_STEPS[1] - 220), 22))
    return s, ["--script=show_section mask", f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "mask_steps": near(3),
                                "inspector_scroll": lambda v: float(v) > 50})


# The Lights section's sphere, where the tray shows it at 1600 x 900: its centre and
# radius in points.
LIGHT_SPHERE = (1377, 249)
LIGHT_SPHERE_R = 80


# The Lights section's Add Point button, and the first light's eye in its list, in points.
LIGHT_ADD_POINT = (1388, 583)
LIGHT1_EYE = (1498, 367)


@scenario
def lights_added_and_switched_off_in_the_list():
    """In Scene: Lights, a tap on Add Point adds a fifth light, a point light, and picks it; a tap on the first light's eye switches it off; each is one undo step and nothing is sculpted."""
    s = Script()
    s.ftap(*LIGHT_ADD_POINT)
    s.wait(4)
    s.ftap(*LIGHT1_EYE)
    s.wait(4)
    return s, ["--script=show_section lights"], camera_still({"dabs": near(0), "light_count": near(5), "light_pick": near(5), "light1_on": near(0), "undo_steps": near(2)})


@scenario
def light_sphere_moves_and_flips_lights():
    """In Scene: Lights, a finger drag from the first light's marker on the sphere moves that light to where it lets go (in front still); a tap on it then sends it behind the model; nothing is sculpted and the camera stays."""
    s = Script()
    cx, cy = LIGHT_SPHERE
    # The first light (the key) shows up and to the left: -0.51, 0.61 of the radius.
    key = (cx - 0.508 * LIGHT_SPHERE_R, cy - 0.609 * LIGHT_SPHERE_R)
    to = (cx + 0.5 * LIGHT_SPHERE_R, cy)
    s.fdrag(line(key, to, 16))
    s.wait(4)
    s.ftap(*to)
    s.wait(4)
    return s, ["--script=show_section lights"], camera_still({"dabs": near(0), "light_pick": near(1), "light1_on": near(1), "light_flips": near(1),
                                                             "light1": lambda v: all(abs(float(a) - b) < 0.03 for a, b in zip(v.split(","), (0.5, 0, -0.866)))})


# The Lights section's Place highlight switch, in points; and the first light's marker
# in the viewport, on the circle 0.42 of the view's height round its middle.
LIGHT_PLACE = (1490, 695)
LIGHT1_MARKER = (800 - 0.508 * 378, 450 - 0.609 * 378)


@scenario
def light_marker_dragged_in_the_viewport():
    """In Scene: Lights, a finger drag on the first light's marker in the viewport moves the light round the circle to the right (in front still), as the light sphere would; one undo step, nothing sculpted, the camera stays."""
    s = Script()
    s.fdrag(line(LIGHT1_MARKER, (800 + 0.5 * 378, 450), 16))
    s.wait(4)
    return s, ["--script=show_section lights"], camera_still({"dabs": near(0), "light_pick": near(1), "light_moves": near(1), "undo_steps": near(1),
                                                             "light1": lambda v: all(abs(float(a) - b) < 0.03 for a, b in zip(v.split(","), (0.5, 0, 0.866)))})


# The scene's x axis on screen from the middle, as the default camera (yaw 0.6, pitch
# 0.35) sees it: its right is (cos yaw, 0, -sin yaw) and its up (-sin pitch sin yaw,
# cos pitch, -sin pitch cos yaw).
GIZMO_X_WAY = (math.cos(0.6), math.sin(0.35) * math.sin(0.6))
GIZMO_X_WAY = (GIZMO_X_WAY[0] / math.hypot(*GIZMO_X_WAY), GIZMO_X_WAY[1] / math.hypot(*GIZMO_X_WAY))


@scenario
def light_gizmo_arm_moves_the_light_along_x():
    """In Scene: Lights, with the first light a point light standing 1.5 in front of the orbit's centre (in the middle of the view), a finger drag along its x arm, out from its marker, moves it along the scene's x alone; one undo step, nothing sculpted, the camera stays."""
    s = Script()
    w = GIZMO_X_WAY
    s.fdrag(line((800 + 40 * w[0], 450 + 40 * w[1]), (800 + 120 * w[0], 450 + 120 * w[1]), 16))
    s.wait(4)
    setup = "show_section lights; set light1_kind point; set light1_px 0; set light1_py 0; set light1_pz 1.5; wait 2"
    # Where it stood: the orbit's centre plus 1.5 toward the eye, (0.80, 0.51, 1.16).
    at = lambda v: [float(x) for x in v.split(",")]
    return s, [f"--script={setup}"], camera_still({"dabs": near(0), "light_pick": near(1), "light_moves": near(1), "undo_steps": near(1),
                                                    "light1_at": lambda v: at(v)[0] > 0.9 and abs(at(v)[1] - 0.51) < 0.015 and abs(at(v)[2] - 1.16) < 0.015})


@scenario
def place_highlight_lights_where_the_finger_taps():
    """In Scene: Lights, with Place highlight switched on a tap in the middle of the sphere turns the first light to shine from the camera, so its highlight lands there; one undo step, nothing sculpted, the camera stays."""
    s = Script()
    s.ftap(*LIGHT_PLACE)
    s.wait(4)
    s.ftap(800, 450)
    s.wait(4)
    return s, ["--script=show_section lights"], camera_still({"dabs": near(0), "light_pick": near(1), "light_moves": near(1), "undo_steps": near(1),
                                                             "light1": lambda v: all(abs(float(a) - b) < 0.03 for a, b in zip(v.split(","), (0, 0, 1)))})


# The Lights section's name field for the picked light, with every option shown.
LIGHT_NAME_FIELD = (1376, 748)


@scenario
def light_renamed_by_typing_is_one_step():
    """In Scene: Lights, with every option shown, a tap on the name field and typing "Key lamp" then Enter names the first light; the typing is one undo step and nothing is sculpted."""
    s = Script()
    write_settings("all_options 1\n")
    s.ftap(*LIGHT_NAME_FIELD)
    s.wait(4)
    s.type("Key lamp")
    s.press("Return")
    s.wait(4)
    return s, ["--script=show_section lights", f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "light1_name": is_text("Key_lamp"), "undo_steps": near(1)})


# The Mask section's Steps slider, where the tray shows it at 1600 x 900.
MASK_STEPS = (1376, 362)


@scenario
def slider_drag_sideways():
    """A sideways finger drag on the tray's Strength slider sets it, without orbiting or scrolling."""
    s = Script()
    s.fdrag(line((1376, 325), (1466, 327), 12))
    return s, [], camera_still({"dabs": near(0), "brush_strength": lambda v: float(v) > 0.6, "inspector_scroll": near(0)})


@scenario
def finger_sculpts_model():
    """One finger on the model sculpts after the hold; the camera stays still."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    return s, [], camera_still({"dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def spray_stroke_by_mouse():
    """A Spray stroke dabs as it goes and is one undo step."""
    s = Script()
    s.mouse_drag(line((740, 420), (880, 480), 14))
    return s, ["--script=set stroke spray"], camera_still({"dabs": lambda v: int(v) > 2, "undo_steps": near(1)})


@scenario
def shift_mid_stroke_lays_a_line():
    """Shift pressed mid-stroke lays the stroke again as a straight line, one undo step."""
    s = Script()
    s.add("move:720,420")
    s.wait(1)
    s.add("down")
    for x, y in [(750, 450), (780, 400), (810, 460)]:
        s.wait(1)
        s.add(f"move:{x},{y}")
    s.wait(1)
    s.add("key:shift")
    for x, y in [(840, 430), (870, 440), (900, 450)]:
        s.wait(1)
        s.add(f"move:{x},{y}")
    s.wait(1)
    s.add("up")
    s.add("keyup:shift")
    s.wait(3)
    return s, [], camera_still({"stroke_lines": near(1), "dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def rail_smooth_mid_stroke_lays_a_line_by_pen():
    """The rail's Smooth held down mid-stroke by the other hand turns a pen stroke into a
    straight line, as Shift does with a mouse."""
    s = Script()
    s.add("pnear")
    s.add("pdown:720,420")
    for x, y in [(750, 450), (780, 400)]:
        s.wait(1)
        s.add(f"pmove:{x},{y}")
    rail_hold(s, "smooth")
    for x, y in [(820, 440), (860, 430), (900, 450)]:
        s.wait(1)
        s.add(f"pmove:{x},{y}")
    s.wait(1)
    s.add("pup")
    s.wait(1)
    rail_lift(s)
    s.add("pfar")
    s.wait(3)
    return s, [], camera_still({"stroke_lines": near(1), "dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def join_strokes_by_pen():
    """With Join strokes on, a pen stroke pressed where the last one ended carries it on;
    one pressed far away does not."""
    s = Script()
    pen_stroke(s, line((720, 420), (800, 440), 8))
    pen_stroke(s, line((806, 442), (880, 460), 8))
    pen_stroke(s, line((700, 520), (760, 530), 6))
    return s, ["--script=set stroke_join on"], camera_still({"stroke_joins": near(1), "undo_steps": near(3)})


@scenario
def connected_from_the_palette_by_pen():
    """The palette's Connected only turns the switch on, and a pen stroke then sculpts as
    one undo step."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("connected only")
    s.press("Return")
    s.wait(4)
    pen_stroke(s, line((720, 420), (840, 460), 10))
    return s, [], camera_still({"brush_connected": near(1), "brush_lock_plane": near(0), "palette": near(0),
                                "dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


@scenario
def lock_plane_flatten_by_finger():
    """A finger Flatten stroke with Lock plane on sculpts as one undo step."""
    s = Script()
    s.fdrag(line((700, 430), (900, 470), 20))
    return s, ["--script=lock_plane on; brush flatten"], camera_still({"brush_lock_plane": near(1), "dabs": lambda v: int(v) > 0,
                                                              "undo_steps": near(1)})


@scenario
def roll_stroke_by_finger():
    """A Roll stroke by finger lays its dabs a brush width apart, so fewer than Dots does
    over the same path, and is one undo step."""
    s = Script()
    s.fdrag(line((700, 430), (900, 470), 20))
    return s, ["--script=set stroke roll"], camera_still({"dabs": lambda v: 0 < int(v) < 10, "undo_steps": near(1)})


@scenario
def drag_dot_stroke_by_finger():
    """A Drag dot stroke by finger slides its one stamp with the finger, a dab each frame it
    moves, and is one undo step."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    return s, ["--script=set stroke drag_dot"], camera_still({"dabs": lambda v: int(v) > 2, "undo_steps": near(1)})


@scenario
def stroke_section_shows_spray_and_colour_spray():
    """The brush bar's Stroke opens the Stroke section with its five modes and, on Spray, the
    Spread and Colour spray sliders; nothing moves."""
    s = Script()
    s.ftap(*UI["stroke"])
    s.wait(8)
    return s, ["--script=set stroke spray"], camera_still({"dabs": near(0), "bar_pop": is_text("stroke")})


@scenario
def finger_orbits_empty_space():
    """One finger on empty space turns the view, and a stroke started there keeps turning over the model."""
    s = Script()
    s.fdrag(past_slop((250, 400), (650, 400), 20))
    return s, ["--script=set orbit_style turntable"], {"dabs": near(0), "camera_pitch": near(0.35),
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
    return s, ["--script=set orbit_style free"], {"dabs": near(0)} | {k: near(v, 5e-3) for k, v in CAMERA0.items()}


@scenario
def orbit_full_turns_turntable():
    """Turntable: three turns right and one over the top come back to the start with no flip."""
    s = Script()
    for _ in range(3):
        s.fdrag(past_slop((150, 120), (150 + ORBIT_TURN, 120), 60))
    s.fdrag(past_slop((250, 80), (250, 80 + ORBIT_TURN), 60))
    return s, ["--script=set orbit_style turntable"], {"dabs": near(0)} | {k: near(v, 5e-3) for k, v in CAMERA0.items()}


@scenario
def orbit_default_is_turntable():
    """With no setting changed, a sideways drag on empty space turns about the up axis: the tilt and the horizon stay as they were, and a twist does not roll."""
    s = Script()
    s.fdrag(past_slop((150, 120), (350, 120), 20))
    s.wait(3)
    twist(s, math.radians(45))
    return s, [], {"dabs": near(0), "camera_yaw": near(wrap(0.6 - 200 * 0.008), 2e-3), "camera_pitch": near(0.35), "camera_roll": near(0)}


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
    return s, ["--script=set orbit_style free"], {"camera_roll": lambda v: math.radians(34) < float(v) < math.radians(45),
                                       "camera_distance": near(3.5, 0.05), "dabs": near(0)}


@scenario
def twist_wobble_rolls_nothing():
    """Two fingers turning less than the deadzone (a pinch's wobble) leave the roll alone."""
    s = Script()
    twist(s, math.radians(8))
    return s, ["--script=set orbit_style free"], {"camera_roll": near(0), "dabs": near(0)}


@scenario
def twist_rolls_nothing_in_turntable():
    """Turntable keeps the horizon level by default: a twist does not roll."""
    s = Script()
    twist(s, math.radians(45))
    return s, ["--script=set orbit_style turntable"], {"camera_roll": near(0), "dabs": near(0)}


def twist_path(s, turns, frames=20):
    """Two fingers 100 points apart about (300, 300), turning clockwise through each of `turns` (radians from where they land) in one touch."""
    mid, r = (300, 300), 50
    for i in (0, 1):
        s.add(f"fdown:{i}:{mid[0] + (r if i else -r):g},{mid[1]:g}")
    s.wait(2)
    a0 = 0
    for turn in turns:
        for k in range(1, frames + 1):
            a = a0 + (turn - a0) * k / frames
            for i, sign in ((0, -1), (1, 1)):
                s.add(f"fmove:{i}:{mid[0] + sign * r * math.cos(a):g},{mid[1] + sign * r * math.sin(a):g}")
            s.wait(1)
        a0 = turn
    for i in (0, 1):
        s.add(f"fup:{i}")
    s.wait(3)


@scenario
def turntable_twist_rolls_when_unlocked():
    """With Twist two fingers to roll the turntable on, twisting 45 degrees rolls the view with the fingers, less the 10 degree deadzone, about the point between them, and the turn stays as it was."""
    s = Script()
    twist(s, math.radians(45))
    return s, ["--script=set turntable_roll on"], {"camera_roll": lambda v: math.radians(30) < float(v) < math.radians(45), "camera_yaw": near(0.6),
                                                   "camera_pitch": near(0.35), "camera_distance": near(3.5, 0.05), "camera_target": lambda v: v != "0.0000,0.0000,0.0000", "dabs": near(0)}


@scenario
def turntable_twist_back_holds_level():
    """Twisted 40 degrees and back to 12 in one touch, the unlocked turntable's roll lands within the level detent and holds exactly level."""
    s = Script()
    twist_path(s, [math.radians(40), math.radians(12)])
    return s, ["--script=set turntable_roll on"], {"camera_roll": near(0, 1e-5), "dabs": near(0)}


@scenario
def rolled_turntable_drag_follows_the_finger():
    """Rolled about 80 degrees, the turntable reads a drag along the rolled screen: one finger dragged 100 points down on empty space turns the model about its up axis (the yaw), nearly not the tilt, and the roll stays."""
    s = Script()
    twist(s, math.radians(90))
    s.wait(4)
    s.fdrag(past_slop((1000, 150), (1000, 250), 20))
    s.wait(3)
    return s, ["--script=set turntable_roll on"], {"camera_roll": lambda v: math.radians(70) < float(v) < math.radians(90), "camera_pitch": near(0.35, 0.2),
                                                   "camera_yaw": lambda v: abs(float(v) - 0.6) > 0.6, "dabs": near(0)}


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
    return s, ["--script=set finger_model orbit; set orbit_style turntable"], {"camera_yaw": near(wrap(0.6 - 100 * 0.008), 2e-3), "dabs": lambda v: int(v) > 0, "undo_steps": near(1)}


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
    s.fingers([(1376, 600), (900, 300)], [(0, 0), (0, 0)], 1)
    return s, [], camera_still({"undo_steps": near(1), "redo_steps": near(0)})


@scenario
def three_finger_size():
    """Three fingers dragged up grow the brush."""
    s = Script()
    s.fingers([(300, 600), (380, 600), (460, 600)], [(0, -200)] * 3, 20)
    return s, [], {"brush_radius_px": lambda v: float(v) > 100, "camera_distance": near(3.5, 0.2), "dabs": near(0)}


@scenario
def three_finger_focal_shift():
    """Three fingers dragged sideways set the focal shift, 200 points right taking it near +100 (less the slop that decides the way), and leave the strength."""
    s = Script()
    s.fingers([(300, 600), (300, 680), (300, 760)], [(200, 0)] * 3, 20)
    return s, [], {"brush_focal": lambda v: 90 <= float(v) <= 100, "brush_strength": near(0.5, 1e-3), "brush_radius_px": near(60),
                   "camera_distance": near(3.5, 0.2), "dabs": near(0)}


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
    return s, ["--script=set orbit_style turntable"], {"dabs": near(0), "camera_yaw": near(wrap(0.6 - 200 * 0.008), 2e-3)}


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
    return s, ["--script=set orbit_style turntable"], {"dabs": lambda v: int(v) > 0, "undo_steps": near(1),
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
    return s, ["--script=set orbit_style turntable"], {
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
    return s, ["--script=set orbit_style turntable; set orbit_pivot centre"], {
        "pivot_source": lambda v: v == "centre", "camera_target": lambda v: v == "0.0000,0.0000,0.0000",
        "camera_yaw": near(wrap(0.6 - 200 * 0.008), 2e-3)}


def three_start(st):
    """The camera THREE starts with: the default turn, framing the three spheres in a row
    along x (at 0, 2.25 and 4.5) about the middle one. An orbit keeps the distance."""
    return {"camera_yaw": 0.6, "camera_pitch": 0.35, "camera_roll": 0, "camera_distance": st["camera_distance"], "camera_target": "2.25,0,0"}


@scenario
def orbit_about_the_selection_setting():
    """With Turn about set to the selected objects, an orbit turns about the selected sphere's middle, which stays put on screen."""
    s = Script()
    s.fdrag(past_slop((250, 120), (450, 120), 20))
    def at_selected(st):
        x, y, z = (float(v) for v in st["transform"].split(",")[:3])
        return math.dist(pivot(st), (x, y, z)) < 0.05 and abs(x) > 0.5
    return s, THREE + ["--script=set orbit_style turntable; set orbit_pivot selection; select 3"], {
        "dabs": near(0), "pivot_source": lambda v: v == "selection", "@pivot_at_selected": at_selected,
        "@pivot_stays_put": lambda st: math.dist(on_screen(st, pivot(st)), on_screen(three_start(st), pivot(st))) < 2e-3}


@scenario
def orbit_about_the_whole_scene_setting():
    """With Turn about set to the whole scene, an orbit turns about the middle of all three spheres, not the selected one."""
    s = Script()
    s.fdrag(past_slop((250, 120), (450, 120), 20))
    def not_selected(st):
        x, y, z = (float(v) for v in st["transform"].split(",")[:3])
        return math.dist(pivot(st), (x, y, z)) > 0.5
    return s, THREE + ["--script=set orbit_style turntable; set orbit_pivot scene; select 3"], {
        "dabs": near(0), "pivot_source": lambda v: v == "scene", "@pivot_not_the_selected": not_selected,
        "@pivot_stays_put": lambda st: math.dist(on_screen(st, pivot(st)), on_screen(three_start(st), pivot(st))) < 2e-3}


@scenario
def orbit_about_the_air_under_the_pointer():
    """With Turn about the pointer and the air pivot on, a drag off the model turns about the point under the press, as deep as the view's middle."""
    s = Script()
    s.fdrag(past_slop((250, 400), (450, 400), 20))
    return s, ["--script=set orbit_style turntable; set orbit_pivot pointer; set air_pivot on"], {
        "dabs": near(0), "pivot_source": lambda v: v == "air", "camera_target": lambda v: v != "0.0000,0.0000,0.0000",
        "@pivot_left_of_the_sphere": lambda st: on_screen(None, pivot(st))[0] < -0.3,
        "@pivot_stays_put": lambda st: math.dist(on_screen(st, pivot(st)), on_screen(None, pivot(st))) < 2e-3}


@scenario
def wheel_zooms_toward_the_pointer_setting():
    """With Wheel zooms toward the pointer on, three notches over the sphere's upper right zoom in and move the view's middle toward it."""
    s = Script()
    s.add("move:1000,300")
    s.wait(1)
    s.add("wheel:3")
    s.wait(3)
    return s, ["--script=set wheel_toward on"], {
        "dabs": near(0), "camera_distance": lambda v: float(v) < 3.0,
        "@target_moved": lambda st: math.dist(tuple(float(v) for v in st["camera_target"].split(",")), (0, 0, 0)) > 0.05}


@scenario
def wheel_zooms_toward_the_middle_by_default():
    """By default the same three notches zoom toward the middle: the view's middle stays where it was."""
    s = Script()
    s.add("move:1000,300")
    s.wait(1)
    s.add("wheel:3")
    s.wait(3)
    return s, [], {"dabs": near(0), "camera_distance": lambda v: float(v) < 3.0, "camera_target": is_text("0.0000,0.0000,0.0000")}


def zoomed_in(s):
    """Eight wheel notches in: the sphere fills the whole window, with no empty space left."""
    s.add("move:800,450")
    s.wait(1)
    s.add("wheel:8")
    s.wait(3)


def edge_drags(s):
    """A finger along the bottom edge and the pen along the top one (under the top bar),
    both over the model, where no panel is, each 200 points sideways."""
    zoomed_in(s)
    s.fdrag(past_slop((250, 868), (450, 868), 20))
    s.add("pnear")
    s.wait(1)
    s.add("pdown:260,82")
    for x, y in past_slop((260, 82), (460, 82), 20)[1:]:
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
    return s, ["--script=set orbit_style turntable"], {"dabs": near(0), "undo_steps": near(0),
                                            "camera_yaw": near(wrap(0.6 - 400 * 0.008), 3e-3),
                                            "camera_distance": near(3.5 * 0.88 ** 8, 1e-3)}


@scenario
def edge_off_sculpts():
    """With the safe zone off, the same drags at the edges sculpt the model and leave the view alone."""
    s = Script()
    edge_drags(s)
    return s, ["--script=set orbit_style turntable; set edge_orbit off"], {"dabs": lambda v: int(v) > 0, "undo_steps": near(2),
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
    s.add("move:490,330")
    s.wait(4)
    return s, [], {"cursor_hit": near(1), "cursor_normal": normal_near(sphere_normal_under(490, 330), 8), "dabs": near(0)}


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


def macros_folder():
    """Where the scenario's macros are kept: beside its settings file, named after it."""
    return settings_file()[:-len(".txt")] + "-macros"


def library_folder():
    """Where the scenario's library is kept: beside its settings file, named after it."""
    return settings_file()[:-len(".txt")] + "-library"


def link_folder():
    """The scenario's Blender link folder: beside its settings file, named after it."""
    return settings_file()[:-len(".txt")] + "-link"


def plugins_folder():
    """The scenario's script plugins folder: beside its settings file, named after it."""
    return settings_file()[:-len(".txt")] + "-plugins"


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
    s.ftap(*{"interface": (1187, 158), "camera": (1261, 158), "touch": (1334, 158), "keys": (1408, 158), "performance": (1481, 158)}[tab])
    s.wait(10)


@scenario
def settings_scroll_and_persist():
    """Settings opens from the menu, a switch changes at a tap, the body scrolls from the first touch on a slider, and Done remembers it."""
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    s = Script()
    open_settings(s, "camera")
    s.ftap(1495, 492)  # Invert sideways orbit
    s.wait(4)
    s.fdrag(line((1246, 447), (1251, 147), 20))  # from the Orbit speed slider, upward
    s.wait(16)
    s.ftap(1427, 766)  # Done
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], camera_still({
        "dabs": near(0), "settings_open": near(0), "settings_scroll": lambda v: float(v) > 100,
        "@saved": saved(invert_x="1", zoom_speed="1", orbit_speed="1")})


@scenario
def settings_reset_everything():
    """Reset everything takes a second tap, then puts every category back."""
    s = Script()
    with open(settings_file(), "w") as f:
        f.write("orbit_speed 2\ninvert_wheel 1\nfinger_model orbit\nstats 1\n")
    open_settings(s, "touch")
    s.ftap(1240, 766)  # Reset everything: arms it
    s.wait(10)
    s.ftap(1240, 766)  # Tap again to reset all
    s.wait(4)
    s.ftap(1427, 766)  # Done
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
    s.ftap(1240, 766)
    s.wait(4)
    s.ftap(1427, 766)  # Done
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
    s.ftap(1379, 158)  # the Touch tab
    s.wait(1)
    s.fdrag(line((1246, 600), (1251, 300), 15))
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
        s.ftap(1379, 158)
        s.wait(2)
        s.fdrag(line((1246, 600), (1251, 300), 15))
        s.wait(4)
        s.ftap(1427, 766)  # Done
        s.wait(10)
    return s, [], camera_still({"dabs": near(0), "settings_open": near(0), "settings_scroll": lambda v: float(v) > 100})


@scenario
def changed_touch_setting_takes_effect():
    """Settings > Touch > On the model > Turns the view, then a finger on the model orbits and sculpts nothing; it is saved."""
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    s = Script()
    open_settings(s, "touch")
    s.ftap(1429, 251)  # Turns the view
    s.wait(4)
    s.ftap(1427, 766)  # Done
    s.wait(10)
    s.fdrag(past_slop((760, 430), (860, 430), 20))
    return s, [f"--settings-file={settings_file()}", "--script=set orbit_style turntable"], {
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


# The Mask section's More options row, where the tray shows it at 1600 x 900: with no mask
# command run yet, and after one, whose "Last:" line moves it down.
MASK_MORE = (1275, 655)
MASK_MORE_AFTER_LAST = (1275, 679)


def select_page(s):
    """The palette's Object: Mask: the tray on the Mask section."""
    palette_run(s, "object mask")
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
    s.ftap(*MASK_MORE_AFTER_LAST)
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


# The Mask by Apply button once the tray is dragged 600 px up, with every option shown.
MASK_BY_APPLY = (1377, 730)


@scenario
def mask_by_from_the_section():
    """With Show every option on, the Mask section's Mask by Apply masks what faces away from the view as one undo step."""
    with open(settings_file(), "w") as f:
        f.write("all_options 1\nmask_by_kind facing_away\n")
    s = Script()
    select_page(s)
    s.fdrag(line((1380, 760), (1380, 160), 30))
    s.wait(20)
    s.ftap(*MASK_BY_APPLY)
    s.wait(10)
    return s, [f"--settings-file={settings_file()}"], camera_still({
        "dabs": near(0), "undo_steps": near(1), "mask_by": is_text("facing_away"), "last_op": is_text("Mask_by_facing_away"),
        "masked": near(1), "mask_mean": lambda v: 0.3 < float(v) < 0.7})


# Hide, clip and slice's Grow at 1600 x 900 with every option shown.
HIDE_GROW = (1303, 620)


@scenario
def grow_visibility_from_the_section():
    """With half the sphere hidden and Show every option on, a finger tap on Hide, clip and slice's Grow shows one ring more as one undo step."""
    with open(settings_file(), "w") as f:
        f.write("all_options 1\n")
    s = Script()
    palette_run(s, "object hide clip")
    s.wait(10)
    s.ftap(*HIDE_GROW)
    s.wait(10)
    # hide x hides 40,960 of the 81,920 triangles; a ring more shows about 400 of them.
    return s, [f"--settings-file={settings_file()}", "--script=hide x"], camera_still({
        "dabs": near(0), "undo_steps": near(1), "hidden_triangles": lambda v: 39000 < int(v) < 40900, "action_bar": is_text("hidden")})


# The Layers section's Duplicate at 1600 x 900 with one layer and every option shown.
LAYER_DUPLICATE = (1303, 541)


@scenario
def layer_duplicate_from_the_section():
    """With a layer and Show every option on, a finger tap on the Layers section's Duplicate adds a hidden copy as one undo step (the script's layer is no step of the run's)."""
    with open(settings_file(), "w") as f:
        f.write("all_options 1\n")
    s = Script()
    palette_run(s, "object layers")
    s.wait(10)
    s.ftap(*LAYER_DUPLICATE)
    s.wait(10)
    return s, [f"--settings-file={settings_file()}", "--script=new_layer"], camera_still({"dabs": near(0), "layers": near(2), "undo_steps": near(1)})


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
                                                         "@layout": clear_of("coach", "top_bar", "inspector", "brush_bar", "view_bar")}


PRESET_SAVE_NEW = (1302, 309)  # the Preset section's Save as preset, on a plain brush
PRESET_NAME = (1378, 309)  # on a preset: its name field
PRESET_REVERT = (1451, 363)


def save_a_preset(s):
    palette_run(s, "brush preset")
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
    """A finger taps the tray's Object palette, then its Mask section; the Brush palette and back keep Mask, and nothing is sculpted."""
    s = Script()
    s.ftap(*UI["list_object"])
    s.wait(6)
    s.ftap(*TRAY_OBJECT_MASK)
    s.wait(6)
    s.ftap(*UI["list_brush"])
    s.wait(6)
    s.ftap(*UI["list_object"])
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "inspector_tab": is_text("object"), "object_page": is_text("Select"), "tray_section": is_text("Mask")})


@scenario
def nav_head_tap_looks_from_that_side():
    """A click on the middle of the navigation head looks from the side facing the viewer (the front, from the start's view), then a finger's tap on its right side looks from the right; nothing is sculpted."""
    s = Script()
    s.add("move:%d,%d" % UI["nav_head"])
    s.wait(2)
    s.add("down")
    s.wait(2)
    s.add("up")
    s.wait(4)
    x, y = UI["nav_head"]
    s.ftap(x + 18, y)
    s.wait(4)
    return s, [], {"dabs": near(0), "undo_steps": near(0), "nav_taps": near(2),
                   "camera_yaw": near(math.pi / 2, 1e-3), "camera_pitch": near(0), "camera_distance": near(3.5)}


@scenario
def nav_head_drag_turns_the_view():
    """A finger dragged from the navigation head turns the view as dragging empty space does, and snaps to no side when let go."""
    s = Script()
    x, y = UI["nav_head"]
    s.fdrag([(x, y)] + [(x - 10 * k, y) for k in range(1, 21)])
    return s, ["--script=set orbit_style turntable"], {"dabs": near(0), "undo_steps": near(0), "nav_taps": near(0), "camera_pitch": near(0.35),
                                                      "camera_yaw": lambda v: abs(float(v) - 0.6) > 1}


@scenario
def show_where_marks_the_control():
    """Search's Shift+Enter on Blur mask opens the tray on the Object palette's Mask section with its More options open and marks the Blur button; nothing runs or is sculpted."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("blur mask")
    s.press("Return", ("shift",))
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "undo_steps": near(0), "palette": near(0), "palette_runs": near(0), "inspector_tab": is_text("object"),
                                "tray_section": is_text("Mask"), "more": is_text("mask"), "tray_marked": near(1)})


@scenario
def long_press_a_search_row_shows_where():
    """A finger's long press on search's first row (Layers' New layer) shows where it lives rather than running it: the Object palette's Layers section."""
    s = Script()
    s.ftap(*UI["search"])
    s.wait(4)
    s.type("new layer")
    s.wait(4)
    long_press(s, *UI["palette_row1"])
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "undo_steps": near(0), "palette_runs": near(0), "tray_section": is_text("Layers"), "tray_marked": near(1)})


@scenario
def search_opens_a_section_by_name():
    """Typing a section's name in search and Enter opens the tray on it: Polypaint, from the Brush palette."""
    s = Script()
    palette_run(s, "object polypaint")
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "palette_last": is_text("Show_Section:Paint"), "inspector_tab": is_text("object"), "tray_section": is_text("Paint")})


# The Mask row of the tray's list with the Object palette open.
TRAY_OBJECT_MASK = (1110, 542)


@scenario
def inspector_tab_switch_then_scroll():
    """After switching the tray to the Object palette's Mask section (every option shown), a first finger drag over its values scrolls it."""
    s = Script()
    write_settings("all_options 1\n")
    s.ftap(*UI["list_object"])
    s.wait(6)
    s.ftap(*TRAY_OBJECT_MASK)
    s.wait(6)
    s.fdrag(line(MASK_STEPS, (MASK_STEPS[0] + 5, MASK_STEPS[1] - 220), 20))
    return s, [f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "inspector_scroll": lambda v: float(v) > 50, "selected": near(0)})


def saved_line(line):
    """A check that the settings file the app wrote holds `line` (for keys with several lines)."""
    def ok(_):
        return os.path.exists(settings_file()) and line in open(settings_file()).read().splitlines()
    return ok


# The inspector's title bar at 1600 x 900: its title, Minimise and Close.
INSPECTOR_TITLE, INSPECTOR_MINIMISE, INSPECTOR_CLOSE = (1286, 103), (1450, 103), (1500, 103)
# The Stats window's title, where it starts (Settings > Performance or F11 opens it).
STATS_TITLE = (150, 148)


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
    s.fdrag(line(MASK_STEPS, (MASK_STEPS[0] + 5, MASK_STEPS[1] - 220), 22))
    write_settings("all_options 1\n")
    return s, ["--script=show_section mask", f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "window_inspector": lambda v: v.startswith("1,0,"),
                                "inspector_scroll": lambda v: float(v) > 50})


@scenario
def window_close_and_reopen():
    """Close hides the inspector; the Inspector button on the right bar brings it back."""
    s = Script()
    s.ftap(*INSPECTOR_CLOSE)
    s.wait(10)
    s.ftap(*UI["inspector"])
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


# The docked tray's Panel options button, beside Minimise, and the panel menu's Dock on the
# left row it opens (panels.odin).
PANEL_OPTIONS = (1400, 103)
PANEL_MENU_DOCK_LEFT = (1440, 184)


@scenario
def docked_tray_drags_out_to_float():
    """A finger drags the docked tray by its header past the slop: it leaves the right column and floats on under the finger."""
    s = Script()
    s.fdrag(line(INSPECTOR_TITLE, (700, 300), 20))
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "column_right": is_text("none"), "panel_moves": near(1),
                                "window_inspector": lambda v: v == "1,0,460,265"})


@scenario
def stats_dropped_on_the_right_column_docks_it():
    """Floating Stats dragged over the right column, under the tray, docks there when the finger lifts."""
    with open(settings_file(), "w") as f:
        f.write("stats 1\n")
    s = Script()
    s.fdrag(line(STATS_TITLE, (1290, 650), 30))
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], camera_still({
        "dabs": near(0), "column_right": is_text("inspector,stats"), "panel_moves": near(1),
        "@saved": saved_line("column right Inspector Stats")})


@scenario
def panel_menu_docks_the_tray_on_the_left():
    """Panel options on the docked tray, then Dock on the left: the tray moves to the left column and the menu closes."""
    s = Script()
    s.ftap(*PANEL_OPTIONS)
    s.wait(10)
    s.ftap(*PANEL_MENU_DOCK_LEFT)
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "column_left": is_text("inspector"), "column_right": is_text("none"),
                                "panel_menu": near(0)})


@scenario
def pinned_sections_stack_in_the_right_column():
    """Pin as a panel (here from a script) docks Layers and then Camera under the tray, each its own panel."""
    s = Script()
    s.add("move:800,450")
    s.wait(10)
    return s, ["--script=pin_section layers; pin_section camera"], camera_still({
        "dabs": near(0), "column_right": is_text("inspector,layers,camera"),
        "panel_pins": is_text("layers,camera")})


# The top bar's workspace switcher at 1600 x 900, just after Export, and the rows of the
# menu it opens: the four built-ins, then Save, Save as new, Export, Import, Revert and Reset.
WORKSPACE_CHIP = (275, 26)
WORKSPACE_ROWS = {"sculpt": 106, "focus": 150, "inspect": 194, "studio": 238, "save": 283, "save_as": 327, "export": 371, "import": 415, "revert": 459, "reset": 503}
# With the brush bar and the view bar hidden (Focus), Undo and Search in the top bar.
TOP_UNDO, TOP_SEARCH = (266, 26), (1216, 26)


@scenario
def workspace_switcher_picks_focus():
    """The switcher's menu, then Focus: the side bars and the action bar go, the tray closes, and the menu with them."""
    s = Script()
    s.ftap(*WORKSPACE_CHIP)
    s.wait(10)
    s.ftap(WORKSPACE_CHIP[0], WORKSPACE_ROWS["focus"])
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "workspace": is_text("Focus"), "zones_hidden": is_text("brush_bar,view_bar,action_bar"),
                                "workspace_menu": near(0), "window_inspector": lambda v: v.startswith("0,"), "workspace_modified": near(0)})


@scenario
def a_closed_panel_marks_the_workspace_and_revert_puts_it_back():
    """Closing the tray marks Sculpt as changed; Revert in the switcher's menu opens it again and clears the mark."""
    s = Script()
    s.ftap(*INSPECTOR_CLOSE)
    s.wait(10)
    s.ftap(*WORKSPACE_CHIP)
    s.wait(10)
    s.ftap(WORKSPACE_CHIP[0], WORKSPACE_ROWS["revert"])
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "workspace": is_text("Sculpt"), "workspace_modified": near(0),
                                "window_inspector": lambda v: v.startswith("1,")})


@scenario
def a_changed_workspace_shows_its_mark():
    """Closing the tray leaves Sculpt marked as changed."""
    s = Script()
    s.ftap(*INSPECTOR_CLOSE)
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "workspace_modified": near(1)})


@scenario
def focus_moves_undo_and_search_to_the_top_bar():
    """In Focus a stroke, then Undo in the top bar takes it back, and Search there opens the palette."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    s.wait(4)
    s.ftap(*TOP_UNDO)
    s.wait(4)
    s.ftap(*TOP_SEARCH)
    s.wait(10)
    return s, ["--script=workspace focus"], {"undo_steps": near(0), "redo_steps": near(1), "palette": near(1), "workspace": is_text("Focus")}


# The Lens top bar at 1600 x 900 (kit_top_lens.odin): Menu, Undo and Redo at the left, the
# workspace pill's segments and its "+" in the middle, the Search field at the right.
LENS = ["--chrome=lens"]
LENS_MENU, LENS_UNDO, LENS_REDO = (33, 26), (217, 26), (267, 26)
LENS_PILL = {"sculpt": (617, 26), "focus": (684, 26), "inspect": (755, 26), "studio": (828, 26), "plus": (884, 26)}
LENS_SEARCH = (1340, 26)
# The Lens menu's first row, Home.
LENS_MENU_HOME = (120, 82)


@scenario
def lens_pill_switches_workspace():
    """In the Lens top bar a tap on Focus in the workspace pill switches to Focus, with no menu."""
    s = Script()
    s.ftap(*LENS_PILL["focus"])
    s.wait(10)
    return s, LENS, camera_still({"dabs": near(0), "chrome": is_text("lens"), "workspace": is_text("Focus"), "workspace_menu": near(0), "workspace_switches": near(1)})


@scenario
def lens_pill_current_segment_and_plus_open_the_menu():
    """A tap on the current workspace in the pill opens the switcher's menu, a second closes it, and "+" opens it again."""
    s = Script()
    s.ftap(*LENS_PILL["sculpt"])
    s.wait(10)
    s.ftap(*LENS_PILL["sculpt"])
    s.wait(10)
    s.ftap(*LENS_PILL["plus"])
    s.wait(10)
    return s, LENS, camera_still({"dabs": near(0), "workspace": is_text("Sculpt"), "workspace_menu": near(1), "workspace_switches": near(0)})


@scenario
def lens_search_field_opens_the_palette():
    """A tap on the Lens top bar's Search field opens the command palette."""
    s = Script()
    s.ftap(*LENS_SEARCH)
    s.wait(10)
    return s, LENS, camera_still({"dabs": near(0), "palette": near(1)})


@scenario
def lens_undo_and_redo_in_the_top_bar():
    """A stroke, then Undo in the Lens top bar takes it back and Redo puts it back; the file block says the changes are not saved."""
    s = Script()
    s.fdrag(line((760, 430), (860, 470), 20))
    s.wait(4)
    s.ftap(*LENS_UNDO)
    s.wait(10)
    s.ftap(*LENS_REDO)
    s.wait(10)
    return s, LENS, {"undo_steps": near(1), "redo_steps": near(0), "file_status": is_text("Unsaved%20changes")}


@scenario
def lens_file_block_says_saved():
    """A scene just saved and opened again, the Lens top bar's file block says "Saved just now"; a fresh scene says "Not saved"."""
    first, args, checks = first_save()
    return Steps([(first, args, checks), (Script(), LENS + [f"--open={scene_file()}"], {"file_status": is_text("Saved%20just%20now")}),
                  (Script(), LENS, {"file_status": is_text("Not%20saved")})])


@scenario
def lens_menu_heads_with_home():
    """The Lens menu's first row is Home, which shows the Home screen."""
    s = Script()
    s.ftap(*LENS_MENU)
    s.wait(10)
    s.ftap(*LENS_MENU_HOME)
    s.wait(10)
    return s, LENS, {"home": near(1), "menu": near(0)}


def shift_left_of_middle(v):
    x, y = (float(c) for c in v.split(","))
    return x < -0.2 and abs(y) < 0.2


@scenario
def lens_view_starts_in_the_free_area():
    """In Lens the model is drawn in the middle of the room the tray and bars leave: left of the window's middle, the camera itself unmoved."""
    s = Script()
    s.wait(10)
    return s, LENS, camera_still({"camera_shift": shift_left_of_middle})


@scenario
def lens_focus_fits_the_free_area():
    """F (Focus selected) in Lens keeps the model in the free area and backs the camera off to fit its shorter side."""
    s = Script()
    s.wait(6)
    s.press("f")
    s.wait(6)
    return s, LENS, {"camera_shift": shift_left_of_middle, "camera_distance": lambda v: 3.6 < float(v) < 7.1}


@scenario
def classic_view_has_no_shift():
    """The Classic layout draws the model in the middle of the window, as it always did."""
    s = Script()
    s.wait(6)
    s.press("f")
    s.wait(6)
    return s, [], {"camera_shift": is_text("0.000,0.000"), "camera_distance": near(3.5)}


@scenario
def lens_tab_hides_the_interface():
    """Tab in Lens is Clean view: every control goes, the dial stays."""
    s = Script()
    s.press("Tab")
    s.wait(10)
    return s, LENS, camera_still({"clean_view": near(1), "window_inspector": lambda v: v.startswith("1,")})


@scenario
def lens_escape_brings_the_interface_back():
    """Escape leaves Clean view."""
    s = Script()
    s.press("Tab")
    s.wait(6)
    s.press("Escape")
    s.wait(6)
    return s, LENS, camera_still({"clean_view": near(0)})


@scenario
def four_finger_tap_hides_the_interface():
    """A four-finger tap is Clean view, its default gesture."""
    s = Script()
    s.fingers([(500, 300), (560, 300), (620, 300), (680, 300)], [(0, 0)] * 4, 2)
    s.wait(10)
    return s, LENS, camera_still({"clean_view": near(1)})


@scenario
def a_stroke_under_the_tray_fades_it():
    """A stroke that starts on the model and runs under the tray fades the tray while it lasts; the stroke goes on under it."""
    s = Script()
    s.fdrag(line((600, 450), (1250, 420), 30))
    s.wait(10)
    return s, LENS, {"panels_faded": lambda v: int(v) >= 1, "dabs": lambda v: int(v) > 0}


# Lens's chrome round the view at 1440x900: the island's Size slider, the view chips,
# the view rail's buttons and the mini view's picture (with the thumbnail on and a Front
# camera, it stands at the bottom of the pen side).
LENS_ISLAND_SIZE = (42, 380)
LENS_CHIP_CAMERA, LENS_CHIP_OBJECT = (75, 77), (120, 125)
LENS_RAIL = {"layout": (1403, 133), "passes": (1403, 181), "camera": (1403, 229), "lights": (1403, 421), "mini": (1403, 470)}
LENS_1440 = LENS + ["--width=1440", "--height=900"]
LENS_MINI = ["--script=set thumbnail 1;set second_camera Front"]
LENS_MINI_PICTURE = (1285, 800)


def rect_x(lo, hi):
    """A rect stat (x,y,w,h) whose x lies in [lo, hi]."""
    return lambda v: lo <= float(v.split(",")[0]) <= hi


@scenario
def lens_rail_holds_the_view_tools():
    """Lens shows the off-hand island at the left, the chips over the view's top-left corner and the view rail's eight view tools; nothing moves the camera."""
    s = Script()
    s.wait(10)
    rail = "View_Layout_Menu,Pass_Menu,Camera_Menu,Focus_Selected,Symmetry_X,Wireframe,Show_Section:Lights,Thumbnail"
    return s, LENS_1440, camera_still({"view_rail": is_text(rail), "island": rect_x(8, 16), "chips": lambda v: float(v.split(",")[0]) < 20})


@scenario
def lens_island_drag_raises_the_size():
    """A finger dragged up the island's Size slider raises the brush size by the drag, without sculpting."""
    s = Script()
    s.fdrag(line(LENS_ISLAND_SIZE, (LENS_ISLAND_SIZE[0], LENS_ISLAND_SIZE[1] - 40), 10))
    return s, LENS_1440, camera_still({"brush_radius_px": lambda v: float(v) > 70, "dabs": near(0)})


@scenario
def lens_camera_chip_opens_the_camera_menu():
    """A tap on the camera chip opens the Camera menu under it."""
    s = Script()
    s.ftap(*LENS_CHIP_CAMERA)
    s.wait(10)
    return s, LENS_1440, camera_still({"bar_pop": is_text("camera")})


@scenario
def lens_object_chip_opens_the_scene_palette():
    """A tap on the object chip opens the stack's Scene card."""
    s = Script()
    s.ftap(*LENS_CHIP_OBJECT)
    s.wait(10)
    return s, LENS_1440, camera_still({"inspector_tab": is_text("scene"), "window_inspector": lambda v: v.startswith("1,"), "stack": lambda v: "Scene+" in v.split(",")})


@scenario
def lens_rail_opens_beside_itself():
    """The rail's Passes and Lights open beside the rail, and View layout its menu of grids."""
    def run(name, checks):
        s = Script()
        s.ftap(*LENS_RAIL[name])
        s.wait(10)
        return (s, LENS_1440, camera_still(checks))
    return Steps([run("passes", {"pass_menu": near(1)}), run("lights", {"bar_pop": is_text("lights")}), run("layout", {"bar_pop": is_text("view_layout")})])


@scenario
def lens_rail_mini_view_turns_it_on():
    """The rail's Mini view shows the second view as the mini view at the pen side's bottom."""
    s = Script()
    s.ftap(*LENS_RAIL["mini"])
    s.wait(10)
    return s, LENS_1440, camera_still({"thumbnail": near(1), "mini": rect_x(1150, 1250)})


@scenario
def lens_mini_view_tap_swaps_the_cameras():
    """A tap on the mini view's picture gives the main view its Front camera, and a second tap swaps back."""
    s = Script()
    s.ftap(*LENS_MINI_PICTURE)
    s.wait(10)
    second = Script()
    second.ftap(*LENS_MINI_PICTURE)
    second.wait(10)
    second.ftap(*LENS_MINI_PICTURE)
    second.wait(10)
    return Steps([(s, LENS_1440 + LENS_MINI, {"mini_swaps": near(1), "camera_ortho": near(1), "second_camera": is_text("Free")}),
                  (second, LENS_1440 + LENS_MINI, camera_still({"mini_swaps": near(2), "camera_ortho": near(0)}))])


@scenario
def lens_left_handed_mirrors_the_chrome():
    """Left-handed, the island and the chips go to the right and the rail to the left; the model moves right of the middle."""
    s = Script()
    s.wait(10)
    return s, LENS_1440 + ["--script=set left_handed 1"], camera_still({"island": rect_x(1360, 1376), "chips": lambda v: float(v.split(",")[0]) > 900, "camera_shift": lambda v: float(v.split(",")[0]) > 0.2})


# The Lens shelf at 1440 x 900 (lens_shelf.odin): its tiles, All, the page names under it, and
# in the brush picker the Paint page and the Draw and Inflate cards.
LENS_SHELF = {"clay": (396, 830), "draw": (459, 830), "layer": (972, 830), "all": (1044, 830)}
LENS_SHELF_PAGES = {"sculpt": (633, 883), "paint": (693, 883), "move": (752, 883), "curve": (813, 883)}
LENS_SHEET = {"paint": (839, 120), "draw": (525, 320), "inflate": (525, 440)}
LENS_SHELF_SCULPT = "Brush:Clay,Brush:Draw,Brush:Smooth,Brush:Inflate,Brush:Pinch,Brush:Crease,Brush:Grab,Brush:Flatten,Brush:Mask,Brush:Layer"


@scenario
def lens_shelf_tap_picks_a_brush():
    """A tap on a shelf tile picks its brush, and nothing else opens."""
    s = Script()
    s.ftap(*LENS_SHELF["clay"])
    s.wait(10)
    return s, LENS_1440, camera_still({"brush_kind": is_text("clay"), "shelf_quick": near(0), "brush_sheet": near(0), "dabs": near(0)})


@scenario
def lens_shelf_long_press_shows_quick_settings():
    """A long press on a shelf tile picks its brush and shows its quick settings above it."""
    s = Script()
    s.ftap(*LENS_SHELF["clay"], hold=LONG_PRESS_FRAMES)
    s.wait(10)
    return s, LENS_1440, camera_still({"brush_kind": is_text("clay"), "shelf_quick": near(1), "dabs": near(0)})


@scenario
def lens_shelf_page_names_turn_the_page():
    """A tap on Paint under the shelf turns it to the Paint page, whose first tile is the Paint brush."""
    s = Script()
    s.ftap(*LENS_SHELF_PAGES["paint"])
    s.wait(10)
    return s, LENS_1440, camera_still({"shelf_page": is_text("Paint"), "shelf_turns": near(1),
                                       "shelf": lambda v: v.startswith("Brush:Paint,Brush:Mask,Brush:Smooth,Colors_Card")})


@scenario
def lens_shelf_all_opens_the_picker():
    """All opens the brush picker over the shelf; a tap on a card picks it and closes the picker; the picker's Paint turns the shelf too."""
    def run(card):
        s = Script()
        s.ftap(*LENS_SHELF["all"])
        s.wait(10)
        if card:
            s.ftap(*LENS_SHEET["inflate"])
            s.wait(10)
            return s, LENS_1440, camera_still({"brush_sheet": near(0), "brush_kind": is_text("inflate"), "dabs": near(0)})
        s.ftap(*LENS_SHEET["paint"])
        s.wait(10)
        return s, LENS_1440, camera_still({"brush_sheet": near(1), "shelf_page": is_text("Paint"), "dabs": near(0)})
    return Steps([run(False), run(True)])


@scenario
def lens_picker_card_dragged_onto_a_tile_keeps_it():
    """A card dragged from the picker onto the shelf's last tile takes its place there; the picker stays open and nothing is sculpted."""
    s = Script()
    s.ftap(*LENS_SHELF["all"])
    s.wait(10)
    s.fdrag(line(LENS_SHEET["inflate"], LENS_SHELF["layer"], 12) + [LENS_SHELF["layer"]] * 3)
    s.wait(10)
    shelf = LENS_SHELF_SCULPT.replace("Brush:Layer", "Brush:Inflate")
    return s, LENS_1440, camera_still({"shelf_drops": near(1), "shelf": is_text(shelf), "brush_sheet": near(1), "dabs": near(0)})


# The Lens stack at 1440 x 900 (lens_stack.odin): the Brush card's header and its Stroke
# group open; with Brush folded, the Symmetry card's grip and Layers' Float.
LENS_STACK = {"brush": (1180, 94), "stroke": (1200, 370), "symmetry_grip": (1075, 154), "layers_float": (1300, 214)}


@scenario
def lens_stack_header_tap_folds_the_card():
    """A tap on the Brush card's header folds it to its header, and a Brush group's header folds that group."""
    def run(group):
        s = Script()
        s.ftap(*(LENS_STACK["stroke"] if group else LENS_STACK["brush"]))
        s.wait(10)
        if group:
            return s, LENS_1440, camera_still({"stack": lambda v: v.startswith("Brush+,"), "stack_shut": lambda v: "Stroke" in v.split(","), "dabs": near(0)})
        return s, LENS_1440, camera_still({"stack": lambda v: v.startswith("Brush,"), "stack_folds": near(1), "dabs": near(0)})
    return Steps([run(False), run(True)])


@scenario
def lens_stack_grip_drag_moves_a_card():
    """With Brush folded, Symmetry's grip dragged below Scene moves it there."""
    s = Script()
    s.ftap(*LENS_STACK["brush"])
    s.wait(6)
    grip = LENS_STACK["symmetry_grip"]
    s.fdrag(line(grip, (grip[0], 300), 8) + [(grip[0], 300)] * 3)
    s.wait(10)
    return s, LENS_1440, camera_still({"stack": lambda v: v.startswith("Brush,Layers,Scene,Symmetry"), "stack_moves": near(1), "dabs": near(0)})


@scenario
def lens_stack_float_floats_a_card():
    """Layers' Float takes it out of the stack as a card of its own, open."""
    s = Script()
    s.ftap(*LENS_STACK["brush"])
    s.wait(6)
    s.ftap(*LENS_STACK["layers_float"])
    s.wait(10)
    return s, LENS_1440, camera_still({"stack": lambda v: "Layers+^" in v.split(","), "dabs": near(0)})


# Resizing the Lens stack at 1440x900: its inner edge (the strip just left of the cards),
# where that edge is once 40 points wider, the open Symmetry card's grip with Brush folded,
# and a floating Layers card's bottom-left corner.
LENS_RESIZE = {"edge": (1050, 400), "wider": (1010, 400), "wider_edge": (1012, 400), "symmetry_title": (1150, 154),
               "symmetry_grip": (1218, 416), "layers_corner": (738, 340)}


@scenario
def lens_stack_edge_sets_the_width():
    """Dragging the stack's inner edge 40 points out makes it 352 wide; a double tap on the edge puts 312 back."""
    def run(reset):
        s = Script()
        s.fdrag(line(LENS_RESIZE["edge"], LENS_RESIZE["wider"], 4))
        s.wait(6)
        if not reset:
            return s, LENS_1440, camera_still({"stack_width": near(352), "stack_resizes": near(1), "dabs": near(0)})
        s.ftap(*LENS_RESIZE["wider_edge"], gap=2)
        s.ftap(*LENS_RESIZE["wider_edge"])
        s.wait(6)
        return s, LENS_1440, camera_still({"stack_width": near(312), "stack_resizes": near(2), "dabs": near(0)})
    return Steps([run(False), run(True)])


@scenario
def lens_stack_grip_sets_a_card_height():
    """An open card's grip dragged up shows less of it, which then scrolls; dragged up past its header it folds the card."""
    def run(fold):
        s = Script()
        s.ftap(*LENS_STACK["brush"])
        s.wait(6)
        s.ftap(*LENS_RESIZE["symmetry_title"])
        s.wait(8)
        grip = LENS_RESIZE["symmetry_grip"]
        s.fdrag(line(grip, (grip[0], 140 if fold else 336), 4))
        s.wait(6)
        if fold:
            return s, LENS_1440, camera_still({"stack": lambda v: "Symmetry" in v.split(","), "stack_sizes": is_text("none"), "dabs": near(0)})
        return s, LENS_1440, camera_still({"stack": lambda v: "Symmetry+" in v.split(","), "stack_sizes": is_text("Symmetry=136"), "stack_resizes": near(1), "dabs": near(0)})
    return Steps([run(False), run(True)])


@scenario
def lens_stack_floating_card_resizes_from_a_corner():
    """A floating card's bottom-left corner dragged out and down makes it wider and taller, on the 8 point grid."""
    s = Script()
    s.ftap(*LENS_STACK["brush"])
    s.wait(6)
    s.ftap(*LENS_STACK["layers_float"])
    s.wait(8)
    s.fdrag(line(LENS_RESIZE["layers_corner"], (692, 420), 4))
    s.wait(6)
    return s, LENS_1440, camera_still({"stack_sizes": is_text("Layers+360x272"), "stack_resizes": near(1), "dabs": near(0)})


# Lens's split views at 1440x900 in One plus two: the vertical divider, the one between the
# two right panes, the Front pane's camera chip and Top in its list, the strip's Brush tab,
# and in the View layout menu (the rail's first slot) the Four drawing.
LENS_SPLIT = ["--script=view_grid one_plus_two"]
LENS_PANES = {"divider": (862, 300), "divider_right": (1150, 451), "front_camera": (920, 89), "top": (900, 390),
              "brush_tab": (1348, 95), "layout": (1403, 133), "four": (1230, 263)}


@scenario
def lens_pane_camera_chip_lists_cameras():
    """A view pane's camera chip lists the cameras under it; Top there turns the pane to the top view."""
    s = Script()
    s.ftap(*LENS_PANES["front_camera"])
    s.wait(8)
    s.ftap(*LENS_PANES["top"])
    s.wait(8)
    return s, LENS_1440 + LENS_SPLIT, camera_still({"pane_camera": is_text("Top"), "pane_menu": near(0), "dabs": near(0)})


@scenario
def lens_divider_to_the_edge_closes_panes():
    """The divider dragged to the right edge closes both right panes; the one between them dragged to the top closes the upper one."""
    def run(right):
        s = Script()
        if right:
            s.fdrag(line(LENS_PANES["divider"], (1425, 300), 6))
            s.wait(8)
            return s, LENS_1440 + LENS_SPLIT, camera_still({"grid": is_text("Single"), "grid_closes": near(1), "dabs": near(0)})
        s.fdrag(line(LENS_PANES["divider_right"], (1150, 20), 6))
        s.wait(8)
        return s, LENS_1440 + LENS_SPLIT, camera_still({"grid": is_text("Side_By_Side"), "pane_camera": is_text("Right"), "grid_closes": near(1), "dabs": near(0)})
    return Steps([run(True), run(False)])


@scenario
def lens_divider_double_tap_evens_it_out():
    """A double tap on the divider gives both sides half the room."""
    s = Script()
    s.ftap(*LENS_PANES["divider"], gap=2)
    s.ftap(*LENS_PANES["divider"])
    s.wait(8)
    return s, LENS_1440 + LENS_SPLIT, camera_still({"grid_split": lambda v: v.startswith("0.500,"), "grid_evens": near(1), "dabs": near(0)})


@scenario
def lens_new_panes_start_as_the_setting_says():
    """With new panes set to start as the same camera, a layout's added panes are linked to the main one."""
    s = Script()
    s.wait(4)
    return s, LENS_1440 + ["--script=set new_panes same_camera; view_grid one_plus_two"], camera_still({"pane_camera": is_text("Follow"), "new_panes": is_text("Same_Camera")})


@scenario
def lens_split_stack_becomes_tabs():
    """With panes beside the main one the stack is a strip of tabs; the Brush tab opens its card over the view."""
    s = Script()
    s.ftap(*LENS_PANES["brush_tab"])
    s.wait(8)
    return s, LENS_1440 + LENS_SPLIT, camera_still({"stack_strip": near(1), "stack_tab": is_text("Brush"), "dabs": near(0)})


@scenario
def lens_view_layout_menu_draws_the_presets():
    """The View layout menu's Four drawing shows four panes."""
    s = Script()
    s.ftap(*LENS_PANES["layout"])
    s.wait(8)
    s.ftap(*LENS_PANES["four"])
    s.wait(8)
    return s, LENS_1440, camera_still({"grid": is_text("Four"), "dabs": near(0)})


# Lens's pane gestures (lens_areas.odin) on one plus two at 1440 x 900: pane 1 is the top
# right one, pane 2 the bottom right; the targets inside their corners clear of the dividers.
LENS_CORNERS = {"pane1_bottom_left": (890, 420), "pane2_top_right": (1295, 478), "main_middle": (430, 450), "main_left": (120, 450)}


@scenario
def lens_corner_drag_splits_a_pane():
    """A drag from a view pane's corner sideways splits it left and right: four panes, the new one copying Front."""
    s = Script()
    s.fdrag(line(LENS_CORNERS["pane1_bottom_left"], (1100, 420), 8))
    s.wait(8)
    return s, LENS_1440 + LENS_SPLIT, camera_still({"grid_panes": near(4), "grid_splits": near(1), "grid": is_text("Custom"), "grid_undo_steps": near(2), "dabs": near(0)})


@scenario
def lens_corner_split_refuses_a_fifth_pane():
    """With four panes a corner drag splits nothing and says so with a shake."""
    s = Script()
    s.fdrag(line((745, 420), (950, 420), 8))
    s.wait(8)
    return s, LENS_1440 + ["--script=view_grid four"], camera_still({"grid_panes": near(4), "grid_refused": near(1), "grid_splits": near(0), "dabs": near(0)})


@scenario
def lens_corner_drag_into_a_neighbour_joins():
    """From the lower right pane's top corner up into the pane above, the two join: side by side, the lower pane's Right camera kept."""
    s = Script()
    s.fdrag(line(LENS_CORNERS["pane2_top_right"], (1295, 250), 8))
    s.wait(8)
    return s, LENS_1440 + LENS_SPLIT, camera_still({"grid": is_text("Side_By_Side"), "grid_joins": near(1), "pane_camera": is_text("Right"), "dabs": near(0)})


@scenario
def lens_corner_drag_back_to_the_corner_cancels():
    """Inward and back to the corner again, the drag splits nothing; nor does one a second finger joins."""
    def run(second):
        s = Script()
        start = LENS_CORNERS["pane1_bottom_left"]
        if second:
            s.fdrag(line(start, (1100, 420), 6), lift=False)
            s.add("fdown:1:1200,200")
            s.wait(2)
            s.add("fup:1")
            s.add("fup:0")
        else:
            s.fdrag(line(start, (1100, 420), 6) + line((1100, 420), (start[0] - 4, start[1] + 4), 6))
        s.wait(8)
        return s, LENS_1440 + LENS_SPLIT, camera_still({"grid_panes": near(3), "grid_splits": near(0), "grid_cancels": near(1)})
    return Steps([run(False), run(True)])


@scenario
def lens_camera_chip_drags_a_pane_to_swap_or_dock():
    """Pane 1's camera chip dropped on the main pane's middle swaps the two; dropped on its left part, docks pane 1 on the left."""
    def run(swap):
        s = Script()
        s.fdrag(past_slop(LENS_PANES["front_camera"], LENS_CORNERS["main_middle" if swap else "main_left"], 10))
        s.wait(8)
        if swap:
            return s, LENS_1440 + LENS_SPLIT, camera_still({"grid_swaps": near(1), "grid_main": lambda v: float(v.split("x")[0]) < 700, "pane_menu": near(0), "grid_undo_steps": near(2)})
        return s, LENS_1440 + LENS_SPLIT, camera_still({"grid_docks": near(1), "grid_panes": near(3), "grid": is_text("Custom"), "pane_menu": near(0)})
    return Steps([run(True), run(False)])


@scenario
def lens_undo_takes_a_split_back():
    """Ctrl+Z after a corner split puts the three panes back, and Ctrl+Shift+Z splits again."""
    def run(redo):
        s = Script()
        s.fdrag(line(LENS_CORNERS["pane1_bottom_left"], (1100, 420), 8))
        s.wait(4)
        s.press("z", ("ctrl",))
        if redo:
            s.wait(2)
            s.press("z", ("ctrl", "shift"))
        s.wait(6)
        return s, LENS_1440 + LENS_SPLIT, camera_still({"grid_panes": near(4 if redo else 3), "grid_undos": near(1), "grid_redos": near(1 if redo else 0)})
    return Steps([run(False), run(True)])


@scenario
def lens_divider_menu_swaps_the_sides():
    """A right click on the divider opens its menu; Swap sides puts the main view on the right, a step Ctrl+Z takes back."""
    def run(undo):
        s = Script()
        s.add("move:862,300")
        s.wait(1)
        s.add("rdown")
        s.wait(1)
        s.add("rup")
        s.wait(4)
        s.ftap(912, 445)
        s.wait(4)
        if undo:
            s.press("z", ("ctrl",))
        s.wait(4)
        tree = "v600,0,h500,1,2" if undo else "v400,h500,1,2,0"
        return s, LENS_1440 + LENS_SPLIT, camera_still({"grid_tree": is_text(tree), "grid_swaps": near(1), "dabs": near(0)})
    return Steps([run(False), run(True)])


@scenario
def lens_shift_moves_lined_up_dividers():
    """In Four the two column dividers line up: dragged with Shift both move, without it only the one held."""
    def run(shift):
        s = Script()
        s.mouse_drag(line((720, 300), (900, 300), 8), keys=("shift",) if shift else ())
        s.wait(6)
        tree = "h500,v625,0,1,v625,2,3" if shift else "h500,v625,0,1,v500,2,3"
        return s, LENS_1440 + ["--script=view_grid four"], camera_still({"grid_tree": is_text(tree), "dabs": near(0)})
    return Steps([run(True), run(False)])



# Focus in Lens at 1600 x 900: the middle island's workspace chip and X symmetry chip, and
# the tools island's View layout and Passes.
LENS_FOCUS = {"workspace": (770, 33), "symmetry": (838, 33), "layout": (1460, 33), "passes": (1510, 33)}


@scenario
def lens_focus_draws_islands():
    """Focus in Lens: the top bar becomes islands, X symmetry is a chip there, and Passes opens its menu."""
    s = Script()
    s.ftap(*LENS_PILL["focus"])
    s.wait(6)
    s.ftap(*LENS_FOCUS["symmetry"])
    s.wait(4)
    s.ftap(*LENS_FOCUS["passes"])
    s.wait(6)
    return s, LENS, camera_still({"workspace": is_text("Focus"), "lens_focus": near(1), "symmetry": is_text("x"), "pass_menu": near(1), "dabs": near(0)})


# The Lens menu's button and its rows at 1600 x 900 that open submenus, and the first row
# of the submenu Open recent opens.
LENS_MENU = (33, 26)
LENS_MENU_ROWS = {"new": (120, 129), "recent": (120, 217), "export": (120, 482), "more": (120, 835)}
LENS_SUBMENU_FIRST = (380, 248)


@scenario
def lens_menu_recent_opens_sideways():
    """Open recent opens its list beside the menu on a tap, and More on a mouse resting on it; a scene gone leaves Recent."""
    folder = os.path.join(ROOT, "build", "touch", "scenes")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, CURRENT.name + ".sculpt")
    if os.path.exists(path):
        os.remove(path)

    def tap(open_it):
        s = Script()
        s.ftap(*LENS_MENU)
        s.wait(6)
        s.ftap(*LENS_MENU_ROWS["recent"])
        s.wait(8)
        if open_it:
            s.ftap(*LENS_SUBMENU_FIRST)
            s.wait(8)
        # Each run its own settings file: the first run's exit writes its own back.
        settings = settings_file()[:-4] + ("-open.txt" if open_it else ".txt")
        with open(settings, "w") as f:
            f.write(f"recent_scenes {path}\n")
        expect = {"menu_sub": is_text("Recent"), "menu_subs": near(1), "dabs": near(0)}
        # The file is gone, so the tap takes it off Recent rather than opening it, and the
        # list stays open to show it went.
        if open_it:
            expect.update({"recent_scenes": near(0), "menu_recent_opens": near(0)})
        return s, LENS + [f"--settings-file={settings}"], camera_still(expect)

    def rest():
        s = Script()
        s.ftap(*LENS_MENU)
        s.wait(6)
        s.add(f"move:{LENS_MENU_ROWS['more'][0]},{LENS_MENU_ROWS['more'][1]}")
        s.wait(30)
        return s, LENS, camera_still({"menu_sub": is_text("More"), "menu_subs": near(1)})
    return Steps([tap(False), tap(True), rest()])


@scenario
def lens_search_groups_and_puts_on_a_bar():
    """Lens's search groups what matches; Ctrl+Enter puts the pick on the view rail and leaves search open."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("flat shading")
    s.wait(2)
    s.press("Return", ("ctrl",))
    s.wait(4)
    return s, LENS, camera_still({"palette": near(1), "palette_bar_puts": near(1), "palette_groups": lambda v: v.startswith("Commands"), "dabs": near(0)})


# The Lens Scene and Layers cards at 1440x900 with the Brush card folded: their headers,
# the first object row's lock, the Scene card's filter past ten objects, and with two
# layers (Layer 2 picked, as New layer leaves it) Layer 1's name and record dot.
LENS_CARDS = {"brush": (1180, 94), "layers": (1150, 214), "scene": (1150, 274), "first_lock": (1337, 330),
              "filter": (1150, 330), "layer1_name": (1150, 372), "layer1_dot": (1343, 372)}


def lens_card_open(s, card):
    s.ftap(*LENS_CARDS["brush"])
    s.wait(6)
    s.ftap(*LENS_CARDS[card])
    s.wait(6)


@scenario
def lens_scene_card_locks_an_object():
    """The Scene card's lock locks the sphere, so a stroke over it passes it by and sculpts nothing."""
    s = Script()
    lens_card_open(s, "scene")
    s.ftap(*LENS_CARDS["first_lock"])
    s.wait(6)
    s.fdrag(line((700, 430), (780, 470), 16))
    s.wait(6)
    return s, LENS_1440, {"object_locks": near(1), "dabs": near(0), "selected": near(-1)}


@scenario
def lens_scene_card_filters_past_ten():
    """With twelve objects the Scene card offers a filter; typing 3 leaves only Sphere 3's row."""
    s = Script()
    lens_card_open(s, "scene")
    s.ftap(*LENS_CARDS["filter"])
    s.wait(4)
    s.type("3")
    s.wait(6)
    return s, LENS_1440 + ["--script=" + "duplicate_object; " * 11], camera_still({"scene_rows": near(1), "scene_filter": near(1), "dabs": near(0)})


@scenario
def lens_layers_card_records_and_picks():
    """On the Layers card a tap on Layer 1's name picks it and leaves Layer 2 recording; a tap on its dot records into it."""
    def run(dot):
        s = Script()
        lens_card_open(s, "layers")
        s.ftap(*LENS_CARDS["layer1_dot" if dot else "layer1_name"])
        s.wait(6)
        return s, LENS_1440 + ["--script=new_layer; new_layer"], camera_still({"layer_rows": near(2), "layer_picked": near(0), "layer_recording": near(0 if dot else 1), "dabs": near(0)})
    return Steps([run(False), run(True)])


# Lens's brush pie at 1440x900: the dial's Pie sector opens it at the viewport's middle;
# the top slice (Clay) and the editor's first brush slot.
LENS_PIE = {"dial": (122, 822), "middle": (720, 450), "top": (720, 334), "crease": (800, 520), "editor_first": (764, 190), "search": (1180, 26)}


@scenario
def lens_brush_pie_dial_then_tap_picks():
    """The dial's Pie opens the brush pie in the middle, pointing at nothing; a tap on its top slice picks Clay and closes it."""
    def run(tap):
        s = Script()
        s.ftap(*LENS_PIE["dial"])
        s.wait(10)
        if not tap:
            return s, LENS_1440, camera_still({"pie_open": near(0), "pie_hover": near(-1), "dabs": near(0)})
        s.ftap(*LENS_PIE["top"])
        s.wait(10)
        return s, LENS_1440, camera_still({"pie_open": near(-1), "brush_kind": is_text("clay"), "dabs": near(0)})
    return Steps([run(False), run(True)])


@scenario
def lens_brush_pie_space_flick_picks():
    """Holding Space over the model and letting go toward the lower right picks Crease, without a dab or a turn."""
    s = Script()
    s.add(f"move:{LENS_PIE['middle'][0]},{LENS_PIE['middle'][1]}")
    s.wait(2)
    s.add("key:Space")
    s.wait(4)
    s.add(f"move:{LENS_PIE['crease'][0]},{LENS_PIE['crease'][1]}")
    s.wait(3)
    s.add("keyup:Space")
    s.wait(8)
    return s, LENS_1440, camera_still({"pie_open": near(-1), "brush_kind": is_text("crease"), "pie_quicks": near(0), "dabs": near(0)})


@scenario
def lens_brush_pie_rest_shows_quick_settings():
    """Resting on a slice with Space held picks its brush and shows its quick settings there."""
    s = Script()
    s.add(f"move:{LENS_PIE['middle'][0]},{LENS_PIE['middle'][1]}")
    s.wait(2)
    s.add("key:Space")
    s.wait(4)
    s.add(f"move:{LENS_PIE['crease'][0]},{LENS_PIE['crease'][1]}")
    s.wait(45)
    s.add("keyup:Space")
    s.wait(8)
    return s, LENS_1440, camera_still({"pie_open": near(-1), "brush_kind": is_text("crease"), "pie_quicks": near(1), "shelf_quick": near(1), "dabs": near(0)})


@scenario
def lens_pie_editor_brush_slot_chooses_in_search():
    """In Lens the pie editor's first row is the brush pie; a tap on a slot there opens Search, and what is chosen there takes the slot."""
    s = Script()
    s.ftap(*LENS_PIE["search"])
    s.wait(8)
    s.type("pies")
    s.press("Return")
    s.wait(8)
    s.ftap(*LENS_PIE["editor_first"])
    s.wait(8)
    s.type("snake hook")
    s.press("Return")
    s.wait(8)
    return s, LENS_1440, camera_still({"pie_editor": near(0), "palette": near(0), "brush_pie": lambda v: v.startswith("Brush:Snake_Hook,Brush:Draw")})


@scenario
def save_as_new_workspace_is_remembered():
    """Save as a new workspace from the switcher makes "Workspace 1", current, and the settings keep it."""
    s = Script()
    s.ftap(*WORKSPACE_CHIP)
    s.wait(10)
    s.ftap(WORKSPACE_CHIP[0], WORKSPACE_ROWS["save_as"])
    s.wait(10)
    return s, [f"--settings-file={settings_file()}"], camera_still({
        "dabs": near(0), "workspace": is_text("Workspace%201"), "workspace_count": near(5),
        "@saved": saved_line("workspace 4 Workspace%201")})


@scenario
def the_current_workspace_comes_back():
    """A settings file naming Inspect as current starts in Inspect: Stats docked on the left and the view grid's four panes."""
    with open(settings_file(), "w") as f:
        f.write("workspace_current 2\n")
    s = Script()
    s.add("move:800,450")
    s.wait(10)
    return s, [f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "workspace": is_text("Inspect"),
                                                                     "column_left": is_text("stats"), "zones_hidden": is_text("brush_bar,dock"),
                                                                     "grid": is_text("Four")})


# Arrange's head at 1600 x 900 (arrange.odin): Panels, the Dock's Show switch, the dock's
# outline's Show once hidden, and in the Panels drawer the Statistics row's Left.
ARRANGE_PANELS, ARRANGE_DOCK, ARRANGE_SHOW_DOCK, ARRANGE_STATS_LEFT = (622, 154), (821, 208), (800, 836), (817, 300)


@scenario
def arrange_hides_the_dock_and_shows_it_again():
    """In Arrange the Dock switch hides the dock, which marks the workspace; its outline's Show brings it back."""
    def run(show):
        s = Script()
        s.ftap(*ARRANGE_DOCK)
        s.wait(10)
        if show:
            s.ftap(*ARRANGE_SHOW_DOCK)
            s.wait(10)
        hidden = "none" if show else "dock"
        return s, ["--script=customise_bars"], camera_still({"dabs": near(0), "zones_hidden": is_text(hidden), "bars_edit": near(1),
                                                             "workspace_modified": near(0 if show else 1)})
    return Steps([run(False), run(True)])


@scenario
def arrange_drawer_docks_stats_on_the_left():
    """In Arrange's Panels drawer, Left on the Statistics row opens Stats docked in the left column."""
    s = Script()
    s.ftap(*ARRANGE_PANELS)
    s.wait(10)
    s.ftap(*ARRANGE_STATS_LEFT)
    s.wait(10)
    return s, ["--script=customise_bars"], camera_still({"dabs": near(0), "column_left": is_text("stats"), "arrange_drawer": near(1),
                                                         "window_stats": lambda v: v.startswith("1,")})


# The top bar's pass chip at 1600 x 900, and the Normals and Wipe compare rows of its list.
PASS_CHIP, PASS_NORMALS, PASS_MENU_WIPE = (1340, 25), (1415, 150), (1375, 415)


@scenario
def pass_chip_picks_normals_from_its_list():
    """A tap on the top bar's pass chip opens the list of passes; Normals there shows the normals and marks the workspace."""
    s = Script()
    s.ftap(*PASS_CHIP)
    s.wait(10)
    s.ftap(*PASS_NORMALS)
    s.wait(10)
    return s, [], camera_still({"dabs": near(0), "pass": is_text("Normals"), "pass_shown": is_text("Normals"), "pass_menu": near(0),
                                "workspace_modified": near(1)})


@scenario
def pass_chip_held_peeks_until_lifted():
    """A finger held on the pass chip shows Normals, the peek with no other pass yet, while it stays down; lifting it brings Shaded back, with nothing changed."""
    def run(lift):
        s = Script()
        s.add(f"fdown:0:{PASS_CHIP[0]},{PASS_CHIP[1]}")
        s.wait(40)
        if lift:
            s.add("fup:0")
            s.wait(10)
        return s, [], camera_still({"dabs": near(0), "pass": is_text("Shaded"), "pass_shown": is_text("Shaded" if lift else "Normals"),
                                    "pass_menu": near(0), "workspace_modified": near(0)})
    return Steps([run(False), run(True)])


@scenario
def pass_keys_flip_and_backquote_peeks():
    """Alt+3 shows Depth, Alt+3 again leaves it, and Alt+0 goes back to Shaded; a held backquote then peeks at Depth until it is let go."""
    def run(held):
        s = Script()
        s.add("move:800,450")
        s.wait(2)
        s.press("3", ("alt",))
        s.press("3", ("alt",))
        s.press("0", ("alt",))
        s.add("key:`")
        s.wait(6)
        if not held:
            s.add("keyup:`")
            s.wait(6)
        return s, [], camera_still({"dabs": near(0), "pass": is_text("Shaded"), "pass_shown": is_text("Depth" if held else "Shaded"),
                                    "pass_switches": near(2)})
    return Steps([run(True), run(False)])


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
    """A 1280 x 800 window (a tablet's size): the tray's tall Mask section scrolls from the first touch and far-apart taps turn nothing."""
    s = Script()
    write_settings("all_options 1\n")
    s.fdrag(line((1066, 362), (1071, 142), 22))
    s.ftap(200, 150)
    s.ftap(300, 700)
    s.ftap(150, 650)
    return s, ["--width=1280", "--height=800", "--script=show_section mask", f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "inspector_scroll": lambda v: float(v) > 50,
                                                            "brush_radius_px": near(60)})



# The modifier wheel's sectors at the bottom left at 1600 x 900 (Smooth at the top, the
# brush pie at the right, Invert at the bottom, Mask at the left) and its grip in the
# middle, and the finger that holds them: an id of its own, as a second hand's would have.
RAIL = {"smooth": (78, 779), "pie": (121, 822), "invert": (78, 865), "mask": (35, 822), "grip": (78, 822)}
RAIL_FINGER = 9


def pen_stroke(s, path, pressure=None):
    """The pen near, down along `path` one frame a point, up and away; with `pressure`
    (0 to 1), pressing that hard (otherwise as the last stroke did: 0 until set)."""
    s.add("pnear")
    if pressure is not None:
        s.add(f"ppress:{pressure:g}")
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
BAR_SHOW_ALL = (682, 786)
BAR_MASK_HIDDEN = (968, 786)  # Mask it, the fifth of the Hidden group alone
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
    return s, ["--script=hide x"], camera_still({"action_bar": is_text("none"), "dabs": near(0),
                                          "@shown": lambda stats: "hidden_triangles" not in stats})


@scenario
def action_bar_masks_the_hidden_part():
    """With half the sphere hidden, the bar's Mask it masks that half; Ctrl+H then shows everything and the mask stays on
    the half that was hidden, each an undo step."""
    s = Script()
    s.wait(8)
    s.ftap(*BAR_MASK_HIDDEN)
    s.wait(8)
    s.press("h", ("ctrl",))
    s.wait(8)
    return s, ["--script=hide x"], camera_still({"masked": near(1), "mask_mean": lambda v: 0.3 < float(v) < 0.7, "undo_steps": near(2),
                                          "@shown": lambda stats: "hidden_triangles" not in stats})


@scenario
def palette_hides_the_masked_part():
    """A band of mask, then the palette's Hide masked: the band is hidden, the mask stays, and it is one more undo step."""
    s = Script()
    masked_first(s)
    s.press("k", ("ctrl",))
    s.type("hide masked")
    s.press("Return")
    s.wait(6)
    return s, [], camera_still({"masked": near(1), "undo_steps": near(2), "palette": near(0),
                                "hidden_triangles": lambda v: int(v) > 0})


@scenario
def hide_unmasked_then_undo_shows_it_again():
    """A band of mask, the palette's Hide unmasked leaves only the band shown, and one Ctrl+Z shows everything again."""
    s = Script()
    masked_first(s)
    s.press("k", ("ctrl",))
    s.type("hide unmasked")
    s.press("Return")
    s.wait(6)
    s.press("z", ("ctrl",))
    s.wait(6)
    return s, [], camera_still({"masked": near(1), "undo_steps": near(1), "redo_steps": near(1),
                                "@shown": lambda stats: "hidden_triangles" not in stats})


# Selection sets: the first set's Restore, where the tray shows the section.
SETS_RESTORE_FIRST = (1469, 297)


def store_set(s):
    """The palette's Store mask as set."""
    s.press("k", ("ctrl",))
    s.type("store mask")
    s.press("Return")
    s.wait(4)


def open_sets(s):
    palette_run(s, "object selection sets")
    s.wait(12)


@scenario
def selection_set_restores_by_finger():
    """A band of mask stored as a set, Alt+M clears it, and a finger on the set's Restore brings it back as an undo step
    with Undo on its note."""
    s = Script()
    masked_first(s)
    store_set(s)
    s.press("m", ("alt",))
    s.wait(4)
    open_sets(s)
    s.ftap(*SETS_RESTORE_FIRST)
    s.wait(8)
    return s, [], camera_still({"masked": near(1), "selection_sets": near(1), "undo_steps": near(3), "toast_undo": near(1),
                                "last_op": is_text("Restored_Set_1")})


@scenario
def selection_set_restore_undoes():
    """The palette's Restore selection set 1 brings the stored mask back after Alt+M, and one Ctrl+Z clears it again."""
    s = Script()
    masked_first(s)
    store_set(s)
    s.press("m", ("alt",))
    s.wait(4)
    s.press("k", ("ctrl",))
    s.type("restore selection set 1")
    s.press("Return")
    s.wait(6)
    s.press("z", ("ctrl",))
    s.wait(6)
    return s, [], camera_still({"masked": near(0), "selection_sets": near(1), "undo_steps": near(2), "redo_steps": near(1)})


@scenario
def remesh_drops_the_sets_and_undo_brings_them_back():
    """Ctrl+R rebuilds the mesh, so its stored set goes and the note says so; Ctrl+Z puts the old mesh back with the set."""
    s = Script()
    masked_first(s)
    store_set(s)
    s.press("r", ("ctrl",))
    s.wait(8)
    first = (s, [], {"selection_sets": near(0), "sets_noted": near(1)})
    again = Script()
    masked_first(again)
    store_set(again)
    again.press("r", ("ctrl",))
    again.wait(8)
    again.press("z", ("ctrl",))
    again.wait(8)
    return Steps([first, (again, [], {"selection_sets": near(1), "redo_steps": near(1)})])


@scenario
def dynamic_topology_drops_the_sets_and_says_so():
    """Ctrl+T numbers the vertices afresh, so the stored set goes, and its note says how many."""
    s = Script()
    masked_first(s)
    store_set(s)
    s.press("t", ("ctrl",))
    s.wait(8)
    return s, [], camera_still({"selection_sets": near(0), "sets_noted": near(1), "toast_undo": near(1)})


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
    return s, ["--width=820", "--height=640", "--script=hide x"], camera_still({"masked": near(0), "action_pop": near(0),
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
    return s, ["--width=820", "--height=640", "--script=hide x"], camera_still({"action_pop": near(0), "masked": near(0),
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
        "action_bar": is_text("mask"), "@layout": clear_of("action_bar", "brush_bar", "inspector", "dock", "points")}


@scenario
def action_bar_clears_the_panels_on_a_narrow_window():
    """At 820 x 640 with a mask and hidden parts, the bar meets neither the inspector, the dock, the object's status, the rail nor the sliders."""
    s = Script()
    s.press("i", ("ctrl",))
    s.wait(12)
    return s, ["--width=820", "--height=640", "--script=hide x"], {"action_bar": is_text("mask+hidden"),
                                                          "@layout": clear_of("action_bar", "inspector", "dock", "points", "modifier_rail", "brush_bar")}


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
def wheel_pie_sector_opens_the_brush_pie():
    """A finger's tap on the wheel's right sector opens the brush pie and sculpts nothing; the mouse's click does the same."""
    finger, mouse = Script(), Script()
    rail_tap(finger, "pie")
    finger.wait(6)
    click(mouse, RAIL["pie"])
    mouse.wait(6)
    want = {"dabs": near(0), "pie_open": near(0), "rail_latched": lambda v: v == "none"}
    return Steps([(finger, [], camera_still(want)), (mouse, [], camera_still(want))])


def wheel_at(x, y):
    """A check that the wheel's square has its top left corner at (x, y), give or take a point."""
    def ok(stats):
        r = [float(v) for v in stats["layout_modifier_rail"].split(",")]
        return abs(r[0] - x) <= 1 and abs(r[1] - y) <= 1
    return ok


@scenario
def wheel_moves_by_its_grip():
    """A finger dragging the wheel's grip carries the wheel with it, turning and sculpting nothing, and Settings' Done remembers where; at the Large size the wheel is larger."""
    if os.path.exists(settings_file()):
        os.remove(settings_file())
    moved = Script()
    moved.fdrag(line(RAIL["grip"], (378, 622), 12))
    moved.wait(6)
    moved.ftap(*UI["settings"])
    moved.wait(12)
    moved.ftap(1427, 750)  # Done
    moved.wait(6)
    large = Script()
    large.add(f"move:{EMPTY[0]},{EMPTY[1]}")
    large.wait(6)
    with open(os.path.join(ROOT, "build", "touch", "wheel_large.txt"), "w") as f:
        f.write("wheel_size Large\n")
    return Steps([
        (moved, [f"--settings-file={settings_file()}"], camera_still({"dabs": near(0), "@moved": wheel_at(312, 556), "@saved": saved(wheel_x="300", wheel_y="-200")})),
        (large, [f"--settings-file={os.path.join(ROOT, 'build', 'touch', 'wheel_large.txt')}"], {"@large": lambda st: st["layout_modifier_rail"].split(",")[2] == "156"}),
    ])


def layout_x(name, test):
    """A check on where the layout put `name` across the window: `test` takes its left edge and width."""
    def ok(stats):
        x, _, w, _ = (float(v) for v in stats[f"layout_{name}"].split(","))
        return w > 0 and test(x, w)
    return ok


@scenario
def left_handed_layout_swaps_the_sides():
    """In the left-handed layout the brush bar, its popovers and the wheel are on the right and the view bar on the left: a finger on the mirrored wheel latches Smooth, and on the mirrored Focal shift opens its slider to the bar's left."""
    s = Script()
    s.wait(4)
    s.ftap(1600 - RAIL["smooth"][0], RAIL["smooth"][1])
    s.wait(6)
    s.ftap(1600 - UI["focal"][0], UI["focal"][1])
    s.wait(8)
    # The first-run tip and the History panel keep clear of the bars on their new sides.
    coach = Script()
    coach.wait(4)
    coach.ftap(*UI["history"])
    coach.wait(12)
    return Steps([
        (s, ["--script=set left_handed 1"], camera_still({
            "dabs": near(0), "bar_pop": is_text("focal"), "rail_latched": is_text("smooth"),
            "@brush bar on the right": layout_x("brush_bar", lambda x, w: x + w > 1590 and x > 1500),
            "@view bar on the left": layout_x("view_bar", lambda x, w: x < 20),
            "@wheel on the right": layout_x("modifier_rail", lambda x, w: x > 1400),
        })),
        (coach, ["--script=set left_handed 1", "--coach"], {
            "@readout on the right": layout_x("points", lambda x, w: x + w > 1580),
            "@tip clear": clear_of("coach", "brush_bar", "points", "view_bar", "inspector"),
        }),
    ])


@scenario
def rail_hide_gesture():
    """Smooth and Mask latched together are Hide: a finger drags the hide rectangle over part of the model, and once applied (Enter) the rest is hidden."""
    s = Script()
    rail_tap(s, "smooth")
    rail_tap(s, "mask")
    s.fdrag(line((250, 150), (800, 450), 20))
    s.wait(4)
    s.press("Return")
    return s, [], camera_still({"dabs": near(0), "hidden_triangles": lambda v: int(v) > 0, "rail_latched": lambda v: v == "smooth+mask"})


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
    return s, ["--width=1280", "--height=800", f"--settings-file={settings_file()}"], {"@layout": rail_clear("brush_bar", "dock")}


@scenario
def rail_fits_portrait():
    """In a portrait 800 x 1280 window the rail clears the dock and the sliders."""
    s = Script()
    s.add("move:400,640")
    s.wait(6)
    return s, ["--width=800", "--height=1280"], {"@layout": rail_clear("brush_bar", "dock")}


@scenario
def rail_on_the_right_clears_the_panels():
    """Put on the right, the rail sits above the object's status, clear of the inspector and the dock."""
    with open(settings_file(), "w") as f:
        f.write("modifier_rail Right\n")
    s = Script()
    s.add("move:640,400")
    s.wait(6)
    return s, [f"--settings-file={settings_file()}"], {"@layout": rail_clear("points", "inspector", "dock", "brush_bar")}


def long_press(s, x, y, finger=0, frames=LONG_PRESS_FRAMES):
    """A finger held still on (x, y) long enough to be a long press, then lifted."""
    s.add(f"fdown:{finger}:{x:g},{y:g}")
    s.wait(frames)
    s.add(f"fup:{finger}")
    s.wait(4)


INSPECTOR_BUTTON = UI["inspector"]
FOCUS_BUTTON, FRAME_ALL_BUTTON = (1300, 282), (1452, 282)  # the Move tool's palette, above the gizmo's settings
# The first object's row in the tray's Scene palette (scene_tab opens it).
SCENE_ROW = (1376, 186)


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
    return s, [], camera_still({"dabs": near(0), "long_tip": lambda v: v == "Palettes",
                                "window_inspector": lambda v: v.startswith("1,0,")})


@scenario
def long_press_a_scene_row_opens_its_menu():
    """A long press on an object in the Scene tab opens its menu (Focus, Duplicate, Delete), as a right-click does."""
    s = Script()
    scene_tab(s)
    long_press(s, *SCENE_ROW)
    return s, [], camera_still({"dabs": near(0), "object_menu": near(1), "selected": near(0)})


# The Scene tab's rows with three spheres (--spheres=3), each a touch target tall: the
# eye at a row's right end, its ghost just before it (scene_tree.odin, ui.tree_row), and
# where each sphere shows in the starting view.
THREE = ["--spheres=3", "--vertices=20000"]
SCENE_ROWS_Y = [186, 240, 294]
SCENE_EYE_X, SCENE_GHOST_X, SCENE_ROW_X = 1496, 1451, 1346
SPHERES3 = [(630, 410), (800, 450), (1006, 498)]


def scene_tab(s):
    """Opens the tray's Scene palette on Objects, whatever the tool: the Objects card, docked
    back into the tray by holding its dots."""
    objects_card(s)
    long_press(s, *OBJECTS_CARD["dots"])
    s.wait(10)


def objects_card(s):
    """Opens the Objects card from the view bar, waiting for its pictures to be drawn."""
    s.ftap(*UI["objects"])
    s.wait(12)


# The Objects card at 1600 x 900 (kit_objects_card.odin): its dots, its buttons, and its
# rows' bodies, boolean switches, polypaint toggles and eyes.
OBJECTS_CARD = {"dots": (1378, 89), "add": (1258, 174), "more": (1497, 174), "actions": (1300, 444),
                # With the Actions open and their sections folded: the headers, then what a
                # section shows open (Split above Merge, Align once scrolled up).
                "split": (1300, 567), "merge": (1300, 613), "align": (1300, 751),
                "split_parts": (1451, 670), "merge_down": (1378, 664), "align_x_max": (1480, 563)}
CARD_ROWS_Y = [233, 293, 353]
CARD_ROW_X, CARD_SWITCH_X, CARD_PAINT_X, CARD_EYE_X = 1360, 1312, 1446, 1494
CARD_ROW_H = 60


@scenario
def objects_card_opens_with_pictures():
    """The view bar's Objects button opens the Objects card in the tray's place, with a row and a picture for each object."""
    s = Script()
    objects_card(s)
    return s, THREE, {"dabs": near(0), "window_objects": lambda v: v.startswith("1,0,"), "window_inspector": lambda v: v.startswith("0,"),
                      "card_rows": near(3), "thumbs_drawn": near(3)}


@scenario
def objects_card_long_press_opens_the_menu():
    """A long press on the selected row opens its full menu; on another row, only how that object takes part in booleans, leaving the selection alone."""
    mine = Script()
    objects_card(mine)
    long_press(mine, CARD_ROW_X, CARD_ROWS_Y[0])
    other = Script()
    objects_card(other)
    long_press(other, CARD_ROW_X, CARD_ROWS_Y[1])
    return Steps([
        (mine, THREE, {"card_menu": near(1), "card_menu_full": near(1), "selected": near(0), "dabs": near(0)}),
        (other, THREE, {"card_menu": near(1), "card_menu_full": near(0), "selected": near(0), "dabs": near(0)}),
    ])


@scenario
def objects_card_long_press_then_drag_moves_a_row():
    """A finger held on the third row until its menu opens, then dragged above the first, moves that object to the top as one undo step and closes the menu; a quick drag without the hold moves nothing."""
    held = Script()
    objects_card(held)
    held.add(f"fdown:0:{CARD_ROW_X},{CARD_ROWS_Y[2]}")
    held.wait(LONG_PRESS_FRAMES)
    for y in range(CARD_ROWS_Y[2] - 4, CARD_ROWS_Y[0] - 32, -8):
        held.add(f"fmove:0:{CARD_ROW_X},{y}")
        held.wait(1)
    held.wait(2)
    held.add("fup:0")
    held.wait(6)
    quick = Script()
    objects_card(quick)
    quick.fdrag(line((CARD_ROW_X, CARD_ROWS_Y[2]), (CARD_ROW_X, CARD_ROWS_Y[0] - 28), 12))
    quick.wait(6)
    return Steps([
        (held, THREE, {"scene_order": is_text("3,1,2"), "undo_steps": near(1), "card_menu": near(0), "dabs": near(0)}),
        (quick, THREE, {"scene_order": is_text("1,2,3"), "undo_steps": near(0), "dabs": near(0)}),
    ])


@scenario
def objects_card_mouse_drag_moves_a_row():
    """With a mouse a row drags at once: the third dropped above the first goes to the top."""
    s = Script()
    s.mouse_drag([(1569, 251)])
    s.wait(12)
    s.mouse_drag(line((CARD_ROW_X, CARD_ROWS_Y[2]), (CARD_ROW_X, CARD_ROWS_Y[0] - 28), 12))
    s.wait(6)
    return s, THREE, {"scene_order": is_text("3,1,2"), "undo_steps": near(1), "dabs": near(0)}


@scenario
def objects_card_toggles_eye_paint_and_boolean():
    """A row's eye hides its object, its polypaint toggle leaves the paint out, and the switch under its name makes it a boolean, none of them selecting it."""
    s = Script()
    objects_card(s)
    s.ftap(CARD_EYE_X, CARD_ROWS_Y[1])
    s.wait(6)
    s.ftap(CARD_PAINT_X, CARD_ROWS_Y[2])
    s.wait(6)
    s.ftap(CARD_SWITCH_X, CARD_ROWS_Y[2] + 12)
    s.wait(6)
    return s, THREE, {"objects_off": near(1), "paint_off": near(1), "booleans": near(1), "selected": near(0), "dabs": near(0)}


@scenario
def objects_card_holding_its_dots_docks_it():
    """Holding the card's dots puts it back in the Scene palette: the card closes and the tray opens on Objects."""
    s = Script()
    objects_card(s)
    long_press(s, *OBJECTS_CARD["dots"])
    s.wait(6)
    return s, THREE, {"window_objects": lambda v: v.startswith("0,"), "window_inspector": lambda v: v.startswith("1,0,"), "tree_rows": near(3)}


@scenario
def objects_card_gives_way_to_the_tray():
    """Opening the palette tray closes the card, which shares its place; the Objects button opens the card again and closes the tray."""
    closed = Script()
    objects_card(closed)
    closed.ftap(*UI["inspector"])
    closed.wait(8)
    again = Script()
    objects_card(again)
    again.ftap(*UI["inspector"])
    again.wait(8)
    objects_card(again)
    return Steps([
        (closed, THREE, {"window_objects": lambda v: v.startswith("0,"), "window_inspector": lambda v: v.startswith("1,")}),
        (again, THREE, {"window_objects": lambda v: v.startswith("1,"), "window_inspector": lambda v: v.startswith("0,")}),
    ])


def card_slot(k):
    """Where Store visibility's V`k` tile is, with the Actions open."""
    return (CARD_SLOT_X0 + (k - 1) * CARD_SLOT_STEP, CARD_SLOT_Y)


CARD_SLOT_X0, CARD_SLOT_STEP, CARD_SLOT_Y = 1250, 36.5, 518


def card_actions(s):
    """Opens the Objects card and unfolds its Actions."""
    objects_card(s)
    s.ftap(*OBJECTS_CARD["actions"])
    s.wait(12)


@scenario
def objects_card_actions_store_visibility():
    """Store visibility: V1 keeps the eyes turned while it is chosen, V2 its own, and choosing V1 again brings its eyes back."""
    s = Script()
    card_actions(s)
    s.ftap(*card_slot(1))
    s.wait(4)
    s.ftap(CARD_EYE_X, CARD_ROWS_Y[1])
    s.wait(4)
    s.ftap(*card_slot(2))
    s.wait(4)
    s.ftap(CARD_EYE_X, CARD_ROWS_Y[1])
    s.wait(2)
    s.ftap(CARD_EYE_X, CARD_ROWS_Y[2])
    s.wait(4)
    back = Script()
    card_actions(back)
    for step in (lambda: back.ftap(*card_slot(1)), lambda: back.ftap(CARD_EYE_X, CARD_ROWS_Y[1]), lambda: back.ftap(*card_slot(2)),
                 lambda: back.ftap(CARD_EYE_X, CARD_ROWS_Y[1]), lambda: back.ftap(CARD_EYE_X, CARD_ROWS_Y[2]), lambda: back.ftap(*card_slot(1))):
        step()
        back.wait(4)
    return Steps([
        (s, THREE, {"card_actions": near(1), "vis_slot": near(2), "vis_used": near(3), "objects_off": near(1), "dabs": near(0)}),
        (back, THREE, {"vis_slot": near(1), "objects_off": near(1), "dabs": near(0)}),
    ])


@scenario
def objects_card_actions_merge_down_and_split_to_parts():
    """Merge down makes the first two objects one, as one undo step; Split to parts makes them two again, with the third left as it was."""
    merged = Script()
    card_actions(merged)
    merged.ftap(*OBJECTS_CARD["merge"])
    merged.wait(6)
    merged.ftap(*OBJECTS_CARD["merge_down"])
    merged.wait(12)
    split = Script()
    card_actions(split)
    split.ftap(*OBJECTS_CARD["merge"])
    split.wait(6)
    split.ftap(*OBJECTS_CARD["merge_down"])
    split.wait(12)
    # One row fewer: everything under the list is a row higher.
    x, y = OBJECTS_CARD["split"]
    split.ftap(x, y - CARD_ROW_H)
    split.wait(10)
    x, y = OBJECTS_CARD["split_parts"]
    split.ftap(x, y - CARD_ROW_H)
    split.wait(12)
    return Steps([
        # undo_steps counts entries: a merge is two chained (the rebuild and the delete),
        # a split two more (the rebuild and the part it added).
        (merged, THREE, {"objects": near(2), "scene_order": is_text("1,3"), "merged": near(2), "undo_steps": near(2), "dabs": near(0)}),
        (split, THREE, {"objects": near(3), "scene_order": is_text("1,4,3"), "split_made": near(1), "undo_steps": near(4), "dabs": near(0)}),
    ])


@scenario
def objects_card_actions_align_lines_up():
    """Align's X max tile moves the selected object, alone, to the right edge of everything shown, as one undo step."""
    s = Script()
    card_actions(s)
    s.ftap(*OBJECTS_CARD["align"])
    s.wait(10)
    s.fdrag(line((1380, 820), (1380, 560), 12))
    s.wait(20)
    s.ftap(*OBJECTS_CARD["align_x_max"])
    s.wait(6)
    return s, THREE, {"aligned": near(1), "undo_steps": near(1), "dabs": near(0)}


@scenario
def copy_and_paste_an_object():
    """Ctrl+C copies the selected object and Ctrl+V adds it below the selection as one undo step; Ctrl+Z takes it away again."""
    s = Script()
    s.press("c", ("ctrl",))
    s.wait(4)
    s.press("v", ("ctrl",))
    s.wait(6)
    undo = Script()
    undo.press("c", ("ctrl",))
    undo.wait(4)
    undo.press("v", ("ctrl",))
    undo.wait(6)
    undo.press("z", ("ctrl",))
    undo.wait(6)
    return Steps([
        (s, THREE, {"objects": near(4), "scene_order": is_text("1,4,2,3"), "selected": near(1), "undo_steps": near(1), "clipboard_bytes": lambda v: int(v) > 0}),
        (undo, THREE, {"objects": near(3), "scene_order": is_text("1,2,3"), "redo_steps": near(1)}),
    ])


@scenario
def scene_eye_hides_and_shows_an_object():
    """A finger on a row's eye in the Scene tab takes that object out of view without selecting it; a second tap brings it back."""
    hide = Script()
    scene_tab(hide)
    hide.ftap(SCENE_EYE_X, SCENE_ROWS_Y[2])
    hide.wait(6)
    back = Script()
    scene_tab(back)
    back.ftap(SCENE_EYE_X, SCENE_ROWS_Y[2])
    back.wait(6)
    back.ftap(SCENE_EYE_X, SCENE_ROWS_Y[2])
    back.wait(6)
    return Steps([
        (hide, THREE, {"objects_shown": near(2), "objects_off": near(1), "selected": near(0), "dabs": near(0)}),
        (back, THREE, {"objects_shown": near(3), "objects_off": near(0), "selected": near(0)}),
    ])


@scenario
def scene_ghost_lets_a_click_through():
    """A ghost is drawn but out of reach: ghosting the selected sphere hands the selection on, and a Move click on the ghost goes through to the empty space behind, which selects nothing; on a solid sphere the same click selects it."""
    ghost = Script()
    scene_tab(ghost)
    ghost.ftap(SCENE_GHOST_X, SCENE_ROWS_Y[0])
    ghost.wait(6)
    click(ghost, UI["gizmo"])
    click(ghost, SPHERES3[0])
    solid = Script()
    scene_tab(solid)
    solid.ftap(SCENE_ROW_X, SCENE_ROWS_Y[1])
    solid.wait(6)
    click(solid, UI["gizmo"])
    click(solid, SPHERES3[0])
    return Steps([
        (ghost, THREE, {"objects_ghost": near(1), "objects_shown": near(3), "selected": near(-1), "undo_steps": near(0)}),
        (solid, THREE, {"objects_ghost": near(0), "selected": near(0)}),
    ])


@scenario
def h_hides_the_selected_and_alt_h_shows_all():
    """H hides the selected object and selects the next, saying how to bring it back; Alt+H shows every object again and keeps the selection."""
    hide = Script()
    hide.wait(3)
    hide.press("h")
    back = Script()
    back.wait(3)
    back.press("h")
    back.press("h", ["alt"])
    return Steps([
        (hide, THREE, {"objects_off": near(1), "objects_shown": near(2), "selected": near(1), "last_op": lambda v: v.startswith("Hid_Sphere_1"), "undo_steps": near(0)}),
        (back, THREE, {"objects_off": near(0), "objects_shown": near(3), "selected": near(1)}),
    ])


@scenario
def solo_follows_the_row_picked():
    """Shift+S shows only the selected sphere; picking another row moves Solo to it; Shift+S again shows all three."""
    s = Script()
    s.wait(3)
    s.press("s", ["shift"])
    scene_tab(s)
    s.ftap(SCENE_ROW_X, SCENE_ROWS_Y[2])
    s.wait(6)
    again = Script()
    again.wait(3)
    again.press("s", ["shift"])
    again.press("s", ["shift"])
    return Steps([
        (s, THREE, {"solo": near(1), "objects_shown": near(1), "selected": near(2), "objects_off": near(0)}),
        (again, THREE, {"solo": near(0), "objects_shown": near(3)}),
    ])


@scenario
def scene_row_of_a_hidden_object_brings_it_back():
    """A tap on the row of a sphere H hid selects it and puts it back in view, as ZBrush's SubTool list does."""
    s = Script()
    s.wait(3)
    s.press("h")
    scene_tab(s)
    s.ftap(SCENE_ROW_X, SCENE_ROWS_Y[0])
    s.wait(6)
    return s, THREE, {"objects_off": near(0), "objects_shown": near(3), "selected": near(0)}


@scenario
def undo_keeps_an_object_hidden():
    """Undoing a remesh of a sphere hidden since brings back the sphere as it was but keeps it out of view: the eye is not part of the step."""
    s = Script()
    s.wait(3)
    s.press("r", ["ctrl"])
    s.wait(20)
    scene_tab(s)
    s.ftap(SCENE_EYE_X, SCENE_ROWS_Y[0])
    s.wait(6)
    s.press("z", ["ctrl"])
    s.wait(10)
    return s, THREE, {"objects_off": near(1), "objects_shown": near(2), "undo_steps": near(0), "redo_steps": near(1)}


# A folder's row with three spheres after Ctrl+G on the first: its chevron at the left,
# and its menu's rows where a right-click at FOLDER_MENU_AT puts them.
FOLDER_CHEVRON = (1260, 186)
FOLDER_MENU_AT = (1366, 186)
FOLDER_MENU = {"rename": (1376, 214), "select": (1376, 258), "ungroup": (1376, 303), "show_paint": (1376, 347), "hide_paint": (1376, 392), "delete": (1376, 436)}


def folder_first(s):
    """Ctrl+G puts the first sphere in a new folder; then the Scene tab shows it."""
    s.wait(3)
    s.press("g", ["ctrl"])
    scene_tab(s)


@scenario
def ctrl_g_makes_a_folder_and_undo_takes_it_back():
    """Ctrl+G puts the selected sphere in a new folder, one undo step; Ctrl+Z takes the folder away again."""
    make = Script()
    folder_first(make)
    back = Script()
    folder_first(back)
    back.press("z", ["ctrl"])
    return Steps([
        (make, THREE, {"folders": near(1), "scene_folders": is_text("1,0,0"), "undo_steps": near(1), "tree_rows": near(4)}),
        (back, THREE, {"folders": near(0), "scene_folders": is_text("0,0,0"), "undo_steps": near(0), "redo_steps": near(1)}),
    ])


@scenario
def folder_chevron_folds_its_objects():
    """A tap on a folder's chevron folds it: its objects leave the list, nothing is selected or undone."""
    s = Script()
    folder_first(s)
    s.ftap(*FOLDER_CHEVRON)
    s.wait(6)
    return s, THREE, {"tree_rows": near(3), "scene_names": lambda v: v.endswith("Folder_1:folded"), "undo_steps": near(1), "selected": near(0)}


@scenario
def folder_eye_hides_everything_in_it():
    """A folder's eye takes every object in it out of view, and the selection moves on to one still in view."""
    s = Script()
    folder_first(s)
    s.ftap(SCENE_EYE_X, SCENE_ROWS_Y[0])
    s.wait(6)
    return s, THREE, {"objects_off": near(1), "objects_shown": near(2), "selected": near(1), "undo_steps": near(1)}


@scenario
def f2_renames_and_undo_names_it_back():
    """F2 opens a name field for the selected object; typing and Enter renames it as one step, and Ctrl+Z gives it its old name."""
    name = Script()
    name.wait(3)
    name.press("F2")
    name.wait(4)
    name.type("Head")
    name.press("Return")
    back = Script()
    back.wait(3)
    back.press("F2")
    back.wait(4)
    back.type("Head")
    back.press("Return")
    back.press("z", ["ctrl"])
    return Steps([
        (name, THREE, {"scene_names": lambda v: v.startswith("Head,Sphere_2"), "undo_steps": near(1)}),
        (back, THREE, {"scene_names": lambda v: v.startswith("Sphere_1,Sphere_2"), "redo_steps": near(1)}),
    ])


@scenario
def delete_folder_and_undo_brings_both_back():
    """Delete folder in its menu removes the folder with its sphere; one Ctrl+Z brings back both, the sphere in its folder."""
    gone = Script()
    folder_first(gone)
    gone.add(f"move:{FOLDER_MENU_AT[0]},{FOLDER_MENU_AT[1]}")
    gone.wait(1)
    gone.add("rdown")
    gone.wait(1)
    gone.add("rup")
    gone.wait(6)
    click(gone, FOLDER_MENU["delete"])
    back = Script()
    folder_first(back)
    back.add(f"move:{FOLDER_MENU_AT[0]},{FOLDER_MENU_AT[1]}")
    back.wait(1)
    back.add("rdown")
    back.wait(1)
    back.add("rup")
    back.wait(6)
    click(back, FOLDER_MENU["delete"])
    back.wait(4)
    back.press("z", ["ctrl"])
    back.wait(6)
    return Steps([
        (gone, THREE, {"objects": near(2), "folders": near(0), "scene_order": is_text("2,3")}),
        # One Ctrl+Z takes back both entries of the step (the tree's and the sphere's), and
        # leaves Ctrl+G's.
        (back, THREE, {"objects": near(3), "folders": near(1), "scene_folders": is_text("1,0,0"), "scene_order": is_text("1,2,3"), "redo_steps": near(2), "undo_steps": near(1)}),
    ])


@scenario
def folders_come_back_from_the_scene_file():
    """A scene saved with a folded, hidden, renamed folder opens with it as it was."""
    path = scene_file()
    shutil.rmtree(os.path.dirname(path), ignore_errors=True)
    os.makedirs(os.path.dirname(path))
    save = Script()
    folder_first(save)
    save.ftap(*FOLDER_CHEVRON)
    save.wait(4)
    save.ftap(SCENE_EYE_X, SCENE_ROWS_Y[0])
    save.wait(6)
    opened = Script()
    opened.wait(4)
    return Steps([
        (save, THREE + [f"--save={path}"], {"folders": near(1)}),
        (opened, [f"--open={path}"], {"folders": near(1), "scene_folders": is_text("1,0,0"), "objects_off": near(1), "scene_names": lambda v: v.endswith("Folder_1:folded"), "selected": near(1)}),
    ])


SCENE_GRIP_X = 1260  # an object row's grip, outside folders


@scenario
def grip_drag_moves_a_row_and_undo_puts_it_back():
    """A mouse drag on the third row's grip up above the first moves that object to the top of the list as one undo step, keeping the selection on the same object; Ctrl+Z puts it back."""
    drag = Script()
    scene_tab(drag)
    drag.mouse_drag(line((SCENE_GRIP_X, SCENE_ROWS_Y[2]), (SCENE_GRIP_X, SCENE_ROWS_Y[0] - 22), 8))
    drag.wait(4)
    back = Script()
    scene_tab(back)
    back.mouse_drag(line((SCENE_GRIP_X, SCENE_ROWS_Y[2]), (SCENE_GRIP_X, SCENE_ROWS_Y[0] - 22), 8))
    back.wait(4)
    back.press("z", ["ctrl"])
    return Steps([
        (drag, THREE, {"scene_order": is_text("3,1,2"), "undo_steps": near(1), "selected": near(1), "dabs": near(0)}),
        (back, THREE, {"scene_order": is_text("1,2,3"), "undo_steps": near(0), "redo_steps": near(1), "selected": near(0)}),
    ])


@scenario
def finger_drags_an_object_into_a_folder():
    """A finger on a grip drags the row rather than scrolling the inspector: Sphere 3 dropped on the middle of Folder 1's row goes into it, after Sphere 1."""
    s = Script()
    folder_first(s)
    s.fdrag(line((SCENE_GRIP_X, SCENE_ROWS_Y[2] + 54), (SCENE_GRIP_X, SCENE_ROWS_Y[0]), 10))
    s.wait(4)
    return s, THREE, {"scene_order": is_text("1,3,2"), "scene_folders": is_text("1,1,0"), "undo_steps": near(2), "inspector_scroll": near(0)}


@scenario
def column_drag_hides_every_row_it_crosses():
    """A mouse pressed on the first row's eye and dragged down the column hides each object it passes, as one sweep, and none of them is an undo step."""
    s = Script()
    scene_tab(s)
    s.mouse_drag(line((SCENE_EYE_X, SCENE_ROWS_Y[0]), (SCENE_EYE_X, SCENE_ROWS_Y[2] + 10), 6))
    s.wait(6)
    return s, THREE, {"objects_off": near(3), "objects_shown": near(0), "undo_steps": near(0), "selected": near(-1)}


@scenario
def finger_holds_a_ghost_then_slides_down_the_column():
    """A finger held on a ghost toggle until its tooltip shows takes the column: sliding down makes the first two objects ghosts, the selection moving to the third; a quick drag would have scrolled the panel."""
    s = Script()
    scene_tab(s)
    s.add(f"fdown:0:{SCENE_GHOST_X},{SCENE_ROWS_Y[0]}")
    s.wait(LONG_PRESS_FRAMES + 4)
    for x, y in line((SCENE_GHOST_X, SCENE_ROWS_Y[0]), (SCENE_GHOST_X, SCENE_ROWS_Y[1] + 5), 6)[1:]:
        s.add(f"fmove:0:{x:g},{y:g}")
        s.wait(1)
    s.add("fup:0")
    s.wait(6)
    return s, THREE, {"objects_ghost": near(2), "objects_off": near(0), "selected": near(2), "inspector_scroll": near(0)}


SELECT_SEVERAL = (1499, 348)  # the Scene tab's switch, with three spheres and one selected


@scenario
def shift_click_rows_then_drag_moves_both():
    """Shift + click on the third row adds it to the selection; dragging the first sphere's body with the Move tool moves both by the same amount, the second staying put, and one Ctrl+Z puts both back."""
    def build(undo):
        s = Script()
        scene_tab(s)
        s.add("key:shift")
        click(s, (SCENE_ROW_X, SCENE_ROWS_Y[2]))
        s.add("keyup:shift")
        s.wait(2)
        click(s, UI["gizmo"])
        s.mouse_drag(line(SPHERES3[0], (SPHERES3[0][0] + 80, SPHERES3[0][1]), 8))
        if undo:
            s.press("z", ["ctrl"])
        return s

    def moved_together(v):
        p = [tuple(float(c) for c in o.split(":")) for o in v.split(",")]
        d0 = [a - b for a, b in zip(p[0], (0, 0, 0))]
        d2 = [a - b for a, b in zip(p[2], (4.5, 0, 0))]
        return abs(d0[0]) > 0.2 and all(abs(a - b) < 1e-3 for a, b in zip(d0, d2)) and p[1] == (2.25, 0, 0)

    return Steps([
        (build(False), THREE, {"selected_count": near(2), "scene_positions": moved_together, "transform_undo": near(2)}),
        (build(True), THREE, {"scene_positions": is_text("0.000:0.000:0.000,2.250:0.000:0.000,4.500:0.000:0.000"), "undo_steps": near(0), "redo_steps": near(2)}),
    ])


@scenario
def shift_click_objects_in_the_viewport():
    """With the Move tool, Shift + click on the third sphere adds it to the selection without moving anything; then, with Select several on, a finger tap on empty space misses and keeps both selected."""
    s = Script()
    click(s, UI["gizmo"])
    s.add("key:shift")
    click(s, SPHERES3[2])
    s.add("keyup:shift")
    s.wait(2)
    scene_tab(s)
    s.ftap(*SELECT_SEVERAL)
    s.wait(4)
    s.ftap(300, 700)
    s.wait(6)
    return s, THREE, {"selected_count": near(2), "selected": near(2), "undo_steps": near(0), "scene_positions": is_text("0.000:0.000:0.000,2.250:0.000:0.000,4.500:0.000:0.000")}


@scenario
def select_several_with_a_finger_then_delete_takes_both():
    """With Select several on, a finger tap on a row adds it rather than replacing the selection; Delete then takes both objects as one undo step."""
    s = Script()
    scene_tab(s)
    s.ftap(*SELECT_SEVERAL)
    s.wait(4)
    s.ftap(SCENE_ROW_X, SCENE_ROWS_Y[1])
    s.wait(4)
    s.press("Delete")
    s.wait(4)
    return s, THREE, {"objects": near(1), "scene_order": is_text("3"), "undo_steps": near(2)}


@scenario
def duplicate_copies_the_whole_selection():
    """Ctrl+Shift+D with two objects selected copies both, keeping their spacing, and the copies become the selection; one Ctrl+Z takes both copies away."""
    def build(undo):
        s = Script()
        scene_tab(s)
        s.add("key:shift")
        click(s, (SCENE_ROW_X, SCENE_ROWS_Y[2]))
        s.add("keyup:shift")
        s.wait(2)
        s.press("d", ["ctrl", "shift"])
        s.wait(4)
        if undo:
            s.press("z", ["ctrl"])
            s.wait(4)
        return s

    def spaced(v):
        p = [tuple(float(c) for c in o.split(":")) for o in v.split(",")]
        # The copies follow their sources in the list: 1, copy of 1, 2, 3, copy of 3.
        return len(p) == 5 and all(abs((p[4][i] - p[1][i]) - (p[3][i] - p[0][i])) < 1e-3 for i in range(3))

    return Steps([
        (build(False), THREE, {"objects": near(5), "selected_count": near(2), "scene_positions": spaced, "undo_steps": near(2)}),
        (build(True), THREE, {"objects": near(3), "redo_steps": near(2)}),
    ])


@scenario
def folder_menu_selects_its_objects():
    """A folder's menu selects every object in it, the first carrying the gizmo: Sphere 2 dragged into Sphere 1's folder, then Select its objects."""
    s = Script()
    folder_first(s)
    s.mouse_drag(line((SCENE_GRIP_X, SCENE_ROWS_Y[2]), (SCENE_GRIP_X, SCENE_ROWS_Y[0]), 8))
    s.wait(4)
    s.add(f"move:{FOLDER_MENU_AT[0]},{FOLDER_MENU_AT[1]}")
    s.wait(1)
    s.add("rdown")
    s.wait(1)
    s.add("rup")
    s.wait(6)
    click(s, FOLDER_MENU["select"])
    s.wait(4)
    return s, THREE, {"scene_folders": is_text("1,1,0"), "selected_count": near(2), "selected": near(0)}


@scenario
def long_press_on_a_folded_docked_header_opens_its_options():
    """A long press on the docked tray's folded header opens Panel options, as a right-click does, and leaves it folded; a tap then unfolds it."""
    s = Script()
    s.ftap(*INSPECTOR_MINIMISE)
    s.wait(4)
    long_press(s, *INSPECTOR_TITLE)
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "window_inspector": lambda v: v.startswith("1,1,"), "panel_menu": near(1),
                                "long_tip": lambda v: v == "none"})


@scenario
def tap_on_a_folded_docked_header_unfolds_it():
    """A tap on the docked tray's folded header opens it again."""
    s = Script()
    s.ftap(*INSPECTOR_MINIMISE)
    s.wait(4)
    s.ftap(*INSPECTOR_TITLE)
    s.wait(4)
    return s, [], camera_still({"dabs": near(0), "window_inspector": lambda v: v.startswith("1,0,"), "panel_menu": near(0)})


@scenario
def a_press_short_of_long_still_taps():
    """A finger held 0.2 s on the Inspector button, short of the 0.25 s Hold delay, is still a tap: no tooltip, and the inspector closes."""
    s = Script()
    x, y = INSPECTOR_BUTTON
    s.add(f"fdown:0:{x:g},{y:g}")
    s.wait(12)
    s.add(f"fup:0")
    s.wait(4)
    return s, [], camera_still({"long_tip": lambda v: v == "none", "window_inspector": lambda v: v.startswith("0,")})


STATUS_CHIP = UI["status"]


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
    s.ftap(*UI["list_object"])
    s.wait(6)
    long_press(s, *UI["dock_smooth"])
    s.wait(10)
    s.ftap(*SLOT_SETTINGS)
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "brush_kind": lambda v: v == "smooth", "inspector_tab": lambda v: v == "tool",
                                "window_inspector": lambda v: v.startswith("1,0,"), "dock_menu": near(0)})


DEFAULT_DOCK = "Draw,Smooth,Clay,Flatten,Inflate,Grab,Mask"
# The slot menu over the dock's Smooth at 1600 by 900. It grows up from the dock, so
# Brush settings is where it sits with no preset, Pinch and the first preset where they
# sit with one, and Reset dock, at its foot, the same either way.
SLOT_SETTINGS, SLOT_PINCH, SLOT_PRESET, SLOT_RESET = (410, 190), (367, 330), (367, 678), (400, 774)
# The brush browser opened from the dock, at 1600 by 900: its header's Search, the
# heart beside the current brush, the categories down its left, its tiles' middles
# (three columns, the first row at the top) and its A to Z index.
BROWSER_SEARCH, BROWSER_HEART = (1079, 89), (724, 191)
BROWSER_CATEGORY = {"recent": (690, 264), "favorites": (690, 312), "all": (690, 360), "move": (690, 552),
                    "mask": (690, 648), "clip": (690, 744)}
BROWSER_COLUMNS, BROWSER_ROWS = (860, 964, 1068), (163, 275, 387, 499, 611, 723)
BROWSER_INDEX_X, BROWSER_INDEX_A, BROWSER_INDEX_STEP = 1139, 135, 25.85


def browser_tile(column, row):
    """The middle of the brush browser's tile in `column` and `row` (from 0) as scrolled."""
    return BROWSER_COLUMNS[column], BROWSER_ROWS[row]


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
    """The brush browser's Search finds your preset Soft clay by part of its name, in any
    case; a tap on it puts the brush on it and closes the browser."""
    s = Script()
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(*BROWSER_SEARCH)
    s.wait(4)
    s.type("SOFT")
    s.wait(4)
    s.ftap(*browser_tile(0, 0))
    s.wait(6)
    return s, [one_preset_settings()], camera_still({"dabs": near(0), "preset": near(1), "preset_name": is_text("Soft_clay"), "browser": near(0),
                                                     "brush_browser_picks": near(1)})


@scenario
def browser_picks_a_built_in_preset():
    """The brush browser's Move category lists Grab and the library's moves alphabetically:
    a tap on the third, Move all depth, puts the brush on it (Grab reaching through the
    depth) and closes the browser."""
    s = Script()
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(*BROWSER_CATEGORY["move"])
    s.wait(6)
    s.ftap(*browser_tile(2, 0))
    s.wait(6)
    return s, [one_preset_settings()], camera_still({"dabs": near(0), "preset_name": is_text("Move_all_depth"), "brush_kind": is_text("grab"),
                                                     "brush_grab_depth": near(1), "browser": near(0)})


@scenario
def browser_picks_the_knife_and_mask_lasso():
    """The brush browser lists the hide and cut tools under Clip and hide and the mask
    shapes under Mask: a tap on Knife (Clip, Hide lasso, Hide rectangle, Knife) makes it
    what Ctrl + Shift + drag runs and closes the browser, leaving the brush held; a tap on
    Mask lasso (Mask, Mask lasso) does the same for Ctrl + drag's shape, and the browser
    stays on the last category."""
    s = Script()
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(*BROWSER_CATEGORY["clip"])
    s.wait(6)
    s.ftap(*browser_tile(0, 1))
    s.wait(6)
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(*BROWSER_CATEGORY["mask"])
    s.wait(6)
    s.ftap(*browser_tile(1, 0))
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "gesture": is_text("knife"), "mask_shape": is_text("lasso"),
                                "brush_kind": is_text("draw"), "browser": near(0), "brush_category": is_text("mask")})


@scenario
def browser_heart_keeps_a_favorite():
    """The heart beside the current brush puts it in Favorites, whose count and list show
    it; a brush picked from the dock comes first in Recent; both are remembered."""
    s = Script()
    s.ftap(*UI["dock_smooth"])
    s.wait(4)
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(*BROWSER_HEART)
    s.wait(4)
    s.ftap(*BROWSER_CATEGORY["favorites"])
    s.wait(6)
    s.ftap(*browser_tile(0, 0))
    s.wait(6)
    return Steps([
        (s, [f"--settings-file={settings_file()}"],
         camera_still({"dabs": near(0), "brush_kind": is_text("smooth"), "brush_favorites": near(1), "brush_recent": near(1),
                       "brush_category": is_text("favorites"), "browser": near(0), "brush_browser_picks": near(1)})),
        (Script(), [f"--settings-file={settings_file()}"], {"brush_favorites": near(1), "brush_recent": near(1), "brush_category": is_text("favorites")}),
    ])


@scenario
def browser_index_jumps_to_a_letter():
    """A tap on S in the brush browser's A to Z index scrolls All to the brushes starting
    with S: as far down as the grid goes, which puts Sharp crease in the third row's first
    tile, where a tap picks it."""
    s = Script()
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(BROWSER_INDEX_X, BROWSER_INDEX_A + BROWSER_INDEX_STEP * (ord("S") - ord("A")))
    s.wait(16)
    s.ftap(*browser_tile(0, 2))
    s.wait(6)
    return s, [], camera_still({"dabs": near(0), "preset_name": is_text("Sharp_crease"), "browser": near(0)})


@scenario
def knife_cuts_away_the_shaded_side():
    """Ctrl + Shift + drag down the middle with Knife the gesture tool cuts the sphere and
    throws away the half on the right of the drag (the screen's left, going down), closing
    the cut, as one undo step that Ctrl+Z takes back; Alt keeps that half instead (the
    sum of the kept coordinates changes sign). A recording layer comes across, a dynamic topology
    sphere is compacted and cut too, and the script's `knife x` cuts across the middle."""
    def cut(keys=("ctrl", "shift"), undo=False):
        s = Script()
        s.wait(3)
        s.mouse_drag(line((800, 60), (800, 840), 10), keys=keys)
        s.wait(5)
        if undo:
            s.press("z", ("ctrl",))
            s.wait(5)
        return s
    settings = settings_file()
    os.makedirs(os.path.dirname(settings), exist_ok=True)
    with open(settings, "w") as f:
        f.write("version 1\ngesture knife\n")
    use = f"--settings-file={settings}"
    # Half the sphere's 40962 vertices and the cap closing the cut, which is as dense as
    # the cut's edges.
    half = lambda v: 20481 < int(v) < 40962
    steps = [(cut(), [use], {"objects": near(1, 0), "vertices": half, "undo_steps": near(1, 0), "mesh_sum": lambda v: float(v) > 1000}),
             (cut(undo=True), [use], {"objects": near(1, 0), "vertices": near(40962, 0), "undo_steps": near(0, 0)}),
             (cut(keys=("ctrl", "shift", "alt")), [use], {"objects": near(1, 0), "vertices": half, "undo_steps": near(1, 0), "mesh_sum": lambda v: float(v) < -1000}),
             (cut(), [use, "--script=new_layer"], {"vertices": half, "layers": near(1, 0), "layers_noted": near(1, 0)}),
             (cut(), [use, "--script=dyntopo_toggle on"], {"objects": near(1, 0), "vertices": half}),
             (Script(), ["--script=knife x"], {"objects": near(1, 0), "vertices": half})]
    return Steps([(sc, args, camera_still(want)) for sc, args, want in steps])


# The Assign key popover beside the Palettes button, at 1600 by 900: Use it here and Keep
# it there on a conflict; the palette's Star, Put in a pie and Assign key with "wire"
# typed (three rows: Wireframe, Wipe compare, New scene: Figure), and its first row with nothing typed under the STARRED caption.
BIND_USE_HERE, BIND_KEEP = (1343, 367), (1507, 367)
PALETTE_STAR, PALETTE_PIE, PALETTE_ASSIGN = (1192, 430), (1328, 430), (1466, 430)
PALETTE_FIRST_STARRED = (1195, 235)
# The pie editor opened from the palette: Pie 1's first slot and Pie 3's.
EDITOR_PIE1_FIRST, EDITOR_PIE3_FIRST = (1104, 296), (1104, 463)
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
    s.ftap(1195, 211)
    s.wait(6)
    s.ftap(638, 855)  # over the dock's Flatten, under the pie's Orthographic slice
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
    s.add("move:1148,206")
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
KEYS_SEARCH, KEYS_FIRST_ROW = (1334, 497), (1334, 573)


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
    s.ftap(*UI["size"])
    s.wait(12)
    x, y = UI["size_slider"]
    s.fdrag(line((x, y), (x, y - 80), 10))
    long_press(s, x, y)
    return s, [], camera_still({"dabs": near(0), "brush_radius_px": near(60)})


@scenario
def size_slider_drag_still_slides():
    """A drag on the size slider (the control check for the reset above) changes the size and sculpts nothing."""
    s = Script()
    s.ftap(*UI["size"])
    s.wait(12)
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
    return s, ["--script=set finger_model orbit; set orbit_style turntable"], {
        "pinned": near(1), "pivot_source": lambda v: v == "tapped", "@pivot": pivot_on_front,
        "dabs": near(0), "undo_steps": near(0), "camera_yaw": lambda v: abs(float(v) - 0.6) > 0.5}


@scenario
def pinned_pivot_ends_with_the_next_stroke():
    """A pin lasts until the next stroke ends: the pen's stroke on the model unpins it."""
    s = Script()
    double_tap(s, *MODEL)
    s.wait(6)
    pen_stroke(s, line((760, 430), (860, 470), 20))
    return s, ["--script=set finger_model orbit"], {"pinned": near(0), "undo_steps": near(1)}


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
    return s, ["--script=set orbit_style turntable"], {"camera_yaw": lambda v: float(v) < 0.6 - 0.5, "dabs": near(0), "undo_steps": near(0), "redo_steps": near(0)}


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
    return s, ["--script=set orbit_style turntable"], {"camera_yaw": near(0.6), "camera_pitch": near(0.35), "camera_distance": lambda v: float(v) < 3.4, "dabs": near(0)}


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
def one_finger_tap_runs_its_command():
    """With One-finger tap set to Wireframe, a tap on empty space turns wireframe on once no second tap came, and sculpts nothing."""
    s = Script()
    write_settings("gesture_map One_Tap Wireframe\n")
    s.ftap(*EMPTY)
    s.wait(24)
    return s, [f"--settings-file={settings_file()}"], camera_still({"wireframe": near(1), "dabs": near(0), "framed": near(0)})


@scenario
def one_finger_tap_gives_way_to_a_double_tap():
    """With One-finger tap set to Wireframe, a double tap on empty space still frames the object, and wireframe stays off."""
    s = Script()
    write_settings("gesture_map One_Tap Wireframe\n")
    zoom_a_little(s)
    double_tap(s, *EMPTY)
    s.wait(24)
    return s, [f"--settings-file={settings_file()}"], {"camera_distance": near(3.5), "framed": near(1), "wireframe": near(0)}


@scenario
def one_finger_tap_dropped_by_the_pen():
    """A finger's tap on empty space that the pen comes near within the gap was the hand, not a tap: wireframe stays off."""
    s = Script()
    write_settings("gesture_map One_Tap Wireframe\n")
    s.ftap(*EMPTY, gap=2)
    s.add("pnear")
    s.add("pmove:800,450")
    s.wait(24)
    s.add("pfar")
    s.wait(3)
    return s, [f"--settings-file={settings_file()}"], camera_still({"wireframe": near(0), "dabs": near(0)})


@scenario
def one_finger_tap_keeps_the_move_selection():
    """With the Move tool, a tap on empty space runs One-finger tap's command in place of clearing the selection."""
    s = Script()
    write_settings("gesture_map One_Tap Wireframe\n")
    s.press("w")
    s.ftap(*EMPTY)
    s.wait(24)
    return s, [f"--settings-file={settings_file()}"], camera_still({"wireframe": near(1), "selected": near(0), "tool": is_text("move")})


@scenario
def gesture_any_command_from_search():
    """Settings > Touch: Pen side button's Any command... opens the search to choose; Wireframe picked there then runs from the pen's side button, and nothing ran while choosing."""
    s = Script()
    open_settings(s, "touch")
    s.add("move:1330,600")
    s.wait(1)
    # Down to the end of the tab, where the gesture map's last row is Pen side button.
    for _ in range(14):
        s.add("wheel:-5")
        s.wait(2)
    s.wait(10)
    s.ftap(1333, 504)
    s.wait(12)
    # Its list opens above it; the list's last row is Any command...
    for _ in range(10):
        s.fdrag(line((1330, 440), (1330, 20), 10))
        s.wait(4)
    s.wait(20)
    s.ftap(1250, 454)
    s.wait(14)
    s.type("wireframe")
    s.press("Return")
    s.wait(6)
    s.ftap(1427, 750)
    s.wait(16)
    s.add("pnear")
    s.add("pmove:800,450")
    s.wait(4)
    s.add("pright")
    s.wait(6)
    return s, [], camera_still({"wireframe": near(1), "palette": near(0), "palette_runs": near(0), "pie_open": near(-1), "dabs": near(0)})


# Gap list PR 4: the wheel's two-finger resize and turn, its labels, the pen's hover names and roll.

@scenario
def wheel_two_fingers_spread_resize_it():
    """Two fingers on the wheel's ring spreading apart make it larger (the nearest size, 3XL here), latch nothing and sculpt nothing."""
    s = Script()
    s.add("fdown:8:78,770")
    s.add("fdown:9:78,874")
    s.wait(2)
    for k in range(1, 16):
        s.add(f"fmove:8:78,{770 - 4 * k:g}")
        s.add(f"fmove:9:78,{874 + 1.4 * k:g}")
        s.wait(1)
    s.add("fup:8")
    s.add("fup:9")
    s.wait(4)
    return s, [], camera_still({"wheel_size": is_text("xl3"), "wheel_turn": near(0), "rail_latched": is_text("none"), "dabs": near(0)})


@scenario
def wheel_two_fingers_twist_turn_it():
    """Two fingers on the wheel's ring, one on the brush pie's sector, twisted 45 degrees clockwise turn it 45 degrees, keep its size and open no pie."""
    s = Script()
    s.add("fdown:8:35,822")
    s.wait(1)
    s.add("fdown:9:121,822")
    s.wait(2)
    for k in range(1, 16):
        a = math.radians(3 * k)
        s.add(f"fmove:8:{78 - 43 * math.cos(a):.2f},{822 - 43 * math.sin(a):.2f}")
        s.add(f"fmove:9:{78 + 43 * math.cos(a):.2f},{822 + 43 * math.sin(a):.2f}")
        s.wait(1)
    s.add("fup:8")
    s.add("fup:9")
    s.wait(4)
    return s, [], camera_still({"wheel_size": is_text("medium"), "wheel_turn": near(45), "rail_latched": is_text("none"), "pie_open": near(-1), "dabs": near(0)})


@scenario
def wheel_turned_taps_the_turned_sector():
    """With the wheel turned a quarter turn clockwise, Smooth sits on the right: a tap there latches Smooth."""
    s = Script()
    s.ftap(121, 822, finger=RAIL_FINGER)
    return s, ["--script=set wheel_turn 90; set wheel_labels icons_and_names"], camera_still({"rail_latched": is_text("smooth"), "wheel_labels": is_text("icons_and_names"), "pie_open": near(-1)})


def pen_hover(s, x, y, frames=60):
    s.add("pnear")
    s.add(f"pmove:{x:g},{y:g}")
    s.wait(frames)


@scenario
def pen_hover_shows_the_name():
    """The pen held over the brush bar's Draw size without touching shows its name, as the mouse resting on it does."""
    s = Script()
    pen_hover(s, *UI["size"])
    return s, [], camera_still({"tip_showing": lambda v: v.startswith("Draw_size"), "dabs": near(0)})


@scenario
def pen_hover_names_off():
    """With Names while the pen hovers set to Never, the hovering pen shows no name; the mouse still does."""
    s = Script()
    pen_hover(s, *UI["size"])
    pen = Script()
    pen.events, pen.frame = list(s.events), s.frame
    mouse = Script()
    mouse.add(f"move:{UI['size'][0]:g},{UI['size'][1]:g}")
    mouse.wait(60)
    return Steps([(pen, ["--script=set pen_tips never"], camera_still({"tip_showing": is_text("none")})),
            (mouse, ["--script=set pen_tips never"], camera_still({"tip_showing": lambda v: v.startswith("Draw_size")}))])


@scenario
def pen_roll_sets_the_size():
    """The pen hovering on Draw size and turned a quarter turn clockwise, across the half turn where its numbers wrap, doubles the size and shows the readout."""
    s = Script()
    pen_hover(s, *UI["size"], frames=4)
    for deg in (150, 170, -170, -150, -120):
        s.add(f"proll:{deg}")
        s.wait(2)
    return s, [], camera_still({"brush_radius_px": near(2 * 60, 0.5), "dabs": near(0)})


def camera_back(stats):
    """The camera's back direction (toward the viewer) from its yaw and pitch, as orbit_basis has it."""
    y, p = float(stats["camera_yaw"]), float(stats["camera_pitch"])
    return (math.cos(p) * math.sin(y), math.sin(p), math.cos(p) * math.cos(y))


def axis_orbit(axis):
    """A finger dragged sideways on empty space turns the view about the world's `axis` only: the eye keeps its height along that axis."""
    s = Script()
    s.fdrag(past_slop(EMPTY, (EMPTY[0] + 120, EMPTY[1]), 20))
    s.wait(3)
    b0 = (math.cos(0.35) * math.sin(0.6), math.sin(0.35), math.cos(0.35) * math.cos(0.6))
    def check(stats):
        b = camera_back(stats)
        if abs(b[axis] - b0[axis]) >= 2e-3:
            return f"the eye's height along the axis moved from {b0[axis]:.4f} to {b[axis]:.4f}"
        return True
    return s, check


@scenario
def x_axis_orbit_setting():
    """With the X axis orbit style, a sideways finger drag on empty space turns the view about the world's X axis."""
    s, check = axis_orbit(0)
    return s, ["--script=set orbit_style axis_x"], {"camera_distance": near(3.5), "camera_pitch": lambda v: abs(float(v) - 0.35) > 0.05, "dabs": near(0), "@axis": check}


@scenario
def z_axis_orbit_setting():
    """With the Z axis orbit style, a sideways finger drag on empty space turns the view about the world's Z axis."""
    s, check = axis_orbit(2)
    return s, ["--script=set orbit_style axis_z"], {"camera_distance": near(3.5), "dabs": near(0), "@axis": check}


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
    s.fdrag(line((1334, 700), (1338, 300), 20))
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
    shutil.rmtree(macros_folder(), ignore_errors=True)
    shutil.rmtree(library_folder(), ignore_errors=True)
    shutil.rmtree(link_folder(), ignore_errors=True)
    shutil.rmtree(plugins_folder(), ignore_errors=True)
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
    # The scenarios were written against the Classic layout and keep its coordinates; a
    # scenario of the Lens layout says so with --chrome=lens.
    if not any(a.startswith("--chrome") for a in args):
        cmd.append("--chrome=classic")
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
            except (KeyError, ValueError, OSError):
                good = False
            # A check may say what was wrong instead of only False.
            if isinstance(good, str):
                failures.append(f"{key} wrong: {good}")
            elif not good:
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


def file_difference(a, b):
    """True when files `a` and `b` hold the same bytes, else where they differ, so a rare
    mismatch says something the next time it happens (both files are kept)."""
    x, y = open(a, "rb").read(), open(b, "rb").read()
    if x == y:
        return True
    at = next((i for i in range(min(len(x), len(y))) if x[i] != y[i]), min(len(x), len(y)))
    return f"{len(x)} bytes against {len(y)}, first difference at byte {at} ({a} and {b})"


def glb_read(path):
    """A .glb's shape keys (name, weight) and its base positions with every key added at
    its weight: the surface a reader shows at the file's own values."""
    import json
    data = open(path, "rb").read()
    json_len = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + json_len])
    bin_at = 20 + json_len + 8
    mesh = doc["meshes"][0]
    prim = mesh["primitives"][0]

    def view(index):
        v = doc["bufferViews"][index]
        return data[bin_at + v.get("byteOffset", 0):][:v["byteLength"]]

    pos = doc["accessors"][prim["attributes"]["POSITION"]]
    flat = struct.unpack("<%df" % (3 * pos["count"]), view(pos["bufferView"]))
    points = [list(flat[3 * v:3 * v + 3]) for v in range(pos["count"])]
    weights = mesh.get("weights", [])
    for target, weight in zip(prim.get("targets", []), weights):
        sparse = doc["accessors"][target["POSITION"]].get("sparse")
        if not sparse or weight == 0:
            continue
        n = sparse["count"]
        at = struct.unpack("<%dI" % n, view(sparse["indices"]["bufferView"]))
        d = struct.unpack("<%df" % (3 * n), view(sparse["values"]["bufferView"]))
        for i, v in enumerate(at):
            for k in range(3):
                points[v][k] += weight * d[3 * i + k]
    names = mesh.get("extras", {}).get("targetNames", [])
    return list(zip(names, weights)), points


def usda_read(path):
    """A .usda's blend shapes (name, weight) and its points with every shape added at its
    weight, as glb_read gives a .glb's."""
    import re
    text = open(path).read()

    def tuples(name):
        body = re.search(name + r" = \[([^\]]*)\]", text).group(1)
        return [[float(x) for x in t.split(",")] for t in re.findall(r"\(([^)]*)\)", body)]

    points = tuples(r"point3f\[\] points")
    names = re.findall(r'"((?:[^"\\]|\\.)*)"', re.search(r"skel:blendShapes = \[([^\]]*)\]", text).group(1)) if "skel:blendShapes" in text else []
    weights = [float(x) for x in re.search(r"float\[\] blendShapeWeights = \[([^\]]*)\]", text).group(1).split(",")] if names else []
    shapes = re.findall(r"offsets = \[([^\]]*)\]\s*uniform int\[\] pointIndices = \[([^\]]*)\]", text)
    for (offsets, indices), weight in zip(shapes, weights):
        d = [[float(x) for x in t.split(",")] for t in re.findall(r"\(([^)]*)\)", offsets)]
        for v, off in zip((int(i) for i in indices.split(",")), d):
            for k in range(3):
                points[v][k] += weight * off[k]
    return list(zip(names, weights)), points


def obj_points(path):
    return [[float(x) for x in line.split()[1:4]] for line in open(path) if line.startswith("v ")]


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
    # 2M vertices, so the reading lasts several frames even on a busy machine: at 500k
    # the thread could finish before the next frame's press when the gate ran the
    # scenarios side by side, and nothing was left to stop.
    return s, autosave_args("--vertices=2000000"), {"autosave_aborts": lambda v: int(v) >= 1, "autosaves": lambda v: int(v) >= 1, "autosave_torn": near(0, 0)}


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
    same = lambda _: file_difference(control, recovered)
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


# The thumbnail window at 1600x900 (thumbnail.odin), under the object's readout: its
# Shaded tab, Flip and Close.
# The second view (the thumbnail window) at 1600 x 900 with --script=thumbnail on: its
# camera and pass lists and their rows, its Flip, Maximise and Close, its picture, and
# Restore once maximised.
SECOND_CAMERA, SECOND_PASS = (132, 310), (250, 310)
SECOND_FRONT, SECOND_SHADED, SECOND_NORMALS = (107, 404), (250, 404), (250, 448)
THUMBNAIL_FLIP, SECOND_LINK, SECOND_MAX, THUMBNAIL_CLOSE = (100, 365), (152, 365), (205, 365), (258, 365)
SECOND_PICTURE, SECOND_RESTORE = (192, 213), (205, 774)


@scenario
def thumbnail_switches_to_shaded_and_flips():
    """The second view's pass list picks Shaded and its Flip mirrors it, sculpting nothing."""
    s = Script()
    s.wait(4)
    s.ftap(*SECOND_PASS)
    s.wait(4)
    s.ftap(*SECOND_SHADED)
    s.wait(4)
    s.ftap(*THUMBNAIL_FLIP)
    s.wait(10)
    return s, ["--script=thumbnail on"], camera_still({"thumbnail": near(1, 0), "second_pass": is_text("Shaded"), "thumbnail_flip": near(1, 0),
                                                     "thumbnail_draws": lambda v: int(v) >= 2, "dabs": near(0)})


@scenario
def second_view_looks_from_the_front_in_normals():
    """The second view's camera list picks Front and its pass list Normals: it draws again from the front, the main camera untouched."""
    s = Script()
    s.wait(4)
    s.ftap(*SECOND_CAMERA)
    s.wait(4)
    s.ftap(*SECOND_FRONT)
    s.wait(4)
    s.ftap(*SECOND_PASS)
    s.wait(4)
    s.ftap(*SECOND_NORMALS)
    s.wait(10)
    return s, ["--script=thumbnail on"], camera_still({"second_camera": is_text("Front"), "second_pass": is_text("Normals"),
                                                     "thumbnail_draws": lambda v: int(v) >= 3, "dabs": near(0)})


@scenario
def second_view_drag_turns_its_own_camera():
    """A finger dragged across the second view's picture, looking from the front, turns its own camera, which becomes Free; the main camera stays still and nothing is sculpted."""
    s = Script()
    s.wait(4)
    s.ftap(*SECOND_CAMERA)
    s.wait(4)
    s.ftap(*SECOND_FRONT)
    s.wait(4)
    x, y = SECOND_PICTURE
    s.fdrag([(x - 40 + i * 8, y) for i in range(11)])
    s.wait(6)
    return s, ["--script=thumbnail on"], camera_still({"second_camera": is_text("Free"), "second_turns": lambda v: int(v) >= 5,
                                                     "thumbnail_draws": lambda v: int(v) >= 3, "dabs": near(0)})


@scenario
def second_view_linked_drag_turns_the_main_camera():
    """The second view starts linked: a finger dragged across its picture turns the main camera, and the view stays linked; nothing is sculpted."""
    s = Script()
    s.wait(4)
    x, y = SECOND_PICTURE
    s.fdrag([(x - 40 + i * 8, y) for i in range(11)])
    s.wait(6)
    return s, ["--script=thumbnail on"], {"second_camera": is_text("Follow"), "second_linked": lambda v: int(v) >= 5, "second_turns": near(0),
                                         "camera_yaw": lambda v: abs(float(v) - CAMERA0["camera_yaw"]) > 0.05, "dabs": near(0)}


@scenario
def second_view_unlinks_to_free():
    """The second view's link button lets it go to its own Free camera at the view it shows; a drag then turns only it."""
    s = Script()
    s.wait(4)
    s.ftap(*SECOND_LINK)
    s.wait(4)
    x, y = SECOND_PICTURE
    s.fdrag([(x - 40 + i * 8, y) for i in range(11)])
    s.wait(6)
    return s, ["--script=thumbnail on"], camera_still({"second_camera": is_text("Free"), "second_turns": lambda v: int(v) >= 5, "second_linked": near(0), "dabs": near(0)})


@scenario
def second_view_maximises_and_restores():
    """Maximise grows the floating second view's picture to most of the viewport; Restore brings it back to its small size."""
    def run(restore):
        s = Script()
        s.wait(4)
        s.ftap(*SECOND_MAX)
        s.wait(8)
        if restore:
            s.ftap(*SECOND_RESTORE)
            s.wait(8)
        size = (lambda v: v == "232x131") if restore else (lambda v: int(v.split("x")[0]) > 800)
        return s, ["--script=thumbnail on"], camera_still({"second_max": near(0 if restore else 1), "thumbnail_px": size, "dabs": near(0)})
    return Steps([run(False), run(True)])


# Scene: Background's Screenshots without background switch, under the colours.
TRANSPARENT_SWITCH = (1499, 569)


@scenario
def transparent_screenshots_switch_in_the_background_section():
    """A tap on Scene: Background's Screenshots without background switch turns it on, and sculpts
    nothing."""
    s = Script()
    s.wait(4)
    s.ftap(*TRANSPARENT_SWITCH)
    s.wait(4)
    return s, ["--script=show_section background"], camera_still({"screenshot_transparent": near(1, 0), "dabs": near(0)})


# Scene: Turntable's Frames slider knob at 120 frames.
TURNTABLE_FRAMES_KNOB = (1370, 197)


@scenario
def turntable_frames_slider_by_finger():
    """A finger drag left on Scene: Turntable's Frames slider takes fewer frames,
    and turns the camera and sculpts nothing."""
    s = Script()
    s.wait(4)
    x, y = TURNTABLE_FRAMES_KNOB
    s.fdrag(line((x, y), (x - 90, y), 10))
    s.wait(4)
    return s, ["--script=show_section turntable"], camera_still({"turntable_frames": lambda v: 24 <= int(v) < 100, "turntable_written": near(0), "dabs": near(0)})


# The Camera menu's View grid rows at 1600 x 900 (Side by side), and with the tray docked
# on the right, Side by side's divider, its view pane's middle and that pane's Maximise
# (Restore once it fills the grid).
GRID_SIDE_BY_SIDE = (1350, 603)
GRID_DIVIDER = (519, 600)
GRID_PANE = (800, 600)
GRID_PANE_LINK = (812, 93)
GRID_PANE_MAX = (865, 93)
GRID_PANE_WINDOW = (918, 93)
GRID_PANE_RESTORE = (410, 93)
GRID_PANE_CAMERA, GRID_PANE_LINKED, GRID_PANE_MIRRORED = (600, 93), (590, 144), (590, 496)


@scenario
def camera_menu_splits_the_view_side_by_side():
    """The Camera menu's View grid row Side by side splits the viewport: the main view keeps the left half of the room left of the tray, and the view pane beside it looks from the front."""
    s = Script()
    s.wait(3)
    s.ftap(*UI["camera"])
    s.wait(8)
    s.ftap(*GRID_SIDE_BY_SIDE)
    s.wait(10)
    return s, ["--script=set panes_under_panels off"], camera_still({"grid": is_text("Side_By_Side"), "grid_main": lambda v: 450 < float(v.split("x")[0]) < 560,
                                "pane_camera": is_text("Front"), "pane_draws": lambda v: int(v) >= 1, "dabs": near(0)})


@scenario
def panes_run_under_the_panels_by_default():
    """By default the view grid fills the window and the docked tray floats over the right pane: Side by side halves the whole window, and the view pane still draws."""
    s = Script()
    s.wait(10)
    return s, ["--script=view_grid side_by_side"], camera_still({"grid": is_text("Side_By_Side"), "grid_main": lambda v: 780 < float(v.split("x")[0]) < 820,
                                                               "viewport_origin": is_text("0,0"), "pane_draws": lambda v: int(v) >= 1, "dabs": near(0)})


# Wipe compare's knob in the middle of the main view at 1600 x 900, and where its dumped
# viewport is sampled either side of the line, on the sphere.
WIPE_KNOB = (800, 450)
WIPE_LEFT, WIPE_RIGHT = (700, 450), (900, 450)


def wipe_sides(path):
    """A check that the dumped viewport at path shows clay left of the wipe's line and
    the Normals pass's blue-violet right of it."""
    def check(_):
        from ppm import read_ppm
        w, _h, rgb = read_ppm(path)
        def at(p):
            i = (p[1] * w + p[0]) * 3
            return tuple(rgb[i:i + 3])
        left, right = at(WIPE_LEFT), at(WIPE_RIGHT)
        if not (left[0] > left[2] and right[2] > right[0] + 30):
            return f"left {left}, right {right}"
        return True
    return check


@scenario
def wipe_compare_shows_two_passes_in_one_view():
    """Wipe compare from a script shows the Shaded pass left of the line and Normals right of it in one picture of the main view; nothing is sculpted."""
    s = Script()
    s.wait(10)
    path = os.path.join(ROOT, "build", "touch", "wipe_sides.ppm")
    return s, ["--script=view_wipe", f"--dump-viewport={path}"], camera_still({"wipe": near(1), "wipe_right": is_text("Normals"), "wipe_at": near(0.5),
                                                                          "dabs": near(0), "@sides": wipe_sides(path)})


@scenario
def wipe_knob_drag_moves_the_line():
    """A finger dragging wipe compare's knob to the right moves the line with it; the camera stays still and nothing is sculpted."""
    s = Script()
    s.wait(4)
    x, y = WIPE_KNOB
    s.fdrag([(x + i * 10, y) for i in range(16)])
    s.wait(6)
    return s, ["--script=view_wipe"], camera_still({"wipe_at": lambda v: 0.57 < float(v) < 0.62, "wipe_drags": lambda v: int(v) > 0, "dabs": near(0)})


@scenario
def wipe_compare_from_the_pass_menu():
    """Wipe compare from the pass chip's menu turns the wipe on, and a second time off."""
    def run(taps):
        s = Script()
        s.wait(4)
        for _ in range(taps):
            s.ftap(*PASS_CHIP)
            s.wait(8)
            s.ftap(*PASS_MENU_WIPE)
            s.wait(8)
        return s, [], camera_still({"wipe": near(taps % 2), "dabs": near(0)})
    return Steps([run(1), run(2)])


# Proportion guides in the view grid's Four at 1600 x 900 beside the tray: the Brow tag in
# the Front pane (top right).
GUIDE_FRONT_BROW = (1008, 165)


@scenario
def guides_show_in_the_level_side_views_only():
    """Proportion guides with the view grid's Four (perspective main view, Front, Right and Top) draw three lines in the Front pane and three in the Right one, none in Top or the main view; Shown in the main view once it looks from the front orthographic."""
    def run(front):
        s = Script()
        s.wait(30)
        script = "ortho_toggle on; view_axis front; view_guides" if front else "set panes_under_panels off; view_grid four; view_guides"
        return s, [f"--script={script}"], {"guides": near(1), "guide_lines": near(3 if front else 6), "guide_heights": lambda v: abs(float(v.split(",")[2]) + 1) < 0.05, "dabs": near(0)}
    return Steps([run(False), run(True)])


@scenario
def guide_tag_drag_moves_the_guide():
    """A finger dragging the Brow tag down in the Front pane lowers the Brow guide (in every view that shows it); the main camera stays still and nothing is sculpted."""
    s = Script()
    s.wait(30)
    x, y = GUIDE_FRONT_BROW
    s.fdrag(line((x, y), (x, y + 60), 10))
    s.wait(6)
    return s, ["--script=set panes_under_panels off; view_grid four; view_guides"], camera_still({"guide_drags": lambda v: int(v) > 0, "guide_heights": lambda v: float(v.split(",")[0]) < 0.2,
                                                                                         "guide_lines": near(6), "dabs": near(0)})


@scenario
def guides_are_saved_with_the_scene():
    """Guides shown and one dragged are in the saved scene: opening it shows them at the heights they had."""
    path = scene_file()
    shutil.rmtree(os.path.dirname(path), ignore_errors=True)
    os.makedirs(os.path.dirname(path))
    first = Script()
    first.wait(30)
    x, y = GUIDE_FRONT_BROW
    first.fdrag(line((x, y), (x, y + 60), 10))
    first.wait(6)
    moved = {}

    def remember(v):
        moved["heights"] = v
        return float(v.split(",")[0]) < 0.2
    opened = Script()
    opened.wait(4)
    return Steps([(first, ["--script=set panes_under_panels off; view_grid four; view_guides", f"--save={path}"], {"guide_heights": remember}),
                  (opened, [f"--open={path}"], {"guides": near(1), "guide_heights": lambda v: v == moved.get("heights")})])


# A 1024 x 768 window, under the columns' breakpoint: the right column's tab beside the
# navigation head, the right bar's Palettes button, and a point on the view.
NARROW = ["--width=1024", "--height=768"]
NARROW_TAB, NARROW_PALETTES, NARROW_VIEW = (926, 91), (993, 203), (400, 400)


@scenario
def narrow_window_puts_the_column_away():
    """On a window under 1180 points the right column (the tray) starts put away with a tab at its top; a tap on the tab pops it over the view, and a press on the view puts it away again without sculpting."""
    def run(taps):
        s = Script()
        s.wait(6)
        if taps > 0:
            s.ftap(*NARROW_TAB)
            s.wait(8)
        if taps > 1:
            s.ftap(*NARROW_VIEW)
            s.wait(8)
        return s, NARROW, camera_still({"columns_narrow": near(1), "column_popped": is_text("right" if taps == 1 else "none"),
                                        "column_pops": near(1 if taps > 0 else 0), "dabs": near(0), "undo_steps": near(0)})
    return Steps([run(0), run(1), run(2)])


@scenario
def narrow_window_palettes_pops_the_column():
    """On a narrow window Palettes pops the tray's column over the view and a second tap puts it away, the tray staying open in it."""
    def run(taps):
        s = Script()
        s.wait(6)
        for _ in range(taps):
            s.ftap(*NARROW_PALETTES)
            s.wait(8)
        return s, NARROW, camera_still({"column_popped": is_text("right" if taps == 1 else "none"), "window_inspector": lambda v: v.startswith("1,"), "dabs": near(0)})
    return Steps([run(1), run(2)])


@scenario
def narrow_window_opening_a_panel_pops_its_column():
    """On a narrow window a section pinned into the right column pops the column, as opening any panel docked there does; with Columns pop over a narrow window off, the columns stay beside the view."""
    return Steps([(Script(), NARROW + ["--script=pin_section layers"], {"column_popped": is_text("right"), "columns_narrow": near(1)}),
                  (Script(), NARROW + ["--script=set column_popovers off"], {"columns_narrow": near(0), "column_popped": is_text("none")}),
                  (Script(), [], {"columns_narrow": near(0)})])


def workspace_file():
    """The workspace file of the scenario running on this thread."""
    return os.path.join(ROOT, "build", "touch", "settings", CURRENT.name + ".workspace")


@scenario
def workspace_file_carries_a_layout():
    """Inspect exported to a file and imported in a fresh run comes back as a workspace of one's own, "Inspect 2", with Inspect's hidden bars and its four panes, unchanged from what it saved."""
    path = workspace_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    return Steps([(Script(), ["--script=workspace inspect", f"--export-workspace={path}"], {"workspace_exports": near(1), "@written": lambda _: os.path.exists(path)}),
                  (Script(), [f"--import-workspace={path}"], {"workspace": is_text("Inspect%202"), "workspace_imports": near(1), "workspace_count": near(5),
                                                               "workspace_modified": near(0), "zones_hidden": is_text("brush_bar,dock"), "grid": is_text("Four")})])


@scenario
def workspace_file_damaged_is_refused():
    """A file that is not a workspace file is refused with a note: no workspace is added and the layout stays Sculpt's."""
    path = workspace_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("SCULPT_WORKSPACE 9\nname Future\nlayout open\n")
    return Script(), [f"--import-workspace={path}"], {"workspace": is_text("Sculpt"), "workspace_imports": near(0), "workspace_count": near(4)}


@scenario
def stroke_in_the_main_pane_beside_a_left_column():
    """With the tray docked on the left the main pane starts right of it; a stroke inside the pane sculpts where the finger is, not where the window's point would be, and the camera stays still."""
    s = Script()
    s.ftap(*PANEL_OPTIONS)
    s.wait(10)
    s.ftap(*PANEL_MENU_DOCK_LEFT)
    s.wait(10)
    s.fdrag(line((940, 420), (990, 470), 16))
    s.wait(6)
    return s, ["--script=set panes_under_panels off; view_grid side_by_side"], camera_still({"viewport_origin": is_text("562,0"), "dabs": lambda v: int(v) > 0,
                                                                "undo_steps": near(1), "column_left": is_text("inspector")})


@scenario
def view_pane_drag_turns_its_own_camera():
    """With Work in any view off, a finger dragged across the view pane turns its own camera, which becomes Free; the main camera stays still and nothing is sculpted."""
    s = Script()
    s.wait(4)
    x, y = GRID_PANE
    s.fdrag([(x - 40 + i * 8, y) for i in range(11)])
    s.wait(6)
    return s, ["--script=set panes_under_panels off; set panes_work off; view_grid side_by_side"], camera_still({"pane_camera": is_text("Free"), "pane_turns": lambda v: int(v) >= 5, "dabs": near(0)})


@scenario
def grid_divider_drag_moves_the_split():
    """Dragging the divider between the main view and the view pane moves the split, the main view growing; the camera stays still and nothing is sculpted."""
    s = Script()
    s.wait(4)
    s.fdrag(line(GRID_DIVIDER, (GRID_DIVIDER[0] + 120, GRID_DIVIDER[1]), 12))
    s.wait(6)
    return s, ["--script=set panes_under_panels off; view_grid side_by_side"], camera_still({"grid_split": lambda v: float(v.split(",")[0]) > 0.6, "grid_drags": lambda v: int(v) > 0,
                                                                "grid_main": lambda v: float(v.split("x")[0]) > 600, "dabs": near(0)})


@scenario
def view_pane_link_turns_the_main_camera():
    """The view pane's link button links it to the main camera: a drag across it turns the main view with it, and the pane stays linked."""
    s = Script()
    s.wait(4)
    s.ftap(*GRID_PANE_LINK)
    s.wait(4)
    x, y = GRID_PANE
    s.fdrag([(x - 40 + i * 8, y) for i in range(11)])
    s.wait(6)
    return s, ["--script=set panes_under_panels off; set panes_work off; view_grid side_by_side"], {"pane_camera": is_text("Follow"), "pane_links": near(1), "linked_turns": lambda v: int(v) >= 5,
                                                   "pane_turns": near(0), "camera_yaw": lambda v: abs(float(v) - CAMERA0["camera_yaw"]) > 0.05, "dabs": near(0)}


@scenario
def view_pane_mirrored_turns_the_main_camera_the_other_way():
    """Mirrored from the view pane's camera list shows the main camera reflected; a drag to the right across it turns the main camera as a drag to the left on the main view would."""
    def run(mirrored):
        s = Script()
        s.wait(4)
        s.ftap(*GRID_PANE_CAMERA)
        s.wait(4)
        s.ftap(*(GRID_PANE_MIRRORED if mirrored else GRID_PANE_LINKED))
        s.wait(4)
        x, y = GRID_PANE
        s.fdrag([(x - 40 + i * 8, y) for i in range(11)])
        s.wait(6)
        turned = (lambda v: float(v) > CAMERA0["camera_yaw"] + 0.05) if mirrored else (lambda v: float(v) < CAMERA0["camera_yaw"] - 0.05)
        return s, ["--script=set panes_under_panels off; set panes_work off; view_grid side_by_side"], {"pane_camera": is_text("Mirror" if mirrored else "Follow"), "pane_links": near(1),
                                                       "camera_yaw": turned, "dabs": near(0)}
    return Steps([run(True), run(False)])


# Four's Front pane (top right, 1600 x 900, panes beside the docked tray): over the model's
# middle, and a corner of empty space in it.
FOUR_FRONT_MODEL = (778, 225)
FOUR_FRONT_EMPTY = (560, 420)
FOUR_FRONT_LINK = (812, 93)
# The Front pane's Shows select and its AO only and Studio rows.
FOUR_FRONT_PASS, FOUR_FRONT_AO, FOUR_FRONT_STUDIO = (724, 94), (706, 364), (701, 408)


@scenario
def view_pane_stroke_works_in_the_pane():
    """With Work in any view on (the default), a finger stroke on the model in Four's Front pane sculpts there, seen from the front: dabs land, the Front pane stays Front, and the main camera is the same after."""
    s = Script()
    s.wait(30)
    x, y = FOUR_FRONT_MODEL
    s.fdrag(line((x - 40, y), (x + 40, y + 20), 16))
    s.wait(8)
    return s, ["--script=set panes_under_panels off; view_grid four"], camera_still({"pane_works": near(1), "pane_work": near(0), "pane_work_dabs": lambda v: int(v) > 0,
                                                                            "dabs": lambda v: int(v) > 0, "undo_steps": near(1), "pane_camera": is_text("Front")})


@scenario
def view_pane_empty_drag_turns_the_pane():
    """A one-finger drag on empty space in the Front pane turns that pane's camera as the main view's would turn (it becomes Free), never the main camera, and sculpts nothing."""
    s = Script()
    s.wait(30)
    x, y = FOUR_FRONT_EMPTY
    s.fdrag([(x + i * 8, y) for i in range(12)])
    s.wait(8)
    return s, ["--script=set panes_under_panels off; view_grid four"], camera_still({"pane_works": near(1), "pane_work": near(0), "pane_camera": is_text("Free"), "dabs": near(0)})


@scenario
def view_pane_linked_stroke_keeps_the_link():
    """A stroke in a pane linked to the main camera sculpts through the main camera's view and the pane stays linked; the main camera does not move."""
    s = Script()
    s.wait(30)
    s.ftap(*FOUR_FRONT_LINK)
    s.wait(6)
    x, y = FOUR_FRONT_MODEL
    s.fdrag(line((x - 40, y), (x + 40, y + 20), 16))
    s.wait(8)
    return s, ["--script=set panes_under_panels off; view_grid four"], camera_still({"pane_works": near(1), "pane_work_dabs": lambda v: int(v) > 0,
                                                                                                   "pane_camera": is_text("Follow")})


@scenario
def view_pane_studio_gathers_at_rest():
    """Studio in the Front pane's Shows gathers the studio's samples while the app rests, and a stroke in the main view starts them over once it is done."""
    def run(stroke):
        s = Script()
        s.wait(30)
        s.ftap(*FOUR_FRONT_PASS)
        s.wait(10)
        s.ftap(*FOUR_FRONT_STUDIO)
        s.wait(290)
        if stroke:
            s.fdrag(line((220, 220), (300, 260), 12))
            s.wait(40)
        samples = (lambda v: 0 < int(v) < 100) if stroke else near(256)
        return s, ["--script=set panes_under_panels off; view_grid four"], {"pane_heavy": near(1), "pane_samples": samples, "dabs": (lambda v: int(v) > 0) if stroke else near(0)}
    return Steps([run(False), run(True)])


@scenario
def view_pane_studio_stroke_in_it_gathers_again():
    """A stroke worked in a Studio pane draws Shaded live there; once it is done the pane draws its studio picture again and gathers anew (about 190 samples before it, fewer than 120 after)."""
    s = Script()
    s.wait(30)
    s.ftap(*FOUR_FRONT_PASS)
    s.wait(10)
    s.ftap(*FOUR_FRONT_STUDIO)
    s.wait(200)
    x, y = FOUR_FRONT_MODEL
    s.fdrag(line((x - 40, y), (x + 40, y + 20), 16))
    s.wait(60)
    return s, ["--script=set panes_under_panels off; view_grid four"], camera_still({"pane_works": near(1), "pane_work_dabs": lambda v: int(v) > 0,
                                                                            "pane_samples": lambda v: 0 < int(v) < 120, "pane_camera": is_text("Front")})


@scenario
def view_pane_ao_only_shows():
    """AO only in the Front pane's Shows is a heavy pass the pane draws at rest; the main view's pass stays Shaded."""
    s = Script()
    s.wait(30)
    s.ftap(*FOUR_FRONT_PASS)
    s.wait(10)
    s.ftap(*FOUR_FRONT_AO)
    s.wait(30)
    return s, ["--script=set panes_under_panels off; view_grid four"], camera_still({"pane_heavy": near(1), "pass": is_text("Shaded"), "pane_draws": lambda v: int(v) >= 4, "dabs": near(0)})


@scenario
def render_preview_builds_beside_the_main_view():
    """Render preview puts the grid side by side with its pane linked and on Render; the pane gathers render samples at rest, and a stroke in the main view starts them over once it is done."""
    def run(stroke):
        s = Script()
        s.wait(240)
        if stroke:
            s.fdrag(line((360, 420), (420, 470), 12))
            s.wait(20)
        samples = (lambda v: 0 <= int(v) < 3) if stroke else (lambda v: int(v) >= 4)
        return s, ["--script=set panes_under_panels off; render_preview"], {"grid": is_text("Side_By_Side"), "pane_camera": is_text("Follow"), "pane_heavy": near(1),
                                                                            "pane_render_samples": samples, "dabs": (lambda v: int(v) > 0) if stroke else near(0)}
    return Steps([run(False), run(True)])


# A view window (960x640 points at scale 1): its picture's middle, and its head's Shows select and Close.
WINDOW_MIDDLE = (480, 330)
WINDOW_SHOWS, WINDOW_CLOSE = (206, 34), (346, 34)


@scenario
def view_window_opens_and_draws_its_picture():
    """--view-windows=1 opens a view window beside the main one: it draws its picture at rest and presents only when something changed, not every frame."""
    s = Script()
    s.wait(40)
    return s, ["--view-windows=1"], camera_still({"view_windows": near(1), "view_window_opens": near(1), "view_window_draws": lambda v: int(v) >= 1,
                                                  "view_window_presents": lambda v: 1 <= int(v) <= 6, "dabs": near(0)})


@scenario
def view_window_mouse_drag_turns_the_linked_camera():
    """A mouse drag on a linked view window's picture turns the main camera; the main window's pointer presses nothing, so no stroke is laid."""
    s = Script()
    s.wait(10)
    s.window = 1
    s.mouse_drag(past_slop(WINDOW_MIDDLE, (WINDOW_MIDDLE[0] + 80, WINDOW_MIDDLE[1]), 8))
    s.window = 0
    s.wait(10)
    return s, ["--view-windows=1"], {"camera_yaw": lambda v: abs(float(v) - 0.6) > 0.05, "view_windows": near(1), "dabs": near(0), "undo_steps": near(0)}


@scenario
def view_window_finger_turns_its_free_camera():
    """In a view window set to Front, a finger drag turns the window's own camera (it becomes Free) and leaves the main camera still."""
    s = Script()
    s.wait(10)
    s.window = 1
    s.fdrag(past_slop(WINDOW_MIDDLE, (WINDOW_MIDDLE[0] + 80, WINDOW_MIDDLE[1]), 8))
    s.window = 0
    s.wait(10)
    return s, ["--script=view_grid side_by_side; view_window"], camera_still({"view_windows": near(1), "view_window_camera": is_text("Free"), "dabs": near(0)})


@scenario
def view_window_head_picks_what_it_shows():
    """The Shows select on a view window's head opens in that window and picks its pass: Normals."""
    s = Script()
    s.wait(10)
    s.window = 1
    s.ftap(*WINDOW_SHOWS)
    s.wait(10)
    s.ftap(WINDOW_SHOWS[0], WINDOW_SHOWS[1] + 51 + 2 * 44)
    s.window = 0
    s.wait(20)
    return s, ["--view-windows=1"], camera_still({"view_window_pass": is_text("Normals"), "view_window_draws": lambda v: int(v) >= 2, "dabs": near(0)})


@scenario
def view_pane_opens_in_a_window():
    """Open in a window on a view pane's head opens a view window showing that pane's camera and pass (Front, Shaded); the pane stays."""
    s = Script()
    s.wait(4)
    s.ftap(*GRID_PANE_WINDOW)
    s.wait(20)
    return s, ["--script=set panes_under_panels off; view_grid side_by_side"], camera_still({"view_windows": near(1), "view_window_camera": is_text("Front"),
                                                                                          "view_window_pass": is_text("Shaded"), "grid": is_text("Side_By_Side"), "dabs": near(0)})


@scenario
def view_window_close_button_closes_it():
    """The Close button on a view window's head closes that window only; the app goes on."""
    s = Script()
    s.wait(10)
    s.window = 1
    s.ftap(*WINDOW_CLOSE)
    s.window = 0
    s.wait(10)
    return s, ["--view-windows=1"], camera_still({"view_windows": near(0), "view_window_opens": near(1), "dabs": near(0)})


@scenario
def view_window_keys_stay_the_main_windows():
    """A key typed while a view window has the events goes to the main window's commands: P turns the main camera orthographic."""
    s = Script()
    s.wait(10)
    s.window = 1
    s.add(f"move:{WINDOW_MIDDLE[0]},{WINDOW_MIDDLE[1]}")
    s.wait(2)
    s.press("p")
    s.window = 0
    s.wait(6)
    return s, ["--view-windows=1"], {"ortho": near(1), "view_windows": near(1), "dabs": near(0)}


@scenario
def view_pane_maximises_and_restores():
    """Maximise on the view pane fills the grid's room with it; Restore brings the two panes back."""
    def run(restore):
        s = Script()
        s.wait(4)
        s.ftap(*GRID_PANE_MAX)
        s.wait(8)
        if restore:
            s.ftap(*GRID_PANE_RESTORE)
            s.wait(8)
        size = (lambda v: 450 < int(v.split("x")[0]) < 560) if restore else (lambda v: int(v.split("x")[0]) > 1000)
        return (s, ["--script=set panes_under_panels off; view_grid side_by_side"], camera_still({"grid_max": near(0 if restore else 1), "pane_px": size, "dabs": near(0)}))
    return Steps([run(False), run(True)])


@scenario
def thumbnail_follows_a_stroke_and_closes():
    """A stroke on the model draws the thumbnail again; its Close shuts the window."""
    s = Script()
    s.wait(4)
    s.mouse_drag([(800, 450), (830, 465), (860, 480)])
    s.wait(12)
    s.ftap(*THUMBNAIL_CLOSE)
    s.wait(4)
    return s, ["--script=thumbnail on"], {"thumbnail": near(0, 0), "thumbnail_draws": lambda v: int(v) >= 2, "dabs": lambda v: int(v) > 0}


# Scene > 3D print at 1600x900: the inches tab, and the Height value's middle.
PRINT_INCHES = (1472, 179)
PRINT_HEIGHT = (1380, 281)


@scenario
def print_height_by_finger_and_inches():
    """A finger drag right on Scene > 3D print's Height makes the print bigger, a tap on
    in shows inches, and neither sculpts nor turns the view."""
    s = Script()
    s.wait(4)
    x, y = PRINT_HEIGHT
    s.fdrag(line((x, y), (x + 120, y), 12))
    s.wait(4)
    s.ftap(*PRINT_INCHES)
    s.wait(4)
    return s, ["--script=show_section print"], camera_still({"print_mm": lambda v: float(v) > 26, "print_unit": near(2, 0), "dabs": near(0)})


# Object > Deformation at 1600x900: the middle of Amount's track (Offset, with the axes).
DEFORMATION_AMOUNT = (1378, 362)


@scenario
def deformation_amount_by_finger():
    """A finger drag on Object > Deformation's Amount offsets the sphere live and is one
    undo step when let go; it sculpts nothing and turns nothing."""
    s = Script()
    s.wait(4)
    x, y = DEFORMATION_AMOUNT
    s.fdrag(line((x, y), (x + 60, y), 8))
    s.wait(4)
    return s, ["--script=show_section deform"], camera_still({"reshapes": near(1, 0), "undo_steps": near(1, 0), "dabs": near(0)})


# Object > Shape > Modify topology at 1600x900 (repair.odin): Close holes and Delete hidden.
TOPOLOGY_CLOSE_HOLES = (1377, 393)
TOPOLOGY_DELETE_HIDDEN = (1377, 447)


@scenario
def delete_hidden_then_close_holes_by_finger():
    """With half the sphere hidden, a tap on Modify topology's Delete hidden deletes that
    half and a tap on Close holes caps the opening: two repairs, sculpting nothing and
    turning nothing."""
    s = Script()
    s.wait(4)
    s.ftap(*TOPOLOGY_DELETE_HIDDEN)
    s.wait(6)
    s.ftap(*TOPOLOGY_CLOSE_HOLES)
    s.wait(6)
    return s, ["--script=show_section mirror; hide y", "--check-mesh"], camera_still({"repairs": near(2, 0), "mesh_closed": lambda got: got == "true", "dabs": near(0)})


# The Home screen at 1600x900 (kit_home.odin): the Head starter, and the first scene tile.
HOME_NEW_HEAD = (180, 145)
HOME_TILE1 = (385, 190)


@scenario
def home_opens_from_the_top_bar():
    """A tap on the top bar's Home shows the Home screen over everything."""
    s = Script()
    s.ftap(*UI["home"])
    s.wait(4)
    return s, [], {"home": near(1, 0), "home_opened": near(1, 0), "dabs": near(0)}


@scenario
def home_closes_on_escape():
    """Escape closes the Home screen and goes back to the scene as it was."""
    s = Script()
    s.ftap(*UI["home"])
    s.wait(4)
    s.press("Escape")
    return s, [], camera_still({"home": near(0, 0), "home_opened": near(1, 0), "objects": near(1, 0)})


@scenario
def home_starts_a_new_scene_from_a_tile():
    """The Head starter on Home replaces the untouched sphere at once and closes Home."""
    s = Script()
    s.ftap(*UI["home"])
    s.wait(4)
    s.ftap(*HOME_NEW_HEAD)
    s.wait(10)
    return s, [], {"home": near(0, 0), "objects": near(1, 0), "selected_name": lambda v: v.startswith("Head")}


@scenario
def home_opens_a_recent_scene():
    """A scene saved earlier shows on Home's Recent with its picture; a tap opens it."""
    path = scene_file()
    s = Script()
    s.ftap(*UI["home"])
    s.wait(20)
    s.ftap(*HOME_TILE1)
    s.wait(6)

    def second():
        write_settings(f"recent_scenes {path}\n")
        return s, [f"--settings-file={settings_file()}"], {"home": near(0, 0), "home_pictures": near(1, 0), "home_read": near(1, 0),
                                                           "scene_name": is_text("head.sculpt"), "recent_scenes": near(1, 0)}
    return Steps([first_save(), second()])


@scenario
def home_drops_a_scene_that_is_gone():
    """A tap on a Recent scene whose file is gone takes it off Recent and opens nothing."""
    write_settings(f"recent_scenes {scene_file()}\n")
    s = Script()
    s.ftap(*UI["home"])
    s.wait(10)
    s.ftap(*HOME_TILE1)
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], {"home": near(1, 0), "recent_scenes": near(0, 0), "scene_name": is_text("none")}


@scenario
def home_recovers_a_crashed_sessions_autosave():
    """After a crash Home opens on Autosaves, where the crashed session's autosave is; a tap
    recovers it."""
    after = Script()
    after.wait(10)
    after.ftap(*UI["home"])
    after.wait(10)
    after.ftap(*HOME_TILE1)
    after.wait(10)
    return Steps([crash_after_stroke(), (after, autosave_args(), {"home": near(0, 0), "home_autosaves": near(1, 0), "recovered": near(1, 0)})])


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


# The Save popover's Save next row, under the top bar's Save.
SAVE_POP_NEXT = (198, 172)


@scenario
def save_next_numbers_the_files():
    """Save next from the long press on Save, twice over an opened file, a stroke before
    each: head_002 and then head_003 are written beside head, and the scene saves to the
    newest."""
    path = scene_file()
    folder = os.path.dirname(path)
    s = Script()
    s.wait(5)
    for at in ((800, 450), (700, 400)):
        s.mouse_drag([at, (at[0] + 30, at[1] + 15)])
        s.wait(3)
        long_press(s, *UI["save"])
        s.wait(10)
        click(s, SAVE_POP_NEXT)
        s.wait(6)
    ctrl_s(s)
    numbered = lambda _: all(os.path.exists(os.path.join(folder, f"head_00{n}.sculpt")) for n in (2, 3))
    # Ctrl+S saved over head_003, keeping the one it replaced: only that file has an earlier save.
    newest = lambda _: len(versions_of(os.path.join(folder, "head_003.sculpt"))) == 1 and not versions_of(path)
    return Steps([first_save(), (s, [f"--open={path}"], {"@numbered files": numbered, "@saves to the newest": newest})])


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
    s.add("move:168,400")
    s.add("wheel:-10")
    s.wait(1)
    s.add("wheel:-10")
    s.wait(20)
    click(s, (133, MENU_SHORT_LAST_Y - 44 * (len(MENU_APP_ROWS) - 1 - MENU_APP_ROWS.index("settings"))))
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
    """A check that files `a` and `b` (written by the runs) hold the same bytes."""
    return lambda _: file_difference(a, b)


@scenario
def macro_records_and_replays():
    """Record macro from the palette, Ctrl+R (a remesh, recorded once it has applied),
    Wireframe from the palette, the Clay brush by its key and the Stats panel (not
    recorded), then Stop and a typed name: the macro is kept as a script file. A later run
    runs it from the palette by that name, as the person's own work: the mesh is the one
    the same commands give from a start-up script, and only the remesh is an undo step."""
    direct, replayed = autosave_folder() + "-direct.ply", autosave_folder() + "-replayed.ply"
    record = Script()
    record.wait(3)
    palette_run(record, "record macro")
    record.press("r", ("ctrl",))
    record.wait(5)
    palette_run(record, "wireframe")
    record.press("3")
    record.press("F11")
    record.wait(3)
    palette_run(record, "record macro")
    record.type("Zebra")
    record.press("Return")
    record.wait(3)

    def kept(_):
        path = os.path.join(macros_folder(), "macro-01.cmd")
        text = open(path).read()
        want = "# Macro: Zebra\nremesh\nwireframe on\nbrush clay\n"
        return text == want or f"{path} holds {text!r}"

    replay = Script()
    replay.wait(3)
    palette_run(replay, "zebra")
    replay.wait(3)
    settings = f"--settings-file={settings_file()}"
    return Steps([
        (record, [settings, "--vertices=20000"], {"macros": near(1, 0), "macro_recording": near(0, 0), "macro_entries": near(0, 0), "@the file": kept}),
        (Script(), ["--vertices=20000", "--script=remesh; wireframe on; brush clay", f"--export={direct}"], {}),
        (replay, [settings, "--vertices=20000", f"--export={replayed}"],
         {"macros_run": near(1, 0), "macro_steps": near(3, 0), "undo_steps": near(1, 0), "@the commands' mesh": same_file(direct, replayed)}),
    ])


@scenario
def macros_panel_runs_renames_and_deletes():
    """Menu > Macros lists the two macros kept: a finger runs the first (as the person's
    work: wireframe on and a Smooth all, its one undo step), renames it by its pencil, and deletes the second with
    two taps on its bin. A single tap on the first's bin only arms it, so it stays."""
    os.makedirs(macros_folder())
    first, second = os.path.join(macros_folder(), "macro-01.cmd"), os.path.join(macros_folder(), "macro-02.cmd")
    with open(first, "w") as f:
        f.write("# Macro: Wire\nwireframe on\nsmooth_all\n")
    with open(second, "w") as f:
        f.write("# Macro: Flat\nflat_shading on\n")
    s = Script()
    s.wait(3)
    s.ftap(*UI["menu"])
    s.wait(10)
    s.ftap(*UI["menu_macros"])
    s.wait(16)
    s.ftap(*UI["macro1_run"])
    s.wait(5)
    s.ftap(*UI["macro1_rename"])
    s.wait(10)
    s.type("Wires")
    s.press("Return")
    s.wait(5)
    s.ftap(*UI["macro2_delete"])
    s.wait(10)
    s.ftap(*UI["macro2_delete"])
    s.wait(10)
    s.ftap(*UI["macro1_delete"])
    s.wait(10)

    def files(_):
        if os.path.exists(second):
            return "the second macro's file is still there"
        text = open(first).read() if os.path.exists(first) else None
        return text == "# Macro: Wires\nwireframe on\nsmooth_all\n" or f"the first macro's file holds {text!r}"

    return s, [f"--settings-file={settings_file()}"], camera_still({
        "dabs": near(0), "macros": near(1, 0), "macros_run": near(1, 0), "macro_steps": near(2, 0), "undo_steps": near(1, 0),
        "wireframe": near(1, 0), "window_macros": lambda v: v.startswith("1,0,"), "@the files": files})


def export_keeps_layers(ext, read, blender_keys):
    """Three sculpt layers (the first at 1.5, the second hidden, the third recording a
    mouse stroke) and paint, exported as `ext` and as .obj: the file names the layers as
    shape keys at their strengths, and its base plus the keys at those values is the
    shown surface the OBJ holds. Blender and a validator are asked too when
    scripts/export_check.py finds them (a skip is not a failure here), expecting
    `blender_keys`."""
    path, obj = autosave_folder() + "-layers" + ext, autosave_folder() + "-shown.obj"
    setup = ("--script=set paint_color 0.8 0.2 0.1; mask_rect 0 0 0.5 1; paint fill; mask clear; "
             "new_layer; set smooth_steps 2; smooth_all; new_layer; mask_rect 0.5 0 1 1; mask invert; smooth_all; mask clear; "
             "layer 2 0.4 hidden; layer 1 1.5; new_layer")
    keys = [("Layer 1", 1.5), ("Layer 2", 0), ("Layer 3", 1)]

    def rebuilt(_):
        got, points = read(path)
        if [(n, round(w, 6)) for n, w in got] != keys:
            return f"shape keys {got}, expected {keys}"
        shown = obj_points(obj)
        if len(shown) != len(points):
            return f"{len(points)} vertices against the OBJ's {len(shown)}"
        worst = max(abs(a - b) for p, q in zip(points, shown) for a, b in zip(p, q))
        return worst < 1e-5 or f"the keys rebuild the surface {worst:g} away"

    def outside_tools(_):
        run = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "export_check.py"), path, "--keys",
                              ",".join(f"{n}={w}" for n, w in blender_keys), "--colors"], capture_output=True, text=True)
        return run.returncode == 0 or run.stdout.strip()

    return Steps([
        (stroke_then_rest(Script(), 5), [setup, f"--export={obj}"], {"layers": near(3, 0)}),
        (stroke_then_rest(Script(), 5), [setup, f"--export={path}"],
         {"layers": near(3, 0), "dabs": lambda v: int(v) > 0, "@the keys rebuild the shown surface": rebuilt,
          "@the validator and Blender agree": outside_tools}),
    ])


def grey_png(path, size=16):
    """Writes a grey gradient PNG (8-bit greyscale) of `size` pixels a side."""
    rows = b"".join(b"\0" + bytes((x * 255 // (size - 1) + y) % 256 for x in range(size)) for y in range(size))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


@scenario
def library_alphas_survive_a_restart():
    """Images in the library's mine/alphas load at start after the built-ins, and a file
    there that is not an image is skipped and counted; a script picks one by its
    reference, and the next start, with nothing asked, has the brush on it again from
    the settings. The Alpha section shows it with Remove from library."""
    alphas = os.path.join(library_folder(), "mine", "alphas")
    os.makedirs(alphas, exist_ok=True)
    grey_png(os.path.join(alphas, "rock.png"))
    with open(os.path.join(alphas, "broken.png"), "w") as f:
        f.write("not an image")
    return Steps([
        (Script(), [f"--settings-file={settings_file()}", "--script=alpha mine/rock"],
         {"library_alphas": near(1, 0), "library_skipped": near(1, 0), "alpha": is_text("mine/rock")}),
        (Script(), [f"--settings-file={settings_file()}", "--script=show_section alpha"],
         {"library_alphas": near(1, 0), "alpha": is_text("mine/rock"), "@saved": saved(brush_alpha="mine/rock")}),
    ])


def make_pack(path, name, alphas, extra=()):
    """Writes a content pack: pack.txt naming it, by Bolt, and grey PNG alphas."""
    import zipfile
    os.makedirs(os.path.dirname(path), exist_ok=True)
    folder = path + ".parts"
    os.makedirs(folder, exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("pack.txt", f"name {name}\nauthor Bolt\nversion 1.0\nlicense CC0\ndescription Pebbles and cracks for stone\n")
        for i, stem in enumerate(alphas):
            png = os.path.join(folder, stem + ".png")
            grey_png(png, 16 + i)
            z.write(png, f"alphas/{stem}.png")
        for entry, text in extra:
            z.writestr(entry, text)
    shutil.rmtree(folder)


# The Library panel's Remove for the first pack, below Your own, at 1600x900.
LIBRARY_PACK1_REMOVE = (1494, 291)


@scenario
def content_pack_installs_and_removes():
    """A script installs a pack (its macros/ folder left out as code) and picks one of its
    alphas, which the Alpha section shows under the pack's name; the next start has the
    pack back, and the Library panel (Menu > Library) removes it with two taps on its
    bin, taking its folder away and the brush back to round."""
    pack = autosave_folder() + "-rocks.sculptpack"
    make_pack(pack, "Rock Set", ["Pebble", "crack"], [("macros/evil.cmd", "remesh\n")])
    s = Script()
    s.wait(3)
    click(s, UI["menu"])
    s.wait(4)
    click(s, UI["menu_library"])
    s.wait(10)
    click(s, LIBRARY_PACK1_REMOVE)
    s.wait(3)
    click(s, LIBRARY_PACK1_REMOVE)
    s.wait(5)
    folder = os.path.join(library_folder(), "rock-set")
    return Steps([
        (Script(), [f"--settings-file={settings_file()}", f"--script=install_pack {pack}; alpha rock-set/crack; show_section alpha"],
         {"packs": near(1, 0), "pack_alphas": near(2, 0), "packs_installed": near(1, 0), "alpha": is_text("rock-set/crack"),
          "@unpacked": lambda _: os.path.exists(os.path.join(folder, "alphas", "crack.png")) and not os.path.exists(os.path.join(folder, "macros"))}),
        (s, [f"--settings-file={settings_file()}"],
         {"packs": near(0, 0), "pack_alphas": near(0, 0), "alpha": is_text("-"), "@removed": lambda _: not os.path.exists(folder)}),
    ])


@scenario
def pack_presets_reach_the_browser():
    """A pack's brushes.txt brings its presets: a script installs it and puts the brush on
    Stone clay; the next start has the brush back on it, and the brush browser's search
    finds the pack's preset, where a tap picks it again after a plain brush was picked."""
    pack = autosave_folder() + "-brushes.sculptpack"
    line = "preset Stone%20clay Clay 0.35 0 0 0 0 0 Stone Stroke 0 Dots 0 0 0 0 Drag\n"
    make_pack(pack, "Brush Set", ["Stone"], [("brushes.txt", line + line.replace("Stone%20clay", "Ring%20draw").replace("Clay", "Draw").replace(" Stone ", " Rings "))])
    s = Script()
    s.wait(3)
    s.press("1")
    s.wait(3)
    s.ftap(*UI["browser"])
    s.wait(12)
    s.ftap(*BROWSER_SEARCH)
    s.wait(4)
    s.type("stone")
    s.wait(4)
    s.ftap(*browser_tile(0, 0))
    s.wait(6)
    return Steps([
        (Script(), [f"--settings-file={settings_file()}", f"--script=install_pack {pack}; preset brush-set/stone clay"],
         {"packs": near(1, 0), "pack_presets": near(2, 0), "preset_name": is_text("Stone_clay"), "brush_strength": near(0.35)}),
        (s, [f"--settings-file={settings_file()}"],
         camera_still({"dabs": near(0), "preset_name": is_text("Stone_clay"), "brush_kind": is_text("clay"), "alpha": is_text("brush-set/Stone"), "browser": near(0)})),
    ])


# An octahedron, a small closed mesh for a pack.
OCTA_OBJ = ("v 1 0 0\nv -1 0 0\nv 0 1 0\nv 0 -1 0\nv 0 0 1\nv 0 0 -1\n"
            "f 1 3 5\nf 3 2 5\nf 2 4 5\nf 4 1 5\nf 3 1 6\nf 2 3 6\nf 4 2 6\nf 1 4 6\n")
# Menu > New scene's first pack mesh, under the six shapes and the pack's name, at 1600x900.
MENU_PACK_MESH = (96, 645)


@scenario
def pack_meshes_start_and_add():
    """A pack's meshes: a script installs it and adds its Boulder beside the sphere (one
    set-up step); the next start's Menu > New scene lists the pack's meshes under its name,
    and a tap on Boulder starts a scene of it alone, since a fresh scene has no work to
    lose."""
    pack = autosave_folder() + "-meshes.sculptpack"
    make_pack(pack, "Rock Set", [], [("meshes/Boulder.obj", OCTA_OBJ), ("meshes/Pillar.obj", OCTA_OBJ)])
    s = Script()
    s.wait(3)
    click(s, UI["menu"])
    s.wait(6)
    click(s, MENU_PACK_MESH)
    s.wait(6)
    return Steps([
        (Script(), [f"--settings-file={settings_file()}", f"--script=install_pack {pack}; pack_mesh rock-set/boulder"],
         {"pack_meshes": near(2, 0), "objects": near(2, 0), "selected_name": is_text("Boulder")}),
        (s, [f"--settings-file={settings_file()}"],
         {"objects": near(1, 0), "selected_name": is_text("Boulder"), "undo_steps": near(0, 0), "menu": near(0)}),
    ])


def matcap_png(path, size=64, colour=(70, 150, 60)):
    """Writes an RGB PNG of a lit sphere on black, as matcap libraries share them: lit from
    the upper left, with a white highlight."""
    rows = []
    for y in range(size):
        row = bytearray(b"\0")
        for x in range(size):
            nx, ny = (2 * x + 1) / size - 1, 1 - (2 * y + 1) / size
            d = nx * nx + ny * ny
            if d > 1:
                row += b"\0\0\0"
                continue
            nz = (1 - d) ** 0.5
            lit = max(0.0, (-0.5 * nx + 0.6 * ny + 0.62 * nz))
            spec = max(0.0, lit) ** 40
            row += bytes(min(255, int(c * (0.15 + 0.85 * lit) + 255 * spec)) for c in colour)
        rows.append(bytes(row))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


@scenario
def pack_materials_shade_and_stay():
    """A pack's matcaps and materials.txt: a script installs it and gives the sphere its
    Moss material, whose matcap's texture is made then (and only that one); the next
    start's sphere takes Moss again, from the settings."""
    pack = autosave_folder() + "-materials.sculptpack"
    os.makedirs(os.path.dirname(pack), exist_ok=True)
    moss, glint = pack + ".moss.png", pack + ".glint.png"
    matcap_png(moss)
    matcap_png(glint, colour=(200, 200, 210))
    make_pack(pack, "Rock Set", [], [("matcaps/moss.png", open(moss, "rb").read()), ("matcaps/glint.png", open(glint, "rb").read()),
                                     ("materials.txt", "material Moss 1 1 1 0 0.5 moss\n")])
    s = Script()
    s.wait(5)
    return Steps([
        (Script(), [f"--settings-file={settings_file()}", f"--script=install_pack {pack}; set material rock-set/moss"],
         {"pack_materials": near(2, 0), "pack_matcaps": near(2, 0), "pack_matcap_textures": near(1, 0), "selected_material": is_text("Moss")}),
        (s, [f"--settings-file={settings_file()}"],
         {"pack_materials": near(2, 0), "selected_material": is_text("Moss"), "pack_matcap_textures": near(1, 0)}),
    ])


def ply_mesh(path):
    """The vertices and triangles of a binary little-endian PLY as the app writes it
    (x y z floats, perhaps rgb bytes; a uchar count and int indices a face)."""
    data = open(path, "rb").read()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    head = data[:end].decode()
    vertices = int(head.split("element vertex ")[1].split()[0])
    faces = int(head.split("element face ")[1].split()[0])
    stride = 15 if "property uchar red" in head else 12
    points = [struct.unpack_from("<3f", data, end + stride * v) for v in range(vertices)]
    at = end + stride * vertices
    tris = [struct.unpack_from("<3i", data, at + 13 * f + 1) for f in range(faces)]
    return points, tris


def ply_write(path, points, tris):
    """A binary PLY of `points` and `tris`, as Blender's side of the link writes one."""
    head = (f"ply\nformat binary_little_endian 1.0\nelement vertex {len(points)}\nproperty float x\nproperty float y\n"
            f"property float z\nelement face {len(tris)}\nproperty list uchar int vertex_indices\nend_header\n")
    with open(path, "wb") as f:
        f.write(head.encode())
        for p in points:
            f.write(struct.pack("<3f", *p))
        for t in tris:
            f.write(struct.pack("<B3i", 3, *t))


def fake_blender(folder):
    """A check that plays Blender between two runs: from the app's send it returns the
    object sent with its first vertex raised by 0.25 (as moved vertices), sphere 2 as a
    tetrahedron (new topology for a known object) and a tetrahedron of its own (a new
    object), each line echoing the sent transform words, as the add-on does."""
    def act(_):
        lines = open(os.path.join(folder, "link.txt")).read().split("\n")
        token = next(l.split()[1] for l in lines if l.startswith("scene "))
        sent = next(l.split() for l in lines if l.startswith("object "))
        points, tris = ply_mesh(os.path.join(folder, sent[4]))
        points[0] = (points[0][0], points[0][1] + 0.25, points[0][2])
        ply_write(os.path.join(folder, f"blender-{sent[1]}.ply"), points, tris)
        tetra = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)]
        faces = [(0, 2, 1), (0, 1, 3), (0, 3, 2), (1, 2, 3)]
        ply_write(os.path.join(folder, "blender-2.ply"), tetra, faces)
        ply_write(os.path.join(folder, "blender-new-1.ply"), tetra, faces)
        out = ["blender_link 1", f"scene {token}", "sent 1",
               " ".join(["object", sent[1], sent[2], sent[3], f"blender-{sent[1]}.ply", sent[5], sent[6]] + sent[7:]),
               "object 2 0 Tetra blender-2.ply 4 4 2.5 0 0 0 0 0 1",
               "object 0 0 Made%20in%20Blender blender-new-1.ply 4 4 5 0 0 0 0 0 1"]
        with open(os.path.join(folder, "blender.txt"), "w") as f:
            f.write("\n".join(out) + "\n")
        return True
    return act


def same_mesh_file(a, b):
    """A check that PLY files `a` and `b` hold the same vertices and triangles."""
    def check(_):
        x, y = ply_mesh(a), ply_mesh(b)
        if x == y:
            return True
        moved = sum(1 for p, q in zip(x[0], y[0]) if p != q)
        return f"{len(x[0])} and {len(y[0])} vertices, {moved} not the same; {len(x[1])} and {len(y[1])} triangles ({a} and {b})"
    return check


@scenario
def blender_link_round_trip():
    """Send to Blender writes the selected sphere and a manifest, and the saved scene keeps
    the link's token; after a stand-in Blender's send, the scene opened again gets it from
    the palette's Get from Blender: the sphere's raised vertex (the stand-in's mesh, vertex
    for vertex), the second sphere rebuilt as the tetrahedron, and a new object, as one
    undo step."""
    scene, got = autosave_folder() + "-link.sculpt", autosave_folder() + "-got.sculpt"
    back, exported = os.path.join(link_folder(), "blender-1.ply"), autosave_folder() + "-got.ply"
    os.makedirs(os.path.dirname(scene), exist_ok=True)
    def get(undo):
        s = Script()
        s.wait(3)
        s.press("k", ("ctrl",))
        s.type("get from blender")
        s.press("Return")
        s.wait(6)
        if undo:
            s.press("z", ("ctrl",))
            s.wait(4)
        return s
    return Steps([
        (Script(), [f"--settings-file={settings_file()}", "--spheres=2", "--subdiv=3", "--script=select 1; send_to_blender", f"--save={scene}"],
         {"link_sent": near(1, 0), "link_token": near(1, 0), "@stand-in Blender": fake_blender(link_folder())}),
        # One Ctrl+Z takes the whole get back: the move, the rebuild, the new object and
        # the second sphere's new place.
        (get(True), [f"--settings-file={settings_file()}", f"--open={scene}"],
         {"link_moved": near(1, 0), "link_swapped": near(1, 0), "link_added": near(1, 0), "objects": near(2, 0), "undo_steps": near(0, 0), "redo_steps": near(4, 0),
          # The folder notes the send as taken, so the next run would not take it again.
          "@taken once": lambda _: os.path.exists(os.path.join(link_folder(), "taken.txt")) and (os.remove(os.path.join(link_folder(), "taken.txt")) or True)}),
        (get(False), [f"--settings-file={settings_file()}", f"--open={scene}", f"--save={got}"],
         {"objects": near(3, 0), "undo_steps": near(4, 0)}),
        (Script(), [f"--settings-file={settings_file()}", f"--open={got}", "--script=select 1", f"--export={exported}"],
         {"objects": near(3, 0), "link_token": near(1, 0), "@the raised vertex": same_mesh_file(back, exported)}),
    ])


@scenario
def plugin_runs_from_search():
    """A script plugin's command, found in Search by its name and run with Return, runs its
    sculpt.run statements as one undo step each (a duplicate, then a move); a plugin that
    fails to load leaves the others working. The settings remember the command's slot."""
    def plugins(_):
        os.makedirs(plugins_folder(), exist_ok=True)
        with open(os.path.join(plugins_folder(), "tools.luau"), "w") as f:
            f.write("\n".join([
                'sculpt.command{name = "Twin and shift", help = "Duplicates the selected object and moves the copy.", run = function()',
                '    sculpt.run("duplicate_object")',
                '    sculpt.run("move 1.5 0 0")',
                '    sculpt.note(string.format("%d objects", #sculpt.objects()))',
                'end}',
                'sculpt.command{name = "Wires", run = function() sculpt.run("wireframe on") end}',
            ]) + "\n")
        with open(os.path.join(plugins_folder(), "broken.luau"), "w") as f:
            f.write("sculpt.command{name = 'Never', run = 1}\n")
        return True
    s = Script()
    s.wait(3)
    s.press("k", ("ctrl",))
    s.type("twin and shift")
    s.press("Return")
    s.wait(6)
    def slot_kept(_):
        text = open(settings_file()).read()
        return "plugin_slot 0 tools.luau/Twin%20and%20shift" in text and "plugin_slot 1 tools.luau/Wires" in text
    return Steps([
        (Script(), [f"--settings-file={settings_file()}"], {"plugins": near(0, 0), "@a plugins folder": plugins}),
        (s, [f"--settings-file={settings_file()}", "--spheres=1"],
         {"plugins": near(1, 0), "plugin_commands": near(2, 0), "plugin_errors": near(1, 0), "plugin_runs": near(1, 0), "plugin_steps": near(2, 0),
          "objects": near(2, 0), "undo_steps": near(2, 0), "@the slots kept": slot_kept}),
    ])


def echo_blender(folder, raise_first=False):
    """A check that plays Blender between two runs: it sends back the app's one object as
    it got it, or with its first vertex raised by 0.25, its placement word for word."""
    def act(_):
        lines = open(os.path.join(folder, "link.txt")).read().split("\n")
        token = next(l.split()[1] for l in lines if l.startswith("scene "))
        sent = next(l.split() for l in lines if l.startswith("object "))
        points, tris = ply_mesh(os.path.join(folder, sent[4]))
        if raise_first:
            points[0] = (points[0][0], points[0][1] + 0.25, points[0][2])
        ply_write(os.path.join(folder, f"blender-{sent[1]}.ply"), points, tris)
        with open(os.path.join(folder, "blender.txt"), "w") as f:
            f.write("\n".join(["blender_link 1", f"scene {token}", "sent 1",
                               " ".join(["object", sent[1], sent[2], sent[3], f"blender-{sent[1]}.ply"] + sent[5:])]) + "\n")
        return True
    return act


@scenario
def blender_link_keeps_voxels_and_dynamic():
    """A voxel object Blender sends back untouched stays a voxel object, with nothing to
    undo; a dynamic topology object sent back changed is rebuilt from Blender's mesh with
    dynamic topology still on, as one undo step."""
    voxel, dynamic = autosave_folder() + "-voxel.sculpt", autosave_folder() + "-dynamic.sculpt"
    os.makedirs(os.path.dirname(voxel), exist_ok=True)

    def get():
        s = Script()
        s.wait(3)
        s.press("k", ("ctrl",))
        s.type("get from blender")
        s.press("Return")
        s.wait(6)
        return s
    return Steps([
        (Script(), [f"--settings-file={settings_file()}", "--voxels=64", "--script=send_to_blender", f"--save={voxel}"],
         {"link_sent": near(1, 0), "voxel_objects": near(1, 0), "@stand-in Blender": echo_blender(link_folder())}),
        (get(), [f"--settings-file={settings_file()}", f"--open={voxel}"],
         {"link_swapped": near(0, 0), "voxel_objects": near(1, 0), "undo_steps": near(0, 0)}),
        (Script(), [f"--settings-file={settings_file()}", "--subdiv=3", "--script=dyntopo_toggle on; send_to_blender", f"--save={dynamic}"],
         {"link_sent": near(1, 0), "dynamic": near(1, 0), "@stand-in Blender": echo_blender(link_folder(), raise_first=True)}),
        (get(), [f"--settings-file={settings_file()}", f"--open={dynamic}"],
         {"link_swapped": near(1, 0), "dynamic": near(1, 0), "undo_steps": near(1, 0)}),
    ])


@scenario
def settings_system_shows_the_link():
    """Settings > System, scrolled to the end, shows the Blender link's folder with Copy
    path, and Send to Blender there writes the selected sphere to it."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("system")
    s.press("Return")
    s.wait(3)
    s.add("move:1400,500")
    s.add("wheel:-30")
    s.wait(10)
    s.press("k", ("ctrl",))
    s.type("send to blender")
    s.press("Return")
    s.wait(4)
    return s, [f"--settings-file={settings_file()}"], {"settings_open": near(1), "settings_tab": is_text("Performance"), "link_sent": near(1, 0),
                                                       "@the manifest": lambda _: os.path.exists(os.path.join(link_folder(), "link.txt")) or "no link.txt"}


@scenario
def gltf_export_keeps_layers():
    """Layers as glTF morph targets (export_keeps_layers): Blender shows 1.5 as it is."""
    return export_keeps_layers(".glb", glb_read, [("Layer 1", 1.5), ("Layer 2", 0), ("Layer 3", 1)])


@scenario
def usd_export_keeps_layers():
    """Layers as USD blend shapes (export_keeps_layers). Blender's USD importer keys the
    1.5 in an action but keeps the shape key's range at 0 to 1, so it shows 1."""
    return export_keeps_layers(".usda", usda_read, [("Layer 1", 1), ("Layer 2", 0), ("Layer 3", 1)])


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
        (Script(), ["--script=remesh_to 500000", f"--export={direct}"], {}),
        (s, [f"--export={adjusted}"], {"adjust_op": is_text("remesh"), "adjusts": near(1, 0), "adjust_pop": near(1, 0),
                                       "undo_steps": near(1, 0), "redo_steps": near(0, 0), "@a straight remesh": same_file(direct, adjusted)}),
    ])


# Adjust last stroke's popover: with no action bar after a stroke it sits over the dock,
# its Amount slider's left end (0%) here at 1600x900.
ADJUST_STROKE_NONE = (662, 788)
# The middles of the History panel bar's three steps, after three strokes.
TIMELINE_STEPS_OF_3 = [(647, 545), (800, 545), (952, 545)]
# The History panel's Marker and Delete older history buttons, at its foot.
HISTORY_MARKER = (683, 704)
HISTORY_DELETE_OLDER = (916, 704)
# mesh_sum after the History scenario's two Draw strokes, before the History brush.
HISTORY_DRAWN_SUM = 7.81


@scenario
def adjust_last_stroke_to_nothing():
    """A mouse stroke, then the palette's Adjust last operation and the Amount slider at
    0%: the sphere is as it started, the stroke still one undo step, and no action bar."""
    s = Script()
    s.wait(3)
    s.mouse_drag(line((700, 380), (760, 420), 12))
    s.wait(3)
    palette_run(s, "adjust last")
    click(s, ADJUST_STROKE_NONE)
    return s, [], camera_still({"adjust_op": is_text("last_stroke"), "adjusts": near(1, 0), "adjust_pop": near(1, 0),
                                "undo_steps": near(1, 0), "mesh_sum": near(0, 1e-3)})


@scenario
def history_brush_by_pen():
    """Two mouse Draw strokes, then the palette's History brush and two pen strokes over
    them: the sphere goes back toward how it started (mesh_sum toward 0), each History
    stroke is an undo step, and the target is the oldest step, now four back."""
    s = Script()
    s.wait(3)
    for _ in range(2):
        s.mouse_drag(line((700, 380), (800, 420), 12))
        s.wait(2)
    palette_run(s, "history brush")
    for _ in range(2):
        pen_stroke(s, line((700, 380), (800, 420), 12), pressure=0.8)
    return s, [], camera_still({"undo_steps": near(4, 0), "recall_back": near(4, 0), "recall_pinned": near(0, 0),
                                "mesh_sum": lambda v: abs(float(v)) < HISTORY_DRAWN_SUM / 2})


@scenario
def layers_survive_a_rebuild():
    """A stroke into a recording layer, then Remesh selected (Ctrl+R), Mirror and weld,
    Decimate, a Slice (Ctrl+Shift drag with Slice the gesture tool) or Make boolean: the
    rebuilt object keeps the layer, both parts of a slice do, and the note says so. On a
    level above the base, Shift+D and Delete higher carry the layer down to the base;
    Subdivide (Ctrl+D) moves it up to the new level as one undo step (the stroke before
    it can no longer be undone), and its undo puts it back on the base.
    Undoing the decimation (from 163k vertices, so 41k is fewer) brings back the old
    object, its layer and its vertices with it; the rebuild forgot the stroke, so nothing
    is left to undo after."""
    def run(rebuild, undo=False):
        s = Script()
        s.wait(3)
        s.mouse_drag(line((700, 380), (800, 420), 12))
        s.wait(2)
        rebuild(s)
        s.wait(5)
        if undo:
            s.press("z", ("ctrl",))
            s.wait(5)
        return s
    def remesh(s):
        s.press("r", ("ctrl",))
    def subdivide(s):
        s.press("d", ("ctrl",))
    def delete_higher(s):
        s.press("d", ("shift",))
        s.wait(3)
        palette_run(s, "delete higher")
    def slice_(s):
        s.mouse_drag(line((790, 60), (810, 840), 10), keys=("ctrl", "shift"))
    settings = settings_file()
    os.makedirs(os.path.dirname(settings), exist_ok=True)
    with open(settings, "w") as f:
        f.write("version 1\ngesture slice\n")
    kept = {"layers": near(1, 0), "layers_noted": near(1, 0)}
    steps = [(run(remesh), ["--script=new_layer"], dict(kept, layers_carry_ms=lambda v: float(v) > 0)),
             (run(lambda s: palette_run(s, "mirror and weld")), ["--script=new_layer"], kept),
             (run(lambda s: palette_run(s, "decimate to 41k"), undo=True), ["--subdiv=7", "--script=new_layer"],
              dict(kept, undo_steps=near(0, 0), vertices=near(163842, 0))),
             (run(slice_), ["--script=new_layer", f"--settings-file={settings}"], {"objects": near(2, 0), "layers": near(2, 0), "layers_noted": near(1, 0)}),
             (run(delete_higher), ["--subdivide=1", "--script=new_layer"], {"layers": near(1, 0), "layers_noted": near(1, 0), "vertices": near(40962, 0)}),
             (run(subdivide), ["--script=new_layer"], {"layers": near(1, 0), "layers_noted": near(1, 0), "vertices": near(163842, 0), "undo_steps": near(1, 0), "selected_levels": near(2, 0)}),
             (run(subdivide, undo=True), ["--script=new_layer"], {"layers": near(1, 0), "vertices": near(40962, 0), "undo_steps": near(0, 0), "selected_levels": near(1, 0)}),
             (run(lambda s: palette_run(s, "make boolean")), ["--spheres=2", "--script=new_layer; select 2; boolean union; move 0.9 0 0; select 1"],
              {"objects": near(1, 0), "layers": near(1, 0), "layers_noted": near(1, 0)}),
             # A voxel base: the copy is cut out of the sphere on the field, and one clay object is left.
             (run(lambda s: palette_run(s, "make boolean")), ["--voxels=96", "--script=duplicate_object; boolean subtract; move 0.9 0 0; select 1"],
              {"objects": near(1, 0), "voxel_objects": near(1, 0)}),
             # Clay takes a mask shape and the whole-mask commands: the top half masked, then inverted, then cleared, three undo steps.
             (run(lambda s: (palette_run(s, "invert mask"), palette_run(s, "clear mask"))), ["--voxels=96", "--script=mask_rect 0 0 1 0.5"],
              {"voxel_objects": near(1, 0), "undo_steps": near(3, 0), "mask_scans": lambda v: int(v) > 0})]
    # Two spheres start with the view framing both, so the last run is not checked for a still camera.
    return Steps([(sc, args, camera_still(want) if k < 7 else want) for k, (sc, args, want) in enumerate(steps)])


@scenario
def deformers_from_the_palette():
    """The palette's Twist opens the Object tab's Deformers section on Twist, and a drag of
    its Amount slider by the mouse, a finger or the pen twists the sphere as one undo step,
    the slider springing back; the camera stays still."""
    def run(drag):
        s = Script()
        s.wait(3)
        palette_run(s, "twist")
        s.wait(5)
        drag(s)
        s.wait(5)
        return s
    def mouse(s):
        s.mouse_drag(line(DEFORM_AMOUNT, (DEFORM_AMOUNT[0] + 80, DEFORM_AMOUNT[1]), 10))
    def finger(s):
        s.fdrag(past_slop(DEFORM_AMOUNT, (DEFORM_AMOUNT[0] + 80, DEFORM_AMOUNT[1]), 10))
    def pen(s):
        x, y = DEFORM_AMOUNT
        s.add("pnear")
        s.add(f"pdown:{x},{y}")
        for k in range(1, 11):
            s.wait(1)
            s.add(f"pmove:{x + 8 * k},{y}")
        s.wait(1)
        s.add("pup")
        s.add("pfar")
        s.wait(3)
    want = {"deforms": near(1, 0), "deform_kind": lambda v: v == "Twist", "undo_steps": near(1, 0), "dabs": near(0)}
    return Steps([(run(drag), [], camera_still(want)) for drag in (mouse, finger, pen)])


DEFORM_AMOUNT = (1378, 427)  # the Deformers section's Amount slider, opened by the palette


@scenario
def lattice_point_dragged():
    """The palette's Lattice and W put a cage round the sphere in place of the gizmo, and a
    drag of the middle point of its right side by the mouse, a finger or the pen pulls the
    surface as one undo step and leaves the point under the pointer; the camera stays
    still, though the point is off the model."""
    def run(drag):
        s = Script()
        s.wait(3)
        palette_run(s, "lattice")
        s.wait(3)
        # The tray the palette opened on Deformers hides the cage's side: Tab puts it away.
        s.press("Tab")
        s.wait(3)
        s.press("w")
        s.wait(5)
        drag(s)
        s.wait(5)
        return s
    to = (LATTICE_SIDE[0], LATTICE_SIDE[1] - 120)
    def mouse(s):
        s.mouse_drag(line(LATTICE_SIDE, to, 10))
    def finger(s):
        s.fdrag(line(LATTICE_SIDE, to, 10))
    def pen(s):
        x, y = LATTICE_SIDE
        s.add("pnear")
        s.add(f"pdown:{x},{y}")
        for k in range(1, 11):
            s.wait(1)
            s.add(f"pmove:{x},{y - 12 * k}")
        s.wait(1)
        s.add("pup")
        s.add("pfar")
        s.wait(3)
    # The point stays under the pointer: the slop a finger and the pen cross first counts.
    def under(got):
        x, y = (float(v) for v in got.split(","))
        return abs(x - to[0]) <= 3 and abs(y - to[1]) <= 3
    want = {"lattice_on": near(1, 0), "lattice_drags": near(1, 0), "lattice_last": under,
            "undo_steps": near(1, 0), "pose_drags": near(1, 0), "dabs": near(0)}
    return Steps([(run(drag), [], camera_still(want)) for drag in (mouse, finger, pen)])


LATTICE_SIDE = (1185, 540)  # the cage's +x side middle point round the starting sphere


@scenario
def history_point_from_the_timeline():
    """Three strokes and the History panel: a right-click on the second step of its bar
    makes the History brush paint back to before it (two steps back, chosen), and then a
    long press on the third, by a finger and again by the pen, makes it one step back;
    none of it moves through the History."""
    def run(by_pen):
        s = Script()
        s.wait(3)
        for _ in range(3):
            s.mouse_drag(line((700, 380), (800, 420), 12))
            s.wait(2)
        click(s, UI["history"])
        s.wait(20)
        s.add("move:{:g},{:g}".format(*TIMELINE_STEPS_OF_3[1]))
        s.wait(3)
        s.add("right")
        s.wait(4)
        if by_pen:
            s.add("pnear")
            s.add("pdown:{:g},{:g}".format(*TIMELINE_STEPS_OF_3[2]))
            s.wait(LONG_PRESS_FRAMES)
            s.add("pup")
            s.wait(2)
            s.add("pfar")
            s.wait(4)
        else:
            long_press(s, *TIMELINE_STEPS_OF_3[2])
        return s, [], camera_still({"undo_steps": near(3, 0), "redo_steps": near(0, 0), "recall_back": near(1, 0),
                                    "recall_pinned": near(1, 0)})
    return Steps([run(False), run(True)])


@scenario
def history_point_then_drift():
    """A finger's long press on the bar's first step that then drifts along it before
    lifting chooses the step and scrubs nothing: all three steps stay done."""
    s = Script()
    s.wait(3)
    for _ in range(3):
        s.mouse_drag(line((700, 380), (800, 420), 12))
        s.wait(2)
    click(s, UI["history"])
    s.wait(20)
    x, y = TIMELINE_STEPS_OF_3[0]
    s.add(f"fdown:0:{x:g},{y:g}")
    s.wait(LONG_PRESS_FRAMES)
    for k in range(1, 6):
        s.add(f"fmove:0:{x + 40 * k:g},{y:g}")
        s.wait(1)
    s.add("fup:0")
    s.wait(10)
    return s, [], camera_still({"undo_steps": near(3, 0), "redo_steps": near(0, 0), "recall_back": near(3, 0),
                                "recall_pinned": near(1, 0)})


@scenario
def history_point_by_right_click():
    """The same right-click alone: two steps back, chosen."""
    s = Script()
    s.wait(3)
    for _ in range(3):
        s.mouse_drag(line((700, 380), (800, 420), 12))
        s.wait(2)
    click(s, UI["history"])
    s.wait(20)
    s.add("move:{:g},{:g}".format(*TIMELINE_STEPS_OF_3[1]))
    s.wait(3)
    s.add("right")
    s.wait(4)
    return s, [], camera_still({"undo_steps": near(3, 0), "recall_back": near(2, 0), "recall_pinned": near(1, 0)})


@scenario
def history_marker_and_delete_older():
    """Three strokes and the History panel: with Marker on, a finger's tap on the second
    step makes the History brush paint back to before it (two steps back) and goes nowhere;
    Delete older history then takes two taps and forgets all three steps, and an undone
    step stays to redo."""
    def run(delete):
        s = Script()
        s.wait(3)
        for _ in range(3):
            s.mouse_drag(line((700, 380), (800, 420), 12))
            s.wait(2)
        click(s, UI["history"])
        s.wait(20)
        if not delete:
            s.ftap(*HISTORY_MARKER)
            s.wait(4)
            s.ftap(*TIMELINE_STEPS_OF_3[1])
            s.wait(6)
            return s, [], camera_still({"undo_steps": near(3, 0), "redo_steps": near(0, 0), "recall_back": near(2, 0),
                                        "recall_pinned": near(1, 0)})
        s.press("z", ("ctrl",))
        s.wait(4)
        s.ftap(*HISTORY_DELETE_OLDER)
        s.wait(4)
        s.ftap(*HISTORY_DELETE_OLDER)
        s.wait(6)
        return s, [], camera_still({"undo_steps": near(0, 0), "redo_steps": near(1, 0)})
    return Steps([run(False), run(True)])


@scenario
def timeline_tap_and_drag_by_finger():
    """A finger's tap on the History panel's bar goes to that point, and a drag along it
    scrubs: after a tap at the first step's end one step is done, after a drag back to the
    start none."""
    def run(drag):
        s = Script()
        s.wait(3)
        for _ in range(3):
            s.mouse_drag(line((700, 380), (800, 420), 12))
            s.wait(2)
        click(s, UI["history"])
        s.wait(20)
        if drag:
            s.fdrag(line(TIMELINE_STEPS_OF_3[2], (480, 545), 12))
        else:
            s.ftap(718, 545)
        s.wait(30)
        done = 0 if drag else 1
        return s, [], camera_still({"undo_steps": near(done, 0), "redo_steps": near(3 - done, 0)})
    return Steps([run(False), run(True)])


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
    slider's left end: let go, it smooths 1 step from the start, as a start-up
    `set smooth_steps 1; smooth_all` does."""
    direct, adjusted = autosave_folder() + "-direct.ply", autosave_folder() + "-adjusted.ply"
    s = Script()
    s.wait(3)
    palette_run(s, "smooth all")
    palette_run(s, "adjust last")
    click(s, ADJUST_STEPS_LEFT)
    s.wait(5)
    return Steps([
        (Script(), ["--script=set smooth_steps 1; smooth_all", f"--export={direct}"], {}),
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
    """A stroke after Ctrl+R is a newer step: the Adjust group goes from the bar, and what
    the palette's Adjust last operation adjusts is the stroke, not the remesh."""
    s = Script()
    s.wait(3)
    s.press("r", ("ctrl",))
    s.wait(5)
    s.mouse_drag(line((700, 380), (760, 420), 8))
    s.wait(5)
    return s, [], {"adjust_op": is_text("last_stroke"), "action_bar": is_text("none"), "undo_steps": near(2, 0)}


@scenario
def adjust_remesh_keeps_to_the_state_before():
    """Adjusting a remesh made with dynamic topology on, on a lower subdivision level, or
    inside an HD window gives, bit for bit, what remeshing straight to that size from the
    same start gives: undoing the remesh brings back all of that state first."""
    steps = []
    for name, start in [("dyntopo", ["--script=dyntopo_toggle on"]), ("level", ["--subdivide=1", "--level=1"]), ("hd", ["--hd=1", "--hd-open"])]:
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
    a start-up `set retopo_quads 100; retopologize` makes. Extract a masked patch, then adjust Thickness twice: still two
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
        (Script(), ["--script=set retopo_quads 100; retopologize", f"--export={direct}"], {}),
        (retopo, [f"--export={adjusted}"], {"adjust_op": is_text("retopology"), "adjusts": near(1, 0), "objects": near(2, 0),
                                           "@100 quads from the start": same_file(direct, adjusted)}),
        (extract(["left"]), [f"--export={once}"], {"adjust_op": is_text("extract"), "objects": near(2, 0)}),
        (extract(["middle", "left"]), [f"--export={twice}"], {"adjusts": near(2, 0), "objects": near(2, 0), "undo_steps": near(2, 0),
                                                             "@as adjusting once": same_file(once, twice)}),
    ])


# Camera history (camera_history.odin): Camera menu rows at 1600x900.
VIEW_BACK, VIEW_FORWARD = (1399, 360), (1399, 404)
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
def camera_back_and_forward_from_the_camera_menu():
    """Camera > Previous view goes back one orbit and Next view comes forward again: the
    camera is where the two orbits alone leave it."""
    after = {}
    def remember(stats):
        after.update({k: stats[k] for k in CAMERA_KEYS})
        return True
    s = Script()
    s.wait(3)
    two_orbits(s)
    click(s, UI["camera"])  # the Camera button opens the Camera menu
    s.wait(3)
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
    `set shape_apply confirm` it waits, and Enter applies it."""
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
        (waits, ["--script=set shape_apply confirm"], camera_still({"shape_pending": is_text("mask"), "masked": near(0)})),
        (entered, ["--script=set shape_apply confirm"], camera_still({"shape_pending": is_text("none"), "masked": near(1), "undo_steps": near(1)})),
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
TRAY_OBJECT_REBUILD = (1116, 446)  # the Rebuild row of the tray's list, the Object palette open
REBUILD_GOALS = {"even": (1284, 236), "fewer": (1377, 236), "quads": (1471, 236)}
REBUILD_DENSITY = (1406, 296)  # on the Density slider's track
REBUILD_APPLY = (1377, 409)


def open_rebuild(s, goal=None, tap=click):
    s.wait(3)
    tap(s, UI["list_object"])
    s.wait(6)
    tap(s, TRAY_OBJECT_REBUILD)
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


# Remesh's quick menu (kit_remesh_quick, rebuild.odin), a long press on the bottom bar's
# Remesh at 1600x900: Density's track, its Half / Same / Double, the Remesh button and More
# options.
REMESH_QUICK = {"density": (1019, 600), "half": (894, 647), "same": (989, 647), "double": (1083, 647),
                "remesh": (990, 725), "more": (929, 777)}


@scenario
def remesh_long_press_opens_its_quick_menu():
    """A long press on the bottom bar's Remesh opens its small menu over it, not the whole
    section; Double sets twice the sphere's 40k and Remesh rebuilds it at that, in one undo
    step, with the menu still open to try again."""
    s = Script()
    s.wait(3)
    long_press(s, *UI["remesh"])
    s.wait(8)
    s.ftap(*REMESH_QUICK["double"])
    s.wait(3)
    s.ftap(*REMESH_QUICK["remesh"])
    s.wait(10)
    return s, [], camera_still({"bar_pop": is_text("remesh_quick"), "rebuild_goal": is_text("even"), "undo_steps": near(1),
                                "vertices": lambda v: 75_000 < int(v) < 90_000, "dabs": near(0)})


@scenario
def remesh_quick_menu_density_shows_the_cells():
    """A finger held on the quick menu's Density shows the remesh's cells on the object, as
    the Rebuild section's does; More options then opens that section in its place."""
    held, more = Script(), Script()
    for sc in (held, more):
        sc.wait(3)
        long_press(sc, *UI["remesh"])
        sc.wait(8)
    x, y = REMESH_QUICK["density"]
    held.fdrag([(x, y), (x - 30, y), (x - 50, y)], lift=False)
    held.wait(20)
    more.ftap(*REMESH_QUICK["more"])
    more.wait(8)
    return Steps([
        (more, [], camera_still({"bar_pop": is_text("remesh"), "undo_steps": near(0)})),
        (held, [], camera_still({"rebuild_preview": near(1), "rebuild_cell": lambda v: float(v) > 0, "undo_steps": near(0), "dabs": near(0)})),
    ])


@scenario
def shading_and_camera_have_their_own_buttons():
    """The right bar's Shading button opens the Shading menu, whose Wireframe row turns the
    wireframe on; Camera then opens the Camera menu in its place, whose Orthographic row
    switches the projection."""
    s = Script()
    s.wait(3)
    s.ftap(*UI["shading"])
    s.wait(8)
    s.ftap(*SHADING_WIREFRAME)
    s.wait(3)
    s.ftap(*UI["camera"])
    s.wait(8)
    s.ftap(*CAMERA_ORTHO)
    s.wait(4)
    return s, [], camera_still({"bar_pop": is_text("camera"), "wireframe": near(1), "ortho": near(1), "dabs": near(0)})


# The Shading menu's Wireframe row and the Camera menu's Orthographic row, at 1600x900.
SHADING_WIREFRAME = (1399, 294)
CAMERA_ORTHO = (1399, 112)


@scenario
def rebuild_even_is_a_straight_remesh():
    """Rebuild > Even > Remesh at its 500k gives, bit for bit, the mesh a start-up
    `remesh_to 500000` gives, as one undo step: the preview's lattice is the remesh's."""
    direct, panel = autosave_folder() + "-direct.ply", autosave_folder() + "-panel.ply"
    s = Script()
    open_rebuild(s, "even")
    click(s, REBUILD_APPLY)
    s.wait(10)
    return Steps([
        (Script(), ["--script=remesh_to 500000", f"--export={direct}"], {}),
        (s, [f"--export={panel}"], {"undo_steps": near(1), "adjust_op": is_text("remesh"), "@a straight remesh": same_file(direct, panel)}),
    ])


@scenario
def script_sets_up_the_run():
    """A start-up script that rebuilds the sphere, picks Clay and shows the wireframe sets
    the run up the same way given inline (--script), as a file (--run) or taking frames: a
    stroke after it, at the same frame, gives the same mesh bit for bit, and only the stroke
    is in the History."""
    scripted = autosave_folder() + "-script.ply"
    def stroke():
        s = Script()
        s.mouse_drag(line((760, 430), (860, 480), 8))
        s.wait(5)
        return s
    script = "set rebuild_goal even; set rebuild_even 200000; rebuild; brush clay; wireframe on"
    # The same as a file for --run, a statement a line, with comments.
    file = os.path.join(ROOT, "build", "touch", CURRENT.name + ".cmd")
    os.makedirs(os.path.dirname(file), exist_ok=True)
    with open(file, "w", encoding="utf-8") as f:
        f.write("# Rebuild the sphere at 200k.\nset rebuild_goal even\nset rebuild_even 200000\nrebuild\n\nbrush clay  # then Clay\nwireframe on\n")
    from_file = autosave_folder() + "-file.ply"
    waited = autosave_folder() + "-waited.ply"
    want = {"undo_steps": near(1), "wireframe": near(1, 0), "script_failed": near(0), "script_ran": near(5, 0)}
    return Steps([
        (stroke(), [f"--script={script}", f"--export={scripted}"], want),
        (stroke(), [f"--run={file}", f"--export={from_file}"], dict(want, **{"@the inline script's mesh": same_file(scripted, from_file)})),
        # A script that takes frames: the stroke still comes once, after it.
        (stroke(), [f"--script={script}; wait 20", f"--export={waited}"],
         dict(want, **{"script_ran": near(6, 0), "script_frames": near(21, 1), "@the inline script's mesh": same_file(scripted, waited)})),
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
    click(s, UI["list_object"])
    s.mouse_drag(line((1377, 243), (1477, 243), 10))
    click(s, (1377, 697))
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



# Posing (pose.odin): Ctrl + a mouse drag from empty space masks everything below the
# sphere's middle on screen, a hard edge, so the gizmo goes to the free ring along it.
POSE_MASK = line((250, 470), (1296, 880), 10)


def pose_masked(s, presses):
    """The lower half masked by a Ctrl rectangle, then the Move tool with W pressed `presses` more times."""
    s.mouse_drag(POSE_MASK, keys=("ctrl",))
    s.wait(2)
    gizmo_mode(s, presses)
    s.wait(2)


POSE_CENTER = (803, 467)  # where the gizmo goes for that mask
POSE_Y_RING = (POSE_CENTER[0], POSE_CENTER[1] + 31)
POSE_X_ARM = (POSE_CENTER[0] + 38, POSE_CENTER[1] + 8)


def pose_still(checks):
    """`checks`, the camera still, the sphere where it began and the gizmo where the POSE_ points assume."""
    home = is_text("0.0000,0.0000,0.0000,0.000,0.000,0.000,1.0000")
    return camera_still(dict({"transform": home, "pose_mode": near(1), "gizmo_at": is_text(f"{POSE_CENTER[0]},{POSE_CENTER[1]}")}, **checks))


# The sum of the sphere's coordinates as it starts (it is symmetric): mesh_sum.
def mesh_home(v):
    return abs(float(v)) < 1e-3


@scenario
def pose_ring_turns_the_free_part():
    """With the lower half masked, the gizmo sits on the mask's edge and its group reads
    Pose: a Y ring drag turns the upper half, not the sphere, as one undo step, and Ctrl+Z
    puts every vertex back."""
    turned, undone = Script(), Script()
    for sc in (turned, undone):
        pose_masked(sc, 1)
        sc.mouse_drag(line(POSE_Y_RING, (POSE_Y_RING[0] + 60, POSE_Y_RING[1]), 6))
        sc.wait(2)
    undone.press("z", ("ctrl",))
    return Steps([
        (turned, [], pose_still({"pose_drags": near(1), "pose_moved": lambda v: int(v) > 1000, "gizmo_last": is_text("turn_y"), "undo_steps": near(2),
                                 "mesh_sum": lambda v: not mesh_home(v)})),
        (undone, [], pose_still({"undo_steps": near(1), "redo_steps": near(1), "mesh_sum": mesh_home})),
    ])


@scenario
def pose_escape_and_ctrl_i_mid_drag():
    """Esc mid-drag puts the mesh back with no step; Ctrl+I mid-drag ends the pose as its
    own step before inverting the mask, and the rest of the drag does nothing."""
    escape, invert = Script(), Script()
    for sc in (escape, invert):
        pose_masked(sc, 0)
        sc.add(f"move:{POSE_X_ARM[0]},{POSE_X_ARM[1]}")
        sc.wait(1)
        sc.add("down")
        for p in line(POSE_X_ARM, (POSE_X_ARM[0] + 60, POSE_X_ARM[1] + 12), 6)[1:]:
            sc.wait(1)
            sc.add(f"move:{p[0]:g},{p[1]:g}")
        sc.wait(1)
    escape.add("key:Escape")
    escape.wait(1)
    escape.add("keyup:Escape")
    invert.press("i", ("ctrl",))
    for sc in (escape, invert):
        sc.add(f"move:{POSE_X_ARM[0] + 120},{POSE_X_ARM[1] + 24}")
        sc.wait(2)
        sc.add("up")
        sc.wait(4)
    return Steps([
        (escape, [], camera_still({"pose_drags": near(0), "undo_steps": near(1), "mesh_sum": mesh_home})),
        (invert, [], camera_still({"pose_drags": near(1), "undo_steps": near(3), "mesh_sum": lambda v: not mesh_home(v)})),
    ])


@scenario
def pose_body_drag_and_typed_offset():
    """In pose mode a drag on the sphere's body still moves the whole sphere; a click on the
    X arm then 0.5 and Enter moves the free part, not the sphere, and the gizmo with it."""
    body, typed = Script(), Script()
    pose_masked(body, 0)
    body.mouse_drag(line((600, 300), (660, 280), 6))
    pose_masked(typed, 0)
    click(typed, POSE_X_ARM)
    type_value(typed, "0.5")
    moved = transform_is(lambda x, y, z, rx, ry, rz, sc: math.dist((x, y, z), (0, 0, 0)) > 0.05 and (rx, ry, rz, sc) == (0, 0, 0, 1))
    return Steps([
        (body, [], camera_still({"transform": moved, "pose_drags": near(0), "undo_steps": near(2)})),
        (typed, [], camera_still({"transform": is_text("0.0000,0.0000,0.0000,0.000,0.000,0.000,1.0000"), "pose_drags": near(1), "undo_steps": near(2), "gizmo_entry": is_text("none"),
                                  "gizmo_at": lambda v: int(v.split(",")[0]) > POSE_CENTER[0] + 20})),
    ])


# The topological mask (pose.odin): Ctrl and a drag from the sphere's upper left, off the
# gizmo, with the Move tool.
TOPO_PRESS = (600, 300)
TOPO_DRAG = line(TOPO_PRESS, (TOPO_PRESS[0] + 150, TOPO_PRESS[1]), 10)


@scenario
def topo_mask_ctrl_drag_masks_along_the_surface():
    """With the Move tool, Ctrl and a drag on the sphere masks it from the press along the
    surface (free near it, masked beyond) as one undo step, and the handles then pose; a
    Ctrl click only selects, and Ctrl+Z takes the mask back."""
    dragged, tapped, undone = Script(), Script(), Script()
    for sc in (dragged, tapped, undone):
        sc.press("w")
    for sc in (dragged, undone):
        sc.mouse_drag(TOPO_DRAG, keys=("ctrl",))
        sc.wait(4)
    tapped.mouse_drag([TOPO_PRESS, TOPO_PRESS], keys=("ctrl",))
    tapped.wait(2)
    undone.press("z", ("ctrl",))
    return Steps([
        (dragged, [], camera_still({"topo_masks": near(1), "topo_reach": lambda v: float(v) > 0.2, "undo_steps": near(1), "pose_mode": near(1),
                                    "masked": near(1), "mask_mean": lambda v: 0.3 < float(v) < 0.99, "dabs": near(0)})),
        (tapped, [], camera_still({"topo_masks": near(0), "undo_steps": near(0), "masked": near(0), "selected": near(0)})),
        (undone, [], camera_still({"undo_steps": near(0), "redo_steps": near(1), "masked": near(0), "pose_mode": near(0)})),
    ])


@scenario
def topo_mask_by_finger_with_the_rail():
    """With the rail's Mask latched and the Move tool on, a finger dragged from the sphere
    makes the topological mask; Escape mid-drag with the mouse puts the mask back."""
    finger, escape = Script(), Script()
    rail_tap(finger, "mask")
    finger.press("w")
    finger.fdrag(TOPO_DRAG)
    finger.wait(4)
    escape.press("w")
    escape.add("key:ctrl")
    escape.add(f"move:{TOPO_PRESS[0]},{TOPO_PRESS[1]}")
    escape.wait(1)
    escape.add("down")
    for p in TOPO_DRAG[1:]:
        escape.wait(1)
        escape.add(f"move:{p[0]:g},{p[1]:g}")
    escape.wait(1)
    escape.add("key:Escape")
    escape.wait(1)
    escape.add("keyup:Escape")
    escape.wait(1)
    escape.add("up")
    escape.add("keyup:ctrl")
    escape.wait(4)
    return Steps([
        (finger, [], camera_still({"topo_masks": near(1), "undo_steps": near(1), "masked": near(1), "dabs": near(0)})),
        (escape, [], camera_still({"topo_masks": near(0), "undo_steps": near(0), "masked": near(0)})),
    ])

@scenario
def voxel_stroke_sculpts_the_clay_and_undoes():
    """On a voxel sphere (--voxels) a finger stroke lays dabs on the clay as one undo step, which
    Ctrl+Z takes back and Ctrl+Shift+Z brings back; a Grab stroke (key 8) is refused with a note
    and makes no step."""
    s = Script()
    strokes(s, 1)
    s.press("z", ("ctrl",))
    s.press("z", ("ctrl", "shift"))
    s.press("8")
    strokes(s, 1)
    return s, ["--voxels=96"], camera_still({"voxel_objects": near(1), "dabs": lambda v: int(v) > 0, "undo_steps": near(1), "redo_steps": near(0),
                                            "stroke_kind": is_text("draw"), "last_op": is_text("Grab_is_not_a_voxel_brush:_voxels_take_Draw")})


@scenario
def voxel_convert_to_mesh_undoes_and_redoes():
    """Convert to mesh (from the command palette; a start-up script's steps are not undoable) makes
    the voxel object a mesh as one undo step; Ctrl+Z brings the clay back, and a stroke on it then
    drops the redo."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("convert to mesh")
    s.press("Return")
    s.wait(6)
    s.press("z", ("ctrl",))
    s.wait(4)
    strokes(s, 1)
    return s, ["--voxels=96"], camera_still({"voxel_objects": near(1), "dabs": lambda v: int(v) > 0, "palette": near(0),
                                            "undo_steps": near(1), "redo_steps": near(0)})


@scenario
def voxel_object_has_a_picture_in_the_objects_card():
    """The Objects card shows a picture of a voxel object, drawn from its clay's surface as a
    mesh's is from its current level."""
    s = Script()
    objects_card(s)
    return s, ["--voxels=96"], {"voxel_objects": near(1), "card_rows": near(1), "thumbs_drawn": near(1), "dabs": near(0)}


@scenario
def voxel_mesh_converts_to_voxels_and_back():
    """Convert to voxels (from the command palette) makes the mesh sphere a voxel object as one
    undo step and a stroke on the clay another; two Ctrl+Z bring the mesh back. Undoing the swap
    forgets the clay's strokes (as any rebuild does), so one redo step is left: the conversion."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("convert to voxels")
    s.press("Return")
    s.wait(8)
    strokes(s, 1)
    s.press("z", ("ctrl",))
    s.wait(4)
    s.press("z", ("ctrl",))
    s.wait(6)
    return s, [], camera_still({"voxel_objects": near(0), "objects": near(1), "dabs": lambda v: int(v) > 0, "palette": near(0),
                                "undo_steps": near(0), "redo_steps": near(1)})


@scenario
def voxel_resolution_steps_up_and_down_as_undo_steps():
    """Res+ (from the command palette) doubles a 64-across voxel sphere to 128 as one undo step and
    Res- halves it back to 64 as another; Ctrl+Z returns it to 128, and a stroke then sculpts the
    finer clay, which drops the redo step as any stroke does."""
    s = Script()
    s.press("k", ("ctrl",))
    s.type("res+")
    s.press("Return")
    s.wait(6)
    s.press("k", ("ctrl",))
    s.type("res-")
    s.press("Return")
    s.wait(6)
    s.press("z", ("ctrl",))
    s.wait(6)
    strokes(s, 1)
    return s, ["--voxels=64"], camera_still({"voxel_objects": near(1), "voxel_resolution": near(128), "dabs": lambda v: int(v) > 0,
                                            "palette": near(0), "undo_steps": near(2), "redo_steps": near(0)})


@scenario
def voxel_object_deleted_comes_back_with_undo():
    """Delete takes the voxel object out as one undo step and Ctrl+Z brings it back, clay and all; a stroke then sculpts it."""
    s = Script()
    s.press("Delete")
    s.wait(4)
    s.press("z", ("ctrl",))
    s.wait(4)
    strokes(s, 1)
    return s, ["--voxels=96"], camera_still({"voxel_objects": near(1), "objects": near(1), "dabs": lambda v: int(v) > 0, "undo_steps": near(1)})


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
