---
name: sculpt-paint-groups
description: Polypaint and polygroups (PR #36, 2026-10-25): what was built, design choices, limits
metadata:
  type: project
---
PR #36 merged into odin-sculpt on 2026-10-25. It is item 1 of Bolt's 7-item production list (thread "Add production sculpting features").

What it adds:
- **Paint brush** (13th brush). Colours are per vertex: RGBA8, where alpha is coverage over the clay. Ctrl erases.
- **Fill and Clear** commands that respect the mask.
- **Polygroups** from Visible, Masked or Creases (35 degree default).
- **Shortcuts:** Ctrl+W groups the masked part, or what is visible when nothing is masked. Shift+W shows the groups. Ctrl+Shift click isolates the group under the cursor (a second click inverts); Alt masks the group instead.

How it works:
- Paint and groups are saved in .sculpt files (SCENE_VERSION 3) and carried between subdivision levels.
- OBJ and PLY export write vertex colours; import ignores them.
- Groups are drawn with no per-triangle GPU data. Each vertex holds the majority group of its triangles, and each triangle's indices are rotated so its provoking vertex carries the group, which is passed as a flat output.

Limits and cost:
- Refused under dyntopo and in HD windows.
- At 10M, the Draw frame is unchanged (about 1.3 ms) and a Paint frame takes 1.03 ms.
- Not tried on Windows yet.
