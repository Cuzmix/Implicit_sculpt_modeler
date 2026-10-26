#!/usr/bin/env python3
"""Runs some of one package's tests, by name or pattern, with the build's strict flags.

    python scripts/test_only.py sculpt deform_*                 # every test starting deform_
    python scripts/test_only.py app deform_drag_is_one_step sections_*
    python scripts/test_only.py sculpt --list 'layers_*'        # the names a pattern picks

`build.bat test` runs every test of every package (about a minute); while working on one
thing it is quicker to run the few tests it touches. Odin takes the tests to run as
`-define:ODIN_TEST_NAMES=package.name,...` with exact names, the package's own name (app's
is main) and, on Linux, the linker flags for SDL3; this builds that line from the test
procedures it finds in the package's *_test.odin files. A pattern that picks nothing is
an error, so a typo never passes as "0 tests failed". No names runs the whole package.
"""

import fnmatch
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPS = os.path.join(ROOT, "deps")
WINDOWS = os.name == "nt"
TEST_PROC = re.compile(r"@\(test\)\s*\n\s*(\w+)\s*::\s*proc")


def package_tests(directory):
    """The package's own name and its test procedures, in file and line order."""
    name, tests = None, []
    for file in sorted(os.listdir(directory)):
        if not file.endswith(".odin"):
            continue
        with open(os.path.join(directory, file), encoding="utf-8") as f:
            text = f.read()
        if name is None:
            found = re.search(r"^package\s+(\w+)", text, re.M)
            name = found.group(1) if found else None
        if file.endswith("_test.odin"):
            tests += TEST_PROC.findall(text)
    return name, tests


def main(argv):
    args = [a for a in argv if a != "--list"]
    listing = len(args) != len(argv)
    if not args:
        print(__doc__.strip())
        return 2
    package, patterns = args[0], args[1:]
    directory = os.path.join(ROOT, "src", package)
    if not os.path.isdir(directory):
        print(f"no package src/{package}")
        return 2
    name, tests = package_tests(directory)
    chosen = []
    for pattern in patterns:
        picked = [t for t in tests if fnmatch.fnmatchcase(t, pattern)]
        if not picked:
            print(f"no test in src/{package} matches {pattern!r}")
            return 2
        chosen += [t for t in picked if t not in chosen]
    if listing:
        print("\n".join(chosen or tests))
        return 0
    odin = os.path.join(DEPS, "odin", "odin.exe" if WINDOWS else "odin")
    out = os.path.join(ROOT, "build", f"test_only_{package}" + (".exe" if WINDOWS else ""))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = [odin, "test", directory, f"-out:{out}", f"-collection:deps={DEPS}", "-vet", "-strict-style", "-warnings-as-errors"]
    if WINDOWS:
        # The tests load SDL3.dll from beside the executable, as build.bat puts it.
        dll = os.path.join(DEPS, "odin", "vendor", "sdl3", "SDL3.dll")
        if os.path.exists(dll):
            shutil.copy2(dll, os.path.dirname(out))
    else:
        lib = os.path.join(DEPS, "sdl3", "lib")
        cmd.append(f"-extra-linker-flags:-L{lib} -Wl,-rpath,{lib}")
    if chosen:
        cmd.append("-define:ODIN_TEST_NAMES=" + ",".join(f"{name}.{t}" for t in chosen))
    print(f"{len(chosen) or len(tests)} test(s) in src/{package}", flush=True)
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
