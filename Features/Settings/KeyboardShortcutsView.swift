//
//  KeyboardShortcutsView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(SelectionLookupCoordinator.self) private var selectionLookupCoordinator
    @State private var recording: ShortcutAction?

    private let registry = ShortcutRegistry.application

    var body: some View {
        NativeSettingsForm {
            ForEach(visibleCategories) { category in
                let actions = registry.actions(in: category)
                NativeSettingsSectionCard {
                    Text(LocalizedStringKey(category.titleKey))
                } content: {
                    if category == .global {
                        selectionLookupSettings
                        NativeSettingsSeparator()
                    }

                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 {
                            NativeSettingsSeparator()
                        }
                        ShortcutRecorderRow(
                            action: action,
                            shortcut: userConfig.shortcutBinding(for: action),
                            conflictStatus: conflictStatus(for: action),
                            isRecording: recording == action,
                            onRecord: {
                                recording = action
                            },
                            onReset: {
                                userConfig.resetShortcutBinding(for: action)
                                if action.id == GlobalShortcutActions.lookupSelectedText.id {
                                    selectionLookupCoordinator.refresh()
                                }
                            }
                        )
                    }

                    if category == .dictionaryPopup {
                        NativeSettingsSeparator()
                        @Bindable var userConfig = userConfig
                        NativeSettingsRow("Entry Jump Count") {
                            Text(verbatim: "\(userConfig.dictionaryEntryJumpCount)")
                                .foregroundStyle(.secondary)
                            Stepper("", value: $userConfig.dictionaryEntryJumpCount, in: 1...10)
                                .labelsHidden()
                        }
                    }
                } footer: {
                    if category == .global {
                        Text("Shortcuts can reuse the same key when their scopes do not overlap.")
                    }
                }
            }
        }
        .navigationTitle("Keyboard Shortcuts")
        .overlay {
            if recording != nil {
                ShortcutKeyCaptureView(
                    onCapture: assign,
                    onCancel: {
                        recording = nil
                    }
                )
                .frame(width: 0, height: 0)
            }
        }
    }

    private var visibleCategories: [ShortcutCategory] {
        ShortcutCategory.allCases.filter {
            !registry.actions(in: $0).isEmpty
        }
    }

    private func assign(_ shortcut: KeyboardShortcutBinding) {
        guard let recording else { return }
        userConfig.setShortcutBinding(shortcut, for: recording)
        if recording.id == GlobalShortcutActions.lookupSelectedText.id {
            selectionLookupCoordinator.refresh()
        }
        self.recording = nil
    }

    private var selectionLookupSettings: some View {
        NativeSettingsRow("Cross-App Selection Lookup (Experimental)") {
            Text(selectionLookupStatusTitle)
                .font(.callout)
                .foregroundStyle(selectionLookupStatusColor)

            if selectionLookupCoordinator.availability == .permissionRequired {
                Button("Request Access") {
                    selectionLookupCoordinator.requestAccess()
                }
                .buttonStyle(NativeSettingsActionButtonStyle())
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { userConfig.crossAppSelectionLookupEnabled },
                    set: { selectionLookupCoordinator.setEnabled($0) }
                )
            )
            .labelsHidden()
        }
    }

    private var selectionLookupStatusTitle: LocalizedStringKey {
        switch selectionLookupCoordinator.availability {
        case .disabled: "Off"
        case .permissionRequired: "Accessibility Permission Required"
        case .registered: "Ready"
        case .shortcutConflict: "Shortcut Already in Use"
        case .unsupportedShortcut: "Unsupported Shortcut"
        case .registrationFailed: "Shortcut Registration Failed"
        }
    }

    private var selectionLookupStatusColor: Color {
        switch selectionLookupCoordinator.availability {
        case .registered: .green
        case .permissionRequired, .shortcutConflict, .unsupportedShortcut, .registrationFailed: .orange
        case .disabled: .secondary
        }
    }

    private func conflictStatus(for action: ShortcutAction) -> ShortcutRowConflictStatus {
        let binding = userConfig.shortcutBinding(for: action)
        var isShadowed = false

        for other in registry.actions where other.id != action.id {
            let relationship = ShortcutConflictChecker.relationship(
                between: action,
                binding: binding,
                and: other,
                binding: userConfig.shortcutBinding(for: other)
            )
            switch relationship {
            case .conflict:
                return .conflict
            case .shadowed:
                isShadowed = true
            case .none:
                break
            }
        }
        return isShadowed ? .shadowed : .none
    }
}

private enum ShortcutRowConflictStatus {
    case none
    case shadowed
    case conflict
}

private struct ShortcutRecorderRow: View {
    let action: ShortcutAction
    let shortcut: KeyboardShortcutBinding
    let conflictStatus: ShortcutRowConflictStatus
    let isRecording: Bool
    let onRecord: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(action.titleKey))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text("Default Shortcut: \(action.defaultBinding.label)")
                    conflictLabel
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset")
            .disabled(shortcut == action.defaultBinding)

            Button(action: onRecord) {
                NativeSettingsValuePill {
                    if isRecording {
                        Text("Press keys...")
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(shortcut.label)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var conflictLabel: some View {
        switch conflictStatus {
        case .none:
            EmptyView()
        case .shadowed:
            Label("Context Priority", systemImage: "square.stack.3d.up")
                .foregroundStyle(.secondary)
        case .conflict:
            Label("Shortcut Conflict", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
