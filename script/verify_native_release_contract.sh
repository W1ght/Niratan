#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Niratan.xcodeproj/project.pbxproj"
SCHEME_FILE="$ROOT_DIR/Niratan.xcodeproj/xcshareddata/xcschemes/Niratan.xcscheme"
BUILD_RUN_SCRIPT="$ROOT_DIR/script/build_and_run_native.sh"
CHANGELOG_FILE="$ROOT_DIR/docs/CHANGELOG.md"
INFO_PLIST_STRINGS="$ROOT_DIR/InfoPlist.xcstrings"
INFO_PLIST="$ROOT_DIR/HoshiReader-Info.plist"

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
    fail "$file still contains: $text"
  fi
}

assert_absent() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "legacy path still exists: $path"
}

# Native release validation inherits the full product topology, dependency,
# bundle-payload, entitlement, license, and transport boundary checks.
bash "$ROOT_DIR/script/verify_full_build_contract.sh" >/dev/null

assert_contains "$PROJECT_FILE" "PRODUCT_BUNDLE_IDENTIFIER = moe.shishamo.hoshi;"
assert_not_contains "$PROJECT_FILE" "de.manhhao.hoshi.native"
assert_not_contains "$PROJECT_FILE" "SUPPORTS_MACCATALYST"
assert_not_contains "$PROJECT_FILE" "ShareExtension"
assert_not_contains "$PROJECT_FILE" "Niratan Native"
assert_contains "$SCHEME_FILE" 'BuildableName = "Niratan.app"'
assert_contains "$SCHEME_FILE" 'BlueprintName = "Niratan"'

MARKETING_VERSIONS="$(
  awk '/MARKETING_VERSION = / { gsub(/[;[:space:]]/, "", $3); print $3 }' \
    "$PROJECT_FILE" \
    | sort -u
)"
[[ "$(printf '%s\n' "$MARKETING_VERSIONS" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "Debug and Release must use one MARKETING_VERSION"
CHANGELOG_VERSION="$(awk '/^## [0-9]/ { print $2; exit }' "$CHANGELOG_FILE")"
[[ "$CHANGELOG_VERSION" == "$MARKETING_VERSIONS" ]] \
  || fail "Top changelog version $CHANGELOG_VERSION does not match MARKETING_VERSION $MARKETING_VERSIONS"

assert_absent "$ROOT_DIR/App"
assert_absent "$ROOT_DIR/ShareExtension"
assert_absent "$ROOT_DIR/script/build_and_run_catalyst.sh"
assert_absent "$ROOT_DIR/Features/Reader/ReaderView/ReaderView.swift"
assert_absent "$ROOT_DIR/Features/Reader/ReaderView/ReaderViewModel.swift"
assert_absent "$ROOT_DIR/Features/Reader/ReaderView/FullscreenImageView.swift"
assert_absent "$ROOT_DIR/Features/Reader/ReaderWebView/ReaderWebView.swift"
assert_absent "$ROOT_DIR/Features/Reader/ScrollReaderWebView/ScrollReaderWebView.swift"

assert_not_contains "$ROOT_DIR/script/package_mac.sh" "Mac Catalyst"
assert_not_contains "$ROOT_DIR/script/package_mac.sh" "Release-maccatalyst"
assert_contains "$ROOT_DIR/script/package_mac.sh" 'SCHEME_NAME="Niratan"'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'EXPECTED_BUNDLE_ID="moe.shishamo.hoshi"'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'APP_VERSION="${VERSION%%-*}"'
assert_contains "$ROOT_DIR/script/package_mac.sh" '[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)beta[0-9]+$ ]]'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'APP_VERSION="${BASH_REMATCH[1]}"'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'expected $APP_VERSION, got $INFO_VERSION'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'SIGNING_IDENTITY="${HOSHI_RELEASE_SIGNING_IDENTITY:--}"'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$item"'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE"'
assert_contains "$ROOT_DIR/script/package_mac.sh" 'codesign --verify --deep --strict "$APP_BUNDLE"'
assert_not_contains "$ROOT_DIR/script/package_mac.sh" 'codesign --remove-signature'
assert_not_contains "$ROOT_DIR/.github/workflows/release-mac.yml" "notary"
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'HOSHI_RELEASE_SIGNING_IDENTITY: ${{ secrets.HOSHI_RELEASE_SIGNING_IDENTITY }}'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'HOSHI_RELEASE_CERTIFICATE_P12_BASE64: ${{ secrets.HOSHI_RELEASE_CERTIFICATE_P12_BASE64 }}'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'security import "$certificate_path"'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" "No release signing certificate secret configured; package_mac.sh will use ad-hoc signing."
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" "signed with the configured macOS release certificate"
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" "ad-hoc signed native macOS build"
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'prerelease="true"'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" '--prerelease="$prerelease"'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'release/Niratan-Mac-$version.dmg'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" "format('refs/tags/v{0}', inputs.version)"
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'bash script/test_cleanup_build_artifacts.sh'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'bash script/run_tests.sh'
# High-risk regressions run through script/run_tests.sh; they must stay runnable there.
for release_test in test_build_and_run_native_contract test_native_settings_navigation_contract test_manga_library_contract test_suwayomi_connector test_manga_page_processing test_reader_chapter_index test_reader_popup_sasayaki_regressions test_video_ajatt_contract test_video_ajatt_client test_video_remote_subtitle_loader test_video_playback_model test_video_window_open_request test_video_window_coordinator; do
  test_file="$ROOT_DIR/script/$release_test.swift"
  [[ -f "$test_file" ]] || fail "missing release regression test: $release_test"
  if grep -q "^// test-skip:" "$test_file"; then
    fail "release regression test must not be skipped: $release_test"
  fi
done
assert_contains "$ROOT_DIR/script/test_video_ajatt_client.swift" 'Features/Video/Remote/BoundedURLSessionData.swift'
assert_contains "$ROOT_DIR/script/test_video_ajatt_client.swift" 'Features/Video/Subtitles/AJATTSubtitleCatalogClient.swift'
assert_contains "$ROOT_DIR/script/test_video_remote_subtitle_loader.swift" 'Features/Video/Remote/RemoteSubtitleLoader.swift'
assert_contains "$ROOT_DIR/.github/workflows/release-mac.yml" 'swift test --package-path Libraries/AidokuRuntime'
assert_contains "$PROJECT_FILE" "InfoPlist.xcstrings"
assert_contains "$INFO_PLIST_STRINGS" '"NSLocalNetworkUsageDescription"'
assert_contains "$INFO_PLIST_STRINGS" '"zh-Hans"'
assert_contains "$INFO_PLIST_STRINGS" '"zh-Hant"'
LOCAL_NETWORK_DESCRIPTION='Allow Niratan to access AnkiConnect, Suwayomi Server, Jellyfin, Emby and Plex media servers, Fushi interconnect hosts, and user-installed Aidoku sources on your local network.'
assert_contains "$PROJECT_FILE" \
  "INFOPLIST_KEY_NSLocalNetworkUsageDescription = \"$LOCAL_NETWORK_DESCRIPTION\";"
assert_contains "$INFO_PLIST" "$LOCAL_NETWORK_DESCRIPTION"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$INFO_PLIST" 2>/dev/null || true)" == "true" ]] \
  || fail "$INFO_PLIST must allow explicitly confirmed HTTP Aidoku requests"
