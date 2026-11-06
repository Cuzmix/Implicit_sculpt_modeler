#!/usr/bin/env python3
"""The interface's screenshot corpus: the same screens, at a desktop and a tablet size, in a
dark and a light theme, every time, so a change to the interface is judged like with like
(the sm-ui-review skill scores them; scripts/ui_audit.py reads their control maps).

    python scripts/ui_shots.py                          # every screen, both sizes, both themes
    python scripts/ui_shots.py tool_card mesh_card      # some screens (fnmatch patterns too)
    python scripts/ui_shots.py --sizes tablet --themes lens --out build/ui_shots/before
    python scripts/ui_shots.py list                     # the screens and what each opens
    python scripts/ui_shots.py sheet BEFORE AFTER OUT   # before/after pairs, changes boxed

A shot is build/ui_shots/<screen>@<size>-<theme>.png with its control map beside it
(.map, the --ui-map lines). Screens open their panel by a control's name (--ui-events
@NAME), so they hold when the layout moves. `sheet` puts each pair side by side with every
changed region outlined in red on the after, and writes a summary line per screen: what an
eye cannot find in two similar pictures, the boxes point at.

Exit codes: 0 every shot was taken (or every sheet written), 1 a run failed or a screen's
control was not found, 2 usage. Only the standard library is used (PNGs through ppm.py).
"""

import argparse
import concurrent.futures
import fnmatch
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import headless  # noqa: E402
import ppm  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "build" / ("sculpt.exe" if os.name == "nt" else "sculpt")

# Window sizes in points: a desktop window, and an 11 inch iPad held landscape (the
# M2 iPad Air's 1180 x 820 points), where the interface must fit as it ships.
SIZES = {"desktop": (1600, 900), "tablet": (1180, 820)}
# The tablet runs as a tablet with no keyboard does: no key hints, the dial's names shown.
SIZE_FLAGS = {"desktop": [], "tablet": ["--no-keyboard"]}
# A dark theme and a light one: Lens, the default, and Paper, whose low-emphasis colours
# are the first to fail. Each is a settings file's `look` line.
THEMES = {"lens": "Lens", "paper": "Paper"}


def tap(name, at=5):
    """A mouse click on the control called `name`, `at` frames in."""
    return f"{at}:move:@{name};{at + 1}:down;{at + 2}:up"


