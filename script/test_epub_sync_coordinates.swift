// test-sources: Features/Sync/EPUBSyncCoordinates.swift Util/ReaderCharacterNormalizer.swift Models/Book.swift Models/Highlight.swift Models/Sync.swift Models/Statistics.swift
// test-modules: EPUBKit AEXML ZIPFoundation SwiftSoup
import EPUBKit
import Foundation
import ZIPFoundation

// Only the storage wrapper is replaced. The archive parser, both normalizers,
// BookInfo, Bookmark, Highlight, and wire model are production sources.
@MainActor
enum BookStorage {
    static func loadMetadata(root: URL) -> BookMetadata? { load(BookMetadata.self, root.appendingPathComponent("metadata.json")) }
    static func loadBookInfo(root: URL) -> BookInfo? { load(BookInfo.self, root.appendingPathComponent("bookinfo.json")) }
    private static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

@main
private enum EPUBSyncCoordinatesTests {
    @MainActor private static var checks = 0

    @MainActor
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("niratan-coordinate-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("Temp/active-reader.html")
        try fm.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("active reader".utf8).write(to: sentinel)
        let fixtures: [(String, String, Int, Int)] = [
            ("baseline", "ABCD", 4, 4),
            ("decimal-entity", "AB&#26085;CD", 5, 4),
            ("hex-entity", "AB&#x65E5;CD", 5, 4),
            ("numeric-ascii", "AB&#65;CD", 5, 4),
            ("ruby-parentheses", "<ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>後", 2, 2),
            ("ruby-countable-rp", "<ruby>漢<rp>注</rp><rt>かん</rt><rp>記</rp></ruby>後", 4, 2),
            ("hangul-syllables", "가나다", 0, 3),
            ("hangul-compatible-jamo", "ㄱㄴㄷ", 0, 3),
            ("named-quote", "AB&quot;CD", 4, 8),
            ("named-apostrophe", "AB&apos;CD", 4, 8),
            ("named-ampersand", "AB&amp;CD", 4, 4),
            ("nested-escaped-quote", "AB&amp;quot;CD", 8, 8),
            ("invalid-surrogate-entity", "AB&#xD800;CD", 4, 4)
        ]
        for (name, content, nativeCount, canonicalCount) in fixtures {
            let contents = [markup(content), markup("ABCD")]
            let epub = try archive(contents, root: root, name: name)
            let info = nativeInfo(contents)
            require(info.characterCount == nativeCount + 4, "\(name): production native normalization")
            let map = try unwrap(EPUBSyncCoordinates.load(epubURL: epub, nativeInfo: info,
                                                        generation: 4, epubReference: "published/\(name).epub"), name)
            require(map.canonicalTotal == canonicalCount + 4 && map.nativeTotal == nativeCount + 4,
                    "\(name): actual EPUB archive uses recorded counts")
            require(map.canonicalBookInfo.characterCount == map.canonicalTotal
                    && map.canonicalBookInfo.chapterInfo["one.xhtml"]?.chapterCount == canonicalCount
                    && map.canonicalBookInfo.chapterInfo["two.xhtml"]?.currentTotal == canonicalCount
                    && map.canonicalBookInfo.chapterInfo["two.xhtml"]?.spineIndex == 1,
                    "\(name): display-only canonical TOC counts retain spine paths")
            let start = try unwrap(map.nativeBookmark(forCanonical: canonicalCount, modified: 123), name)
            require(start.chapterIndex == 1 && start.progress == 0 && start.characterCount == nativeCount,
                    "\(name): next-chapter boundary remains next chapter")
            let half = try unwrap(map.nativeBookmark(forCanonical: canonicalCount + 2, modified: 456), name)
            require(half.chapterIndex == 1 && half.progress == 0.5 && half.characterCount == nativeCount + 2,
                    "\(name): imported half-chapter position")
            require(half.lastModified?.syncMilliseconds == 456, "\(name): modified preserved")
            require(map.canonicalCharacter(forNativeBookmark: half) == canonicalCount + 2,
                    "\(name): bookmark-aware export uses spine/progress")
            for raw in 0..<canonicalCount {
                let bookmark = try unwrap(map.nativeBookmark(forCanonical: raw, modified: 901), name)
                require(bookmark.chapterIndex == 0 && abs(bookmark.progress - Double(raw) / Double(canonicalCount)) < 1e-12,
                        "\(name): chapter-relative position including zero-native chapter")
                // The ledger retains original raw/time for this unchanged snapshot.
                // A reverse floor can differ by one because Double cannot exactly represent 1/3.
                let echoed = try unwrap(map.canonicalCharacter(forNativeBookmark: bookmark), name)
                require(abs(echoed - raw) <= 1, "\(name): bounded integer rounding, never a chapter jump")
            }
            let eof = try unwrap(map.nativeBookmark(forCanonical: map.canonicalTotal, modified: 987), name)
            require(eof.chapterIndex == 1 && eof.progress == 1 && eof.characterCount == map.nativeTotal,
                    "\(name): explicit EOF sentinel")
            require(map.canonicalCharacter(forNativeBookmark: eof) == map.canonicalTotal, "\(name): EOF export")
            require(map.nativeBookmark(forCanonical: -1, modified: 0) == nil && map.nativeBookmark(forCanonical: map.canonicalTotal + 1, modified: 0) == nil,
                    "\(name): invalid wire integers are deferred")
            let selected = Highlight(id: UUID(), character: nativeCount + 1, offset: 1, text: "B",
                                     color: .green, createdAt: Date(syncMilliseconds: 765))
            let wire = try unwrap(map.exportNativeHighlight(selected), name)
            require(wire.character == canonicalCount + 1 && wire.offset == 1 && wire.text == "B" && wire.createdAt == 765,
                    "\(name): highlight keeps raw DOM offset/text/date")
            require(map.projectCanonicalHighlight(wire)?.character == selected.character,
                    "\(name): verified DOM anchor projects to native")
            require(map.nativeHighlightSpineIndex(selected) == 1, "\(name): Reader highlight filtering uses verified chapter")
            let highlightBookmark = try unwrap(map.nativeHighlightBookmark(selected), name)
            require(highlightBookmark.chapterIndex == 1 && highlightBookmark.progress == 0.25,
                    "\(name): highlight navigation uses exact DOM fraction")
            var wrong = wire
            wrong.text = "not present"
            require(map.projectCanonicalHighlight(wrong) == nil, "\(name): missing text is retained canonical only")
            require(EPUBSyncCoordinates.cached(epubURL: epub)?.identity == map.identity, "\(name): Reader cache")
            let generation = try unwrap(EPUBSyncCoordinates.load(epubURL: epub, nativeInfo: info, generation: 5,
                                                                epubReference: "published/\(name).epub"), name)
            require(generation.identity != map.identity, "\(name): new generation invalidates receipt")
            let reference = try unwrap(EPUBSyncCoordinates.load(epubURL: epub, nativeInfo: info, generation: 5,
                                                               epubReference: "replacement.epub"), name)
            require(reference.identity != generation.identity, "\(name): published reference invalidates receipt")
        }

        // Same book total does not prove the raw coordinates share a basis.
        let collision = [markup("AB&#65;CD&#66;&#67;&#68;"), markup("AB&quot;CD")]
        let collisionURL = try archive(collision, root: root, name: "total-collision")
        let collisionMap = try unwrap(EPUBSyncCoordinates.load(epubURL: collisionURL, nativeInfo: nativeInfo(collision)), "collision")
        require(collisionMap.nativeTotal == 12 && collisionMap.canonicalTotal == 12, "collision: equal totals")
        let six = try unwrap(collisionMap.nativeBookmark(forCanonical: 6, modified: 22), "collision")
        require(six.chapterIndex == 1 && six.progress == 0.25 && six.characterCount == 9,
                "collision: wire raw6 maps native raw9 in correct chapter")

        let zero = [markup("가나다"), markup("ㄱㄴㄷ")]
        let zeroURL = try archive(zero, root: root, name: "all-native-zero")
        let zeroMap = try unwrap(EPUBSyncCoordinates.load(epubURL: zeroURL, nativeInfo: nativeInfo(zero)), "zero")
        let zeroBookmark = try unwrap(zeroMap.nativeBookmark(forCanonical: 4, modified: 31), "zero")
        require(zeroBookmark.chapterIndex == 1 && zeroBookmark.characterCount == 0 && abs(zeroBookmark.progress - 1.0/3) < 1e-12,
                "zero-native: exact chapter/progress survives")
        require(zeroMap.canonicalCharacter(forNativeBookmark: zeroBookmark) == 4, "zero-native: reverse uses chapter")
        let zeroHighlight = Highlight(id: UUID(), character: 0, offset: 1, text: "나", color: .green, createdAt: Date())
        require(zeroMap.nativeHighlightSpineIndex(zeroHighlight) == 0,
                "zero-native: unique raw DOM anchor identifies the empty native range")
        require(zeroMap.exportNativeHighlight(zeroHighlight)?.character == 1,
                "zero-native: unique local highlight exports its canonical DOM prefix")
        let zeroHighlightBookmark = try unwrap(zeroMap.nativeHighlightBookmark(zeroHighlight), "zero-highlight")
        require(zeroHighlightBookmark.chapterIndex == 0 && zeroHighlightBookmark.characterCount == 0
                && abs(zeroHighlightBookmark.progress - 1.0/3) < 1e-12,
                "zero-native: highlight navigation retains its actual chapter and DOM fraction")
        let secondZeroHighlight = Highlight(id: UUID(), character: 0, offset: 2, text: "ㄷ", color: .green, createdAt: Date())
        let secondZeroBookmark = try unwrap(zeroMap.nativeHighlightBookmark(secondZeroHighlight), "second-zero")
        require(secondZeroBookmark.chapterIndex == 1 && abs(secondZeroBookmark.progress - 2.0/3) < 1e-12,
                "zero-native: second all-Korean chapter is not confused with the first")

        let trailing = [markup("ABCD"), markup("&#65;")]
        let trailingURL = try archive(trailing, root: root, name: "trailing-canonical-zero")
        let trailingMap = try unwrap(EPUBSyncCoordinates.load(epubURL: trailingURL, nativeInfo: nativeInfo(trailing)), "trailing")
        let trailingEOF = try unwrap(trailingMap.nativeBookmark(forCanonical: trailingMap.canonicalTotal, modified: 32), "trailing")
        require(trailingEOF.chapterIndex == 1 && trailingEOF.progress == 1 && trailingEOF.characterCount == trailingMap.nativeTotal,
                "EOF includes a trailing numeric-only chapter omitted by the canonical normalizer")

        let ambiguous = [markup("가나다"), markup("가나다")]
        let ambiguousURL = try archive(ambiguous, root: root, name: "ambiguous-highlight")
        let ambiguousMap = try unwrap(EPUBSyncCoordinates.load(epubURL: ambiguousURL, nativeInfo: nativeInfo(ambiguous)), "ambiguous")
        let ambiguousHighlight = Highlight(id: UUID(), character: 0, offset: 0, text: "가", color: .blue, createdAt: Date())
        require(ambiguousMap.exportNativeHighlight(ambiguousHighlight) == nil,
                "ambiguous zero-native DOM anchor must not be assigned to a guessed chapter")
        require(ambiguousMap.nativeHighlightSpineIndex(ambiguousHighlight) == nil,
                "ambiguous highlight remains invisible rather than assigned to either chapter")
        require(ambiguousMap.nativeHighlightBookmark(ambiguousHighlight) == nil,
                "ambiguous DOM anchor cannot produce a navigation bookmark")

        let ruby = [markup("<ruby>漢<rp>注</rp><rt>かん</rt><rp>記</rp></ruby>後"), markup("ABCD")]
        let rubyURL = try archive(ruby, root: root, name: "ruby-highlight")
        let rubyMap = try unwrap(EPUBSyncCoordinates.load(epubURL: rubyURL, nativeInfo: nativeInfo(ruby)), "ruby")
        let rubyHighlight = Highlight(id: UUID(), character: 1, offset: 1, text: "後", color: .pink, createdAt: Date())
        let rubyWire = try unwrap(rubyMap.exportNativeHighlight(rubyHighlight), "ruby")
        require(rubyWire.character == 1 && rubyWire.offset == 1 && rubyMap.projectCanonicalHighlight(rubyWire)?.character == 1,
                "ruby DOM raw stream excludes rt/rp even when local BookInfo counts rp")
        require(rubyMap.nativeHighlightSpineIndex(rubyHighlight) == 0, "ruby anchor identifies its original spine")

        let astral = [markup("A😀日B"), markup("ABCD")]
        let astralURL = try archive(astral, root: root, name: "astral-highlight")
        let astralMap = try unwrap(EPUBSyncCoordinates.load(epubURL: astralURL, nativeInfo: nativeInfo(astral)), "astral")
        let astralHighlight = Highlight(id: UUID(), character: 1, offset: 2, text: "日", color: .yellow, createdAt: Date())
        require(astralMap.exportNativeHighlight(astralHighlight)?.offset == 2,
                "highlight offset counts Unicode code points rather than UTF16 units")

        let numericDOM = [markup("&#65;BCD&#69;"), markup("ABCD")]
        let numericDOMURL = try archive(numericDOM, root: root, name: "numeric-DOM-highlight")
        let numericDOMMap = try unwrap(EPUBSyncCoordinates.load(epubURL: numericDOMURL, nativeInfo: nativeInfo(numericDOM)), "numeric DOM")
        let numericDOMHighlight = Highlight(id: UUID(), character: 3, offset: 3, text: "D", color: .green, createdAt: Date())
        let numericDOMBookmark = try unwrap(numericDOMMap.nativeHighlightBookmark(numericDOMHighlight), "numeric DOM")
        require(numericDOMMap.canonicalChapterCount(spineIndex: 0) == 3 && numericDOMBookmark.chapterIndex == 0
                && numericDOMBookmark.progress == 0.6, "numeric entities: highlight uses DOM3/5 rather than Swift3/3 EOF")

        let quoteDOM = [markup("AB&quot;CD"), markup("ABCD")]
        let quoteDOMURL = try archive(quoteDOM, root: root, name: "quote-DOM-highlight")
        let quoteDOMMap = try unwrap(EPUBSyncCoordinates.load(epubURL: quoteDOMURL, nativeInfo: nativeInfo(quoteDOM)), "quote DOM")
        let quoteDOMHighlight = Highlight(id: UUID(), character: 2, offset: 3, text: "C", color: .green, createdAt: Date())
        require(quoteDOMMap.nativeHighlightBookmark(quoteDOMHighlight)?.progress == 0.5,
                "quote entity: highlight uses DOM2/4 rather than Swift2/8")

        let zeroCanonicalDOM = [markup("&#65;&#66;&#67;"), markup("ABCD")]
        let zeroCanonicalDOMURL = try archive(zeroCanonicalDOM, root: root, name: "zero-canonical-DOM-highlight")
        let zeroCanonicalDOMMap = try unwrap(EPUBSyncCoordinates.load(epubURL: zeroCanonicalDOMURL, nativeInfo: nativeInfo(zeroCanonicalDOM)), "zero canonical DOM")
        let zeroCanonicalDOMHighlight = Highlight(id: UUID(), character: 1, offset: 1, text: "B", color: .green, createdAt: Date())
        let zeroCanonicalDOMBookmark = try unwrap(zeroCanonicalDOMMap.nativeHighlightBookmark(zeroCanonicalDOMHighlight), "zero canonical DOM")
        require(zeroCanonicalDOMBookmark.chapterIndex == 0 && abs(zeroCanonicalDOMBookmark.progress - 1.0/3) < 1e-12,
                "zero canonical markup count: highlight restores the native DOM fraction")

        let identityContents = [markup("ABCD"), markup("EFGH")]
        let identityURL = try archive(identityContents, root: root, name: "source-identity")
        let identityInfo = nativeInfo(identityContents)
        let originalMap = try unwrap(EPUBSyncCoordinates.load(epubURL: identityURL, nativeInfo: identityInfo), "identity")
        let replacementContents = identityContents.map { $0.replacingOccurrences(of: "IgnoredTitle", with: "DifferentTitle") }
        let replacement = try archive(replacementContents, root: root, name: "source-replacement")
        try fm.removeItem(at: identityURL)
        try fm.copyItem(at: replacement, to: identityURL)
        require(EPUBSyncCoordinates.cached(epubURL: identityURL) == nil, "source replacement invalidates Reader cache")
        let changedMap = try unwrap(EPUBSyncCoordinates.load(epubURL: identityURL, nativeInfo: identityInfo), "identity")
        require(changedMap.nativeTotal == originalMap.nativeTotal && changedMap.canonicalTotal == originalMap.canonicalTotal
                && changedMap.identity != originalMap.identity, "streaming content SHA distinguishes same counts and same published name")

        let metadata = BookMetadata(title: "Fixture", epub: identityURL.lastPathComponent, cover: nil,
                                    folder: root.lastPathComponent, lastAccess: Date())
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent("metadata.json"))
        try JSONEncoder().encode(identityInfo).write(to: root.appendingPathComponent("bookinfo.json"))
        let wrapper = try unwrap(EPUBSyncCoordinates.map(root: root, generation: 8, epubReference: "published-reference.epub"), "wrapper")
        require(EPUBSyncCoordinates.cached(root: root)?.identity == wrapper.identity, "root lookup uses the exact validated EPUB")

