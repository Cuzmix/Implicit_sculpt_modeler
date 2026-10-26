#!/usr/bin/env python3
"""The whole "done means" gate (AGENTS.md section 6) in one command, with one summary.

Runs, in order, stopping at the first failure:
    check      odin check of every package and the skill mirror check
    test       odin test on every tested package
    build      the debug app
    smoke      300 frames under GPU validation (no leaks, no asserts)
    touch      scripts/touch_check.py, every scenario, in parallel
    wincheck   the app and bench compiled for Windows (Linux only)
    android    the app compiled for Android arm64 (Linux only)

Each step's whole output goes to build/gate/<step>.log; the terminal gets one line a
step (PASS or FAIL, seconds, and the line that matters: test counts, scenarios, leaks)
and, on a failure, the end of that step's log. On Linux without a display, smoke and
touch run under xvfb-run when it is installed.

Usage:
    python scripts/gate.py                  # every step
    python scripts/gate.py --fast           # check and test only
    python scripts/gate.py --skip android   # leave steps out (repeatable, or comma separated)
    python scripts/gate.py --only touch     # just these (comma separated)
    python scripts/gate.py --keep-going     # run every step even after a failure
    python scripts/gate.py -- tap_ui pinch  # anything after -- goes to touch_check
"""
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"
LOGS = os.path.join(ROOT, "build", "gate")
ORDER = ["check", "test", "build", "smoke", "touch", "wincheck", "android"]
# The display the scripted scenarios need: tall enough for the Settings scenarios.
XVFB = ["xvfb-run", "-a", "-s", "-screen 0 1600x1400x24"]


def build_cmd(mode):
    if WINDOWS:
        return ["cmd", "/c", os.path.join(ROOT, "build.bat"), mode]
    return [os.path.join(ROOT, "build.sh"), mode]


def needs_display(cmd):
    """Wraps a command that opens a window in xvfb-run when Linux has no display."""
    if WINDOWS or os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        return cmd
    if shutil.which("xvfb-run"):
        return XVFB + cmd
    return cmd


def summary_test(log):
    counts = [int(n) for n in re.findall(r"Finished (\d+) tests", log)]
    return f"{sum(counts)} tests in {len(counts)} packages" if counts else ""


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
        ("test", build_cmd("test"), summary_test),
        ("build", build_cmd("debug"), lambda log: ""),
        ("smoke", needs_display(build_cmd("smoke")), summary_smoke),
        ("touch", needs_display([python, os.path.join(ROOT, "scripts", "touch_check.py")] + touch_args), summary_touch),
    ]
    if not WINDOWS:
        out += [
            ("wincheck", build_cmd("wincheck"), summary_last),
            ("android", build_cmd("androidcheck"), summary_last),
        ]
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
    skip, only, keep_going = [], [], False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--fast":
            only += ["check", "test"]
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
    env = dict(os.environ, SDL_ASSERT="abort")
    failed, ran, total = [], 0, time.monotonic()
    for name, cmd, summarise in steps(touch_args):
        if name in skip or (only and name not in only):
            continue
        ran += 1
        start = time.monotonic()
        log_path = os.path.join(LOGS, name + ".log")
        with open(log_path, "w", encoding="utf-8", errors="replace") as log_file:
            code = subprocess.run(cmd, cwd=ROOT, env=env, stdout=log_file, stderr=subprocess.STDOUT).returncode
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
