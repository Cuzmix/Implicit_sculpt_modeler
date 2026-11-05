---
name: figma-access
description: Figma connector limits for Bolt's account (Starter plan, View seat, 20 MCP tool calls a month) and which Figma files exist
metadata:
  type: reference
  modified: 2026-10-27T18:32:20.269Z
---

- Account samflux, plan "samflux's team" (team::1696164863225265978), Starter tier, View seat. Writing to drafts files works (use_figma creates nodes), but the Figma MCP allows only **20 tool calls per month** on Starter/View; whoami, create_new_file, add_code_connect_map, generate_figma_design do not count. Hit the limit on 2026-10-27 after ~20 calls in thread "Explore new UI direction in Figma". Reset date not documented.
- Files: old "Sculpt UI" https://www.figma.com/design/wL91xYDtAQ1RuN2aCy5k4c (one page: Components, Desktop 1440x900, Tablet 1366x1024). New "Sculpt UI — Direction exploration" https://www.figma.com/design/IzPQeqjV84fqOBBMq2wuSB (pages 1 Directions empty, 2 Design system: Lens tokens/text styles/77 Lucide icon components/14 component sets/renders, 3 Workspaces & flows empty).
- 2026-10-29: allowance had only ~2 calls left (create_session + one use_figma read worked, the next use_figma hit the limit). Assume Figma is unusable for the rest of each month once a thread has used it; go straight to HTML mocks.
- Starter drafts allow at most 3 pages per file.

**Why:** calls are scarce; a wasted screenshot costs one of 20.
**How to apply:** batch Figma work into few large use_figma calls, skip verification screenshots unless needed, and fall back to HTML Artifacts when the allowance is gone. See [[ui-direction-lens]].
