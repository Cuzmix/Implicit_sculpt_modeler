---
name: maxon-docs-access
description: How to read ZBrush docs and Maxon tutorials from the container (MadCap TOC trick, iPad docs, Cineversity walkthroughs; YouTube blocked)
metadata:
  type: reference
  modified: 2026-10-28T18:04:44.990Z
---

Found 2026-10-28 (thread "Plan poly modeling like ZModeler"):
- ZBrush desktop docs: https://help.maxon.net/zbr/en-us/ is MadCap Flare. Page list: `Data/Tocs/toc.js` then `Data/Tocs/toc_Chunk0..2.js` (733 pages under /Content/html/...). Plain curl works.
- ZBrush for iPad docs: https://help.maxon.net/zbp/en-us/ (same TOC trick, 193 pages; ZModeler, Retopo brush, modifier wheel, touch gestures pages).
- Maxon "tutorials" = Cineversity (cineversity.maxon.net), a JS site: render with Playwright; the search box goes to /en/results?term=<q>. Each tutorial page has a full written walkthrough with timestamps (good substitute for the video). Don't scrape its search API keys (auto-mode blocked it).
- YouTube (ZClassroom ZModeler videos are YouTube embeds) returns 429 captcha from the container: videos can't be watched; read the doc pages instead.
- 2026-10-28: youtube.com/vimeo.com hosts answer (not a network-policy block); YouTube's bot check and the Shapr3D help centre's Cloudflare check must not be worked around (auto mode denies it as bot-check circumvention). Told Bolt: paste YouTube transcripts ("...more" > "Show transcript"), upload help pages as text/PDF, or screenshots. Changing Network access won't help.
- Local copies were in /tmp/claude-0/mx (gone after the session).

Related: [[best-of-all-worlds]], [[poly-modeling-plan]].
