#!/usr/bin/env python3
"""The whole "done means" gate (AGENTS.md section 6) in one command, with one summary.

Runs, in order, stopping at the first failure:
    check      odin check of every package and the skill mirror check
    reports    scripts/test_input_report.py: the Input diagnostics report analyzer on its samples
    test       odin test on every tested package
    build      the debug app
    smoke      300 frames under GPU validation (no leaks, no asserts)
    touch      scripts/touch_check.py, every scenario, in parallel
    iphone     the app compiled for the iPad (arm64), to an object file
    mac        the app compiled for the Mac (Apple silicon), to an object file
    wincheck   the app and bench compiled for Windows (Linux only)
    android    the app compiled for Android arm64 (Linux only)

Each step's whole output goes to build/gate/<step>.log; the terminal gets one line a
step (PASS or FAIL, seconds, and the line that matters: test counts, scenarios, leaks)
and, on a failure, the end of that step's log. On Linux without a display, smoke and
touch open their windows the way scripts/headless.py finds: SDL's offscreen driver where
SDL has no X11 (a cloud container), else under xvfb-run.

Usage:
    python scripts/gate.py                  # every step
    python scripts/gate.py --fast           # check, reports and test only
    python scripts/gate.py --skip android   # leave steps out (repeatable, or comma separated)
    python scripts/gate.py --only touch     # just these (comma separated)
    python scripts/gate.py --keep-going     # run every step even after a failure
    python scripts/gate.py -- tap_ui pinch  # anything after -- goes to touch_check
    python scripts/gate.py --changed        # only what the branch's changes reach (below)
    python scripts/gate.py --changed=BASE   # ...measured from BASE instead of origin/odin-sculpt

--changed is the gate for one PR of a series: it reads what changed since the branch left
BASE (commits and the working tree) and runs check always, the tests of the packages those
files are in and of every package importing them, the debug build and smoke when the app
or what it draws changed, the touch scenarios the change reaches (changed_scenarios), and
the other platforms' compile checks when platform code or the build scripts changed. Each
step says what it picked. The full gate still ends a series.
"""
import os
import re
import subprocess
import sys
import ast
import time

import headless

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"
LOGS = os.path.join(ROOT, "build", "gate")
# The packages build.sh test runs, in its order, and the base --changed measures from.
TEST_PACKAGES = ["geom", "poly", "camera", "sculpt", "jobs", "gizmo", "png_write", "zip", "hdri", "voxel", "ui", "luau", "usd",
                 "fbx", "quadmesh", "retopo", "app"]
BASE = "origin/odin-sculpt"
# Words in file names too common to say which scenarios a change reaches.
GENERIC = {"kit", "lens", "app", "main", "test", "tests", "new", "odin", "draw", "drawn", "state", "tool", "tools",
           "file", "files", "data", "util", "utils", "mode", "pass", "view", "make", "with", "from", "into", "each"}
# Scenarios that cover the pointer, fingers and pen paths every interface change can reach.
CORE_SCENARIOS = ["tap_ui", "pinch_zoom", "two_finger_pan", "orbit_default_is_turntable", "mouse_controls",
                  "pen_stroke_with_hand_resting", "long_press_shows_the_tooltip_and_does_not_tap"]
ORDER = ["check", "reports", "test", "build", "smoke", "touch", "iphone", "mac", "web", "wincheck", "android"]


def build_cmd(mode):
    if WINDOWS:
        return ["cmd", "/c", os.path.join(ROOT, "build.bat"), mode]
    return [os.path.join(ROOT, "build.sh"), mode]


def needs_display(cmd):
    """Wraps a command that opens a window so it can open one here (headless.py): under
    xvfb-run on Linux with no display and an X11 SDL; as it is otherwise, its environment
    giving the offscreen driver where that is the way."""
    return headless.wrap(cmd)


def summary_test(log):
    counts = [int(n) for n in re.findall(r"Finished (\d+) tests", log)]
    return f"{sum(counts)} tests in {len(counts)} packages" if counts else ""


def summary_unittest(log):
    m = re.findall(r"Ran (\d+) tests?", log)
    return f"{m[-1]} tests" if m else ""


def summary_smoke(log):
    return "no leaks" if "no leaks" in log else ""


def summary_touch(log):
    m = re.findall(r"(\d+ of \d+ scenarios pass[^\n]*)", log)
    return m[-1] if m else ""


def summary_last(log):
    lines = [line for line in log.strip().splitlines() if line.strip()]
    return lines[-1].strip() if lines else ""


