//
//  XboxControllerManager.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GameController

extension ShortcutAction {
    var defaultControllerBinding: XboxControllerBinding? {
        switch id {
        case ReaderShortcutActions.previousPage.id:
            .dpadLeft
        case ReaderShortcutActions.nextPage.id:
            .dpadRight
        case SasayakiShortcutActions.previousCue.id:
            .leftShoulder
        case SasayakiShortcutActions.playPause.id:
            .buttonA
        case SasayakiShortcutActions.nextCue.id:
            .rightShoulder
        case SasayakiShortcutActions.replayCue.id:
            .buttonX
        case SasayakiShortcutActions.jumpCue.id:
            .buttonB
        case ReaderShortcutActions.toggleStatistics.id:
            .buttonY
        // Fushi's manga gamepad defaults: D-pad follows the reading
        // direction, shoulders turn pages, Y toggles the interface, B backs out.
        case MangaShortcutActions.pageLeft.id:
            .dpadLeft
        case MangaShortcutActions.pageRight.id:
            .dpadRight
        case MangaShortcutActions.previousPage.id:
            .leftShoulder
        case MangaShortcutActions.nextPage.id:
            .rightShoulder
        case MangaShortcutActions.toggleInterface.id:
            .buttonY
        case MangaShortcutActions.back.id:
            .buttonB
        default:
            nil
        }
    }
}

enum GameControllerFamily {
    case xbox
    case playStation
    case nintendo
    case generic
}

@MainActor
@Observable
final class XboxControllerManager {
    static let shared = XboxControllerManager()

    private(set) var isConnected = false
    private(set) var connectedControllerName: String?
    private(set) var controllerFamily: GameControllerFamily = .generic
    var recordingAction: ShortcutAction?

    private let registry = ShortcutRegistry.application
    private var userConfig: UserConfig?
    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    private var lastPressTimes: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 0.18

    private init() {}

    func configure(userConfig: UserConfig) {
        self.userConfig = userConfig
        start()
    }

    func startRecording(for action: ShortcutAction) {
        recordingAction = action
        start()
    }

    func cancelRecording() {
        recordingAction = nil
    }

    func resetBinding(for action: ShortcutAction, userConfig: UserConfig) {
        userConfig.resetControllerBinding(for: action)
    }

    func label(for binding: XboxControllerBinding) -> String {
        switch controllerFamily {
        case .xbox:
            xboxLabel(for: binding.input)
        case .playStation:
            playStationLabel(for: binding.input)
        case .nintendo:
            nintendoLabel(for: binding.input)
        case .generic:
            binding.label
        }
    }