        let invalidBookmark = Bookmark(chapterIndex: 99, progress: 0.5, characterCount: 0)
        require(wrapper.canonicalCharacter(forNativeBookmark: invalidBookmark) == nil,
                "missing spine cannot be reverse mapped")
        require(wrapper.canonicalCharacter(spineIndex: 0, progress: .nan) == nil
                && wrapper.canonicalCharacter(spineIndex: 0, progress: 1.01) == nil,
                "invalid chapter progress cannot be reverse mapped")

        let fortyNine = [markup(String(repeating: "A", count: 49)), markup("ABCD")]
        let fortyNineURL = try archive(fortyNine, root: root, name: "forty-nine-rounding")
        let fortyNineMap = try unwrap(EPUBSyncCoordinates.load(epubURL: fortyNineURL, nativeInfo: nativeInfo(fortyNine)), "forty-nine")
        let fortyNineBookmark = try unwrap(fortyNineMap.nativeBookmark(forCanonical: 1, modified: 101), "forty-nine")
        require(Int(fortyNineBookmark.progress * 49) == 0, "49-character fixture reproduces IEEE754 integer underflow")
        require(fortyNineBookmark.characterCount == 1
                && fortyNineMap.nativeCharacter(spineIndex: 0, progress: fortyNineBookmark.progress) == 1
                && fortyNineMap.canonicalCharacter(forNativeBookmark: fortyNineBookmark) == 1,
                "49-character exact ratio retains its imported integer in both spaces")

