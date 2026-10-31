#!/usr/bin/env bash
# Usage: ./build.sh [debug|release|test|run|smoke|bench|gpubench|computebench|wincheck|androidcheck|iphonecheck|maccheck|check|android|androidrun|ios|iosupload|mac|macnotarize|all|clean] [-- app args]
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
#           sphere at 500k, 1M, 5M, 7M, 10M and 20M vertices, with each speed setting on and
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
#   ios     macOS with Xcode only: build the iPad app (ios/, README.md "iPad") into
#           build/ios/Sculpt.ipa, unsigned for AltStore to sign on the iPad, or signed for
#           TestFlight and the App Store when SCULPT_SIGN_IDENTITY and SCULPT_PROFILE are set
#           (.github/workflows/ipad.yml runs it on GitHub's macOS runner)
#   iosupload macOS only: send the signed build/ios/Sculpt.ipa to App Store Connect for
#           TestFlight (ASC_KEY_ID, ASC_ISSUER_ID and the API key's .p8)
#   maccheck compile the app for the Mac (Apple silicon) to an object file, as `mac` does,
#           without Xcode or linking, so Mac-only compile errors show up anywhere
#   mac     macOS with Xcode only: build the Mac app (mac/, README.md "Mac") into
#           build/mac/Sculpt-mac.zip, signed ad hoc, or with the Developer ID certificate
#           SCULPT_MAC_IDENTITY names (.github/workflows/mac.yml runs it on GitHub's Mac)
#   macnotarize macOS only: notarize and staple that Developer ID build (ASC_KEY_ID, ...)
#   all     everything that builds, stopping at the first failure: check, release, then
#           debug (build/sculpt is left as the debug app), test, iphonecheck, maccheck, wincheck,
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
# and add unfused. A shader whose first line starts "// vulkan only" indexes texture arrays,
# for which Slang raises the profile with SPV_EXT_descriptor_indexing on purpose, so that
# warning (41012) is quieted for it; it has no Metal source (scripts/shaders_msl.py). Without deps/slang (scripts/setup_deps.sh) the committed .spv files are
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
		if head -n 1 "$src" | grep -q '^// vulkan only'; then flags+=(-warnings-disable 41012); fi
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

# The app links Luau for script plugins and ufbx for FBX import, which setup_deps builds
# from source.
need_luau() {
	[ -f "$DEPS/luau/libluau.a" ] || { echo "Luau missing: run scripts/setup_deps.sh, which builds deps/luau"; exit 1; }
	# And ufbx for FBX import, with the app's shim round it (scripts/build_ufbx.py).
	[ -f "$DEPS/ufbx/libufbx.a" ] || { echo "ufbx missing: run scripts/setup_deps.sh, which builds deps/ufbx"; exit 1; }
	# A shim changed since the library was built is compiled again (a library built from
	# this shim and tag is kept, so this costs nothing most runs).
	python3 "$ROOT/scripts/build_ufbx.py" > /dev/null || { echo "ufbx: src/fbx/fbx_shim.c changed and rebuilding deps/ufbx failed: run python3 scripts/build_ufbx.py"; exit 1; }
	# And AutoRemesher's core for Quad Remesh, with its boundary (scripts/build_autoremesher.py).
	[ -f "$DEPS/autoremesher/libautoremesher.a" ] || { echo "AutoRemesher missing: run scripts/setup_deps.sh, which builds deps/autoremesher"; exit 1; }
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

# The oldest macOS the Mac app runs on: as on the iPad, Odin's thread waits use the public
# os_sync_wait_on_address from 14.4, which keeps the Mac App Store open to the same build.
MAC_MIN=14.4

# The app for the Mac (Apple silicon) as one object, which `mac` links and `maccheck` stops
# at. SCULPT_DIAGNOSTICS and SCULPT_VERSION as for the iPad.
mac_object() {
	mkdir -p "$ROOT/build/mac"
	local defines=()
	if [ "${SCULPT_DIAGNOSTICS:-}" = 1 ]; then defines+=(-define:SCULPT_DIAGNOSTICS=true); fi
	if [ -n "${SCULPT_VERSION:-}" ]; then defines+=("-define:SCULPT_VERSION=$SCULPT_VERSION"); fi
	"$ODIN" build "$ROOT/src/app" -target:darwin_arm64 -build-mode:obj -use-single-module \
		-minimum-os-version:"$MAC_MIN" -out:"$ROOT/build/mac/sculpt.o" \
		-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors -o:speed -no-bounds-check \
		${defines[@]+"${defines[@]}"}
}

# Writes into the Info.plist at $1 the keys Xcode puts in every app it builds, naming the
# SDK ($2: iphoneos or macosx) and the Xcode it was built with: the App Store's upload checks
# read them, and these builds use Xcode's clang without an Xcode project.
apple_plist_keys() {
	local plist=$1 sdk=$2
	local sdk_version sdk_build xcode_version xcode_build
	sdk_version=$(xcrun -sdk "$sdk" --show-sdk-version)
	sdk_build=$(xcrun -sdk "$sdk" --show-sdk-build-version)
	# DTXcode is the version's digits, major then minor then patch: 26.0 is 2600.
	xcode_version=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\)\.\([0-9]\)\(\.\([0-9]\)\)\{0,1\}.*/\1\2\40/p' | cut -c1-4)
	xcode_build=$(xcodebuild -version | sed -n 's/^Build version //p')
	plutil -replace DTPlatformName -string "$sdk" "$plist"
	plutil -replace DTPlatformVersion -string "$sdk_version" "$plist"
	plutil -replace DTPlatformBuild -string "$sdk_build" "$plist"
	plutil -replace DTSDKName -string "$sdk$sdk_version" "$plist"
	plutil -replace DTSDKBuild -string "$sdk_build" "$plist"
	plutil -replace DTXcode -string "$xcode_version" "$plist"
	plutil -replace DTXcodeBuild -string "$xcode_build" "$plist"
	plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$plist"
	plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$plist"
}

