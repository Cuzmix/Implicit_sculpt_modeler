# UI review round 0 (baseline, build 9aed751 + phase 0), 2026-11-04

Three sm-ui-critic judges (Claude, fresh context, no target given), 9 screens, references: ZBrush for iPad, Nomad, Uniform.
Raw scores: round0-scores.txt. Mean per category over all screens:
Clay first 6.6 · Hierarchy 6.5 · Typography 6.7 · Iconography 5.7 · Colour and contrast 6.1 · Spacing 6.8 · Consistency 6.1 · Touch and pen 6.3.
Lowest screen: model@tablet-lens 5.6; highest: sculpt@desktop-lens 7.0.

## Merged ledger (judges agreeing: A B C)
| id | sev | finding | judges | phase |
|---|---|---|---|---|
| L1 | blocker | Model shelf: nine tools share one glyph | ABC | 2 icons |
| L2 | blocker | Model shelf lit and Extrude chosen while the toast says there is no cage | BC | 3 |
| L3 | should | Shelf labels cut at 1180 pt (Smoo..., Reme..., Dynto..., Cylin...) | ABC | 1 |
| L4 | should | Brush glyphs say nothing; Clay, Layer and the Layers card share one; use Library previews | ABC | 2 |
| L5 | should | 3-5 different selected looks (fill, outline, grey pill, rail fill, orange outline) | ABC | 1 |
| L6 | should | Accent misused: primary buttons, links, slider fills, orange Model tint as a second accent | ABC | 1 |
| L7 | should | Disabled buttons about 2:1; disabled Delete still tinted red | ABC | 1 |
| L8 | should | Object menu labels start at two x positions | ABC | 1 |
| L9 | should | Unlabeled rail, dial and the object menu's icon row on touch | ABC | 4 |
| L10 | should | Small drawn targets: shelf page chips 24 pt, help ?, pin/close 28 pt | ABC | 4 |
| L11 | should | Dock resize corner arcs read as loading spinners | ABC | 1 |
| L12 | should | Developer readout (GPU ms, MB) on by default at about 3:1 | ABC | 3 |
| L13 | should | An open card covers the navigation gizmo | ABC | 3 |
| L14 | should | Tool card repeats Size/Strength three times; equal-weight section headers | ABC | 3 |
| L15 | should | Mesh card states the level three times; counts disagree (40k, 41.0k, 81k tris) | ABC | 3 |
| L16 | should | Search: greyed rows ranked high with no reason; loose fuzzy matches; ALL CAPS footer | ABC | 3 (caps: 1) |
| L17 | should | Library "Search 706" vs All 45 | ABC | 3 |
| L18 | should | Paper: white chrome brighter than the clay; slider thumbs and chosen segment about 1.3:1 | ABC | 1 |
| L19 | should | "Put on a bar" vs "onto the shelf": one word | A | 3 |
| L20 | nit | Keyboard hints shown on a tablet with no keyboard | ABC | 4 |
| L21 | nit | Colour section shows a hex code instead of a swatch | C | 3 |
| L22 | nit | Size/Strength island stays in Model where nothing uses it | BC | 3 |
| L23 | nit | Sculpt-mesh tag shown on desktop, not on tablet | BC | 4 |

## Phase 1a (PR after #631), rounds 1-2
- L5 selected looks: fixed (tabs, list rows, picture rows, library cards, object chip warning no longer a ring). Model's orange space tint kept: it is the space-tint system (Bolt's); 3 judges flagged it as a second accent -> asked Bolt.
- L6 accent misuse: More options link fixed; primary Solid accent buttons kept (declined: "too grey" lesson; one primary per panel).
- L7 disabled: fixed (disabled_ink ~3:1, no tone, hairline only, no fill).
- L18 Paper: knob hairline, wells 1.3:1, selected tint deeper, readout inks over the dark view fixed; Paper chrome brighter than clay: declined (a light theme is light).
- Contrast tokens: hints 4.5:1, wells 1.3:1 in all themes; Graphite on_accent 5.8:1; audit contrast_fails 8 -> 0.
- New/held follow-ups: library iconography mean 7.8 -> 7.0 with no icon change (judge noise); search disabled rows ranking (phase 3); viewport readout default (phase 3).
