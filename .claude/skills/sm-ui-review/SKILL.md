---
name: sm-ui-review
description: Scoring the interface's look and usability so a change can prove it made things better — the screenshot corpus (scripts/ui_shots.py), the computed audit and its baseline (scripts/ui_audit.py), the reference shots of other sculpting apps, three fresh sm-ui-critic reviewers scoring an eight-category rubric out of 10 against them, the findings ledger, the round table a PR carries, and annotated before/after sheets. Load for ANY task that changes how a panel, bar, card, menu, icon, colour, size or motion looks or reads, or asks "is this UI better?", "review the design", "polish this panel"; it adds the measuring to sm-ui (how the kit works), sm-design (what to build) and sm-figma-ui (mocks first).
---

# Scoring the interface (the hill a UI change climbs)

Bolt's ask (2026-11-04, after Theo's T3 Code video): make the interface look and work like a serious commercial
sculpting app, with a loop an agent can repeat. The video's lesson: a UI gets better when its changes are scored
against the old build AND against rival apps, per category, by several judges who do not know the target, until every
score clears the bar; and computed checks beat judged ones wherever a number exists. This skill is that loop.

## 1. The two halves
- **Computed** (`python scripts/ui_audit.py`, part of `build.bat check`): contrast of token pairs in every literal
  theme, distinct popover widths, literal paddings and gaps, hand-scaled type sizes, colour literals outside the
  themes, icons with more than one meaning. Each is a count held against `scripts/ui_audit_baseline.json`: a count
  above it fails check; when a change lowers one, run `--update` in the same PR so it cannot slip back. Never raise
  the baseline to pass; if a new count is right (a new theme's pairs), say why in the PR.
- **Judged** (this skill's council, below): what no count sees: hierarchy, whether the clay reads first, whether a
  sculptor finds the next step.

## 2. The corpus
- `python scripts/ui_shots.py [screens]` writes `build/ui_shots/<screen>@<size>-<theme>.png` and its `.map`, for
  14 screens (`ui_shots.py list`) at desktop 1600 x 900 and tablet 1180 x 820 points (the M2 iPad Air landscape) in
  Lens and Paper. A new card, sheet or menu that people meet gets a row in `SCREENS`, opened by a control's name.
- Before changing anything, take the baseline into its own folder: `--out build/ui_shots/before`. After, into
  `build/ui_shots/after`, then `python scripts/ui_shots.py sheet build/ui_shots/before build/ui_shots/after
  build/ui_shots/sheets`: each pair side by side with every changed region boxed in red, and a line per screen of
  where. Open the sheets and look; a change that boxes more than it meant to is a finding.
- The reference set: other apps' screens of the same jobs, in the project's shared files under
  `notes/ui-reference/<app>/` (`/mnt/project-files/notes/ui-reference` in a cloud session): ZBrush for iPad, Nomad,
  Uniform so far. They are review material only: never copied into the repository, never shipped, and no brand name
  reaches the app's interface (sm-design). Without them, say the review had no references.

## 3. The rubric (each out of 10)
| Category | 9 or 10 looks like |
|---|---|
| Clay first | the model is the brightest, largest thing; chrome recedes; nothing competes with a stroke |
| Hierarchy | one entry point per panel; the common controls first and largest; secondary text clearly quieter |
| Typography | the ramp's steps only; one weight for labels, one for values; nothing cut off that matters |
| Iconography | one icon one meaning; brushes told apart by their effect; icons aligned on one grid and weight |
| Colour and contrast | the accent means "active" only; every text 4.5:1 or better; disabled is clearly disabled yet legible |
| Spacing and alignment | the spacing scale only; edges line up across panels; menus' labels start at one x |
| Consistency | one selected look, one control per job, the same word for the same thing on every surface |
| Touch and pen fit | 48 pt targets, words where there is no hover, nothing under the palm, fits 1180 x 820 |

## 4. A round
1. Fix what you already know before a round; never send known faults to the judges.
2. Start three `sm-ui-critic` agents at once (general-purpose agents told to read `.claude/agents/sm-ui-critic.md`
   first where that role is not offered). Give each the same brief: the screens (paths), the matching reference
   shots, the rubric above, and for a later round the before shots too. Never tell them a target score, which
   inflates scores (the video saw it), and never show them each other's answers.
3. Each returns, per screen, a score per category and findings `id [blocker|should|nit] screen: claim. Fix: ...`.
4. Keep a ledger: id, severity, what you did (fixed / declined: reason / follow-up). Merge the three judges'
   duplicates. A nit, or anything outside the change's system (an icon finding in a spacing PR), is a follow-up,
   never a reason to grow the PR: fight scope creep.
5. Fix the blockers and shoulds that are in scope, re-shoot, start a new round with fresh agents. Budget: three
   rounds a change; stop early when a round brings only nits.
6. Done when every judge gives 8 or more in every category on the changed screens and no screen lost a point
   against the baseline round. A phase that aims higher says so in its plan; the bar rises as the series goes.

## 5. What the PR carries
```markdown
## UI review
Rounds: 2 · References: ZBrush for iPad, Nomad, Uniform · Audit: contrast_fails 8 -> 0, popover_widths 11 -> 4

| Screen | Category | Before | Round 1 | Round 2 |
| --- | --- | --- | --- | --- |
| mesh_card | Hierarchy | 5.3 | 7.0 | 8.3 |
```
Scores are the three judges' mean, one decimal; a judge that gave none is "no score", never invented. Add the
before/after sheets that matter (upload where the session can), and say which findings were declined and why.

## 6. Rules that keep it honest
- Judges see pictures, not code, and are told the app is a touch-first sculpting app for iPad, Android tablets
  and desktops. They review only; they never edit.
- Performance is a hard rule above any score: `ui_ms` p50 and p99 and `ui_vertices` from the exit stats go in the
  PR beside the scores; no blur passes, no per-frame text layout, nothing animated under a stroke (sm-perf, sm-ui).
- Bolt steers: the judges drift toward "grey and safe" (the video's lesson); Bolt's taste at each phase gate wins.
