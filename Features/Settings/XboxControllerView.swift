//
//  XboxControllerView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct XboxControllerView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var controllerManager = XboxControllerManager.shared

    private let registry = ShortcutRegistry.application

    var body: some View {
        NativeSettingsForm {
            NativeSettingsSectionCard {
                Text("Controller")
            } content: {
                NativeSettingsRow {
                    Label("Controller", systemImage: "gamecontroller")
                } accessory: {
                    Text(controllerManager.connectedControllerName ?? String(localized: "Not Connected"))
                        .foregroundStyle(controllerManager.isConnected ? .secondary : .tertiary)
                }

                if let recordingAction = controllerManager.recordingAction {
                    NativeSettingsSeparator()
                    NativeSettingsButtonRow {
                        Button(role: .cancel) {
                            controllerManager.cancelRecording()
                        } label: {
                            Label("Waiting for controller input...", systemImage: "record.circle")
                        }
                        Text(LocalizedStringKey(recordingAction.titleKey))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Choose an action, then press a button or direction on an Xbox, PlayStation, Switch, or compatible controller.")
            }

            ForEach(visibleCategories) { category in
                let actions = registry.actions(in: category)
                NativeSettingsSectionCard {
                    Text(LocalizedStringKey(category.titleKey))
                } content: {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 {
                            NativeSettingsSeparator()
                        }
                        let binding = userConfig.controllerBinding(for: action)
                        XboxControllerRecorderRow(
                            binding: binding,
                            displayLabel: binding.map(controllerManager.label) ?? String(localized: "None"),
                            defaultLabel: action.defaultControllerBinding.map(controllerManager.label) ?? String(localized: "None"),
                            action: action,
                            recording: controllerManager.recordingAction,
                            conflictStatus: conflictStatus(for: action),
                            onRecord: controllerManager.startRecording,
                            onReset: resetBinding
                        )
                    }
                } footer: {
                    if category == .global {
                        Text("Controller inputs can be reused when their scopes do not overlap.")
                    }
                }
            }
        }
        .navigationTitle("Game Controller")
        .onAppear {
            controllerManager.configure(userConfig: userConfig)
        }
    }

    private var visibleCategories: [ShortcutCategory] {
        ShortcutCategory.allCases.filter {
            !registry.actions(in: $0).isEmpty
        }
    }

    private func conflictStatus(for action: ShortcutAction) -> ControllerRowConflictStatus {
        let binding = userConfig.controllerBinding(for: action)
        var isShadowed = false

        for other in registry.actions where other.id != action.id {
            let otherBinding = userConfig.controllerBinding(for: other)
            let relationship = ShortcutConflictChecker.relationship(
                between: action,
                and: other,
                bindingsMatch: binding != nil && binding == otherBinding
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

    private func resetBinding(_ action: ShortcutAction) {
        controllerManager.resetBinding(for: action, userConfig: userConfig)
    }
}

private enum ControllerRowConflictStatus {
    case none
    case shadowed
    case conflict
}

private struct XboxControllerRecorderRow: View {
    let binding: XboxControllerBinding?
    let displayLabel: String
    let defaultLabel: String
    let action: ShortcutAction
    let recording: ShortcutAction?
    let conflictStatus: ControllerRowConflictStatus
    let onRecord: (ShortcutAction) -> Void
    let onReset: (ShortcutAction) -> Void

    private var isRecording: Bool {
        recording == action
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(action.titleKey))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text("Default Controller: \(defaultLabel)")
                    conflictLabel
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onReset(action)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset")
            .disabled(binding == action.defaultControllerBinding)

            Button {
                onRecord(action)
            } label: {
                NativeSettingsValuePill {
                    Text(isRecording ? String(localized: "Press controller...") : displayLabel)
                        .foregroundStyle(isRecording ? Color.accentColor : .secondary)
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
            Label("Controller Conflict", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
