#!/usr/bin/env bash
# Usage: ./build.sh [debug|release|test|run|smoke|bench|gpubench|computebench|wincheck|androidcheck|iphonecheck|check|android|androidrun|ios|all|clean] [-- app args]
#   check   odin check with the strict flags on every package (no link, no shaders), then
#           python3 scripts/agents_sync.py --check (the skill mirror under .agents/ is current)
#   debug   (default) debug build with allocation tracking -> build/sculpt
#   release optimized build without bounds checks -> build/sculpt
#   test    run all package tests
#   run     debug build, then run it with the remaining args
#   bench   headless sculpt benchmark at 500k, 1M, 5M, 7M and 10M vertices (no display
#           needed); extra args go to build/bench, e.g. 2000000 --threads=1
#   smoke   debug build, then run 300 frames with GPU debug mode and a view window (a
#           second swapchain), once on SDL_GPU and once on the Vulkan backend; fails on
#           any SDL assert, GPU error, Vulkan validation message or leaked allocation
#           (needs a display, e.g. Xvfb)
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
#   iphonecheck compile the app for the iPad (arm64) to an object file, as `ios` does,
#           without Xcode or linking, so iOS-only compile errors show up anywhere
#   ios     macOS with Xcode only: build the iPad app (ios/, README.md "iPad") into an
#           unsigned build/ios/Sculpt.ipa, which AltStore signs on the iPad
#           (.github/workflows/ipad.yml runs it on GitHub's macOS runner)
#   all     everything that builds, stopping at the first failure: check, release, then
#           debug (build/sculpt is left as the debug app), test, iphonecheck, wincheck,
#           androidcheck, and the Android APK when the Android SDK is there; smoke and the
#           touch scenarios need a display, so scripts/gate.py runs them
#   clean   remove build/ and the Android build's outputs; deps/ stays
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Cleaning needs no toolchain, so it comes before the check for one.
if [ "${1:-}" = clean ]; then
	rm -rf "$ROOT/build" "$ROOT/android/.gradle" "$ROOT/android/build" "$ROOT/android/app/build" "$ROOT/android/app/.cxx"
	echo "clean: build/ and the Android build's outputs removed"
	exit 0
fi
DEPS="$ROOT/deps"
ODIN="$DEPS/odin/odin"
[ -x "$ODIN" ] || { echo "deps missing: run scripts/setup_deps.sh first"; exit 1; }

mode="${1:-debug}"; shift || true
[ "${1:-}" = "--" ] && shift

