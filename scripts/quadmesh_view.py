#!/usr/bin/env python3
"""Draws a Quad Remesh stage dump (the app's --quadmesh-dump, src/quadmesh/dump.odin) as a
PNG, so a stage can be looked at on its own without the app.

    python scripts/quadmesh_view.py build/qd/island0_3_cover1.obj build/qd/cover.png
    python scripts/quadmesh_view.py build/qd/island0_3_cover1.obj build/qd/uv.png --flat
    python scripts/quadmesh_view.py build/qd/island0_4_quads.obj build/qd/quads.png --view left
    python scripts/quadmesh_view.py build/qd/island0_2_isotropic.obj build/qd/iso.png --size 1600

A cover (vertices, a UV per triangle corner as `f v/vt`, the singular vertices as `p`)
is drawn shaded with its integer UV lines on it, one pixel wide whatever the zoom: the
quads the extraction traces. A triangle whose UV turns the wrong way (a fold) is red, and
a singular vertex a magenta dot. `--flat` draws the UV layout instead: every triangle at
its UV, folds red, the integer lines over it. Any other dump (the thin island, the
isotropic mesh, the quads) is drawn shaded with its polygons' edges, and its feature
edges (`l`) orange. The view is orthographic along an axis (`--view`, front by default)
or from `--yaw` and `--pitch` degrees. Pure Python, no packages: a mesh of a hundred
thousand triangles takes some seconds. A development aid only: nothing of it ships.
"""

import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppm import write_png  # noqa: E402

VIEWS = {"front": (0, 0), "back": (180, 0), "left": (-90, 0), "right": (90, 0), "top": (0, 90), "bottom": (0, -90)}

BACKGROUND = (34, 36, 40)
SURFACE = (200, 202, 206)
FOLD = (220, 60, 50)
GRID = (30, 110, 200)
EDGE = (40, 42, 48)
FEATURE = (240, 150, 30)
SINGULAR = (230, 40, 200)
FLAT_FILL = (190, 194, 200)


