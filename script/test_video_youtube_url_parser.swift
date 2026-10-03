// test-sources: Features/Video/Remote/YouTubeURLParser.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoYouTubeURLParserTests {
    static func main() {
        let valid: [(String, String)] = [
            ("https://www.youtube.com/watch?v=yrL6Qny0E5M", "yrL6Qny0E5M"),
            ("https://youtu.be/yrL6Qny0E5M?t=30", "yrL6Qny0E5M"),
            ("https://www.youtube.com/shorts/yrL6Qny0E5M", "yrL6Qny0E5M"),
            ("https://youtube.com/embed/yrL6Qny0E5M", "yrL6Qny0E5M"),
            ("https://www.youtube-nocookie.com/embed/yrL6Qny0E5M", "yrL6Qny0E5M"),
        ]
        for (rawURL, expectedID) in valid {
            let url = URL(string: rawURL)!
            expect(
                YouTubeURLParser.videoID(from: url),
                expectedID,
                "supported YouTube URL should expose its stable video ID"
            )
            expect(
                YouTubeURLParser.isYouTubeURL(url),
                true,
                "supported YouTube URL should be recognized"
            )
        }

        let invalid = [
            "https://example.com/watch?v=yrL6Qny0E5M",
            "https://youtube.com.evil.test/watch?v=yrL6Qny0E5M",
            "https://www.youtube.com/watch",
            "file:///tmp/yrL6Qny0E5M",
        ]
        for rawURL in invalid {
            let url = URL(string: rawURL)!
            expect(
                YouTubeURLParser.videoID(from: url),
                nil,
                "unsupported URL must not be accepted"
            )
        }

        print("Video YouTube URL parser tests passed")
    }
}
