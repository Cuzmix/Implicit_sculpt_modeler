---
name: top-bar-three-islands
description: 2026-10-31 Bolt chose the three-island top bar (Work group centred) with Settings for islands/one bar and Search icon/field; mock and UI review ideas artifacts
metadata:
  type: project
  modified: 2026-10-31T14:13:03.352Z
---

Thread "Mock three-group top bar and UI ideas" (2026-10-31).
- Mock: https://claude.ai/artifact/5rU785x4pTFsZWY1SmQGv1 (source /mnt/project-files/ui-direction/topbar3/topbar.html). Bolt picked **A: three islands** (File+Undo left, spaces+object chip centred on the window, Search/History/Settings right) and asked to keep user customisation as settings, with the Search field turning into its icon when there is no room and nothing overlapping.
- Built: Settings > Interface > Top bar: Three islands (default, `top_islands`) or One bar; Search as a field (`search_field`, off by default). `kit_top_three` in kit_top_lens.odin: one full-width "top bar" root holding three nested islands (names stay "top bar/..."); give-way order: chip badges, field to icon, chip tag, file block, tabs to layout chip, chip icon, then off centre. Arrange still shows the one bar.
- UI review ideas (U1-U12, R1-R3) for Bolt to pick from: https://claude.ai/artifact/AA1wRnDrE9GsGF1bMyDb2V (sources /mnt/project-files/ui-direction/review-ideas/). Nothing from it is built until Bolt names ids.

- 2026-10-31 14:28 Bolt on the ideas: U5 call the first shelf page "Brushes"; remove the Paint toggle (duplicate of the Paint brush); shelf fully user-customisable per page like the rail (no fixed tools after the divider); All where Paint was. Mock https://claude.ai/artifact/3KUY2ApocWHSNEfWJjL1s3 offers A (All at right, Bolt's) vs B (All pinned at off-hand end, recommended: palm zone); paint-with-any-brush moves to an "Also paint colour" switch in quick settings. 2026-10-31 14:34 Bolt chose **B** and "your recommendations" (Also paint colour switch, starting tiles, old tools appended once). Then asked about the held off-shelf brush island and pinning: mock https://claude.ai/artifact/QhJJohptEskhYP2PBnkc15, recommended option 2 (visiting dashed tile after All inside the shelf, grows toward off-hand side, corner pin; Pin to shelf in quick settings, picker menu, Search; full page asks which to replace).

- 2026-10-31 14:38 Bolt picked option 2; 14:57 "lets do all of it" = build every review idea U1-U12 + R1-R3. Order: PR1 top bar, PR2 shelf B + held brush + pin, PR3 U8/U9/U12/U10, PR4 U1, PR5 R1/R2, PR6 U3, PR7 U7, PR8 U2, PR9 R3, PR10 U6.

**Why:** Bolt wants the centred work group and likes choices exposed as settings. **How to apply:** new top-bar behaviour should work in both styles; offer layout variants as settings. See [[ui-overhaul-build]].

- 2026-10-31 PR2 merged #444: Brushes page, no tools strip/Paint tile, All at off-hand end (mirrored left-handed), visiting tile + pin (corner, quick settings, Search), Also paint colour switch, settings v12 moves old `bottom_tools` onto Sculpt pages. Known pre-existing: left-handed at 1280x720 the shelf's right end sits under the dial. Next: PR3 (U8/U9/U12/U10).
- 2026-10-31 PR3 merged #447 (U8 Save-as icon + scroll foot fade, U9 Add loop/Cut loop tile names, U12 stacked stroke icon tabs `ui.tabs(stacked=)`, U10 safe zone outline only in use; settings v13). Next: PR4 U1 (Size naming).
- 2026-10-31 PR4 merged #449 (U1 Size everywhere, card read-only line while island has both sliders). Next: PR5 R1 Focus uses kit_top_three, R2 settings entries defined once.
- 2026-10-31 PR5 merged #451 (R1 Focus draws kit_top_three(focus=true); R2 narrow Settings tabs = sheet sections via SETTINGS_SECTION_TAB, narrow-only blocks deleted). Next: PR6 U3 (rail labels setting, five default buttons, chevron).
- 2026-10-31 PR6 merged #452 (U3: rail starts Panels+Layout+Passes+Camera+Lights, `rail_labels` Off/Wide(>=1700pt, default)/Always, chevron replaces corner triangle; touch_check `eight_rail()` gives scenarios the old 8-button rail). Next: PR7 U7 (one-line hints, ? popover, "Explain every setting").
- 2026-10-31 PR7 merged #461 (U7: ui.paragraph shows as one-line hint + ? popover while ctx.hints, set in panel_body and settings_block; `explain_all` switch; touch_check --screens also writes .map). Lesson: gate --changed misses scenarios broken by layout shifts; run the full touch suite (in two parts, 90-min tool limit) for any change to cards' layout. Next: PR8 U2 (one View island).
- 2026-11-01 PR8 merged #472 (U2: one View island holds nav head, Camera/Shading chips and customizable View_Island bar slots; rail defaults Objects/Layers/Material). Next: PR9 R3 (Arrange whole islands with snap), then U6 (rendered brush previews), then full gate.
- 2026-11-01 PR9 merged #475 (R3: in Arrange each top island has a grip, work island holds Arrange controls, drag snaps to start/middle/end third and swaps; `top_order` setting, Library "Islands in their places"; vertical edge islands and join gesture not built: edges belong to off-hand island and rail). Arrange scenarios tap At("arrange top bar/Done"). Next: PR10 U6 (rendered brush previews), then full gate.
- 2026-11-01 PR10 merged #476 (U6: sculpt.preview_render strokes each brush on a CPU-rendered strip; app/brush_previews.odin batches all listed slots on a thread into one atlas (KIT_BRUSH_PREVIEWS_IMAGE), 213 ms release; Cloth/History/tools keep the sketch; no PNG disk cache). Series U1-U12+R1-R3 complete; final full gate next.
- 2026-11-01 Final full gate on odin-sculpt after #476: all 9 steps + 789/789 touch scenarios (two halves) pass. Series done.