# Each screen: (what it shows, the --ui-events that open it, extra arguments). The order is
# the order a person meets them: the bare view, the panels beside it, then what floats.
SCREENS = {
    "sculpt": ("The default Sculpt screen, nothing open", "", []),
    "tool_card": ("The Tool card from the view rail", tap("view bar/Tool"), []),
    "layers_card": ("The Layers card from the view rail", tap("view bar/Layers"), []),
    "scene_card": ("The Scene card from the view rail", tap("view bar/Scene"), []),
    "mesh_card": ("The Mesh card from the view rail", tap("view bar/Mesh"), []),
    "mask_card": ("The Mask card from the view rail", tap("view bar/Mask"), []),
    "uv_checker": ("An unwrapped sculpt in the Checker texture view, the Textures section open", "", ["--script=unwrap; texture_view 3; open_section textures"]),
    "uv_checker_level": ("An unwrapped sculpt two subdivision levels up in the Checker texture view: the UVs it takes from the base", "", ["--script=unwrap; subdivide; subdivide; texture_view 3; open_section textures"]),
    "uvs_straighten": ("A Quad Remesh sphere after Straighten in the UV checker, the UVs section's More options open", "", ["--script=set retopo_quads 600; retopologize; straighten; solo_object; frame_all; texture_view 3; open_section uvs; set all_options on"]),
    "uvs_texel_density": ("An unwrapped sphere set to 256 px a unit in the UV checker, the layout shrunk into the square's corner, More options open", "", ["--script=unwrap; set uv_texel_px 256; texel_density; solo_object; frame_all; texture_view 3; open_section uvs; set all_options on"]),
    "paint_new_menu": ("The Paint tab's New layer menu on an unwrapped sphere: On vertices, or In a texture at the Bake size", tap("view bar/Layers") + ";" + tap("card Layers/Paint", 20) + ";" + tap("card Layers/New layer", 35), ["--script=unwrap"]),
    "paint_texture_layer": ("A texture layer made from the New layer menu over a vertex layer, picked in the Paint tab", tap("view bar/Layers") + ";" + tap("card Layers/Paint", 20) + ";" + tap("card Layers/New layer", 30) + ";" + tap("paint new menu/In a texture", 42), ["--script=unwrap; paint fill"]),
    "paint_channels": ("A paint layer on PBR clay painting colour, roughness and metal: the channel strip under the layer list", tap("view bar/Layers") + ";" + tap("card Layers/Paint", 20) + ";" + tap("card Layers/Rough", 35) + ";" + tap("card Layers/Metal", 50), ["--script=set material pbr clay; brush paint; new_paint_layer"]),
    "uvs_peel": ("An unwrapped sculpt half peeled into its UV layout, the UVs section's Peel at the middle", tap("card Mesh/Peel", 20), ["--script=unwrap; open_section uvs"]),
    "uvs_peel_flat": ("An unwrapped sculpt peeled all the way: its UV layout standing flat, facing the view", tap("card Mesh/Peel~135,0", 20), ["--script=unwrap; open_section uvs"]),
    "uvs_section": ("The Mesh card's UVs section after Unwrap, the islands shown as polygroups", "", ["--script=unwrap; group uv_charts; polygroups on; open_section uvs"]),
    "stack_card_cage": ("The Live stack card on a cage: its SHAPE rows, Smooth open, then COPIES with an Array", tap("view bar/Live stack") + ";" + tap("card Stack/stack row Smooth", 20), ["--script=add_cage cube; select 1; delete_object; cage_smooth 2; cage_mirror x; stack array 3 0 0 2.5; frame_all"]),
    "export_stack": ("The Export sheet on an object with a live stack: Bake the live stack", "", ["--script=stack array 3 2.2 0 0; export_sheet"]),
    "stack_card": ("The Live stack card with a Mirror, an Array and a Radial row, the Array open", tap("view bar/Live stack") + ";" + tap("card Stack/stack row Array", 20), ["--script=stack mirror x; stack array 3 2.2 0 0; stack radial 6 y; frame_all"]),
    "stack_array": ("The Live stack card with its Array open: the step's arrow and tip in the view", tap("view bar/Live stack") + ";" + tap("card Stack/stack row Array", 20), ["--script=stack array 3 0 2.2 0; frame_all"]),
    "stack_radial": ("The Live stack card with its Radial open: the pivot's dot and the copies' circle in the view", tap("view bar/Live stack") + ";" + tap("card Stack/stack row Radial", 20), ["--script=stack radial 6 y; frame_all"]),
    "stack_mirror": ("The Live stack card with its Mirror open: the X and Z planes and their chips in the view", tap("view bar/Live stack") + ";" + tap("card Stack/stack row Mirror", 20), ["--script=stack mirror xz; frame_all"]),
    "stack_add": ("The Live stack card's Add menu on a sculpt with an Array", tap("view bar/Live stack") + ";" + tap("card Stack/stack foot/Add", 20), ["--script=stack array 3 2.2 0 0"]),
    "library": ("The brush Library from the shelf's All", tap("dock/All"), []),
    "menu": ("The main menu", tap("top bar/Menu"), []),
    "object_menu": ("The object chip's menu", tap("top bar/Object"), []),
    "search": ("Search with 'smooth' typed", tap("top bar/Search commands") + ";14:text:smooth", []),
    "settings": ("Settings on its first section", tap("top bar/Settings"), []),
    "history": ("The History card", tap("top bar/History"), []),
    "model": ("The Model space with its shelf", tap("top bar/Model"), []),
    "render": ("The Render space", tap("top bar/Render"), []),
    "material_card": ("The Material card: the shelf of material balls", "", ["--script=open_section material"]),
    "material_edit": ("The Material card's Edit on Car paint: Surface, then the layers' switches, Coat on", tap("material preview words/Edit", 12), ["--script=set material car paint; open_section material"]),
    "material_scene": ("The Material card's In this scene after a glTF with three materials was dropped in: each object's, by the file's names",
                       f"3:drop:{ROOT / 'src' / 'app' / 'testdata' / 'import' / 'materials.glb'};4:jobwait;" + tap("material categories 0/In this scene", 30), ["--script=open_section material"]),
    "light_card": ("The Light card on its Lights section", "", ["--script=open_section lights"]),
    "render_card": ("The Render card with the render off", "", ["--script=open_section render"]),
    "shading_menu": ("The shading chip's list in Clay: the looks, Colour, the MatCap discs and Import", tap("readout/Shading", 12), ["--script=shading_mode clay"]),
    "render_full": ("The Render card with Full building up", "", ["--script=render_mode on; open_section render"]),
}

