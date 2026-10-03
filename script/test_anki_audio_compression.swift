// test-sources: Models/Anki.swift Core/AnkiAudioCompressor.swift
// test-modules: SwiftLAME LAME
import AVFAudio
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AnkiAudioCompressionTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoshi-audio-compression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.wav")
        try makeSource(at: sourceURL)

        for format in AnkiAudioCompressionFormat.allCases {
            let lowURL = directory.appendingPathComponent("low.\(format.fileExtension)")
            let highURL = directory.appendingPathComponent("high.\(format.fileExtension)")
            let low = try await AnkiAudioCompressor.data(
                from: sourceURL,
                format: format,
                bitrateKbps: 32,
                destinationURL: lowURL
            )
            let high = try await AnkiAudioCompressor.data(
                from: sourceURL,
                format: format,
                bitrateKbps: 128,
                destinationURL: highURL
            )
            expect(!low.isEmpty && !high.isEmpty, "\(format.rawValue) output should not be empty")
            expect(high.count > low.count, "\(format.rawValue) bitrate should affect output size")
            expect(
                (try? AVAudioFile(forReading: lowURL).length) ?? 0 > 0,
                "\(format.rawValue) output should be readable"
            )
        }

        print("Anki audio compression tests passed")
    }

    private static func makeSource(at url: URL) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frameCount = AVAudioFrameCount(sampleRate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate))
        }
        try file.write(from: buffer)
    }
}
