"""The interface's icon fonts and their names, built from assets/icons/manifest.txt.

Each manifest line names one meaning, its colour group and the drawing it uses, picked from
Phosphor (ph), Tabler (tb) or Lucide (lu), or drawn for this app (own) where no pack draws
a sculpting meaning well. This script turns those drawings into three
fonts with the same code point per icon, so the kit draws them through fontstash like text:

    assets/fonts/Icons-Regular.ttf   the line drawing at Phosphor's regular weight
    assets/fonts/Icons-Bold.ttf      the line drawing at Phosphor's bold weight
    assets/fonts/Icons-Fill.ttf      the soft fill under the lines (Phosphor's duotone layer)

and writes src/ui/icons_gen.odin: one `ICON_<NAME> :: rune(...)` per line, in manifest
order from U+E000, and each icon's group. Phosphor draws filled outlines in a 256 grid;
Tabler and Lucide draw 2 px strokes in a 24 grid, which are outlined here at Phosphor's
stroke widths (1.5 and 2.25 in 24) so every icon reads at one weight.

Our own drawings (assets/icons/svg/own/) follow Phosphor's duotone files: strokes on its
256 grid, solid dots as `fill="currentColor" stroke="none"`, and the soft layer as shapes
with `opacity="0.2"`; each element closes itself (no groups), and the strokes are drawn at
Phosphor's widths, 16 and 24.

The drawings used are kept in assets/icons/svg/<set>/ (ph, ph-bold, ph-duotone, tb, lu, own).
A new drawing comes in with --vendor DIR, DIR holding the unpacked npm packages
(`npm pack @phosphor-icons/core@2.1.1 @tabler/icons@3.19.0 lucide-static@0.460.0`, then
`tar xzf` each into DIR/<package name>/).

    python scripts/icons_build.py [--vendor DIR]   build (needs fontTools, picosvg, skia-pathops)
    python scripts/icons_build.py --check          the fonts and names match the manifest and
                                                   drawings (no third-party modules needed)
"""

import argparse
import hashlib
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "assets" / "icons"
MANIFEST = ICONS / "manifest.txt"
SVG = ICONS / "svg"
FONTS = ROOT / "assets" / "fonts"
GEN = ROOT / "src" / "ui" / "icons_gen.odin"
OUT_FONTS = {"regular": "Icons-Regular.ttf", "bold": "Icons-Bold.ttf", "fill": "Icons-Fill.ttf"}

GROUPS = ["app", "sculpt", "mask", "paint", "model", "view", "render", "file"]
FIRST = 0xE000
UPM = 1024
# Phosphor's stroke is 16 (regular) and 24 (bold) in its 256 grid: 1.5 and 2.25 in a 24 grid.
STROKE = {"regular": 1.5, "bold": 2.25}
# Our own drawings are strokes on Phosphor's 256 grid, so they take its widths as they are.
OWN_STROKE = {"regular": 16, "bold": 24}

# Where each set's drawing of `name` is, inside the vendored folder and inside --vendor's.
PACKAGES = {
    "ph": ("_phosphor-icons_core_2.1.1/package/assets/regular/{}.svg", "ph"),
    "ph-bold": ("_phosphor-icons_core_2.1.1/package/assets/bold/{}-bold.svg", "ph-bold"),
    "ph-duotone": ("_phosphor-icons_core_2.1.1/package/assets/duotone/{}-duotone.svg", "ph-duotone"),
    "tb": ("_tabler_icons_3.19.0/package/icons/outline/{}.svg", "tb"),
    "lu": ("lucide-static_0.460.0/package/icons/{}.svg", "lu"),
}


def fail(msg):
    print(f"icons_build: {msg}", file=sys.stderr)
    sys.exit(1)


