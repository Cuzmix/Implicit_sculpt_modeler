#!/usr/bin/env python3
"""One worktree per task, so several Claude sessions can work on the repo at once.

    python scripts/task.py new gizmo-snap        # ../sculpt-gizmo-snap on branch claude/gizmo-snap
    python scripts/task.py new uv-pack --base claude/uv-engine   # branched from another branch
    python scripts/task.py list                  # every task: branch, commits ahead and behind, changes, PR
    python scripts/task.py sync                  # inside a task: merge the latest odin-sculpt into it
    python scripts/task.py done gizmo-snap       # once merged: remove the worktree and its branches

Each task is a git worktree beside the main checkout with its own branch and its own build/,
so builds and edits never collide, and a session opened in it works on that task alone. The
pinned toolchain in deps/ is large and set up once, so a task links to the main checkout's
deps rather than copying it; .gitignore ignores /deps as a folder or a link, and `new` checks
that before it returns, since a committed link once replaced the real deps on checkout.

`done` refuses a task whose branch is not in origin/odin-sculpt yet, or whose worktree has
uncommitted changes, unless --force says to drop them. The main checkout is never a task:
it stays on odin-sculpt for pulling and for scripts/setup_deps.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"
MAIN_BRANCH = "odin-sculpt"
BRANCH_PREFIX = "claude/"
DIR_PREFIX = "sculpt-"
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def git(*args, cwd=None, check=True):
	"""Runs git and returns its output, stripped; a failure stops the script with git's own words."""
	r = subprocess.run(["git", *args], cwd=cwd or ROOT, capture_output=True, text=True)
	if check and r.returncode != 0:
		sys.exit(f"task: git {' '.join(args)} failed:\n{r.stderr.strip()}")
	return r.stdout.strip()


def main_checkout():
	"""The main checkout's folder, wherever this runs from: the parent of the shared .git."""
	common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
	return os.path.dirname(common)


def worktrees():
	"""Every worktree as (path, branch or None), the main checkout first."""
	out, path, branch = [], None, None
	for line in git("worktree", "list", "--porcelain").splitlines() + [""]:
		if line.startswith("worktree "):
			path = line[len("worktree "):]
		elif line.startswith("branch "):
			branch = line[len("branch refs/heads/"):]
		elif line == "" and path:
			out.append((path, branch))
			path, branch = None, None
	return out


def task_path(name):
	return os.path.join(os.path.dirname(main_checkout()), DIR_PREFIX + name)


def check_name(name):
	if not NAME_RE.match(name):
		sys.exit(f"task: '{name}' is not a task name (lowercase letters, digits and single hyphens)")


def link_deps(main, path):
	"""Links the task's deps to the main checkout's; Windows without developer mode cannot make
	symbolic links, so a directory junction stands in there."""
	target, link = os.path.join(main, "deps"), os.path.join(path, "deps")
	if not os.path.isdir(target):
		print("task: the main checkout has no deps/ yet; run scripts/setup_deps there, then link it", file=sys.stderr)
		return
	try:
		os.symlink(target, link, target_is_directory=True)
	except OSError:
		if not WINDOWS:
			raise
		subprocess.run(["cmd", "/c", "mklink", "/J", link, target], check=True, capture_output=True)
	if git("check-ignore", "deps", cwd=path, check=False) != "deps":
		sys.exit(f"task: {link} is not ignored by git; fix .gitignore before committing anything there")


def cmd_new(a):
	check_name(a.name)
	main, path, branch = main_checkout(), task_path(a.name), BRANCH_PREFIX + a.name
	if os.path.exists(path):
		sys.exit(f"task: {path} already exists")
	if git("branch", "--list", branch):
		sys.exit(f"task: branch {branch} already exists; pick another name or `task.py done {a.name}` first")
	git("fetch", "--quiet", "origin")
	base = a.base if a.base.startswith("origin/") else "origin/" + a.base
	git("worktree", "add", "--quiet", "-b", branch, path, base)
	# The branch tracks its own name on origin, so the first push needs no -u.
	git("config", f"branch.{branch}.remote", "origin", cwd=path)
	git("config", f"branch.{branch}.merge", f"refs/heads/{branch}", cwd=path)
	link_deps(main, path)
	print(f"task {a.name}: {path} on {branch}, from {base} at {git('rev-parse', '--short', 'HEAD', cwd=path)}")
	print(f"open a session there:  cd {path} && claude")


def ahead_behind(path, branch):
	"""Commits the task has that odin-sculpt lacks, and the reverse."""
	counts = git("rev-list", "--left-right", "--count", f"{branch}...origin/{MAIN_BRANCH}", cwd=path, check=False)
	return tuple(int(x) for x in counts.split()) if counts else (0, 0)


