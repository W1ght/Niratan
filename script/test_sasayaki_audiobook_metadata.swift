// test-sources: Features/Sasayaki/SasayakiAudiobookMetadata.swift Models/Sasayaki.swift
import Foundation

@main
enum SasayakiAudiobookMetadataTest {
    static func main() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("niratan-sasayaki-chapters-\(UUID().uuidString).m4b")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let movieHeader = box("mvhd", payload: movieHeaderPayload(timescale: 1_000, duration: 90_000))
        let chapterList = box(
            "chpl",
            payload: chapterListPayload([
                (title: "Opening", startUnits: 0),
                (title: "Chapter Two", startUnits: 300_000_000)
            ])
        )
        let artwork = Data([0x89, 0x50, 0x4E, 0x47])
        let itemList = box(
            "ilst",
            payload: metadataItem([0xA9, 0x6E, 0x61, 0x6D], value: Data("Fixture Audiobook".utf8))
                + metadataItem([0xA9, 0x41, 0x52, 0x54], value: Data("Fixture Artist".utf8))
                + metadataItem([0x63, 0x6F, 0x76, 0x72], value: artwork)
        )
        let metadata = box("meta", payload: Data(repeating: 0, count: 4) + itemList)
        let movie = box(
            "moov",
            payload: movieHeader + box("udta", payload: chapterList + metadata)
        )
        try (box("ftyp", payload: Data(repeating: 0, count: 8)) + movie).write(to: fixtureURL)

        let chapters = SasayakiMP4ChapterParser.parse(url: fixtureURL)
        require(chapters.count == 2, "chpl parser should return both embedded chapters")
        require(chapters[0].title == "Opening", "first chapter title should be decoded")
        require(chapters[0].startTime == 0, "first chapter should start at zero")
        require(chapters[0].endTime == 30, "first chapter should end at the next marker")
        require(chapters[1].title == "Chapter Two", "second chapter title should be decoded")
        require(chapters[1].startTime == 30, "100 ns chapter units should convert to seconds")
        require(chapters[1].endTime == 90, "last chapter should use the movie duration")

        let parsedMetadata = SasayakiMP4MetadataParser.parse(url: fixtureURL)
        require(parsedMetadata.title == "Fixture Audiobook", "iTunes title metadata should be decoded")
        require(parsedMetadata.artist == "Fixture Artist", "iTunes artist metadata should be decoded")
        require(parsedMetadata.artworkData == artwork, "embedded iTunes cover artwork should be decoded")

        print("Sasayaki audiobook metadata contract passed")
    }

    private static func movieHeaderPayload(timescale: UInt32, duration: UInt32) -> Data {
        var data = Data(repeating: 0, count: 12)
        data.append(bigEndian(timescale))
        data.append(bigEndian(duration))
        return data
    }

    private static func chapterListPayload(
        _ chapters: [(title: String, startUnits: UInt64)]
    ) -> Data {
        var data = Data(repeating: 0, count: 8)
        data.append(UInt8(chapters.count))
        for chapter in chapters {
            let title = Data(chapter.title.utf8)
            data.append(bigEndian(chapter.startUnits))
            data.append(UInt8(title.count))
            data.append(title)
        }
        return data
    }

    private static func box(_ type: String, payload: Data) -> Data {
        box(Array(type.utf8), payload: payload)
    }

    private static func metadataItem(_ type: [UInt8], value: Data) -> Data {
        box(type, payload: box("data", payload: Data(repeating: 0, count: 8) + value))
    }

    private static func box(_ type: [UInt8], payload: Data) -> Data {
        precondition(type.count == 4)
        var data = Data()
        data.append(bigEndian(UInt32(payload.count + 8)))
        data.append(contentsOf: type)
        data.append(payload)
        return data
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
