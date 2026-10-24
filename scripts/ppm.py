#!/usr/bin/env python3
"""View, compare and inspect the viewport dumps the app writes with --dump-viewport.

The app writes a binary P6 PPM (RGB, rows top to bottom; write_ppm in src/app/main.odin).
A coding agent can look at a PNG but not at a PPM, and when two runs are compared a
number beats a look, so this script converts, diffs and samples dumps with nothing but
the standard library.

    python scripts/ppm.py to-png build/view.ppm build/view.png
    python scripts/ppm.py uniform build/view.ppm                      # exit 1 on a blank frame
    python scripts/ppm.py diff build/a.ppm build/b.ppm [--threshold 0] [--out b.diff.png]
    python scripts/ppm.py crop build/view.ppm --rect x,y,w,h [--scale 4] build/crop.png
    python scripts/ppm.py pixel build/view.ppm 20,15 100,100
    python scripts/ppm.py selftest [--keep DIR]                      # proves the checks catch a shift

The first line of output is the verdict. Exit codes: 0 ok (for diff: the same), 1 the
images differ, the image is uniform, or the selftest failed, 2 usage or unreadable input.

Break it once before trusting it: change CHANGED_EXPECTED below from 76 to 77, run
`python scripts/ppm.py selftest`, see `FAIL selftest: changed: expected 77 got 76`, revert.
"""

import argparse
import struct
import sys
import tempfile
import zlib
from pathlib import Path


class PpmError(Exception):
    """A dump that cannot be read; the message says why."""


# --- images ------------------------------------------------------------------------


def read_ppm(path):
    """Returns (width, height, rgb bytes) of a binary P6 PPM with maxval 255."""
    data = Path(path).read_bytes()
    pos, tokens = 0, []
    while len(tokens) < 4:
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        if pos < len(data) and data[pos : pos + 1] == b"#":
            while pos < len(data) and data[pos : pos + 1] not in (b"\n", b"\r"):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        if start == pos:
            raise PpmError(f"{path}: truncated header")
        tokens.append(data[start:pos])
    if tokens[0] != b"P6":
        raise PpmError(f"{path}: not a binary P6 PPM (magic {tokens[0]!r}); the app writes P6")
    try:
        w, h, maxval = int(tokens[1]), int(tokens[2]), int(tokens[3])
    except ValueError:
        raise PpmError(f"{path}: header is not 'P6 width height maxval'") from None
    if maxval != 255:
        raise PpmError(f"{path}: maxval {maxval} (only 255 is supported)")
    pos += 1  # exactly one whitespace byte separates the header from the pixels
    rgb = data[pos : pos + w * h * 3]
    if len(rgb) != w * h * 3:
        raise PpmError(f"{path}: expected {w * h * 3} pixel bytes for {w}x{h}, found {len(rgb)}")
    return w, h, rgb


def write_ppm(path, w, h, rgb):
    """The app's exact header, so selftest fixtures match real dumps byte for byte."""
    Path(path).write_bytes(b"P6\n%d %d\n255\n" % (w, h) + rgb)


def write_png(path, w, h, rgb):
    """8-bit RGB, one IDAT, filter 0 on every row: the simplest PNG a viewer accepts."""

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    stride = w * 3
    raw = b"".join(b"\x00" + rgb[y * stride : (y + 1) * stride] for y in range(h))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    Path(path).write_bytes(png)