def steps(touch_args):
    """Each step: its name, its command, and what to print from its log."""
    python = sys.executable or "python3"
    out = [
        ("check", build_cmd("check"), summary_last),
        ("reports", [python, os.path.join(ROOT, "scripts", "test_input_report.py")], summary_unittest),
        ("test", build_cmd("test"), summary_test),
        ("build", build_cmd("debug"), lambda log: ""),
        ("smoke", needs_display(build_cmd("smoke")), summary_smoke),
        ("touch", needs_display([python, os.path.join(ROOT, "scripts", "touch_check.py")] + touch_args), summary_touch),
        ("iphone", build_cmd("iphonecheck"), summary_last),
        ("mac", build_cmd("maccheck"), summary_last),
        # The web version built and sculpted in headless Chromium (skipped without Node and Playwright).
        ("web", [python, os.path.join(ROOT, "scripts", "web_build.py"), "--test"], summary_last),
    ]
    if not WINDOWS:
        out += [
            ("wincheck", build_cmd("wincheck"), summary_last),
            ("android", build_cmd("androidcheck"), summary_last),
        ]
    return out


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout


def changed_files(base):
    """Files changed since the branch left `base`: its commits, the working tree and new files."""
    since = git("merge-base", "HEAD", base).strip() or base
    files = set(git("diff", "--name-only", since).split())
    files |= set(git("ls-files", "--others", "--exclude-standard").split())
    return sorted(files), since


def package_of(path):
    parts = path.split("/")
    return parts[1] if len(parts) > 2 and parts[0] == "src" and path.endswith(".odin") else None


def reached_packages(files):
    """The packages holding a changed file and every package importing one of them."""
    imports = {}
    for pkg in os.listdir(os.path.join(ROOT, "src")):
        folder = os.path.join(ROOT, "src", pkg)
        if not os.path.isdir(folder):
            continue
        found = set()
        for name in os.listdir(folder):
            if name.endswith(".odin"):
                text = open(os.path.join(folder, name), encoding="utf-8", errors="replace").read()
                found |= set(re.findall(r'^import(?:\s+\w+)?\s+"\.\./(\w+)"', text, re.M))
        imports[pkg] = found
    reached = {p for p in (package_of(f) for f in files) if p}
    grew = True
    while grew:
        grew = False
        for pkg, deps in imports.items():
            if pkg not in reached and deps & reached:
                reached.add(pkg)
                grew = True
    return reached


