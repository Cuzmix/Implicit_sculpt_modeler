package ui

// Written by scripts/icons_build.py from assets/icons/manifest.txt: edit that and run the
// script. One name per meaning, each its own drawing in the icon fonts (text.odin).

ICONS_SOURCE_HASH :: "90bf4556a748ba8e6e7dc65ba6b3bbb4efa17fe6a86ec52931dce7dd36b4dc0c"
ICONS_FONTS_HASH :: "a6ed8dde89d35725990ae3582e152caf74855ebd0df221d15c015d340ae09532"

// What an icon works on, which colours it in the Colour icon style.
Icon_Group :: enum u8 {
	App,
	Sculpt,
	Mask,
	Paint,
	Model,
	View,
	Render,
	File,
}

ICON_FIRST :: rune(0xE000)
ICON_COUNT :: 417

ICON_MENU                :: rune(0xE000) // ph:list
ICON_MORE                :: rune(0xE001) // ph:dots-three-circle
ICON_CLOSE               :: rune(0xE002) // ph:x
ICON_CHECK               :: rune(0xE003) // ph:check
ICON_UNCHECKED           :: rune(0xE004) // ph:circle
ICON_CHEVRON_DOWN        :: rune(0xE005) // ph:caret-down
ICON_CHEVRON_UP          :: rune(0xE006) // ph:caret-up
ICON_CHEVRON_LEFT        :: rune(0xE007) // ph:caret-left
ICON_CHEVRON_RIGHT       :: rune(0xE008) // ph:caret-right
ICON_GRIP                :: rune(0xE009) // ph:dots-six-vertical
ICON_MINIMISE            :: rune(0xE00A) // ph:arrows-in-simple
ICON_RESTORE             :: rune(0xE00B) // ph:arrows-out-simple
ICON_SEARCH              :: rune(0xE00C) // ph:magnifying-glass
ICON_ZOOM                :: rune(0xE00D) // ph:magnifying-glass-plus
ICON_HELP                :: rune(0xE00E) // ph:question
ICON_TOUR                :: rune(0xE00F) // ph:signpost
ICON_TIPS                :: rune(0xE010) // ph:lightbulb-filament
ICON_TAG                 :: rune(0xE011) // ph:tag
ICON_KEYBOARD            :: rune(0xE012) // ph:keyboard
ICON_STAR                :: rune(0xE013) // ph:star
ICON_HEART               :: rune(0xE014) // ph:heart
ICON_PIN                 :: rune(0xE015) // ph:push-pin
ICON_PIN_OFF             :: rune(0xE016) // ph:push-pin-slash
ICON_LOCK                :: rune(0xE017) // ph:lock
ICON_LOCK_OPEN           :: rune(0xE018) // ph:lock-open
ICON_LINK                :: rune(0xE019) // ph:link
ICON_FLAG                :: rune(0xE01A) // ph:flag
ICON_FILTER              :: rune(0xE01B) // ph:funnel
ICON_BOOKMARK            :: rune(0xE01C) // ph:bookmark-simple
ICON_PLUS                :: rune(0xE01D) // ph:plus
ICON_MINUS               :: rune(0xE01E) // ph:minus
ICON_TRASH               :: rune(0xE01F) // ph:trash
ICON_COPY                :: rune(0xE020) // ph:copy
ICON_DUPLICATE           :: rune(0xE021) // ph:copy-simple
ICON_PASTE               :: rune(0xE022) // ph:clipboard
ICON_PENCIL              :: rune(0xE023) // ph:pencil-simple
ICON_RENAME              :: rune(0xE024) // ph:textbox
ICON_UNDO                :: rune(0xE025) // ph:arrow-u-up-left
ICON_REDO                :: rune(0xE026) // ph:arrow-u-up-right
ICON_REVERT              :: rune(0xE027) // ph:arrow-counter-clockwise
ICON_RELOAD              :: rune(0xE028) // ph:arrows-clockwise
ICON_SETTINGS            :: rune(0xE029) // ph:gear-six
ICON_BRUSH_VALUE         :: rune(0xE02A) // ph:sliders
ICON_COMMAND             :: rune(0xE02B) // ph:lightning
ICON_CUSTOMISE           :: rune(0xE02C) // ph:pencil-ruler
ICON_PANEL               :: rune(0xE02D) // ph:sidebar-simple
ICON_OPEN_CARD           :: rune(0xE02E) // ph:cards
ICON_RESET_PANELS        :: rune(0xE02F) // tb:layout-sidebar-right-collapse
ICON_SPACE               :: rune(0xE030) // ph:app-window
ICON_RESET_LAYOUT        :: rune(0xE031) // tb:layout-off
ICON_PIE                 :: rune(0xE032) // ph:chart-pie-slice
ICON_EDIT_PIES           :: rune(0xE033) // ph:circles-three-plus
ICON_BRUSH_PIE           :: rune(0xE034) // tb:chart-donut
ICON_TO_TOP              :: rune(0xE035) // ph:arrow-line-up
ICON_TO_BOTTOM           :: rune(0xE036) // ph:arrow-line-down
ICON_DETAILS             :: rune(0xE037) // ph:info
ICON_HOME                :: rune(0xE038) // ph:house
ICON_MONITOR             :: rune(0xE039) // ph:monitor
ICON_TABLET              :: rune(0xE03A) // ph:device-tablet
ICON_SEND                :: rune(0xE03B) // ph:paper-plane-tilt
ICON_HISTORY             :: rune(0xE03C) // ph:clock-counter-clockwise
ICON_HISTORY_LIST        :: rune(0xE03D) // ph:list-bullets
ICON_HISTORY_STRIP       :: rune(0xE03E) // ph:columns
ICON_TINT_STEP           :: rune(0xE03F) // ph:highlighter
ICON_FIND_STEPS          :: rune(0xE040) // ph:list-magnifying-glass
ICON_GO_HERE             :: rune(0xE041) // ph:map-pin
ICON_LOCATE              :: rune(0xE042) // ph:navigation-arrow
ICON_EYE                 :: rune(0xE043) // ph:eye
ICON_EYE_OFF             :: rune(0xE044) // ph:eye-slash
ICON_PLAY                :: rune(0xE045) // ph:play
ICON_PAUSE               :: rune(0xE046) // ph:pause
ICON_STOP                :: rune(0xE047) // ph:stop-circle
ICON_RECORD              :: rune(0xE048) // ph:record
ICON_SKIP_BACK           :: rune(0xE049) // ph:skip-back
ICON_SKIP_FORWARD        :: rune(0xE04A) // ph:skip-forward
ICON_STEP_BACK           :: rune(0xE04B) // ph:rewind
ICON_STEP_FORWARD        :: rune(0xE04C) // ph:fast-forward
ICON_REPLAY              :: rune(0xE04D) // ph:play-circle
ICON_MACROS              :: rune(0xE04E) // ph:list-checks
ICON_RUN_PLUGIN          :: rune(0xE04F) // ph:puzzle-piece
ICON_RUN_SCRIPT          :: rune(0xE050) // ph:code
ICON_SAMPLES             :: rune(0xE051) // ph:waveform
ICON_DIAGNOSTICS         :: rune(0xE052) // ph:hand-tap
ICON_PEN                 :: rune(0xE053) // ph:pen-nib
ICON_PEN_EMPTY           :: rune(0xE054) // ph:cursor
ICON_CHECK_OK            :: rune(0xE055) // ph:check-circle
ICON_CHECK_WAIT          :: rune(0xE056) // ph:hourglass
ICON_CHECK_WARN          :: rune(0xE057) // ph:warning
ICON_FILE                :: rune(0xE058) // ph:file
ICON_FILE_GONE           :: rune(0xE059) // ph:file-x
ICON_FOLDER              :: rune(0xE05A) // ph:folder
ICON_FOLDER_PLUS         :: rune(0xE05B) // ph:folder-plus
ICON_LIBRARY             :: rune(0xE05C) // ph:books
ICON_NEW_SCENE           :: rune(0xE05D) // ph:file-plus
ICON_OPEN                :: rune(0xE05E) // ph:folder-open
ICON_SAVE                :: rune(0xE05F) // ph:floppy-disk
ICON_SAVE_AS             :: rune(0xE060) // ph:pencil-simple-line
ICON_SAVE_NEXT           :: rune(0xE061) // ph:floppy-disk-back
ICON_SAVE_COPY           :: rune(0xE062) // ph:files
ICON_EARLIER_SAVES       :: rune(0xE063) // ph:clock-clockwise
ICON_RECENT              :: rune(0xE064) // tb:file-time
ICON_AUTOSAVE            :: rune(0xE065) // ph:clock-countdown
ICON_IMPORT              :: rune(0xE066) // ph:file-arrow-down
ICON_EXPORT              :: rune(0xE067) // ph:file-arrow-up
ICON_EXPORT_SHEET        :: rune(0xE068) // ph:export
ICON_INSTALL_PACK        :: rune(0xE069) // tb:package-import
ICON_MAKE_PACK           :: rune(0xE06A) // ph:archive
ICON_CRASH_LOG           :: rune(0xE06B) // ph:bug
ICON_BLENDER_GET         :: rune(0xE06C) // ph:arrow-square-in
ICON_BLENDER_SEND        :: rune(0xE06D) // ph:arrow-square-out
ICON_FORMATS             :: rune(0xE06E) // tb:file-3d
ICON_GAMEPAD             :: rune(0xE06F) // ph:game-controller
ICON_PRINTER             :: rune(0xE070) // ph:printer
ICON_PRINT_EXPORT        :: rune(0xE071) // tb:printer
ICON_DOWNLOAD            :: rune(0xE072) // ph:download-simple
ICON_SCREENSHOT          :: rune(0xE073) // ph:camera-plus
ICON_SCREENSHOT_CLEAR    :: rune(0xE074) // ph:selection-background
ICON_CAMERA_SHOT         :: rune(0xE075) // tb:camera-selfie
ICON_TURNTABLE           :: rune(0xE076) // ph:film-strip
ICON_FILM                :: rune(0xE077) // ph:film-reel
ICON_PAINT_MAPS          :: rune(0xE078) // ph:image-square
ICON_IMAGE               :: rune(0xE079) // ph:image
ICON_IMAGE_PLUS          :: rune(0xE07A) // tb:photo-plus
ICON_IMAGE_DOWN          :: rune(0xE07B) // tb:photo-down
ICON_PHOTOS              :: rune(0xE07C) // tb:photo
ICON_BRUSH               :: rune(0xE07D) // ph:paint-brush
ICON_SCULPT_TOOL         :: rune(0xE07E) // own:sculpt_tool
ICON_BRUSH_PICKER        :: rune(0xE07F) // ph:squares-four
ICON_PRESET              :: rune(0xE080) // ph:bookmarks
ICON_PRESET_SAVE         :: rune(0xE081) // ph:bookmark
ICON_SIZE                :: rune(0xE082) // lu:radius
ICON_STRENGTH            :: rune(0xE083) // ph:gauge
ICON_FOCAL               :: rune(0xE084) // ph:crosshair-simple
ICON_SPACING             :: rune(0xE085) // ph:dots-three
ICON_LAZY                :: rune(0xE086) // ph:path
ICON_PRESSURE            :: rune(0xE087) // lu:signature
ICON_EXPOSURE            :: rune(0xE088) // tb:aperture
ICON_ADD                 :: rune(0xE089) // tb:circle-plus
ICON_SUBTRACT            :: rune(0xE08A) // ph:minus-circle
ICON_SYMMETRY            :: rune(0xE08B) // own:symmetry
ICON_LOCAL_SYMMETRY      :: rune(0xE08C) // ph:flip-vertical
ICON_STROKE              :: rune(0xE08D) // ph:scribble
ICON_FALLOFF             :: rune(0xE08E) // ph:circle-dashed
ICON_ALPHA               :: rune(0xE08F) // ph:image-broken
ICON_RECALL              :: rune(0xE090) // ph:arrow-arc-left
ICON_PAINT_BACK          :: rune(0xE091) // tb:brush-off
ICON_STROKE_DOTS         :: rune(0xE092) // ph:dots-three-outline
ICON_STROKE_RECT         :: rune(0xE093) // ph:rectangle
ICON_STROKE_SPRAY        :: rune(0xE094) // ph:spray-bottle
ICON_STROKE_ROLL         :: rune(0xE095) // ph:paint-roller
ICON_STROKE_DRAG_DOT     :: rune(0xE096) // ph:arrow-right
ICON_DYNTOPO             :: rune(0xE097) // own:dyntopo
ICON_REMESH              :: rune(0xE098) // own:remesh
ICON_HD                  :: rune(0xE099) // tb:zoom-scan
ICON_LEVELS              :: rune(0xE09A) // lu:grid-2x2-plus
ICON_SUBDIVIDE           :: rune(0xE09B) // own:subdivide
ICON_LEVEL_UP            :: rune(0xE09C) // ph:caret-double-up
ICON_LEVEL_DOWN          :: rune(0xE09D) // ph:caret-double-down
ICON_DELETE_LEVELS       :: rune(0xE09E) // ph:stack-minus
ICON_MORPH               :: rune(0xE09F) // ph:arrows-left-right
ICON_MORPH_DELETE        :: rune(0xE0A0) // ph:eraser
ICON_LAYERS              :: rune(0xE0A1) // ph:stack
ICON_MERGE               :: rune(0xE0A2) // ph:git-merge
ICON_VOXEL_CLAY          :: rune(0xE0A3) // ph:cube-focus
ICON_SCULPT_MESH         :: rune(0xE0A4) // ph:triangle
ICON_DEFORM              :: rune(0xE0A5) // ph:magic-wand
ICON_DEFORMERS           :: rune(0xE0A6) // tb:rotate-2
ICON_PHYSICS             :: rune(0xE0A7) // ph:t-shirt
ICON_RECORDER            :: rune(0xE0A8) // ph:vinyl-record
ICON_HEIGHT              :: rune(0xE0A9) // ph:mountains
ICON_SCULPT_SPACE        :: rune(0xE0AA) // ph:hand
ICON_BRUSH_DRAW          :: rune(0xE0AB) // ph:pen
ICON_BRUSH_SMOOTH        :: rune(0xE0AC) // ph:waves
ICON_BRUSH_CLAY          :: rune(0xE0AD) // own:brush_clay
ICON_BRUSH_FLATTEN       :: rune(0xE0AE) // own:brush_flatten
ICON_BRUSH_INFLATE       :: rune(0xE0AF) // own:brush_inflate
ICON_BRUSH_PINCH         :: rune(0xE0B0) // tb:arrows-diagonal-minimize
ICON_BRUSH_CREASE        :: rune(0xE0B1) // own:brush_crease
ICON_BRUSH_GRAB          :: rune(0xE0B2) // ph:hand-grabbing
ICON_BRUSH_LAYER         :: rune(0xE0B3) // ph:rows
ICON_BRUSH_SNAKE_HOOK    :: rune(0xE0B4) // tb:ease-in-out
ICON_BRUSH_ELASTIC       :: rune(0xE0B5) // lu:stretch-horizontal
ICON_BRUSH_CLAY_STRIPS   :: rune(0xE0B6) // tb:align-justified
ICON_BRUSH_TRIM          :: rune(0xE0B7) // lu:tent
ICON_BRUSH_TUBE          :: rune(0xE0B8) // own:brush_tube
ICON_MASK                :: rune(0xE0B9) // ph:mask-happy
ICON_MASK_KEY            :: rune(0xE0BA) // ph:circle-half
ICON_MASK_SHAPE          :: rune(0xE0BB) // ph:selection
ICON_LAYER_MASK          :: rune(0xE0BC) // tb:mask
ICON_INVERT              :: rune(0xE0BD) // ph:plus-minus
ICON_INVERT_HIDDEN       :: rune(0xE0BE) // tb:eye-exclamation
ICON_HIDE                :: rune(0xE0BF) // ph:eye-closed
ICON_HIDE_UNMASKED       :: rune(0xE0C0) // tb:eye-minus
ICON_HIDE_SHAPE          :: rune(0xE0C1) // ph:selection-slash
ICON_SHOW_ALL            :: rune(0xE0C2) // ph:eyes
ICON_SHOW_MASKED         :: rune(0xE0C3) // tb:eye-plus
ICON_GROW                :: rune(0xE0C4) // ph:arrows-out
ICON_SHRINK              :: rune(0xE0C5) // ph:arrows-in
ICON_GROW_GROUPS         :: rune(0xE0C6) // tb:arrows-maximize
ICON_OUTER_RING          :: rune(0xE0C7) // ph:circle-notch
ICON_GROUPS              :: rune(0xE0C8) // ph:selection-plus
ICON_RECT_SHAPE          :: rune(0xE0C9) // ph:selection-foreground
ICON_LASSO               :: rune(0xE0CA) // ph:lasso
ICON_HIDE_RECT           :: rune(0xE0CB) // tb:marquee-off
ICON_HIDE_LASSO          :: rune(0xE0CC) // tb:lasso-off
ICON_CLIP                :: rune(0xE0CD) // ph:crop
ICON_SLICE               :: rune(0xE0CE) // ph:scissors
ICON_KNIFE_GESTURE       :: rune(0xE0CF) // tb:slice
ICON_PAINT               :: rune(0xE0D0) // ph:paint-brush-household
ICON_COLOUR              :: rune(0xE0D1) // ph:palette
ICON_SWAP_COLORS         :: rune(0xE0D2) // ph:swap
ICON_EYEDROPPER          :: rune(0xE0D3) // ph:eyedropper
ICON_FILL                :: rune(0xE0D4) // ph:paint-bucket
ICON_FILL_GRADIENT       :: rune(0xE0D5) // ph:gradient
ICON_CHANNEL_SCULPT      :: rune(0xE0D6) // tb:mountain
ICON_CHANNEL_BOTH        :: rune(0xE0D7) // ph:exclude
ICON_CHANNEL_COLOR       :: rune(0xE0D8) // ph:drop
ICON_COLOR_DISC          :: rune(0xE0D9) // tb:color-filter
ICON_COLOR_CLASSIC       :: rune(0xE0DA) // ph:square
ICON_COLOR_HARMONY       :: rune(0xE0DB) // ph:circles-three
ICON_COLOR_VALUE         :: rune(0xE0DC) // ph:sliders-horizontal
ICON_PALETTES            :: rune(0xE0DD) // ph:swatches
ICON_TEXTURES            :: rune(0xE0DE) // ph:checkerboard
ICON_TEXTURE_TAB         :: rune(0xE0DF) // ph:file-image
ICON_PROJECT             :: rune(0xE0E0) // ph:projector-screen
ICON_UVS                 :: rune(0xE0E1) // tb:scissors
ICON_UNWRAP              :: rune(0xE0E2) // tb:box-model-2
ICON_STRAIGHTEN_ISLANDS  :: rune(0xE0E3) // tb:layout-grid
ICON_TEXEL_DENSITY       :: rune(0xE0E4) // tb:grid-dots
ICON_MATERIAL            :: rune(0xE0E5) // tb:ball-bowling
ICON_METAL               :: rune(0xE0E6) // tb:circle-half-2
ICON_ROUGHNESS           :: rune(0xE0E7) // ph:drop-half
ICON_MODEL               :: rune(0xE0E8) // ph:polygon
ICON_EDIT_CAGE           :: rune(0xE0E9) // tb:cube-unfolded
ICON_CAGE                :: rune(0xE0EA) // own:cage
ICON_CAGE_SELECT         :: rune(0xE0EB) // ph:cursor-click
ICON_CAGE_EDIT           :: rune(0xE0EC) // ph:hammer
ICON_CAGE_CHECK          :: rune(0xE0ED) // ph:seal-check
ICON_CAGE_FLAT           :: rune(0xE0EE) // ph:hexagon
ICON_CAGE_SMOOTH         :: rune(0xE0EF) // tb:shape-2
ICON_THICKNESS           :: rune(0xE0F0) // tb:box-padding
ICON_TIDY                :: rune(0xE0F1) // ph:broom
ICON_APPLY_CAGE          :: rune(0xE0F2) // ph:arrow-fat-line-down
ICON_MODEL_ACTION        :: rune(0xE0F3) // tb:hand-click
ICON_MODEL_TARGET        :: rune(0xE0F4) // ph:target
ICON_INSERT              :: rune(0xE0F5) // ph:shapes
ICON_ADD_CAGE            :: rune(0xE0F6) // tb:cube-plus
ICON_ADD_OBJECT          :: rune(0xE0F7) // ph:plus-circle
ICON_EXTRUDE             :: rune(0xE0F8) // ph:arrow-square-up
ICON_INSET               :: rune(0xE0F9) // lu:square-square
ICON_MOVE_POINTS         :: rune(0xE0FA) // ph:arrows-out-cardinal
ICON_DELETE_FACES        :: rune(0xE0FB) // ph:x-square
ICON_POLYGROUP           :: rune(0xE0FC) // tb:components
ICON_FLIP_FACES          :: rune(0xE0FD) // ph:arrows-down-up
ICON_INSERT_LOOP         :: rune(0xE0FE) // lu:between-horizontal-start
ICON_REMOVE_LOOP         :: rune(0xE0FF) // ph:minus-square
ICON_COLLAPSE            :: rune(0xE100) // tb:arrows-diagonal-minimize-2
ICON_SPIN                :: rune(0xE101) // ph:arrow-clockwise
ICON_CLOSE_HOLE          :: rune(0xE102) // tb:circle-dashed
ICON_EXTRUDE_EDGE        :: rune(0xE103) // tb:arrow-bar-up
ICON_BRIDGE              :: rune(0xE104) // ph:arrows-in-line-horizontal
ICON_WELD                :: rune(0xE105) // tb:arrows-join-2
ICON_CONNECT             :: rune(0xE106) // ph:link-simple
ICON_DISSOLVE_POINT      :: rune(0xE107) // lu:diamond-minus
ICON_SELECT              :: rune(0xE108) // tb:marquee-2
ICON_CREASE              :: rune(0xE109) // lu:tangent
ICON_CREASE_POINT        :: rune(0xE10A) // ph:diamond
ICON_BEVEL               :: rune(0xE10B) // ph:octagon
ICON_CIRCLE_LOOP         :: rune(0xE10C) // tb:circle-dot
ICON_SPACE_LOOP          :: rune(0xE10D) // lu:align-horizontal-space-around
ICON_FLATTEN_LOOP        :: rune(0xE10E) // lu:align-vertical-justify-center
ICON_KNIFE               :: rune(0xE10F) // ph:knife
ICON_ALIGN               :: rune(0xE110) // ph:text-align-center
ICON_SPINE               :: rune(0xE111) // ph:bone
ICON_TOPO                :: rune(0xE112) // tb:topology-star-3
ICON_LOOP_CURVE          :: rune(0xE113) // ph:wave-sine
ICON_MEASURE             :: rune(0xE114) // ph:ruler
ICON_SLIDE               :: rune(0xE115) // ph:arrows-horizontal
ICON_RELAX               :: rune(0xE116) // ph:wind
ICON_CUBE                :: rune(0xE117) // tb:cube
ICON_PLANE               :: rune(0xE118) // tb:square
ICON_CYLINDER            :: rune(0xE119) // ph:cylinder
ICON_SPHERE              :: rune(0xE11A) // tb:sphere
ICON_TORUS               :: rune(0xE11B) // lu:torus
ICON_CONE                :: rune(0xE11C) // tb:cone
ICON_BOOLEAN             :: rune(0xE11D) // ph:intersect
ICON_SPLIT               :: rune(0xE11E) // ph:arrows-split
ICON_EXTRACT             :: rune(0xE11F) // tb:arrows-split-2
ICON_RETOPO              :: rune(0xE120) // lu:grid-2x2
ICON_SHARP               :: rune(0xE121) // ph:diamonds-four
ICON_LIVE_STACK          :: rune(0xE122) // ph:wrench
ICON_STACK_ADD           :: rune(0xE123) // tb:tool
ICON_STACK_APPLY         :: rune(0xE124) // tb:square-check
ICON_ARRAY               :: rune(0xE125) // tb:copy
ICON_RADIAL              :: rune(0xE126) // tb:rotate-360
ICON_ALONG               :: rune(0xE127) // tb:route-2
ICON_STACK_BEVEL         :: rune(0xE128) // tb:border-radius
ICON_DISPLACE            :: rune(0xE129) // lu:mountain-snow
ICON_CAGE_DEFORM         :: rune(0xE12A) // ph:tornado
ICON_CAGE_CURVE          :: rune(0xE12B) // tb:vector-spline
ICON_CAGE_WRAP           :: rune(0xE12C) // ph:magnet
ICON_CAGE_MIRROR         :: rune(0xE12D) // tb:flip-vertical
ICON_STACK_SMOOTH        :: rune(0xE12E) // tb:ripple
ICON_CURVE               :: rune(0xE12F) // ph:bezier-curve
ICON_ADD_CURVE           :: rune(0xE130) // tb:vector-bezier-2
ICON_CURVE_BAKE          :: rune(0xE131) // tb:vector-bezier-arc
ICON_CURVE_RUN           :: rune(0xE132) // tb:route
ICON_CURVE_LATHE         :: rune(0xE133) // tb:rotate-dot
ICON_CURVE_LOFT          :: rune(0xE134) // tb:layers-linked
ICON_CURVE_PIPE          :: rune(0xE135) // tb:line-dashed
ICON_CURVE_USE           :: rune(0xE136) // tb:vector-triangle
ICON_MESH                :: rune(0xE137) // tb:triangle-square-circle
ICON_SCENE               :: rune(0xE138) // ph:cube
ICON_OBJECTS             :: rune(0xE139) // tb:stack-2
ICON_OBJECT_MENU         :: rune(0xE13A) // ph:dots-three-vertical
ICON_GHOST               :: rune(0xE13B) // ph:ghost
ICON_SOLO                :: rune(0xE13C) // tb:focus-centered
ICON_TRANSFORM           :: rune(0xE13D) // tb:transform
ICON_MOVE_TOOL           :: rune(0xE13E) // tb:arrows-move
ICON_GIZMO               :: rune(0xE13F) // tb:axis-x
ICON_GIZMO_ORIENT        :: rune(0xE140) // lu:move-3d
ICON_GIZMO_SNAP          :: rune(0xE141) // ph:magnet-straight
ICON_PIVOT               :: rune(0xE142) // ph:crosshair
ICON_PIVOT_CENTER        :: rune(0xE143) // tb:focus-2
ICON_PIVOT_RESET         :: rune(0xE144) // tb:restore
ICON_PIVOT_UNMASKED      :: rune(0xE145) // lu:circle-dot-dashed
ICON_PIVOT_EDIT          :: rune(0xE146) // tb:pencil-pin
ICON_WORLD               :: rune(0xE147) // ph:globe-hemisphere-west
ICON_OBJECT_SPACE        :: rune(0xE148) // tb:box-model
ICON_SURFACE             :: rune(0xE149) // tb:arrow-up-from-arc
ICON_VIEW_SPACE          :: rune(0xE14A) // tb:eye-check
ICON_ALIGN_LEFT          :: rune(0xE14B) // ph:align-left
ICON_ALIGN_CENTER_H      :: rune(0xE14C) // ph:align-center-horizontal
ICON_ALIGN_RIGHT         :: rune(0xE14D) // ph:align-right
ICON_ALIGN_BOTTOM        :: rune(0xE14E) // ph:align-bottom
ICON_ALIGN_CENTER_V      :: rune(0xE14F) // ph:align-center-vertical
ICON_ALIGN_TOP           :: rune(0xE150) // ph:align-top
ICON_DISTRIBUTE_LEFT     :: rune(0xE151) // lu:align-horizontal-distribute-start
ICON_DISTRIBUTE_CENTER_H :: rune(0xE152) // lu:align-horizontal-distribute-center
ICON_DISTRIBUTE_RIGHT    :: rune(0xE153) // lu:align-horizontal-distribute-end
ICON_DISTRIBUTE_BOTTOM   :: rune(0xE154) // lu:align-vertical-distribute-end
ICON_DISTRIBUTE_CENTER_V :: rune(0xE155) // lu:align-vertical-distribute-center
ICON_DISTRIBUTE_TOP      :: rune(0xE156) // lu:align-vertical-distribute-start
ICON_REFERENCES          :: rune(0xE157) // ph:images
ICON_SHOW_REFS           :: rune(0xE158) // tb:photo-scan
ICON_REF_PLANE           :: rune(0xE159) // ph:images-square
ICON_SCAN                :: rune(0xE15A) // ph:scan-smiley
ICON_STICKY_NOTE         :: rune(0xE15B) // ph:note
ICON_LAYOUT_DASHBOARD    :: rune(0xE15C) // ph:layout
ICON_STRETCH_VERTICAL    :: rune(0xE15D) // ph:arrows-out-line-vertical
ICON_FLIP_PICTURE        :: rune(0xE15E) // tb:arrows-horizontal
ICON_GREY                :: rune(0xE15F) // tb:contrast
ICON_TURN                :: rune(0xE160) // tb:rotate-clockwise
ICON_CROP                :: rune(0xE161) // tb:crop
ICON_ON_VIEW             :: rune(0xE162) // ph:picture-in-picture
ICON_VIEW_BEHIND         :: rune(0xE163) // tb:stack-back
ICON_STRAIGHTEN          :: rune(0xE164) // tb:ruler-2
ICON_SEND_TO_BACK        :: rune(0xE165) // tb:layers-subtract
ICON_HEAD                :: rune(0xE166) // ph:user
ICON_CAMERA              :: rune(0xE167) // ph:camera
ICON_RESET_CAMERA        :: rune(0xE168) // ph:camera-rotate
ICON_FRAME               :: rune(0xE169) // ph:frame-corners
ICON_FOCUS               :: rune(0xE16A) // tb:focus
ICON_PICK_FOCUS          :: rune(0xE16B) // tb:focus-auto
ICON_ORTHO               :: rune(0xE16C) // tb:perspective
ICON_FLOOR               :: rune(0xE16D) // lu:axis-3d
ICON_VIEW_GRID           :: rune(0xE16E) // ph:hash
ICON_WIREFRAME           :: rune(0xE16F) // ph:grid-nine
ICON_TRANSPARENCY        :: rune(0xE170) // tb:square-toggle
ICON_CLEAN_VIEW          :: rune(0xE171) // tb:maximize
ICON_VIEW_LAYOUT         :: rune(0xE172) // tb:layout-board
ICON_FOUR_VIEWS          :: rune(0xE173) // tb:layout-grid-add
ICON_VIEW_WINDOW         :: rune(0xE174) // ph:browsers
ICON_SECOND_VIEW         :: rune(0xE175) // tb:picture-in-picture
ICON_VIEW_GUIDES         :: rune(0xE176) // lu:align-vertical-space-between
ICON_VIEW_GUIDES_RESET   :: rune(0xE177) // tb:refresh
ICON_ORBIT_VIEW          :: rune(0xE178) // ph:planet
ICON_FLIP_VIEW           :: rune(0xE179) // tb:flip-horizontal
ICON_ROTATE_3D           :: rune(0xE17A) // tb:rotate-3d
ICON_LOOK                :: rune(0xE17B) // ph:binoculars
ICON_SHADING             :: rune(0xE17C) // ph:circle-half-tilt
ICON_LAST_SHADING        :: rune(0xE17D) // tb:arrow-back-up
ICON_STYLE               :: rune(0xE17E) // ph:paint-brush-broad
ICON_FINISH              :: rune(0xE17F) // tb:sparkles
ICON_WIPE                :: rune(0xE180) // tb:columns-2
ICON_BACKGROUND          :: rune(0xE181) // tb:background
ICON_RENDER              :: rune(0xE182) // ph:film-slate
ICON_RENDER_PREVIEW      :: rune(0xE183) // tb:device-tv
ICON_STUDIO_RENDER       :: rune(0xE184) // ph:sun-horizon
ICON_RENDER_FULL         :: rune(0xE185) // ph:sparkle
ICON_PASSES              :: rune(0xE186) // tb:stack-3
ICON_SPACE_RENDER        :: rune(0xE187) // ph:aperture
ICON_SPACE_MODEL         :: rune(0xE188) // ph:cube-transparent
ICON_LIGHTS              :: rune(0xE189) // ph:sun
ICON_LIGHT_POINT         :: rune(0xE18A) // ph:lightbulb
ICON_LIGHT_SPOT          :: rune(0xE18B) // ph:lamp-pendant
ICON_LIGHT_AREA          :: rune(0xE18C) // tb:rectangle
ICON_LIGHT_SUN           :: rune(0xE18D) // tb:sun-low
ICON_PLACE_LIGHT         :: rune(0xE18E) // tb:bulb
ICON_ENVIRONMENT         :: rune(0xE18F) // tb:world-longitude
ICON_PASS_AO             :: rune(0xE190) // tb:circle-half
ICON_PASS_CURVATURE      :: rune(0xE191) // tb:chart-arcs
ICON_PASS_DEPTH          :: rune(0xE192) // tb:arrows-down-up
ICON_PASS_NORMALS        :: rune(0xE193) // tb:arrows-diagonal
ICON_PASS_SHADED         :: rune(0xE194) // tb:sun-high
ICON_PASS_SILHOUETTE     :: rune(0xE195) // ph:user-focus
ICON_PASS_SKIN           :: rune(0xE196) // tb:fingerprint
ICON_PASS_UNLIT          :: rune(0xE197) // tb:sun-off
ICON_SHADE_CLAY          :: rune(0xE198) // tb:sphere-plus
ICON_SHADE_FLAT          :: rune(0xE199) // tb:circle-half-vertical
ICON_SHADE_FULL          :: rune(0xE19A) // ph:sphere
ICON_SHADE_LIT           :: rune(0xE19B) // ph:sun-dim
ICON_SHADE_RENDERED      :: rune(0xE19C) // tb:stars
ICON_FILL_UPDATE         :: rune(0xE19D) // ph:arrows-counter-clockwise
ICON_BRUSH_ROTATE        :: rune(0xE19E) // ph:arrow-arc-right
ICON_BRUSH_THUMB         :: rune(0xE19F) // ph:hand-swipe-right
ICON_BRUSH_POSE          :: rune(0xE1A0) // ph:person-simple-tai-chi

