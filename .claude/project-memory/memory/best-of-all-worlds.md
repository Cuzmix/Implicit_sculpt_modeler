---
name: best-of-all-worlds
description: Bolt's standing rule (2026-10-27): every feature takes the best of all apps (ZBrush, Nomad, Blender, 3DCoat, Marmoset...), not a 1:1 copy of one
metadata:
  type: feedback
  modified: 2026-10-27T09:16:52.776Z
---

Bolt, 2026-10-27 09:16Z, on real 3D lights: "remember to take best of all worlds", then "don't limit it to lights too I mean everything too".

**Why:** ZBrush for iPad is the model for the layout and look (see [[ui-zbrush-gaplist]]), but Bolt wants each feature's behaviour to be the best of every app that has it, not one app's version.

**How to apply:** before designing any feature (lights, home screen, files, geometry/deform, parked systems, anything new), look briefly at how ZBrush, Nomad, Blender, 3DCoat and other relevant apps (Marmoset, Substance, Forger...) do it, and say in the design which part comes from which and why. Keep the ZBrush-for-iPad layout as the base for where things sit. Brand names stay out of the app's UI (the Help glossary may name them).

2026-10-28 (Bolt, on the real-time render plan): "straight up copy the same techniques they do", and where we know a better way, do that; "what they did wrong, we avoid; what they did right, we take and do better". **How to apply:** designs name each source technique, its known weak spot, and what we do instead (see render plan https://claude.ai/artifact/PPSMxjSsYTUZfkVnufnTdL, section "What we copy, what we avoid, what we do better").

2026-11-03 12:01 (Bolt, after MRGB was researched and cut): "avoid dated design and opt for more modern design choices and philosophy; we should also strive for better and modern optimized solutions". **Why:** ZBrush's MRGB turned out to be a 1999 palette-index design; Bolt does not want familiar-but-dated behaviours copied. Caveat learned 2026-11-03 12:30: separate the NEED from the dated MECHANISM. Multi-channel strokes are current (Wafer 2026 does them); only the material index was dated. Check the newest tools (Wafer, CozyBlanket Pro, Uniform) before calling a behaviour dated, and correct yourself openly when wrong. **How to apply:** for every borrowed behaviour, name the reason the source had it and keep it only if that reason still holds on our stack (tablets, GPU compute, 20M+); prefer continuous values, non-destructive/live, sparse and GPU-resident data, touch first, one implementation per thing reached from wherever it helps ([[one-ui-per-card]], 2026-11-06); every design carries a budget and the compare table (Taken from / Why it still holds / Avoided / Done better). The repo skill `sm-design` (.claude/skills/sm-design, #553 merged 2026-11-03) holds the full rule and is loaded for any design, plan, mock or tech choice; "should we have X like app Y" gets the need behind X, the modern way to meet it here, and a plain verdict.

2026-11-03 12:02 Bolt: "Push back if I suggest any design choices that could be dated and give me reason why". **How to apply:** push back unasked in the first reply, with the era constraint behind the suggestion, its cost here and the modern replacement; then build the modern version unless Bolt keeps the ask.
