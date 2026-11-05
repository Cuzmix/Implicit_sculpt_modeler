---
name: ux-research
description: 2026-10-25 UX research of ZBrush/Nomad/3DCoat docs plus audit of our app; redesign and roadmap phases 0-7 for the sculpt app
metadata:
  type: project
  modified: 2026-10-25T20:12:33.452Z
---

Thread "Reverse-engineer sculpting app UX" (2026-10-25) delivered 14 markdown files in /mnt/project-files/notes/ux-research/ (README index, 00_Sources … 12_Product_Roadmap, 13_Our_App_Audit) and a summary page https://claude.ai/artifact/AqPLtN7YQEq9MMCTKQNymy. Research only, no code changed.

Key conclusions:
- Scorecard average: ZBrush 6.4, Nomad 6.6, 3DCoat 5.7, us 5.7. We are weakest at customisation (2), onboarding (3), discoverability (4).
- The command registry (A-20) is the spine. It unlocks palette search, bindings, favourites, the contextual bar, macros and scripts. It needs an sm-architect review first.
- Roadmap: P0 validate (tablet checklist, Windows try), P1 foundations (settings schema A-22, brush table A-21, registry A-20, op results A-25, app tests A-26), P2 touch parity (modifier rail Smooth/Invert/Mask/Hide, long press, double-tap pivot), P3 find anything (palette, Object tab split into Shape/Select/Surface/Build), P4 customisation, P5 autosave + adjust last op, P6 gizmo/scene tree/depth, P7 scripts/export/plugins.
- Gaps: some ZBrush pages (ZModeler sub-pages, FiberMesh, Python API), the 3DCoat UV page, and Nomad v2.9 (forum only). ZBrush help is only fetchable via `.html.md` URLs.

- 2026-10-25 21:10Z: Bolt asked how to tackle each problem. Plan doc https://claude.ai/artifact/9147KScLQRMX2CJUErAGMD maps all 100: 42 build (workstreams 1-8: registry, touch, find, yours, safety, scene, depth, pipeline), 13 checks (workstream 0), 45 design rules (to go in sm-ui skill and sm-reviewer checklist). A decision card asks Bolt which to start (recommended: registry first).

**Why:** Bolt asked for a modernization plan grounded in competitor docs, plus a maintainability audit.
**How to apply:** Pick future UX/refactor work from 12_Product_Roadmap.md in phase order; cite 07's priority scores. Related: [[sculpt-new-ui]], [[sculpt-touch-camera]].