assert_not_contains "$ROOT_DIR/.github/workflows/release-mac.yml" "Hoshi-Reader-Mac"
assert_contains "$ROOT_DIR/script/release_mac.sh" 'APP_VERSION="${VERSION%%-*}"'
assert_contains "$ROOT_DIR/script/release_mac.sh" '[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)beta[0-9]+$ ]]'
assert_contains "$ROOT_DIR/script/release_mac.sh" 'APP_VERSION="${BASH_REMATCH[1]}"'
assert_not_contains "$ROOT_DIR/script/release_mac.sh" 'HOSHI_RELEASE_ARTIFACT_MODE'
assert_not_contains "$ROOT_DIR/script/release_mac.sh" 'Release-Artifact-Mode:'
assert_contains "$ROOT_DIR/script/release_mac.sh" 'if git diff --cached --quiet; then'
assert_contains "$ROOT_DIR/script/release_mac.sh" 'chore(release): bump version to $VERSION'
assert_contains "$BUILD_RUN_SCRIPT" '--open-url|open-url)'
assert_contains "$BUILD_RUN_SCRIPT" 'open_with_env -a "$APP_BUNDLE" "$url"'
assert_contains "$BUILD_RUN_SCRIPT" 'EXPECTED_BUNDLE_ID="moe.shishamo.hoshi"'
assert_contains "$BUILD_RUN_SCRIPT" 'Built app bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID, got $bundle_identifier.'
assert_contains "$BUILD_RUN_SCRIPT" 'LC_ALL=C pgrep -f -- "$APP_EXECUTABLE"'
assert_not_contains "$BUILD_RUN_SCRIPT" 'pgrep -x "$APP_NAME"'

echo "Native release contract checks passed"
