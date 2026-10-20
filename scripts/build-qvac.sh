#!/usr/bin/env bash
# Builds the QVAC TranscribePsy engine for macOS (Apple silicon) as one static
# library the app links. Output in Vendor/build-qvac/:
#   libparakeet_bundle.a   include/parakeet/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/qvac-transcribepsy"
OUT="$ROOT/Vendor/build-qvac"
# The engine is fetched at this exact commit so every build uses the same source.
QVAC_REPO="https://github.com/tether-ai-research/qvac-transcribepsy.git"
QVAC_COMMIT="364ec36130dc87d2cd46e596598268a6e3313751"

for tool in cmake git; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required (brew install $tool)" >&2; exit 1; }
done

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "Fetching QVAC TranscribePsy at ${QVAC_COMMIT}..."
  rm -rf "$SRC"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$QVAC_REPO"
  git -C "$SRC" fetch -q --depth 1 origin "$QVAC_COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

if [ -f "$OUT/libparakeet_bundle.a" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "QVAC already built ($OUT/libparakeet_bundle.a). FORCE=1 to rebuild."
  exit 0
fi

cmake -S "$SRC" -B "$OUT/cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=ON \
  -DGGML_BLAS=OFF \
  -DGGML_OPENMP=OFF \
  -DPARAKEET_OPENMP=OFF \
  -DPARAKEET_COREML=ON \
  -DPARAKEET_BUILD_EXECUTABLES=OFF \
  -DPARAKEET_BUILD_TESTS=OFF \
  -DPARAKEET_INSTALL=OFF
cmake --build "$OUT/cmake" -j "$(sysctl -n hw.ncpu)"

libs=()
while IFS= read -r a; do libs+=("$a"); done < <(find "$OUT/cmake" -name '*.a' | sort)
[ ${#libs[@]} -gt 0 ] || { echo "error: no static libraries were produced" >&2; exit 1; }
libtool -static -o "$OUT/libparakeet_bundle.a" "${libs[@]}" 2>/dev/null
mkdir -p "$OUT/include"
cp -R "$SRC/include/parakeet" "$OUT/include/"
echo "Built $OUT/libparakeet_bundle.a"
