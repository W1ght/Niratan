// test-sources: Features/Sync/Fushi/FushiProgressSync.swift Features/Sync/Fushi/FushiEPUBSpineReader.swift Features/Sync/Fushi/FushiInterconnectClient.swift Features/Sync/TtuSyncNaming.swift Models/Book.swift Models/Statistics.swift
// test-modules: ZIPFoundation
import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        failures += 1
    }
}

private func chapter(_ spine: Int, _ start: Int, _ count: Int) -> BookInfo.ChapterInfo {
    BookInfo.ChapterInfo(spineIndex: spine, currentTotal: start, chapterCount: count)
}

private func bookmark(_ chapter: Int, _ characters: Int, progress: Double = 0, ms: Int? = nil) -> Bookmark {
    Bookmark(
        chapterIndex: chapter,
        progress: progress,
        characterCount: characters,
        lastModified: ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    )
}

private func remote(_ section: Int, _ norm: Int, _ ms: Int) -> FushiRemoteProgress {
    FushiRemoteProgress(sectionIndex: section, normCharOffset: norm, charOffset: -1, updatedAtMs: ms)
}

@main
struct FushiProgressSyncTests {
    static func main() throws {
        try sectionTableFollowsFushiSpineRules()
        mappingRoundTrips()
        resolverMatchesFushiThreeWayRules()
        wireAndPairingDetails()

        if failures > 0 {
            fputs("\(failures) failure(s)\n", stderr)
            exit(1)
        }
        print("PASS test_fushi_progress_sync")
    }