FRAMES = 60  # enough for every panel's motion to settle at --ui-dt 1/60


def shot(screen, size, theme, out, exe):
    """Takes one shot; returns (key, ok, message)."""
    _, events, extra = SCREENS[screen]
    w, h = SIZES[size]
    key = f"{screen}@{size}-{theme}"
    with tempfile.TemporaryDirectory() as tmp:
        settings = Path(tmp) / "settings.txt"
        settings.write_text(f"look {THEMES[theme]}\n")
        dump = Path(tmp) / "screen.ppm"
        cmd = [str(exe), f"--width={w}", f"--height={h}", f"--frames={FRAMES}", "--ui-dt=0.016667",
               f"--settings-file={settings}", f"--dump-screen={dump}", f"--ui-map={out / (key + '.map')}"] + SIZE_FLAGS[size] + extra
        if events:
            cmd.append(f"--ui-events={events}")
        run = subprocess.run(headless.wrap(cmd), env=headless.env(exact=True), capture_output=True, text=True, timeout=600)
        if run.returncode != 0:
            tail = (run.stdout + run.stderr).strip().splitlines()[-3:]
            return key, False, f"exit {run.returncode}: " + " | ".join(tail)
        try:
            pw, ph, rgb = ppm.read_ppm(dump)
        except ppm.PpmError as e:
            return key, False, str(e)
        ppm.write_png(out / (key + ".png"), pw, ph, rgb)
    return key, True, f"{pw}x{ph}"


# --- before/after sheets -------------------------------------------------------------

TILE = 16  # changed regions are found on a grid this many pixels square
GAP = 24   # between the two pictures of a pair


