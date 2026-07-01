#!/usr/bin/env bash
# Build the Box3D static libs into lib/ and regenerate the Odin bindings from the
# pinned headers. Mirrors vendor/box2d/build_box2d.sh. Box3D has a single SIMD variant
# (no AVX2/SSE2 split), so one native lib per platform.
set -eu

VERSION="0.1.0"
RELEASE="https://github.com/erincatto/box3d/archive/refs/tags/v$VERSION.tar.gz"

cd "$(dirname "$0")"
HERE="$(pwd)"

curl -O -L "$RELEASE"
tar -xzf "v$VERSION.tar.gz"
SRC="box3d-$VERSION"

FLAGS="-DCMAKE_BUILD_TYPE=Release -DBOX3D_SAMPLES=OFF -DBOX3D_UNIT_TESTS=OFF -DBOX3D_BENCHMARKS=OFF -DBOX3D_VALIDATE=OFF"

build_static() { # <extra-cmake-flags> <out-name>
	rm -rf "$SRC/build"
	cmake $FLAGS "$1" -S "$SRC" -B "$SRC/build"
	cmake --build "$SRC/build" -j
	cp "$SRC/build/src/libbox3d.a" "lib/$2"
}

case "$(uname -s)" in
Darwin)
	export MACOSX_DEPLOYMENT_TARGET="11"
	case "$(uname -m)" in
	arm64) build_static "-DCMAKE_OSX_ARCHITECTURES=arm64"  "box3d_darwin_arm64.a" ;;
	*)     build_static "-DCMAKE_OSX_ARCHITECTURES=x86_64" "box3d_darwin_amd64.a" ;;
	esac
	;;
*)
	case "$(uname -m)" in
	x86_64|amd64) build_static "" "box3d_other_amd64.a" ;;
	*)            build_static "" "box3d_other.a" ;;
	esac
	;;
esac

# Shared build too — needed to hot-reload (`odin watch`) a project that links box3d,
# so host and reload DLL share one instance of box3d's global world state.
rm -rf "$SRC/build"
cmake $FLAGS -DBUILD_SHARED_LIBS=ON -S "$SRC" -B "$SRC/build"
cmake --build "$SRC/build" -j
cp -P "$SRC"/build/bin/libbox3d.so* lib/ 2>/dev/null || cp -P "$SRC"/build/src/libbox3d.so* lib/

# Regenerate the flat Odin bindings from the pinned headers, if the toolchain is present.
if command -v clang >/dev/null && python3 -c "import clang.cindex" 2>/dev/null; then
	python3 gen/generate.py "$SRC/include" "$HERE"
	echo "bindings regenerated from v$VERSION headers"
else
	echo "note: skipped binding regen (need clang + python libclang); libs still built"
fi

rm -rf "v$VERSION.tar.gz" "$SRC"