        let coarse = [markup("ABC" + String(repeating: "&#65;", count: 97)), markup("ABCD")]
        let coarseURL = try archive(coarse, root: root, name: "coarse-native-geometry")
        let coarseMap = try unwrap(EPUBSyncCoordinates.load(epubURL: coarseURL, nativeInfo: nativeInfo(coarse)), "coarse")
        require(coarseMap.nativeTotal == 104 && coarseMap.canonicalTotal == 7,
                "coarse geometry actual archive has Native100/Canonical3 in its first chapter")
        require(coarseMap.canonicalCharacter(spineIndex: 0, progress: 0.6) == 1
                && coarseMap.nativeCharacter(spineIndex: 0, progress: 0.6) == 60,
                "native geometry is not double-quantized through the coarse canonical integer")
        require(coarseMap.nativeCharacter(spineIndex: 1, progress: 0.5) == 102,
                "native geometry includes the exact native chapter start")

        let emptyCanonical = [markup("&#65;"), markup("&#66;")]
        let emptyURL = try archive(emptyCanonical, root: root, name: "canonical-empty")
        let emptyMap = try unwrap(EPUBSyncCoordinates.load(epubURL: emptyURL, nativeInfo: nativeInfo(emptyCanonical)), "empty")
        require(emptyMap.canonicalTotal == 0 && emptyMap.nativeBookmark(forCanonical: 0, modified: 1)?.chapterIndex == 0,
                "zero-canonical: only the initial sentinel can be inferred")

