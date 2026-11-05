# Project threads, as of 2026-11-05

A snapshot of the cloud project's threads ("Optimized Sculpting") when this folder was copied.
It does not update itself. Each thread's knowledge lives in `memory/` (the file named in
`memory/MEMORY.md`) and its designs in `notes/`.

## Still open (working or waiting on Bolt)

| Thread | State | Where to read more |
|---|---|---|
| Research Josef Pelz's fast path tracer | working: A1 #702, A2 #703 merged, rest on its own branch (not merged per Bolt) | memory/pelz-pathtracer-study.md, notes/pathtracer-study/ |
| Build UV unwrap for the Surface space | working: UV2-UV4 on branch claude/project-thread-ubkdnn, Unwrap row mock C picked | memory/surface-uv-build.md, notes/surface/ |
| Build cloth and physics brushes | waiting on Bolt: next is PR4 Physics card | memory/physics-brushes-plan.md, notes/physics/ |
| Stop dense remesh crashing on undo memory | waiting on Bolt: iPad 25Mx2 run | memory/dense-remesh-memory-plan.md |
| Plan a Look pad for viewport shading | waiting on Bolt's three picks | memory/look-pad-plan.md |
| Plan UI/UX upgrade from T3's approach | waiting on Bolt: phases ongoing | memory/ui-ux-t3-upgrade.md, notes/ui-review/ |
| Mock ZBrush for iPad layout 1:1 | review ready | memory/ui-zbrush-gaplist.md, notes/zbrush-ipad-shots/ |

## Done but not archived (follow-ups may remain; see their memory file)

Improve sculpt while Bolt is away; Try GPU compute for sculpt operations; Fix tablet touch and camera
controls; Plan one modern real-time Render; Unlock frame rate past 60 Hz; Plan the app UI overhaul;
Add pen roll twist and hover-aware gestures; Plan distinct Remesh and Quad Remesh tools; Weigh building
on Blender's engine; Plan UV unwrap, texturing and shaders; Redesign the interface as docks and cards;
Speed up wireframe on dense meshes; Support every Apple Pencil Pro feature; Make Quad Remesh match
ZRemesher (Flow and Fast engines both kept while Bolt tests); Send scenes between tablet and PC (awaits
device run); Build docking for 2D editors; Build paint layers on vertices (next PT1b); Design a clean
GPU abstraction (G6 recommended skip, awaiting Bolt); Choose GPU vs CPU and language for sculpting;
Fix broken normals shading at edges; Plan reference images like PureRef (next R5b, resizable cards
mock awaiting pick); Redesign the Live stack card; Plan gizmo, pivot and input fixes; Add standalone
3D curve objects (awaiting tablet run); Add sculpting brushes, masking and symmetry; Fix failing app
tests on odin-sculpt.

## Resolved

Help me work out a plan; Multi-mesh sculpt lag; Faking 3D like ZBrush (parked); Add slice tool and
hide; Add flat shading and PBR materials; Add polypaint, layers, retopo and more; Build standout wow
features; Build own cross-platform UI; Build the sculpt app for Android; Build command registry and
touch controls; Design feature hierarchy from ZBrush iPad; Add high-performance voxel sculpting; Add
Procreate-style colour picker; Customise toolbars and add Remesh menu; Design the Lens screens; Prepare
renderer for Vulkan and Slang; Build pen-first poly modeling; Support Apple Pencil Pro shortcuts;
Remove the Classic UI layout; Plan and build the ZBrush-feel brush engine; Show symmetry line and
mirror point; Fix strokes starting off the mesh; Import vertex colours, glTF, USD and FBX; Add combined
move-rotate-scale gizmo; Fix Clay brush and brush menu scrolling; Polish viewport, shading, UI and
import; Digest pain points and cleanup needs; Mock three-group top bar; Keep quads on mirror unweld;
Add adjustable Decimate tool; Keep symmetry in Quad Remesh; Speed up sculpting and orbiting at 25M;
Plan custom app colours and themes; Build Bézier curves and editable strokes; Zoom toward the pinch
midpoint; Pin any brush or tool to the shelf; Keep a log when the app crashes; Import a mesh without
the default sphere; Build a web (WASM) version; Innovate on normal map sculpting; Remove pre-release
backward compatibility; Sculpt 20M+ meshes fully on the GPU; Make Remesh match DynaMesh; Redesign
panels and add motion; Redesign the 3D view gizmo; Start the iPad build; Allow smaller UI scale and
shadow strength; Let users save their own layouts; Stop pen from switching active mesh; List all
brushes for toolbar icons.