    /// Fushi keeps spine items that are HTML and exist; Niratan's spine index counts
    /// every itemref with an idref (EPUBKit), including non-linear ones.
    static func sectionTableFollowsFushiSpineRules() throws {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover" href="images/cover.jpg" media-type="image/jpeg"/>
            <item id="c1" href="text/ch%201.xhtml" media-type="application/xhtml+xml"/>
            <item id="gone" href="text/missing.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/ch2.html" media-type="text/html"/>
            <item id="svg" href="text/page.svg" media-type="image/svg+xml"/>
            <item id="note" href="text/note.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="nav"/>
            <itemref idref="cover"/>
            <itemref/>
            <itemref idref="c1"/>
            <itemref idref="gone"/>
            <itemref idref="c2"/>
            <itemref idref="svg"/>
            <itemref idref="note" linear="no"/>
            <itemref idref="unknown"/>
          </spine>
        </package>
        """
        let files: [String: String] = [
            "META-INF/container.xml": container,
            "OEBPS/content.opf": package,
            "OEBPS/nav.xhtml": "",
            "OEBPS/images/cover.jpg": "",
            "OEBPS/text/ch 1.xhtml": "",
            "OEBPS/text/ch2.html": "",
            "OEBPS/text/page.svg": "",
            "OEBPS/text/note.xhtml": ""
        ]
        let sections = try FushiEPUBSpineReader.sectionSpineIndices(
            read: { files[$0].map { Data($0.utf8) } },
            exists: { files[$0] != nil }
        )
        // Spine (idref only): 0 nav, 1 cover, 2 c1, 3 gone, 4 c2, 5 svg, 6 note, 7 unknown.
        expect(sections == [0, 2, 4, 6], "section spine indices were \(sections)")
        expect(FushiEPUBSpineReader.isHTMLMediaType(" Application/XHTML+XML "), "xhtml media type")
        expect(FushiEPUBSpineReader.isHTMLMediaType("application/vnd.example+html"), "+html media type")
        expect(!FushiEPUBSpineReader.isHTMLMediaType("image/svg+xml"), "svg is not a Fushi chapter")
    }

    static func mappingRoundTrips() {
        // Spine 0 is an image page Fushi skips; chapters at spine 1, 2 and 4.
        let info = BookInfo(
            characterCount: 6_000,
            chapterInfo: [
                "a.xhtml": chapter(1, 0, 1_000),
                "b.xhtml": chapter(2, 1_000, 3_000),
                "img.svg": chapter(3, 4_000, 0),
                "c.xhtml": chapter(4, 4_000, 2_000)
            ]
        )
        let sections = FushiSectionTable(spineIndices: [1, 2, 4])

        let local = bookmark(2, 2_500, progress: 0.9)
        let position = FushiProgressMapping.remotePosition(for: local, bookInfo: info, sections: sections)
        expect(position?.sectionIndex == 1, "spine 2 is Fushi section 1")
        expect(position?.normCharOffset == 5_000, "character offset decides the in-chapter position, got \(String(describing: position))")

        let back = FushiProgressMapping.bookmark(for: remote(1, 5_000, 1_700_000_000_000), bookInfo: info, sections: sections)
        expect(back?.chapterIndex == 2, "section 1 maps back to spine 2")
        expect(back?.characterCount == 2_500, "section 1 at 50% is character 2500")
        expect(back?.lastModified == Date(timeIntervalSince1970: 1_700_000_000), "remote time becomes the bookmark time")

        let skipped = FushiProgressMapping.remotePosition(for: bookmark(3, 4_000), bookInfo: info, sections: sections)
        expect(skipped?.sectionIndex == 2 && skipped?.normCharOffset == 0, "a skipped spine item maps to the next section start")
        let beforeFirst = FushiProgressMapping.remotePosition(for: bookmark(0, 0), bookInfo: info, sections: sections)
        expect(beforeFirst?.sectionIndex == 0 && beforeFirst?.normCharOffset == 0, "leading image page maps to section 0")
        let pastEnd = FushiProgressMapping.remotePosition(for: bookmark(9, 6_000), bookInfo: info, sections: sections)
        expect(pastEnd?.sectionIndex == 2 && pastEnd?.normCharOffset == 10_000, "trailing spine maps to the end of the last section")

        let outside = FushiProgressMapping.remotePosition(for: bookmark(1, 9_999, progress: 0.25), bookInfo: info, sections: sections)
        expect(outside?.normCharOffset == 2_500, "out-of-range characters fall back to chapter progress")

        expect(FushiProgressMapping.bookmark(for: remote(7, 0, 1), bookInfo: info, sections: sections) == nil, "unknown section has no local position")
        let clamped = FushiProgressMapping.bookmark(for: remote(2, 12_000, 1), bookInfo: info, sections: sections)
        expect(clamped?.characterCount == 6_000 && clamped?.progress == 1, "norm offsets above 10000 are clamped")
    }

    static func resolverMatchesFushiThreeWayRules() {
        let info = BookInfo(characterCount: 4_000, chapterInfo: ["a": chapter(0, 0, 2_000), "b": chapter(1, 2_000, 2_000)])
        let sections = FushiSectionTable(spineIndices: [0, 1])

        func decide(local: Bookmark?, remote: FushiRemoteProgress, base: FushiProgressBaseline?) -> FushiProgressAction {
            FushiProgressResolver.resolve(
                local: local,
                remote: remote,
                remoteAsLocal: remote.isEmpty ? nil : FushiProgressMapping.bookmark(for: remote, bookInfo: info, sections: sections),
                localAsRemote: local.flatMap { FushiProgressMapping.remotePosition(for: $0, bookInfo: info, sections: sections) },
                base: base
            )
        }

        let agreedRemote = remote(0, 5_000, 1_000)
        let agreedLocal = bookmark(0, 1_000, ms: 1_000)
        let base = FushiProgressBaseline(remote: agreedRemote, local: agreedLocal)

        expect(decide(local: nil, remote: .empty, base: nil) == .synced, "both empty")
        expect(decide(local: nil, remote: agreedRemote, base: nil) == .applyRemote, "local empty takes Fushi")
        expect(decide(local: agreedLocal, remote: .empty, base: nil) == .pushLocal, "host empty takes local")
        expect(decide(local: agreedLocal, remote: agreedRemote, base: nil) == .synced, "same position without baseline")
        expect(decide(local: bookmark(0, 1_030, ms: 9_000), remote: agreedRemote, base: base) == .synced, "pagination drift is the same position")
        expect(decide(local: bookmark(1, 3_000, ms: 2_000), remote: agreedRemote, base: nil) == .conflict, "different positions without baseline ask the user")
        expect(decide(local: bookmark(1, 3_000, ms: 2_000), remote: agreedRemote, base: base) == .pushLocal, "only Niratan moved")
        expect(decide(local: agreedLocal, remote: remote(1, 2_000, 5_000), base: base) == .applyRemote, "only Fushi moved")
        expect(decide(local: bookmark(1, 3_000, ms: 2_000), remote: remote(1, 9_000, 5_000), base: base) == .conflict, "both moved")
        // An older local timestamp does not matter: the baseline decides.
        expect(decide(local: bookmark(1, 3_500, ms: 10), remote: remote(0, 9_000, 99_999), base: base) == .conflict, "both moved regardless of timestamps")
        let staleBase = FushiProgressBaseline(remote: remote(1, 9_999, 0), local: bookmark(1, 3_999))
        expect(decide(local: bookmark(0, 1_500, ms: 7_000), remote: remote(0, 2_000, 6_000), base: staleBase) == .conflict, "a stale baseline with both sides off it is a conflict")

        expect(FushiProgressResolver.pushTimestamp(local: bookmark(0, 0, ms: 2_000), remote: remote(0, 0, 5_000)) == 5_001, "push beats the host timestamp")
        expect(FushiProgressResolver.pushTimestamp(local: bookmark(0, 0, ms: 9_000), remote: remote(0, 0, 5_000)) == 9_000, "push keeps a newer local timestamp")
    }

    static func wireAndPairingDetails() {
        expect(
            FushiInterconnectClient.pinProof(pin: "123456", clientNonce: "clientNonce-A", hostNonce: "hostNonce-B")
                == "dc9a12c89f76bed7162847926fec139315935daf7c8e4e7c0d63e6b72897e5dc",
            "PIN proof is hex HMAC-SHA256(PIN, clientNonce|hostNonce)"
        )
        let nonce = FushiInterconnectClient.makeNonce()
        expect(nonce.count == 32 && !nonce.contains("=") && !nonce.contains("+") && !nonce.contains("/"), "nonce is unpadded base64url of 24 bytes")

        expect(FushiInterconnectClient.normalizedBaseURL("192.168.1.10")?.absoluteString == "http://192.168.1.10:38765", "default scheme and port")
        expect(FushiInterconnectClient.normalizedBaseURL(" 10.0.0.2:4000/ ")?.absoluteString == "http://10.0.0.2:4000", "explicit port, trimmed path")
        expect(FushiInterconnectClient.normalizedBaseURL("https://host.local")?.absoluteString == "https://host.local:38765", "https keeps its scheme")
        expect(FushiInterconnectClient.normalizedBaseURL("ftp://host") == nil, "other schemes are rejected")
        expect(FushiInterconnectClient.normalizedBaseURL("") == nil, "empty address")

        expect(
            FushiInterconnectClient.normalizedFingerprint("AA:bb:0C") == FushiInterconnectClient.normalizedFingerprint("aabb0c"),
            "fingerprints compare without colons or case"
        )

        let decoded = try? JSONDecoder().decode(
            FushiRemoteProgress.self,
            from: Data(#"{"sectionIndex":2.0,"normCharOffset":null,"updatedAtMs":5}"#.utf8)
        )
        expect(decoded == remote(2, 0, 5), "tolerant progress decoding, got \(String(describing: decoded))")
        let encoded = (try? JSONEncoder().encode(remote(1, 2, 3))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        for key in ["\"sectionIndex\":1", "\"normCharOffset\":2", "\"charOffset\":-1", "\"updatedAtMs\":3"] {
            expect(encoded.contains(key), "progress JSON contains \(key): \(encoded)")
        }

        let keyed = try? JSONDecoder().decode([FushiRemoteBook].self, from: Data(#"[{"title":"a/b?","hasContent":true},{"title":"x","bookKey":"key-x","kind":"manga"}]"#.utf8))
        expect(keyed?.first?.key == "a%2Fb%3F", "books without bookKey use the ッツ-sanitized title")
        expect(keyed?.last?.key == "key-x" && keyed?.last?.isNovel == false, "bookKey wins and manga is not a novel")
    }
}