        var stale = nativeInfo(collision).chapterInfo
        stale["one.xhtml"] = .init(spineIndex: 0, currentTotal: 0, chapterCount: 7)
        try require(try EPUBSyncCoordinates.load(epubURL: collisionURL, nativeInfo: .init(characterCount: 12, chapterInfo: stale)) == nil,
                "stale BookInfo: do not migrate local coordinates")
        require(EPUBSyncCoordinates.cached(epubURL: collisionURL) == nil, "stale BookInfo: invalid cache removed")
        try require(try EPUBSyncCoordinates.load(epubURL: root.appendingPathComponent("missing.epub"), nativeInfo: nativeInfo(collision)) == nil,
                "placeholder: defer projection until actual EPUB exists")
        try require(try EPUBSyncCoordinates.map(root: root.appendingPathComponent("missing-book"), generation: 1, epubReference: nil) == nil,
                "placeholder: root wrapper has no guessed map")
        try require(try String(contentsOf: sentinel, encoding: .utf8) == "active reader", "global Reader Temp untouched")

        // Existing real archives exercise EPUBKit extraction beyond synthetic fixtures.
        for name in ["Alices_Adventures_in_Wonderland", "The_Metamorphosis"] {
            let fixture = URL(fileURLWithPath: "Libraries/EPUBKit/Tests/EPUBKitTests/Resources/\(name).epub")
            if fm.fileExists(atPath: fixture.path) {
                let unpacked = root.appendingPathComponent(name)
                try fm.unzipItem(at: fixture, to: unpacked)
                let document = try EPUBParser().parse(documentAt: unpacked)
                var totals = 0
                var chapters: [String: BookInfo.ChapterInfo] = [:]
                for (index, item) in document.spine.items.enumerated() {
                    guard let manifest = document.manifest.items[item.idref] else { continue }
                    let content = try String(contentsOf: document.contentDirectory.appendingPathComponent(manifest.path), encoding: .utf8)
                    let count = ReaderCharacterNormalizer.filteredText(from: content).count
                    chapters[manifest.path] = .init(spineIndex: index, currentTotal: totals, chapterCount: count)
                    totals += count
                }
                let map = try unwrap(EPUBSyncCoordinates.load(epubURL: fixture, nativeInfo: .init(characterCount: totals, chapterInfo: chapters)), name)
                require(map.nativeTotal == totals && map.canonicalTotal > 0, "\(name): real fixture parsed and verified")
                let eof = try unwrap(map.nativeBookmark(forCanonical: map.canonicalTotal, modified: 100), name)
                require(eof.progress == 1 && map.canonicalCharacter(forNativeBookmark: eof) == map.canonicalTotal, "\(name): real fixture EOF")
            } else { throw TestError.missingRealFixture(name) }
        }
        print("PASS EPUB sync coordinates: \(checks) checks, 13 synthetic archives + 2 real EPUB archives")
    }

