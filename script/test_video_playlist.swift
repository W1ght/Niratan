// test-sources: Features/Video/VideoPlaylist.swift
import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoPlaylistTests {
    static func main() {
        let urls = [
            URL(fileURLWithPath: "/tmp/Show 10.mkv"),
            URL(fileURLWithPath: "/tmp/Show 2.mkv"),
            URL(fileURLWithPath: "/tmp/Show 1.mkv"),
            URL(fileURLWithPath: "/tmp/notes.txt")
        ]
        let playlist = VideoPlaylist(urls: urls, currentURL: urls[1])

        expect(
            playlist.items.map(\.lastPathComponent),
            ["Show 1.mkv", "Show 2.mkv", "Show 10.mkv"],
            "playlist should naturally sort supported videos"
        )
        expect(playlist.currentIndex, 1, "playlist should select the current file")
        expect(playlist.previousURL?.lastPathComponent, "Show 1.mkv", "previous episode")
        expect(playlist.nextURL?.lastPathComponent, "Show 10.mkv", "next episode")

        var changed = playlist
        changed.select(urls[0])
        expect(changed.currentIndex, 2, "select should update current index")
        expect(changed.nextURL, nil, "last episode should not have a next item")

        print("Video playlist tests passed")
    }
}
