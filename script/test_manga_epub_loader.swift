// test-sources: Features/Manga/MangaPageLoader.swift Models/Manga.swift Features/Manga/MangaEPUBParser.swift Features/Manga/MangaMokuroParser.swift
// test-modules: ZIPFoundation
import Foundation
import ZIPFoundation

@main
private enum MangaEPUBLoaderTests {
    static func main() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("hoshi-manga-epub-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let epubURL = directory.appendingPathComponent("fixture.epub")
        let archive = try Archive(url: epubURL, accessMode: .create, pathEncoding: .utf8)
        try archive.addText(
            "application/epub+zip",
            at: "mimetype",
            compressionMethod: .none
        )
        try archive.addText(
            """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/package.opf"
                          media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """,
            at: "META-INF/container.xml"
        )
        try archive.addText(
            """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="decoration" href="Images/000-decoration.png" media-type="image/png"/>
                <item id="p1" href="Text/p1.xhtml" media-type="application/xhtml+xml"/>
                <item id="p2" href="Text/p2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="p2"/>
                <itemref idref="p1"/>
              </spine>
            </package>
            """,
            at: "OEBPS/package.opf"
        )
        try archive.addText(
            #"<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../Images/001.png"/></body></html>"#,
            at: "OEBPS/Text/p1.xhtml"
        )
        try archive.addText(
            #"<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="../Images/002.png"/></body></html>"#,
            at: "OEBPS/Text/p2.xhtml"
        )
        let decoration = Data([0])
        let firstInSpine = Data([2, 2, 2])
        let secondInSpine = Data([1, 1])
        try archive.addData(decoration, at: "OEBPS/Images/000-decoration.png")
        try archive.addData(secondInSpine, at: "OEBPS/Images/001.png")
        try archive.addData(firstInSpine, at: "OEBPS/Images/002.png")

        let pages = try MangaPageLoader.inspectPages(at: epubURL, kind: .epubArchive)
        require(
            pages.map(\.path) == [
                "OEBPS/Images/002.png",
                "OEBPS/Images/001.png",
            ],
            "loader must use EPUB spine order and exclude unreferenced artwork: \(pages.map(\.path))"
        )
        try require(
            try MangaPageLoader.coverData(at: epubURL, kind: .epubArchive) == firstInSpine,
            "EPUB cover cache input must use the first readable spine page"
        )

        let mokuroArchiveURL = directory.appendingPathComponent("mokuro.zip")
        let mokuroArchive = try Archive(
            url: mokuroArchiveURL,
            accessMode: .create,
            pathEncoding: .utf8
        )
        try mokuroArchive.addData(Data([3]), at: "series/volume/001.png")
        try mokuroArchive.addText(
            #"{"pages":[{"img_path":"001.png","img_width":1,"img_height":1,"blocks":[]}]}"#,
            at: "series/volume.mokuro"
        )
        try mokuroArchive.addData(Data([5]), at: "series/volume-two/001.png")
        try mokuroArchive.addText(
            #"{"pages":[{"img_path":"001.png","img_width":1,"img_height":1,"blocks":[]}]}"#,
            at: "series/volume-two.mokuro"
        )
        require(
            MangaPageLoader.hasMokuroMetadata(
                at: mokuroArchiveURL,
                kind: .zipArchive
            ),
            "Mokuro archives must read metadata stored inside the archive"
        )
        let archiveBooks = try MangaPageLoader.mokuroArchiveBooks(at: mokuroArchiveURL)
        let archiveBooksByTitle = Dictionary(
            uniqueKeysWithValues: archiveBooks.map { ($0.title, $0.imagePaths) }
        )
        require(
            Set(archiveBooks.map(\.title)) == ["volume", "volume-two"],
            "each Mokuro metadata root must become its own book: \(archiveBooks)"
        )
        require(
            archiveBooksByTitle["volume"] == ["series/volume/001.png"]
                && archiveBooksByTitle["volume-two"] == ["series/volume-two/001.png"],
            "sibling Mokuro metadata must resolve duplicate page names inside its matching image directory"
        )
        let secondBookPages = try MangaPageLoader.inspectPages(
            at: mokuroArchiveURL,
            kind: .zipArchive,
            archiveMetadataPath: "series/volume-two.mokuro"
        )
        require(
            secondBookPages.map(\.path) == ["series/volume-two/001.png"],
            "opening one archive book must not include sibling book pages"
        )

        let mokuroFolderURL = directory.appendingPathComponent("mokuro-folder")
        let mokuroSeriesURL = mokuroFolderURL.appendingPathComponent("series")
        let firstVolumeURL = mokuroSeriesURL.appendingPathComponent("volume")
        let secondVolumeURL = mokuroSeriesURL.appendingPathComponent("volume-two")
        try fileManager.createDirectory(
            at: firstVolumeURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: secondVolumeURL,
            withIntermediateDirectories: true
        )
        try Data([3]).write(to: firstVolumeURL.appendingPathComponent("001.png"))
        try Data([5]).write(to: secondVolumeURL.appendingPathComponent("001.png"))
        try Data(
            #"{"pages":[{"img_path":"001.png","img_width":1,"img_height":1,"blocks":[]}]}"#
                .utf8
        ).write(to: mokuroSeriesURL.appendingPathComponent("volume.mokuro"))
        try Data(
            #"{"pages":[{"img_path":"001.png","img_width":1,"img_height":1,"blocks":[]}]}"#
                .utf8
        ).write(to: mokuroSeriesURL.appendingPathComponent("volume-two.mokuro"))
        let folderBooks = try MangaPageLoader.mokuroDirectoryURLs(at: mokuroFolderURL)
        require(
            folderBooks.map(\.lastPathComponent) == ["volume", "volume-two"],
            "a nested Mokuro folder must discover each metadata/image sibling pair as one book"
        )

        let plainArchiveURL = directory.appendingPathComponent("plain.zip")
        let plainArchive = try Archive(
            url: plainArchiveURL,
            accessMode: .create,
            pathEncoding: .utf8
        )
        try plainArchive.addData(Data([4]), at: "001.png")
        require(
            !MangaPageLoader.hasMokuroMetadata(
                at: plainArchiveURL,
                kind: .zipArchive
            ),
            "plain image archives must not be accepted as Mokuro imports"
        )

        if let realArchivePath = ProcessInfo.processInfo.environment[
            "HOSHI_MANGA_ARCHIVE_TEST_PATH"
        ] {
            let realBooks = try MangaPageLoader.mokuroArchiveBooks(
                at: URL(fileURLWithPath: realArchivePath)
            )
            if let expectedText = ProcessInfo.processInfo.environment[
                "HOSHI_MANGA_EXPECTED_BOOK_COUNT"
            ], let expectedCount = Int(expectedText) {
                require(
                    realBooks.count == expectedCount,
                    "real Mokuro archive should contain \(expectedCount) books: \(realBooks)"
                )
            }
            print(
                "Real Mokuro archive books: "
                    + realBooks.map {
                        "\($0.title) (\($0.imagePaths.count) pages, "
                            + "\($0.imagePaths.first ?? "no first page") … "
                            + "\($0.imagePaths.last ?? "no last page"))"
                    }.joined(separator: ", ")
            )
        }
        if let realFolderPath = ProcessInfo.processInfo.environment[
            "HOSHI_MANGA_FOLDER_TEST_PATH"
        ] {
            let realFolders = try MangaPageLoader.mokuroDirectoryURLs(
                at: URL(fileURLWithPath: realFolderPath)
            )
            if let expectedText = ProcessInfo.processInfo.environment[
                "HOSHI_MANGA_EXPECTED_BOOK_COUNT"
            ], let expectedCount = Int(expectedText) {
                require(
                    realFolders.count == expectedCount,
                    "real Mokuro folder should contain \(expectedCount) books: \(realFolders)"
                )
            }
            print(
                "Real Mokuro folder books: "
                    + realFolders.map(\.lastPathComponent).joined(separator: ", ")
            )
        }

        print("Manga EPUB loader tests passed")
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) rethrows {
        guard try condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}

private extension Archive {
    func addText(
        _ text: String,
        at path: String,
        compressionMethod: CompressionMethod = .deflate
    ) throws {
        try addData(Data(text.utf8), at: path, compressionMethod: compressionMethod)
    }

    func addData(
        _ data: Data,
        at path: String,
        compressionMethod: CompressionMethod = .deflate
    ) throws {
        try addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressionMethod
        ) { position, size in
            let start = Int(position)
            let end = Swift.min(start + size, data.count)
            return data.subdata(in: start..<end)
        }
    }
}
