---
name: sm-figma-ui
description: Designing interface work in Figma and carrying it into the native kit — first checking whether the Figma connector's tools (mcp__Figma__*) are really there and what the account may do, then the project's "Sculpt UI" file (components and variants mirroring src/ui, the Lens tokens of theme.odin, desktop and tablet frames), states, 48 point touch targets, window sizes and motion notes; a handoff spec in tokens and points; building it with the kit (never web technology); and a side-by-side check of --dump-screen against the frame, with the differences recorded. Without Figma access, the same workflow on specs, screenshots and component inventories. Load for ANY task that designs, redesigns or reviews a screen, panel, control or icon, or starts from a Figma link or frame, e.g. "design a better brush panel", "mock up the settings screen", "implement this Figma frame", "does the panel match the design?". Requires sm-ui; touch targets and store rules are sm-store; testing touch behaviour is sm-touch-testing.
---

# Figma UI design

Figma is where a new screen or control is agreed before it is built; the kit (`src/ui`) is where it is real. The two
stay in step through the tokens: every colour, size, radius, type size and duration in a design is a `Theme` field.

## 0. Check access before promising anything
- The Figma tools come from the Figma MCP connector, named `mcp__Figma__*`. In Claude Code they may be deferred: load
  them with `ToolSearch` (`select:mcp__Figma__whoami,mcp__Figma__create_session,mcp__Figma__get_metadata`), then call
  `whoami`. No tools, an error, or no plan in its answer: there is no Figma access in this session. Say so and use
  section 6; never write that a file was opened, read or changed without a tool result that shows it.
- `whoami` lists the account's plans and seat. A View seat or a starter plan can limit editing team files; a refused
  write is reported as refused, not retried in other ways. Rate limits apply (the answer links the current ones).
- Follow the server's own instructions, which win over this skill's tool notes: `create_session` with the file key
  before any file tool, its `sessionId` on every later call; load the skills it names before their tools (`figma-use`
  before `use_figma`, `figma-design-to-code` before `get_design_context`, `figma-generate-design` to push a screen
  from code into Figma, `figma-generate-library` for a component library); `search_design_system` before drawing.
- The project file is "Sculpt UI": https://www.figma.com/design/wL91xYDtAQ1RuN2aCy5k4c (file key
  `wL91xYDtAQ1RuN2aCy5k4c`). Its one page holds a Components board (Lucide brush and action icons, Brush tile,
  Icon button, Segment, Switch and Vertical slider with their variants) and two frames of the same layout: Desktop
  (Windows, Linux) 1440 x 900 and Tablet (Android, later iPad) 1366 x 1024. Check with `get_metadata` (no node id
  lists the pages) that it still has what you need: the app has grown past it (the inspector's Object and Scene
  tabs, Settings, Stats and History panels are only in code).
- Bolt approves a design in Figma (or as a spec) before it is built; until then build nothing that depends on it.

## 1. Prepare
- Read README "Interface", the sm-ui skill's layout and widget list, and `src/ui/theme.odin` (`THEME_LENS`, the
  default look, the tokens of the Lens design). Dump what exists now: `--ui-events` to open the panel and `--dump-screen=build/x.png`, at the sizes the
  design must hold (1600 x 900, 1280 x 800, 1366 x 1024; `--width`, `--height`). Open the PNGs and describe them.
- Name the one component or workflow to improve and what is wrong with it for a user, with the screenshot.
- Make an inventory: which kit widgets the design can reuse (`button`, `icon_button`, `tabs`, `switch_row`, `slider`,
  `vslider`, `drag_value`, `select`, `list_row`, `section`, `value_row`, `area`, …) and what is new.
- Write the states and layout rules before drawing: what each control does with a mouse, a finger and the pen; which
  container scrolls; what happens at the smallest window; what is hidden while it is open.

## 2. Design in Figma (only with access)
- Reuse the Components board: instances, not copies; a new control becomes a component with variants named
  `State=Default|Hover|Pressed|Selected|Disabled|Focus` (Focus only where a keyboard reaches it) and `Size=` if it has
  more than one. Bind colours to the file's variables ("Sculpt colours"), which mirror `Theme`; a value with no token
  is a new token to propose, not a one-off.
