# Script plugins in Luau (Phase 7 item 6), desktop first

Bolt chose Luau on 2026-10-27, after the comparison at
https://claude.ai/artifact/4PvNYm71dnNZ3PGJyAnw6K (Luau, Lua 5.4, Wasmtime, WAMR, QuickJS-ng).
The roadmap item is C049 and Z015: script plugins over the command registry, sandboxed, with
desktop first.

## What exists when done

- **Where plugins live.** A `plugins/` folder sits beside the settings file. For any other
  settings file it is `<stem>-plugins`, the same rule `macros_folder` uses. Each `*.luau` file
  in it is one plugin.
- **Loading.** Plugins load at start, in file-name order, and again on **Reload plugins**
  (Search, or the Macros panel).
- **Registering commands.** A plugin's top-level code registers commands:

  ```lua
  sculpt.command{
      name = "Smooth and subdivide",
      help = "Smooths the selected object twice, then adds a level.",
      run = function()
          sculpt.run("set smooth_steps 2; smooth_all; subdivide")
      end,
  }
  ```

- **Where the commands show.** Each command shows in Search as `Plugin: <name>`. Like a macro, it
  can take a key (Ctrl+Alt+click on its Run button), a pie slot or a star. It runs on the next
  frame's start, where scene commands and file requests apply.
- **The Macros panel.** It gains a PLUGINS section: each plugin by file name, with its commands
  (Run buttons) and its error if it failed to load or run. Below that are the Reload plugins
  button and a footnote naming the folder.
- **Android.** There are no plugins: no folder is read, no commands appear and the section is
  hidden (store rules, below).

## The plugin API, version 1

The `sculpt` table is read-only, like every built-in.

| Call | Where | What it does |
| --- | --- | --- |
| `sculpt.command{name, help, run}` | top level only | Registers a command. `name` is 1 to 48 bytes and unique across plugins, `help` is up to 200 bytes, `run` is a function. |
| `sculpt.run(text)` | inside `run` only | Runs command-script text (README "Command scripts") now, statement by statement, each its own undo step, as a macro does. Parse errors, `wait`, `new_scene` and commands `script_allows` refuses raise a Luau error before anything runs. A statement that does nothing raises `line N: <statement> did nothing (<why>)`, and the steps before it stay. |
| `sculpt.objects()` | anywhere | Returns an array of `{name, vertices, triangles, selected, shown}`, in scene order. |
| `sculpt.selected()` | anywhere | Returns the selected object's number from 1, or nil. |
| `sculpt.get(key)` | anywhere | Returns a setting's value as the settings file writes it (a string), for `SETTINGS` and `SCRIPT_VALUES` rows. An unknown key raises an error. |
| `sculpt.note(text)` | inside `run` only | Shows an information note (toast). |
| `print(...)` | anywhere | Prints `plugin <file>: ...` to stdout. The last line is kept for the panel. |

The API stays small on purpose. Every change to the scene goes through `sculpt.run`, so plugins
drive exactly the path a person and a script do (AGENTS.md: every vertex move goes through
`apply_dab` and the rest). There is no per-vertex access in version 1.

## Sandbox

- **One VM per plugin.** Each plugin gets its own VM, made by `lua_newstate` with an allocator
  that counts bytes (libc `realloc`/`free`) against `PLUGIN_MEMORY` (64 MB). Past that budget
  the allocator returns nil and Luau raises "not enough memory".
- **Libraries.** `luaL_openlibs` provides Luau's libraries, which already lack `io`, `package`,
  `dofile`, `loadfile`, `load` and `string.dump`; `os` keeps only clock, date, difftime and
  time. We also set `getfenv`, `setfenv`, `require` and `collectgarbage` to nil before
  `luaL_sandbox`, which makes the globals and libraries read-only. The plugin's chunk runs in a
  thread from `luaL_sandboxthread`, so its own globals go in a table of its own.
- **Source only.** Plugins are compiled in the app with `luau_compile`. Bytecode is never read
  from a file: Luau says untrusted bytecode "may lead to exploits", and `loadstring` already
  refuses it.
- **Step budget.** The `interrupt` callback counts safepoints (calls and loop back edges, only
  when `gc < 0`). Past `PLUGIN_STEPS` (50 million) in one load or one run, it raises "ran too
  long". Counting steps rather than time keeps a run deterministic: the same plugin stops at
  the same place on every machine. Time spent inside `sculpt.run` is our own code and is not
  counted.
- **No outside access.** The API above gives no file, network or process access.

## Errors and the C boundary

