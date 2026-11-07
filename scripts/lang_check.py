"""Checks the interface's translations in assets/lang (README "Languages").

Each file must parse as src/ui/language.odin reads it: an `@language` line first, then
English lines each followed by a `= ` translation, no English line twice, and the same
format verbs (%s, %d, %.1f) on both sides. The script also lists, per language, the
entries whose English is not a string literal anywhere in src (stale, or put together
at run time, as "%s brush" is), and with --missing, the lines a run of the app showed
that a language lacks (the app's --language-missing file), so a translator sees what
is left.

    python scripts/lang_check.py                 # check every file, list stale entries
    python scripts/lang_check.py --missing m.txt # also count what m.txt says is missing
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANG = ROOT / "assets" / "lang"
VERB = re.compile(r"%(?!%)[^a-zA-Z%]*[a-zA-Z]")


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s) and s[i + 1] in "n\\":
            out.append("\n" if s[i + 1] == "n" else "\\")
            i += 2
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def verbs(s):
    return VERB.findall(s.replace("%%", ""))


def parse(path):
    """The file's name and entries, or raises ValueError naming the line at fault."""
    lines = path.read_text(encoding="utf-8-sig").split("\n")
    if not lines or not lines[0].startswith("@language "):
        raise ValueError(f"{path.name}:1: the first line must be '@language <name>'")
    name, entries, key, key_line = lines[0][len("@language "):].strip(), {}, None, 0
    for n, raw in enumerate(lines[1:], start=2):
        line = raw.rstrip("\r")
        if not line.strip() or line.startswith("#"):
            continue
        if line.startswith("= "):
            value = unescape(line[2:])
            if key is None:
                raise ValueError(f"{path.name}:{n}: a translation with no English line before it")
            if key in entries:
                raise ValueError(f"{path.name}:{key_line}: '{key}' is given twice")
            if verbs(key) != verbs(value):
                raise ValueError(f"{path.name}:{n}: the format verbs differ from the English's")
            entries[key], key = value, None
        else:
            if key is not None:
                raise ValueError(f"{path.name}:{key_line}: '{key}' has no translation under it")
            key, key_line = unescape(line), n
    if key is not None:
        raise ValueError(f"{path.name}:{key_line}: '{key}' has no translation under it")
    return name, entries


def literals():
    """Every string literal in the app's and the kit's sources, tests left out."""
    found = set()
    for folder in ("app", "ui"):
        for f in (ROOT / "src" / folder).glob("*.odin"):
            if f.name.endswith("_test.odin"):
                continue
            text = f.read_text(encoding="utf-8")
            for m in re.finditer(r'"((?:[^"\\\n]|\\.)*)"', text):
                found.add(re.sub(r"\\(.)", lambda e: {"n": "\n", "t": "\t"}.get(e.group(1), e.group(1)), m.group(1)))
    return found


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--missing", help="a --language-missing file from a run of the app")
    p.add_argument("--quiet", action="store_true", help="only faults, no lists")
    args = p.parse_args()
    ok = True
    known = literals()
    for path in sorted(LANG.glob("*.txt")):
        try:
            name, entries = parse(path)
        except ValueError as e:
            print(f"lang_check: {e}")
            ok = False
            continue
        stale = sorted(k for k in entries if k not in known)
        print(f"lang_check: {path.stem} ({name}): {len(entries)} entries, {len(stale)} not a literal in src")
        if not args.quiet:
            for k in stale:
                print(f"    {k!r}")
        if args.missing:
            wanted = [l for l in Path(args.missing).read_text(encoding="utf-8").split("\n")[1:] if l and not l.startswith("= ")]
            left = [unescape(w) for w in wanted if unescape(w) not in entries]
            print(f"    {len(left)} of the {len(wanted)} lines the run showed have no translation")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
