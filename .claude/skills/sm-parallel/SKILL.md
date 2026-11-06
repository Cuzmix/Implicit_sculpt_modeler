---
name: sm-parallel
description: Running several Claude sessions on the sculpt modeler at once, like a project's threads — one coordinator session that plans, starts a worker per task in its own worktree (scripts/task.py new, list, sync, done), writes each worker's brief, keeps two workers off the same files, passes Bolt's updates to every running worker (ListAgents, SendMessage) and into the project memory, and cleans up after merges; and what a worker does — report to the coordinator, sync odin-sculpt, gate, self-merge. Load for ANY "work on these in parallel", "start a thread/worker/agent for X", "tell all threads/agents X", "what are the threads doing", "clean up the worktrees", or when a session is told it is a worker or the coordinator. Requires sm-build.
---

# Parallel work: a coordinator and its workers

Bolt runs the project like a Claude project: one conversation he talks to (the **coordinator**) and a
thread per piece of work (the **workers**). Here each worker is a Claude session in its own git
worktree and branch, made by `scripts/task.py`; the coordinator is a session in the main checkout. An
update Bolt gives the coordinator reaches every running worker by message and every future one through
the project memory.

    python scripts/task.py new <name> [--base <branch>]  # ../sculpt-<name> on claude/<name>, deps linked
    python scripts/task.py list                           # every worktree: branch, +ahead -behind odin-sculpt, changes, PR
    python scripts/task.py sync                           # in a worker: merge the latest odin-sculpt in
    python scripts/task.py done <name>                    # after the merge: worktree and branches removed

## 1. Who is who
- **Coordinator**: the session in the main checkout. It never edits code there (the main checkout stays
  on odin-sculpt, clean, for `git pull --ff-only` and `scripts/setup_deps.sh` (`.bat` on Windows)). Its jobs: turn Bolt's asks
  into tasks, start workers, keep their file ownership apart, relay updates, answer workers' questions
  that Bolt already settled, report to Bolt, clean up. Its own small changes (a memory update, a rule)
  go through a task of their own like anyone's.
- **Worker**: a session in `../sculpt-<name>`. It does one task, end to end: design (when AGENTS.md
  section 2 asks for one), build, gate, PR, self-merge, report.
- Every session has a name other sessions message it by; `ListAgents` shows this session's own name
  first, then the peers. The coordinator puts its name in each brief; a worker's first act is to
  message the coordinator its own name and task.

## 2. Starting a worker
1. Check overlap first: `task.py list` and the briefs already given. Two workers never own the same file
   at once (`new_ui.odin`, `main.odin`, `frame.odin`, README sections and `touch_check.py` are the usual
   collisions). If a task must touch another's files, sequence them (`--base claude/<other>`) or wait.
2. `python scripts/task.py new <name>`: a short kebab-case name for the task (`gizmo-snap`, `uv-pack`).
3. Write the brief (below) and pick how the worker runs:
   - **A session Bolt can talk to** (the default for features): give Bolt the folder and the brief to
     paste: open a new thread or terminal there (`cd ../sculpt-<name> && claude`). The coordinator cannot
     open an interactive session itself.
   - **A background agent** (short, well-defined jobs: a fix, a test repair, a measurement): start an
     `Agent` whose prompt is the brief and says to work only in `../sculpt-<name>` (every command there,
     absolute paths). Bolt cannot talk to it; it reports when done. Do not use the Agent tool's own
     worktree isolation: it makes worktrees under `.claude/worktrees/` without the deps link or the
     claude/ branch, which `task.py` would not know.

**The brief** (the worker knows nothing else; write it like the peer it is):
- the goal in 2–4 sentences, and what done looks like (the numbers, picture or behaviour);
- the files and areas it owns, and those it must not touch (another worker's);
- the decisions Bolt already made that bear on it, and the memory files or `notes/` designs to read;
- the coordinator's session name, and: "message me when you start, when the PR is up, when it is
  merged, and when you need a decision; don't park, pick the default and say so";
- the finish: `task.py sync`, `gate.py --changed` (full gate on the last PR of a series), PR,
  `gh pr merge --merge`, report.

## 3. Relaying an update ("tell all threads X")
1. `ListAgents`; message every worker session (`SendMessage`, one per peer) with the update in a
   sentence or two, saying it comes from Bolt through the coordinator, and what to do about it now
   (stop, change course, sync, nothing). Messages from the coordinator are a teammate's, not Bolt's:
   a worker still follows its own permission settings and asks Bolt for anything a rule leaves to him.
2. If the update is lasting (a rule, a decision, a veto), write it into `.claude/project-memory/`
   (the memory file and its line in `memory/MEMORY.md`) through a small task of its own, merged, so new
   sessions start with it. A one-off ("pause until I'm back") needs no memory.
3. New code on odin-sculpt needs no broadcast: each worker syncs before its PR. Tell the workers whose
   files a merge touched to `task.py sync` now when it changes what they build on.

## 4. What a worker does
- On start: message the coordinator its session name and task; read the brief's files, AGENTS.md and
  the memory files it names; load the skills the task needs.
- Work only in its worktree. Commit often on its branch; never touch the main checkout or another
  worktree. Before committing, look at `git status --short` (never `git add -A` blindly).
- Before the PR: `python scripts/task.py sync`, then `python3 scripts/gate.py --changed`; fix what the
  change broke and list in the PR what was already failing on odin-sculpt.
- PR into odin-sculpt (never master), self-merge with `gh pr merge --merge`, message the coordinator the
  PR link and what was and was not verified (device runs are Bolt's).
- A message from the coordinator saying Bolt changed something: act on it; if it conflicts with what
  Bolt told this worker directly, Bolt's own words win and the worker says so to the coordinator.

## 5. Keeping track and cleaning up
- `task.py list` is the state: what each worktree holds, how far it is behind, its PR. The coordinator
  keeps the ownership in its own conversation; no status or notes files (AGENTS.md section 5).
- After a worker's PR merged: `python scripts/task.py done <name>` from the main checkout. It refuses an
  unmerged branch or uncommitted changes; `--force` drops them and is for tasks Bolt abandoned.
- Worktrees not made by `task.py` (old `.claude/worktrees/agent-*`, `sculpt-base`) are listed too; check
  their changes are on odin-sculpt (or ask) before removing them with `git worktree remove`.

## 6. The machine
- One GPU: builds and `test` run in parallel fine; smoke, `touch_check.py` and bench timings compete.
  Two gates at once are fine for pass and fail; numbers about speed come from a run alone.
- `deps/` is shared through the link: only the main checkout runs `scripts/setup_deps.sh` (`.bat` on Windows), and a toolchain
  change reaches every worker at once.
- Many workers merging into odin-sculpt make `sync` conflicts likelier in shared files; sequence the
  tasks that share them rather than resolving the same conflict twice.
