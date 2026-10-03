import Foundation

enum VideoAudioClipExporterError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

enum VideoAudioClipExporter {
    static func export(
        source: VideoAudioExportSource,
        from start: TimeInterval,
        to end: TimeInterval,
        outputURL: URL
    ) async throws {
        guard end > start else {
            throw VideoAudioClipExporterError.failed(
                String(localized: "Unable to determine the video audio range.")
            )
        }
        let result: (Bool, String?) = await Task.detached(priority: .userInitiated) {
            var errorMessage: NSString?
            let succeeded = HSMpvAudioClipExporter.exportAudio(
                from: source.url,
                to: outputURL,
                startTime: start,
                endTime: end,
                httpHeaders: source.httpHeaders,
                audioTrackID: source.audioTrackID.map(NSNumber.init(value:)),
                errorMessage: &errorMessage
            )
            return (succeeded, errorMessage as String?)
        }.value
        guard result.0 else {
            throw VideoAudioClipExporterError.failed(
                result.1 ?? String(localized: "The bundled audio encoder could not export this subtitle range.")
            )
        }
    }
}
