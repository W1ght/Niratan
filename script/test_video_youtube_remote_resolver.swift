// test-sources: Features/Video/Remote/RemoteVideoResolver.swift Features/Video/Remote/RemoteVideoSource.swift Features/Video/Remote/YouTubeKitRemoteVideoResolver.swift Features/Video/Remote/YouTubeMediaModels.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift Features/Video/Remote/YouTubeStreamSelector.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func stream(
    id: String,
    height: Int? = nil,
    video: Bool,
    audio: Bool,
    bitrate: Int,
    ext: String
) -> YouTubeMediaStreamDescriptor {
    YouTubeMediaStreamDescriptor(
        url: URL(string: "https://example.com/\(id)")!,
        formatID: id,
        height: height,
        hasVideo: video,
        hasAudio: audio,
        bitrate: bitrate,
        fileExtension: ext,
        prefersNativeCodec: true
    )
}

@main
private enum VideoYouTubeRemoteResolverTests {
    static func main() async throws {
        let originalURL = URL(
            string: "https://www.youtube.com/watch?v=yrL6Qny0E5M"
        )!
        let subtitle = RemoteVideoSubtitleOption(
            id: ".ja",
            language: "ja",
            name: "Japanese",
            url: URL(string: "https://example.com/ja.vtt")!,
            format: .webVTT,
            isAutomatic: false,
            httpHeaders: [:]
        )
        let automaticSubtitle = RemoteVideoSubtitleOption(
            id: "a.ja",
            language: "ja",
            name: "Japanese (auto-generated)",
            url: URL(string: "https://example.com/ja-auto.vtt")!,
            format: .webVTT,
            isAutomatic: true,
            httpHeaders: [:]
        )
        let resolvedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resolver = YouTubeKitRemoteVideoResolver(
            mediaLoader: { url in
                expect(url, originalURL, "resolver should pass through the original URL")
                return YouTubeLoadedMedia(
                    title: "Reference",
                    thumbnailURL: URL(string: "https://example.com/thumb.jpg"),
                    streams: [
                        stream(id: "18", height: 360, video: true, audio: true, bitrate: 700_000, ext: "mp4"),
                        stream(id: "137", height: 1080, video: true, audio: false, bitrate: 3_000_000, ext: "mp4"),
                        stream(id: "140", video: false, audio: true, bitrate: 128_000, ext: "m4a"),
                    ]
                )
            },
            pageMetadataLoader: { videoID in
                expect(videoID, "yrL6Qny0E5M", "page loader should receive the parsed ID")
                return YouTubeResolvedPageMetadata(
                    duration: 1_110,
                    subtitleOptions: [automaticSubtitle, subtitle]
                )
            },
            now: { resolvedAt }
        )

        expect(resolver.canResolve(url: originalURL), true, "YouTube URL should resolve")
        expect(
            resolver.canResolve(url: URL(string: "https://example.com/video")!),
            false,
            "generic video URL should not resolve"
        )

        let source = try await resolver.resolve(
            url: originalURL,
            preferredSubtitleLanguages: ["ja"]
        )
        expect(source.identity.providerID, "youtube", "durable provider ID")
        expect(source.identity.remoteID, "yrL6Qny0E5M", "durable video ID")
        expect(source.identity.title, "Reference", "metadata title")
        expect(source.identity.duration, 1_110, "page duration")
        expect(source.playbackStream.height, 1080, "highest capped quality")
        expect(source.audioStream?.formatID, "140", "external audio selection")
        expect(source.muxedFallbackStream?.formatID, "18", "progressive fallback")
        expect(source.selectedSubtitleLanguage, "ja", "preferred manual caption")
        expect(
            source.preferredSubtitle(preferredLanguages: ["ja"])?.id,
            subtitle.id,
            "publisher captions should win over same-language automatic captions"
        )
        expect(
            source.subtitleOptions.map(\.id),
            [automaticSubtitle.id, subtitle.id],
            "automatic captions remain selectable even when a publisher track shares the language"
        )
        expect(source.resolvedAt, resolvedAt, "resolution timestamp")
        expect(
            source.expiresAt,
            resolvedAt.addingTimeInterval(5 * 60 * 60),
            "signed streams should expire in memory"
        )

        let captionsFail = YouTubeKitRemoteVideoResolver(
            mediaLoader: { _ in
                YouTubeLoadedMedia(
                    title: "Playable",
                    thumbnailURL: nil,
                    streams: [
                        stream(id: "18", height: 360, video: true, audio: true, bitrate: 1, ext: "mp4"),
                    ]
                )
            },
            pageMetadataLoader: { _ in throw URLError(.cannotParseResponse) },
            now: { resolvedAt }
        )
        let playable = try await captionsFail.resolve(
            url: originalURL,
            preferredSubtitleLanguages: []
        )
        expect(playable.subtitleOptions.isEmpty, true, "caption failure should not stop playback")
        expect(
            playable.expiresAt,
            resolvedAt.addingTimeInterval(60),
            "caption metadata failures should expire quickly instead of caching missing subtitles for hours"
        )

        let emptyMetadata = YouTubeKitRemoteVideoResolver(
            mediaLoader: { _ in
                YouTubeLoadedMedia(
                    title: "Playable",
                    thumbnailURL: nil,
                    streams: [
                        stream(id: "18", height: 360, video: true, audio: true, bitrate: 1, ext: "mp4"),
                    ]
                )
            },
            pageMetadataLoader: { _ in .empty },
            now: { resolvedAt }
        )
        let playableWithEmptyMetadata = try await emptyMetadata.resolve(
            url: originalURL,
            preferredSubtitleLanguages: []
        )
        expect(
            playableWithEmptyMetadata.expiresAt,
            resolvedAt.addingTimeInterval(60),
            "successful but empty page metadata should expire quickly instead of caching a degraded response"
        )

        for (failure, expected) in [
            (YouTubeMediaLoaderError.contentUnavailable, RemoteVideoResolverError.contentUnavailable),
            (.signInRequired, .signInRequired),
            (.regionRestricted, .regionRestricted),
            (.cancelled, .cancelled),
            (.timedOut, .timedOut),
            (.resolutionFailed, .resolutionFailed),
        ] {
            let failing = YouTubeKitRemoteVideoResolver(
                mediaLoader: { _ in throw failure },
                pageMetadataLoader: { _ in .empty },
                now: { resolvedAt }
            )
            do {
                _ = try await failing.resolve(
                    url: originalURL,
                    preferredSubtitleLanguages: []
                )
                fputs("FAIL: media failure should be mapped\n", stderr)
                exit(1)
            } catch let error as RemoteVideoResolverError {
                expect(error, expected, "typed media failure mapping")
            }
        }

        print("Video YouTube remote resolver tests passed")
    }
}
