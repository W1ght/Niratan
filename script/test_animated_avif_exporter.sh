#!/usr/bin/env bash
set -euo pipefail
# test-requires-path: Vendor/libmpv/lib/libmpv.2.dylib

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/niratan-avif-exporter.XXXXXX")"
trap 'rm -rf "$OUTPUT_DIR"' EXIT

LIBRARY_DIR="$OUTPUT_DIR/Frameworks"
"$ROOT_DIR/script/embed_video_libraries.sh" "$LIBRARY_DIR"
for library in "$LIBRARY_DIR"/*.dylib; do
  codesign --force --sign - "$library" >/dev/null 2>&1
done
xcrun clang++ -std=c++17 -fobjc-arc \
  -I "$ROOT_DIR/Features/Video/Playback" \
  -I "$ROOT_DIR/Vendor/libmpv/include" \
  -I "$ROOT_DIR/Vendor/libmpv/include/mpv" \
  "$ROOT_DIR/script/test_animated_avif_exporter.mm" \
  "$ROOT_DIR/Features/Video/Playback/HSMpvAnimatedAVIFExporter.mm" \
  "$LIBRARY_DIR/libmpv.2.dylib" \
  "$LIBRARY_DIR/libavformat.61.dylib" \
  "$LIBRARY_DIR/libavcodec.61.dylib" \
  "$LIBRARY_DIR/libavutil.59.dylib" \
  -framework Foundation \
  -framework ImageIO \
  -Wl,-rpath,"$LIBRARY_DIR" \
  -o "$OUTPUT_DIR/test_animated_avif_exporter"

codesign --force --sign - "$OUTPUT_DIR/test_animated_avif_exporter" >/dev/null
"$OUTPUT_DIR/test_animated_avif_exporter" --self-test
