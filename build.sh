#!/usr/bin/env bash
# Usage: ./build.sh [debug|release|test|run|smoke] [-- app args]
#   debug   (default) debug build with allocation tracking -> build/sculpt
#   release optimized build -> build/sculpt
#   test    run all package tests
#   run     debug build, then run it with the remaining args
#   smoke   debug build, then run 300 frames with GPU debug mode; fails on any
#           SDL assert, GPU error or leaked allocation (needs a display, e.g. Xvfb)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPS="$ROOT/deps"
ODIN="$DEPS/odin/odin"
[ -x "$ODIN" ] || { echo "deps missing: run scripts/setup_deps.sh first"; exit 1; }

mode="${1:-debug}"; shift || true
[ "${1:-}" = "--" ] && shift

compile_shaders() {
	for src in "$ROOT"/src/render/shaders/*.{vert,frag}; do
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
	release)
		compile_shaders
		"$ODIN" build "$ROOT/src/app" -out:"$ROOT/build/sculpt" -o:speed "${common[@]}"
		;;
	test)
		compile_shaders
		for pkg in geom camera; do
			"$ODIN" test "$ROOT/src/$pkg" -out:"$ROOT/build/test_$pkg" "${common[@]}"
		done
		;;
	*) echo "unknown mode: $mode"; exit 1 ;;
esac
