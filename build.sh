#!/usr/bin/env bash
# Usage: ./build.sh [debug|release|test|run|smoke|bench] [-- app args]
#   debug   (default) debug build with allocation tracking -> build/sculpt
#   release optimized build without bounds checks -> build/sculpt
#   test    run all package tests
#   run     debug build, then run it with the remaining args
#   bench   headless sculpt benchmark at 500k, 1M, 5M, 7M and 10M vertices (no display
#           needed); extra args go to build/bench, e.g. 2000000 --threads=1
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
		"$ODIN" build "$ROOT/src/app" -out:"$ROOT/build/sculpt" -o:speed -no-bounds-check "${common[@]}"
		;;
	bench)
		"$ODIN" build "$ROOT/src/bench" -out:"$ROOT/build/bench" -o:speed -no-bounds-check "${common[@]}"
		"$ROOT/build/bench" "$@"
		;;
	test)
		compile_shaders
		for pkg in geom camera sculpt jobs; do
			"$ODIN" test "$ROOT/src/$pkg" -out:"$ROOT/build/test_$pkg" "${common[@]}"
		done
		;;
	*) echo "unknown mode: $mode"; exit 1 ;;
esac