def changed_boxes(w, h, a, b, threshold=8):
    """The changed regions between two same-sized images, as (x, y, w, h) boxes: tiles
    with a changed pixel, joined with their changed neighbours."""
    cols, rows = (w + TILE - 1) // TILE, (h + TILE - 1) // TILE
    hot = bytearray(cols * rows)
    for y in range(h):
        base = 3 * y * w
        ty = (y // TILE) * cols
        for x in range(0, w):
            j = base + 3 * x
            if max(abs(a[j] - b[j]), abs(a[j + 1] - b[j + 1]), abs(a[j + 2] - b[j + 2])) > threshold:
                hot[ty + x // TILE] = 1
    seen, boxes = bytearray(cols * rows), []
    for start in range(cols * rows):
        if not hot[start] or seen[start]:
            continue
        stack, x0, y0, x1, y1 = [start], cols, rows, -1, -1
        seen[start] = 1
        while stack:
            t = stack.pop()
            tx, ty = t % cols, t // cols
            x0, y0, x1, y1 = min(x0, tx), min(y0, ty), max(x1, tx), max(y1, ty)
            for nx, ny in ((tx + 1, ty), (tx - 1, ty), (tx, ty + 1), (tx, ty - 1)):
                if 0 <= nx < cols and 0 <= ny < rows:
                    n = ny * cols + nx
                    if hot[n] and not seen[n]:
                        seen[n] = 1
                        stack.append(n)
        boxes.append((x0 * TILE, y0 * TILE, min(w, (x1 + 1) * TILE) - x0 * TILE, min(h, (y1 + 1) * TILE) - y0 * TILE))
    return boxes


def outline(img, w, h, box, color=b"\xff\x30\x30", thick=3):
    x, y, bw, bh = box
    for t in range(thick):
        for xx in range(max(0, x - t), min(w, x + bw + t)):
            for yy in (y - 1 - t, y + bh + t):
                if 0 <= yy < h:
                    img[3 * (yy * w + xx): 3 * (yy * w + xx) + 3] = color
        for yy in range(max(0, y - t), min(h, y + bh + t)):
            for xx in (x - 1 - t, x + bw + t):
                if 0 <= xx < w:
                    img[3 * (yy * w + xx): 3 * (yy * w + xx) + 3] = color


def sheet(before, after, out):
    out.mkdir(parents=True, exist_ok=True)
    pairs = sorted(p.name for p in Path(after).glob("*.png") if (Path(before) / p.name).exists())
    if not pairs:
        print(f"no shots with the same name in {before} and {after}")
        return 1
    for name in pairs:
        wa, ha, a = ppm.read_png_rgb(Path(before) / name)
        wb, hb, b = ppm.read_png_rgb(Path(after) / name)
        if (wa, ha) != (wb, hb):
            print(f"{name}: sizes differ ({wa}x{ha} and {wb}x{hb}), skipped")
            continue
        boxes = changed_boxes(wa, ha, a, b)
        marked = bytearray(b)
        for box in boxes:
            outline(marked, wb, hb, box)
        sw = 2 * wa + GAP
        canvas = bytearray(b"\x40\x40\x40" * (sw * ha))
        for y in range(ha):
            canvas[3 * y * sw: 3 * y * sw + 3 * wa] = a[3 * y * wa: 3 * (y + 1) * wa]
            o = 3 * (y * sw + wa + GAP)
            canvas[o: o + 3 * wa] = marked[3 * y * wa: 3 * (y + 1) * wa]
        ppm.write_png(out / name, sw, ha, bytes(canvas))
        where = ", ".join(f"{x},{y} {bw}x{bh}" for x, y, bw, bh in boxes[:8]) + (" ..." if len(boxes) > 8 else "")
        print(f"{name}: {len(boxes)} changed region(s){': ' + where if boxes else ''}")
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["list"]:
        for name, (what, _, _) in SCREENS.items():
            print(f"{name:14} {what}")
        return 0
    if argv[:1] == ["sheet"]:
        if len(argv) != 4:
            print("usage: ui_shots.py sheet BEFORE_DIR AFTER_DIR OUT_DIR")
            return 2
        return sheet(Path(argv[1]), Path(argv[2]), Path(argv[3]))
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("screens", nargs="*", help="screen names or fnmatch patterns (default: all)")
    p.add_argument("--out", default=str(ROOT / "build" / "ui_shots"))
    p.add_argument("--sizes", default=",".join(SIZES))
    p.add_argument("--themes", default=",".join(THEMES))
    p.add_argument("--exe", default=str(EXE))
    p.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    a = p.parse_args(argv)
    names = [n for n in SCREENS if not a.screens or any(fnmatch.fnmatch(n, pat) for pat in a.screens)]
    sizes, themes = a.sizes.split(","), a.themes.split(",")
    bad = [s for s in sizes if s not in SIZES] + [t for t in themes if t not in THEMES]
    if not names or bad:
        print(f"nothing to take: unknown {bad or a.screens}")
        return 2
    exe = Path(a.exe)
    if not exe.exists():
        print(f"{exe} is missing: build the debug app first")
        return 1
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    jobs = [(n, s, t) for n in names for s in sizes for t in themes]
    failed = 0
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool:
        for key, ok, msg in pool.map(lambda j: shot(*j, out, exe), jobs):
            print(f"{'ok  ' if ok else 'FAIL'} {key} {msg}")
            failed += not ok
    print(f"{len(jobs) - failed} of {len(jobs)} shots in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
