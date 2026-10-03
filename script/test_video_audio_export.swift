// test-skip: manual tool (needs <source-media> <output> arguments and the app's Objective-C++ mpv bridge)
import Foundation

@main
private enum VideoAudioExportTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            exit(2)
        }
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        try await VideoAudioClipExporter.export(
            sourceURL: sourceURL,
            from: 0,
            to: 0.8,
            audioTrackID: 1,
            outputURL: outputURL
        )
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else {
            fputs("FAIL: exported audio clip is empty\n", stderr)
            exit(1)
        }
        print("Video audio export test passed")
    }
}
