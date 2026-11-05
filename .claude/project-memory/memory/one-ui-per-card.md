---
name: one-ui-per-card
description: Bolt 2026-11-02: never two different UIs for the same thing; each card is the one UI, sections/palettes draw the card, best of both combined
metadata:
  type: feedback
  modified: 2026-11-02T12:07:27.568Z
---

Bolt 2026-11-02 11:55: "not have two different ui for the same thing... double check all cards... just like how we did with the scene card... take the best of both and combine it". Triggered by the rail's Layers button opening the tray's plain Layers section (no thumbnails) instead of the Layers card (fixed #493: rail_card_slot migrates saved rails).

**Why:** duplicate panels drift apart in style and features, and Bolt notices the inconsistency on device.
**How to apply:** when adding or changing a card, make every entry point (rail, Show_Section, palettes, object menu, shelf) draw that same card; fold the twin's unique controls into it (under More/groups if the card would grow); never leave a second UI. Audit 2026-11-02 found 4 twins: Layers card vs Object palette Layers section, Material card vs Scene palette Material section, Lights card vs Lights section, Scene card vs Scene palette Objects tree + Add object section. Brush, Symmetry, Tools, Environment were already single. See [[rail-groups-lights-plan]], [[lens-panel-model]].
