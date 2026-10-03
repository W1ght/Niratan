import Foundation
import Synchronization

/// Receives playback progress for remote sources whose provider tracks it
/// server-side, such as media servers.
@MainActor
protocol RemotePlaybackReporting: AnyObject {
    func playbackDidUpdate(position: TimeInterval, duration: TimeInterval, isPlaying: Bool)
    func playbackDidStop(position: TimeInterval, duration: TimeInterval)
}

/// Feature modules register reporter factories at launch so the player model
/// stays independent of them.
nonisolated enum RemotePlaybackReporterCatalog {
    typealias Factory = @MainActor @Sendable (ResolvedRemoteVideoSource) -> (any RemotePlaybackReporting)?

    private static let factories = Mutex<[Factory]>([])

    static func register(_ factory: @escaping Factory) {
        factories.withLock { $0.append(factory) }
    }

    @MainActor
    static func makeReporter(for source: ResolvedRemoteVideoSource) -> (any RemotePlaybackReporting)? {
        for factory in factories.withLock({ $0 }) {
            if let reporter = factory(source) {
                return reporter
            }
        }
        return nil
    }
}

nonisolated struct RemotePlaybackAttempt: Equatable, Sendable {
    let source: ResolvedRemoteVideoSource
    let generation: Int
    let resumeTime: TimeInterval
}

nonisolated enum RemotePlaybackPreparation: Equatable, Sendable {
    case play(RemotePlaybackAttempt)
    case terminal(RemotePlaybackFailure)
    case ignored
}

nonisolated enum RemotePlaybackRecovery: Equatable, Sendable {
    case retry(RemotePlaybackAttempt)
    case terminal(RemotePlaybackFailure)
    case ignored
}

typealias RemotePlaybackResolving = @Sendable (
    _ identity: RemoteVideoIdentity,
    _ preferredSubtitleLanguages: [String],
    _ forceRefresh: Bool
) async throws -> ResolvedRemoteVideoSource

actor RemotePlaybackSession {
    let identity: RemoteVideoIdentity
    let preferredSubtitleLanguages: [String]

    private let resolver: RemotePlaybackResolving
    private let preferredQualityHeight: Int?
    private var currentSource: ResolvedRemoteVideoSource
    private var generation = 1
    private var refreshUsed = false
    private var fallbackUsed = false
    private var resumeTime: TimeInterval = 0

    init(
        source: ResolvedRemoteVideoSource,
        preferredSubtitleLanguages: [String] = [],
        resolver: @escaping RemotePlaybackResolving
    ) {
        identity = source.identity
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        currentSource = source
        preferredQualityHeight = source.playbackStream.height
        self.resolver = resolver
    }

    func prepare(now: Date = Date()) async -> RemotePlaybackPreparation {
        guard currentSource.isExpired(now: now) else {
            return .play(currentAttempt())
        }
        guard !refreshUsed else {
            return .terminal(.sourceUnavailable)
        }
        let guardedGeneration = generation
        refreshUsed = true
        do {
            let source = try await resolver(identity, preferredSubtitleLanguages, true)
            guard generation == guardedGeneration else { return .ignored }
            install(source)
            return .play(currentAttempt())
        } catch {
            guard generation == guardedGeneration else { return .ignored }
            return .terminal(.sourceUnavailable)
        }
    }

    func recover(
        from failure: RemotePlaybackFailure,
        generation failedGeneration: Int,
        resumeTime: TimeInterval
    ) async -> RemotePlaybackRecovery {
        guard failedGeneration == generation else { return .ignored }
        self.resumeTime = max(0, resumeTime)

        switch failure {
        case .remoteLoadFailed:
            guard !refreshUsed else {
                return .terminal(.sourceUnavailable)
            }
            return await refresh(terminalFailure: .sourceUnavailable)
        case .externalAudioUnavailable:
            if !refreshUsed {
                return await refresh(terminalFailure: .audioUnavailable)
            }
            return useMuxedFallback()
        case .audioUnavailable:
            return .terminal(.audioUnavailable)
        case .sourceUnavailable:
            return .terminal(.sourceUnavailable)
        }
    }

    private func refresh(
        terminalFailure: RemotePlaybackFailure
    ) async -> RemotePlaybackRecovery {
        let guardedGeneration = generation
        refreshUsed = true
        do {
            let source = try await resolver(identity, preferredSubtitleLanguages, true)
            guard generation == guardedGeneration else { return .ignored }
            install(source)
            return .retry(currentAttempt())
        } catch {
            guard generation == guardedGeneration else { return .ignored }
            return .terminal(terminalFailure)
        }
    }

    private func useMuxedFallback() -> RemotePlaybackRecovery {
        guard !fallbackUsed,
              let fallback = currentSource.muxedFallbackStream else {
            return .terminal(.audioUnavailable)
        }
        fallbackUsed = true
        currentSource = ResolvedRemoteVideoSource(
            identity: currentSource.identity,
            playbackStream: fallback,
            audioStream: nil,
            muxedFallbackStream: nil,
            miningStream: currentSource.miningStream ?? fallback,
            subtitleOptions: currentSource.subtitleOptions,
            selectedSubtitleLanguage: currentSource.selectedSubtitleLanguage,
            resolvedAt: currentSource.resolvedAt,
            expiresAt: currentSource.expiresAt,
            qualityOptions: currentSource.qualityOptions,
            providerContext: currentSource.providerContext,
            resumeHint: currentSource.resumeHint
        )
        generation &+= 1
        return .retry(currentAttempt())
    }

    private func install(_ source: ResolvedRemoteVideoSource) {
        currentSource = preferredQualityHeight
            .flatMap { source.selectingQuality(height: $0) }
            ?? source
        generation &+= 1
    }

    private func currentAttempt() -> RemotePlaybackAttempt {
        RemotePlaybackAttempt(
            source: currentSource,
            generation: generation,
            resumeTime: resumeTime
        )
    }
}
