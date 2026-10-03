#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Niratan.xcodeproj/project.pbxproj"
SCHEME="$ROOT_DIR/Niratan.xcodeproj/xcshareddata/xcschemes/Niratan.xcscheme"
SCHEME_SEARCH_ROOT="$ROOT_DIR/Niratan.xcodeproj"
RETIRED_VIDEO_SCHEME="$ROOT_DIR/Niratan.xcodeproj/xcshareddata/xcschemes/Niratan Video.xcscheme"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run_native.sh"
PACKAGE_SCRIPT="$ROOT_DIR/script/package_mac.sh"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release-mac.yml"
BOOTSTRAP_SCRIPT="$ROOT_DIR/script/bootstrap_libmpv.sh"
VIDEO_BOOTSTRAP_SCRIPT="$ROOT_DIR/script/bootstrap_video_dependencies.sh"
SVT_BOOTSTRAP_SCRIPT="$ROOT_DIR/script/bootstrap_svt_av1.sh"
DEPENDENCY_MANIFEST="$ROOT_DIR/Vendor/libmpv/manifest.json"
DEPENDENCY_CHECKSUMS="$ROOT_DIR/script/libmpv-1.4.2.sha256"
MPV_CLIENT="$ROOT_DIR/Features/Video/Playback/HSMpvClient.mm"
AIDOKU_PACKAGE="$ROOT_DIR/Libraries/AidokuRuntime/Package.swift"
AIDOKU_WASM3="$ROOT_DIR/Libraries/AidokuRuntime/Sources/wasm3-c/m3_parse.c"
AIDOKU_VIEW="$ROOT_DIR/Features/Manga/AidokuSourceView.swift"
ABOUT_VIEW="$ROOT_DIR/Features/Settings/AboutView.swift"
INFO_PLIST="$ROOT_DIR/HoshiReader-Info.plist"
INFO_PLIST_STRINGS="$ROOT_DIR/InfoPlist.xcstrings"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -F -q -- "$text" "$file" || fail "$file is missing: $text"
}

assert_not_contains() {
  local file="$1"
  local text="$2"
  if grep -F -q -- "$text" "$file"; then
    fail "$file unexpectedly contains: $text"
  fi
}

assert_occurrences() {
  local file="$1"
  local text="$2"
  local expected="$3"
  local actual
  actual="$(grep -F -c -- "$text" "$file" || true)"
  [[ "$actual" == "$expected" ]] \
    || fail "$file must contain '$text' exactly $expected time(s), found $actual"
}

assert_section_occurrences() {
  local file="$1"
  local section="$2"
  local text="$3"
  local expected="$4"
  local actual
  actual="$(
    sed -n \
      "/\/\* Begin $section section \*\//,/\/\* End $section section \*\//p" \
      "$file" \
      | grep -F -c -- "$text" \
      || true
  )"
  [[ "$actual" == "$expected" ]] \
    || fail "$section must contain '$text' exactly $expected time(s), found $actual"
}

assert_plist_true() {
  local key_path="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key_path" "$INFO_PLIST" 2>/dev/null || true)"
  [[ "$value" == "true" ]] || fail "$INFO_PLIST must set $key_path to true"
}

assert_plist_absent() {
  local key_path="$1"
  if /usr/libexec/PlistBuddy -c "Print :$key_path" "$INFO_PLIST" >/dev/null 2>&1; then
    fail "$INFO_PLIST must not contain $key_path"
  fi
}

[[ ! -e "$RETIRED_VIDEO_SCHEME" ]] || fail "The retired Video scheme still exists"

NATIVE_TARGET_COUNT="$(
  awk '/isa = PBXNativeTarget;/ { count += 1 } END { print count + 0 }' "$PROJECT_FILE"
)"
[[ "$NATIVE_TARGET_COUNT" == "1" ]] \
  || fail "The project must contain exactly one PBXNativeTarget, found $NATIVE_TARGET_COUNT"