# The app icon for platform $1 (iphoneos or macosx), compiled into the folder $2 and its keys
# merged into the Info.plist at $3; the rest are actool's flags. An asset catalog is made in
# build/ from the one 1024-point picture, assets/icon/sculpt-1024.png, which actool turns
# into the icon files (Assets.car, and AppIcon.icns on the Mac); the App Store refuses an
# app without them.
apple_icon() {
	local platform=$1 dest=$2 plist=$3
	shift 3
	local icon="$ROOT/assets/icon/sculpt-1024.png" catalog="$ROOT/build/icon-$platform/Assets.xcassets"
	[ -f "$icon" ] || { echo "app icon missing: $icon"; exit 1; }
	rm -rf "$catalog"
	mkdir -p "$catalog/AppIcon.appiconset"
	cp "$icon" "$catalog/AppIcon.appiconset/AppIcon.png"
	printf '{"info":{"author":"xcode","version":1}}\n' > "$catalog/Contents.json"
	local os=ios
	[ "$platform" = macosx ] && os=macos
	printf '{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"%s","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n' "$os" \
		> "$catalog/AppIcon.appiconset/Contents.json"
	xcrun actool "$catalog" --compile "$dest" --platform "$platform" --app-icon AppIcon \
		--output-partial-info-plist "$ROOT/build/icon-$platform/icon.plist" \
		--errors --warnings --output-format human-readable-text "$@"
	/usr/libexec/PlistBuddy -c "Merge $ROOT/build/icon-$platform/icon.plist" "$plist"
}

