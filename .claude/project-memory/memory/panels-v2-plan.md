---
name: panels-v2-plan
description: 2026-11-04 panels+docks redesign from scratch (palettes out): Bolt approved mock v7.2, building PRs A-G on branch claude/project-thread-8vgln6
metadata:
  type: project
  modified: 2026-11-04T00:02:19.018Z
---

Bolt 2026-11-03 23:49 (thread "Redesign panels and dock bar from scratch"): "completely refactor the panel and dock bar... I don't like it... keeping code that's not needed... palettes should be removed... push back and be critical". Planning only, no code until Bolt approves.

Delivered 2026-11-04:
- Review + plan (Claude Doc): https://claude.ai/artifact/RsfEHZKMGNA5Awi5EA7fDm (every iteration's pros/cons, palettes verdict, benchmark, model, deletions, PRs).
- Interactive mock "Docks and Cards v7": https://claude.ai/artifact/1hGzEd2pmaZD6KULbE31LW, source /mnt/project-files/notes/panels-v2/mock.html (iPad / narrow / Windows, left-handed, zones).

Model: Dock = buttons, Card = controls; sheets transient; cards in columns beside docks (one per column on touch, pinned returns; palm zone; mouse splits; <900 pt bottom sheet).

2026-11-04 01:03 Bolt DECIDED: docks stay movable like Affinity (edge or floating), resize by a minimal faint corner handle; mock v7.1 adds a faint grip bar to move and the corner for 1-3 columns. 01:29 Bolt: docks (shelf too) repositionable ANYWHERE, keep today's soft grid alignment; mock v7.2 does it (any edge, top/bottom = row, floating aligns 10 pt). Bolt: keep iterating the mock until it looks right before code. Still open: one layout per space vs named workspaces (rec one); palettes removed (rec yes).


2026-11-04 02:00 Bolt: "OK looks good proceed I wo be away" = build the series autonomously. PR plan as built: A cards replace stack/tray/palettes (10 cards: Tool Layers Scene Mesh Mask Deform Paint Symmetry Look Render; `Section` enum replaces Panel_Kind; Open_Card arg=Card, Open_Section arg=Section; layout line `column right Look`; files cards.odin, column.odin); B floating cards; C sheets + History/Colours cards (Kit_Window gone); D docks anywhere, rows, faint grip+corner; E one layout per space; F platforms; G second view as pane, docs, touch suite.
PR A findings: ui_ms p50 4.5 -> 2.1 ms; offscreen dumps cut at 1280x720 (use --width=1280 --height=720).

2026-11-04 PRs merged: A #607 cards, B #608 floating, C1 #609 History/Colours cards, C2 #610 sheets (sheet.odin, exit stat sheet=), C3 #611 Details card (Stats gone). Next D1 grip+corner without Edit docks, D2 Top edge/rows (design.md).
2026-11-04 08:00 Bolt approved consistency/removals ("proceed"); Stats -> Details card (C3, my rec). 08:25 Bolt OK'd it: keep removing what isn't needed, refactor, make consistent, keep UX simple.
2026-11-04 09:43 Bolt OK'd D1-G mock https://claude.ai/artifact/43N8p4SCtowCanwLzaMPEa (source notes/panels-v2/d1-g.html) incl. my rec: Edit docks -> per-dock "Edit buttons" from a dock's menu, global mode leaves the main menu (do in D2). D1 = dock_grip + faint corner (arrange_carry_follow keyed by carry_by id).
2026-11-04 13:00: D1 #615, D2 #618 merged (any edge, rows, grip only). E built (layouts.odin replaces workspaces*: one layout per space, kept as left, tab dots, Reset layout; dock menu Edit buttons = k.edit_dock, dock_editing/bar_editing). Touch fails also on base: + history_step_menu, history_tint, object_menu_lists_verbs.
E #622, F #623 merged (sheet <900pt, Android gesture strips gesture_edges.odin). Compact mouse rows dropped (asked Bolt if wanted as a setting). G #625 merged 2026-11-04: Thumbnail window/Kit_Window/mini view gone, Second view toggles Single<->Side_By_Side; Render ships Look card only. SERIES DONE.
2026-11-04 Bolt said yes to all 8 motion places + any others: PR #628 (panel_motion.odin: copy_prev leaves, Pop pills, slot glides, pane wipe/grow; kinds Cards/Docks/Spaces/Pills). Headless mid-frame dumps: script then `wait N` (dump at end); --ui-events frames count after the script.
