// test-sources: NativeMac/NativeFullscreenImageDocument.swift
import Foundation

@main
struct NativeFullscreenImageDocumentTests {
    static func main() {
        let url = URL(fileURLWithPath: "/tmp/Reader Fixture/image-a.svg")
        let data = Data("<svg></svg>".utf8)
        let document = NativeFullscreenImageDocument.html(for: url, data: data)

        precondition(document.contains("object-fit: contain"))
        precondition(document.contains("data:image/svg+xml;base64,"))
        precondition(document.contains(data.base64EncodedString()))
        precondition(document.contains("max-width: 100%"))
        precondition(document.contains("max-height: 100%"))

        print("Native fullscreen image document tests passed")
    }
}
