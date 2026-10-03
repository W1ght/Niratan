// test-sources: Models/Anki.swift Features/Video/VideoMiningMediaStore.swift Core/AnkiMediaProcessor.swift
import AppKit
import Foundation
import ImageIO

private func expect(_ c: @autoclosure () -> Bool, _ m: String) {
    guard c() else { fputs("FAIL: \(m)\n", stderr); exit(1) }
}

@main
private struct VideoScreenshotCompressionTests {
    @MainActor
    static func main() async throws {
        let json = #"{"selectedDeck":null,"selectedNoteType":null,"allowDupes":false,"compactGlossaries":false,"embedMedia":false,"fieldMappings":{},"tags":"","duplicateScope":"collection","checkAllModels":false}"#
        let profile = try JSONDecoder().decode(AnkiProfileConfig.self, from: Data(json.utf8))
        expect(profile.effectiveCompressVideoScreenshots, "legacy profile defaults compression on")
        expect(profile.effectiveImageCompressionFormat == .jpeg, "legacy profile defaults to JPEG")
        expect(
            profile.effectiveAnimatedAVIFMaximumHeight == 350,
            "legacy profiles default animated AVIF to 350p"
        )
        expect(
            profile.effectiveAnimatedAVIFFramesPerSecond == 10,
            "legacy profiles default animated AVIF to 10 fps"
        )
        let customProfileJSON = #"{"selectedDeck":null,"selectedNoteType":null,"allowDupes":false,"compactGlossaries":false,"embedMedia":false,"fieldMappings":{},"tags":"","duplicateScope":"collection","checkAllModels":false,"animatedAVIFMaximumHeight":240,"animatedAVIFFramesPerSecond":6}"#
        let customProfile = try JSONDecoder().decode(
            AnkiProfileConfig.self,
            from: Data(customProfileJSON.utf8)
        )
        expect(
            customProfile.effectiveAnimatedAVIFMaximumHeight == 240,
            "profiles persist custom animated AVIF height"
        )
        expect(
            customProfile.effectiveAnimatedAVIFFramesPerSecond == 6,
            "profiles persist custom animated AVIF frame rate"
        )
        let names = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
            cueStart: 1, cueEnd: 2, audioStart: 1, audioEnd: 2,
            screenshotFormat: .jpeg
        )
        expect(names.screenshot.hasSuffix(".jpg"), "JPEG names use .jpg")
        let avifNames = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
            cueStart: 1, cueEnd: 2, audioStart: 1, audioEnd: 2,
            screenshotFormat: .avif,
            screenshotQuality: 0.75
        )
        expect(
            avifNames.screenshot.hasSuffix("_avif5_q75.avif"),
            "AVIF names version the animation profile with the user's Image Quality"
        )
        let avifLowQuality = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
            cueStart: 1, cueEnd: 2, audioStart: 1, audioEnd: 2,
            screenshotFormat: .avif,
            screenshotQuality: 0.40
        )
        expect(
            avifNames.screenshot != avifLowQuality.screenshot,
            "AVIF media names should differ by the chosen Image Quality"
        )
        let compactAVIFNames = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
            cueStart: 1, cueEnd: 2, audioStart: 1, audioEnd: 2,
            screenshotFormat: .avif,
            screenshotQuality: 0.75,
            animatedAVIFMaximumHeight: 240,
            animatedAVIFFramesPerSecond: 6
        )
        expect(
            compactAVIFNames.screenshot.hasSuffix("_avif5_q75_h240_fps6.avif"),
            "AVIF media names should include custom resolution and frame rate"
        )
        expect(
            avifNames.screenshot != compactAVIFNames.screenshot,
            "different AVIF animation settings must not reuse cached media"
        )
        let delayedAVIFNames = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/tmp/episode.mkv"),
            cueStart: 1, cueEnd: 2, audioStart: 1.25, audioEnd: 2.25,
            screenshotFormat: .avif,
            screenshotStart: 1.25,
            screenshotEnd: 2.25,
            screenshotQuality: 0.75
        )
        expect(
            avifNames.screenshot != delayedAVIFNames.screenshot,
            "AVIF media names should include the actual delayed animation range"
        )

        let store = VideoMiningMediaStore()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        memset(bitmap.bitmapData!, 0x7f, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let source = store.screenshotURL()
        try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        let jpeg = try store.preparedScreenshot(at: source, compress: true)
        expect(jpeg.pathExtension == "jpg", "compressed output is .jpg")
        let jpegData = try Data(contentsOf: jpeg)
        expect(
            jpegData.starts(with: [0xFF, 0xD8]),
            "JPEG magic bytes"
        )

        let avifSource = store.screenshotURL()
        try bitmap.representation(using: .png, properties: [:])!.write(to: avifSource)
        let avif = try store.preparedScreenshot(
            at: avifSource,
            compress: true,
            format: .avif,
            quality: 0.75
        )
        expect(avif.pathExtension == "avif", "compressed AVIF output uses .avif")
        let avifData = try Data(contentsOf: avif)
        expect(
            avifData.range(of: Data("ftypavif".utf8)) != nil,
            "AVIF file type marker"
        )
        expect(
            CGImageSourceCreateWithData(avifData as CFData, nil) != nil,
            "AVIF data should be readable by ImageIO"
        )

        let highSource = store.screenshotURL()
        let lowSource = store.screenshotURL()
        try bitmap.representation(using: .png, properties: [:])!.write(to: highSource)
        try bitmap.representation(using: .png, properties: [:])!.write(to: lowSource)
        let highQuality = try store.preparedScreenshot(
            at: highSource,
            compress: true,
            quality: 0.95
        )
        let lowQuality = try store.preparedScreenshot(
            at: lowSource,
            compress: true,
            quality: 0.40
        )
        let highQualityData = try Data(contentsOf: highQuality)
        let lowQualityData = try Data(contentsOf: lowQuality)
        expect(
            highQualityData != lowQualityData,
            "image quality slider should change JPEG encoding"
        )

        let png = store.screenshotURL()
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let retained = try store.preparedScreenshot(at: png, compress: false)
        expect(retained.pathExtension == "png", "opt-out retains .png")
        let pngData = try Data(contentsOf: retained)
        expect(
            pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]),
            "PNG magic bytes"
        )

        let sharedDestination = store.directory.appendingPathComponent(
            "shared-media-\(UUID().uuidString).avif"
        )
        defer { try? FileManager.default.removeItem(at: sharedDestination) }
        expect(
            store.claimDirectMediaGeneration(at: sharedDestination),
            "the first direct-media request should own generation"
        )
        let sharedWaiter = Task { @MainActor in
            await store.waitForDirectMediaGeneration(at: sharedDestination)
        }
        await Task.yield()
        try Data("ready".utf8).write(to: sharedDestination)
        store.finishDirectMediaGeneration(at: sharedDestination, succeeded: true)
        let sharedReady = await sharedWaiter.value
        expect(
            sharedReady,
            "a repeated card should wait until shared media is actually ready"
        )

        let failedDestination = store.directory.appendingPathComponent(
            "failed-media-\(UUID().uuidString).avif"
        )
        expect(
            store.claimDirectMediaGeneration(at: failedDestination),
            "a failed direct-media request should initially own generation"
        )
        let failedWaiter = Task { @MainActor in
            await store.waitForDirectMediaGeneration(at: failedDestination)
        }
        await Task.yield()
        store.finishDirectMediaGeneration(at: failedDestination, succeeded: false)
        let failedReady = await failedWaiter.value
        expect(
            failedReady == false,
            "a failed shared export must not be reported as ready"
        )
        print("Video screenshot compression tests passed")
    }
}