def read_png_rgb(path):
    """Reads back only what write_png writes (filter 0), to keep the selftest honest."""
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise PpmError(f"{path}: not a PNG")
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        (n,) = struct.unpack(">I", data[pos : pos + 4])
        kind, body = data[pos + 4 : pos + 8], data[pos + 8 : pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            if (depth, ctype) != (8, 2):
                raise PpmError(f"{path}: not 8-bit RGB")
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride, rows = zlib.decompress(idat), w * 3, []
    for y in range(h):
        if raw[y * (stride + 1)] != 0:
            raise PpmError(f"{path}: row {y} uses a filter this reader does not know")
        rows.append(raw[y * (stride + 1) + 1 : (y + 1) * (stride + 1)])
    return w, h, b"".join(rows)


def hexcolor(rgb, i):
    return "#%02X%02X%02X" % (rgb[i], rgb[i + 1], rgb[i + 2])


def is_uniform(rgb):
    return rgb == rgb[:3] * (len(rgb) // 3)


def compare(w, h, a, b, threshold=0):
    """Per-pixel largest channel difference; a pixel counts as changed above the threshold.

    Returns changed count, the bounding box of the changed pixels as (x, y, w, h) or None,
    the largest difference and where it first occurs, and a diff image: changed pixels
    red over a dim copy of `a`, so the eye finds the region the numbers name.
    """
    diff = bytearray(len(a))
    changed, max_diff, at = 0, 0, (0, 0)
    x0 = y0 = x1 = y1 = None
    for i in range(w * h):
        j = 3 * i
        d = max(abs(a[j] - b[j]), abs(a[j + 1] - b[j + 1]), abs(a[j + 2] - b[j + 2]))
        if d > max_diff:
            max_diff, at = d, (i % w, i // w)
        if d > threshold:
            changed += 1
            x, y = i % w, i // w
            x0 = x if x0 is None or x < x0 else x0
            x1 = x if x1 is None or x > x1 else x1
            y0 = y if y0 is None else y0  # scan order: the first changed row is the lowest
            y1 = y
            diff[j : j + 3] = b"\xff\x00\x00"
        else:
            diff[j] = diff[j + 1] = diff[j + 2] = (a[j] + a[j + 1] + a[j + 2]) // 9
    bbox = None if changed == 0 else (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    return {"changed": changed, "total": w * h, "bbox": bbox, "max_diff": max_diff, "at": at, "diff": bytes(diff)}


def crop(w, h, rgb, x, y, cw, ch, scale):
    """Nearest-neighbour enlargement of a rectangle, clamped to the image."""
    x0, y0, x1, y1 = max(0, x), max(0, y), min(w, x + cw), min(h, y + ch)
    if x1 <= x0 or y1 <= y0:
        raise PpmError(f"rectangle {x},{y},{cw},{ch} lies outside the {w}x{h} image")
    out = bytearray()
    for yy in range(y0, y1):
        row = bytearray()
        for xx in range(x0, x1):
            k = 3 * (yy * w + xx)
            row += rgb[k : k + 3] * scale
        out += row * scale
    return (x1 - x0) * scale, (y1 - y0) * scale, bytes(out), x0, y0


# --- commands ----------------------------------------------------------------------


def ints(text, n, what):
    parts = text.split(",")
    if len(parts) != n or not all(p.strip().lstrip("-").isdigit() for p in parts):
        raise PpmError(f"{what} must be {n} integers separated by commas, not {text!r}")
    return [int(p) for p in parts]


def cmd_to_png(args):
    w, h, rgb = read_ppm(args.ppm)
    write_png(args.png, w, h, rgb)
    print(f"ok to-png: {args.png} {w}x{h}")
    if is_uniform(rgb):
        print(f"warning: uniform image ({hexcolor(rgb, 0)}): a blank frame")
    return 0


def cmd_uniform(args):
    w, h, rgb = read_ppm(args.ppm)
    if is_uniform(rgb):
        print(f"FAIL uniform: every pixel of {args.ppm} is {hexcolor(rgb, 0)} ({w}x{h}): a blank frame")
        return 1
    print(f"ok uniform: {args.ppm} {w}x{h} is not uniform")
    return 0


def cmd_diff(args):
    wa, ha, a = read_ppm(args.a)
    wb, hb, b = read_ppm(args.b)
    if (wa, ha) != (wb, hb):
        print(f"FAIL diff: sizes differ: {wa}x{ha} vs {wb}x{hb}")
        return 1
    r = compare(wa, ha, a, b, args.threshold)
    if r["changed"] == 0:
        print(f"ok diff: same within {args.threshold} ({wa}x{ha}; largest channel difference {r['max_diff']})")
        return 0
    out = args.out or str(Path(args.b).with_suffix(".diff.png"))
    write_png(out, wa, ha, r["diff"])
    x, y, w, h = r["bbox"]
    ax, ay = r["at"]
    k = 3 * (ay * wa + ax)
    print(f"FAIL diff: {r['changed']} pixel(s) differ by more than {args.threshold} ({100 * r['changed'] / r['total']:.3f}% of {wa}x{ha})")
    print(f"bbox={x},{y},{w},{h} (x {x}..{x + w - 1}, y {y}..{y + h - 1}); to look closer: python scripts/ppm.py crop {args.b} --rect {x},{y},{w},{h} --scale 4 build/crop.png")
    print(f"max_diff={r['max_diff']} at=({ax},{ay}) a={hexcolor(a, k)} b={hexcolor(b, k)}")
    print(f"diff image: {out} (changed pixels red over a dim copy of a); open it with Read")
    return 1


def cmd_crop(args):
    w, h, rgb = read_ppm(args.ppm)
    x, y, cw, ch = ints(args.rect, 4, "--rect")
    if args.scale < 1:
        raise PpmError("--scale must be at least 1")
    ow, oh, out, x0, y0 = crop(w, h, rgb, x, y, cw, ch, args.scale)
    write_png(args.png, ow, oh, out)
    print(f"ok crop: {args.png} {ow}x{oh} from ({x0},{y0}) at {args.scale}x; open it with Read")
    return 0


def cmd_pixel(args):
    w, h, rgb = read_ppm(args.ppm)
    points = [ints(p, 2, "a point") for p in args.points]
    for x, y in points:
        if not (0 <= x < w and 0 <= y < h):
            raise PpmError(f"({x},{y}) is outside the {w}x{h} image")
    print(f"ok pixel: {args.ppm} {w}x{h}")
    for x, y in points:
        k = 3 * (y * w + x)
        print(f"({x},{y}) {hexcolor(rgb, k)} rgb({rgb[k]}, {rgb[k + 1]}, {rgb[k + 2]})")
    return 0


# Two 10x8 white rectangles on a dark background, the second shifted by (3, 2): they
# overlap in 7x6 = 42 pixels, so 38 + 38 pixels differ.
CHANGED_EXPECTED = 76


def selftest_images():
    w, h, bg = 64, 48, b"\x20\x20\x20"

    def image(rx, ry):
        px = bytearray(bg * (w * h))
        for y in range(ry, ry + 8):
            for x in range(rx, rx + 10):
                px[3 * (y * w + x) : 3 * (y * w + x) + 3] = b"\xff\xff\xff"
        return bytes(px)

    return w, h, image(20, 15), image(23, 17)


def cmd_selftest(args):
    w, h, a, b = selftest_images()
    checks = []
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(args.keep or tmp)
        d.mkdir(parents=True, exist_ok=True)
        write_ppm(d / "a.ppm", w, h, a)
        write_ppm(d / "b.ppm", w, h, b)
        header = (d / "a.ppm").read_bytes()[:13]
        checks.append(("ppm header", b"P6\n64 48\n255\n", header))
        checks.append(("ppm round trip", (w, h, a), read_ppm(d / "a.ppm")))
        write_png(d / "a.png", w, h, a)
        checks.append(("png round trip", (w, h, a), read_png_rgb(d / "a.png")))
        r = compare(w, h, a, b)
        checks.append(("changed", CHANGED_EXPECTED, r["changed"]))
        checks.append(("bbox", (20, 15, 13, 10), r["bbox"]))
        checks.append(("max_diff at", (223, (20, 15)), (r["max_diff"], r["at"])))
        diff = r["diff"]
        checks.append(("diff pixels", (b"\xff\x00\x00", b"\x0a\x0a\x0a"), (diff[3 * (15 * w + 20) :][:3], diff[:3])))
        checks.append(("uniform", (True, False), (is_uniform(b"\x20\x20\x20" * (w * h)), is_uniform(a))))
        checks.append(("pixel", ("#FFFFFF", "#202020"), (hexcolor(a, 3 * (18 * w + 25)), hexcolor(a, 0))))
        cw, ch, c, _, _ = crop(w, h, a, 20, 15, 10, 8, 2)
        checks.append(("crop", (20, 16, b"\xff\xff\xff", b"\xff\xff\xff"), (cw, ch, c[:3], c[3 * (15 * 20 + 19) :][:3])))
        checks.append(("same image", 0, compare(w, h, a, a)["changed"]))
    for name, want, got in checks:
        if want != got:
            print(f"FAIL selftest: {name}: expected {want!r} got {got!r}")
            return 1
    print(f"ok selftest: {len(checks)} checks passed")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("to-png", help="convert a dump to a PNG that can be looked at")
    s.add_argument("ppm")
    s.add_argument("png")
    s.set_defaults(run=cmd_to_png)
    s = sub.add_parser("uniform", help="exit 1 when every pixel is the same: a blank frame")
    s.add_argument("ppm")
    s.set_defaults(run=cmd_uniform)
    s = sub.add_parser("diff", help="count, box and picture the pixels that differ between two dumps")
    s.add_argument("a")
    s.add_argument("b")
    s.add_argument("--threshold", type=int, default=0, help="largest channel difference still counted as the same (default 0)")
    s.add_argument("--out", help="the diff image (default: <b>.diff.png)")
    s.set_defaults(run=cmd_diff)
    s = sub.add_parser("crop", help="enlarge a rectangle to a PNG (nearest neighbour)")
    s.add_argument("ppm")
    s.add_argument("png")
    s.add_argument("--rect", required=True, help="x,y,w,h in pixels")
    s.add_argument("--scale", type=int, default=4)
    s.set_defaults(run=cmd_crop)
    s = sub.add_parser("pixel", help="print the colour at one or more x,y points")
    s.add_argument("ppm")
    s.add_argument("points", nargs="+")
    s.set_defaults(run=cmd_pixel)
    s = sub.add_parser("selftest", help="check every command on a synthetic pair of images")
    s.add_argument("--keep", help="write the synthetic images and PNG here instead of a temp dir")
    s.set_defaults(run=cmd_selftest)
    args = p.parse_args(argv)
    try:
        return args.run(args)
    except (PpmError, OSError) as e:
        print(f"FAIL {args.cmd}: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
