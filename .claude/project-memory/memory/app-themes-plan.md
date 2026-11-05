---
name: app-themes-plan
description: 2026-10-31 thread "Plan custom app colours and themes": theme editor mock approved, built as 3 PRs #455 #458 #463, all merged 2026-10-31
metadata:
  type: project
  modified: 2026-10-31T19:05:26.491Z
---

Bolt 2026-10-31 18:58 asked to let users customise the app's colours and theme, plan the UI first with an HTML mock (Bezier curves went to a separate thread).

- Today: Settings > Interface > Look picks one of three fixed `ui.Theme` constants (Lens default, Studio, Graphite; `Look` enum in kit_bars.odin, THEME_* in src/ui/theme.odin).
- Mock (interactive): https://claude.ai/artifact/Tvc6Fyhf1at2fG8UzzWTXo, source /mnt/project-files/ui-direction/themes/src.html (icons.js spliced at /*ICONS*/ into themes.html).
- Design: gallery of themes (Lens, Studio, Graphite + new Paper light, Midnight pure black, High contrast, then user's "Yours"); Dark/Light/Match device with Day and Night themes; accent swatches + any colour + device accent (off) + clay-hue warning; Soft/Solid chosen tile; sliders Tint, Tint strength, Contrast, Panel opacity; Corners; Pure black; Panel shadows; folds: Space colours, Viewport marks (mask/selection/wireframe, Bring background off), Every colour (all tokens, search, reset); contrast check (WCAG 4.5/3); editing a built-in starts a draft with Keep/Undo; Hold to compare; Share/Import as readable `sculpt-theme 1 ...` code.
- Under the hood: `Theme_Seed` + pure `theme_derive` in src/ui; existing three looks stay exact constants; settings lines theme, theme_day, theme_night, theme_match_device, user_theme; light theme needs hard-coded colours (13 app files) moved onto tokens first.
- Build order proposed: 1 seeds+derive+new presets, 2 Look page, 3 your themes/share/every colour/contrast check, 4 viewport marks, space colours, device accent.
- Open questions with defaults: theme carries viewport background only with Bring background on; space colours editable under one fold.

**Status:** done 2026-10-31 (3 PRs merged). **How to apply:** follow [[best-of-all-worlds]]; build only after Bolt approves.

- 2026-10-31 19:15 Bolt: "looks good" = build. Order changed to 3 PRs: PR1 seeds+new themes+Look page **merged #455** (src/ui/theme_seed.odin, src/app/themes.odin; settings lines user_theme/look_user/look_seed/look_match/look_day/look_night; exit stats theme=...). Touch coords are PNG coords (LOOK_CARD_GRAPHITE etc. in touch_check.py). Next PR2: card menu (rename/duplicate/share/delete), Share/Import code, Every colour overrides; PR3: viewport marks, space colours, Bring background, device accent, full gate.
- PR2 merged #458 (card menu, share/import code `sculpt-theme 1 name base words`, Every colour = ui.Theme_Overrides). PR3: space tints + wire + selection tokens (applied only when set by hand, keeps renders exact), Bring background; device accent and mask colour left out (native code per platform; mask is a shader darkening).
- PR3 merged #463: Every colour gains Space_Sculpt/Model/Render, Wire, Selection tokens (wire/selection reach the viewport only when set by hand; Renderer.wire_color folded into redraw keys only when set); Bring its background (look_background). Left out: device accent, mask colour (await Bolt if wanted).