def read_manifest():
    entries, names, sources = [], set(), {}
    for n, line in enumerate(MANIFEST.read_text().splitlines(), 1):
        words = line.split("#", 1)[0].split()
        if not words:
            continue
        if len(words) != 3 or ":" not in words[2]:
            fail(f"manifest.txt:{n}: want `NAME group pack:name`")
        name, group, source = words
        pack, drawing = source.split(":", 1)
        if not re.fullmatch(r"ICON_[A-Z0-9_]+", name):
            fail(f"manifest.txt:{n}: {name} is not an ICON_ name")
        if group not in GROUPS:
            fail(f"manifest.txt:{n}: group {group} is not one of {', '.join(GROUPS)}")
        if pack not in ("ph", "tb", "lu", "own"):
            fail(f"manifest.txt:{n}: pack {pack} is not ph, tb, lu or own")
        if name in names:
            fail(f"manifest.txt:{n}: {name} is named twice")
        if name in ("ICON_FIRST", "ICON_COUNT", "ICON_GROUP_TABLE"):
            fail(f"manifest.txt:{n}: {name} is the generated file's own name")
        if source in sources:
            fail(f"manifest.txt:{n}: {name} draws {source}, as {sources[source]} does: one drawing, one meaning")
        names.add(name)
        sources[source] = name
        entries.append((name, group, pack, drawing))
    return entries


def drawing_sets(pack):
    return ["ph", "ph-bold", "ph-duotone"] if pack == "ph" else [pack]


def svg_path(kind, drawing):
    return SVG / kind / f"{drawing}.svg"


def source_hash(entries):
    h = hashlib.sha256()
    h.update(Path(__file__).read_bytes())
    h.update(MANIFEST.read_bytes())
    for _, _, pack, drawing in entries:
        for kind in drawing_sets(pack):
            p = svg_path(kind, drawing)
            if not p.exists():
                fail(f"{p.relative_to(ROOT)} is missing: run with --vendor DIR")
            h.update(p.read_bytes())
    return h.hexdigest()


def fonts_hash():
    h = hashlib.sha256()
    for f in OUT_FONTS.values():
        p = FONTS / f
        if not p.exists():
            return ""
        h.update(p.read_bytes())
    return h.hexdigest()


def vendor(entries, src):
    used = {(kind, drawing) for _, _, pack, drawing in entries for kind in drawing_sets(pack)}
    for kind in PACKAGES:
        d = SVG / kind
        d.mkdir(parents=True, exist_ok=True)
        for old in d.glob("*.svg"):
            if (kind, old.stem) not in used:
                old.unlink()
    for kind, drawing in sorted(used):
        p = svg_path(kind, drawing)
        if p.exists():
            continue
        found = Path(src) / PACKAGES[kind][0].format(drawing)
        if not found.exists():
            fail(f"{found} is missing")
        shutil.copyfile(found, p)


# --- outlines -------------------------------------------------------------------------

def strip_layer(svg, keep_soft):
    """Phosphor's duotone drawing: the soft layer (opacity 0.2) or everything else."""
    body = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)
    parts = re.findall(r"<[a-z]+\b[^>]*/>", body)
    kept = [p for p in parts if ('opacity="0.2"' in p) == keep_soft]
    kept = [p.replace(' opacity="0.2"', "") for p in kept]
    head = re.match(r"(<svg[^>]*>)", svg).group(1)
    return head + "".join(kept) + "</svg>"


def outline(svg_text, stroke=None):
    """The drawing's filled area as one skia path in its own viewBox units."""
    import pathops
    from picosvg.svg import SVG as PicoSVG

    text = re.sub(r"<!--.*?-->", "", svg_text, flags=re.S)
    if stroke is not None:
        text = re.sub(r'stroke-width="[^"]*"', f'stroke-width="{stroke}"', text)
    if "<svg" in text and not re.search(r"<svg[^>]*\bxmlns=", text):
        text = text.replace("<svg", '<svg xmlns="http://www.w3.org/2000/svg"', 1)
    # Width and height in the root confuse nothing but the viewBox decides the grid.
    pico = PicoSVG.fromstring(text).topicosvg(allow_text=False)
    path = pathops.Path()
    for shape in pico.shapes():
        d = shape.as_path().d
        if not d:
            continue
        p = pathops.Path()
        from fontTools.svgLib.path import parse_path
        parse_path(d, p.getPen())
        path = pathops.op(path, p, pathops.PathOp.UNION)
    path.simplify(fix_winding=True)
    return path


