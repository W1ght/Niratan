// test-sources: Features/Manga/MangaEPUBParser.swift Models/Manga.swift
import Foundation

@main
private enum MangaEPUBParserTests {
    static func main() throws {
        let container = Data(
            """
            <?xml version="1.0"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf"
                          media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8
        )
        let packagePath = try MangaEPUBParser.packagePath(in: container)
        require(packagePath == "OEBPS/content.opf", "container rootfile must resolve")

        let packageData = Data(
            """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="cover" href="Images/cover.jpg" media-type="image/jpeg"/>
                <item id="p1" href="Text/p1.xhtml" media-type="application/xhtml+xml"/>
                <item id="p2" href="Text/p2.svg" media-type="image/svg+xml"/>
                <item id="p3" href="Images/003.jpg" media-type="image/jpeg"/>
                <item id="nonlinear" href="Text/nav.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="p1"/>
                <itemref idref="p2"/>
                <itemref idref="p3"/>
                <itemref idref="nonlinear" linear="no"/>
              </spine>
            </package>
            """.utf8
        )
        let package = try MangaEPUBParser.package(
            at: packagePath,
            data: packageData
        )
        require(
            package.spineItemIDs == ["p1", "p2", "p3"],
            "non-linear spine resources must not become manga pages"
        )

        let documents: [String: Data] = [
            "OEBPS/Text/p1.xhtml": Data(
                """
                <html xmlns="http://www.w3.org/1999/xhtml">
                  <body><img src="../Images/001.jpg#page"/></body>
                </html>
                """.utf8
            ),
            "OEBPS/Text/p2.svg": Data(
                """
                <svg xmlns="http://www.w3.org/2000/svg"
                     xmlns:xlink="http://www.w3.org/1999/xlink">
                  <image xlink:href="../Images/002.jpg"/>
                </svg>
                """.utf8
            ),
        ]
        let pages = try package.orderedImagePaths { documents[$0] }
        require(
            pages == [
                "OEBPS/Images/001.jpg",
                "OEBPS/Images/002.jpg",
                "OEBPS/Images/003.jpg",
            ],
            "EPUB manga pages must follow spine order and resolve document-relative image paths: \(pages)"
        )
        require(
            MangaEPUBParser.resolve(
                reference: "../../../secret.jpg",
                relativeTo: "OEBPS/Text/page.xhtml"
            ) == nil,
            "EPUB references must not escape the archive root"
        )

        print("Manga EPUB parser tests passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
