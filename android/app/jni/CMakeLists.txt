# libmain.so: the Odin app (src/app, compiled to one arm64 object by Odin) linked with
# stb_truetype, plus libSDL3.so beside it. Gradle runs this with the NDK's toolchain
# (android/app/build.gradle); the pinned sources come from deps/ (scripts/setup_deps,
# and scripts/setup_android.bat on Windows).
cmake_minimum_required(VERSION 3.22)
project(sculpt C)
# The static libraries end up inside libmain.so.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

get_filename_component(SCULPT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(DEPS "${SCULPT_ROOT}/deps")
if(CMAKE_HOST_WIN32)
	set(ODIN "${DEPS}/odin/odin.exe")
else()
	set(ODIN "${DEPS}/odin/odin")
endif()
foreach(needed "${ODIN}" "${DEPS}/sdl3-src/CMakeLists.txt" "${DEPS}/odin/vendor/stb/lib/stb_truetype.a")
	if(NOT EXISTS "${needed}")
		message(FATAL_ERROR "${needed} is missing: run scripts/setup_deps, then on Windows scripts/setup_android.bat (README.md, Android)")
	endif()
endforeach()
if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
	message(FATAL_ERROR "Odin builds the app for arm64-v8a only, not ${ANDROID_ABI}")
endif()

# Google Play needs native libraries aligned for 16 KB pages (the sm-store skill); NDK
# r28 does this by default, and saying so keeps it true with any NDK.
add_link_options("-Wl,-z,max-page-size=16384")

# SDL3 as libSDL3.so, which SDLActivity loads before libmain.so.
set(SDL_SHARED ON CACHE BOOL "" FORCE)
set(SDL_STATIC OFF CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory("${DEPS}/sdl3-src" SDL3)

# stb_truetype (and stb_rect_pack, which its source file includes) for vendor:fontstash.
add_library(stb STATIC "${DEPS}/odin/vendor/stb/src/stb_truetype.c")
target_compile_options(stb PRIVATE -O2)

# The app itself. Odin rebuilds the object whenever a source, shader or font it embeds
# changes; it is always optimised, so a debug APK sculpts at full speed too.
set(ODIN_OBJECT "${CMAKE_CURRENT_BINARY_DIR}/sculpt.o")
file(GLOB_RECURSE ODIN_INPUTS CONFIGURE_DEPENDS
	"${SCULPT_ROOT}/src/*.odin"
	"${SCULPT_ROOT}/src/render/shaders/*.spv"
	"${SCULPT_ROOT}/assets/*"
)
add_custom_command(
	OUTPUT "${ODIN_OBJECT}"
	COMMAND "${CMAKE_COMMAND}" -E env "ODIN_ANDROID_NDK=${ANDROID_NDK}"
		"${ODIN}" build "${SCULPT_ROOT}/src/app"
		-target:linux_arm64 -subtarget:android -build-mode:obj -use-single-module -reloc-mode:pic
		"-out:${ODIN_OBJECT}" "-collection:deps=${DEPS}"
		-vet -strict-style -warnings-as-errors -o:speed -no-bounds-check
	DEPENDS ${ODIN_INPUTS}
	WORKING_DIRECTORY "${SCULPT_ROOT}"
	COMMENT "Odin: src/app for Android arm64"
	VERBATIM
)

add_library(main SHARED android_main.c "${ODIN_OBJECT}")
# nativewindow: android_main.c asks for the screen's frame rate (ANativeWindow_setFrameRate,
# API 30), which the NDK puts in libnativewindow, not libandroid.
target_link_libraries(main PRIVATE stb SDL3::SDL3-shared android nativewindow log m)
# Every symbol the Odin object needs must resolve now, not when the tablet loads it.
target_link_options(main PRIVATE "-Wl,--no-undefined")
