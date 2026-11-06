---
name: sm-parallel
description: Running several agents on the sculpt modeler at once, like a project's threads — one coordinator that plans, starts a worker per task in its own worktree (in Paseo through its tools — list_profiles, create_workspace, create_agent, send_agent_prompt, archive_workspace — with paseo.json linking deps; elsewhere scripts/task.py new, list, sync, done), writes each worker's brief, keeps two workers off the same files, passes Bolt's updates to every running worker and into the project memory, and cleans up after merges; and what a worker does — report, sync odin-sculpt, gate, self-merge. Load for ANY "work on these in parallel", "start a thread/worker/agent for X", "tell all threads/agents X", "what are the threads doing", "clean up the worktrees", or when an agent is told it is a worker or the coordinator. Requires sm-build.
---

# Parallel work: a coordinator and its workers

Bolt runs the project like a Claude project: one conversation he talks to (the **coordinator**) and a
thread per piece of work (the **workers**). Each worker is an agent in its own git worktree and
branch; the coordinator works from the main checkout. An update Bolt gives the coordinator reaches
every running worker by message and every future one through the project memory.

Bolt runs agents in **Paseo** (paseo.sh): its workspaces make the worktrees, its tools let the
coordinator start, prompt and archive workers, and its **Subagents track** lets Bolt open any worker
and talk to it. `paseo.json` at the repo root runs `python3 scripts/task.py link` in every new
worktree (deps linked to the main checkout's and checked ignored) and offers check, test, build,
smoke, touch, gate-changed, gate and sync as one-click scripts. Outside Paseo, `scripts/task.py` does
the worktree work by hand:

    python scripts/task.py new <name> [--base <branch>]  # ../sculpt-<name> on claude/<name>, deps linked
    python scripts/task.py list                           # every worktree: branch, +ahead -behind odin-sculpt, changes, PR
    python scripts/task.py sync                           # in a worker: merge the latest odin-sculpt in
    python scripts/task.py link                           # in a worktree made elsewhere: link deps
    python scripts/task.py done <name>                    # after the merge: worktree and branches removed

## 1. Who is who
- **Coordinator**: works from the main checkout and never edits code there (it stays on odin-sculpt,
  clean, for `git pull --ff-only` and `scripts/setup_deps.sh`, `.bat` on Windows). Its jobs: turn
  Bolt's asks into tasks, start workers, keep their file ownership apart, relay updates, answer
  workers' questions Bolt already settled, report to Bolt, clean up. Its own small changes (a memory
  update, a rule) go through a worker or a worktree of their own like anyone's.
- **Worker**: an agent in one worktree doing one task end to end: design (when AGENTS.md section 2
  asks for one), build, gate, PR, self-merge, report.

## 2. Starting a worker
1. Check overlap first: `task.py list` (it lists Paseo's worktrees too) and the briefs already given.
   Two workers never own the same file at once (`new_ui.odin`, `main.odin`, `frame.odin`, README
   sections and `touch_check.py` are the usual collisions). If a task must touch another's files,
   sequence them (branch off the other's branch) or wait.
2. **Pick the profile.** In Paseo, `list_profiles` and read each profile's notes; choose the one Bolt
   named or the one whose notes fit (UI work, planning, review, ...). `create_agent` takes no profile:
   copy its provider, model, mode and thinking into the call. No profile fits: say which settings you
   chose.
3. **Make the worktree.** In Paseo, `create_workspace` with worktree isolation, branching off
   `origin/odin-sculpt` (the fetched ref, never the local branch) on a new branch `claude/<name>`;
   setup links deps. Outside Paseo, `python scripts/task.py new <name>`.
4. **Start the worker** with the brief as its first prompt. In Paseo, `create_agent` with the
   workspace's `workspaceId` and `initialPrompt`: it is the coordinator's subagent, Bolt can open it in
   the Subagents track, and the coordinator is told when it finishes. Leave `background` off for
   features so Bolt sees it; set it for small jobs nobody needs to watch (a measurement, a test
   repair). Outside Paseo, give Bolt the folder and the brief to paste into a new session there.

**The brief** (the worker knows nothing else; write it like the peer it is):
- the goal in 2–4 sentences, and what done looks like (the numbers, picture or behaviour);
- the files and areas it owns, and those it must not touch (another worker's);
- the decisions Bolt already made that bear on it, and the memory files or `notes/` designs to read;
- how to reach the coordinator (in Paseo the finish notification comes by itself; ask questions with
  `send_agent_prompt` to the coordinator's agent id, which the brief gives), and: "don't park on
  questions: pick the default, say so, and carry on";
- the finish: `task.py sync`, `gate.py --changed` (the full gate on the last PR of a series), PR,
  `gh pr merge --merge`, then a final message with the PR link and what was and was not verified.

## 3. Relaying an update ("tell all threads X")
1. Send it to every running worker: in Paseo, `send_agent_prompt` to each of the coordinator's
   workers (`list_agents` shows them); outside Paseo, `ListAgents` and `SendMessage` to each session.
   Say in a sentence or two what changed, that it comes from Bolt through the coordinator, and what to
   do now (stop, change course, sync, nothing). A worker still keeps its own permission settings and
   asks Bolt for anything a rule leaves to him.
2. If the update is lasting (a rule, a decision, a veto), write it into `.claude/project-memory/`
   (the memory file and its line in `memory/MEMORY.md`) in a worktree of its own, merged, so new
   agents start with it. A one-off ("pause until I'm back") needs no memory.
3. New code on odin-sculpt needs no broadcast: each worker syncs before its PR. Tell the workers whose
   files a merge touched to sync now when it changes what they build on.

## 4. What a worker does
- On start: read the brief's files, AGENTS.md and the memory files it names; load the skills the task
  needs.
- Work only in its worktree. Commit often on its branch; never touch the main checkout or another
  worktree. Before committing, look at `git status --short` (never `git add -A` blindly).
- Before the PR: `python scripts/task.py sync`, then `python3 scripts/gate.py --changed`; fix what the
  change broke and list in the PR what was already failing on odin-sculpt.
- PR into odin-sculpt (never master), self-merge with `gh pr merge --merge`, and end with the PR link
  and what was and was not verified (device runs are Bolt's).
- An update from the coordinator: act on it; if it conflicts with what Bolt told this worker
  directly, Bolt's own words win and the worker says so.

## 5. Keeping track and cleaning up
- `task.py list` is the state: every worktree, how far it is behind, its PR. The coordinator keeps the
  ownership in its own conversation; no status or notes files (AGENTS.md section 5).
- After a worker's PR merged: in Paseo, `archive_workspace` (its teardown removes the worktree);
  otherwise `python scripts/task.py done <name>` from the main checkout, which refuses an unmerged
  branch or uncommitted changes (`--force` drops them, for tasks Bolt abandoned). Delete the merged
  branch on origin if it is still there.
- Worktrees made by neither (`sculpt-base`, the parity baseline; old `.claude/worktrees/*`): check
  their changes are on odin-sculpt, or ask, before `git worktree remove`.

## 6. The machine
- One GPU: builds and `test` run in parallel fine; smoke, `touch_check.py` and bench timings compete.
  Two gates at once are fine for pass and fail; numbers about speed come from a run alone.
- `deps/` is shared through the link: only the main checkout runs `scripts/setup_deps.sh`, and a
  toolchain change reaches every worker at once.
- Many workers merging into odin-sculpt make `sync` conflicts likelier in shared files; sequence the
  tasks that share them rather than resolving the same conflict twice.