def read_obj(path):
    """Positions, UVs, faces as (vertex indices, UV indices or None), points and lines."""
    v, vt, faces, points, lines = [], [], [], [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            kind = parts[0]
            if kind == "v":
                v.append((float(parts[1]), float(parts[2]), float(parts[3])))
            elif kind == "vt":
                vt.append((float(parts[1]), float(parts[2])))
            elif kind == "f":
                corners = [p.split("/") for p in parts[1:]]
                vs = [int(c[0]) - 1 for c in corners]
                uvs = [int(c[1]) - 1 for c in corners] if all(len(c) > 1 and c[1] for c in corners) else None
                faces.append((vs, uvs))
            elif kind == "p":
                points.extend(int(p) - 1 for p in parts[1:])
            elif kind == "l":
                idx = [int(p) - 1 for p in parts[1:]]
                lines.extend(zip(idx, idx[1:]))
    return v, vt, faces, points, lines


def view_basis(yaw, pitch):
    """Screen right, up and toward the viewer for a camera turned `yaw` about y and tilted
    `pitch` up, looking at the mesh from +z when both are 0."""
    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    toward = (sy * cp, sp, cy * cp)
    right = (cy, 0.0, -sy)
    up = (-sy * sp, cp, -cy * sp)
    return right, up, toward


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def fit(points2d, size, margin=0.06):
    """The scale and offset putting 2D points inside a size by size image, y down."""
    xs = [p[0] for p in points2d]
    ys = [p[1] for p in points2d]
    lo_x, hi_x, lo_y, hi_y = min(xs), max(xs), min(ys), max(ys)
    span = max(hi_x - lo_x, hi_y - lo_y, 1e-12)
    scale = size * (1 - 2 * margin) / span
    ox = size / 2 - scale * (lo_x + hi_x) / 2
    oy = size / 2 + scale * (lo_y + hi_y) / 2
    return lambda p: (ox + scale * p[0], oy - scale * p[1])


class Image:
    def __init__(self, size):
        self.size = size
        self.rgb = bytearray(BACKGROUND * (size * size))
        self.depth = [-math.inf] * (size * size)

    def put(self, x, y, color):
        i = 3 * (y * self.size + x)
        self.rgb[i : i + 3] = bytes(color)

    def dot(self, cx, cy, radius, color, depth=None):
        for y in range(max(0, int(cy - radius)), min(self.size, int(cy + radius) + 2)):
            for x in range(max(0, int(cx - radius)), min(self.size, int(cx + radius) + 2)):
                if (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= radius * radius:
                    if depth is None or depth >= self.depth[y * self.size + x] - self.tolerance:
                        self.put(x, y, color)


def raster(img, tri, shade):
    """Fills screen triangle `tri` ((x, y, depth) three times), calling shade(b0, b1, b2)
    for the colour of each pixel whose centre it covers and that is nearest the viewer."""
    (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = tri
    area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if area == 0:
        return
    size = img.size
    lo_x, hi_x = max(0, int(math.floor(min(x0, x1, x2)))), min(size - 1, int(math.ceil(max(x0, x1, x2))))
    lo_y, hi_y = max(0, int(math.floor(min(y0, y1, y2)))), min(size - 1, int(math.ceil(max(y0, y1, y2))))
    inv = 1.0 / area
    depth = img.depth
    for y in range(lo_y, hi_y + 1):
        py = y + 0.5
        for x in range(lo_x, hi_x + 1):
            px = x + 0.5
            b0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) * inv
            b1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) * inv
            b2 = 1.0 - b0 - b1
            if b0 < 0 or b1 < 0 or b2 < 0:
                continue
            z = b0 * z0 + b1 * z1 + b2 * z2
            i = y * size + x
            if z <= depth[i]:
                continue
            depth[i] = z
            img.put(x, y, shade(b0, b1, b2))


def mix(a, b, t):
    return tuple(int(a[k] + (b[k] - a[k]) * t) for k in range(3))


def lit(color, light):
    return tuple(int(c * light) for c in color)


def draw_3d(img, v, vt, faces, points, lines, basis):
    right, up, toward = basis
    projected = [(dot(p, right), dot(p, up)) for p in v]
    to_screen = fit(projected, img.size)
    screen = []
    for p, q in zip(v, projected):
        sx, sy = to_screen(q)
        screen.append((sx, sy, dot(p, toward)))
    xs = [s[0] for s in screen]
    zs = [s[2] for s in screen]
    # A depth a pixel's worth of size, so a point or a line on the surface passes the test.
    scale = (max(xs) - min(xs)) / max(max(dot(p, right) for p in v) - min(dot(p, right) for p in v), 1e-12)
    img.tolerance = 2.0 / max(scale, 1e-12) + 1e-9 * (max(zs) - min(zs))
    folds = 0
    for vs, uvs in faces:
        a, b, c = v[vs[0]], v[vs[1]], v[vs[2]]
        n = cross(sub(b, a), sub(c, a))
        length = math.sqrt(dot(n, n)) or 1.0
        facing = dot(n, toward) / length
        light = 0.35 + 0.65 * abs(facing)
        fold = False
        if uvs is not None and len(vs) == 3:
            (u0, w0), (u1, w1), (u2, w2) = vt[uvs[0]], vt[uvs[1]], vt[uvs[2]]
            fold = (u1 - u0) * (w2 - w0) - (u2 - u0) * (w1 - w0) < 0
            folds += fold
            draw_cover_triangle(img, [screen[i] for i in vs], [vt[i] for i in uvs], lit(FOLD if fold else SURFACE, light), light)
            continue
        # A polygon as a fan; only its own sides are drawn as edges.
        count = len(vs)
        for k in range(1, count - 1):
            tri = [screen[vs[0]], screen[vs[k]], screen[vs[k + 1]]]
            sides = (True, k + 1 == count - 1, k == 1)  # the side opposite each corner is the polygon's own
            draw_edged_triangle(img, tri, sides, lit(SURFACE, light))
    for a, b in lines:
        draw_line(img, screen[a], screen[b], FEATURE)
    for s in points:
        x, y, z = screen[s]
        img.dot(x, y, max(2.5, img.size / 300), SINGULAR, z)
    return folds


def draw_cover_triangle(img, tri, uv, color, light):
    """A cover triangle: its integer UV lines one pixel wide, from the UV's screen gradient."""
    (x0, y0, _), (x1, y1, _), (x2, y2, _) = tri
    det = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
    if det == 0:
        return
    grads = []
    for c in range(2):
        d1, d2 = uv[1][c] - uv[0][c], uv[2][c] - uv[0][c]
        gx = (d1 * (y2 - y0) - d2 * (y1 - y0)) / det
        gy = (d2 * (x1 - x0) - d1 * (x2 - x0)) / det
        grads.append(math.hypot(gx, gy) or 1e-12)
    grid = lit(GRID, light)

    def shade(b0, b1, b2):
        for c in range(2):
            t = b0 * uv[0][c] + b1 * uv[1][c] + b2 * uv[2][c]
            if abs(t - round(t)) / grads[c] < 0.6:
                return grid
        return color

    raster(img, tri, shade)


def draw_edged_triangle(img, tri, sides, color):
    """A triangle with its marked sides (the one opposite each corner) drawn dark, about a
    pixel wide: a barycentric times the corner's height over that side is the distance."""
    (x0, y0, _), (x1, y1, _), (x2, y2, _) = tri
    area2 = abs((x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0))
    lengths = (math.hypot(x2 - x1, y2 - y1), math.hypot(x0 - x2, y0 - y2), math.hypot(x1 - x0, y1 - y0))
    heights = [area2 / l if l > 0 else 0.0 for l in lengths]
    edge = mix(color, EDGE, 0.85)

    def shade(b0, b1, b2):
        for b, h, side in ((b0, heights[0], sides[0]), (b1, heights[1], sides[1]), (b2, heights[2], sides[2])):
            if side and b * h < 0.7:
                return edge
        return color

    raster(img, tri, shade)


def draw_line(img, a, b, color):
    steps = int(max(abs(b[0] - a[0]), abs(b[1] - a[1]))) + 1
    for k in range(steps + 1):
        t = k / steps
        x, y, z = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
        xi, yi = int(x), int(y)
        if 0 <= xi < img.size and 0 <= yi < img.size and z >= img.depth[yi * img.size + xi] - img.tolerance:
            img.put(xi, yi, color)


def draw_flat(img, vt, faces, points, v):
    """The UV layout: each triangle at its UV, folds red, the integer lines over it."""
    corners = [vt[i] for _, uvs in faces if uvs for i in uvs]
    if not corners:
        return 0
    to_screen = fit(corners, img.size)
    folds = 0
    for _, uvs in faces:
        if not uvs or len(uvs) != 3:
            continue
        uv = [vt[i] for i in uvs]
        fold = (uv[1][0] - uv[0][0]) * (uv[2][1] - uv[0][1]) - (uv[2][0] - uv[0][0]) * (uv[1][1] - uv[0][1]) < 0
        folds += fold
        # Folds drawn on top, so a fold under a sound triangle still shows.
        tri = [(*to_screen(p), 1.0 if fold else 0.0) for p in uv]
        draw_cover_triangle(img, tri, uv, FOLD if fold else FLAT_FILL, 1.0)
    return folds


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("obj", help="a dump's OBJ file (island<i>_<stage>.obj)")
    parser.add_argument("png", help="the PNG to write")
    parser.add_argument("--size", type=int, default=1024, help="the image's side in pixels (1024)")
    parser.add_argument("--view", choices=sorted(VIEWS), default="front", help="the axis looked along (front)")
    parser.add_argument("--yaw", type=float, help="degrees turned about the up axis, instead of --view")
    parser.add_argument("--pitch", type=float, default=None, help="degrees tilted up, with --yaw")
    parser.add_argument("--flat", action="store_true", help="draw a cover's UV layout instead of the surface")
    args = parser.parse_args(argv)
    v, vt, faces, points, lines = read_obj(args.obj)
    if not v or not faces:
        print("%s has no faces to draw" % args.obj)
        return 2
    for vs, _ in faces:
        if any(i < 0 or i >= len(v) for i in vs):
            print("%s names a vertex it does not have" % args.obj)
            return 2
    img = Image(args.size)
    img.tolerance = 0.0
    if args.flat:
        if not vt:
            print("%s has no UVs: --flat draws a cover (island<i>_3_cover<k>.obj)" % args.obj)
            return 2
        folds = draw_flat(img, vt, faces, points, v)
    else:
        yaw, pitch = VIEWS[args.view]
        if args.yaw is not None:
            yaw, pitch = args.yaw, args.pitch or 0.0
        folds = draw_3d(img, v, vt, faces, points, lines, view_basis(yaw, pitch))
    write_png(args.png, args.size, args.size, bytes(img.rgb))
    what = "%d faces, %d vertices" % (len(faces), len(v))
    if vt:
        what += ", %d folded, %d singular" % (folds, len(points))
    if lines:
        what += ", %d feature edges" % len(lines)
    print("%s: %s" % (args.png, what))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
