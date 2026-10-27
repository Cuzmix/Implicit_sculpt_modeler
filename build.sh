#!/usr/bin/env bash
# Usage: ./build.sh [debug|release|test|run|smoke|bench|gpubench|computebench|wincheck|androidcheck|check|android|androidrun] [-- app args]
#   check   odin check with the strict flags on every package (no link, no shaders), then
#           python3 scripts/agents_sync.py --check (the skill mirror under .agents/ is current)
#   debug   (default) debug build with allocation tracking -> build/sculpt
#   release optimized build without bounds checks -> build/sculpt
#   test    run all package tests
#   run     debug build, then run it with the remaining args
#   bench   headless sculpt benchmark at 500k, 1M, 5M, 7M and 10M vertices (no display
#           needed); extra args go to build/bench, e.g. 2000000 --threads=1
#   smoke   debug build, then run 300 frames with GPU debug mode; fails on any
#           SDL assert, GPU error or leaked allocation (needs a display, e.g. Xvfb)
#   gpubench release build, then time the GPU and CPU while orbiting and sculpting a
#           sphere at 500k, 1M, 5M, 7M and 10M vertices, with each speed setting on and
#           off; prints markdown tables and writes them to build/gpubench.md (needs a
#           display; use a real GPU for meaningful numbers)
#   computebench release build, then time Smooth all on the CPU and as a GPU compute
#           shader (upload and readback included) at the same sizes, check the GPU's
#           result against the CPU's, and write build/computebench.md (needs a display)
#   wincheck compile the app and bench for Windows (x64) to object files, without
#           linking, so Windows-only compile errors show up on Linux too
#   androidcheck compile the app for Android (arm64) to an object file, as the Android
#           build does, without the NDK or linking
#   android build the Android app (android/, README.md "Android") into a debug APK with
#           Gradle and the Android SDK and NDK (ANDROID_HOME, default ~/Android/Sdk)
#   androidrun the same, then install it on the device adb sees and start it
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPS="$ROOT/deps"
ODIN="$DEPS/odin/odin"
[ -x "$ODIN" ] || { echo "deps missing: run scripts/setup_deps.sh first"; exit 1; }

mode="${1:-debug}"; shift || true
[ "${1:-}" = "--" ] && shift

