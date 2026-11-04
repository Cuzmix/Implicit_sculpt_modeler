#!/usr/bin/env python3
"""The interface's measurable qualities, counted from the sources and the theme, and held
against a baseline so they only get better (the computed half of the sm-ui-review skill;
the other half is reviewers scoring screenshots).

    python scripts/ui_audit.py                 # report, exit 1 when a count got worse
    python scripts/ui_audit.py --update        # write today's counts as the baseline
    python scripts/ui_audit.py --json          # the counts as JSON, for a PR's table
    python scripts/ui_audit.py --quiet         # one line unless something got worse (check runs this)

What is counted (each a number; lower is better):
  contrast_fails     token pairs under their floor in the literal themes (theme.odin):
                     text 7:1, secondary 4.5:1 and tertiary 4.5:1 on a panel, the accent's
                     text 4.5:1 on it, a well 1.3:1 and a hairline 1.2:1 against a panel
  popover_widths     distinct widths given to popovers, a number or a name (the ui
                     package's few popover widths are the aim)
  literal_spacing    paddings and gaps written as a number other than 0 in src/app
  type_arithmetic    type sizes scaled by hand (`text_size * 1.4`) instead of a ramp step
  color_literals     colours written as bytes in src/app outside the theme files
  shared_icons       icons that mean more than one thing: a glyph shown for brushes or
                     commands with different first words ("Cage smooth 1" and "... 2" are
                     one meaning; "Extrude" and "Inset" on one glyph are two)

The baseline is scripts/ui_audit_baseline.json. A count above it fails; a count below it
says so, and --update records the gain so it cannot slip back. Standard library only.
"""

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "src" / "app"
UI = ROOT / "src" / "ui"
BASELINE = ROOT / "scripts" / "ui_audit_baseline.json"
THEME_FILES = {"themes.odin"}

# The floors for token pairs: (foreground, background, floor). The background of panels is
# `surface` laid over a mid-grey clay, since panels are translucent over the model.
PAIRS = [
    ("text", "surface", 7.0),
    ("text_secondary", "surface", 4.5),
    ("text_tertiary", "surface", 4.5),
    ("on_accent", "accent", 4.5),
    ("fill", "surface", 1.3),
    ("border", "surface", 1.2),
]
CLAY = (0x80, 0x80, 0x80)


def sources(folder):
    return [p for p in sorted(folder.glob("*.odin")) if not p.name.endswith("_test.odin")]


def strip_comments(text):
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))


# --- contrast --------------------------------------------------------------------------


def luminance(c):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])


def over(fg, bg):
    a = fg[3] / 255 if len(fg) > 3 else 1
    return tuple(fg[i] * a + bg[i] * (1 - a) for i in range(3))


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def themes():
    text = (UI / "theme.odin").read_text()
    out = {}
    for m in re.finditer(r"^(THEME_\w+) :: Theme \{(.*?)^\}", text, flags=re.S | re.M):
        tokens = {}
        for t in re.finditer(r"(\w+)\s*=\s*\{0x(\w\w),\s*0x(\w\w),\s*0x(\w\w),\s*0x(\w\w)\}", m.group(2)):
            tokens[t.group(1)] = tuple(int(t.group(i), 16) for i in range(2, 6))
        out[m.group(1)] = tokens
    return out


def contrast():
    fails, rows = 0, []
    for name, t in themes().items():
        panel = over(t["surface"], CLAY)
        for fg, bg, floor in PAIRS:
            if fg not in t or bg not in t:
                continue
            back = panel if bg == "surface" else over(t[bg], panel)
            r = ratio(over(t[fg], back), back)
            ok = r >= floor
            fails += not ok
            rows.append((name, f"{fg}/{bg}", r, floor, ok))
    return fails, rows


# --- the sources -----------------------------------------------------------------------


def scan():
    widths, spacing, arithmetic, colors = set(), [], [], []
    for path in sources(APP):
        text = strip_comments(path.read_text())
        for m in re.finditer(r"popover_begin\([^\n]*?width\s*=\s*([^,}\n]+)", text):
            widths.add(m.group(1).strip())
        for m in re.finditer(r"\b(padding|gap)\s*=\s*(\d+(?:\.\d+)?)\b", text):
            if float(m.group(2)) != 0:
                spacing.append(f"{path.name}:{text[:m.start()].count(chr(10)) + 1} {m.group(0)}")
        for m in re.finditer(r"\b(caption|small|text|title|heading)_size\s*[*+\-]\s*\d", text):
            arithmetic.append(f"{path.name}:{text[:m.start()].count(chr(10)) + 1}")
        if path.name not in THEME_FILES:
            for m in re.finditer(r"\{0x[0-9a-fA-F]{2},\s*0x", text):
                colors.append(f"{path.name}:{text[:m.start()].count(chr(10)) + 1}")
    return sorted(widths), spacing, arithmetic, colors