    private func start() {
        guard !isStarted else {
            refreshConnectedControllers()
            return
        }

        isStarted = true
        observeControllerConnections()
        refreshConnectedControllers()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    private func observeControllerConnections() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object is GCController else { return }
            Task { @MainActor in
                self?.refreshConnectedControllers()
            }
        })

        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConnectedControllers()
            }
        })
    }

    private func refreshConnectedControllers() {
        GCController.controllers().forEach(configure)
        let controller = GCController.controllers().first
        isConnected = controller != nil
        connectedControllerName = controller?.vendorName
        controllerFamily = controller.map(detectFamily) ?? .generic
    }

    private func configure(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        bind(gamepad.buttonA, to: "buttonA")
        bind(gamepad.buttonB, to: "buttonB")
        bind(gamepad.buttonX, to: "buttonX")
        bind(gamepad.buttonY, to: "buttonY")
        bind(gamepad.leftShoulder, to: "leftShoulder")
        bind(gamepad.rightShoulder, to: "rightShoulder")
        bind(gamepad.leftTrigger, to: "leftTrigger")
        bind(gamepad.rightTrigger, to: "rightTrigger")
        bind(gamepad.buttonMenu, to: "buttonMenu")
        bindIfAvailable(gamepad.buttonOptions, to: "buttonOptions")
        bindIfAvailable(gamepad.buttonHome, to: "buttonHome")
        bindIfAvailable(gamepad.leftThumbstickButton, to: "leftThumbstickButton")
        bindIfAvailable(gamepad.rightThumbstickButton, to: "rightThumbstickButton")
        if let xboxGamepad = controller.physicalInputProfile as? GCXboxGamepad {
            bindIfAvailable(xboxGamepad.buttonShare, to: "buttonShare")
            bindIfAvailable(xboxGamepad.paddleButton1, to: "xboxPaddle1")
            bindIfAvailable(xboxGamepad.paddleButton2, to: "xboxPaddle2")
            bindIfAvailable(xboxGamepad.paddleButton3, to: "xboxPaddle3")
            bindIfAvailable(xboxGamepad.paddleButton4, to: "xboxPaddle4")
        }
        if let dualShockGamepad = controller.physicalInputProfile as? GCDualShockGamepad {
            bind(dualShockGamepad.touchpadButton, to: "playStationTouchpad")
        }
        if let dualSenseGamepad = controller.physicalInputProfile as? GCDualSenseGamepad {
            bind(dualSenseGamepad.touchpadButton, to: "playStationTouchpad")
        }

        bind(gamepad.dpad.up, to: "dpadUp")
        bind(gamepad.dpad.down, to: "dpadDown")
        bind(gamepad.dpad.left, to: "dpadLeft")
        bind(gamepad.dpad.right, to: "dpadRight")

        bind(gamepad.leftThumbstick.up, to: "leftThumbstickUp")
        bind(gamepad.leftThumbstick.down, to: "leftThumbstickDown")
        bind(gamepad.leftThumbstick.left, to: "leftThumbstickLeft")
        bind(gamepad.leftThumbstick.right, to: "leftThumbstickRight")

        bind(gamepad.rightThumbstick.up, to: "rightThumbstickUp")
        bind(gamepad.rightThumbstick.down, to: "rightThumbstickDown")
        bind(gamepad.rightThumbstick.left, to: "rightThumbstickLeft")
        bind(gamepad.rightThumbstick.right, to: "rightThumbstickRight")
    }

    private func bind(_ button: GCControllerButtonInput, to input: String) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in
                self?.handle(input: input)
            }
        }
    }

    private func bindIfAvailable(_ button: GCControllerButtonInput?, to input: String) {
        guard let button else { return }
        bind(button, to: input)
    }

    private func handle(input: String) {
        let now = Date()
        if let lastPressTime = lastPressTimes[input],
           now.timeIntervalSince(lastPressTime) < debounceInterval {
            return
        }
        lastPressTimes[input] = now

        if let recordingAction, let userConfig {
            userConfig.setControllerBinding(
                XboxControllerBinding(input: input),
                for: recordingAction
            )
            self.recordingAction = nil
            return
        }

        guard let userConfig else {
            return
        }
        let actionIDs = registry.actions.compactMap { action in
            userConfig.controllerBinding(for: action)?.input == input ? action.id : nil
        }
        _ = ShortcutManager.dispatchActionIDs(actionIDs)
    }

    private func detectFamily(for controller: GCController) -> GameControllerFamily {
        if controller.physicalInputProfile is GCXboxGamepad {
            return .xbox
        }
        if controller.physicalInputProfile is GCDualShockGamepad || controller.physicalInputProfile is GCDualSenseGamepad {
            return .playStation
        }

        let vendorName = controller.vendorName?.lowercased() ?? ""
        if vendorName.contains("xbox") {
            return .xbox
        }
        if vendorName.contains("playstation") || vendorName.contains("dualshock") || vendorName.contains("dualsense") || vendorName.contains("sony") {
            return .playStation
        }
        if vendorName.contains("switch") || vendorName.contains("nintendo") || vendorName.contains("joy-con") || vendorName.contains("pro controller") {
            return .nintendo
        }
        return .generic
    }

    private func xboxLabel(for input: String) -> String {
        switch input {
        case "buttonA": "A"
        case "buttonB": "B"
        case "buttonX": "X"
        case "buttonY": "Y"
        case "leftShoulder": "LB"
        case "rightShoulder": "RB"
        case "leftTrigger": "LT"
        case "rightTrigger": "RT"
        case "buttonOptions": String(localized: "View")
        case "buttonMenu": String(localized: "Menu")
        case "buttonHome": "Xbox"
        case "buttonShare": String(localized: "Share")
        case "xboxPaddle1": String(localized: "Paddle 1")
        case "xboxPaddle2": String(localized: "Paddle 2")
        case "xboxPaddle3": String(localized: "Paddle 3")
        case "xboxPaddle4": String(localized: "Paddle 4")
        default: XboxControllerBinding(input: input).label
        }
    }

    private func playStationLabel(for input: String) -> String {
        switch input {
        case "buttonA": String(localized: "Cross")
        case "buttonB": String(localized: "Circle")
        case "buttonX": String(localized: "Square")
        case "buttonY": String(localized: "Triangle")
        case "leftShoulder": "L1"
        case "rightShoulder": "R1"
        case "leftTrigger": "L2"
        case "rightTrigger": "R2"
        case "leftThumbstickButton": "L3"
        case "rightThumbstickButton": "R3"
        case "buttonOptions": String(localized: "Share/Create")
        case "buttonMenu": "Options"
        case "buttonHome": "PS"
        case "buttonShare": "Create"
        case "playStationTouchpad": String(localized: "Touchpad")
        default: XboxControllerBinding(input: input).label
        }
    }

    private func nintendoLabel(for input: String) -> String {
        switch input {
        case "buttonA": "B"
        case "buttonB": "A"
        case "buttonX": "Y"
        case "buttonY": "X"
        case "leftShoulder": "L"
        case "rightShoulder": "R"
        case "leftTrigger": "ZL"
        case "rightTrigger": "ZR"
        case "buttonOptions": "-"
        case "buttonMenu": "+"
        case "buttonHome": "Home"
        case "buttonShare": String(localized: "Capture")
        default: XboxControllerBinding(input: input).label
        }
    }
}
