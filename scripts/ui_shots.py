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
    "library": ("The brush Library from the shelf's All", tap("dock/All"), []),
    "menu": ("The main menu", tap("top bar/Menu"), []),
    "object_menu": ("The object chip's menu", tap("top bar/Object"), []),
    "search": ("Search with 'smooth' typed", tap("top bar/Search commands") + ";14:text:smooth", []),
    "settings": ("Settings on its first section", tap("top bar/Settings"), []),
    "history": ("The History card", tap("top bar/History"), []),
    "model": ("The Model space with its shelf", tap("top bar/Model"), []),
    "render": ("The Render space", tap("top bar/Render"), []),
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
               f"--settings-file={settings}", f"--dump-screen={dump}", f"--ui-map={out / (key + '.map')}"] + extra
        if events:
            cmd.append(f"--ui-events={events}")
        run = subprocess.run(headless.wrap(cmd), env=headless.env(), capture_output=True, text=True, timeout=600)
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