- **Build settings.** Luau is built as its own `LUAU_EXTERN_C` option builds it:
  `LUA_USE_LONGJMP=1`, with `LUA_API` and `LUACODE_API` set to `extern "C"`. A Luau error is
  then a `longjmp`, never a C++ exception through Odin frames. The compiler's own exceptions
  stay inside `luau_compile`, which returns its errors as bytecode that `luau_load` reports.
- **Odin callbacks.** Every callback is `proc "c"`. It restores the caller's context from the
  `Plugin_Call` it reads through `lua_callbacks(L).userdata`, so the debug build's tracking
  allocator stays the one in use. It checks its arguments first. It raises a Luau error only as
  its last act, after freeing what it made: a script it parsed is destroyed before the raise,
  and other text lives in the temp allocator. No `defer` is pending when it raises.
- **A failed load or run.** The error and the line go in the plugin's row in the panel and in a
  warning note.

## Running a command

- **Starting.** `Run_Plugin` (argument: the slot) is enabled when the slot holds a command and
  `script_can_start` holds: no recording, script, stroke, save or file dialog under way. Running
  it sets `app.plugins.pending`.
- **At the frame's start.** Next to `script_frame`, `plugins_frame` calls the command's `run`
  with the step budget reset. Each `sculpt.run` inside parses the text the way `script_start`
  does for a person's run, then calls a new `script_run_now(app, statements)`. That is
  `script_step` for each statement, including its `autosave_settle`. A failure stops the
  statements and becomes the Luau error.
- **Afterwards.** The note reads "Ran plugin <name>: N steps", or the error as a warning.
  `app.macro.steps` counts the steps as for macros, and History has one entry per step.

## Command registry

- **New commands.** `.Run_Plugin` has args = `PLUGIN_COMMANDS_MAX` (64), the label "Run plugin"
  and the palette name `Plugin: <name>`. Its empty slots are hidden from Search as Run_Macro's
  are. `.Reload_Plugins` reloads the folder.
- **Scripts.** `script_allows` refuses both, so no script runs a plugin and no plugin runs
  itself.
- **Slots.** Slots are given in load order: files by name, then commands in the order they
  register. Keys and pies are stored by slot, as a macro's are, so they stay put while the
  folder's plugins do. A reload within a run keeps the slot of any command whose `file/name`
  is still there, and new ones take free slots. The README says a key follows the slot.

## Store rules and platforms

- **Constant.** `PLUGINS_AVAILABLE :: ODIN_PLATFORM_SUBTARGET != .Android`, as with
  `LINK_AVAILABLE`.
- **The binding package.** `src/luau` wraps its `foreign import` and foreign blocks in
  `when PLUGINS_AVAILABLE`-equivalent conditions. Android's object file then references no
  Luau symbol, and the APK build is unchanged.
- **Why Android has none.** Google Play exempts code in an interpreter with only indirect API
  access, but Apple 2.5.2 bans downloaded code, so sm-store keeps plugins off tablet store
  builds. A later change could allow scripts the artist writes in the app.
- **sm-store.** Its "No downloading or running code" line gains: desktop plugins only, Luau
  sandbox, no plugin store.

## Build

- **Version pin.** `scripts/versions.env` gains `LUAU_TAG=0.744`, Luau's tag of 2026-10-23.
- **New script.** `scripts/build_luau.py` (stdlib only) works on both desktops:
  1. It shallow-clones `https://github.com/luau-lang/luau.git` at the tag into `deps/luau-src`.
  2. It compiles the 61 `.cpp` files of Common, Ast, Bytecode, Compiler and VM in parallel, at
     -O2 with C++17. Linux uses `clang++ -fPIC`. Windows uses `cl /MT /EHsc /O2 /std:c++17`,
     after the vcvarsall set-up that stb's build already does.
  3. It archives them into `deps/luau/libluau.a` (`ar`) or `deps/luau/luau.lib` (`lib`), and
     skips the build when that file and a stamp of the tag already exist.
- **Callers.** `setup_deps.sh` calls it. `setup_deps.bat` calls it after setting up cl.
- **Linking.** Linux adds `system:stdc++`. On Windows, `/MT` objects bring `libcpmt` in through
  their default-library records, as odin-imgui's did before ImGui was removed.
- **Checks.** `wincheck` and `androidcheck` do not link, so they are unchanged. `build.sh` and
  `build.bat` print "run scripts/setup_deps" when the library is missing, as for other deps.
- **Measured here.** The build takes 31 s on 4 cores, and the archive is 4.7 MB. A minimal Odin
  program linked against it compiled `local s = 0 for i = 1, 1000 do s += i end return s`
  (500500), and reported a runtime error and a parse error.

## Exit stats

`plugins=N plugin_commands=N plugin_errors=N plugin_runs=N plugin_steps=N`

## Tests

