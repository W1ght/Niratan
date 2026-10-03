//
//  AnkiMining.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum AnkiMiningStatus: String {
    case added
    case duplicate
    case failed
    case pending
}

struct AnkiMiningResult {
    let status: AnkiMiningStatus
    let message: String
    let noteID: Int64?

    var webPayload: [String: String] {
        var payload = [
            "status": status.rawValue,
            "message": message
        ]
        if let noteID {
            payload["noteID"] = String(noteID)
        }
        return payload
    }

    static func added(noteID: Int64, _ message: String = String(localized: "Added to Anki.")) -> AnkiMiningResult {
        AnkiMiningResult(status: .added, message: message, noteID: noteID)
    }

    static func duplicate(
        noteID: Int64? = nil,
        _ message: String = String(localized: "Already exists in Anki.")
    ) -> AnkiMiningResult {
        AnkiMiningResult(status: .duplicate, message: message, noteID: noteID)
    }

    static func failed(_ message: String) -> AnkiMiningResult {
        AnkiMiningResult(status: .failed, message: message, noteID: nil)
    }

    static func pending(_ message: String) -> AnkiMiningResult {
        AnkiMiningResult(status: .pending, message: message, noteID: nil)
    }
}

private var activeProfileChangedMiningResult: AnkiMiningResult {
    .failed(String(localized: "The active Profile changed. Try adding the card again."))
}

@MainActor
func preflightAnkiMining(content: [String: String]) async -> AnkiMiningResult? {
    let profileID = ProfileRepository.shared.activeProfile.id
    AnkiManager.shared.activateProfile(profileID)

    guard AnkiManager.shared.selectedDeck != nil,
          AnkiManager.shared.selectedNoteType != nil else {
        return .failed(String(localized: "Configure Anki deck and model first."))
    }

    let expression = content["expression"] ?? "Entry"
    if !AnkiManager.shared.allowDupes {
        let duplicateLookup = await AnkiManager.shared.duplicateLookup(word: expression)
        guard ProfileRepository.shared.activeProfile.id == profileID,
              AnkiManager.shared.activeProfileID == profileID else {
            return activeProfileChangedMiningResult
        }
        if duplicateLookup.isDuplicate {
            return .duplicate(
                noteID: duplicateLookup.noteIDs.first,
                String(localized: "Already exists in Anki.")
            )
        }
    }

    return nil
}

@MainActor
func mineAnkiEntry(
    content: [String: String],
    context: MiningContext,
    preflightAlreadyPassed: Bool = false
) async -> AnkiMiningResult {
    var context = context
    let profileID = context.profileID ?? ProfileRepository.shared.activeProfile.id
    guard ProfileRepository.shared.activeProfile.id == profileID else {
        return activeProfileChangedMiningResult
    }
    AnkiManager.shared.activateProfile(profileID)
    context.profileID = profileID

    if !preflightAlreadyPassed {
        if let preflightResult = await preflightAnkiMining(content: content) {
            return preflightResult
        }
        guard ProfileRepository.shared.activeProfile.id == profileID,
              AnkiManager.shared.activeProfileID == profileID else {
            return activeProfileChangedMiningResult
        }
    }

    if AnkiManager.shared.needsVideoAudioClip,
       let video = context.video,
       video.audioClipURL == nil,
       video.audioClipFilename == nil {
        return .failed(
            video.audioClipErrorMessage
                ?? String(localized: "Unable to capture the subtitle audio clip.")
        )
    }

    if AnkiManager.shared.needsVideoScreenshot,
       let video = context.video,
       video.screenshotURL == nil,
       video.screenshotFilename == nil {
        return .failed(
            video.screenshotErrorMessage
                ?? String(localized: "Unable to capture the video screenshot.")
        )
    }

    if let noteID = await AnkiManager.shared.addNote(content: content, context: context) {
        return .added(noteID: noteID, String(localized: "Added to Anki."))
    }

    return .failed(AnkiManager.shared.errorMessage ?? String(localized: "Failed to add card."))
}
