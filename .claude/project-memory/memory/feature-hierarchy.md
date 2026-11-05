---
name: feature-hierarchy
description: 2026-10-26 ZBrush for iPad UI research and proposed one-home feature hierarchy for the sculpt app (doc, proposals, open question)
metadata:
  type: project
  modified: 2026-10-26T19:33:37.125Z
---

Thread "Design feature hierarchy from ZBrush iPad" (2026-10-26). Research only, no code changed. Claude Doc: https://claude.ai/artifact/GXDbfPpR14mwtwb9WbGAbN

- Network (updated 2026-10-26 19:30Z after Bolt changed the environment): curl now reaches help.maxon.net/zbp/en-us/Content/html/*.html and its Resources/Images (real 2000px screenshots), maxonassets.imgix.net, and chatgpt.com/share pages (conversation text is in `streamController.enqueue("...")` chunks). apps.apple.com and is1-ssl.mzstatic.com still fail.
- Core finding: ZBrush iPad scales because every feature has one home in the palette tree and toolbar items are copies naming their parent; Quick Search (2026.1) shows the path and opens the place. Our code has six separate lists (Command_Group, BRUSH/OBJECT/SCENE_SECTIONS, Menu/View arrays, action bar groups) and no path.
- Proposed (after Phase 6 lands): 1 COMMAND_HOMES table + test, Help/Keys group by home, drop Command_Group; 2 palette path line + "Show where" + Palette_Kind.Section with slider search words; 3 Brush tab pages Brush/Tip, Object Shape split into Shape + Mesh (levels, HD, dyntopo, Rebuild), Deformation to Shape, Symmetry section in Options; 4 long press "Open settings" on every quick copy, commands in dock slots; 5 sections in pie slots as popovers; 6 Export/Import my setup file.
- Avoid: multiple swiped toolbars, brand names, no-undo deletes, paywalled customisation.
- Open question for Bolt: fifth Object page (Mesh) OK?

**Why:** Bolt asked for ZBrush iPad research mapped to our code. **How to apply:** pick this up as a short workstream after Phase 6 item 7; related [[ux-research]], [[sculpt-discoverability]], [[sculpt-customisation]].
- 2026-10-26: mock canvas https://claude.ai/artifact/7rueE5Y2oigRxaENscCHXE has two artboards: Main (proposed desktop hierarchy) and IpadLayout (Bolt asked for a 1:1 ZBrush for iPad layout copy; built from Maxon text docs with our look, names and features; orange = ZBrush has it, we don't).
- 2026-10-26 (thread "Mock ZBrush for iPad layout 1:1"): third artboard ZBrushIpad1to1 (now the canvas launch) is a measured 1:1 copy of the ZBrush iPad canvas from Maxon screenshots (grey look, orange accent, icon toolbars, modifier wheel, real long press, ~35 panels, rendered brush sphere sprites, our Head sculpt in grey) with our features in every slot; plus two reference frames of the real screenshots. 16 key screenshots saved in /mnt/project-files/notes/zbrush-ipad-shots/. Mock only, no app code changed.
- 2026-10-26 ~20:30Z: Bolt said "lets implement the ui". Build plan doc https://claude.ai/artifact/JMYFsps6688BZQfKDZQJW6; final mock is board ZBrushFinal (canvas launch) on the same canvas. 7 phases as PRs into odin-sculpt from thread "Mock ZBrush for iPad layout 1:1": 1 Studio theme (grey, accent #F2A33A, beside Graphite) + top bar, 2 left brush bar, 3 right view bar, 4 bottom toolbar (dock pages), 5 modifier wheel (replaces rail), 6 palette tray (replaces inspector), 7 navigation head. Defaults chosen: new layout replaces old; our Lucide icons, our names; only real features; tap acts, long press opens settings. Details in [[ui-zbrush-build]].