- **Unit tests** (`src/app/plugins_test.odin`):
  - The sandbox: `io`, `os.execute`, `getfenv`, `require` and bytecode through `loadstring` are
    absent or refused, and writing to `string` or `sculpt` raises.
  - `while true do end` stops at the step budget with "ran too long".
  - Growing a table without end stops at the memory budget.
  - A plugin registers two commands. A duplicate name and `sculpt.command` called inside `run`
    are refused.
  - `sculpt.run` adds an object (`add sphere` or a primitive command), and a failing statement
    keeps the steps before it and reports the line.
  - A load error is listed with its line.
  - Two loads of the same folder give the same slots.
- **Touch scenario** (`plugin_runs_from_search`): writes a plugin into the run's plugins folder,
  starts the app, opens Search, types the plugin's name, runs it, and checks `objects` and
  `plugin_runs`.
- **Size.** About 350 lines in the luau package, 550 in `plugins.odin`, 80 in the panel and 300
  in tests, plus the build script, README and skills: over 300 lines, a new package and new
  commands, hence this note and a review.

## README and skills

- **README.** A "Script plugins" section covers the folder, API, limits, an example, desktop
  only and the Luau credit (MIT, "Luau" attribution in user-facing docs). The Layout section
  gains a `src/luau` row.
- **AGENTS.md.** The map gains `src/luau`, and the package-boundaries line says `luau` knows
  nothing of rendering or UI.
- **Skills.** sm-store gets the plugin rule. sm-build gets `build_luau.py` in setup.

## Architect review (adopted)

The sm-architect review found the approach sound, with five must-fix items. All are adopted.

1. **Slots by identity.** A `plugin_slot <n> <file>/<name>` settings line keeps each command's slot
   across runs. A command takes its remembered slot, and a new one takes the lowest slot that is
   neither remembered nor taken. A remembered slot whose command is gone stays reserved and shows
   in the panel as missing, with Forget. Forget clears its keys, pies, stars, gestures and recent
   entries through `command_slot_forget`, which is factored out of `macro_delete`.
2. **Desktop only, iPad included.** `AVAILABLE :: (ODIN_OS == .Windows || ODIN_OS == .Linux) &&
   ODIN_PLATFORM_SUBTARGET != .Android`, so an iPhone subtarget gets none either. The sm-store
   rule changes to: desktop builds only, never store builds (Bolt chose "Luau, desktop first" on
   a card that said so).
3. **Every entry is protected.** Each entry into a VM is a `lua_pcall`, with the pushes inside
   it. Registering the `sculpt` table and running the chunk go through a protected C function,
   so a memory error never reaches `abort()`. The allocator refuses only while a call is in a
   plugin (`budget` on).
4. **Callbacks raise only when they hold nothing.** Argument checks use `lua_type` with no
   coercion. Strings are cloned to the Odin heap before their value leaves the stack.
   `sculpt.run` parses, runs and destroys its `Script` before it pushes anything. No callback
   has a `defer` or a heap allocation live across a `lua_*` call that can raise.
5. **Re-checked at the frame's start.** `app.plugins.pending` and a pending reload are part of
   `script_can_start`, and `plugins_frame` checks again before it runs. A run that can no
   longer start is dropped with a note. Reload applies at the frame's start too.

Should-fix items adopted:

- **Interrupt.** It raises only when `gc < 0`, and keeps raising at every safepoint once over
  budget, so a plugin's own `pcall` cannot swallow "ran too long".
- **Libraries.** Luau 0.744 has no `loadstring`, `require` or `collectgarbage`. We set
  `getfenv`, `setfenv`, `debug` and `os` to nil, and seed `math.random` with a constant before
  `luaL_sandbox`. Plugins are then deterministic: no clock, no date and no time-seeded random.
- **Budgets.** `PLUGIN_LOAD_STEPS` is 5 million and `PLUGIN_RUN_STEPS` 50 million, measured
  with a test that times a loop to the budget. README says built-ins such as string patterns
  and `table.sort` run between safepoints.
- **Context.** `lua_callbacks(L).userdata` points at a `Plugin_Call` on the stack, set before
  each entry and cleared after.
- **Android build.** Every call site is under `when PLUGINS_AVAILABLE`.
- **Windows.** `longjmp` through Odin frames is unverified there. Bolt's `build.bat test` runs
  the binding's error tests.

Nits adopted: `Run_Plugin` and `Reload_Plugins` are `.Skip` for recordings. Names and help must
be valid UTF-8 with no control bytes. The allocator never refuses a free or a shrink. Luau's two
licence files are copied into `third_party/luau/` (sm-store licences). `luau` joins the test and
check lists. README says a run without a settings file loads no plugins.
