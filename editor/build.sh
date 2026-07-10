#!/usr/bin/env sh
# Build medit with the Methodin compiler at the repo root.
set -eu
cd "$(dirname "$0")/.."

if [ ! -x ./odin ]; then
	echo "error: build the Methodin compiler first: ./build_odin.sh release" >&2
	exit 1
fi

# stb static libs are not shipped for unix; build them once.
if [ ! -f vendor/stb/lib/stb_truetype.a ]; then
	make -C vendor/stb/src
fi

./odin build editor -out:editor/medit -o:speed
echo "built editor/medit"
