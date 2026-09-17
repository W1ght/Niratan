#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BINARY="$(mktemp -t niratan-online-subtitles)"
trap 'rm -f "$TEST_BINARY"' EXIT
xcrun swiftc -parse-as-library \
  Models/Subtitle.swift \
  Features/Video/Remote/YouTubeURLParser.swift \
  Features/Video/Remote/RemoteVideoSource.swift \
  Features/Video/Remote/BoundedURLSessionData.swift \
  Features/Video/Subtitles/JimakuAPIClient.swift \
  Features/Video/Subtitles/AJATTSubtitleCatalogClient.swift \
  Features/Video/Subtitles/JimakuCredentialStore.swift \
  Features/Video/Subtitles/OnlineSubtitleClients.swift \
  Features/Video/Subtitles/OnlineSubtitleGrouping.swift \
  Features/Video/Subtitles/OnlineSubtitleBrowserModel.swift \
  script/test_video_online_subtitles.swift -o "$TEST_BINARY"
"$TEST_BINARY"
