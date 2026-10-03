import SwiftUI

/// App-global state for downloadable OCR and panel models. Downloads keep
/// running when the settings panel or the reader closes.
@Observable
@MainActor
final class MangaOCRModelManager {
    static let shared = MangaOCRModelManager()

    private(set) var statuses: [MangaOCRModelSet: MangaOCRModelSetStatus] = [:]
    private(set) var progress: [MangaOCRModelSet: Double] = [:]
    private(set) var errors: [MangaOCRModelSet: String] = [:]
    /// Increments whenever installed models change.
    private(set) var revision = 0
    @ObservationIgnored private var tasks: [MangaOCRModelSet: Task<Void, Never>] = [:]
    @ObservationIgnored private let store: MangaOCRModelStore

    init(store: MangaOCRModelStore = .shared) {
        self.store = store
    }

    func refresh() async {
        var next: [MangaOCRModelSet: MangaOCRModelSetStatus] = [:]
        for set in MangaOCRModelSet.allCases {
            next[set] = await store.status(for: set)
        }
        statuses = next
    }

    func isDownloading(_ set: MangaOCRModelSet) -> Bool {
        tasks[set] != nil
    }

    func download(_ set: MangaOCRModelSet) {
        guard tasks[set] == nil else { return }
        errors[set] = nil
        progress[set] = 0
        let store = store
        tasks[set] = Task {
            do {
                try await store.download(set) { value in
                    Task { @MainActor in
                        MangaOCRModelManager.shared.progress[set] = value
                    }
                }
            } catch is CancellationError {
            } catch {
                errors[set] = error.localizedDescription
            }
            tasks[set] = nil
            progress[set] = nil
            await refresh()
            revision += 1
        }
    }

    func cancel(_ set: MangaOCRModelSet) {
        tasks[set]?.cancel()
    }

    func delete(_ set: MangaOCRModelSet) {
        Task {
            await MangaLocalOCREngine.shared.unload()
            await MangaPanelDetector.shared.unload()
            do {
                try await store.delete(set)
            } catch {
                errors[set] = error.localizedDescription
            }
            await refresh()
            revision += 1
        }
    }
}

/// OCR tab of the reader settings panel.
struct MangaReaderOCRSettingsSection: View {
    @Bindable var viewModel: MangaReaderViewModel
    let panel: MangaReaderSettingsPanel
    @State private var showsRerunConfirmation = false

    var body: some View {
        Section("Recognition") {
            panel.row("ocrTrigger") {
                Picker("Recognize Pages", selection: panel.binding(\.ocrTrigger)) {
                    ForEach(MangaOCRTrigger.allCases) { trigger in
                        Text(LocalizedStringKey(trigger.titleKey)).tag(trigger)
                    }
                }
            }
            panel.row("ocrEngine") {
                Picker("Engine", selection: panel.binding(\.ocrEngine)) {
                    ForEach(MangaOCREngineChoice.allCases) { engine in
                        Text(LocalizedStringKey(engine.titleKey)).tag(engine)
                    }
                }
            }
            if let selection = viewModel.ocrEngine {
                LabeledContent("Current Engine") {
                    Text(LocalizedStringKey(selection.engine.titleKey))
                }
            }
            Text(engineDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Re-run OCR on This Manga…") {
                showsRerunConfirmation = true
            }
            .disabled(viewModel.ocrEngine?.isAvailable != true)
        }
        .confirmationDialog(
            "Re-run OCR on This Manga?",
            isPresented: $showsRerunConfirmation
        ) {
            Button("Re-run OCR") {
                viewModel.rerunOCR()
            }
        } message: {
            Text("Pages recognized by the current engine are recognized again. Embedded Mokuro text is not affected.")
        }

        Section("On-Device Models") {
            MangaOCRModelRow(
                set: .mangaCTC,
                titleKey: "Manga CTC (Fast)",
                detailKey: "Fushi's manga-tuned CTC recognizer. Fast and accurate for vertical and horizontal text."
            )
            MangaOCRModelRow(
                set: .mangaOCR,
                titleKey: "manga-ocr",
                detailKey: "The classic manga-ocr model. Larger and slower; reads whole speech bubbles."
            )
            MangaOCRModelRow(
                set: .textDetector,
                titleKey: "Text Detector for Apple Vision",
                detailKey: "Lets Apple Vision read each speech bubble separately for better accuracy."
            )
            Text("Models are downloaded once from their pinned public sources and verified before use. Page images never leave this Mac with on-device engines.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Text Regions") {
            panel.row("showsOCRBoxes") {
                Toggle("Show Recognized Text Regions", isOn: panel.binding(\.showsOCRBoxes))
            }
            panel.row("looksUpOnHover") {
                Toggle("Look Up on Hover", isOn: panel.binding(\.looksUpOnHover))
            }
            Text("Hold Shift while hovering to look up text at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var engineDescription: LocalizedStringKey {
        switch viewModel.settings.ocrEngine {
        case .automatic:
            "Uses a downloaded on-device model when available, otherwise Apple Vision. Never uploads pages."
        case .mangaCTC, .mangaOCR:
            "Recognizes text on this Mac with the downloaded model."
        case .appleVision:
            "Recognizes text on this Mac with Apple Vision. No download is required."
        case .googleLens:
            "Sends a reduced copy of each page to Google. Requires an internet connection and your confirmation."
        }
    }
}

/// Panel-by-panel navigation settings.
struct MangaPanelNavigationSettingsSection: View {
    @Bindable var viewModel: MangaReaderViewModel
    let panel: MangaReaderSettingsPanel

    var body: some View {
        Section("Panel Navigation") {
            panel.row("panelNavigation") {
                Toggle("Panel-by-Panel Navigation", isOn: panel.binding(\.panelNavigation))
            }
            MangaOCRModelRow(
                set: .panelDetector,
                titleKey: "Panel Detection Model",
                detailKey: "Trained on the Manga109-s dataset (Matsui et al. 2017; Aizawa et al. 2020)."
            )
        }
    }
}

private struct MangaOCRModelRow: View {
    let set: MangaOCRModelSet
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    @State private var manager = MangaOCRModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleKey)
                    Text(sizeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if manager.isDownloading(set) {
                    Button("Cancel") {
                        manager.cancel(set)
                    }
                } else if status?.isReady == true {
                    Button("Delete", role: .destructive) {
                        manager.delete(set)
                    }
                } else {
                    Button("Download") {
                        manager.download(set)
                    }
                }
            }
            if let progress = manager.progress[set] {
                ProgressView(value: progress)
            }
            Text(detailKey)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = manager.errors[set] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            await manager.refresh()
        }
    }

    private var status: MangaOCRModelSetStatus? {
        manager.statuses[set]
    }

    private var sizeDescription: String {
        let total = ByteCountFormatter.string(fromByteCount: set.totalBytes, countStyle: .file)
        if status?.isReady == true {
            return String(format: String(localized: "Installed · %@"), total)
        }
        return String(format: String(localized: "Not downloaded · %@"), total)
    }
}
