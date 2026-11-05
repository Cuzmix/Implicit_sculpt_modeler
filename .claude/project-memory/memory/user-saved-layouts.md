---
name: user-saved-layouts
description: 2026-11-05 Bolt asked to let users create their own layouts; status of that ask and the options offered
metadata:
  type: project
---

2026-11-05 Bolt (thread "Let users save their own layouts"): "allow the user to create their own layout... I don't see an option to add a layout."
Checked at af03b4e: no saving exists by design since PR E #622 (one auto-kept layout per space, amber dot, Reset layout; src/app/layouts.odin).
Offered via decision card: (rec) saved layouts as stamps (Save layout as… + list in the space menu, picking loads into the current space), my default per space, custom spaces, leave as is. Bolt picked stamps 2026-11-05 and asked for a mock first: https://claude.ai/artifact/AtF2xnCokWyoYCQdCKRTCw (source /mnt/project-files/notes/saved-layouts/mock.html): menu rows load into current space (Undo toast), tick on match, ⋯ Update/Rename/Delete, Save as… with Replace on name clash. Bolt OK'd the mock; built and merged as #690 2026-11-05 (LAYOUT_SLOTS 16, Layout_Load command per slot, layout_saved settings lines, script layout_save NAME / layout_load N). Untested on tablet.
Related: [[panels-v2-plan]].
