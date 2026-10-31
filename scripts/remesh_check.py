#!/usr/bin/env python3
"""Runs Remesh, Remesh with Quads and Quad Remesh over a corpus of generated meshes and
tables what each gave, against the acceptance the plan set.

    python scripts/remesh_check.py                       # the whole corpus, build/remesh_check/report.md
    python scripts/remesh_check.py --only gap --keep     # one fixture, its OBJ outputs kept
    python scripts/remesh_check.py --vertices 50000 --quads 4000
    python scripts/remesh_check.py --real "Female expression6.obj"   # a real sculpt besides

Each fixture is written as an OBJ into build/remesh_check/fixtures by a generator here
(deterministic, nothing random), then each tool runs on it in the headless app:
`--import` the fixture, `--script` the tool's set lines and verb (what the panel would
do) and `--export` the selected object (the remeshed one, or Quad Remesh's new object, as
quads where it has them). The log gives the time (Remesh's own line, Quad Remesh's result
line, which also says when the engine fell back to the built-in one and why). A run the
app ends with exit code 2 refused or warned (the script runner fails a statement whose
result is a warning, and then exports nothing): the row says what the result line or the
last warning said. Any other failure is a crash. The exported OBJ is read back as
polygons for the rest: faces, the quads' share, the share of vertices with four faces,
boundary and non-manifold edges, the signed volume against the input's, and the deviation
from the input (every output vertex's distance to the nearest input triangle, as a share
of the input's bounding diagonal). Memory is the app's own `peak_rss_mb` exit stat (Linux
and Android; 0 elsewhere). `--stability` runs each tool once more on one thread and
compares the two OBJ files byte for byte.

The Check column holds the plan's acceptance (the report's section 7) per fixture: a
closed fixture's Remesh must come back closed and manifold (every face a quad with
Quads), its volume within 1 % of the input's, every vertex within 0.6 of the lattice
spacing of the input (a closed solid's surface; an open input's caps lie off it) and, for
a single solid, its count within 5 % of the request; Quad
Remesh must give at least 99 % quads with no boundary or non-manifold edge, faces within
-25 % / +10 % of the request, the volume within 2 %, a deviation under 0.5 % at most and
0.1 % on average, and at least 95 % four-valent vertices on the sphere and the bumpy
sphere, 100 % on the torus. An engine fallback is judged as a result that is not
AutoRemesher's (FAIL, with the engine's reason). Open, non-manifold and invalid fixtures
stay in the table with what they did: a refusal there is a PASS, as is the import's
refusal of a NaN position. The exit code is 1 when a check failed, else 0. A development
aid only: nothing of it ships.
"""

import argparse
import math
import os
import re
import subprocess
import sys
import time

import headless

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "remesh_check")
EXE = os.path.join(ROOT, "build", "sculpt.exe" if os.name == "nt" else "sculpt")


# --- fixtures ------------------------------------------------------------------------

