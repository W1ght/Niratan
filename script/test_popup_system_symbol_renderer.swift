// test-sources: Features/Popup/PopupSystemSymbolRenderer.swift
import AppKit
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum PopupSystemSymbolRendererContract {
    static func main() throws {
        let symbols = [
            "duplicate": PopupSystemSymbolRenderer.duplicateSymbolDataURL,
            "view note": PopupSystemSymbolRenderer.viewNoteSymbolDataURL,
        ]
        for (name, value) in symbols {
            guard let dataURL = value else {
                fputs("FAIL: renderer should produce the \(name) system symbol\n", stderr)
                exit(1)
            }
            try validate(dataURL)
        }
        print("PASS: popup system symbol renderer contract")
    }

    private static func validate(_ dataURL: String) throws {
        require(dataURL.hasPrefix("data:image/png;base64,"), "renderer should return a PNG data URL")

        let encoded = String(dataURL.dropFirst("data:image/png;base64,".count))
        guard let data = Data(base64Encoded: encoded),
              let bitmap = NSBitmapImageRep(data: data) else {
            fputs("FAIL: renderer output should decode as PNG\n", stderr)
            exit(1)
        }
        require(bitmap.pixelsWide == 84 && bitmap.pixelsHigh == 84, "renderer should use a 28-point 3x canvas")
        require(bitmap.hasAlpha, "renderer output should preserve transparency")

        let containsVisiblePixels = (0..<bitmap.pixelsHigh).contains { y in
            (0..<bitmap.pixelsWide).contains { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
            }
        }
        require(containsVisiblePixels, "renderer output should contain visible symbol pixels")
    }
}