assert_occurrences "$PROJECT_FILE" 'isa = PBXAggregateTarget;' 0
assert_occurrences "$PROJECT_FILE" 'isa = PBXLegacyTarget;' 0

SHARED_SCHEME_COUNT="$(
  find "$SCHEME_SEARCH_ROOT" -type f \
    -path '*/xcshareddata/xcschemes/*.xcscheme' -print \
    | wc -l \
    | tr -d ' '
)"
[[ "$SHARED_SCHEME_COUNT" == "1" ]] \
  || fail "The project must contain exactly one shared scheme, found $SHARED_SCHEME_COUNT"
[[ -f "$SCHEME" ]] || fail "The sole shared scheme must be $SCHEME"
assert_occurrences "$SCHEME" '<BuildActionEntry' 1

assert_contains "$SCHEME" 'buildConfiguration = "Debug"'
assert_contains "$SCHEME" 'buildConfiguration = "Release"'
assert_not_contains "$PROJECT_FILE" "Debug-Video"
assert_not_contains "$PROJECT_FILE" "Release-Video"
assert_not_contains "$PROJECT_FILE" "HOSHI_VIDEO"
assert_contains "$PROJECT_FILE" "PRODUCT_BUNDLE_IDENTIFIER = moe.shishamo.hoshi;"
assert_contains "$PROJECT_FILE" "Manga/SuwayomiClient.swift"
assert_contains "$PROJECT_FILE" "Manga/SuwayomiSourceView.swift"
assert_contains "$PROJECT_FILE" "Manga/AidokuSourceView.swift"
assert_section_occurrences "$PROJECT_FILE" "XCLocalSwiftPackageReference" \
  'relativePath = Libraries/AidokuRuntime;' 1
assert_section_occurrences "$PROJECT_FILE" "XCSwiftPackageProductDependency" \
  'productName = AidokuRuntime;' 1
assert_section_occurrences "$PROJECT_FILE" "PBXBuildFile" \
  'AidokuRuntime in Frameworks' 1
assert_section_occurrences "$PROJECT_FILE" "PBXFrameworksBuildPhase" \
  'AidokuRuntime in Frameworks' 1
assert_section_occurrences "$PROJECT_FILE" "PBXNativeTarget" \
  '/* AidokuRuntime */,' 1

AIDOKU_PACKAGE_REFERENCE_ID="$(
  sed -n \
    '/\/\* Begin XCLocalSwiftPackageReference section \*\//,/\/\* End XCLocalSwiftPackageReference section \*\//p' \
    "$PROJECT_FILE" \
    | sed -n \
      's/^[[:space:]]*\([A-F0-9][A-F0-9]*\) \/\* XCLocalSwiftPackageReference "Libraries\/AidokuRuntime" \*\/ = {$/\1/p'
)"
[[ "$AIDOKU_PACKAGE_REFERENCE_ID" =~ ^[A-F0-9]{24}$ ]] \
  || fail "Unable to resolve the AidokuRuntime local package reference ID"
assert_section_occurrences "$PROJECT_FILE" "PBXProject" \
  "$AIDOKU_PACKAGE_REFERENCE_ID /* XCLocalSwiftPackageReference \"Libraries/AidokuRuntime\" */," 1

AIDOKU_PRODUCT_ID="$(
  sed -n \
    '/\/\* Begin XCSwiftPackageProductDependency section \*\//,/\/\* End XCSwiftPackageProductDependency section \*\//p' \
    "$PROJECT_FILE" \
    | sed -n \
      's/^[[:space:]]*\([A-F0-9][A-F0-9]*\) \/\* AidokuRuntime \*\/ = {$/\1/p'
)"
[[ "$AIDOKU_PRODUCT_ID" =~ ^[A-F0-9]{24}$ ]] \
  || fail "Unable to resolve the AidokuRuntime product dependency ID"

