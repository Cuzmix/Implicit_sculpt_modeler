# Metal display-link pacing and presented times: design (native GPU plan 1.7, A2 Metal half)

Status: design for review, 2026-10-30. This change touches when a frame starts on Apple's platforms, so it waits for review before it is built.

## Where things stand
- **The frame loop already waits for the display before it reads input.** `src/app/main.odin:899-913` runs `frame_pace`, then `fence_finish`, then `swapchain_acquire(wait = true)`, and only then `PollEvent`. So a wait inside the acquire is a wait at the start of the frame, which is where it should be.
- **The own Metal backend acquires with `CAMetalLayer.nextDrawable`** (`mtl_swapchain.odin:122`). Before that, it waits for the frame `mtl_state.frames` back (Low latency: 1 or 2).
  - `nextDrawable` returns as soon as any of the layer's three drawables is free. It does not wait for the display.
  - At 120 Hz the app can therefore read input up to two refreshes before its frame is shown, even with one frame in flight.
- **Metal tells nothing about when a frame reached the screen.**
  - `Gpu_Caps.present_timing` is `.None` under Metal.
  - So the Stats panel has `latency_ms` (input to submit) but no `display_ms` on the iPad.

## What changes

### 1. Presented times (both Low latency modes, iPad and Mac)
- **Hook.** Each drawable gets `addPresentedHandler:` before it is presented. The handler runs on a thread of Metal's.
- **What the handler records.**
  - It reads `presentedTime`, which is 0 when the frame never reached the screen.
  - It pushes `{input_ns, shown_ns}` into the window's ring, under a mutex. The window is the handler block's user data.
  - It counts a dropped frame when the time is 0.
- **The input time.** It comes from `gpu_present_input`, as for Vulkan. A frame with no input is tagged 0 and skipped, as Vulkan skips it.
- **Clock conversion.** `presentedTime` is in `CACurrentMediaTime` seconds. The backend samples `CACurrentMediaTime()` and `sdl.GetTicksNS()` together once, when it claims the window, and keeps the offset. Both clocks count mach time, so the offset does not drift.
- **The block.** Made with `NS.Block_createGlobalWithParam` (heap), so it outlives the frame. One block per window serves every drawable, and it is freed when the window is released, after `mtl_wait_for_idle`.
- **What the app sees.**
  - `gpu_present_timing` answers `.Presented_Handler`, a new `Present_Timing` member, under the own Metal backend.
  - `gpu_present_times` drains the ring.
  - So `display_ms` appears in Stats and the exit stats, with no change in the app.
  - The new exit stat `frames_dropped=` counts handlers that saw time 0.

### 2. Display-link pacing (only while one frame is in flight)
- **The link.** A `CAMetalDisplayLink` (iOS 17 / macOS 14, inside our minimums) is made on the window's layer when the window is claimed.
  - `preferredFrameLatency` is 1.
  - `preferredFrameRateRange` is left at the display's.
  - It is added to the run loop of a thread the backend starts for it: `mtl_link_thread`, a plain `core:thread` running `NSRunLoop.run`.
  - It is never on the main run loop. SDL's UIKit pump runs that loop only inside `PollEvent`, so an acquire blocked on the main thread would never see the link's callback.
- **The delegate.** It is an Objective-C class of ours (`@(objc_class = "SculptDisplayLinkDelegate", objc_implement)`, as `Mtl_Objc_Anchor` is) with one method, `metalDisplayLink:needsUpdate:`. Under the window's mutex it:
  - releases any update still waiting (only the newest is kept, so a slow frame never queues old drawables);
  - retains the update's drawable and keeps its `targetPresentationTimestamp`;
  - counts the update, and signals a semaphore (`core:sync` `Sema`).
- **Acquire.** `mtl_acquire_swapchain` uses the link only when the window is linked, vsync is on and `mtl_state.frames == 1`. Then:
  - **wait = true:** it waits on the semaphore for up to two refresh periods. If the update arrived, it takes the waiting drawable instead of calling `nextDrawable`. On a timeout (the link not running yet, the app returning from the background, a missed callback) it falls back to `nextDrawable`, so the loop never stalls longer than today.
  - **wait = false:** it takes a waiting update if there is one, else no texture, as a busy swapchain gives.
  - The GPU wait for the frame `mtl_state.frames` back stays as it is.