def closed_subpaths(d):
    """The subpaths of path data `d` that end where they began (Tabler draws a circle as
    two arcs with no close), as path data again."""
    from fontTools.pens.recordingPen import RecordingPen
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.svgLib.path import parse_path

    rec = RecordingPen()
    parse_path(d, rec)
    out, sub = SVGPathPen(None), []

    def flush():
        if not sub:
            return
        closed = sub[-1][0] == "closePath"
        drawn = [(op, args) for op, args in sub if op not in ("closePath", "endPath")]
        start, end = drawn[0][1][0], drawn[-1][1][-1]
        if len(drawn) > 2 and (closed or (abs(start[0] - end[0]) < 0.01 and abs(start[1] - end[1]) < 0.01)):
            for op, args in drawn:
                getattr(out, op)(*args)
            out.closePath()
        sub.clear()

    for op, args in rec.value:
        if op == "moveTo":
            flush()
        sub.append((op, args))
        if op in ("closePath", "endPath"):
            flush()
    flush()
    return out.getCommands()


def closed_areas(svg_text):
    """A stroked drawing's soft layer, as Phosphor's duotone has one: the inside of each
    closed shape (circles, rectangles, polygons and closed paths), with no stroke. Open
    lines (arrows, ticks) give none, so their icons stay plain lines."""
    body = re.sub(r"<!--.*?-->", "", svg_text, flags=re.S)
    head = re.search(r"<svg[^>]*>", body).group(0)
    shapes = []
    for el in re.findall(r"<(?:path|circle|rect|ellipse|polygon)\b[^>]*/>", body):
        if 'stroke="none"' in el:
            continue  # Tabler's invisible 24 x 24 frame
        if el.startswith("<path"):
            d = re.search(r'\bd="([^"]*)"', el)
            closed = closed_subpaths(d.group(1)) if d else ""
            if not closed:
                continue
            el = el.replace(d.group(0), f'd="{closed}"')
        el = re.sub(r'\s(fill|stroke|stroke-width|stroke-linecap|stroke-linejoin)="[^"]*"', "", el)
        shapes.append(el.replace("/>", ' fill="black" stroke="none"/>'))
    if not shapes:
        return None
    head = re.sub(r'\s(fill|stroke|stroke-width|stroke-linecap|stroke-linejoin)="[^"]*"', "", head)
    return outline(head + "".join(shapes) + "</svg>")


def glyph_from_path(path, scale):
    from fontTools.pens.cu2quPen import Cu2QuPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.pens.ttGlyphPen import TTGlyphPen

    tt = TTGlyphPen(None)
    # SVG's y runs down, a font's up: flip about the em.
    pen = Cu2QuPen(TransformPen(tt, (scale, 0, 0, -scale, 0, UPM)), max_err=0.5, reverse_direction=True)
    path.draw(pen)
    return tt.glyph()


