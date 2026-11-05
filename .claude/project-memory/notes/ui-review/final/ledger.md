# Final critic rounds: ledger (2026-11-05)

Three Claude critics each round, 14 screens x desktop/tablet, Lens theme. Scores in
scores-round-final.txt (round 1) and round2-{A,B,C}-scores.txt.

| Round | Mean | Clay | Hier | Type | Icon | Colour | Spacing | Consist | Touch |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 6.73 | 7.21 | 6.83 | 7.12 | 6.35 | 6.60 | 7.02 | 6.18 | 6.49 |
| 2 | 6.91 | 7.18 | 7.10 | 7.36 | 6.35 | 6.80 | 7.11 | 6.53 | 6.85 |

## Round 1 findings fixed (PR after #660)
- History card opened over the view toolbar: cards under a top-bar button keep between the side bars.
- Render shelf labels cut off: one-word shelf labels (Final, Focus, Snapshot, Turntable, Split, HDRI, Highlight); the dial uses the same short words.
- Model's cage actions lit and enabled on a sculpt mesh: dimmed unless a cage or curve (or nothing) is selected.
- Two Mask glyphs: one venetian-mask glyph on the brush, the Mask card, history and the dial.
- Favorites/Favourites: Favourites everywhere.
- View info faint lines under 3:1: raised.
- COMMON caption heading only the brush row: sections within a group part by space, not dividers.
- Stray pane-corner bracket over cards: corner handles under a card are hidden.
- Tablet corpus showed key hints: ui_shots runs the tablet size with --no-keyboard.

## Round 2 findings fixed
- Mask card told a keyboardless tablet to Ctrl + drag (blocker, all three): names the dial's Mask instead.
- Model shelf drawn enabled on a sculpt mesh (all three): dimmed (above).
- Dial label "Pick focus" ran off the screen: short words.

## Tried and reverted
- Card title repeated as its first section ("Mask"/"Mask", "Look"/"Look"): showing that section bare took away
  folding the Look card's Look section, which the Render workflow uses to reach Lights. Kept the header.

## Declined
- "24 pt targets": the kit grows every hit area to 48 pt.

## Open, for Bolt (taste or larger changes)
- Accent on primary action buttons (Subdivide, New layer, Quad Remesh): all three want accent for state only and a neutral strong fill for actions.
- One selected look: tinted fill + accent text everywhere (history row outline, theme tile outline, render shelf accent text differ).
- Brush icons that show the effect (shaded swatch or library thumbnail crop) on the shelf; library thumbnails that tell Clay/Draw/Inflate apart and a Smooth tile that reads as smoothing.
- Help lines cut with an ellipsis: wrap to two lines or one About row per card.
- Tablet: collapse the labelled rail to icons while a card is open (rail + card = 37% of 1180 pt).
- Shading twin: Shading_Menu vs Pass_Menu ("Solid" in the view head and on the Render shelf).
- One noun for the shelf ("Put on a bar" vs shelf), one unit for mesh size (41k vertices vs 82k tris), sentence case "Quad remesh".
- Search fuzzy matches ("smooth" lists Size, Skew, Noise); command rows share one wand glyph.
- Object menu's unlabeled icon row on touch; two near-identical frame glyphs.
- Hide the Size/Strength column in Render; page chips under the shelf (24 pt) near the shelf's targets.
- Menu: Save a copy and Earlier saves reuse Save and Open recent glyphs.
- History transport buttons not all dimmed at Step 0 of 0.