- **Pause when unused.** The link is paused when nothing has been taken for 8 updates. This happens when the app rests while idle (`#173`), when Low latency is off, or when frames in flight is 2. The delegate does this on its own thread. The next linked acquire unpauses it (`setPaused:` on the main thread; Apple documents `paused` as settable from any thread for `CADisplayLink`, UNVERIFIED for `CAMetalDisplayLink`, so the unpause is sent with `performSelector:onThread:` to the link's thread to be safe). That acquire then waits up to two periods for the first update.
- **No new setting.** Low latency is the switch:
  - Always, or During strokes while drawing, gives one frame in flight, which uses the link.
  - Off gives two frames and `nextDrawable`, as today.
  - That is the A/B Bolt can run on the iPad without flags.
  - `Gpu_Caps.display_link` (true once a link exists on the main window) lets Settings > Performance say "Display link: on".
  - The Low latency explanation gains one sentence for Apple's platforms.
- **The Mac.**
  - The same pacing, under vsync only: the IMMEDIATE present mode turns display sync off and the link with it.
  - View windows (Mac only) get their own link, since they acquire with wait = false.

### 3. Not in this step
- Predicted touches for the brush ring (A2's companion). These are UIKit's, in `ios/sculpt_ios.m`, and come separately.
- Changing what `frame_pace` limits.
  - With Limit at 60 on a 120 Hz iPad, the pacer's sleep comes first, and the acquire then waits for the next update.
  - The link's `preferredFrameRateRange` could follow the limit later. That would be a battery change, not a latency one.

## Size
About 300 lines:

| Part | Lines |
|---|---|
| Presented handler, ring and clock offset (`mtl_swapchain.odin`) | ~90 |
| Link, delegate class, thread and semaphore (new `mtl_link.odin`) | ~150 |
| Seam, caps and stats | ~30 |
| README and sm-render | ~30 |

## Risks
- **Bindings.** The Odin binding has no `CAMetalDisplayLink`, so the class, its properties and the update are reached with `msgSend` (`NS.objc_lookUpClass("CAMetalDisplayLink")`, `initWithMetalLayer:`, `setDelegate:`, `addToRunLoop:forMode:`, `drawable`, `targetPresentationTimestamp`). A typo there compiles and fails only on the device. Each selector is checked with `respondsToSelector:` when the link is made; on any miss the window stays unlinked and the log says which.
- **Thread safety.** The delegate runs on the link thread, the acquire on the main thread, and the presented handler on Metal's. Each window's shared fields sit behind its mutex, and nothing else crosses threads.
- **Drawable lifetime.** A waiting drawable released unused returns to the layer's pool. Apple's sample does the same when a frame is skipped.
- **Shutdown.** Releasing a window:
  1. invalidates the link on its thread (`performSelector:onThread:` with `invalidate`, waiting until done);
  2. stops that thread's run loop;
  3. joins the thread;
  4. releases any waiting drawable;
  5. frees the presented-handler block.
- **The stores.** The privacy manifest needs nothing new: `CACurrentMediaTime` is not a required-reason API, and SDL's 35F9.1 entry already covers elapsed-time measurement (UNVERIFIED against Apple's current list; the PR says so).

## Checks
- **Here.**
  - `maccheck` and `iphonecheck` compile the code.
  - `check` and `test` pass.
  - `smoke` passes; Linux is unchanged.
- **Bolt, before merge, on the iPad under Metal (trial):**
  - Settings > Performance shows "Pen to screen" (display_ms) under each Low latency choice.
  - A 10 s stroke with Low latency Always and with Off, reading `display_ms` and dropped frames from the Stats panel.
  - Orbiting and idle rest still behave, and the app returns from the background cleanly.
- **Acceptance.** `display_ms` p50 is lower with Always than with Off by about one refresh (8 ms at 120 Hz), with no more dropped frames.

## Review (sm-architect, 2026-10-30): approve with changes; split into 1.7a and 1.7b
- **Part 1 (presented times) is sound; build it first as 1.7a**, together with the cheaper latency lever the review named: `maximumDrawableCount` 2 while one frame is in flight (3 otherwise). With one drawable on screen and one being drawn, `nextDrawable` blocks until the display lets one go, which gets most of the one-refresh win in a few lines, with no thread, class or semaphore. Low latency Off against Always is the A/B, read from `display_ms` and the new Frames dropped row.
- **Presented-handler lifetime.** Metal keeps our global block, and handlers fire after `mtl_wait_for_idle`. So the logs live in `mtl_state.present_logs` (eight), outlive their windows (a released window only marks its log free and clears its pending drawables), and their blocks are freed with the device.
- **Part 2 (the link) becomes 1.7b, built only if 1.7a's numbers leave a gap.** It then takes these changes:
  - Post the semaphore only when the update slot goes from empty to full (or use a `Cond` with a pending flag), and re-check the slot after waking.
  - Run the link thread with `runMode:beforeDate:` while a quit flag is clear, making and adding the link on that thread.
  - Reach NSThread, NSRunLoop, `performSelector:onThread:` and `CAMetalDisplayLink` through `msgSend` (none are bound), with the delegate's own `resume`/`stop` methods instead of `setPaused:` through `performSelector`. Set `context` in every `proc "c"` and wrap the delegate in an autorelease pool.
  - Pause only after 8 updates with no acquire at all (idle rest), not whenever two frames are in flight, since During strokes switches at every pen-down.
  - Check on the device whether `nextDrawable` may be called while a link drives the layer; if not, a timeout skips the frame.
  - Use one link thread for every window, and take the period from successive `targetPresentationTimestamp`s.
- **Clock.** SDL's Apple timer uses `mach_absolute_time` (`HAVE_CLOCK_GETTIME` is not set for Apple), the same clock as `CACurrentMediaTime`, so the offset is sound.
- **The menu path** is Settings > System > Frame rate (Low latency), not Performance.