def build_font(entries, kind):
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen

    order = [".notdef"] + [f"g{i}" for i in range(len(entries))]
    glyphs, metrics, cmap = {}, {}, {}
    empty = TTGlyphPen(None).glyph()
    glyphs[".notdef"], metrics[".notdef"] = empty, (UPM, 0)
    for i, (name, _, pack, drawing) in enumerate(entries):
        g = f"g{i}"
        cmap[FIRST + i] = g
        if pack == "ph":
            if kind == "fill":
                text = strip_layer(svg_path("ph-duotone", drawing).read_text(), True)
            else:
                text = svg_path("ph" if kind == "regular" else "ph-bold", drawing).read_text()
            path, scale = outline(text), UPM / 256
        elif pack == "own":
            text = svg_path("own", drawing).read_text()
            if kind == "fill":
                path = outline(strip_layer(text, True))
            else:
                path = outline(strip_layer(text, False), OWN_STROKE[kind])
            scale = UPM / 256
        else:
            text = svg_path(pack, drawing).read_text()
            path, scale = (closed_areas(text) if kind == "fill" else outline(text, STROKE[kind])), UPM / 24
        glyphs[g] = glyph_from_path(path, scale) if path is not None else empty
        bounds = path.bounds if path is not None else (0, 0, 0, 0)
        metrics[g] = (UPM, int(round(bounds[0] * scale)))
    fb = FontBuilder(UPM, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap(cmap)
    fb.setupGlyf(glyphs)
    glyf = fb.font["glyf"]
    for g in order:
        glyf[g].recalcBounds(glyf)
        metrics[g] = (UPM, glyf[g].xMin if hasattr(glyf[g], "xMin") else 0)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=UPM, descent=0)
    family = f"Sculpt Icons {kind.title()}"
    fb.setupNameTable({"familyName": family, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=UPM, sTypoDescender=0, usWinAscent=UPM, usWinDescent=0)
    fb.setupPost()
    fb.font["head"].created = fb.font["head"].modified = 0
    fb.save(str(FONTS / OUT_FONTS[kind]))


def write_gen(entries, src_hash):
    lines = [
        "package ui",
        "",
        "// Written by scripts/icons_build.py from assets/icons/manifest.txt: edit that and run the",
        "// script. One name per meaning, each its own drawing in the icon fonts (text.odin).",
        "",
        f'ICONS_SOURCE_HASH :: "{src_hash}"',
        f'ICONS_FONTS_HASH :: "{fonts_hash()}"',
        "",
        "// What an icon works on, which colours it in the Colour icon style.",
        "Icon_Group :: enum u8 {",
    ]
    lines += [f"\t{g.title()}," for g in GROUPS]
    lines += ["}", "", f"ICON_FIRST :: rune(0x{FIRST:X})", f"ICON_COUNT :: {len(entries)}", ""]
    width = max(len(n) for n, *_ in entries)
    for i, (name, _, pack, drawing) in enumerate(entries):
        lines.append(f"{name:<{width}} :: rune(0x{FIRST + i:X}) // {pack}:{drawing}")
    lines += ["", "ICON_GROUP_TABLE := [ICON_COUNT]Icon_Group {"]
    lines += [f"\t.{g.title()}, // {n}" for n, g, *_ in entries]
    lines += ["}", ""]
    GEN.write_text("\n".join(lines))


def generated_hashes():
    if not GEN.exists():
        return "", ""
    text = GEN.read_text()
    s = re.search(r'ICONS_SOURCE_HASH :: "(\w*)"', text)
    f = re.search(r'ICONS_FONTS_HASH :: "(\w*)"', text)
    return (s.group(1) if s else ""), (f.group(1) if f else "")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--vendor", metavar="DIR")
    args = ap.parse_args()
    entries = read_manifest()
    if args.check:
        src, fonts = generated_hashes()
        if src != source_hash(entries):
            fail("src/ui/icons_gen.odin is out of date with assets/icons: run python scripts/icons_build.py")
        if fonts != fonts_hash():
            fail("assets/fonts/Icons-*.ttf differ from what icons_build.py wrote: run python scripts/icons_build.py")
        return
    if args.vendor:
        vendor(entries, args.vendor)
    src = source_hash(entries)
    for kind in OUT_FONTS:
        build_font(entries, kind)
    write_gen(entries, src)
    print(f"icons_build: {len(entries)} icons into {', '.join(OUT_FONTS.values())} and {GEN.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
