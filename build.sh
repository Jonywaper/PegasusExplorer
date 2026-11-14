#!/bin/bash
# Compila PegasusExplorer usando solo las Command Line Tools de Apple.
#   ./build.sh              -> app para la arquitectura de esta Mac
#   ./build.sh --universal  -> app para Intel y Apple silicon
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PegasusExplorer"
MIN_MACOS="13.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

ARCHS=("$(uname -m)")
if [[ "${1:-}" == "--universal" ]]; then
  ARCHS=(x86_64 arm64)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINS=()
for arch in "${ARCHS[@]}"; do
  out="$BUILD_DIR/$APP_NAME-$arch"
  echo "Compilando para $arch..."
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" \
    -framework NetFS \
    -o "$out" Sources/*.swift
  BINS+=("$out")
done

lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Listo: $APP"
