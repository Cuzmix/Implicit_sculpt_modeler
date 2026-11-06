---
name: sculpt-worktrees
description: "How to make a worktree for a task: one per task beside the repo, deps symlinked to the main checkout's (safe since .gitignore ignores /deps in any form, 2026-11-06)"
metadata:
  type: project
  modified: 2026-11-06T15:00:00.000Z
---

Each task gets its own worktree and branch beside the main checkout, and its own Claude session; the main checkout is only for pulling and for `scripts/setup_deps.sh`:

    git worktree add ../sculpt-<task> -b claude/<task> odin-sculpt
    ln -s "$PWD/deps" ../sculpt-<task>/deps
    cd ../sculpt-<task> && claude

`deps/` (the pinned Odin, SDL3 and the rest) is shared through the link; `build/` is per worktree, so builds do not collide. One branch per worktree (git refuses two), and `smoke`, `touch_check.py` and bench timings share the one GPU, so run those one at a time when the numbers matter.

History: on 2026-10-27 a worktree's `deps` symlink was committed, because `.gitignore` said `/deps/`, which matches only a directory, not a link. Checking that branch out in the main repo replaced the real deps folder with a self-referencing link and setup_deps.sh had to run again. Since 2026-11-06 `.gitignore` says `/deps`, which ignores it as a folder or a link, and `.git/info/exclude` (shared by every worktree) also lists `deps`.

**Why:** Bolt runs several sessions in parallel on his laptop; on 2026-11-06 three sessions shared the main checkout and their uncommitted work got tangled.

**How to apply:** never work in the main checkout; make the worktree as above. Before committing from a worktree, still look at `git status --short` rather than `git add -A` blindly. Remove a worktree with `git worktree remove` once its PR merged. Related: [[local-machine-real-gpu]].