def changed_scenarios(files, since):
    """Touch scenarios a change reaches: those whose own lines in touch_check.py changed,
    those named with a word of a changed interface, input or render file's name, and the
    core pointer scenarios whenever the app or the interface kit changed."""
    path = os.path.join(ROOT, "scripts", "touch_check.py")
    tree = ast.parse(open(path, encoding="utf-8").read())
    spans = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and any(getattr(d, "id", "") == "scenario" for d in node.decorator_list):
            spans[node.name] = (node.lineno, node.end_lineno)
    picked = []

    def add(name):
        if name in spans and name not in picked:
            picked.append(name)

    if "scripts/touch_check.py" in files:
        lines = set()
        for m in re.finditer(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", git("diff", "-U0", since, "--", "scripts/touch_check.py"), re.M):
            start, count = int(m.group(1)), int(m.group(2) or 1)
            lines |= set(range(start, start + max(count, 1)))
        for name, (a, b) in spans.items():
            if any(a <= n <= b for n in lines):
                add(name)
    words = set()
    for f in files:
        if package_of(f) in ("app", "ui", "render"):
            stem = os.path.splitext(os.path.basename(f))[0]
            words |= {w for w in stem.split("_") if len(w) >= 4 and w not in GENERIC}
    for name in spans:
        if any(w in name.split("_") for w in words):
            add(name)
    if any(package_of(f) in ("app", "ui") for f in files):
        for name in CORE_SCENARIOS:
            add(name)
    return picked


def changed_steps(base, touch_args):
    """The steps --changed runs, each with what it picked, in the gate's order."""
    files, since = changed_files(base)
    python = sys.executable or "python3"
    print(f"changed since {since[:10]} ({base}): {len(files)} files")
    reached = reached_packages(files)
    pkgs = [p for p in TEST_PACKAGES if p in reached]
    drawn = reached & {"app", "render", "ui", "sculpt"}
    platform = reached & {"app", "render", "ui", "fbx", "luau", "quadmesh"} or any(
        f in ("build.sh", "build.bat") or f.split("/")[0] in ("android", "ios", "mac") for f in files)
    scenarios = touch_args or changed_scenarios(files, since)
    out = [("check", build_cmd("check"), summary_last, "always")]
    if any(f.startswith("scripts/") and "input_report" in f for f in files):
        out.append(("reports", [python, os.path.join(ROOT, "scripts", "test_input_report.py")], summary_unittest, "report analyzer changed"))
    if pkgs:
        cmds = [[python, os.path.join(ROOT, "scripts", "test_only.py"), p] for p in pkgs]
        out.append(("test", cmds, summary_test, " ".join(pkgs)))
    if drawn or scenarios:
        out.append(("build", build_cmd("debug"), lambda log: "", "app reached" if drawn else "for the scenarios"))
    if drawn:
        out.append(("smoke", needs_display(build_cmd("smoke")), summary_smoke, " ".join(sorted(drawn))))
    if scenarios:
        out.append(("touch", needs_display([python, os.path.join(ROOT, "scripts", "touch_check.py")] + scenarios),
                    summary_touch, f"{len(scenarios)} scenarios"))
    if platform:
        out.append(("iphone", build_cmd("iphonecheck"), summary_last, "platform code"))
        out.append(("mac", build_cmd("maccheck"), summary_last, "platform code"))
    if "web" in reached or any(f.split("/")[0] == "web" or f.startswith("scripts/web_") for f in files):
        out.append(("web", [python, os.path.join(ROOT, "scripts", "web_build.py"), "--test"], summary_last, "the web version"))
    if platform:
        if not WINDOWS:
            out.append(("wincheck", build_cmd("wincheck"), summary_last, "platform code"))
            out.append(("android", build_cmd("androidcheck"), summary_last, "platform code"))
    return out


def names_of(values):
    out = []
    for v in values:
        out += [n for n in v.split(",") if n]
    for n in out:
        if n not in ORDER:
            sys.exit(f"unknown step {n!r}: the steps are {', '.join(ORDER)}")
    return out


def main(argv):
    touch_args = []
    if "--" in argv:
        i = argv.index("--")
        argv, touch_args = argv[:i], argv[i + 1:]
    skip, only, keep_going, base = [], [], False, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--fast":
            only += ["check", "reports", "test"]
        elif a == "--changed" or a.startswith("--changed="):
            base = a.split("=", 1)[1] if "=" in a else BASE
        elif a == "--keep-going":
            keep_going = True
        elif a in ("--skip", "--only") and i + 1 < len(argv):
            (skip if a == "--skip" else only).append(argv[i + 1])
            i += 1
        elif a.startswith("--skip="):
            skip.append(a.split("=", 1)[1])
        elif a.startswith("--only="):
            only.append(a.split("=", 1)[1])
        else:
            print(__doc__)
            return 2
        i += 1
    skip, only = names_of(skip), names_of(only)

    os.makedirs(LOGS, exist_ok=True)
    env = headless.env(dict(os.environ, SDL_ASSERT="abort"))
    failed, ran, total = [], 0, time.monotonic()
    chosen = changed_steps(base, touch_args) if base else [(n, c, f, "") for n, c, f in steps(touch_args)]
    for name, cmd, summarise, why in chosen:
        if name in skip or (only and name not in only):
            continue
        if why:
            print(f"     {name}: {why}", flush=True)
        ran += 1
        start = time.monotonic()
        log_path = os.path.join(LOGS, name + ".log")
        # A step is one command, or several run in turn into one log (--changed's tests,
        # a package each), stopping at the first that fails.
        with open(log_path, "w", encoding="utf-8", errors="replace") as log_file:
            for one in (cmd if isinstance(cmd[0], list) else [cmd]):
                code = subprocess.run(one, cwd=ROOT, env=env, stdout=log_file, stderr=subprocess.STDOUT).returncode
                if code != 0:
                    break
        with open(log_path, encoding="utf-8", errors="replace") as log_file:
            log = log_file.read()
        seconds = time.monotonic() - start
        note = summarise(log)
        print(f"{'PASS' if code == 0 else 'FAIL'} {name:9s} {seconds:6.1f}s  {note}", flush=True)
        if code != 0:
            failed.append(name)
            tail = log.strip().splitlines()[-25:]
            print(f"     exit code {code}; the end of {os.path.relpath(log_path, ROOT)}:")
            for line in tail:
                print(f"     | {line}")
            if not keep_going:
                break
    elapsed = time.monotonic() - total
    if failed:
        print(f"gate: FAILED at {', '.join(failed)} ({elapsed:.0f}s); logs in build/gate/")
        return 1
    print(f"gate: {ran} steps pass ({elapsed:.0f}s); logs in build/gate/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