- Sizes in points, as the kit's: every hit area at least 48 x 48 (`target`), drawn controls 36 high (`control`), rows
  40 (`row`), panels 12 from the window edge (`edge`), radii 6, 8, 12 (`radius_small`, `_medium`, `_large`), Inter at
  the theme's five sizes (11, 12, 13, 15, 17), Lucide icons at 18 in toolbars and 16 in rows. Spacing on the kit's
  steps: 4 and 8 inside a group, 12 between groups (`gap`), 12 to 16 panel padding.
- One frame per target size (desktop 1440 x 900, tablet 1366 x 1024, and portrait or split view when the layout must
  survive them), with the safe area marked on tablet frames. Annotate what a tap, a drag and a scroll do, and motion
  intent in the kit's terms: which duration token (`press_time`, `popover_time`, `panel_time`, …), what eases, and
  "none" for anything a stroke, the camera or a drag follows.
- Draw only what the kit can draw: rounded rectangles, hairlines, circles, polylines, convex fills, text, Lucide
  icons, images, and the soft shadow under panels and popovers. No blur, gradients, arbitrary vector paths or web
  effects; if a design needs one, flag it as a kit change to estimate first.

## 3. Hand off
Write the spec where the work is tracked (the PR body, or a Claude Doc for a larger design), one block per component:

    Component:   <name>, Figma <node link>          Kit: <existing widget(s)> | new widget in src/ui/widgets.odin
    Size:        <w x h points>; hit area <w x h>; padding <p>, gap <g>
    Tokens:      background <Theme field>, text <field> at <size field>, radius <field>, border <field>
    States:      default / hover / pressed / selected / disabled / focus: <what changes, in tokens>
    Input:       mouse: <...>; finger: <...> (tentative in scroll areas; claims sideways or at once); pen: <...>
    Motion:      <what animates, duration token, ease>; nothing on what a drag follows
    Sizes:       <how it lays out at 1280 x 800 and at the smallest window>
    References:  <frame links, screenshots>
    Open:        <questions with a default each>

## 4. Build it
- In the kit and the app only (sm-ui): widgets in `src/ui`, panels in `src/app/kit_*.odin`, tokens only, no literal
  colours or sizes, no new dependency, no web view or web technology. A new widget with logic gets a test in
  `src/ui/ui_test.odin`; anything a finger can drag gets a scenario in `scripts/touch_check.py` (sm-touch-testing).

## 5. Validate against the design
- Dump the built screen at each frame's size and open it beside the frame (`get_screenshot` of the node, with access).
  Check layout, spacing, sizes, tokens, every state (hover with `move`, pressed with a held `down`, disabled, selected)
  and the touch behaviour the spec gives.
- List every difference as intentional (the kit cannot draw it, the layout had to adapt, a better idea found while
  building) or a bug to fix. Record intentional ones in the PR and, with write access, as a note on the frame, so
  the design and the app never disagree silently. With access and approval, update the frame to what shipped.

## 6. Without Figma access
- Say so in the first reply: the work proceeds on specs and screenshots, not in Figma.
- Design in the spec itself: the component inventory, the handoff blocks of section 3, annotated `--dump-screen`
  PNGs of the current state, and a wireframe of boxes with sizes in points (in the doc, or as a page drawn with the kit
  behind a flag and dumped). Bolt reviews the spec instead of a frame.
- When access returns, the spec is what goes into Figma first, before any further building.

## Traps
| You might expect | What happens |
|---|---|
| the connector is there because it was last session | sessions differ: check `whoami` every time before saying anything about Figma |
| `get_metadata` gives enough to build from | it is the structure only; `get_design_context` (after loading `figma-design-to-code`) gives the reference, which is adapted to the kit, never pasted |
| design-to-code output is code to use | it is web-shaped (React, Tailwind): read it for sizes and tokens, then write kit calls |
| a 40 point button is fine on desktop | one layout serves every device: hit areas are 48 everywhere (sm-store) |
| the Figma file is the whole app | it covers the main screen and the core components; newer panels exist only in code until someone draws them |
