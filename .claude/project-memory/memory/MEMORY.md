# Optimized Sculpting — project memory

## Working mode (Bolt's standing rules)
- 2026-11-02: app is pre-release, nobody uses it. No backward compatibility anywhere (scene files, settings, layouts, .strokes): a format change replaces the old reader; old v1-35 scene readers and settings migrations deleted #504, AGENTS.md rule changed (no-migration-before-release.md).
- Threads work autonomously and self-merge PRs into odin-sculpt (never master), assigned to Cuzmix; don't park on questions, pick defaults and summarize. 2026-11-06: Bolt confirmed self-merge is allowed; this replaces the 2026-11-05 evening "don't merge, keep it on your branch" told to the UV and Pelz threads (self-merge.md).
- Never start GitHub Actions (Input tests, iPad build) unless Bolt asks; test locally (no-github-actions.md).
- 2026-11-06: run gate.py (full, or --changed per PR of a series) on Bolt's Linux laptop, where agents now work; this replaces the 2026-11-02 "Bolt runs the gate on his PC" rule, which was about 30-minute cloud runs (gate-on-bolts-pc.md, gate-per-pr.md).
- Be very careful with performance-critical changes (frame pacing, latency, culling): Low latency now Off by default (#465+).
- 2026-11-03: sculpting performance must NEVER degrade: no feature may add a hitch/pause to strokes (#591). Time stroke start/end/undo for anything touching sculpt paths.
- Take the best of all apps (ZBrush, Nomad, Blender, 3D-Coat, Marmoset...) in every design, ZBrush iPad layout as the base; compare credible candidates side by side (best-of-all-worlds.md).
- When a pain point recurs, build the skills/scripts/fixes that remove it; aim for professional quality.
- Bolt welcomes pushback/debate on his asks (2026-11-01).
- One UI per thing: every entry point draws the same card, never two panels for one feature (one-ui-per-card.md, 2026-11-02).
- 2026-11-04: keep removing what isn't needed; refactor for consistency; keep UX/UI simple (one layout per space + saved layout stamps).
- 2026-11-05: Bolt wants mocks for UI redesigns to pick from before building.

## Bolt and devices
- iPad Air M2 (sideloads), OnePlus Pad (Mali-G710), Windows PC with RTX 3060 Ti. 2026-10-31: app tested on all three, works.
- Goal: performance to match ZBrush (bench 500k-10M; <1 ms GPU up to 10M on the 3060 Ti; next frontier 20M+).
- 2026-11-05: iPad build run on odin-sculpt at #679 (Bolt asked); later merges (#681+) not in it.
- 2026-11-06: Claude Code also runs on Bolt's Linux laptop with a real GPU (Radeon 890M, RADV; Ryzen AI 9 HX 470, 24 threads): there the app, smoke, touch_check, bench and gate.py run for real (local-machine-real-gpu.md).

## Stack and repo
- Odin, SDL3 for windows/input, own Vulkan/Metal/WebGPU backends in package src/gpu (#589); G1-G7 GPU abstraction plan (notes/gpu-own-model/design.md), G5c skipped, G6 recommended skip, awaiting Bolt. Own UI kit, Lens is the only layout (#275).
- github.com/Cuzmix/Implicit_sculpt_modeler branch `odin-sculpt`. Cloud threads built on Linux with SwiftShader/lavapipe; local sessions run on the real GPU (local-machine-real-gpu.md). Touch scenarios offscreen (touch-check-offscreen.md). Worktrees: one per task beside the repo, with deps symlinked; .gitignore ignores `/deps` in any form since 2026-11-06 (sculpt-worktrees.md).
- Container can't download GitHub release files or dl.google.com unless Network access allows it.
- Scene file: chunks (SCEN, OBJ , CURV), current version only, no version branches until release (#504); v50 after curves.

## Vetoed or parked (don't re-suggest without Bolt)
- AI features skipped; LAN live co-editing vetoed (one-shot scene Send is wanted); Blockout JSON import parked; ZBrush fake-3D parked; no DirectX 12 backend.

## Plans and reports (all built unless noted; details in the named files)
- Early features and perf #1-#48: sculpt-*.md files.
- UX roadmap phases 1-7 #50-#152 (sculpt-registry.md, sculpt-phase7.md...); Luau plugins #161; UX research https://claude.ai/artifact/AqPLtN7YQEq9MMCTKQNymy.
- ZBrush-iPad UI: hierarchy https://claude.ai/artifact/GXDbfPpR14mwtwb9WbGAbN, gap list https://claude.ai/artifact/GMspYkj46rpUZzLjb1sf61 (ui-zbrush-gaplist.md); next: 14b follow-up ClayPolish/Unify.
- Lens UI https://claude.ai/artifact/HZ7t24kdzBsBZGps8tcar2, round 2 https://claude.ai/artifact/AvrVn5LqUEbNVTt8x8ME7r (ui-direction-lens.md). Figma quota used up.
- UI modes overhaul https://claude.ai/artifact/AdNY9KYVfEXXPeDtgc7xwz, #278-#382 (ui-build-gotchas.md).
- Poly modeling plan https://claude.ai/artifact/FbiAiDoT6wX8dyrMjJYUjx, #248-#270 (poly-modeling-plan.md).
- Voxel sculpting stages 3-8 merged; stage 9 = Bolt's device run (sculpt-voxel-roadmap.md).
- Rendering roadmap https://claude.ai/artifact/YDpGZoj6b964KHvhp9VYrk, stages 1-4 (sculpt-rendering-roadmap.md).
- Native GPU plan https://claude.ai/artifact/SxLRNE3chkX2QR8UUvDXfX, done #430; Metal ray tracing off by default, unverified on device (native-gpu-plan.md).
- Brush engine https://claude.ai/artifact/FWUTVoVJ4chsRmnuNUDMAz, #277-#298 (brush-engine-build.md).
- Apple Pencil Pro plan https://claude.ai/artifact/C8yCo9s7GAVHUstFFcr1Ew; pen gestures by area https://claude.ai/artifact/3hN2875WbW9YgPsti6Pt7U.
- Import formats #308-#329; Remesh/Quad Remesh #358-#376; Keep symmetry switch (keep-symmetry.md).
- Viewport polish #397-#419, report https://claude.ai/artifact/WtzYDHTFw1ZkiYHh8gDUDA; follow-ups asked: nested folders, lossy+tiled EXR, STL/glTF quads (viewport-polish-plan.md).
- Pain-points digest https://claude.ai/artifact/TNxWG76HJuZK9drKDMfdYu, built #428-#435+.
- App themes #455 #458 #463, mock https://claude.ai/artifact/Tvc6Fyhf1at2fG8UzzWTXo.
- Top bar three islands + U1-U12/R1-R3 built #444-#476.
- Pelz Pathtracer study https://claude.ai/artifact/2fqGs7JomNmBRiH8mLxQTq: plan https://claude.ai/artifact/XbF8gpo5XncXTQRoYLfX8M approved 2026-11-05; A1 #702, A2 #703 merged; B1 on branch claude/project-thread-072t81 (ae2a7d5), unmerged; B2-E on hold. Its stage E (materials) is taken over by the render materials plan (pelz-pathtracer-study.md, render-materials-plan.md).
- 25M-polygon sculpting: built #442-#450; open: Mali GPU-cull numbers, Metal cull, packed normals https://claude.ai/artifact/AvDakDd6t9znNrUjjrARvT (perf-25m-study.md).
- Bézier curves (Nomad-style) 13 PRs #453-#474, untested on tablet https://claude.ai/artifact/BnWpcs912G7Vtrcb6K122Y (bezier-curves-build.md).
- Blender-as-engine: answered no (blender-engine-question.md).
- Surface space (UV, texture paint, shader graph): plan https://claude.ai/artifact/GvRMYf6uCFT8KGXT2Twwep, split-view https://claude.ai/artifact/Rm5R6Yi89MiR6CG7MRfmxe, docking https://claude.ai/artifact/PhtFwCVdgKqMcKbg5awvHb; UV merged #559-#572 and #704-#720 (Unwrap row mock C https://claude.ai/artifact/NctPzXiK1NXc994g5T615t), texture paint #725-#748; shader graph not built; uv_check.py against Blender never run (surface-uv-build.md).
- Rail groups + lights: plan https://claude.ai/artifact/6q6XCT1Q3oQ1gu9X8fFpkv; cards pop out everywhere #590.
- Cleanup sweep 2026-11-03 (notes/cleanup-2026-11-03/report.md); open: C7 mini view naming, C8 display-link trial needs iPad run.
- Web (WASM): whole app in browser on WebGPU #522 (web-wasm-build.md).
- Uniform (Sparseal) study https://claude.ai/artifact/HrYcx5dkE9EKrRifEDWYsE; round 2 awaiting Bolt (uniform-study.md).
- Detail skin plan https://claude.ai/artifact/8HFKdC1pNjc5Ynh6pGHagf, all merged; auto-add off #591 (detail-skin-plan.md).
- Docks + Cards redesign mock https://claude.ai/artifact/Gd91mHtFYV58iqmKnK6ZNf, merged; open: merge Edit mode's old Library sheet into new Library? (docks-cards-redesign.md).
- GPU-resident sculpting 20M+ https://claude.ai/artifact/WgXMUpaNXKbQHNbyMwB75j, P1-P7 merged, awaits device runs (gpu-sculpt-plan.md).
- Quad Remesh at ZRemesher quality: AutoRemesher core ported to Odin, C++ deleted #644, src/sparse solver, 1M 2.6 s vs C++ 16.4 s; plan done #673; engines Flow/Fast #679, both kept while Bolt tests (autoremesher-odin-port-results.md, zremesher-plan.md).
- Send scenes tablet <-> PC: https://claude.ai/artifact/2KC4kvCGQ4uj6bLZGjPpbC, all merged, awaits device run (send-scenes-plan.md).
- Remesh to DynaMesh level https://claude.ai/artifact/GMgjv5FvEkPiHiz4SexY27, built; sharp edges parked (remesh-dynamesh-plan.md).
- Cloth and physics brushes https://claude.ai/artifact/CPv7XBVvWcZ13GxbvpEfUy; #557 #560 #565 #567, Physics card #730, presets #732, coarse level #737, proxy #744, rope on curves #745 merged; PR7 GPU kernels deferred until Settle proves slow (physics-brushes-plan.md).
- Docking DK1 tabs #568, DK2 Texture tab #571; DK3a parked as an uncompiled patch, DK3b not started (docking-dk-build.md). Paint layers PT1a #569, PT1b finished as #725 (paint-layers-build.md).
- Panels+docks from scratch: review https://claude.ai/artifact/RsfEHZKMGNA5Awi5EA7fDm, mock https://claude.ai/artifact/1hGzEd2pmaZD6KULbE31LW, all merged by #625, motion #628 (panels-v2-plan.md).
- Dense remesh memory crash plan https://claude.ai/artifact/9mmo3S83hHYZ8HBsaE1dMs, merged #617-#670 and #735 (old object released first when memory is short), PR5 skipped; BLOCKED on Bolt: build #735 for the iPad, remesh to 15M twice, send sculpt-log.txt (dense-remesh-memory-plan.md).
- Look pad plan https://claude.ai/artifact/7B85zKHpkeQE7BSxaQEgB1: Bolt chose the lighter version after critique; #738 four looks (Clay, Lit, Full, Flat), #749 a look per context (look-pad-plan.md).
- View gizmo styles #616 (view-gizmo-styles.md).
- UI/UX upgrade (T3 video) report https://claude.ai/artifact/45W86UmLQX1Sd7dHFcMeoy; sm-ui-review skill; merged #631-#687, #741 #747 #750; critic score 6.3 to 6.91 against a target of 8 (ui-ux-t3-upgrade.md).
- Reference images plan https://claude.ai/artifact/LMXDdcQdwqqm63VUEkBZMm, R1-R6 + card A #684 merged; resizable cards mock https://claude.ai/artifact/WaVnjtxYDSrdjEzujryjpY awaiting pick; next R5b (reference-images-plan.md).
- Modifiers (Live stack) https://claude.ai/artifact/AsztZy5PHcrx6eSmmeyGNS, #662-#681 merged; card A #685; view handles #689; Apply this row and Search #733 (modifiers-live-stack-plan.md).
- Gizmo/pivot/input fixes plan https://claude.ai/artifact/SbcPS7g7B6ymSZgqvVsctN (gizmo-pivot-input-plan.md).
- 2026-11-05: UI scale to 60% + shadow strength done; saved layouts stamps #690; pen keeps to active object #694.
- Curves in 3D space https://claude.ai/artifact/DL4BbVKsirEBDdqmirxww8, #691-#700 merged, awaiting tablet run (curves-3d-space-plan.md).
- Brush icons 2026-11-05: glossy 3D-render style (grey ball + coloured effect, round tiles), all 18 in notes/icons/glossy/ (ray2.py renderer, README), in app #701 (assets/brush_icons/ PNGs); open: Trim vs Flatten look alike, icons small on shelf.
- 2026-11-06 Whole-app gap list (beyond modelling) https://claude.ai/artifact/BMtDJHh2h7ktUM7e5MDLPQ, with what to run on a real GPU: notes/app-gaps/gaps-2026-11-06.md (app-gaps-2026-11-06.md).
- 2026-11-06 Modelling gaps vs ZBrush/Blender #711-#724 (selection, snapping, Measure, exact cage booleans, Live stack Deform/Displace/Curve/Wrap/Sharp edges, Panel loops); dyntopo wireframe crumple #716; matcaps like ZBrush #727, Grey clay default #743 (A/B cavity and Transition slider promised, not built).
- 2026-11-06 Innovation picks: Tap to find #752, Dial back #754, Hover preview #755; Live strokes design only, Onion skin not picked.
- 2026-11-06 local sessions: stale tests and try_it #756, Android save and export to a picked file #757, 37 touch scenarios fixed with jobwait/jobhold ui-events #758, shading menu fits #759, GPU strokes land deterministically #760.
- 2026-11-06 Render materials plan (Series E, then O) approved, worktree ../sculpt-render; E1-E3 in PR #761 (render-materials-plan.md).
- 2026-11-06 What waits on Bolt (device runs, blocked items, unanswered picks), from the study of the exported threads: open-decisions-2026-11-06.md.