def icosphere(level, radius=1.0, center=(0.0, 0.0, 0.0)):
    t = (1 + 5 ** 0.5) / 2
    verts = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
             (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    verts = [normalize(v) for v in verts]
    tris = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
            (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
            (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    for _ in range(level):
        cache = {}
        out = []

        def mid(a, b):
            key = (min(a, b), max(a, b))
            if key not in cache:
                cache[key] = len(verts)
                verts.append(normalize(tuple((verts[a][i] + verts[b][i]) / 2 for i in range(3))))
            return cache[key]

        for a, b, c in tris:
            ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
            out += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        tris = out
    return [tuple(center[i] + radius * v[i] for i in range(3)) for v in verts], tris


def normalize(v):
    n = math.sqrt(sum(x * x for x in v))
    return tuple(x / n for x in v)


def torus(big=1.0, small=0.4, nu=96, nv=48):
    verts, tris = [], []
    for i in range(nu):
        a = 2 * math.pi * i / nu
        for j in range(nv):
            b = 2 * math.pi * j / nv
            r = big + small * math.cos(b)
            verts.append((r * math.cos(a), small * math.sin(b), r * math.sin(a)))
    for i in range(nu):
        for j in range(nv):
            p, q = i * nv + j, ((i + 1) % nu) * nv + j
            p2, q2 = i * nv + (j + 1) % nv, ((i + 1) % nu) * nv + (j + 1) % nv
            tris += [(p, p2, q), (q, p2, q2)]
    return verts, tris


def tube(radius, half_height, n, axis, center=(0.0, 0.0, 0.0), caps=False):
    """A cylinder's wall along `axis` (open unless `caps`), facing outward."""
    verts, tris = [], []
    o1, o2 = (axis + 1) % 3, (axis + 2) % 3
    for s in (-1, 1):
        for i in range(n):
            a = 2 * math.pi * i / n
            p = [0.0, 0.0, 0.0]
            p[axis], p[o1], p[o2] = s * half_height, radius * math.cos(a), radius * math.sin(a)
            verts.append(tuple(center[k] + p[k] for k in range(3)))
    for i in range(n):
        j = (i + 1) % n
        tris += [(i, n + i, n + j), (i, n + j, j)]
    if caps:
        lo, hi = len(verts), len(verts) + 1
        for s in (-1, 1):
            p = [0.0, 0.0, 0.0]
            p[axis] = s * half_height
            verts.append(tuple(center[k] + p[k] for k in range(3)))
        for i in range(n):
            j = (i + 1) % n
            tris += [(lo, j, i), (hi, n + i, n + j)]
    return verts, tris


def cube(center, size):
    h = size / 2
    verts = [(center[0] + h * x, center[1] + h * y, center[2] + h * z) for z in (-1, 1) for y in (-1, 1) for x in (-1, 1)]
    quads = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
    tris = []
    for a, b, c, d in quads:
        tris += [(a, b, c), (a, c, d)]
    return verts, tris


def merge(*parts):
    verts, tris = [], []
    for v, t in parts:
        base = len(verts)
        verts += v
        tris += [(a + base, b + base, c + base) for a, b, c in t]
    return verts, tris


def moved(part, offset, scale=1.0):
    v, t = part
    return [tuple(scale * p[i] + offset[i] for i in range(3)) for p in v], t


def bumpy():
    v, t = icosphere(6)
    out = []
    for x, y, z in v:
        bump = 1 + 0.08 * math.sin(7 * x) * math.sin(5 * y) * math.cos(6 * z) + 0.04 * math.cos(11 * x + 3 * z)
        out.append((bump * x, bump * y, bump * z))
    return out, t


def gap():
    along = normalize((1.0, 0.7, 0.4))
    s = icosphere(5)
    return merge(moved(s, tuple(-1.01 * a for a in along)), moved(s, tuple(1.01 * a for a in along)))


def rod():
    return merge(icosphere(5), tube(0.03, 1.3, 24, 0, caps=True))


def nonmanifold():
    # Two cubes sharing an edge, and a fin (two triangles) standing on one of them.
    a = cube((0.0, 0.0, 0.0), 1.0)
    b = cube((1.0, 1.0, 0.0), 1.0)
    fin = ([(0.0, 0.5, 0.0), (0.0, 1.2, 0.0), (0.0, 0.5, 0.7)], [(0, 1, 2), (0, 2, 1)])
    return merge(a, b, fin)


def with_nan():
    v, t = icosphere(3)
    v[5] = (float("nan"), 0.0, 0.0)
    return v, t


def with_duplicate():
    v, t = icosphere(3)
    return v, t + [t[0]]


def with_flipped():
    v, t = icosphere(3)
    return v, t[:1] + [(t[1][0], t[1][2], t[1][1])] + t[2:]


# name: (builder, the Remesh checks, the Quad Remesh checks). Checks: "closed" (closed and
# manifold, every face a quad with Quads), "near" (every vertex within 0.6 of the lattice
# spacing of the input: a closed solid's surface, not an open input whose caps lie off it), "volume"
# (within 1 % of the input's; 2 % for Quad Remesh), "count" (within 5 % of the request),
# "quads" (99 % quads, no boundary or non-manifold edge, faces within -25 % / +10 %,
# deviation, AutoRemesher itself), "regular" (95 % four-valent), "regular100" (every
# vertex), "refuse" (a refusal, a fallback or a result all pass), "unreadable" (the import
# refuses the file).
FIXTURES = {
    "sphere": (lambda: icosphere(5), {"closed", "near", "volume", "count"}, {"quads", "volume", "regular"}),
    "torus": (torus, {"closed", "near", "volume", "count"}, {"quads", "volume", "regular100"}),
    # The input's signed volume counts the overlap twice, so no volume check.
    "overlap": (lambda: merge(icosphere(5), moved(icosphere(5), (0.8, 0.3, 0.0))), {"closed", "near"}, {"quads"}),
    "gap": (gap, {"closed", "near", "volume"}, {"quads", "volume"}),
    "rod": (rod, {"closed", "near", "volume"}, {"quads", "volume"}),
    "cylinder": (lambda: tube(0.5, 1.0, 48, 1), {"closed"}, {"refuse"}),
    "pieces": (lambda: merge(icosphere(4), moved(icosphere(4), (2.0, 0.0, 0.0), 0.5), moved(icosphere(4), (0.0, 1.8, 0.0), 0.25)),
               {"closed", "near", "volume"}, {"quads", "volume"}),
    "nonmanifold": (nonmanifold, {"closed"}, {"refuse"}),
    "bumpy": (bumpy, {"closed", "near", "volume", "count"}, {"quads", "volume", "regular"}),
    "nan": (with_nan, {"unreadable"}, {"unreadable"}),
    "duplicate": (with_duplicate, {"closed", "near", "volume"}, {"refuse"}),
    "flipped": (with_flipped, {"closed", "near", "volume"}, {"refuse"}),
}


def write_obj(path, verts, faces):
    with open(path, "w", encoding="utf-8") as f:
        f.write("# remesh_check fixture\n")
        for v in verts:
            f.write("v %.6f %.6f %.6f\n" % v)
        for face in faces:
            f.write("f " + " ".join(str(i + 1) for i in face) + "\n")


# --- measuring an OBJ ------------------------------------------------------------------

def read_obj(path):
    verts, faces = [], []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("v "):
                verts.append(tuple(float(x) for x in line.split()[1:4]))
            elif line.startswith("f "):
                faces.append(tuple(int(w.split("/")[0]) - 1 for w in line.split()[1:]))
    return verts, faces


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def volume(verts, faces):
    v = 0.0
    for face in faces:
        a = verts[face[0]]
        for i in range(1, len(face) - 1):
            v += dot(a, cross(verts[face[i]], verts[face[i + 1]])) / 6
    return v


def topology(verts, faces):
    """Quads' share, non-quads, four-valent share, boundary, non-manifold and inconsistent
    edge counts, and whether the mesh is closed and manifold."""
    edges = {}
    per_vertex = [0] * len(verts)
    quads = 0
    for face in faces:
        if len(face) == 4:
            quads += 1
        for i, a in enumerate(face):
            b = face[(i + 1) % len(face)]
            per_vertex[a] += 1
            key = (min(a, b), max(a, b))
            n, forward = edges.get(key, (0, 0))
            edges[key] = (n + 1, forward + (1 if a < b else 0))
    boundary = sum(1 for n, _ in edges.values() if n == 1)
    non_manifold = sum(1 for n, _ in edges.values() if n > 2)
    inconsistent = sum(1 for n, f in edges.values() if n == 2 and f != 1)
    four = sum(1 for n in per_vertex if n == 4)
    return {
        "quads": quads / max(len(faces), 1),
        "non_quads": len(faces) - quads,
        "four": four / max(len(verts), 1),
        "boundary": boundary,
        "non_manifold": non_manifold,
        "inconsistent": inconsistent,
        "closed": boundary == 0 and non_manifold == 0 and inconsistent == 0 and len(faces) > 0,
    }


def closest_on_triangle(p, a, b, c):
    """The squared distance from p to triangle abc (Ericson, Real-Time Collision Detection)."""
    ab, ac, ap = sub(b, a), sub(c, a), sub(p, a)
    d1, d2 = dot(ab, ap), dot(ac, ap)
    if d1 <= 0 and d2 <= 0:
        return dot(ap, ap)
    bp = sub(p, b)
    d3, d4 = dot(ab, bp), dot(ac, bp)
    if d3 >= 0 and d4 <= d3:
        return dot(bp, bp)
    vc = d1 * d4 - d3 * d2
    if vc <= 0 and d1 >= 0 and d3 <= 0:
        v = d1 / (d1 - d3) if d1 != d3 else 0
        q = sub(p, (a[0] + v * ab[0], a[1] + v * ab[1], a[2] + v * ab[2]))
        return dot(q, q)
    cp = sub(p, c)
    d5, d6 = dot(ab, cp), dot(ac, cp)
    if d6 >= 0 and d5 <= d6:
        return dot(cp, cp)
    vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0:
        w = d2 / (d2 - d6) if d2 != d6 else 0
        q = sub(p, (a[0] + w * ac[0], a[1] + w * ac[1], a[2] + w * ac[2]))
        return dot(q, q)
    va = d3 * d6 - d5 * d4
    if va <= 0 and d4 - d3 >= 0 and d5 - d6 >= 0:
        w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        q = sub(p, (b[0] + w * (c[0] - b[0]), b[1] + w * (c[1] - b[1]), b[2] + w * (c[2] - b[2])))
        return dot(q, q)
    denom = 1 / (va + vb + vc)
    v, w = vb * denom, vc * denom
    q = sub(p, (a[0] + ab[0] * v + ac[0] * w, a[1] + ab[1] * v + ac[1] * w, a[2] + ab[2] * v + ac[2] * w))
    return dot(q, q)


class Surface:
    """The input's triangles in a grid, for the distance from a point to the surface."""

    def __init__(self, verts, tris):
        self.verts, self.tris = verts, tris
        used = [verts[i] for t in tris for i in t]
        lo = [min(v[i] for v in used) for i in range(3)]
        hi = [max(v[i] for v in used) for i in range(3)]
        self.diagonal = math.sqrt(sum((hi[i] - lo[i]) ** 2 for i in range(3))) or 1.0
        self.lo = lo
        self.cell = self.diagonal / 48
        # The grid's last cell on each axis: a search past it on every axis has seen everything.
        self.hi_cell = [int((hi[i] - lo[i]) // self.cell) for i in range(3)]
        self.grid = {}
        for t, tri in enumerate(tris):
            pts = [verts[i] for i in tri]
            lo_c = [int((min(p[i] for p in pts) - lo[i]) // self.cell) for i in range(3)]
            hi_c = [int((max(p[i] for p in pts) - lo[i]) // self.cell) for i in range(3)]
            for x in range(lo_c[0], hi_c[0] + 1):
                for y in range(lo_c[1], hi_c[1] + 1):
                    for z in range(lo_c[2], hi_c[2] + 1):
                        self.grid.setdefault((x, y, z), []).append(t)

    def distance(self, p):
        c = [int((p[i] - self.lo[i]) // self.cell) for i in range(3)]
        best = None
        # Rings widen until one holds a triangle and the next could hold no nearer one; the
        # last ring reaches every grid cell from p, so a far point (a cap on an open input)
        # still gets its true distance.
        last = max(max(c[i], self.hi_cell[i] - c[i]) for i in range(3))
        for ring in range(0, last + 1):
            for x in range(c[0] - ring, c[0] + ring + 1):
                for y in range(c[1] - ring, c[1] + ring + 1):
                    for z in range(c[2] - ring, c[2] + ring + 1):
                        if max(abs(x - c[0]), abs(y - c[1]), abs(z - c[2])) != ring:
                            continue
                        for t in self.grid.get((x, y, z), ()):
                            a, b, cc = (self.verts[i] for i in self.tris[t])
                            d = closest_on_triangle(p, a, b, cc)
                            if best is None or d < best:
                                best = d
            # Anything in a farther ring is at least `ring` cells away.
            if best is not None and best <= (ring * self.cell) ** 2:
                break
        return math.sqrt(best)


def deviation(surface, verts, at_most=100_000):
    """Max and mean distance to the surface over every vertex (every k-th past `at_most`)."""
    step = max(1, len(verts) // at_most)
    ds = [surface.distance(verts[i]) for i in range(0, len(verts), step)]
    if not ds:
        return 0.0, 0.0
    return max(ds) / surface.diagonal, sum(ds) / len(ds) / surface.diagonal


def area(verts, tris):
    total = 0.0
    for a, b, c in tris:
        n = cross(sub(verts[b], verts[a]), sub(verts[c], verts[a]))
        total += math.sqrt(dot(n, n)) / 2
    return total


# --- running the app -------------------------------------------------------------------

# Remesh's own log line always carries its time (the result line leaves it out under 50 ms).
REMESH_LINE = re.compile(r"remesh: (\d+) vertices in (\d+) ms")
RESULT_REMESH = re.compile(r"Remeshed .*?: [\d,]+ vertices(?: \(\d+ ms\))?(.*)$")
# "Quad remeshed X: 1,608 quads (AutoRemesher), UVs in 12 charts, 226 ms", the engine
# "built-in, as AutoRemesher said <why>" when it fell back.
RESULT_QUAD = re.compile(r"Quad remeshed .*?: (.*?) \((.*)\)(?:, UVs in \d+ charts)?, (\d+) ms\s*$")
WARNING = re.compile(r"\[WARN \].*?\] (?:\[.*?\] )?(.*)$")
UNREADABLE = re.compile(r"Cannot read .*?: (.*)$")

# The app's exit code when a script statement refused or warned (src/app/script.odin).
EXIT_SCRIPT_FAILED = 2


def run_app(fixture_obj, script, out_obj, timeout, threads=0):
    env = headless.env(dict(os.environ, SDL_ASSERT="abort"))
    cmd = [EXE, "--import=" + fixture_obj, "--script=" + script, "--frames=2", "--export=" + out_obj]
    if threads:
        cmd.append("--threads=%d" % threads)
    start = time.time()
    info = {"crashed": False, "warned": False, "unreadable": "", "note": "", "ms": None, "rss": 0.0, "detail": "", "fell_back": "",
            "wall": 0.0}
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        info["crashed"], info["note"], info["wall"] = True, "timed out after %d s" % timeout, time.time() - start
        return info
    info["wall"] = time.time() - start
    text = proc.stdout + proc.stderr
    for line in text.splitlines():
        m = REMESH_LINE.search(line)
        if m:
            info["ms"] = int(m.group(2))
        m = RESULT_REMESH.search(line)
        if m:
            info["detail"] = m.group(1).strip("; ")
        m = RESULT_QUAD.search(line)
        if m:
            info["ms"], info["detail"] = int(m.group(3)), m.group(1)
            engine = m.group(2)
            if engine.startswith("built-in"):
                info["fell_back"] = engine
        m = WARNING.search(line)
        if m:
            info["note"] = m.group(1)
        m = UNREADABLE.search(line)
        if m:
            info["unreadable"] = m.group(1)
        if line.startswith("peak_rss_mb="):
            info["rss"] = float(line.split("=")[1])
    if proc.returncode == EXIT_SCRIPT_FAILED:
        info["warned"] = True
    elif proc.returncode != 0 and not info["unreadable"]:
        info["crashed"] = True
        info["note"] = info["note"] or "exit %d" % proc.returncode
    return info


# --- the table -------------------------------------------------------------------------

def pct(x):
    return "%.1f%%" % (100 * x)


def check_run(tool, checks, info, result, requested, input_volume, spacing, stable):
    """What the row's Check column says: PASS or FAIL and why."""
    if "unreadable" in checks:
        return "PASS (the import refused it)" if info["unreadable"] and not info["crashed"] else "FAIL (the import took a NaN position)"
    if info["crashed"]:
        return "FAIL (%s)" % (info["note"] or "the app did not exit normally")
    if info["unreadable"]:
        return "FAIL (the import refused it: %s)" % info["unreadable"]
    if "refuse" in checks:
        return "PASS"
    if result is None:
        why = info["fell_back"] or info["note"] or "no result"
        return "FAIL (%s)" % why
    fails = []
    if info["fell_back"]:
        fails.append(info["fell_back"])
    t = result["topology"]
    if "closed" in checks:
        if not t["closed"]:
            fails.append("%d boundary, %d non-manifold, %d inconsistent edges" % (t["boundary"], t["non_manifold"], t["inconsistent"]))
        if tool == "remesh-quads" and t["non_quads"] > 0:
            fails.append("%d faces are not quads" % t["non_quads"])
    if "near" in checks and spacing and result["dev_max_abs"] > 0.6 * spacing:
        fails.append("a vertex %.3f off the input, the spacing being %.3f" % (result["dev_max_abs"], spacing))
    if "volume" in checks and input_volume:
        limit = 0.02 if "quads" in checks else 0.01
        if abs(result["volume"] - input_volume) > limit * abs(input_volume):
            fails.append("volume %.4f against the input's %.4f" % (result["volume"], input_volume))
    if "count" in checks and abs(result["vertices"] - requested) > 0.05 * requested:
        fails.append("%d vertices for %d asked" % (result["vertices"], requested))
    if "quads" in checks:
        if t["quads"] < 0.99:
            fails.append("%s quads" % pct(t["quads"]))
        if t["boundary"] or t["non_manifold"] or t["inconsistent"]:
            fails.append("%d boundary and %d non-manifold edges" % (t["boundary"], t["non_manifold"] + t["inconsistent"]))
        if not -0.25 * requested <= result["faces"] - requested <= 0.10 * requested:
            fails.append("%d faces for %d asked" % (result["faces"], requested))
        if result["dev_max"] > 0.005 or result["dev_mean"] > 0.001:
            fails.append("deviation max %.2f%% mean %.3f%%" % (100 * result["dev_max"], 100 * result["dev_mean"]))
    if "regular" in checks and t["four"] < 0.95:
        fails.append("%s four-valent" % pct(t["four"]))
    if "regular100" in checks and t["four"] < 1:
        fails.append("%s four-valent, not all" % pct(t["four"]))
    if stable is False:
        fails.append("the one-thread run differs")
    verdict = "PASS" if not fails else "FAIL (" + "; ".join(fails) + ")"
    if stable:
        verdict += ", stable"
    return verdict


def measure(out_obj, surface):
    if not os.path.exists(out_obj):
        return None
    verts, faces = read_obj(out_obj)
    if not faces:
        return None
    dev_max, dev_mean = deviation(surface, verts)
    return {"vertices": len(verts), "faces": len(faces), "topology": topology(verts, faces), "volume": volume(verts, faces),
            "dev_max": dev_max, "dev_mean": dev_mean, "dev_max_abs": dev_max * surface.diagonal}


def row(fixture, tool, info, result, check):
    if result is None:
        if info["unreadable"]:
            what = "not imported: " + info["unreadable"]
        elif info["fell_back"]:
            what = "%s (%s), not exported since the run warned" % (info["detail"], info["fell_back"])
        elif info["ms"] is not None and info["detail"]:
            what = "%s, not exported since the run warned" % info["detail"]
        else:
            what = "refused: " + (info["note"] or "no result")
        return "| %s | %s | %s | | | | | | %s | %.0f | %s |" % (fixture, tool, what, "" if info["ms"] is None else info["ms"], info["rss"], check)
    t = result["topology"]
    edges = "closed" if t["closed"] else "%d boundary, %d non-manifold, %d inconsistent" % (t["boundary"], t["non_manifold"], t["inconsistent"])
    return "| %s | %s | %s vertices, %s faces | %s (%d not) | %s | %s | %.4f | %.2f%% / %.3f%% | %s | %.0f | %s |" % (
        fixture, tool, "{:,}".format(result["vertices"]), "{:,}".format(result["faces"]), pct(t["quads"]), t["non_quads"], pct(t["four"]), edges,
        result["volume"], 100 * result["dev_max"], 100 * result["dev_mean"], "" if info["ms"] is None else info["ms"], info["rss"], check)


HEADER = ("| Fixture | Tool | Result | Quads | Four-valent | Edges | Volume | Deviation max / mean | ms (result line) | Peak MB | Check |\n"
          "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")


def main(argv):
    global EXE
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", help="run this fixture alone (or `real`)")
    parser.add_argument("--vertices", type=int, default=20000, help="what Remesh asks for (20,000)")
    parser.add_argument("--quads", type=int, default=2000, help="what Quad Remesh asks for (2,000)")
    parser.add_argument("--real", help="an OBJ of a real sculpt to run besides, Quad Remesh with Close first off and on")
    parser.add_argument("--app", default=EXE, help="the app to run (build/sculpt)")
    parser.add_argument("--keep", action="store_true", help="keep the exported OBJ files")
    parser.add_argument("--timeout", type=int, default=1800, help="seconds a run may take")
    parser.add_argument("--stability", action="store_true", help="run each tool again on one thread and compare the OBJ files")
    args = parser.parse_args(argv)
    EXE = args.app
    if not os.path.exists(EXE):
        print("no app at %s: build it first" % EXE)
        return 2
    os.makedirs(os.path.join(OUT, "fixtures"), exist_ok=True)
    names = list(FIXTURES)
    if args.real:
        names.append("real")
    if args.only:
        if args.only not in names:
            print("no fixture %s; there are %s" % (args.only, ", ".join(names)))
            return 2
        names = [args.only]
    rows, failed = [], 0
    tools = [
        ("remesh", "set remesh_quads off; set rebuild_goal even; set rebuild_even %d; rebuild" % args.vertices, args.vertices, 0),
        ("remesh-quads", "set remesh_quads on; set rebuild_goal even; set rebuild_even %d; rebuild" % args.vertices, args.vertices, 1),
        ("quad-remesh", "set retopo_close_first off; set retopo_quads %d; retopologize" % args.quads, args.quads, 2),
    ]
    for name in names:
        if name == "real":
            fixture_obj = os.path.abspath(args.real)
            verts, faces = read_obj(fixture_obj)
            tris = []
            for f in faces:
                for i in range(1, len(f) - 1):
                    tris.append((f[0], f[i], f[i + 1]))
            remesh_checks, quad_checks = set(), set()
            runs = tools + [("quad-remesh-closed-first", "set retopo_close_first on; set retopo_quads %d; retopologize" % args.quads, args.quads, 2)]
        else:
            builder, remesh_checks, quad_checks = FIXTURES[name]
            verts, tris = builder()
            fixture_obj = os.path.join(OUT, "fixtures", name + ".obj")
            write_obj(fixture_obj, verts, tris)
            runs = tools
        print("%s: %s triangles" % (name, "{:,}".format(len(tris))), flush=True)
        # Triangles with a NaN corner (the invalid fixture) are no surface to measure against.
        sound = [t for t in tris if all(all(math.isfinite(x) for x in verts[i]) for i in t)]
        surface = Surface(verts, sound) if sound else None
        sound_verts = [verts[i] for t in sound for i in t]
        input_volume = volume(verts, sound) if sound_verts else 0.0
        # Remesh's lattice spacing for the request (geom.remesh_spacing).
        spacing = math.sqrt(1.5 * area(verts, sound) / args.vertices) if sound else 0.0
        for tool, script, requested, kind in runs:
            out_obj = os.path.join(OUT, "%s_%s.obj" % (name, tool))
            if os.path.exists(out_obj):
                os.remove(out_obj)
            info = run_app(fixture_obj, script, out_obj, args.timeout)
            result = measure(out_obj, surface) if surface is not None and not info["crashed"] and info["ms"] is not None else None
            stable = None
            if args.stability and result is not None:
                again = out_obj[:-4] + "_one_thread.obj"
                run_app(fixture_obj, script, again, args.timeout, threads=1)
                stable = os.path.exists(again) and open(again, "rb").read() == open(out_obj, "rb").read()
                if not args.keep and os.path.exists(again):
                    os.remove(again)
            checks = remesh_checks if kind < 2 else quad_checks
            check = check_run(tool, checks, info, result, requested, input_volume, spacing if kind < 2 else 0.0, stable)
            if check.startswith("FAIL"):
                failed += 1
            line = row(name, tool, info, result, check)
            rows.append(line)
            print("  " + line, flush=True)
            if not args.keep and os.path.exists(out_obj):
                os.remove(out_obj)
    report = "# remesh_check: %d vertices asked of Remesh, %d quads of Quad Remesh\n\n%s\n%s\n" % (args.vertices, args.quads, HEADER, "\n".join(rows))
    path = os.path.join(OUT, "report.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(report)
    print("\n%s\n%s" % (HEADER, "\n".join(rows)))
    print("\n%d checks failed; the table is in %s" % (failed, os.path.relpath(path, ROOT)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