AIDOKU_BUILD_LINK="$(
  sed -n \
    '/\/\* Begin PBXBuildFile section \*\//,/\/\* End PBXBuildFile section \*\//p' \
    "$PROJECT_FILE" \
    | sed -n \
      's/^[[:space:]]*\([A-F0-9][A-F0-9]*\) \/\* AidokuRuntime in Frameworks \*\/ = {isa = PBXBuildFile; productRef = \([A-F0-9][A-F0-9]*\) \/\* AidokuRuntime \*\/; };$/\1 \2/p'
)"
read -r AIDOKU_BUILD_FILE_ID AIDOKU_LINKED_PRODUCT_ID <<< "$AIDOKU_BUILD_LINK"
[[ "$AIDOKU_BUILD_FILE_ID" =~ ^[A-F0-9]{24}$ ]] \
  || fail "Unable to resolve the AidokuRuntime Frameworks build-file ID"
[[ "$AIDOKU_LINKED_PRODUCT_ID" == "$AIDOKU_PRODUCT_ID" ]] \
  || fail "The AidokuRuntime Frameworks build file does not reference its package product"
assert_section_occurrences "$PROJECT_FILE" "PBXFrameworksBuildPhase" \
  "$AIDOKU_BUILD_FILE_ID /* AidokuRuntime in Frameworks */," 1
assert_section_occurrences "$PROJECT_FILE" "PBXNativeTarget" \
  "$AIDOKU_PRODUCT_ID /* AidokuRuntime */," 1
assert_not_contains "$PROJECT_FILE" "Manga Source Runtime.xpc"
assert_contains "$AIDOKU_PACKAGE" 'exact: "2.13.7"'
assert_contains "$AIDOKU_PACKAGE" '.library(name: "AidokuRuntime", targets: ["AidokuRuntime"])'
assert_contains "$AIDOKU_PACKAGE" 'name: "Wasm3"'
assert_contains "$AIDOKU_WASM3" 'd_m3MaxDuplicateFunctionImpl'
assert_contains "$AIDOKU_VIEW" 'Aidoku Source Lists'
assert_not_contains "$PROJECT_FILE" "AidokuRunner"
assert_not_contains "$PROJECT_FILE" "Shinsou"
assert_not_contains "$PROJECT_FILE" ".apk"
assert_contains "$PROJECT_FILE" '$(SRCROOT)/Vendor/libmpv/include/mpv'
assert_contains "$PROJECT_FILE" 'LIBRARY_SEARCH_PATHS = "$(SRCROOT)/Vendor/libmpv/lib";'
assert_contains "$PROJECT_FILE" 'OTHER_LDFLAGS = "-lmpv";'
assert_contains "$PROJECT_FILE" 'SWIFT_OBJC_BRIDGING_HEADER = "Features/Video/Playback/HoshiVideo-Bridging-Header.h";'
assert_contains "$MPV_CLIENT" 'moe.shishamo.hoshi.video.mpv'
assert_not_contains "$MPV_CLIENT" 'de.manhhao.hoshi.video.mpv'
assert_not_contains "$MPV_CLIENT" "HOSHI_VIDEO"
assert_not_contains "$PROJECT_FILE" 'Vendor/iina/deps/include'

assert_contains "$ABOUT_VIEW" 'name: "Wasm3 Swift Wrapper (AidokuRuntime)"'
assert_contains "$ABOUT_VIEW" 'Copyright (c) 2023-2025 Skittyblock'
assert_contains "$ABOUT_VIEW" 'name: "Wasm3 Core (AidokuRuntime)"'
assert_contains "$ABOUT_VIEW" 'Copyright (c) 2019 Steven Massey, Volodymyr Shymanskyy'
assert_contains "$ABOUT_VIEW" 'name: "SwiftSoup 2.13.7 (AidokuRuntime)"'
assert_contains "$ABOUT_VIEW" 'https://github.com/scinfu/SwiftSoup/tree/2.13.7'
assert_contains "$ABOUT_VIEW" 'Copyright (c) 2009-2025 Jonathan Hedley <https://jsoup.org/>'
assert_contains "$ABOUT_VIEW" 'Copyright (c) 2016-2025 Nabil Chatbi (Swift port)'
assert_occurrences "$ABOUT_VIEW" \
  'Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)' 2
