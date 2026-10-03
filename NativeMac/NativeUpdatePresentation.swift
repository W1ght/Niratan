import SwiftUI

/// Runs the background GitHub release checks for the main window and presents
/// their results: an alert when a newer release is found and the download overlay.
/// Manual checks live in Settings > About and report their result inline there.
private struct NativeUpdatePresentation: ViewModifier {
    @State private var updateChecker = UpdateChecker.shared

    func body(content: Content) -> some View {
        content
            .task {
                await updateChecker.runAutomaticChecks()
            }
            .alert(alertTitle, isPresented: alertBinding) {
                if case .available = updateChecker.alert {
                    Button("Download and Install") {
                        Task {
                            await updateChecker.downloadAndOpenAvailableUpdate()
                        }
                    }
                    Button("Later", role: .cancel) { }
                } else {
                    Button("OK", role: .cancel) { }
                }
            } message: {
                Text(alertMessage)
            }
            .overlay {
                if updateChecker.isDownloading {
                    LoadingOverlay(updateChecker.downloadStatusText)
                }
            }
    }

    private var alertBinding: Binding<Bool> {
        Binding {
            updateChecker.alert != nil
        } set: { isPresented in
            if !isPresented {
                updateChecker.alert = nil
            }
        }
    }

    private var alertTitle: String {
        switch updateChecker.alert {
        case .available:
            String(localized: "Update Available")
        case .upToDate:
            String(localized: "You're Up to Date")
        case .failed:
            String(localized: "Update Check Failed")
        case .downloadFailed:
            String(localized: "Update Download Failed")
        case nil:
            ""
        }
    }

    private var alertMessage: String {
        switch updateChecker.alert {
        case .available(let release, let currentVersion):
            String(
                format: String(localized: "Version %@ is available. You are using %@."),
                release.version,
                currentVersion
            )
        case .upToDate(let currentVersion):
            String(
                format: String(localized: "Niratan %@ is the latest version."),
                currentVersion
            )
        case .failed:
            String(localized: "Unable to check for updates. Please try again later.")
        case .downloadFailed:
            String(localized: "Unable to download or verify the update. Please try again later.")
        case nil:
            ""
        }
    }
}

extension View {
    func nativeUpdatePresentation() -> some View {
        modifier(NativeUpdatePresentation())
    }
}
