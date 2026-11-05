---
name: ui-build-gotchas
description: Gotchas for UI PRs in this repo: merge method, parity base worktree, sm-ui split, prev_rect in roots
metadata:
  type: project
---

merge PRs with method merge (not squash): a squash leaves the branch diverged and pushing then needs a `-s ours` join (never force). Parity runs against a base build in scratchpad worktree wt-values, which needs deps/ufbx copied in (never symlinked) since FBX import #329. sm-ui split in #349: the Lens layout map is .claude/skills/sm-ui/references/lens-layout.md (body 398 lines). Inside another root use ui.prev_root_rect, as prev_rect hashes under the current id. lens_stack_grip_sets_a_card_height was broken by #312 and fixed on the base by 537d1c3. Checks per PR: [[gate-per-pr]].
