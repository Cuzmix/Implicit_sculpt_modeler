# Load and store audit (native GPU plan 4.1, D2), 2026-10-30

Every render pass outside the backends was read, from `grep load_op|store_op src/render/*.odin`. Each was checked for a pass that loads what it clears or fully overwrites, and for a pass that stores what nothing reads afterwards.

**Result: no pass needs changing today.** The only stores worth removing depend on what the next frame does. They belong to 4.2 and 4.3, as listed at the end.

| Pass | Load / store | Why it is right |
|---|---|---|
| Viewport mesh pass (`begin_mesh_pass` via `renderer.odin:1662`) | color LOAD on a partial redraw, else CLEAR; RESOLVE_AND_STORE with MSAA, else STORE; depth the same load, STORE | Partial redraw loads both next frame. Depth is also read by Live AO (`live_ao.odin:107`), the studio (`studio.odin:222`, `:313`), the idle cache copy (`renderer.odin:1489`), and the overlay passes later in the frame. |
| Idle cache (`renderer.odin:1478`) | CLEAR, STORE both | Copied back into the viewport while idle. |
| Thumbnails, step pictures, thumbnail view (`thumbs.odin:59`, `thumbnail_view.odin:46`) | color CLEAR, STORE; depth DONT_CARE unless `keep_depth` | Color is copied into the atlas; depth is unread. |
| Nav head (`nav_head.odin:89`), render-mode backdrop (`path.odin:557`) | color CLEAR, STORE; depth DONT_CARE | The same. |
| Atlas clears (`pictures.odin:60`, `step_pictures.odin:48`, `thumbs.odin:46`) | CLEAR, STORE, only when the atlas is new | A new texture holds garbage; it runs once. |
| Live AO (`live_ao.odin:137`, `:153`) | LOAD on partial, else DONT_CARE (full-screen draw), STORE | It is composited, and loaded on the next partial frame. |
| Studio shadow depth (`studio.odin:245`) | CLEAR, STORE | Sampled by the gather pass right after. |
| Studio and trace accumulate (`studio.odin:275`, `trace.odin:200`) | CLEAR on the first sample, else LOAD; STORE | Accumulation. |
| Trace visibility clear (`trace.odin:166`) | CLEAR, STORE | The compute pass writes zeros into it, and it is then sampled. |
| Full-screen resolves and filters (`studio.odin:326`, `:346`, `:475`, `path.odin:597`, `:609`, `:622`, `finish.odin:170`, `environment.odin:104`) | DONT_CARE, STORE | Each draws every pixel, and the result is read. |
| Screen pass (`screen_pass.odin:40`) | LOAD on partial, else CLEAR; STORE | As the viewport. |
| Interface into the swapchain (`gpu.odin:82`, `ui_pass.odin:230`) | CLEAR, STORE | Presented. |

## Left for 4.2 and 4.3 (D1)
- **Depth of the one-shot passes.** These are thumbnail scratch, nav head, render-mode backdrop and step-picture scratch. Each is DONT_CARE-stored already, so it is never written to memory, but it is still allocated.

  It can be transient or memoryless (4.2). On Mali and Apple GPUs that saves the allocation; it saves no bandwidth.
- **The viewport's MSAA samples and depth.** These are stored every frame only for partial redraw's LOAD next frame. That is 4.3's A/B: partial redraw with stored samples, against full redraws with memoryless samples, measured on the iPad and the OnePlus Pad.