assert_not_contains "$ABOUT_VIEW" 'Copyright (c) 2017-2026 Thomas Zoechling'
assert_not_contains "$ABOUT_VIEW" 'Copyright (c) 2016 Michael Rönnau'

LOCAL_NETWORK_DESCRIPTION='Allow Niratan to access AnkiConnect, Suwayomi Server, Jellyfin, Emby and Plex media servers, Fushi interconnect hosts, and user-installed Aidoku sources on your local network.'
assert_occurrences "$PROJECT_FILE" \
  "INFOPLIST_KEY_NSLocalNetworkUsageDescription = \"$LOCAL_NETWORK_DESCRIPTION\";" 2
assert_contains "$INFO_PLIST" "$LOCAL_NETWORK_DESCRIPTION"
assert_contains "$INFO_PLIST_STRINGS" "$LOCAL_NETWORK_DESCRIPTION"
assert_plist_true 'NSAppTransportSecurity:NSAllowsArbitraryLoads'
# On current macOS, the presence of NSAllowsLocalNetworking makes the system
# ignore NSAllowsArbitraryLoads. The global key is required because confirmed
# Aidoku sources can name arbitrary remote HTTP hosts as well as local hosts.
assert_plist_absent 'NSAppTransportSecurity:NSAllowsLocalNetworking'
assert_plist_absent 'NSAppTransportSecurity:NSAllowsArbitraryLoadsForMedia'
assert_plist_absent 'NSAppTransportSecurity:NSAllowsArbitraryLoadsInWebContent'

assert_contains "$BOOTSTRAP_SCRIPT" 'IINA_ARTIFACT_VERSION="1.4.2"'
assert_contains "$BOOTSTRAP_SCRIPT" 'IINA_SOURCE_REVISION="f6755d24ae461ce27c08814b9babe566ab43c80a"'
assert_contains "$BOOTSTRAP_SCRIPT" 'EXPECTED_FILE_LIST_SHA256="665da1e0506eeb952c0870153265df23602a9ef35e45290c8218dccc50a6da96"'
assert_contains "$VIDEO_BOOTSTRAP_SCRIPT" 'bootstrap_libmpv.sh'
assert_contains "$VIDEO_BOOTSTRAP_SCRIPT" 'bootstrap_svt_av1.sh'
assert_contains "$SVT_BOOTSTRAP_SCRIPT" 'SVT_AV1_VERSION="4.0.1"'
assert_contains "$SVT_BOOTSTRAP_SCRIPT" 'SVT_AV1_SOURCE_REVISION="4ae9272b588a05ee6e77a43e8dfdac05f54c4ff0"'
assert_contains "$SVT_BOOTSTRAP_SCRIPT" 'CMAKE_OSX_ARCHITECTURES'
assert_contains "$SVT_BOOTSTRAP_SCRIPT" 'lipo -create'
assert_contains "$DEPENDENCY_MANIFEST" '"provider": "SVT-AV1"'
assert_contains "$DEPENDENCY_MANIFEST" '"version": "4.0.1"'
assert_contains "$DEPENDENCY_MANIFEST" '"artifactVersion": "1.4.2"'
[[ "$(wc -l < "$DEPENDENCY_CHECKSUMS" | tr -d ' ')" == "71" ]] \
  || fail "$DEPENDENCY_CHECKSUMS must lock all 71 IINA 1.4.2 dylibs"

assert_contains "$BUILD_SCRIPT" 'SCHEME_NAME="Niratan"'
assert_contains "$BUILD_SCRIPT" 'CONFIGURATION="Debug"'
assert_contains "$BUILD_SCRIPT" 'bash "$ROOT_DIR/script/bootstrap_video_dependencies.sh"'
assert_not_contains "$BUILD_SCRIPT" 'VARIANT='
assert_not_contains "$BUILD_SCRIPT" 'Debug-Video'

