import CryptoKit
import Foundation

/// A downloadable model file with a pinned, immutable URL.
nonisolated struct MangaOCRModelFile: Sendable, Equatable {
    let fileName: String
    let url: URL
    let expectedBytes: Int64
    let sha256: String
}

nonisolated enum MangaOCRModelSet: String, CaseIterable, Sendable {
    /// Text detector + PP-OCRv6 line detector + manga-tuned CTC recognizer
    /// (Fushi "manga CTC (fast)").
    case mangaCTC
    /// Text detector + manga-ocr (KV-cache decoder) + PP-OCRv6 line models
    /// (Fushi classic local ONNX engine).
    case mangaOCR
    /// Text detector only (used to guide the Apple Vision engine).
    case textDetector
    /// Manga panel detector for panel-by-panel navigation.
    case panelDetector

    static let detectorFile = MangaOCRModelFile(
        fileName: "detector-v4-s_int8.onnx",
        url: URL(string: "https://huggingface.co/ogkalu/comic-text-and-bubble-detector/resolve/16e8a622f91fabc6b5b65c96d32d1183f8843546/detector-v4-s_int8.onnx")!,
        expectedBytes: 11_120_765,
        sha256: "5fe9e4f576e49d4e7e8b0e029d6d3cdc252abd4694113e1cae120e62c931ea79"
    )
    static let encoderFile = MangaOCRModelFile(
        fileName: "encoder_model.onnx",
        url: URL(string: "https://huggingface.co/mayocream/manga-ocr-onnx/resolve/24b12778d85800835e2ca409236de281b8ab7b9f/encoder_model.onnx")!,
        expectedBytes: 343_454_249,
        sha256: "15fa8155fe9bc1a7d25d9bb353debaa4def033d0174e907dbd2dd6d995def85f"
    )
    /// KV-cache decoder export of manga-ocr (Fushi release
    /// `manga-ocr-kv-onnx-v1`); token-for-token identical to the classic
    /// `decoder_model.onnx`, about twice as fast.
    static let crossKVFile = MangaOCRModelFile(
        fileName: "cross_kv.onnx",
        url: URL(string: "https://github.com/hajisensai/Fushi/releases/download/manga-ocr-kv-onnx-v1/cross_kv.onnx")!,
        expectedBytes: 9_456_696,
        sha256: "3355a58b0e05f874d7fbb332df6824c0e6634d0b99c756322ba119a9d3f35722"
    )
    static let decoderKVFile = MangaOCRModelFile(
        fileName: "decoder_kv.onnx",
        url: URL(string: "https://github.com/hajisensai/Fushi/releases/download/manga-ocr-kv-onnx-v1/decoder_kv.onnx")!,
        expectedBytes: 89_050_460,
        sha256: "db4907131dc96308c3d9e4910db2238cf2dee5cfcb1cd3ae7c7b52d630cd8de5"
    )
    static let vocabFile = MangaOCRModelFile(
        fileName: "vocab.txt",
        url: URL(string: "https://huggingface.co/mayocream/manga-ocr-onnx/resolve/24b12778d85800835e2ca409236de281b8ab7b9f/vocab.txt")!,
        expectedBytes: 30_216,
        sha256: "5cb5c5586d98a2f331d9f8828e4586479b0611bfba5d8c3b6dadffc84d6a36a3"
    )
    static let lineDetectorFile = MangaOCRModelFile(
        fileName: "ppocrv6_small_det.onnx",
        url: URL(string: "https://huggingface.co/PaddlePaddle/PP-OCRv6_small_det_onnx/resolve/28fe5895c24fd108c19eb3e8479f4ab385fbfc62/inference.onnx")!,
        expectedBytes: 9_880_512,
        sha256: "d73e0058b7a8086bbd57f3d10b8bcd4ff95363f67e06e2762b5e814fe9c9410e"
    )
    static let lineRecognizerFile = MangaOCRModelFile(
        fileName: "ppocrv6_small_rec.onnx",
        url: URL(string: "https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/resolve/b8f84f0b80c529de40b4fbb3544b84fa7233a513/inference.onnx")!,
        expectedBytes: 21_159_378,
        sha256: "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634"
    )
    static let lineDictionaryFile = MangaOCRModelFile(
        fileName: "ppocrv6_small_rec.yml",
        url: URL(string: "https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx/resolve/b8f84f0b80c529de40b4fbb3544b84fa7233a513/inference.yml")!,
        expectedBytes: 150_579,
        sha256: "ab078671bb49f06228eadccd34f1bb501e157f7a047095ffb943ba81512c77d1"
    )
    /// Kellenok/PP-OCRv6_manga rec v0.2 (Apache-2.0; fine-tuned on Manga109-s
    /// and AnimeText). Same input contract and 18710-entry dictionary as the
    /// PP-OCRv6 small recognizer.
    static let mangaCTCRecognizerFile = MangaOCRModelFile(
        fileName: "kellenok_manga_rec_v0.2.onnx",
        url: URL(string: "https://huggingface.co/Kellenok/PP-OCRv6_manga/resolve/ba1d479e8a61a20e8318c9758c73fbbbd290b98d/rec/manga_rec_v0.2.onnx")!,
        expectedBytes: 21_167_540,
        sha256: "de12c84c63e62c80339e882e675983d886670dcb6f0147e1ed041afd6fa81888"
    )
    /// leoxs22/manga-panel-detector-yolo26n (Apache-2.0, trained on
    /// Manga109-s) as exported by Fushi.
    static let panelFile = MangaOCRModelFile(
        fileName: "manga_panel_detector_yolo26n_fp32.onnx",
        url: URL(string: "https://github.com/hajisensai/Fushi/releases/download/manga-panel-detector-onnx-v1/manga_panel_detector_yolo26n_fp32.onnx")!,
        expectedBytes: 9_779_394,
        sha256: "6a2143c6130c358e390a8d425c51b22589fd43d4647485e2c011a553b73aaaed"
    )

    var files: [MangaOCRModelFile] {
        switch self {
        case .mangaCTC:
            [Self.detectorFile, Self.lineDetectorFile, Self.lineDictionaryFile, Self.mangaCTCRecognizerFile]
        case .mangaOCR:
            [Self.detectorFile, Self.encoderFile, Self.crossKVFile, Self.decoderKVFile, Self.vocabFile,
             Self.lineDetectorFile, Self.lineRecognizerFile, Self.lineDictionaryFile]
        case .textDetector:
            [Self.detectorFile]
        case .panelDetector:
            [Self.panelFile]
        }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.expectedBytes } }
}

