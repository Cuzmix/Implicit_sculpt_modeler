---
name: sm-design
description: How to choose what to build in the sculpt modeler — take the best of every app (ZBrush, Nomad, Blender, 3D-Coat, Substance, Marmoset...) but never its dated parts; keep a borrowed behaviour only when the reason behind it still holds today, prefer the modern philosophy (continuous values, non-destructive and live, sparse and GPU-resident data, touch first, one UI per thing) and the measured, optimised solution, with the compare table every design must carry. Load for ANY design, plan, mock, tech choice or "should we have X like app Y" question, before forming the plan; it does not replace sm-ui (how panels work), sm-perf (how to measure) or sm-store (what ships).
---

# Design choices: modern, best of all worlds, optimised

Bolt's standing rules (2026-10-27 "take best of all worlds, everything"; 2026-10-28 "what they did wrong we avoid,
what they did right we take and do better"; 2026-11-03 "avoid dated design, opt for modern design choices and
philosophy, strive for better and modern optimised solutions", after the ZBrush MRGB idea was researched and cut).

## 1. Survey, then ask why
- Before designing any feature, look at how ZBrush, Nomad, Blender, 3D-Coat, Substance, Mari, Marmoset, Forger and any
  other credible app does it (manuals, and the source where it is open: Blender, ArmorPaint, Dust3D/AutoRemesher).
  Say in the design which part comes from which app. Brand names stay out of the app's UI (the Help glossary may name them).
- For every borrowed behaviour, name the reason the source had it. Keep it only when that reason still holds for us
  (tablets, Odin, own Vulkan and Metal, GPU compute, 20M+ polygons). A behaviour whose reason was a constraint of its
  era is dated and is not copied, however familiar it is. Examples of dated reasons: a per-vertex material index
  (ZBrush's M channel: palettes from 1999), a separate 2.5D canvas, modal tools that lock the view, fixed-pixel
  layouts for a mouse, a bake step before anything shows, shaders compiled on the device, full-size textures per
  layer, 8-bit everything, serial code that assumes one core, file-based round trips where live data works.
- A familiar habit of Bolt's (or the user base's) is still a design input: keep the gesture or the mental model, build
  it on the modern store. "Looks the same in every view mode" is the need; MRGB was one dated way to meet it.

## 2. Prefer the modern philosophy
- Continuous values over indices and slots; non-destructive layers, generators and live masks over baked results;
  one store read by every view (no twin data for Sculpt and Render); sparse data (tiles, bricks, nodes) over full
  grids; GPU-resident work with CPU reference code; deterministic and parallel (AGENTS.md).
- Touch first (ZBrush for iPad's layout is the base), one UI per thing (every entry point draws the same card), no
  mode that hides the model, no second way to do what has a way already.
- Undo for everything a user sees; a format that one build writes and reads (no compatibility before release).
- When a tool's weak spot is known (ArmorPaint's UV-space raster per dab, ZBrush's material index, Blender's
  per-vertex paint with no layers), the design names it under "what we avoid" and says what we do instead.

## 3. Optimised means measured
- Every design carries a budget (ms on the M2 iPad and the Mali tablet, MB at 20M) and names the bench or exit stat
  that will prove it (sm-perf). A solution without a number is a guess.
- Compare credible candidates side by side before a tech choice (library, algorithm, runtime, data layout): cost,
  licence, App Store fit, tablet fit, speed, and what each would make impossible later. Recommend one; never anchor on
  the first.
- Prefer the current state of the art (papers and recent tools) over the technique the oldest reference app uses,
  when it is measured to be better here; prefer the simpler one when the numbers tie.

## 4. The compare table every design carries
| Part | Taken from | Why it still holds | Avoided | Done better |
|---|---|---|---|---|
One row per part of the feature. "Avoided" names the dated or weak behaviour and its source; "Done better" names ours and
the number or the user-visible gain that justifies it. A design with an empty "Done better" column is a copy, and a
row whose "Why it still holds" is only "users know it" needs the modern store under the familiar gesture.

## 5. When Bolt suggests a design choice
Answer with the need behind it, how the source app meets it and why, the modern way to meet the same need here, and a
plain verdict with pros and cons. Bolt asked (2026-11-03) to be pushed back on, unasked, whenever a suggestion could be
dated: say so in the first reply, with the reason (the era constraint behind it, what it costs us, what replaces it),
then build the modern version unless Bolt keeps the ask. "No, because the need is already met by Z" is a good answer.
