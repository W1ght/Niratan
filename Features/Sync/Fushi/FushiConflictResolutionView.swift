//
//  FushiConflictResolutionView.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Asks which reading position to keep when Niratan and Fushi both moved away
/// from the last synced position. Nothing is overwritten until the user picks a
/// side; "Decide Later" leaves both positions as they are.
struct FushiConflictResolutionView: View {
    let conflicts: [FushiProgressConflict]
    /// Called after a choice was applied, so an open Reader can reload.
    var onResolved: (FushiProgressConflict, FushiConflictChoice) -> Void = { _, _ in }
    var onDismiss: () -> Void

    @State private var workingConflictID: String?
    @State private var errorMessage: String?
    private let coordinator = FushiProgressCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Reading Progress Conflict", systemImage: "arrow.triangle.branch")
                    .font(.title3.weight(.semibold))
                Text("Niratan and Fushi both moved since they last synced. Choose the position to keep; the other side is updated to match. Until you choose, neither side is changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(conflicts) { conflict in
                        conflictCard(conflict)
                    }
                }
            }
            .frame(maxHeight: 420)
            .scrollBounceBehavior(.basedOnSize)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Decide Later") {
                    coordinator.postpone(conflicts)
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(workingConflictID != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: conflicts.isEmpty) { _, isEmpty in
            if isEmpty {
                onDismiss()
            }
        }
    }

    private func conflictCard(_ conflict: FushiProgressConflict) -> some View {
        let isWorking = workingConflictID == conflict.id
        return VStack(alignment: .leading, spacing: 12) {
            Text(conflict.book.displayTitle)
                .font(.headline)
                .lineLimit(2)

            HStack(alignment: .top, spacing: 12) {
                positionColumn(
                    title: Text("This Mac"),
                    systemImage: "desktopcomputer",
                    percent: Self.percent(conflict.local.characterCount, of: conflict.totalCharacters),
                    date: conflict.local.lastModified
                )
                positionColumn(
                    title: Text(verbatim: "Fushi · \(conflict.hostName)"),
                    systemImage: "network",
                    percent: conflict.remoteAsLocal.map { Self.percent($0.characterCount, of: conflict.totalCharacters) },
                    date: Date(timeIntervalSince1970: TimeInterval(conflict.remote.updatedAtMs) / 1000)
                )
            }

            HStack(spacing: 8) {
                Button("Keep This Mac's Position") {
                    resolve(conflict, .keepLocal)
                }
                Button("Use Fushi's Position") {
                    resolve(conflict, .useFushi)
                }
                .buttonStyle(.borderedProminent)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(workingConflictID != nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func positionColumn(
        title: Text,
        systemImage: String,
        percent: Double?,
        date: Date?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                title
            } icon: {
                Image(systemName: systemImage)
            }
            .font(.subheadline.weight(.semibold))
            if let percent {
                Text("\(percent, format: .percent.precision(.fractionLength(1))) of the book")
                    .font(.callout)
            }
            if let date {
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolve(_ conflict: FushiProgressConflict, _ choice: FushiConflictChoice) {
        workingConflictID = conflict.id
        errorMessage = nil
        Task {
            defer { workingConflictID = nil }
            do {
                try await coordinator.resolve(conflict, choice: choice)
                onResolved(conflict, choice)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func percent(_ characters: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(characters) / Double(total), 0), 1)
    }
}

/// Sheet over the coordinator's pending conflicts. Reads the coordinator itself
/// so the list shrinks as the user resolves entries.
struct FushiConflictSheet: View {
    /// The bookshelf prompt skips conflicts postponed this session; Settings lists
    /// every unresolved one.
    var includePostponed: Bool
    var onDismiss: () -> Void
    private let coordinator = FushiProgressCoordinator.shared

    var body: some View {
        FushiConflictResolutionView(
            conflicts: includePostponed ? coordinator.pendingConflicts : coordinator.bookshelfConflicts,
            onDismiss: onDismiss
        )
    }
}
