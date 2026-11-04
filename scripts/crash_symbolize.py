"""Names the frames of a Windows crash log from the linker map of the same build.

    python scripts/crash_symbolize.py [crash log] [map]

The release build carries no debug information (Odin's -debug also defines ODIN_DEBUG,
which turns on the tracking allocator), so `build.bat release` asks the linker for a map
instead: build/sculpt.map, which lists every procedure's address, the file-private ones
too, without changing a byte of the code. The crash log's lines name frames as
`sculpt.exe+0x62d12c`; this prints each with the procedure that holds it and the offset
into it. The map must come from the build that crashed: rebuilding the same commit the
same way gives the same addresses (only the header's time stamp differs).

The crash log defaults to %APPDATA%/Implicit/Sculpt/sculpt-log-crash.txt and the map to
build/sculpt.map.
"""

import bisect
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The image base the map's addresses count from; frames in the log are offsets from it.
IMAGE_BASE = 0x140000000
FRAME = re.compile(r"sculpt\.exe\+0x([0-9a-fA-F]+)")
# A map line: section:offset, the symbol's name, its address including the image base.
SYMBOL = re.compile(r"\s*[0-9a-f]{4}:[0-9a-f]{8}\s+(\S+)\s+([0-9a-f]{16})")


def read_map(path):
    """The map's symbols as a sorted list of (address, name)."""
    symbols = []
    with open(path, encoding="latin-1") as f:
        for line in f:
            m = SYMBOL.match(line)
            if m:
                symbols.append((int(m.group(2), 16), m.group(1)))
    symbols.sort()
    return symbols


def name(symbols, addresses, offset):
    """The procedure holding `offset` and how far into it, or None before the first."""
    at = IMAGE_BASE + offset
    i = bisect.bisect_right(addresses, at) - 1
    if i < 0:
        return None
    start, symbol = symbols[i]
    return f"{symbol} + 0x{at - start:x}"


def main():
    appdata = os.environ.get("APPDATA", "")
    log = sys.argv[1] if len(sys.argv) > 1 else os.path.join(appdata, "Implicit", "Sculpt", "sculpt-log-crash.txt")
    map_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "build", "sculpt.map")
    if not os.path.exists(map_path):
        sys.exit(f"crash_symbolize: no map at {map_path}; build.bat release writes one")
    symbols = read_map(map_path)
    if not symbols:
        sys.exit(f"crash_symbolize: {map_path} lists no symbols")
    addresses = [a for a, _ in symbols]
    found = False
    with open(log, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("crash:"):
                continue
            found = True
            line = line.rstrip("\n")
            names = [name(symbols, addresses, int(m.group(1), 16)) for m in FRAME.finditer(line)]
            names = [n for n in names if n]
            print(line + ("    " + "; ".join(names) if names else ""))
    if not found:
        sys.exit(f"crash_symbolize: {log} has no crash lines")


if __name__ == "__main__":
    main()