def pr_states():
	"""Branch name to its newest PR's number and state, from gh when it is installed and signed in."""
	if not shutil.which("gh"):
		return {}
	r = subprocess.run(["gh", "pr", "list", "--state", "all", "--limit", "200", "--json", "number,state,headRefName",
		"--jq", '.[] | "\\(.headRefName) #\\(.number) \\(.state)"'], cwd=ROOT, capture_output=True, text=True)
	states = {}
	for line in r.stdout.splitlines():
		head, number, state = line.split(" ")
		states.setdefault(head, f"{number} {state.lower()}")
	return states


def cmd_list(a):
	git("fetch", "--quiet", "origin")
	main, prs = main_checkout(), pr_states()
	rows = []
	for path, branch in worktrees():
		if os.path.normpath(path) == os.path.normpath(main):
			continue
		changes = len(git("status", "--porcelain", cwd=path, check=False).splitlines())
		ahead, behind = ahead_behind(path, branch) if branch else (0, 0)
		rows.append((os.path.basename(path), branch or "(detached)", f"+{ahead} -{behind}", f"{changes} changed", prs.get(branch, "no PR")))
	if not rows:
		print("no tasks; start one with: python scripts/task.py new <name>")
		return
	widths = [max(len(r[i]) for r in rows) for i in range(5)]
	print("  ".join(h.ljust(w) for h, w in zip(("folder", "branch", "vs odin-sculpt", "worktree", "PR"), widths)))
	for r in rows:
		print("  ".join(c.ljust(w) for c, w in zip(r, widths)))


def cmd_sync(a):
	"""Merges the latest odin-sculpt into the task this runs in, as every PR does before it opens."""
	here = git("rev-parse", "--show-toplevel", cwd=os.getcwd())
	if os.path.normpath(here) == os.path.normpath(main_checkout()):
		sys.exit("task: sync runs inside a task's worktree; the main checkout pulls with git pull --ff-only")
	if git("status", "--porcelain", "--untracked-files=no", cwd=here):
		sys.exit("task: commit or stash the changes first, so the merge cannot mix with them")
	git("fetch", "--quiet", "origin", cwd=here)
	r = subprocess.run(["git", "merge", "--no-edit", f"origin/{MAIN_BRANCH}"], cwd=here, capture_output=True, text=True)
	print(r.stdout.strip() or r.stderr.strip())
	if r.returncode != 0:
		sys.exit("task: the merge stopped on conflicts; resolve them, then git commit")


def cmd_done(a):
	check_name(a.name)
	path, branch = task_path(a.name), BRANCH_PREFIX + a.name
	if not any(os.path.normpath(p) == os.path.normpath(path) for p, _ in worktrees()):
		sys.exit(f"task: no worktree at {path}")
	if (os.path.normpath(os.getcwd()) + os.sep).startswith(os.path.normpath(path) + os.sep):
		sys.exit(f"task: run done from outside {path}; a shell still in it would be left in a folder that is gone")
	git("fetch", "--quiet", "origin")
	dirty = git("status", "--porcelain", cwd=path, check=False)
	merged = subprocess.run(["git", "merge-base", "--is-ancestor", branch, f"origin/{MAIN_BRANCH}"], cwd=ROOT).returncode == 0
	if not a.force:
		if dirty:
			sys.exit(f"task: {path} has uncommitted changes:\n{dirty}\nCommit them, or pass --force to drop them")
		if not merged:
			sys.exit(f"task: {branch} is not in origin/{MAIN_BRANCH} yet; merge its PR first, or pass --force to drop it")
	git("worktree", "remove", *(["--force"] if a.force else []), path)
	git("branch", "-D" if a.force else "-d", branch)
	removed = "worktree and branch"
	if git("ls-remote", "--heads", "origin", branch):
		git("push", "--quiet", "origin", "--delete", branch)
		removed += ", and the branch on origin,"
	print(f"task {a.name}: {removed} removed" + ("" if merged else " (it was not merged)"))


def main():
	p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	sub = p.add_subparsers(dest="cmd", required=True)
	n = sub.add_parser("new", help="start a task in its own worktree")
	n.add_argument("name")
	n.add_argument("--base", default=MAIN_BRANCH, help="the branch to start from (default odin-sculpt)")
	sub.add_parser("list", help="every task and its state")
	sub.add_parser("sync", help="merge the latest odin-sculpt into the task this runs in")
	d = sub.add_parser("done", help="remove a merged task's worktree and branches")
	d.add_argument("name")
	d.add_argument("--force", action="store_true", help="also when unmerged or with uncommitted changes")
	a = p.parse_args()
	{"new": cmd_new, "list": cmd_list, "sync": cmd_sync, "done": cmd_done}[a.cmd](a)


if __name__ == "__main__":
	main()