    @MainActor private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    private enum TestError: Error { case missing(String), missingRealFixture(String) }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestError.missing(message) }
        return value
    }
    private static func markup(_ content: String) -> String {
        "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>IgnoredTitle</title></head><body><p>\(content)</p></body></html>"
    }
    @MainActor private static func nativeInfo(_ contents: [String]) -> BookInfo {
        var chapters: [String: BookInfo.ChapterInfo] = [:]
        var total = 0
        for (index, content) in contents.enumerated() {
            let count = ReaderCharacterNormalizer.filteredText(from: content).count
            chapters[index == 0 ? "one.xhtml" : "two.xhtml"] = .init(spineIndex: index, currentTotal: total, chapterCount: count)
            total += count
        }
        return BookInfo(characterCount: total, chapterInfo: chapters)
    }
    private static func archive(_ contents: [String], root: URL, name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: directory.appendingPathComponent("mimetype"))
        try Data("""
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8).write(to: directory.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <?xml version="1.0"?><package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">\(name)</dc:identifier><dc:title>\(name)</dc:title><dc:language>en</dc:language></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="one"/><itemref idref="two"/></spine></package>
        """.utf8).write(to: directory.appendingPathComponent("package.opf"))
        try Data("""
        <?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>Fixture</text></docTitle><navMap><navPoint id="one" playOrder="1"><navLabel><text>One</text></navLabel><content src="one.xhtml"/></navPoint><navPoint id="two" playOrder="2"><navLabel><text>Two</text></navLabel><content src="two.xhtml"/></navPoint></navMap></ncx>
        """.utf8).write(to: directory.appendingPathComponent("toc.ncx"))
        for (index, content) in contents.enumerated() {
            try Data(content.utf8).write(to: directory.appendingPathComponent(index == 0 ? "one.xhtml" : "two.xhtml"))
        }
        let archive = root.appendingPathComponent(name + ".epub")
        try FileManager.default.zipItem(at: directory, to: archive, shouldKeepParent: false)
        return archive
    }
}
