// test-sources: Models/Book.swift Features/Reader/ReaderChapterIndex.swift Util/ReaderCharacterNormalizer.swift Features/Reader/Gallery/ReaderImageGalleryIndex.swift
import Foundation

@main
enum ReaderChapterIndexTests {
    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fail("\(message)\nExpected: \(expected)\nActual: \(actual)")
        }
    }

    static func main() throws {
        let legacyJSON = Data(#"""
        {
          "characterCount": 150,
          "chapterInfo": {
            "Text/a.xhtml": {
              "spineIndex": 0,
              "currentTotal": 0,
              "chapterCount": 100
            }
          }
        }
        """#.utf8)
        let legacyBookInfo = try JSONDecoder().decode(BookInfo.self, from: legacyJSON)
        expect(
            legacyBookInfo.chapterInfo["Text/a.xhtml"]?.fragmentOffsets == nil,
            "legacy bookinfo should decode without fragment offsets"
        )

        let markup = #"""
        <html>
          <head><meta id="head-target"/><title>HEAD123</title></head>
          <body>甲<!-- <i id="comment-target"></i> --><script><i id="script-target"></i></script><style>#style-target { color: red; }</style><section id='part-1'>乙<ruby>漢<rt>かん</rt></ruby>&quot;</section><h2 ID="part&amp;2">丙</h2><div xml:id='xml part'>&#x4E01;</div></body>
        </html>
        """#
        let offsets = ReaderChapterIndex.fragmentOffsets(
            in: markup,
            fragments: [
                "part-1",
                "part%262",
                "xml%20part",
                "comment-target",
                "script-target",
                "missing",
            ]
        )
        expectEqual(offsets["part-1"], 1, "single-quoted ids should resolve after the first readable character")
        expectEqual(offsets["part%262"], 3, "percent-encoded fragments and XML entities should match the DOM id")
        expectEqual(offsets["xml%20part"], 4, "xml:id and percent-encoded spaces should resolve")
        expectEqual(offsets["missing"], 0, "unresolved TOC fragments should retain the safe XHTML-start fallback")
        expect(
            offsets["head-target"] == nil,
            "fragment indexing should only inspect body elements"
        )
        expectEqual(offsets["comment-target"], 0, "fragment indexing should ignore tag-shaped text in comments")
        expectEqual(offsets["script-target"], 0, "fragment indexing should ignore tag-shaped text in scripts")
        expectEqual(
            ReaderCharacterNormalizer.filteredText(
                from: "<html><body>&quot;&apos;&amp;lt;甲</body></html>"
            ),
            "lt甲",
            "character references should decode once before readable-character filtering"
        )

        let indexedBookInfo = BookInfo(
            characterCount: 150,
            chapterInfo: [
                "Text/a.xhtml": .init(
                    spineIndex: 0,
                    currentTotal: 0,
                    chapterCount: 100,
                    fragmentOffsets: ["part": 40]
                ),
                "Text/b.xhtml": .init(
                    spineIndex: 1,
                    currentTotal: 100,
                    chapterCount: 50,
                    fragmentOffsets: [:]
                ),
            ],
            images: ["Images/cover.jpg"],
            imagePositions: ["Images/cover.jpg": 0]
        )
        let starts = ReaderChapterIndex.chapterStarts(
            tableOfContentsItems: [
                "./Text/a.xhtml",
                "Text/a.xhtml#part",
                "Text/b.xhtml",
            ],
            bookInfo: indexedBookInfo
        )
        expectEqual(starts, [0, 40, 100], "same-XHTML TOC fragments should create distinct chapter starts")

        let middleRange = ReaderChapterIndex.chapterRange(
            containing: 50,
            chapterStarts: starts,
            bookCharacterCount: indexedBookInfo.characterCount
        )
        expectEqual(middleRange, .init(start: 40, count: 60), "chapter bounds should end at the next TOC entry")
        expectEqual(middleRange.character(at: 50), 10, "chapter-local progress should subtract the fragment start")
        expectEqual(middleRange.remaining(at: 50), 50, "chapter remaining characters should use the true TOC range")

        let finalRange = ReaderChapterIndex.chapterRange(
            containing: 150,
            chapterStarts: starts,
            bookCharacterCount: indexedBookInfo.characterCount
        )
        expectEqual(finalRange, .init(start: 100, count: 50), "book-end progress should remain in the final chapter")
        expectEqual(finalRange.remaining(at: 150), 0, "the final chapter should have no characters remaining at book end")

        let mergedBookInfo = indexedBookInfo.mergingMissingFragmentOffsets([
            "Text/a.xhtml": ["part": 45, "later": 75],
        ])
        expectEqual(
            mergedBookInfo.chapterInfo["Text/a.xhtml"]?.fragmentOffsets,
            ["part": 40, "later": 75],
            "backfill should preserve existing offsets while adding missing fragments"
        )
        expectEqual(mergedBookInfo.images, indexedBookInfo.images, "fragment backfill should preserve gallery paths")
        expectEqual(
            mergedBookInfo.imagePositions,
            indexedBookInfo.imagePositions,
            "fragment backfill should preserve gallery positions"
        )

        let markedLegacyBookInfo = legacyBookInfo.mergingMissingFragmentOffsets([
            "Text/a.xhtml": [:],
        ])
        expectEqual(
            markedLegacyBookInfo.chapterInfo["Text/a.xhtml"]?.fragmentOffsets,
            [:],
            "an XHTML file without TOC fragments should be marked as indexed"
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-reader-chapter-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let chapterURL = temporaryDirectory.appendingPathComponent("chapter.xhtml")
        try Data(markup.utf8).write(to: chapterURL)

        let sourceResult = ReaderChapterIndex.fragmentOffsets(sources: [
            .init(
                chapterPath: "Text/a.xhtml",
                chapterURL: chapterURL,
                fragments: ["part-1"],
                expectedChapterStart: 0,
                expectedChapterCount: 100
            ),
            .init(
                chapterPath: "Text/b.xhtml",
                chapterURL: chapterURL,
                fragments: [],
                expectedChapterStart: 100,
                expectedChapterCount: 50
            ),
        ])
        expectEqual(sourceResult?["Text/a.xhtml"]?["part-1"], 1, "background sources should calculate requested offsets")
        expectEqual(sourceResult?["Text/b.xhtml"], [:], "background sources should mark empty fragment sets")

        var cancellationChecks = 0
        let cancelledResult = ReaderChapterIndex.fragmentOffsets(
            sources: [
                .init(
                    chapterPath: "Text/a.xhtml",
                    chapterURL: chapterURL,
                    fragments: ["part-1"],
                    expectedChapterStart: 0,
                    expectedChapterCount: 100
                ),
                .init(
                    chapterPath: "Text/b.xhtml",
                    chapterURL: chapterURL,
                    fragments: [],
                    expectedChapterStart: 100,
                    expectedChapterCount: 50
                ),
            ],
            shouldCancel: {
                cancellationChecks += 1
                return cancellationChecks > 2
            }
        )
        expect(cancelledResult == nil, "cancelled fragment backfills should discard partial results")

        print("Reader chapter index tests passed")
    }
}