assert_contains "$PACKAGE_SCRIPT" 'SCHEME_NAME="Niratan"'
assert_contains "$PACKAGE_SCRIPT" 'CONFIGURATION="Release"'
assert_contains "$PACKAGE_SCRIPT" 'ARTIFACT_NAME="Niratan-Mac-$VERSION"'
assert_contains "$PACKAGE_SCRIPT" 'verify_full_bundle'
assert_occurrences "$PACKAGE_SCRIPT" 'verify_full_bundle' 3
assert_contains "$PACKAGE_SCRIPT" 'libSvtAv1Enc.4.dylib'
assert_contains "$PACKAGE_SCRIPT" 'YouTubeKit_YouTubeKit.bundle'
assert_contains "$PACKAGE_SCRIPT" 'unexpected Mach-O helper executable'
assert_contains "$PACKAGE_SCRIPT" 'unexpected executable helper payload'
assert_contains "$PACKAGE_SCRIPT" "-iname '*.app'"
assert_contains "$PACKAGE_SCRIPT" "-iname '*.xpc'"
assert_contains "$PACKAGE_SCRIPT" "-iname '*.appex'"
assert_contains "$PACKAGE_SCRIPT" '*AidokuRunner*'
assert_contains "$PACKAGE_SCRIPT" '*Shinsou*'
assert_contains "$PACKAGE_SCRIPT" "'*.apk'"
assert_contains "$PACKAGE_SCRIPT" "'*.jar'"
assert_contains "$PACKAGE_SCRIPT" "'*.class'"
assert_contains "$PACKAGE_SCRIPT" "'*.dex'"
assert_contains "$PACKAGE_SCRIPT" "'*jre*'"
assert_contains "$PACKAGE_SCRIPT" "'*jvm*'"
assert_contains "$PACKAGE_SCRIPT" 'otool -hv "$candidate"'
assert_contains "$PACKAGE_SCRIPT" 'file -Lb "$candidate"'
assert_contains "$PACKAGE_SCRIPT" "'(^|[[:space:]])EXECUTE([[:space:]]|$)'"
assert_contains "$PACKAGE_SCRIPT" 'verify_no_jit_entitlements'
assert_contains "$PACKAGE_SCRIPT" 'com\.apple\.security\.cs\.(allow-jit|allow-unsigned-executable-memory)'
assert_occurrences "$PACKAGE_SCRIPT" 'verify_no_jit_entitlements' 2
assert_not_contains "$PACKAGE_SCRIPT" 'VARIANT='
assert_not_contains "$PACKAGE_SCRIPT" 'Niratan-Mac-Video-'
assert_contains "$PACKAGE_SCRIPT" "grep -E -q '/opt/homebrew|/usr/local'"
assert_contains "$PACKAGE_SCRIPT" 'codesign --verify --deep --strict "$APP_BUNDLE"'
assert_not_contains "$PACKAGE_SCRIPT" 'codesign --remove-signature'

assert_not_contains "$RELEASE_WORKFLOW" 'variant: light'
assert_not_contains "$RELEASE_WORKFLOW" 'variant: video'
assert_not_contains "$RELEASE_WORKFLOW" 'Niratan-Mac-Video-'
assert_contains "$RELEASE_WORKFLOW" 'script/package_mac.sh "${{ steps.version.outputs.version }}"'
assert_contains "$RELEASE_WORKFLOW" 'actions/upload-artifact@v4'
assert_contains "$RELEASE_WORKFLOW" 'actions/download-artifact@v4'
assert_contains "$RELEASE_WORKFLOW" '--prerelease="$prerelease"'

if rg -q '#if[[:space:]]+HOSHI_VIDEO|#elseif[[:space:]]+HOSHI_VIDEO' \
  "$ROOT_DIR/Core" "$ROOT_DIR/Features" "$ROOT_DIR/Models" "$ROOT_DIR/NativeMac" "$ROOT_DIR/Util"; then
  fail "Source code still contains HOSHI_VIDEO conditional compilation"
fi

echo "Full-build contract checks passed"