# Every Metal shader through Apple's own compiler for SDK $1 (iphoneos or macosx), into
# build/$2/msl, so a translation error stops the build here rather than on the device, where
# SDL compiles each from source when the app first makes its pipeline (scripts/shaders_msl.py
# made them). A shader whose source and compiler match those it last passed with (its .sum
# beside its .air, which the workflows keep in their caches) is not checked again.
metal_check() {
	local sdk=$1 out="$ROOT/build/$2/msl"
	mkdir -p "$out"
	local metal_version
	metal_version=$(xcrun -sdk "$sdk" metal --version 2>&1 | head -n 1)
	for msl in "$ROOT"/src/render/shaders/*.msl; do
		local air sum
		air="$out/$(basename "$msl" .msl)"
		sum=$({ echo "$metal_version"; cat "$msl"; } | shasum -a 256 | cut -d' ' -f1)
		if [ -f "$air.air" ] && [ "$(cat "$air.sum" 2> /dev/null)" = "$sum" ]; then continue; fi
		xcrun -sdk "$sdk" metal -x metal -c "$msl" -o "$air.air"
		echo "$sum" > "$air.sum"
	done
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
		for pkg in geom poly camera sculpt jobs gizmo png_write zip voxel ui luau usd fbx quadmesh app; do
			"$ODIN" test "$ROOT/src/$pkg" -out:"$ROOT/build/test_$pkg" "${common[@]}"
		done
		;;
	check)
		# Library packages have no main, hence -no-entry-point; it is harmless on the executables.
		# odin check takes no linker flags, so this is wincheck's flag list, not common's.
		for pkg in app bench fbx geom camera gizmo jobs luau png_write poly quadmesh render sculpt ui usd voxel zip; do
			"$ODIN" check "$ROOT/src/$pkg" -no-entry-point \
				-collection:deps="$DEPS" -vet -strict-style -warnings-as-errors
		done
		python3 "$ROOT/scripts/agents_sync.py" --check
		python3 "$ROOT/scripts/boundary_check.py"
		python3 "$ROOT/scripts/shaders_msl.py" --check
		echo "check: 18 packages type-check, agent mirror current, only render names the GPU API, Metal shaders current"
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
		for step in check release debug test iphonecheck maccheck wincheck androidcheck; do
			"$ROOT/build.sh" "$step"
		done
		if [ -d "${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools" ]; then
			"$ROOT/build.sh" android
			echo "all: check, release, debug, test, iphonecheck, maccheck, wincheck, androidcheck and android done; build/sculpt is the debug app"
		else
			echo "all: check, release, debug, test, iphonecheck, maccheck, wincheck and androidcheck done; no Android SDK, so no APK; build/sculpt is the debug app"
		fi
		;;
	iphonecheck)
		ios_object
		echo "iphonecheck: app compiles for the iPad (arm64, iPadOS $IOS_MIN)"
		;;
	ios)
		# SDL3 as a static library, the app's object, stb_truetype and ios/sculpt_ios.m (the
		# file dialogs SDL lacks on iOS), linked by Xcode's clang into Sculpt.app, then zipped:
		# unsigned for AltStore to sign with the person's Apple Account on the iPad, or signed
		# here for the App Store.
		[ "$(uname)" = Darwin ] || { echo "ios needs macOS with Xcode; ./build.sh iphonecheck compiles the app for the iPad anywhere"; exit 1; }
		[ -f "$DEPS/sdl3-src/CMakeLists.txt" ] || { echo "SDL source missing: clone SDL_TAG (scripts/versions.env) into deps/sdl3-src"; exit 1; }
		[ -f "$DEPS/ufbx-src/ufbx.c" ] || { echo "ufbx source missing: clone UFBX_TAG (scripts/versions.env) into deps/ufbx-src"; exit 1; }
		command -v pkg-config > /dev/null || { echo "pkg-config missing: brew install pkgconf"; exit 1; }
		out="$ROOT/build/ios"
		app="$out/Payload/Sculpt.app"
		cc=(xcrun -sdk iphoneos clang -target "arm64-apple-ios$IOS_MIN")
		[ -f "$out/sdl/lib/libSDL3.a" ] || "$ROOT/scripts/sdl_ios.sh" "$IOS_MIN" "$DEPS/sdl3-src" "$out"
		metal_check iphoneos ios
		ios_object
		"${cc[@]}" -O2 -c "$DEPS/odin/vendor/stb/src/stb_truetype.c" -o "$out/stb_truetype.o"
		# ufbx with the app's shim round it, for FBX import (src/fbx).
		"${cc[@]}" -O2 -w -I"$DEPS/ufbx-src" -c "$ROOT/src/fbx/fbx_shim.c" -o "$out/ufbx.o"
		"${cc[@]}" -O2 -Wall -fobjc-arc -I"$out/sdl/include" -c "$ROOT/ios/sculpt_ios.m" -o "$out/sculpt_ios.o"
		rm -rf "$out/Payload"
		mkdir -p "$app"
		# SDL's pkg-config file names the libraries and frameworks it needs; the document
		# picker's content types are one more.
		libs=$(PKG_CONFIG_PATH="$out/sdl/lib/pkgconfig" pkg-config --static --libs sdl3)
		[ -n "$libs" ] || { echo "pkg-config gave no flags for SDL's static library"; exit 1; }
		read -r -a sdl_libs <<< "$libs"
		"${cc[@]}" "$out/sculpt.o" "$out/stb_truetype.o" "$out/ufbx.o" "$out/sculpt_ios.o" "${sdl_libs[@]}" \
			-framework UniformTypeIdentifiers -o "$app/Sculpt"
		cp "$ROOT/ios/Info.plist" "$app/Info.plist"
		plutil -replace MinimumOSVersion -string "$IOS_MIN" "$app/Info.plist"
		plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-1}" "$app/Info.plist"
		apple_plist_keys "$app/Info.plist" iphoneos
		apple_icon iphoneos "$app" "$app/Info.plist" --target-device ipad --minimum-deployment-target "$IOS_MIN"
		plutil -lint "$app/Info.plist"
		# The privacy manifest: the "required reason" APIs the app and SDL call (sm-store).
		cp "$ROOT/ios/PrivacyInfo.xcprivacy" "$app/PrivacyInfo.xcprivacy"
		plutil -lint "$app/PrivacyInfo.xcprivacy"
		if [ -n "${SCULPT_SIGN_IDENTITY:-}" ]; then
			# Signed for TestFlight and the App Store: the distribution certificate named by
			# SCULPT_SIGN_IDENTITY (in the keychain) and the App Store provisioning profile at
			# SCULPT_PROFILE, whose entitlements the signature carries. A store build is never
			# a developer build (sm-store: no debug panels reachable).
			[ "${SCULPT_DIAGNOSTICS:-}" != 1 ] || { echo "a signed store build cannot be a developer build: unset SCULPT_DIAGNOSTICS"; exit 1; }
			[ -f "${SCULPT_PROFILE:-}" ] || { echo "SCULPT_PROFILE must name the App Store provisioning profile (.mobileprovision)"; exit 1; }
			cp "$SCULPT_PROFILE" "$app/embedded.mobileprovision"
			security cms -D -i "$SCULPT_PROFILE" > "$out/profile.plist"
			/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$out/profile.plist" > "$out/entitlements.plist"
			codesign --force --sign "$SCULPT_SIGN_IDENTITY" --entitlements "$out/entitlements.plist" --generate-entitlement-der "$app"
			codesign --verify --strict "$app"
		fi
		(cd "$out" && rm -f Sculpt.ipa && zip -qry Sculpt.ipa Payload)
		if [ -n "${SCULPT_SIGN_IDENTITY:-}" ]; then
			echo "ios: build/ios/Sculpt.ipa (signed for the App Store; build ${BUILD_NUMBER:-1})"
		else
			echo "ios: build/ios/Sculpt.ipa (unsigned; AltStore signs it on the iPad)"
		fi
		;;
	iosupload)
		# Sends build/ios/Sculpt.ipa, signed for the App Store by `ios`, to App Store Connect,
		# where it shows in TestFlight once Apple has processed it. The App Store Connect API
		# key's id and issuer come from ASC_KEY_ID and ASC_ISSUER_ID, and altool reads the key
		# itself from ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
		[ "$(uname)" = Darwin ] || { echo "iosupload needs macOS with Xcode"; exit 1; }
		[ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || { echo "set ASC_KEY_ID and ASC_ISSUER_ID (App Store Connect > Users and Access > Integrations)"; exit 1; }
		[ -f "$ROOT/build/ios/Sculpt.ipa" ] || { echo "no build/ios/Sculpt.ipa: run SCULPT_SIGN_IDENTITY=... SCULPT_PROFILE=... ./build.sh ios first"; exit 1; }
		xcrun altool --upload-app --type ios --file "$ROOT/build/ios/Sculpt.ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
		;;
	maccheck)
		mac_object
		echo "maccheck: app compiles for the Mac (Apple silicon, macOS $MAC_MIN)"
		;;
	mac)
		# The Mac app as the iPad's is made: SDL3 as a static library, the app's object,
		# stb_truetype and ufbx linked by Xcode's clang into Sculpt.app, with the icon, the
		# privacy manifest and the toolchain's keys, then zipped as build/mac/Sculpt-mac.zip.
		# SDL has the Mac's file dialogs, so no native code of the app's own is needed. With
		# SCULPT_MAC_IDENTITY (a Developer ID Application certificate in the keychain) it is
		# signed with the hardened runtime for notarizing (`macnotarize`); without, signed ad
		# hoc, which Apple silicon needs to run it at all, for this Mac or one that allows it.
		[ "$(uname)" = Darwin ] || { echo "mac needs macOS with Xcode; ./build.sh maccheck compiles the app for the Mac anywhere"; exit 1; }
		[ -f "$DEPS/sdl3-src/CMakeLists.txt" ] || { echo "SDL source missing: clone SDL_TAG (scripts/versions.env) into deps/sdl3-src"; exit 1; }
		[ -f "$DEPS/ufbx-src/ufbx.c" ] || { echo "ufbx source missing: clone UFBX_TAG (scripts/versions.env) into deps/ufbx-src"; exit 1; }
		command -v pkg-config > /dev/null || { echo "pkg-config missing: brew install pkgconf"; exit 1; }
		out="$ROOT/build/mac"
		app="$out/Sculpt.app"
		cc=(xcrun -sdk macosx clang -target "arm64-apple-macos$MAC_MIN")
		[ -f "$out/sdl/lib/libSDL3.a" ] || "$ROOT/scripts/sdl_mac.sh" "$MAC_MIN" "$DEPS/sdl3-src" "$out"
		metal_check macosx mac
		mac_object
		"${cc[@]}" -O2 -c "$DEPS/odin/vendor/stb/src/stb_truetype.c" -o "$out/stb_truetype.o"
		"${cc[@]}" -O2 -w -I"$DEPS/ufbx-src" -c "$ROOT/src/fbx/fbx_shim.c" -o "$out/ufbx.o"
		# Quad Remesh is offered on the Mac (src/quadmesh), so AutoRemesher's core links in too,
		# built for the same minimum macOS when it is missing.
		[ -f "$DEPS/autoremesher/libautoremesher.a" ] || MACOSX_DEPLOYMENT_TARGET="$MAC_MIN" python3 "$ROOT/scripts/build_autoremesher.py" || exit 1
		rm -rf "$app"
		mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
		libs=$(PKG_CONFIG_PATH="$out/sdl/lib/pkgconfig" pkg-config --static --libs sdl3)
		[ -n "$libs" ] || { echo "pkg-config gave no flags for SDL's static library"; exit 1; }
		read -r -a sdl_libs <<< "$libs"
		"${cc[@]}" "$out/sculpt.o" "$out/stb_truetype.o" "$out/ufbx.o" "$DEPS/autoremesher/libautoremesher.a" -lc++ "${sdl_libs[@]}" -o "$app/Contents/MacOS/Sculpt"
		plist="$app/Contents/Info.plist"
		cp "$ROOT/mac/Info.plist" "$plist"
		plutil -replace LSMinimumSystemVersion -string "$MAC_MIN" "$plist"
		plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-1}" "$plist"
		apple_plist_keys "$plist" macosx
		apple_icon macosx "$app/Contents/Resources" "$plist" --minimum-deployment-target "$MAC_MIN"
		plutil -lint "$plist"
		# The same privacy manifest as the iPad's: the same code calls the same APIs.
		cp "$ROOT/ios/PrivacyInfo.xcprivacy" "$app/Contents/Resources/PrivacyInfo.xcprivacy"
		if [ -n "${SCULPT_MAC_IDENTITY:-}" ]; then
			[ "${SCULPT_DIAGNOSTICS:-}" != 1 ] || { echo "a signed release cannot be a developer build: unset SCULPT_DIAGNOSTICS"; exit 1; }
			codesign --force --options runtime --timestamp --sign "$SCULPT_MAC_IDENTITY" "$app"
		else
			codesign --force --sign - "$app"
		fi
		codesign --verify --strict "$app"
		rm -f "$out/Sculpt-mac.zip"
		ditto -c -k --keepParent "$app" "$out/Sculpt-mac.zip"
		if [ -n "${SCULPT_MAC_IDENTITY:-}" ]; then
			echo "mac: build/mac/Sculpt-mac.zip (Developer ID; ./build.sh macnotarize next)"
		else
			echo "mac: build/mac/Sculpt-mac.zip (signed ad hoc: Control-click > Open on another Mac)"
		fi
		;;
	macnotarize)
		# Sends the Developer ID build to Apple's notary service with the App Store Connect API
		# key iosupload uses, waits for its verdict, staples the ticket to Sculpt.app and zips
		# it again: Gatekeeper then opens it on any Mac, offline too.
		[ "$(uname)" = Darwin ] || { echo "macnotarize needs macOS with Xcode"; exit 1; }
		[ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] || { echo "set ASC_KEY_ID and ASC_ISSUER_ID (App Store Connect > Users and Access > Integrations)"; exit 1; }
		key="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
		[ -f "$key" ] || { echo "the API key is not at $key"; exit 1; }
		out="$ROOT/build/mac"
		[ -f "$out/Sculpt-mac.zip" ] || { echo "no build/mac/Sculpt-mac.zip: run SCULPT_MAC_IDENTITY=... ./build.sh mac first"; exit 1; }
		xcrun notarytool submit "$out/Sculpt-mac.zip" --key "$key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
		xcrun stapler staple "$out/Sculpt.app"
		rm -f "$out/Sculpt-mac.zip"
		ditto -c -k --keepParent "$out/Sculpt.app" "$out/Sculpt-mac.zip"
		echo "macnotarize: build/mac/Sculpt-mac.zip is notarized and stapled"
		;;
	*) echo "unknown mode: $mode"; exit 1 ;;
esac
