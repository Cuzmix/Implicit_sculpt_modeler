# Round 2, PR 10: Inspect and Studio (design)

This PR covers screens `inspect2` and `studio2` of the approved round 2 mock, in Lens chrome only. It is built as two PRs:

- **10a: Inspect**, the pass popover and the Inspect workspace.
- **10b: Studio**, the Lights, Material and Environment stack cards and a render mini view.

## What the app has already

- Passes (#213).
- Wipe compare, with a draggable line.
- Hold the chip, or the backquote key, to peek at the last pass.
- Four panes with linked and free cameras (#215 to #225).
- Light markers in the view with move handles (#177, #189).
- The render preview pane (#224).
- The thumbnail window.

## What differs from the mock

- **Inspect:**
  - Inspect opens floating Statistics, Camera and Look panels over the panes. The mock shows only the panes and the rail.
  - The pass list is flat. The mock groups it into RECENT, SHADING and DIAGNOSTICS, with each pass's key, and puts the shading looks next to the diagnostic passes.
- **Studio:**
  - The Lights, Material and Environment sections are old floating panels, each with a minimise and a close button. The mock has them as stack cards:
    - Lights: one row per light, with its colour and "5200 K · 3.0"; the picked light opens Intensity and Size.
    - Material: preset spheres and Roughness.
    - Environment: folded to its name.
  - The corner window shows a silhouette pane. The mock shows a render that keeps refining ("Render · 64/256").

## 10a: Inspect

### Pass popover (`kit_pass_menu`, Lens)

The popover has three groups:

- **RECENT:** the pass shown now and the last other one (`ps.last`), when the two differ.
- **SHADING:**
  - Shaded.
  - The looks: Sculpt studio and Classic (`Viewport_Look`).
  - Flat shading.
  - Render, which is the Studio render switch.
- **DIAGNOSTICS:** Normals, Curvature, AO only, Depth and Silhouette.

How the rows behave:

- Each row has its icon and its keys from the registry (`command_menu_item`), so Alt+1 to Alt+6 show beside the passes.
- The mock shows a single letter on each row. While the popover is open, the first letter of each diagnostic pass picks it: N, C, A, D, S. Those letters belong to the popover only and are not bindings.
- **Last pass** and **Wipe compare** stay under a divider.
- The hint line becomes the mock's "Hold a pass chip to peek at your last pass · release to come back."

Classic keeps the flat list.

### Inspect workspace

- The built-in layout loses its floating Stats, Camera and Look panels. They stay a tap away on the rail and in Search, and the four panes get the whole window.
- The layout keeps hiding the brush bar and the dock (the shelf and the sliders). The dial stays.
- The panes follow the mock: the main pane is Shaded, pane 1 is Curvature, pane 2 is Normals, and pane 3 is a Front silhouette. AO depends on the GPU, and a silhouette is a fair stand-in for the mock's close-up.
- Older saved Inspect layouts keep their panels. Only the built-in default changes, and Revert to built-in gives the new one.

### Pane chips

- A pane's camera chip says "Persp · linked" or "Front · free". The dot is teal for linked and violet for free, as in the mock.
- Today the chip says "Linked" with no camera.

### Tests

- The Lens popover lists RECENT only when there is a last pass.
- A typed letter in the popover picks that pass.
- The built-in Inspect layout has no floating panels.
- Touch scenario `lens_pass_popover_letter_picks`: open the popover, type `d`, and check that the pass is Depth.

## 10b: Studio

### Stack cards that a workspace can leave out

- `Stack_Card` gains **Lights**, **Material** and **Environment**.
- A stack line can leave a card out with a `-Card` word, and the stack then hides it.
- A fresh layout hides the three new cards, so Sculpt is unchanged.
- The Studio built-in stack line is `stack Lights+ Material+ Environment -Brush -Symmetry -Layers -Scene -Tools Palettes`, so its stack shows the mock's three cards and Palettes. Its floating panels go.
- Opening one of the three sections (from Search, or the rail's Lights button) shows its card and opens it, wherever the user is.
- A card's More menu gains **Hide card**.

### Lights card (`lens_lights.odin`)

- **Rows:** each light has a colour dot (`light_rgb`), its name, and on the right "5200 K · 3.0", or "3.0" for a light with no colour temperature.
  - A tap on a row picks the light.
  - The picked row is tinted and holds **Intensity** and **Size**. Size is Angle for a sun and Radius for a lamp, with the same ranges as the section.
- **Add light:** adds a point light.
- **Lights follow the camera:** switches every light's space, through `lights_fix` inverted.
- **More options:** the full Lights section's kind, colour, distance, cone and delete, which sends the user to the Palettes section.
- A whole drag is one undo step, as in the section (`light_drag_changed`).

### Material card (`lens_material.odin`)

- The material presets as spheres (`ui.fill_ball`), five across, with the picked one ringed. A tap puts the preset on the selected objects, as the Material section's list does.
- A "+" at the end opens the Material section in Palettes, for custom materials and packs.
- **Roughness** sits under the spheres and edits the selected object's material, as one undo step a drag.
- The header line names the material.

### Environment card

- Draws the Environment section as it is. The header line says "Studio soft" or the image's name.

### Render mini view

- In Studio, the thumbnail window shows the Render preview: the render pane's refining path trace, with its sample count ("Render · 64/256") on its chip.
- This uses the render preview pane's view kind in the thumbnail window, which `grid.odin`'s `Render_Preview` already draws in a pane. If the thumbnail window cannot host it without a second render target, it shows a fourth pane instead. The as-built note will record which.

### Tests

- A stack line with `-Brush` hides Brush and reads back.
- A fresh layout hides the three new cards.
- Opening the Lights section shows its card.
- The Lights card's picked-row Intensity drag is one undo step.
- A tap on a material sphere puts that preset on.
- Touch scenarios: `lens_studio_stack_shows_lights_material_environment` and `lens_lights_card_picks_and_adds`.

## 10a as built

Screen: `screens/round2/pr10a-inspect-pass-popover.png`. It shows Inspect with no panels over its four panes, the pane chips reading "Persp linked" and "Front ortho", and the popover grouped into RECENT (Curvature, Shaded), SHADING and DIAGNOSTICS.

- **Popover letters dropped.** The popover leaves out the one-letter picks. N, C, D and S are already app-wide shortcuts for brushes and tools, and popovers do not take keys. Each row shows its registry keys instead (Alt+1 to Alt+6, Shift+G, Shift+R).
- **SHADING rows.** The Looks and Flat shading are ticked rows. Render is the Studio render switch.
- **RECENT** shows the current pass and the last pass, as two rows, only while they differ.
- **Free camera chip.** A free pane's chip says "Own camera free". Free is the app's name for a pane's own camera.
- **Tests.** `inspect_built_in_opens_no_panels` and the touch scenario `lens_pass_popover_groups_the_passes`. I also updated `the_current_workspace_comes_back`, because Inspect now has no left column.

## 10b as built

Screens: `screens/round2/pr10b-studio-stack.png` (Studio as it opens) and `pr10b-studio-add-light.png` (after Add light, Material folded). The first shows the stack with Lights open on Light 1's Intensity and Size, Material's nine spheres with Clay ringed and Roughness, and the mini view beside the stack's foot reading "Render · 5/1024".

- **Studio differs by chrome.** `built_in_layout(b, chrome)` gives Lens a Studio of its own: `thumbnail Follow Render`, `open Inspector Thumbnail`, a window line that puts the mini view beside the stack's foot, and the stack line from the design. Classic keeps its pinned panels. Changing the chrome swaps a built-in that is as it comes for the other chrome's (`workspaces_chrome`, run once a frame) and keeps one the user saved. A render-time mapping of the pinned panels was the alternative; it would have needed the stack to show with the tray closed, in several places.
- **Thumbnail line.** A layout can now name the thumbnail's camera and pass. It writes them back only when it named them (`Kit_State.second_in_layout`), so every older layout reads the same as before.
- **Mini view placement.** The mock puts the render beside the stack, not under it. Studio's layout places the mini view there (`window Thumbnail 1 End End 390 112 0`), which gives the stack the column's height.
- **Hide card** is named **Leave out of the stack**. **More options** on the Lights and Material cards is in the card's More menu, as All light settings and All material settings, which open the full section under Palettes.
- **Material card** shows nine presets, after the mock's two rows (`MATERIAL_CARD`), with the one in use always among them.
- **Sample count.** The mini view's chip says "Render · n/total" or "Studio · n/total" while a heavy pass gathers (`picture_samples`).
- **Tests.** `lens_studio_test.odin` (stack line `-Card`, the look cards revealed, Studio by chrome, chrome swap, Material card) and touch scenarios `lens_studio_stack_shows_lights_material_environment` and `lens_lights_card_picks_and_adds`, which covers Add light and the Intensity drag being one undo step.
- **Not done.** On a 900-point-high window, the Environment card's header sits under the fold while Lights and Material are open, so the stack scrolls to it.