def icon_constants():
    """Every ICON_ name to its code point, following aliases (ICON_X :: ui.ICON_Y)."""
    raw = {}
    for path in sources(APP) + sources(UI):
        for m in re.finditer(r"^(ICON_\w+)\s*::\s*(?:rune\((0x[0-9a-fA-F]+)\)|(?:ui\.)?(ICON_\w+))", path.read_text(), flags=re.M):
            raw[m.group(1)] = int(m.group(2), 16) if m.group(2) else m.group(3)
    def resolve(name, depth=0):
        v = raw.get(name)
        return v if isinstance(v, int) or v is None or depth > 8 else resolve(v, depth + 1)
    return {k: resolve(k) for k in raw}


def shared_icons():
    icons = icon_constants()
    meanings = defaultdict(set)
    brushes = (APP / "brushes.odin").read_text()
    for m in re.finditer(r"^\s*\.\w+\s*=\s*\{\"([^\"]+)\",\s*\"[^\"]*\",\s*(0x[0-9a-fA-F]+)", brushes, flags=re.M):
        meanings[int(m.group(2), 16)].add(m.group(1))
    commands = strip_comments((APP / "commands.odin").read_text())
    start = commands.find("COMMANDS := [Command_Id]Command {")
    for row in re.split(r"\n\t\.\w+\s*=\s*\{", commands[start:]):
        label = re.search(r"label\s*=\s*\"([^\"]+)\"", row)
        icon = re.search(r"\bicon\s*=\s*(?:ui\.)?(ICON_\w+)", row)
        if label and icon and icons.get(icon.group(1)):
            meanings[icons[icon.group(1)]].add(label.group(1))
    shared = {}
    for code, labels in meanings.items():
        words = {re.split(r"[ .,]", l.lower())[0] for l in labels}
        if len(words) > 1:
            shared[code] = sorted(labels)
    return shared


# --- report ----------------------------------------------------------------------------


def measure():
    fails, rows = contrast()
    widths, spacing, arithmetic, colors = scan()
    shared = shared_icons()
    counts = {
        "contrast_fails": fails,
        "popover_widths": len(widths),
        "literal_spacing": len(spacing),
        "type_arithmetic": len(arithmetic),
        "color_literals": len(colors),
        "shared_icons": len(shared),
    }
    detail = {"contrast": rows, "widths": widths, "spacing": spacing, "arithmetic": arithmetic,
              "colors": colors, "shared": shared}
    return counts, detail


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    counts, detail = measure()
    if "--json" in argv:
        print(json.dumps(counts, indent=1))
        return 0
    verbose = "-v" in argv or "--verbose" in argv
    base = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    worse = [k for k, v in counts.items() if k in base and v > base[k]]
    if "--quiet" in argv and not worse:
        print(f"ui_audit: nothing worse than the baseline ({', '.join(f'{k} {v}' for k, v in counts.items())})")
        return 0
    print("contrast (literal themes; the seeded ones are checked by the ui package's tests):")
    for name, pair, r, floor, ok in detail["contrast"]:
        if verbose or not ok:
            print(f"  {'ok  ' if ok else 'FAIL'} {name:14} {pair:24} {r:5.2f}:1 (floor {floor}:1)")
    print(f"popover widths: {', '.join(detail['widths'])}")
    if verbose:
        for line in detail["spacing"]:
            print(f"  spacing {line}")
        for line in detail["arithmetic"]:
            print(f"  type {line}")
    print("icons with more than one meaning:")
    for code, labels in sorted(detail["shared"].items(), key=lambda kv: -len(kv[1]))[: (None if verbose else 8)]:
        shown = ", ".join(labels[:6]) + (f" and {len(labels) - 6} more" if len(labels) > 6 else "")
        print(f"  U+{code:04X}: {shown}")
    print("\ncount              now  baseline")
    for k, v in counts.items():
        b = base.get(k)
        mark = "" if b is None else (" WORSE" if v > b else (" better" if v < b else ""))
        print(f"{k:18} {v:4}  {'' if b is None else b:>8}{mark}")
    if "--update" in argv:
        BASELINE.write_text(json.dumps(counts, indent=1) + "\n")
        print(f"baseline written to {BASELINE.relative_to(ROOT)}")
        return 0
    if worse:
        print(f"FAIL: {', '.join(worse)} got worse than the baseline")
        return 1
    print("ok: nothing got worse than the baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
