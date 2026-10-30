#!/usr/bin/env python3
"""Builds the iPad app on GitHub and downloads it, for AltStore to install.

    python scripts/ipad_build.py              # build the current branch on GitHub, wait, download
    python scripts/ipad_build.py --latest     # download the newest successful build of the branch
    python scripts/ipad_build.py --branch odin-sculpt --latest
    python scripts/ipad_build.py --no-open    # do not open the folder afterwards
    python scripts/ipad_build.py --testflight # a store build, signed and sent to TestFlight

The iPad build needs a Mac, so it runs on GitHub's macOS runner (.github/workflows/ipad.yml,
./build.sh ios). This starts that workflow for a branch with the GitHub CLI (gh, signed in),
waits for the run and saves its IPA as build/ios/Sculpt.ipa. GitHub builds what it has, so the
branch must be pushed, and this script never pushes: it stops when the branch on GitHub is not
the commit checked out here. Installing stays a person's job, since AltServer has no command
line: the steps are printed at the end. Exit codes: 0 the IPA is saved; 1 a step failed.
"""

import argparse
import calendar
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = "ipad.yml"
ARTIFACT = "Sculpt-ipa"
OUT = os.path.join(ROOT, "build", "ios", "Sculpt.ipa")


def run(args, check=True):
    """Runs a command in the repository and returns its stdout; stops the script when it fails."""
    done = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if check and done.returncode != 0:
        sys.exit(f"ipad_build: {' '.join(args)} failed:\n{done.stdout}{done.stderr}".rstrip())
    return done.stdout.strip()


def current_branch():
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    if branch == "HEAD":
        sys.exit("ipad_build: no branch is checked out; pass --branch")
    return branch


def check_pushed(branch):
    """GitHub builds the branch as it is there, so it must be this commit."""
    if not run(["git", "ls-remote", "--heads", "origin", branch]):
        sys.exit(f"ipad_build: {branch} is not on GitHub; push it first (this script never pushes)")
    run(["git", "fetch", "-q", "origin", branch])
    local, remote = run(["git", "rev-parse", "HEAD"]), run(["git", "rev-parse", f"origin/{branch}"])
    if local != remote:
        sys.exit(f"ipad_build: origin/{branch} is {remote[:7]}, but {local[:7]} is checked out here; "
                 f"push {branch} first (this script never pushes)")
    if run(["git", "status", "--porcelain", "--untracked-files=no"]):
        print("ipad_build: note: uncommitted changes here are not in the build")


def start_run(branch, testflight=False):
    """Starts the workflow and returns its run's id."""
    started = time.time()
    # Only a store build names its input: the workflow's default is the plain build, and
    # GitHub answered HTTP 500 when dispatches named testflight=false.
    inputs = ["-f", "testflight=true"] if testflight else []
    out = run(["gh", "workflow", "run", WORKFLOW, "--ref", branch, *inputs])
    match = re.search(r"/actions/runs/(\d+)", out)
    if match:
        return match.group(1)
    # Older gh prints no URL: the newest manual run of the branch made since now is ours.
    for _ in range(20):
        time.sleep(3)
        rows = run(["gh", "run", "list", "--workflow", WORKFLOW, "--branch", branch, "--event", "workflow_dispatch",
                    "--limit", "1", "--json", "databaseId,createdAt", "--jq", ".[] | \"\\(.databaseId) \\(.createdAt)\""])
        if rows:
            run_id, created = rows.split()
            if calendar.timegm(time.strptime(created, "%Y-%m-%dT%H:%M:%SZ")) >= started - 60:
                return run_id
    sys.exit("ipad_build: the workflow started, but its run did not show up; see the Actions tab")


def latest_run(branch):
    run_id = run(["gh", "run", "list", "--workflow", WORKFLOW, "--branch", branch, "--status", "success",
                  "--limit", "1", "--json", "databaseId", "--jq", ".[].databaseId"])
    if not run_id:
        sys.exit(f"ipad_build: no successful iPad build of {branch} on GitHub yet; run this without --latest")
    return run_id


def download(run_id):
    """Saves the run's IPA as build/ios/Sculpt.ipa, replacing any older one."""
    with tempfile.TemporaryDirectory() as scratch:
        run(["gh", "run", "download", run_id, "--name", ARTIFACT, "--dir", scratch])
        ipa = os.path.join(scratch, "Sculpt.ipa")
        if not os.path.isfile(ipa):
            sys.exit(f"ipad_build: run {run_id}'s {ARTIFACT} artifact holds no Sculpt.ipa")
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        shutil.copyfile(ipa, OUT)


def show(path):
    """Opens the folder with the file selected, where the platform has a way to."""
    if os.name == "nt":
        subprocess.run(["explorer", "/select,", path])
    elif sys.platform == "darwin":
        subprocess.run(["open", "-R", path])
    elif shutil.which("xdg-open"):
        subprocess.run(["xdg-open", os.path.dirname(path)])


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--branch", help="the branch to build or download (default: the one checked out)")
    p.add_argument("--latest", action="store_true", help="download the newest successful build instead of starting one")
    p.add_argument("--no-open", action="store_true", help="do not open the folder afterwards")
    p.add_argument("--testflight", action="store_true",
                   help="sign a store build and send it to TestFlight (the repository's signing secrets, README \"iPad\")")
    args = p.parse_args(argv)
    if not shutil.which("gh"):
        sys.exit("ipad_build: the GitHub CLI (gh) is not on PATH: https://cli.github.com, then gh auth login")
    run(["gh", "auth", "status"])
    branch = args.branch or current_branch()
    if args.latest:
        run_id = latest_run(branch)
        print(f"ipad_build: newest successful build of {branch}: run {run_id}")
    else:
        if branch == current_branch():
            check_pushed(branch)
        run_id = start_run(branch, args.testflight)
        print(f"ipad_build: building {branch} on GitHub, run {run_id}; this takes a few minutes")
        watch = subprocess.run(["gh", "run", "watch", run_id, "--exit-status", "--interval", "20"], cwd=ROOT)
        if watch.returncode != 0:
            sys.exit(f"ipad_build: run {run_id} failed; its log: gh run view {run_id} --log-failed")
        if args.testflight:
            # A store build goes to App Store Connect, not AltStore: the IPA is not fetched.
            print(f"ipad_build: run {run_id} sent its build to App Store Connect (the build number is the run's number);")
            print("it shows in TestFlight once Apple has processed it, usually within half an hour.")
            return 0
    download(run_id)
    print(f"ipad_build: saved {os.path.relpath(OUT, ROOT)} from run {run_id}")
    print("To install it (README \"iPad\"): with AltServer running on this PC and the iPad on the same Wi-Fi or")
    print("plugged in, hold Shift and click AltServer's tray icon, then Sideload .ipa, the iPad, and Sculpt.ipa;")
    print("or copy it to the iPad and open it from AltStore > My Apps > +.")
    if not args.no_open:
        show(OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
