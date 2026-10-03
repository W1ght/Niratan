// test-sources: Features/Video/Remote/RemoteVideoSource.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoRemoteIdentityTests {
    static func main() throws {
        let identity = VideoMediaIdentity.remote(
            providerID: "youtube",
            remoteID: "yrL6Qny0E5M"
        )
        expect(
            identity.persistenceKey,
            "remote://youtube/yrL6Qny0E5M",
            "remote identity should expose a stable persistence key"
        )
        expect(
            identity.localURL,
            nil,
            "remote identity must not expose a synthetic file URL"
        )

        let legacyJSON = #"{"providerID":"ytdlp","remoteID":"yrL6Qny0E5M","originalURL":"https:\/\/www.youtube.com\/watch?v=yrL6Qny0E5M","title":"Reference"}"#
        let migrated = try JSONDecoder().decode(
            RemoteVideoIdentity.self,
            from: Data(legacyJSON.utf8)
        )
        expect(
            migrated.providerID,
            "youtube",
            "legacy YouTube test entries should migrate away from yt-dlp"
        )
        expect(
            migrated.mediaIdentity,
            identity,
            "migrated identity should preserve the YouTube video ID"
        )

        let futureJSON = #"{"providerID":"future-provider","remoteID":"abc","originalURL":"https:\/\/example.com\/video","title":"Future"}"#
        let future = try JSONDecoder().decode(
            RemoteVideoIdentity.self,
            from: Data(futureJSON.utf8)
        )
        expect(
            future.providerID,
            "future-provider",
            "unknown provider identifiers should remain forward compatible"
        )

        let encoded = String(
            decoding: try JSONEncoder().encode(migrated),
            as: UTF8.self
        )
        expect(
            encoded.contains("googlevideo.com"),
            false,
            "durable identity must not persist signed media URLs"
        )
        expect(
            encoded.contains("httpHeaders"),
            false,
            "durable identity must not persist request headers"
        )

        print("Video remote identity tests passed")
    }
}