compile_shaders() {
	for src in "$ROOT"/src/render/shaders/*.{vert,frag,comp}; do
		glslangValidator -V --quiet "$src" -o "$src.spv"
	done
}

common=(-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors
	"-extra-linker-flags:-L$DEPS/sdl3/lib -Wl,-rpath,$DEPS/sdl3/lib")

mkdir -p "$ROOT/build"
case "$mode" in
	debug|run|smoke)
		compile_shaders
		"$ODIN" build "$ROOT/src/app" -out:"$ROOT/build/sculpt" -debug "${common[@]}"
		if [ "$mode" = run ]; then exec "$ROOT/build/sculpt" "$@"; fi
		if [ "$mode" = smoke ]; then SDL_ASSERT=abort exec "$ROOT/build/sculpt" --frames=300 --gpu-debug "$@"; fi
		;;
	release|gpubench|computebench)
		compile_shaders
		"$ODIN" build "$ROOT/src/app" -out:"$ROOT/build/sculpt" -o:speed -no-bounds-check "${common[@]}"
		if [ "$mode" = gpubench ]; then exec "$ROOT/build/sculpt" --gpubench "$ROOT/build/gpubench.md" "$@"; fi
		if [ "$mode" = computebench ]; then exec "$ROOT/build/sculpt" --compute-bench "$ROOT/build/computebench.md" "$@"; fi
		;;
	bench)
		"$ODIN" build "$ROOT/src/bench" -out:"$ROOT/build/bench" -o:speed -no-bounds-check "${common[@]}"
		"$ROOT/build/bench" "$@"
		;;
	test)
		compile_shaders
		for pkg in geom camera sculpt voxel jobs gizmo png_write ui app; do
			"$ODIN" test "$ROOT/src/$pkg" -out:"$ROOT/build/test_$pkg" "${common[@]}"
		done
		;;
	check)
		# Library packages have no main, hence -no-entry-point; it is harmless on the executables.
		# odin check takes no linker flags, so this is wincheck's flag list, not common's.
		for pkg in app bench geom camera gizmo jobs png_write render sculpt sdf_trial ui voxel; do
			"$ODIN" check "$ROOT/src/$pkg" -no-entry-point \
				-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors
		done
		python3 "$ROOT/scripts/agents_sync.py" --check
		echo "check: 12 packages type-check, agent mirror current"
		;;
	wincheck)
		# Object files need no Windows SDK; the empty root only satisfies the flag.
		out="$ROOT/build/wincheck"
		mkdir -p "$out/sdk"
		# vendor:stb refuses to compile for Windows unless its .lib files exist, and only
		# Windows can build them. Object files never link, so an Odin root in build/ that
		# shares everything with deps/odin but has empty stand-ins for those files is
		# enough; deps/ itself stays untouched.
		root="$out/odin_root"
		rm -rf "$root"
		mkdir -p "$root/vendor/stb/lib"
		for entry in "$DEPS/odin"/*; do
			[ "$(basename "$entry")" = vendor ] || ln -s "$entry" "$root/"
		done
		for entry in "$DEPS/odin"/vendor/*; do
			[ "$(basename "$entry")" = stb ] || ln -s "$entry" "$root/vendor/"
		done
		for entry in "$DEPS/odin"/vendor/stb/*; do
			name=$(basename "$entry")
			[ "$name" = lib ] && continue
			# Copied, not linked: stb finds its libraries relative to its own files.
			cp -r "$entry" "$root/vendor/stb/"
		done
		cp -r "$DEPS/odin"/vendor/stb/lib/. "$root/vendor/stb/lib/"
		for lib in stb_truetype stb_rect_pack stb_image stb_image_write stb_image_resize stb_sprintf stb_vorbis; do
			: > "$root/vendor/stb/lib/$lib.lib"
		done
		export ODIN_ROOT="$root"
		for pkg in app bench; do
			"$ODIN" build "$ROOT/src/$pkg" -target:windows_amd64 -build-mode:obj \
				-windows-sdk-root:"$out/sdk" -out:"$out/$pkg.obj" \
				-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors
		done
		echo "wincheck: app and bench compile for windows_amd64"
		;;
	androidcheck)
		# Odin wants an NDK path for Android even when it only writes an object file; an
		# empty folder does, since nothing is linked here.
		out="$ROOT/build/android"
		mkdir -p "$out/no-ndk"
		ODIN_ANDROID_NDK="$out/no-ndk" "$ODIN" build "$ROOT/src/app" \
			-target:linux_arm64 -subtarget:android -build-mode:obj -use-single-module -reloc-mode:pic \
			-out:"$out/sculpt.o" -collection:deps="$DEPS" -vet -strict-style -warnings-as-errors -o:speed -no-bounds-check
		echo "androidcheck: app compiles for Android arm64"
		;;
	android|androidrun)
		export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
		[ -f "$DEPS/sdl3-src/CMakeLists.txt" ] || { echo "SDL source missing: run scripts/setup_deps.sh first"; exit 1; }
		[ -d "$ANDROID_HOME/platform-tools" ] || { echo "no Android SDK in $ANDROID_HOME: install Android Studio, or set ANDROID_HOME"; exit 1; }
		if [ "$mode" = android ]; then
			(cd "$ROOT/android" && ./gradlew assembleDebug)
			echo "android: android/app/build/outputs/apk/debug/app-debug.apk"
		else
			(cd "$ROOT/android" && ./gradlew installDebug)
			"$ANDROID_HOME/platform-tools/adb" shell am start -n io.github.cuzmix.sculpt/org.libsdl.app.SDLActivity
		fi
		;;
	*) echo "unknown mode: $mode"; exit 1 ;;
esac
