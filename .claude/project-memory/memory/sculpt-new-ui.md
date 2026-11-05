---
name: sculpt-new-ui
description: State of the new touch-first interface (src/ui kit, PR #47): redesign done, now the default UI, flags and limitations
metadata:
  type: project
  modified: 2026-10-25T14:27:08.579Z
---

PR #47 (merged into odin-sculpt 2026-10-25) holds phase 1 (src/ui kit, sm-store skill) and, since 2026-10-25, the full redesign Bolt asked for (HeroUI look, Anime.js-style motion).

- Dear ImGui was REMOVED entirely in commit 200bec1 ("one interface, drawn by the kit"); no --classic-ui any more. `--reduce-motion` (remembered), `--ui-events` scripted pointer for tests, `--dump-screen` PNG.
- Tokens: src/ui/theme.odin ("Graphite", accent #5B8CFF).
- Motion: src/ui/motion.odin (tweens keyed by id, retarget, presence, transform_since). Popovers/tooltips/toasts in src/ui/popup.odin.
- Design spec Claude Doc: https://claude.ai/artifact/XbPCViHydzp6UGAWT1PCvP ; screenshots in /mnt/project-files/notes/ui/redesign-*.png.
- Release ui_ms p50 ~0.3 ms vs ImGui 0.4 ms.
- All panels now live in the kit (Object tab has 18 folding sections, an IA problem noted in notes/ux-research/13_Our_App_Audit.md). Layer names are text fields. No light theme. Not tried on Windows.

**Why:** Bolt chose Odin + SDL3 + own UI for Windows/Linux/Android tablets ([[cross-platform-flutter-plan]]).
**How to apply:** next UI work ports the classic-only panels into the inspector, then focus navigation and text fields.
