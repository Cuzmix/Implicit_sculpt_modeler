---
name: cross-platform-flutter-plan
description: Cross-platform UI decision for the sculpt app: Bolt chose Odin + SDL3 + own UI over Flutter/Qt (2026-10-25); plan doc, measurements, constraints
metadata:
  type: project
  modified: 2026-10-25T12:08:39.053Z
---

Thread "Move sculpt app to a Flutter UI" (started 2026-10-25 as a Flutter plan). Plan doc (Claude Doc): https://claude.ai/artifact/GihFa9ADcNxPmSudjhiWMy

- DECIDED 2026-10-25 (Bolt, decision card): Odin + SDL3 + our own touch-first UI drawn by our renderer, replacing ImGui panels (ImGui may stay as debug overlay). Flutter and Qt Quick were rejected; don't re-propose without new reason. **Why:** only route with one language and the viewport in the same GPU frame as the UI on every platform; Bolt wants "consistent and simple".
- Bolt's constraints: today's ~4 ms input-to-submit latency is the hard line where possible (desktop; Android adds its own frames). Platforms: Windows, Linux, Android tablets now; macOS and iPad later (no hardware). Bolt is not set on SDL but SDL3 is the cheap path to Android (pen API covers Win/Linux/Android); Odin has -subtarget:android and `odin bundle android`.
- Dart test (src/dart_trial, branch claude/project-thread-vwel1p): 10M Draw hot loops on 4-core VM, Odin 1.7-2.1 ms/frame vs Dart 6.5 ms (~3.5x). Core stays Odin regardless.
- Bolt's tablet: "OnePlus tablet" (model unknown: Pad = Dimensity 9000/Mali, Pad 2 = Snapdragon 8 Gen 3/Adreno).
- Cloud env blocks dl.google.com (Android SDK/NDK, Google Maven): Android builds can't run in the container unless Bolt allows that host.

Related: [[tech-stack]], [[bolt-preferences]], [[sculpt-decisions]].
- 2026-10-25: Bolt wants an Apple-UIKit-like clean look (mock-up canvas https://claude.ai/artifact/QvdB7vN2Ecs6DWbJJytiNa, desktop + tablet boards) and store rules enforced for the WHOLE app, not just UI: repo skill `sm-store` (commit 18a4764 on claude/project-thread-vwel1p) holds App Store + Google Play rules and AGENTS.md makes every change check it.
- 2026-10-25 12:35Z: Bolt: keep the UI the same on all OSes and devices for simplicity. One touch-sized (48) layout everywhere, desktop included, scaled by DPI; no separate denser desktop layout. Recorded in sm-store.
- 2026-10-25: Figma connected (Bolt's account samflux, starter team). UI source of truth is Figma file "Sculpt UI" https://www.figma.com/design/wL91xYDtAQ1RuN2aCy5k4c : Components board (brush tile, icon button, segment, switch, vertical slider, icons, "Sculpt colours" variables) + Desktop 1440x900 and Tablet 1366x1024 frames, same layout. Figma MCP can write (use_figma), not just read. Build UI code to match it.
