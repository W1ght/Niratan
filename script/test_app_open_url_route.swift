// test-sources: NativeMac/AppOpenURLRoute.swift
import Foundation

@main
private enum AppOpenURLRouteTests {
    static func main() {
        expect(
            AppOpenURLRoute(url: URL(fileURLWithPath: "/tmp/book.epub")),
            .localFile(URL(fileURLWithPath: "/tmp/book.epub")),
            "file URLs should route to local import"
        )

        expect(
            AppOpenURLRoute(url: URL(string: "hoshi://search?text=%E6%98%9F")!),
            .dictionarySearch("星"),
            "search URLs should decode and route the text query"
        )

        expect(
            AppOpenURLRoute(url: URL(string: "hoshi://search")!),
            .dictionarySearch(""),
            "search URLs without text should open an empty dictionary search"
        )

        expect(
            AppOpenURLRoute(url: URL(string: "hoshi://open?url=https%3A%2F%2Fexample.com%2Fbook.epub")!),
            .remoteBook(URL(string: "https://example.com/book.epub")!),
            "open URLs should route valid remote book URLs"
        )

        expect(
            AppOpenURLRoute(url: URL(string: "hoshi://open?url=not-a-url")!),
            nil,
            "open URLs should reject values without a URL scheme"
        )

        expect(
            AppOpenURLRoute(url: URL(string: "https://example.com/book.epub")!),
            nil,
            "ordinary web URLs should not be handled as app routes"
        )

        print("App open URL route tests passed")
    }

    private static func expect(
        _ actual: AppOpenURLRoute?,
        _ expected: AppOpenURLRoute?,
        _ message: String
    ) {
        guard actual == expected else {
            fputs("FAIL: \(message)\nExpected: \(String(describing: expected))\nActual: \(String(describing: actual))\n", stderr)
            exit(1)
        }
    }
}