nonisolated struct MangaOCRModelSetStatus: Sendable, Equatable {
    let set: MangaOCRModelSet
    let installedBytes: Int64
    let totalBytes: Int64
    let isReady: Bool
}

nonisolated enum MangaOCRModelError: LocalizedError, Equatable {
    case downloadFailed
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            String(localized: "The OCR model download failed. Check your internet connection and try again.")
        case .verificationFailed(let detail):
            String(
                format: String(localized: "The downloaded OCR model could not be verified (%@)."),
                detail
            )
        }
    }
}

/// App-global store for downloaded OCR / panel models.
///
/// Files are downloaded from pinned revisions, length- and SHA-256-verified,
/// then atomically renamed into place. Shared files (the text detector) are
/// stored once and counted by every set that needs them.
actor MangaOCRModelStore {
    static let shared = MangaOCRModelStore()

    nonisolated let directory: URL
    private let fileManager: FileManager
    private let session: URLSession

    init(directory: URL? = nil, fileManager: FileManager = .default, session: URLSession? = nil) {
        self.fileManager = fileManager
        self.directory = directory ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Niratan", isDirectory: true)
            .appendingPathComponent("MangaOCRModels", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    nonisolated func url(for file: MangaOCRModelFile) -> URL {
        directory.appendingPathComponent(file.fileName)
    }

    func status(for set: MangaOCRModelSet) -> MangaOCRModelSetStatus {
        var installed: Int64 = 0
        var ready = true
        for file in set.files {
            let size = fileSize(url(for: file))
            if size == file.expectedBytes {
                installed += size
            } else {
                ready = false
            }
        }
        return MangaOCRModelSetStatus(set: set, installedBytes: installed, totalBytes: set.totalBytes, isReady: ready)
    }

    func isReady(_ set: MangaOCRModelSet) -> Bool {
        status(for: set).isReady
    }

    /// Download every missing file of `set`. Progress is reported as a 0…1
    /// fraction of the set's total bytes, including already-installed files.
    func download(_ set: MangaOCRModelSet, progress: @escaping @Sendable (Double) -> Void) async throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = Double(set.totalBytes)
        var completed: Int64 = 0
        for file in set.files {
            try Task.checkCancellation()
            let destination = url(for: file)
            if fileSize(destination) == file.expectedBytes {
                completed += file.expectedBytes
                progress(Double(completed) / total)
                continue
            }
            let base = completed
            try await downloadFile(file, to: destination) { written in
                progress(min(1, Double(base + written) / total))
            }
            completed += file.expectedBytes
            progress(Double(completed) / total)
        }
    }

    /// Remove the set's files that no other installed set still needs.
    func delete(_ set: MangaOCRModelSet) throws {
        let retained = Set(MangaOCRModelSet.allCases
            .filter { $0 != set && status(for: $0).isReady }
            .flatMap { $0.files.map(\.fileName) })
        for file in set.files where !retained.contains(file.fileName) {
            let target = url(for: file)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try? fileManager.removeItem(at: target.appendingPathExtension("part"))
        }
    }

    /// Short identity of the pinned model files, for OCR cache signatures.
    nonisolated func fingerprint(for set: MangaOCRModelSet) -> String {
        let joined = set.files.map { "\($0.fileName):\($0.sha256)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return -1 }
        return size.int64Value
    }

    private func downloadFile(
        _ file: MangaOCRModelFile,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("part")
        try? fileManager.removeItem(at: partial)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(
                from: file.url,
                delegate: MangaOCRDownloadProgressDelegate(progress: progress)
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MangaOCRModelError.downloadFailed
        }
        defer { try? fileManager.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MangaOCRModelError.downloadFailed
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: temporary, to: partial)
        let written = fileSize(partial)
        let digest = Self.sha256(of: partial)
        guard written == file.expectedBytes, digest == file.sha256 else {
            try? fileManager.removeItem(at: partial)
            throw MangaOCRModelError.verificationFailed(
                "\(file.fileName), \(written) bytes, \(digest?.prefix(12) ?? "unreadable")"
            )
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
        progress(written)
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `read(upToCount:)` returns nil at end of file; only a thrown
            // error means the file is unreadable.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 4 << 20)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated final class MangaOCRDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
