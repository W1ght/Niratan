// test-sources: Features/Bookshelf/BookshelfDropSupport.swift
import AppKit
import Foundation

@main
private enum BookshelfFileDropDecoderTests {
    static func main() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hoshi-bookshelf-file-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let epubURL = URL(fileURLWithPath: "/tmp/Hoshi Drop Test.epub")
        let textURL = URL(fileURLWithPath: "/tmp/Hoshi Drop Test.txt")

        let epubItem = NSPasteboardItem()
        epubItem.setData(epubURL.absoluteString.data(using: .utf8)!, forType: .fileURL)
        let textItem = NSPasteboardItem()
        textItem.setData(textURL.absoluteString.data(using: .utf8)!, forType: .fileURL)
        pasteboard.writeObjects([epubItem, textItem])

        let urls = BookshelfFileDropDecoder.fileURLs(from: pasteboard)
        expect(urls == [epubURL, textURL], "file URL pasteboard data should decode in drop order")
        expect(urls.filter { $0.pathExtension.lowercased() == "epub" } == [epubURL], "EPUB filtering should preserve Finder file URLs")

        print("Bookshelf file drop decoder tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