ICON_GROUP_TABLE := [ICON_COUNT]Icon_Group {
	.App, // ICON_MENU
	.App, // ICON_MORE
	.App, // ICON_CLOSE
	.App, // ICON_CHECK
	.App, // ICON_UNCHECKED
	.App, // ICON_CHEVRON_DOWN
	.App, // ICON_CHEVRON_UP
	.App, // ICON_CHEVRON_LEFT
	.App, // ICON_CHEVRON_RIGHT
	.App, // ICON_GRIP
	.App, // ICON_MINIMISE
	.App, // ICON_RESTORE
	.App, // ICON_SEARCH
	.App, // ICON_ZOOM
	.App, // ICON_HELP
	.App, // ICON_TOUR
	.App, // ICON_TIPS
	.App, // ICON_TAG
	.App, // ICON_KEYBOARD
	.App, // ICON_STAR
	.App, // ICON_HEART
	.App, // ICON_PIN
	.App, // ICON_PIN_OFF
	.App, // ICON_LOCK
	.App, // ICON_LOCK_OPEN
	.App, // ICON_LINK
	.App, // ICON_FLAG
	.App, // ICON_FILTER
	.App, // ICON_BOOKMARK
	.App, // ICON_PLUS
	.App, // ICON_MINUS
	.App, // ICON_TRASH
	.App, // ICON_COPY
	.App, // ICON_DUPLICATE
	.App, // ICON_PASTE
	.App, // ICON_PENCIL
	.App, // ICON_RENAME
	.App, // ICON_UNDO
	.App, // ICON_REDO
	.App, // ICON_REVERT
	.App, // ICON_RELOAD
	.App, // ICON_SETTINGS
	.App, // ICON_BRUSH_VALUE
	.App, // ICON_COMMAND
	.App, // ICON_CUSTOMISE
	.App, // ICON_PANEL
	.App, // ICON_OPEN_CARD
	.App, // ICON_RESET_PANELS
	.App, // ICON_SPACE
	.App, // ICON_RESET_LAYOUT
	.App, // ICON_PIE
	.App, // ICON_EDIT_PIES
	.App, // ICON_BRUSH_PIE
	.App, // ICON_TO_TOP
	.App, // ICON_TO_BOTTOM
	.App, // ICON_DETAILS
	.App, // ICON_HOME
	.App, // ICON_MONITOR
	.App, // ICON_TABLET
	.File, // ICON_SEND
	.App, // ICON_HISTORY
	.App, // ICON_HISTORY_LIST
	.App, // ICON_HISTORY_STRIP
	.App, // ICON_TINT_STEP
	.App, // ICON_FIND_STEPS
	.App, // ICON_GO_HERE
	.App, // ICON_LOCATE
	.View, // ICON_EYE
	.View, // ICON_EYE_OFF
	.App, // ICON_PLAY
	.App, // ICON_PAUSE
	.App, // ICON_STOP
	.App, // ICON_RECORD
	.App, // ICON_SKIP_BACK
	.App, // ICON_SKIP_FORWARD
	.App, // ICON_STEP_BACK
	.App, // ICON_STEP_FORWARD
	.App, // ICON_REPLAY
	.App, // ICON_MACROS
	.App, // ICON_RUN_PLUGIN
	.App, // ICON_RUN_SCRIPT
	.App, // ICON_SAMPLES
	.App, // ICON_DIAGNOSTICS
	.App, // ICON_PEN
	.App, // ICON_PEN_EMPTY
	.App, // ICON_CHECK_OK
	.App, // ICON_CHECK_WAIT
	.App, // ICON_CHECK_WARN
	.File, // ICON_FILE
	.File, // ICON_FILE_GONE
	.File, // ICON_FOLDER
	.File, // ICON_FOLDER_PLUS
	.File, // ICON_LIBRARY
	.File, // ICON_NEW_SCENE
	.File, // ICON_OPEN
	.File, // ICON_SAVE
	.File, // ICON_SAVE_AS
	.File, // ICON_SAVE_NEXT
	.File, // ICON_SAVE_COPY
	.File, // ICON_EARLIER_SAVES
	.File, // ICON_RECENT
	.File, // ICON_AUTOSAVE
	.File, // ICON_IMPORT
	.File, // ICON_EXPORT
	.File, // ICON_EXPORT_SHEET
	.File, // ICON_INSTALL_PACK
	.File, // ICON_MAKE_PACK
	.File, // ICON_CRASH_LOG
	.File, // ICON_BLENDER_GET
	.File, // ICON_BLENDER_SEND
	.File, // ICON_FORMATS
	.File, // ICON_GAMEPAD
	.File, // ICON_PRINTER
	.File, // ICON_PRINT_EXPORT
	.File, // ICON_DOWNLOAD
	.File, // ICON_SCREENSHOT
	.File, // ICON_SCREENSHOT_CLEAR
	.File, // ICON_CAMERA_SHOT
	.File, // ICON_TURNTABLE
	.File, // ICON_FILM
	.File, // ICON_PAINT_MAPS
	.File, // ICON_IMAGE
	.File, // ICON_IMAGE_PLUS
	.File, // ICON_IMAGE_DOWN
	.File, // ICON_PHOTOS
	.Sculpt, // ICON_BRUSH
	.Sculpt, // ICON_SCULPT_TOOL
	.Sculpt, // ICON_BRUSH_PICKER
	.Sculpt, // ICON_PRESET
	.Sculpt, // ICON_PRESET_SAVE
	.Sculpt, // ICON_SIZE
	.Sculpt, // ICON_STRENGTH
	.Sculpt, // ICON_FOCAL
	.Sculpt, // ICON_SPACING
	.Sculpt, // ICON_LAZY
	.Sculpt, // ICON_PRESSURE
	.Sculpt, // ICON_EXPOSURE
	.Sculpt, // ICON_ADD
	.Sculpt, // ICON_SUBTRACT
	.Sculpt, // ICON_SYMMETRY
	.Sculpt, // ICON_LOCAL_SYMMETRY
	.Sculpt, // ICON_STROKE
	.Sculpt, // ICON_FALLOFF
	.Sculpt, // ICON_ALPHA
	.Sculpt, // ICON_RECALL
	.Sculpt, // ICON_PAINT_BACK
	.Sculpt, // ICON_STROKE_DOTS
	.Sculpt, // ICON_STROKE_RECT
	.Sculpt, // ICON_STROKE_SPRAY
	.Sculpt, // ICON_STROKE_ROLL
	.Sculpt, // ICON_STROKE_DRAG_DOT
	.Sculpt, // ICON_DYNTOPO
	.Sculpt, // ICON_REMESH
	.Sculpt, // ICON_HD
	.Sculpt, // ICON_LEVELS
	.Sculpt, // ICON_SUBDIVIDE
	.Sculpt, // ICON_LEVEL_UP
	.Sculpt, // ICON_LEVEL_DOWN
	.Sculpt, // ICON_DELETE_LEVELS
	.Sculpt, // ICON_MORPH
	.Sculpt, // ICON_MORPH_DELETE
	.Sculpt, // ICON_LAYERS
	.Sculpt, // ICON_MERGE
	.Sculpt, // ICON_VOXEL_CLAY
	.Sculpt, // ICON_SCULPT_MESH
	.Sculpt, // ICON_DEFORM
	.Sculpt, // ICON_DEFORMERS
	.Sculpt, // ICON_PHYSICS
	.Sculpt, // ICON_RECORDER
	.Sculpt, // ICON_HEIGHT
	.Sculpt, // ICON_SCULPT_SPACE
	.Sculpt, // ICON_BRUSH_DRAW
	.Sculpt, // ICON_BRUSH_SMOOTH
	.Sculpt, // ICON_BRUSH_CLAY
	.Sculpt, // ICON_BRUSH_FLATTEN
	.Sculpt, // ICON_BRUSH_INFLATE
	.Sculpt, // ICON_BRUSH_PINCH
	.Sculpt, // ICON_BRUSH_CREASE
	.Sculpt, // ICON_BRUSH_GRAB
	.Sculpt, // ICON_BRUSH_LAYER
	.Sculpt, // ICON_BRUSH_SNAKE_HOOK
	.Sculpt, // ICON_BRUSH_ELASTIC
	.Sculpt, // ICON_BRUSH_CLAY_STRIPS
	.Sculpt, // ICON_BRUSH_TRIM
	.Sculpt, // ICON_BRUSH_TUBE
	.Mask, // ICON_MASK
	.Mask, // ICON_MASK_KEY
	.Mask, // ICON_MASK_SHAPE
	.Mask, // ICON_LAYER_MASK
	.Mask, // ICON_INVERT
	.Mask, // ICON_INVERT_HIDDEN
	.Mask, // ICON_HIDE
	.Mask, // ICON_HIDE_UNMASKED
	.Mask, // ICON_HIDE_SHAPE
	.Mask, // ICON_SHOW_ALL
	.Mask, // ICON_SHOW_MASKED
	.Mask, // ICON_GROW
	.Mask, // ICON_SHRINK
	.Mask, // ICON_GROW_GROUPS
	.Mask, // ICON_OUTER_RING
	.Mask, // ICON_GROUPS
	.Mask, // ICON_RECT_SHAPE
	.Mask, // ICON_LASSO
	.Mask, // ICON_HIDE_RECT
	.Mask, // ICON_HIDE_LASSO
	.Mask, // ICON_CLIP
	.Mask, // ICON_SLICE
	.Mask, // ICON_KNIFE_GESTURE
	.Paint, // ICON_PAINT
	.Paint, // ICON_COLOUR
	.Paint, // ICON_SWAP_COLORS
	.Paint, // ICON_EYEDROPPER
	.Paint, // ICON_FILL
	.Paint, // ICON_FILL_GRADIENT
	.Paint, // ICON_CHANNEL_SCULPT
	.Paint, // ICON_CHANNEL_BOTH
	.Paint, // ICON_CHANNEL_COLOR
	.Paint, // ICON_COLOR_DISC
	.Paint, // ICON_COLOR_CLASSIC
	.Paint, // ICON_COLOR_HARMONY
	.Paint, // ICON_COLOR_VALUE
	.Paint, // ICON_PALETTES
	.Paint, // ICON_TEXTURES
	.Paint, // ICON_TEXTURE_TAB
	.Paint, // ICON_PROJECT
	.Paint, // ICON_UVS
	.Paint, // ICON_UNWRAP
	.Paint, // ICON_STRAIGHTEN_ISLANDS
	.Paint, // ICON_TEXEL_DENSITY
	.Paint, // ICON_MATERIAL
	.Paint, // ICON_METAL
	.Paint, // ICON_ROUGHNESS
	.Model, // ICON_MODEL
	.Model, // ICON_EDIT_CAGE
	.Model, // ICON_CAGE
	.Model, // ICON_CAGE_SELECT
	.Model, // ICON_CAGE_EDIT
	.Model, // ICON_CAGE_CHECK
	.Model, // ICON_CAGE_FLAT
	.Model, // ICON_CAGE_SMOOTH
	.Model, // ICON_THICKNESS
	.Model, // ICON_TIDY
	.Model, // ICON_APPLY_CAGE
	.Model, // ICON_MODEL_ACTION
	.Model, // ICON_MODEL_TARGET
	.Model, // ICON_INSERT
	.Model, // ICON_ADD_CAGE
	.Model, // ICON_ADD_OBJECT
	.Model, // ICON_EXTRUDE
	.Model, // ICON_INSET
	.Model, // ICON_MOVE_POINTS
	.Model, // ICON_DELETE_FACES
	.Model, // ICON_POLYGROUP
	.Model, // ICON_FLIP_FACES
	.Model, // ICON_INSERT_LOOP
	.Model, // ICON_REMOVE_LOOP
	.Model, // ICON_COLLAPSE
	.Model, // ICON_SPIN
	.Model, // ICON_CLOSE_HOLE
	.Model, // ICON_EXTRUDE_EDGE
	.Model, // ICON_BRIDGE
	.Model, // ICON_WELD
	.Model, // ICON_CONNECT
	.Model, // ICON_DISSOLVE_POINT
	.Model, // ICON_SELECT
	.Model, // ICON_CREASE
	.Model, // ICON_CREASE_POINT
	.Model, // ICON_BEVEL
	.Model, // ICON_CIRCLE_LOOP
	.Model, // ICON_SPACE_LOOP
	.Model, // ICON_FLATTEN_LOOP
	.Model, // ICON_KNIFE
	.Model, // ICON_ALIGN
	.Model, // ICON_SPINE
	.Model, // ICON_TOPO
	.Model, // ICON_LOOP_CURVE
	.Model, // ICON_MEASURE
	.Model, // ICON_SLIDE
	.Model, // ICON_RELAX
	.Model, // ICON_CUBE
	.Model, // ICON_PLANE
	.Model, // ICON_CYLINDER
	.Model, // ICON_SPHERE
	.Model, // ICON_TORUS
	.Model, // ICON_CONE
	.Model, // ICON_BOOLEAN
	.Model, // ICON_SPLIT
	.Model, // ICON_EXTRACT
	.Model, // ICON_RETOPO
	.Model, // ICON_SHARP
	.Model, // ICON_LIVE_STACK
	.Model, // ICON_STACK_ADD
	.Model, // ICON_STACK_APPLY
	.Model, // ICON_ARRAY
	.Model, // ICON_RADIAL
	.Model, // ICON_ALONG
	.Model, // ICON_STACK_BEVEL
	.Model, // ICON_DISPLACE
	.Model, // ICON_CAGE_DEFORM
	.Model, // ICON_CAGE_CURVE
	.Model, // ICON_CAGE_WRAP
	.Model, // ICON_CAGE_MIRROR
	.Model, // ICON_STACK_SMOOTH
	.Model, // ICON_CURVE
	.Model, // ICON_ADD_CURVE
	.Model, // ICON_CURVE_BAKE
	.Model, // ICON_CURVE_RUN
	.Model, // ICON_CURVE_LATHE
	.Model, // ICON_CURVE_LOFT
	.Model, // ICON_CURVE_PIPE
	.Model, // ICON_CURVE_USE
	.Model, // ICON_MESH
	.App, // ICON_SCENE
	.App, // ICON_OBJECTS
	.App, // ICON_OBJECT_MENU
	.App, // ICON_GHOST
	.App, // ICON_SOLO
	.App, // ICON_TRANSFORM
	.App, // ICON_MOVE_TOOL
	.App, // ICON_GIZMO
	.App, // ICON_GIZMO_ORIENT
	.App, // ICON_GIZMO_SNAP
	.App, // ICON_PIVOT
	.App, // ICON_PIVOT_CENTER
	.App, // ICON_PIVOT_RESET
	.App, // ICON_PIVOT_UNMASKED
	.App, // ICON_PIVOT_EDIT
	.App, // ICON_WORLD
	.App, // ICON_OBJECT_SPACE
	.App, // ICON_SURFACE
	.App, // ICON_VIEW_SPACE
	.App, // ICON_ALIGN_LEFT
	.App, // ICON_ALIGN_CENTER_H
	.App, // ICON_ALIGN_RIGHT
	.App, // ICON_ALIGN_BOTTOM
	.App, // ICON_ALIGN_CENTER_V
	.App, // ICON_ALIGN_TOP
	.App, // ICON_DISTRIBUTE_LEFT
	.App, // ICON_DISTRIBUTE_CENTER_H
	.App, // ICON_DISTRIBUTE_RIGHT
	.App, // ICON_DISTRIBUTE_BOTTOM
	.App, // ICON_DISTRIBUTE_CENTER_V
	.App, // ICON_DISTRIBUTE_TOP
	.App, // ICON_REFERENCES
	.App, // ICON_SHOW_REFS
	.App, // ICON_REF_PLANE
	.App, // ICON_SCAN
	.App, // ICON_STICKY_NOTE
	.App, // ICON_LAYOUT_DASHBOARD
	.App, // ICON_STRETCH_VERTICAL
	.App, // ICON_FLIP_PICTURE
	.App, // ICON_GREY
	.App, // ICON_TURN
	.App, // ICON_CROP
	.App, // ICON_ON_VIEW
	.App, // ICON_VIEW_BEHIND
	.App, // ICON_STRAIGHTEN
	.App, // ICON_SEND_TO_BACK
	.App, // ICON_HEAD
	.View, // ICON_CAMERA
	.View, // ICON_RESET_CAMERA
	.View, // ICON_FRAME
	.View, // ICON_FOCUS
	.View, // ICON_PICK_FOCUS
	.View, // ICON_ORTHO
	.View, // ICON_FLOOR
	.View, // ICON_VIEW_GRID
	.View, // ICON_WIREFRAME
	.View, // ICON_TRANSPARENCY
	.View, // ICON_CLEAN_VIEW
	.View, // ICON_VIEW_LAYOUT
	.View, // ICON_FOUR_VIEWS
	.View, // ICON_VIEW_WINDOW
	.View, // ICON_SECOND_VIEW
	.View, // ICON_VIEW_GUIDES
	.View, // ICON_VIEW_GUIDES_RESET
	.View, // ICON_ORBIT_VIEW
	.View, // ICON_FLIP_VIEW
	.View, // ICON_ROTATE_3D
	.View, // ICON_LOOK
	.View, // ICON_SHADING
	.View, // ICON_LAST_SHADING
	.View, // ICON_STYLE
	.View, // ICON_FINISH
	.View, // ICON_WIPE
	.View, // ICON_BACKGROUND
	.Render, // ICON_RENDER
	.Render, // ICON_RENDER_PREVIEW
	.Render, // ICON_STUDIO_RENDER
	.Render, // ICON_RENDER_FULL
	.Render, // ICON_PASSES
	.Render, // ICON_SPACE_RENDER
	.Render, // ICON_SPACE_MODEL
	.Render, // ICON_LIGHTS
	.Render, // ICON_LIGHT_POINT
	.Render, // ICON_LIGHT_SPOT
	.Render, // ICON_LIGHT_AREA
	.Render, // ICON_LIGHT_SUN
	.Render, // ICON_PLACE_LIGHT
	.Render, // ICON_ENVIRONMENT
	.Render, // ICON_PASS_AO
	.Render, // ICON_PASS_CURVATURE
	.Render, // ICON_PASS_DEPTH
	.Render, // ICON_PASS_NORMALS
	.Render, // ICON_PASS_SHADED
	.Render, // ICON_PASS_SILHOUETTE
	.Render, // ICON_PASS_SKIN
	.Render, // ICON_PASS_UNLIT
	.Render, // ICON_SHADE_CLAY
	.Render, // ICON_SHADE_FLAT
	.Render, // ICON_SHADE_FULL
	.Render, // ICON_SHADE_LIT
	.Render, // ICON_SHADE_RENDERED
	.Paint, // ICON_FILL_UPDATE
	.Sculpt, // ICON_BRUSH_ROTATE
	.Sculpt, // ICON_BRUSH_THUMB
	.Sculpt, // ICON_BRUSH_POSE
}