# Shaders are Slang: each name.stage.slang (stage vert, frag or comp) compiles to the
# name.stage.spv the renderer embeds, as SPIR-V 1.3 (Vulkan 1.1). The other .slang files
# are includes. Matrices are row-major, so mul(v, M) is GLSL's M * v (sm-render), and -O0
# leaves the arithmetic as written: the optimizer turns x / c into x * (1 / c), which moves
# pixels. A shader whose first line is "// slangc: -fp-mode precise" keeps every multiply
# and add unfused. Without deps/slang (scripts/setup_deps.sh) the committed .spv files are
# used as they are.
SLANGC="$DEPS/slang/bin/slangc"
compile_shaders() {
	[ -x "$SLANGC" ] || { echo "slangc missing: using the committed shaders"; return 0; }
	local src name stage flags
	for src in "$ROOT"/src/render/shaders/*.{vert,frag,comp}.slang; do
		name="${src%.slang}"
		case "${name##*.}" in vert) stage=vertex;; frag) stage=fragment;; comp) stage=compute;; esac
		flags=()
		if head -n 1 "$src" | grep -q '^// slangc: -fp-mode precise'; then flags=(-fp-mode precise); fi
		"$SLANGC" "$src" -target spirv -profile spirv_1_3 -matrix-layout-row-major -O0 -stage "$stage" -entry main "${flags[@]}" -o "$name.spv"
	done
	# Each new .spv's Metal source for the iPad build (scripts/shaders_msl.py), when
	# SDL_shadercross is built (scripts/build_shadercross.py); `check` fails on a stale one.
	if [ -x "$DEPS/shadercross/shadercross" ]; then
		python3 "$ROOT/scripts/shaders_msl.py"
	else
		echo "shadercross missing: the committed .msl files are kept"
	fi
}

common=(-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors
	"-extra-linker-flags:-L$DEPS/sdl3/lib -Wl,-rpath,$DEPS/sdl3/lib")

# The app links Luau for script plugins, which setup_deps builds from source.
need_luau() {
	[ -f "$DEPS/luau/libluau.a" ] || { echo "Luau missing: run scripts/setup_deps.sh, which builds deps/luau"; exit 1; }
}

# The oldest iPadOS the iPad build runs on. From 17.4 Odin's thread waits use the public
# os_sync_wait_on_address; below it they fall back to a private call App Review refuses.
IOS_MIN=17.4

# The app for the iPad as one arm64 object, which `ios` links and `iphonecheck` stops at.
# SCULPT_DIAGNOSTICS=1 makes it a developer build that reaches Input diagnostics, and
# SCULPT_VERSION names it in the reports; .github/workflows/ipad.yml sets both for the
# AltStore IPA. A build without them, as a store build must be, has neither (sm-store).
# Odin reads a -define value as a literal, so a version that reads as a number (an all-digit
# hash, 12345e6, 0b101) would not compile: give it a letter first, as ipad.yml's g<hash>.
ios_object() {
	mkdir -p "$ROOT/build/ios"
	local defines=()
	if [ "${SCULPT_DIAGNOSTICS:-}" = 1 ]; then defines+=(-define:SCULPT_DIAGNOSTICS=true); fi
	if [ -n "${SCULPT_VERSION:-}" ]; then defines+=("-define:SCULPT_VERSION=$SCULPT_VERSION"); fi
	# macOS's bash 3.2 calls an empty array unbound under set -u, hence the +.
	"$ODIN" build "$ROOT/src/app" -target:darwin_arm64 -subtarget:iphone -build-mode:obj -use-single-module \
		-minimum-os-version:"$IOS_MIN" -out:"$ROOT/build/ios/sculpt.o" \
		-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors -o:speed -no-bounds-check \
		${defines[@]+"${defines[@]}"}
}

mkdir -p "$ROOT/build"
case "$mode" in
	debug|run|smoke)
		need_luau
		compile_shaders
		"$ODIN" build "$ROOT/src/app" -out:"$ROOT/build/sculpt" -debug "${common[@]}"
		if [ "$mode" = run ]; then exec "$ROOT/build/sculpt" "$@"; fi
		# The smoke runs once on each GPU backend; a Vulkan validation message fails it.
		if [ "$mode" = smoke ]; then
			SDL_ASSERT=abort "$ROOT/build/sculpt" --frames=300 --gpu-debug --view-windows=1 --gpu=sdl "$@"
			SDL_ASSERT=abort exec "$ROOT/build/sculpt" --frames=300 --gpu-debug --view-windows=1 --gpu=vulkan "$@"
		fi
		;;
	release|gpubench|computebench)
		need_luau
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
		need_luau
		for pkg in geom poly camera sculpt jobs gizmo png_write zip voxel ui luau usd app; do
			"$ODIN" test "$ROOT/src/$pkg" -out:"$ROOT/build/test_$pkg" "${common[@]}"
		done
		;;
	check)
		# Library packages have no main, hence -no-entry-point; it is harmless on the executables.
		# odin check takes no linker flags, so this is wincheck's flag list, not common's.
		for pkg in app bench geom camera gizmo jobs luau png_write poly render sculpt sdf_trial ui usd voxel zip; do
			"$ODIN" check "$ROOT/src/$pkg" -no-entry-point \
				-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors
		done
		python3 "$ROOT/scripts/agents_sync.py" --check
		python3 "$ROOT/scripts/boundary_check.py"
		python3 "$ROOT/scripts/shaders_msl.py" --check
		echo "check: 16 packages type-check, agent mirror current, only render names the GPU API, Metal shaders current"
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
	all)
		# One mode per run of this script, as a person would run them, so each keeps its own setup.
		for step in check release debug test iphonecheck wincheck androidcheck; do
			"$ROOT/build.sh" "$step"
		done
		if [ -d "${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools" ]; then
			"$ROOT/build.sh" android
			echo "all: check, release, debug, test, iphonecheck, wincheck, androidcheck and android done; build/sculpt is the debug app"
		else
			echo "all: check, release, debug, test, iphonecheck, wincheck and androidcheck done; no Android SDK, so no APK; build/sculpt is the debug app"
		fi
		;;
	iphonecheck)
		ios_object
		echo "iphonecheck: app compiles for the iPad (arm64, iPadOS $IOS_MIN)"
		;;
	ios)
		# SDL3 as a static library, the app's object, stb_truetype and ios/sculpt_ios.m (the
		# file dialogs SDL lacks on iOS), linked by Xcode's clang into Sculpt.app, then zipped
		# unsigned: AltStore signs it with the person's Apple Account on the iPad.
		[ "$(uname)" = Darwin ] || { echo "ios needs macOS with Xcode; ./build.sh iphonecheck compiles the app for the iPad anywhere"; exit 1; }
		[ -f "$DEPS/sdl3-src/CMakeLists.txt" ] || { echo "SDL source missing: clone SDL_TAG (scripts/versions.env) into deps/sdl3-src"; exit 1; }
		command -v pkg-config > /dev/null || { echo "pkg-config missing: brew install pkgconf"; exit 1; }
		out="$ROOT/build/ios"
		app="$out/Payload/Sculpt.app"
		cc=(xcrun -sdk iphoneos clang -target "arm64-apple-ios$IOS_MIN")
		[ -f "$out/sdl/lib/libSDL3.a" ] || "$ROOT/scripts/sdl_ios.sh" "$IOS_MIN" "$DEPS/sdl3-src" "$out"
		# Every Metal shader through Apple's own compiler, so a translation error stops the
		# build here rather than on the iPad, where SDL compiles each from source when the app
		# first makes its pipeline (scripts/shaders_msl.py made them). A shader whose source and
		# compiler match those it last passed with (its .sum beside its .air, which the iPad
		# workflow keeps in its cache) is not checked again.
		mkdir -p "$out/msl"
		metal_version=$(xcrun -sdk iphoneos metal --version 2>&1 | head -n 1)
		for msl in "$ROOT"/src/render/shaders/*.msl; do
			air="$out/msl/$(basename "$msl" .msl)"
			sum=$({ echo "$metal_version"; cat "$msl"; } | shasum -a 256 | cut -d' ' -f1)
			if [ -f "$air.air" ] && [ "$(cat "$air.sum" 2> /dev/null)" = "$sum" ]; then continue; fi
			xcrun -sdk iphoneos metal -x metal -c "$msl" -o "$air.air"
			echo "$sum" > "$air.sum"
		done
		ios_object
		"${cc[@]}" -O2 -c "$DEPS/odin/vendor/stb/src/stb_truetype.c" -o "$out/stb_truetype.o"
		"${cc[@]}" -O2 -Wall -fobjc-arc -I"$out/sdl/include" -c "$ROOT/ios/sculpt_ios.m" -o "$out/sculpt_ios.o"
		rm -rf "$out/Payload"
		mkdir -p "$app"
		# SDL's pkg-config file names the libraries and frameworks it needs; the document
		# picker's content types are one more.
		libs=$(PKG_CONFIG_PATH="$out/sdl/lib/pkgconfig" pkg-config --static --libs sdl3)
		[ -n "$libs" ] || { echo "pkg-config gave no flags for SDL's static library"; exit 1; }
		read -r -a sdl_libs <<< "$libs"
		"${cc[@]}" "$out/sculpt.o" "$out/stb_truetype.o" "$out/sculpt_ios.o" "${sdl_libs[@]}" \
			-framework UniformTypeIdentifiers -o "$app/Sculpt"
		cp "$ROOT/ios/Info.plist" "$app/Info.plist"
		plutil -replace MinimumOSVersion -string "$IOS_MIN" "$app/Info.plist"
		plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-1}" "$app/Info.plist"
		plutil -lint "$app/Info.plist"
		(cd "$out" && rm -f Sculpt.ipa && zip -qry Sculpt.ipa Payload)
		echo "ios: build/ios/Sculpt.ipa (unsigned; AltStore signs it on the iPad)"
		;;
	*) echo "unknown mode: $mode"; exit 1 ;;
esac
