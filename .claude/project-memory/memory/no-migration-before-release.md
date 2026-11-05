---
name: no-migration-before-release
description: Bolt 2026-11-02: app is unreleased, nobody uses it; never write migration code for saved settings/layouts, just change formats freely
metadata:
  type: feedback
  modified: 2026-11-02T18:57:22.084Z
---

Bolt 2026-11-02 18:57 (thread "Redesign the interface as docks and cards"): "nobody's using this app. We're still in development. Don't care about migrating saves or doing any weird changes to support the migration saves until we are released... any changes is completely fine."

**Why:** migration code (old rail/shelf/stack lines -> new layout, settings version bumps that convert) is cost with no users to protect.
**How to apply:** for scene files, settings, layouts, docks, UI state, .strokes, cage/voxel sections: change writer and reader together, delete old reading, no version branches, no optional trailing fields, no renamed-line aliases, no one-time default conversions; an old file is refused (or a settings line skipped). Done in #504 (2026-11-02): v1-35 scene readers, settings migrations, Panels_Old/rail_main/grid upgrades removed; AGENTS.md hard rule rewritten. Still kept on purpose: script aliases (light_key, Workspace:Focus), variable-length preset lines, writer layout quirks (area light as spot, CURV chunk). Revisit at release. Related: [[docks-cards-redesign]].
