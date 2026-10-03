// test-sources: Features/Video/Remote/YouTubeAndroidVRPlayerResponseParser.swift Features/Video/Remote/YouTubeInitialPlayerResponseParser.swift Features/Video/Remote/YouTubeMediaModels.swift Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoYouTubeCaptionParserTests {
    static func main() throws {
        let html = #"""
        <script>
        var ytInitialPlayerResponse = {
          "videoDetails": {"lengthSeconds": "1110"},
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=ref&lang=ja",
                  "name": {"simpleText": "日本語 {公式}"},
                  "vssId": ".ja",
                  "languageCode": "ja"
                },
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=ref&kind=asr&lang=ja",
                  "name": {"simpleText": "Japanese (auto-generated)"},
                  "vssId": "a.ja",
                  "languageCode": "ja",
                  "kind": "asr"
                },
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=ref&lang=en&fmt=srv3",
                  "name": {"simpleText": "English"},
                  "vssId": ".en",
                  "languageCode": "en"
                }
              ]
            }
          }
        };
        </script>
        """#

        let metadata = try YouTubeInitialPlayerResponseParser.parse(html: html)
        expect(metadata.duration, 1_110, "duration should decode from lengthSeconds")
        expect(
            metadata.subtitleOptions.map(\.language),
            ["ja", "ja", "en"],
            "publisher and automatic caption tracks should be retained in source order"
        )
        expect(
            metadata.subtitleOptions.contains(where: { $0.id == "a.ja" }),
            true,
            "ASR caption tracks should remain available when publisher captions are absent"
        )
        expect(
            metadata.subtitleOptions.allSatisfy { option in
                URLComponents(url: option.url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .contains(where: { $0.name == "fmt" && $0.value == "vtt" }) == true
            },
            true,
            "caption requests should explicitly ask for WebVTT"
        )
        expect(
            metadata.subtitleOptions.map(\.isAutomatic),
            [false, true, false],
            "caption tracks should preserve whether YouTube marked them automatic"
        )
        expect(
            metadata.subtitleOptions.allSatisfy { $0.format == .webVTT },
            true,
            "accepted YouTube tracks should be WebVTT options"
        )

        let androidVRResponse = Data(#"""
        {
          "videoDetails": {"lengthSeconds": "1111"},
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=ref&lang=ja&fmt=srv3",
                  "name": {"simpleText": "Japanese"},
                  "vssId": ".ja",
                  "languageCode": "ja"
                },
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=ref&kind=asr&lang=ja&fmt=srv3",
                  "name": {"simpleText": "Japanese (auto-generated)"},
                  "vssId": "a.ja",
                  "languageCode": "ja",
                  "kind": "asr"
                }
              ]
            }
          }
        }
        """#.utf8)
        let androidMetadata = try YouTubeAndroidVRPlayerResponseParser.parse(
            data: androidVRResponse
        )
        expect(androidMetadata.duration, 1_111, "Android VR duration should decode")
        expect(
            androidMetadata.subtitleOptions.map(\.id),
            [".ja", "a.ja"],
            "Android VR response should retain publisher and automatic captions"
        )
        expect(
            URLComponents(
                url: androidMetadata.subtitleOptions[0].url,
                resolvingAgainstBaseURL: false
            )?.queryItems?.filter { $0.name == "fmt" }.map(\.value),
            ["vtt"],
            "Android VR timedtext URLs should replace srv3 with WebVTT"
        )

        let embedded = #"<script>window.data={"ytInitialPlayerResponse":{"videoDetails":{"lengthSeconds":"9"}}};</script>"#
        let embeddedMetadata = try YouTubeInitialPlayerResponseParser.parse(html: embedded)
        expect(embeddedMetadata.duration, 9, "embedded marker shape should be supported")
        expect(embeddedMetadata.subtitleOptions.isEmpty, true, "missing captions should be empty")

        let missing = try YouTubeInitialPlayerResponseParser.parse(html: "<html></html>")
        expect(missing, .empty, "missing player response should be non-fatal")

        do {
            _ = try YouTubeInitialPlayerResponseParser.parse(
                html: #"var ytInitialPlayerResponse = {"videoDetails": }"#
            )
            fputs("FAIL: malformed player JSON should fail deterministically\n", stderr)
            exit(1)
        } catch YouTubeInitialPlayerResponseParserError.invalidJSON {
            // Expected.
        }

        print("Video YouTube caption parser tests passed")
    }
}
