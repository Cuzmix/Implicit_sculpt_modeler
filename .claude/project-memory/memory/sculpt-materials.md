---
name: sculpt-materials
description: Viewport flat shading toggle and PBR materials (PR #32, 2026-10-25): how they work, where, what is untested
metadata:
  type: project
---

PR #32 merged into odin-sculpt 2026-10-25 (thread "Add flat shading and PBR materials", Bolt's ask).
- View > Flat shading (Shift+G, --flat): face normal from dFdx/dFdy in mesh.frag, zero vertex memory. Far simplified (LOD) chunks show coarse facets while orbiting.
- PBR presets after the classic ones (FIRST_PBR in src/app/material.odin): Gold, Copper, Chrome, Steel, Plastic, Ceramic, Rubber, PBR clay. GGX + procedural studio env + Karis env BRDF + ACES, all in shader. Roughness 0 = classic Blinn-Phong path (pixel-identical to before).
- Custom material: menu sliders copy the current material into app.custom (CUSTOM_MATERIAL index); settings.txt keys `custom_material r g b metallic roughness`, `flat`.
- Look tuned on software GPU only; not tried on Windows/real GPU yet. Follows [[sculpt-polish-oct25]].
