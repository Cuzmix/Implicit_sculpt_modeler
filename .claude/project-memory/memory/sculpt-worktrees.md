---
name: sculpt-worktrees
description: Gotcha when using a second git worktree for the sculpt repo: never symlink deps into it
metadata:
  type: project
  modified: 2026-10-27T19:51:03.397Z
---

2026-10-27: a second worktree with `deps` symlinked to the main repo's deps got the symlink committed (.gitignore has `deps/`, which matches only a directory, not a symlink). Checking that branch out in the main repo replaced the real deps folder with a self-referencing link, and the toolchain had to be reinstalled with scripts/setup_deps.sh.

**Why:** cost a setup_deps rerun (a few minutes) and nearly shipped a `deps` symlink in a PR.
**How to apply:** in a worktree, run setup_deps there or pass the toolchain path some other way; before committing from a worktree run `git status --short | grep deps` and never `git add -A` blindly.
