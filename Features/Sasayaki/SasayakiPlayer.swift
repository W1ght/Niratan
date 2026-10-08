//
//  SasayakiPlayer.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import OSLog
import SwiftUI

private let sasayakiPersistenceLogger = Logger(subsystem: "moe.shishamo.hoshi", category: "SasayakiPersistence")

struct CueTimeline {
    private let cues: [SasayakiMatch]
    
    init(match: SasayakiMatchData? = nil) {
        cues = match?.matches ?? []
    }
    
    func nextCueMatch(after time: Double) -> SasayakiMatch? {
        var index = findCue(time)
        if index < cues.count, cues[index].startTime == time {
            index += 1
        }
        return index < cues.count ? cues[index] : nil
    }

    func nextCue(after time: Double) -> Double? {
        nextCueMatch(after: time)?.startTime
    }
    
    func prevCueMatch(before time: Double) -> SasayakiMatch? {
        let index = findCue(time)
        return index > 0 ? cues[index - 1] : nil
    }

    func prevCue(before time: Double) -> Double? {
        prevCueMatch(before: time)?.startTime
    }
    
    func cue(at time: Double) -> SasayakiMatch? {
        let index = findCue(time)
        if index < cues.count {
            let delta: Double = cues[index].startTime - time
            if delta >= -0.01 && delta <= 0.01 {
                return cues[index]
            }
        }
        if index == 0 {
            return nil
        }
        let cue = cues[index - 1]
        return time <= cue.endTime ? cue : nil
    }
    
    private func findCue(_ time: Double) -> Int {
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startTime < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

@Observable
@MainActor
class SasayakiPlayer {
    private let skipInterval: TimeInterval = 15
    private let seekLandingTolerance: TimeInterval = 0.75
    
    var errorMessage: String?
    var isRestoring = false
    
    var matchData: SasayakiMatchData?
    var timeline = CueTimeline()
    
    var playback = SasayakiPlaybackData(lastPosition: 0)
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false { didSet { updatePlaybackActivity() } }
    var audiobookMetadata = SasayakiAudiobookMetadata.empty
    var audiobookChapters: [SasayakiAudiobookChapter] = []
    var isLoadingAudiobookChapters = false
    var stopPlaybackTime: Double?
    var pendingSeekPosition: Double?
    var seekGeneration = 0
    var lastUpdate = -1
    
    var delay: Double = 0 {
        didSet {
            guard !isRestoring else { return }
            savePlayback()
            updateCue(for: currentTime)
        }
    }
    var rate: Float = 1 {
        didSet {
            guard !isRestoring else { return }
            savePlayback()
            player?.defaultRate = rate
            if isPlaying {
                player?.rate = rate
            }
        }
    }
    var autoScroll: Bool { UserDefaults.standard.object(forKey: "sasayakiAutoScroll") as? Bool ?? true }
    
    var currentCue: SasayakiMatch?
    var pendingCue: SasayakiMatch?
    var revealPendingCueOnRestore = false
    var chapterTransition = false
    var shouldResume = false
    var hasPlayedOnce = false
    var player: AVPlayer?
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var audiobookChapterLoadTask: Task<Void, Never>?
    var audiobookChapterLoadGeneration = 0
    let transcription = SasayakiTranscription()
    var audioURL: URL?
    private var miningAudioCache: [String: Data] = [:]
    var playbackActivity: NSObjectProtocol?

    var hasAudio: Bool { player != nil }
    var hasMatch: Bool { matchData != nil }

    var currentAudiobookChapterID: SasayakiAudiobookChapter.ID? {
        let lastChapterID = audiobookChapters.last?.id
        return audiobookChapters.last { chapter in
            guard currentTime >= chapter.startTime else { return false }
            return chapter.endTime.map {
                chapter.id == lastChapterID ? currentTime <= $0 : currentTime < $0
            } ?? true
        }?.id
    }
    
    let rootURL: URL
    let bridge: WebViewBridge
    let loadChapter: (Int) -> Void
    let getCurrentIndex: () -> Int
    let onPlayback: () -> Void
    
    init(rootURL: URL, bridge: WebViewBridge, loadChapter: @escaping (Int) -> Void, getCurrentIndex: @escaping () -> Int, onPlayback: @escaping () -> Void) {
        self.rootURL = rootURL
        self.bridge = bridge
        self.loadChapter = loadChapter
        self.getCurrentIndex = getCurrentIndex
        self.onPlayback = onPlayback
        matchData = BookStorage.loadSasayakiMatch(root: rootURL)
        timeline = CueTimeline(match: matchData)
        reloadPlayback()
    }
    
    func reloadPlayback() {
        isRestoring = true
        playback = BookStorage.loadSasayakiPlayback(root: rootURL) ?? SasayakiPlaybackData(lastPosition: 0)
        currentTime = playback.lastPosition
        delay = playback.delay
        rate = playback.rate
        lastUpdate = Int(currentTime.rounded(.down))
        seekGeneration += 1
        let generation = seekGeneration
        stopPlaybackTime = nil
        pendingSeekPosition = nil
        guard let player else {
            isRestoring = false
            return
        }

        let target = currentTime
        pendingSeekPosition = target
        player.defaultRate = rate
        if isPlaying {
            player.rate = rate
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isRestoring = false
                if finished {
                    self.pendingSeekPosition = nil
                }
            }
        }
    }

    func updateMatchData(_ matchData: SasayakiMatchData) {
        self.matchData = matchData
        timeline = CueTimeline(match: matchData)
        bridge.send(.applySasayakiCues(cues(for: getCurrentIndex()), completion: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateCue(for: self.currentTime)
            }
        }))
    }
    
    func importAudio(from url: URL) throws {
        _ = url.startAccessingSecurityScopedResource()
        teardown()
        miningAudioCache.removeAll()
        
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        playback.audioBookmark = bookmark
        savePlayback()
        
        audioURL = url
        errorMessage = nil
        setupPlayer(url: url)
    }
    
    func cues(for chapterIndex: Int) -> String {
        let cues = matchData?.matches
            .filter { $0.chapterIndex == chapterIndex }
            .map { SasayakiCueRange(id: $0.id, start: $0.start, length: $0.length) } ?? []
        let data = try? JSONEncoder().encode(cues)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    
    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
            if autoScroll, let currentCue {
                displayCue(currentCue, reveal: true)
            }
        }
    }
    
    func updatePlaybackActivity() {
        let shouldPreventDisplaySleep = isPlaying && autoScroll
        if shouldPreventDisplaySleep {
            guard playbackActivity == nil else { return }
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Playing Sasayaki with auto-scroll"
            )
        } else if let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
    }

    func refreshDisplayedCue(reveal: Bool = false) {
        guard let currentCue else { return }
        bridge.send(.highlightSasayakiCue(id: currentCue.id, reveal: reveal))
    }

    func visibleCueWindow(radius: Int = 4) -> [SasayakiMatch] {
        guard let matches = matchData?.matches, !matches.isEmpty else { return [] }
        let activeIndex = currentCue
            .flatMap { cue in matches.firstIndex(where: { $0.id == cue.id }) }
            ?? cueIndex(near: currentTime - delay, in: matches)
        let safeRadius = max(0, radius)
        let lowerBound = max(matches.startIndex, activeIndex - safeRadius)
        let upperBound = min(matches.endIndex, activeIndex + safeRadius + 1)
        return Array(matches[lowerBound..<upperBound])
    }

    func seekToCue(_ cue: SasayakiMatch, startPlayback: Bool = true) {
        navigateToCue(cue, startPlayback: startPlayback)
    }

    func seekRelative(_ delta: TimeInterval) {
        stopPlaybackTime = nil
        let target = currentTime + delta
        seek(seconds: duration > 0 ? min(max(0, target), duration) : max(0, target))
    }
    
    func nextCue() {
        stopPlaybackTime = nil
        let next = timeline.nextCueMatch(after: currentCue?.startTime ?? currentTime - delay)
        guard let next else { return }
        navigateToCue(next)
    }
    
    func prevCue() {
        stopPlaybackTime = nil
        guard let previous = timeline.prevCueMatch(before: currentCue?.startTime ?? max(0, currentTime - delay)) else {
            seek(seconds: 0)
            return
        }
        navigateToCue(previous)
    }
    
    func skip(forward: Bool) {
        stopPlaybackTime = nil
        if forward {
            let target = self.currentTime + self.skipInterval
            seek(seconds: self.duration != 0 ? min(self.currentTime + self.skipInterval, self.duration) : target)
        } else {
            seek(seconds: max(0, self.currentTime - self.skipInterval))
        }
    }

    func seekToAudiobookChapter(_ chapter: SasayakiAudiobookChapter) {
        stopPlaybackTime = nil
        seek(seconds: chapter.startTime)
    }
    
    func handleRestoreCompleted(currentIndex: Int) {
        guard hasMatch else { return }
        
        let wasChapterTransition = chapterTransition
        let resume = shouldResume
        let cue: SasayakiMatch?
        let revealCue: Bool
        if wasChapterTransition, let pendingCue, pendingCue.chapterIndex == currentIndex {
            cue = pendingCue
            revealCue = revealPendingCueOnRestore || (resume && autoScroll)
        } else if let active = timeline.cue(at: currentTime - delay), active.chapterIndex == currentIndex {
            cue = active
            revealCue = resume && autoScroll
        } else {
            cue = nil
            revealCue = false
        }
        
        chapterTransition = false
        shouldResume = false
        revealPendingCueOnRestore = false
        pendingCue = nil
        
        if let cue {
            displayCue(cue, reveal: revealCue)
        } else {
            clearDisplayedCue()
        }
        
        if resume {
            startPlayback()
        }
    }
    
    func prepareTransition() {
        shouldResume = isPlaying
        chapterTransition = true
        stopPlaybackTime = nil
        clearDisplayedCue()
        if isPlaying {
            pausePlayback()
        }
    }
    
    func findCue(chapterIndex: Int, offset: Int) -> SasayakiMatch? {
        guard let matches = matchData?.matches else { return nil }
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            let m = matches[mid]
            if m.chapterIndex < chapterIndex || (m.chapterIndex == chapterIndex && m.start + m.length <= offset) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return (low < matches.count && matches[low].chapterIndex == chapterIndex && matches[low].start <= offset) ? matches[low] : nil
    }
    
    func playCue(from cue: SasayakiMatch, stop: Bool) {
        sasayakiPersistenceLogger.notice(
            "sasayaki.playCue.request book=\(self.rootURL.lastPathComponent, privacy: .public) cue=\(cue.id, privacy: .public) chapter=\(cue.chapterIndex, privacy: .public) start=\(cue.startTime, privacy: .public) end=\(cue.endTime, privacy: .public) stop=\(stop, privacy: .public) delay=\(self.delay, privacy: .public)"
        )
        stopPlaybackTime = nil
        if isPlaying {
            pausePlayback()
        }
        seek(
            seconds: cue.startTime + delay,
            startPlayback: true,
            updateCue: false,
            stopPlaybackTime: stop ? cue.endTime + delay : nil
        )
    }

    func flushPlayback() {
        let pending = pendingSeekPosition.map { String(format: "%.3f", $0) } ?? "nil"
        sasayakiPersistenceLogger.notice(
            "sasayaki.flush.start book=\(self.rootURL.lastPathComponent, privacy: .public) current=\(self.currentTime, privacy: .public) pending=\(pending, privacy: .public) playing=\(self.isPlaying, privacy: .public)"
        )
        if let pendingSeekPosition {
            persistPlaybackPosition(pendingSeekPosition)
            return
        }
        guard isPlaying else {
            sasayakiPersistenceLogger.notice(
                "sasayaki.flush.skipInactive book=\(self.rootURL.lastPathComponent, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            return
        }
        if let seconds = player?.currentTime().seconds, seconds.isFinite {
            sasayakiPersistenceLogger.notice(
                "sasayaki.flush.samplePlayer book=\(self.rootURL.lastPathComponent, privacy: .public) player=\(seconds, privacy: .public)"
            )
            currentTime = seconds
        }
        playback.lastPosition = currentTime
        savePlayback()
        onPlayback()
    }
    
    func teardown() {
        sasayakiPersistenceLogger.notice(
            "sasayaki.teardown.start book=\(self.rootURL.lastPathComponent, privacy: .public) current=\(self.currentTime, privacy: .public) pending=\(self.pendingSeekPosition.map { String(format: "%.3f", $0) } ?? "nil", privacy: .public) playing=\(self.isPlaying, privacy: .public)"
        )
        flushPlayback()
        seekGeneration += 1
        isRestoring = false
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        
        if let token = timeObserver, let player {
            player.removeTimeObserver(token)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        transcription.reset()
        audiobookChapterLoadTask?.cancel()
        audiobookChapterLoadTask = nil
        audiobookChapterLoadGeneration += 1
        player = nil
        timeObserver = nil
        endObserver = nil
        isPlaying = false
        duration = 0
        audiobookMetadata = .empty
        audiobookChapters = []
        isLoadingAudiobookChapters = false
        stopPlaybackTime = nil
        pendingSeekPosition = nil
        
        clearDisplayedCue()
        
        if let url = audioURL {
            url.stopAccessingSecurityScopedResource()
            audioURL = nil
        }
        miningAudioCache.removeAll()
    }
    
    func cueSentenceAudio(
        _ cue: SasayakiMatch,
        sentence: String,
        format: AnkiAudioCompressionFormat,
        bitrateKbps: Int
    ) async -> Data? {
        guard let url = audioURL else {
            return nil
        }
        
        let range = expandCue(cue, sentence: sentence)
        let start = max(0, range.start + delay)
        let end = max(start, range.end + delay)
        // Mined audio follows the current playback speed so the card sounds like what the user heard.
        let playbackRate = Double(rate)
        let cacheKey = [
            url.standardizedFileURL.path(percentEncoded: false),
            String(Int((start * 1000).rounded())),
            String(Int((end * 1000).rounded())),
            format.rawValue,
            String(bitrateKbps),
            String(Int((playbackRate * 100).rounded()))
        ].joined(separator: "\n")
        if let cached = miningAudioCache[cacheKey] {
            return cached
        }

        let sourceAsset = AVURLAsset(url: url)
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        let asset: AVAsset
        let exportRange: CMTimeRange
        if abs(playbackRate - 1) < 0.001 {
            asset = sourceAsset
            exportRange = sourceRange
        } else {
            guard let composition = try? await Self.rateAdjustedComposition(
                of: sourceAsset,
                timeRange: sourceRange,
                rate: playbackRate
            ) else {
                return nil
            }
            asset = composition
            exportRange = CMTimeRange(start: .zero, duration: composition.duration)
        }
        let identifier = UUID().uuidString
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sasayaki-audio-\(identifier).m4a")
        let encodedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sasayaki-audio-\(identifier)-encoded.\(format.fileExtension)"
            )
        defer {
            try? FileManager.default.removeItem(at: m4aURL)
            try? FileManager.default.removeItem(at: encodedURL)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        session.timeRange = exportRange
        session.audioTimePitchAlgorithm = .spectral
        do {
            try await session.export(to: m4aURL, as: .m4a)
            let data = try await AnkiAudioCompressor.data(
                from: m4aURL,
                format: format,
                bitrateKbps: bitrateKbps,
                destinationURL: encodedURL
            )
            miningAudioCache[cacheKey] = data
            return data
        } catch {
            return nil
        }
    }
    
    private static func rateAdjustedComposition(
        of asset: AVURLAsset,
        timeRange: CMTimeRange,
        rate: Double
    ) async throws -> AVMutableComposition? {
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let clippedRange = timeRange.intersection(try await sourceTrack.load(.timeRange))
        guard clippedRange.duration > .zero else {
            return nil
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }
        try track.insertTimeRange(clippedRange, of: sourceTrack, at: .zero)
        track.scaleTimeRange(
            CMTimeRange(start: .zero, duration: clippedRange.duration),
            toDuration: CMTimeMultiplyByFloat64(clippedRange.duration, multiplier: 1 / rate)
        )
        return composition
    }

    private func expandCue(_ cue: SasayakiMatch, sentence: String) -> (start: Double, end: Double) {
        guard let cues = matchData?.matches.filter({ $0.chapterIndex == cue.chapterIndex }),
              let index = cues.firstIndex(where: { $0.id == cue.id }) else {
            return (cue.startTime, cue.endTime)
        }
        
        var start = index
        var end = index
        let filteredSentence = sentence.filtered()
        while start > cues.startIndex, filteredSentence.contains(cues[start - 1].text.filtered()) { start -= 1 }
        while end < cues.index(before: cues.endIndex), filteredSentence.contains(cues[end + 1].text.filtered()) { end += 1 }
        return (cues[start].startTime, cues[end].endTime)
    }

    private func cueIndex(near time: Double, in matches: [SasayakiMatch]) -> Int {
        var low = matches.startIndex
        var high = matches.endIndex
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].startTime < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == matches.startIndex {
            return low
        }
        if low == matches.endIndex {
            return matches.index(before: matches.endIndex)
        }
        let previous = matches.index(before: low)
        return abs(matches[previous].startTime - time) <= abs(matches[low].startTime - time) ? previous : low
    }

    private func navigateToCue(_ cue: SasayakiMatch, startPlayback: Bool = false) {
        stopPlaybackTime = nil
        let target = cue.startTime + delay
        guard cue.chapterIndex != getCurrentIndex() else {
            seek(seconds: target, startPlayback: startPlayback)
            return
        }

        let shouldStartAfterRestore = isPlaying || startPlayback
        pendingCue = cue
        revealPendingCueOnRestore = true
        loadChapter(cue.chapterIndex)
        currentCue = cue
        seek(seconds: target, updateCue: false)
        if shouldStartAfterRestore {
            shouldResume = true
        }
    }
    
    private func startPlayback() {
        guard let player else { return }
        player.play()
        isPlaying = true
        hasPlayedOnce = true
    }
    
    private func pausePlayback() {
        guard let player else { return }
        player.pause()
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            persistPlaybackPosition(seconds)
        }
        isPlaying = false
    }
    
    private func tick(_ seconds: Double) {
        guard !isRestoring else { return }
        if let pendingSeekPosition {
            guard abs(seconds - pendingSeekPosition) <= seekLandingTolerance else { return }
            self.pendingSeekPosition = nil
        }

        currentTime = seconds
        
        if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            self.duration = duration
        }
        
        if let stopTime = stopPlaybackTime, seconds >= stopTime {
            stopPlaybackTime = nil
            if isPlaying {
                pausePlayback()
            }
        }
        
        let second = Int(seconds.rounded(.down))
        if second != lastUpdate {
            lastUpdate = second
            playback.lastPosition = seconds
            sasayakiPersistenceLogger.notice(
                "sasayaki.tick.persist book=\(self.rootURL.lastPathComponent, privacy: .public) position=\(seconds, privacy: .public) second=\(second, privacy: .public)"
            )
            savePlayback()
            onPlayback()
        }
        
        updateCue(for: seconds)
    }
    
    private func seek(seconds: Double, startPlayback: Bool = false, updateCue: Bool = true, stopPlaybackTime: Double? = nil) {
        guard let player else { return }
        
        seekGeneration += 1
        let generation = seekGeneration
        isRestoring = false
        pendingSeekPosition = seconds
        sasayakiPersistenceLogger.notice(
            "sasayaki.seek.request book=\(self.rootURL.lastPathComponent, privacy: .public) target=\(seconds, privacy: .public) generation=\(generation, privacy: .public) startPlayback=\(startPlayback, privacy: .public) updateCue=\(updateCue, privacy: .public) stopPlaybackTime=\(stopPlaybackTime ?? -1, privacy: .public)"
        )
        persistPlaybackPosition(seconds)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.seekGeneration == generation else { return }
                self.stopPlaybackTime = stopPlaybackTime
                if updateCue {
                    self.tick(seconds)
                } else {
                    self.currentTime = seconds
                }
                
                if startPlayback {
                    self.startPlayback()
                }
            }
        }
    }

    private func persistPlaybackPosition(_ seconds: Double) {
        sasayakiPersistenceLogger.notice(
            "sasayaki.persist.position book=\(self.rootURL.lastPathComponent, privacy: .public) position=\(seconds, privacy: .public)"
        )
        currentTime = seconds
        lastUpdate = Int(seconds.rounded(.down))
        playback.lastPosition = seconds
        savePlayback()
        onPlayback()
    }
    
    private func setupPlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.defaultRate = rate
        player?.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.125, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }
        
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopPlaybackTime = nil
                self.isPlaying = false
            }
        }

        loadAudiobookMetadata(from: item.asset, url: url)
    }

    private func loadAudiobookMetadata(from asset: AVAsset, url: URL) {
        audiobookChapterLoadTask?.cancel()
        audiobookChapterLoadGeneration += 1
        let generation = audiobookChapterLoadGeneration
        audiobookMetadata = .empty
        audiobookChapters = []
        isLoadingAudiobookChapters = true

        audiobookChapterLoadTask = Task { [weak self] in
            let metadata = await SasayakiAudiobookMetadataLoader.loadMetadata(from: asset)
            guard !Task.isCancelled else { return }
            let chapters = await SasayakiAudiobookMetadataLoader.loadChapters(
                from: asset,
                fallbackURL: url
            )
            guard let self,
                  !Task.isCancelled,
                  generation == self.audiobookChapterLoadGeneration else { return }
            self.audiobookMetadata = metadata
            self.audiobookChapters = chapters
            self.isLoadingAudiobookChapters = false
            self.audiobookChapterLoadTask = nil
        }
    }
    
    func restoreAudio() {
        guard let bookmark = playback.audioBookmark else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        if isStale {
            playback.audioBookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            savePlayback()
        }
        audioURL = url
        miningAudioCache.removeAll()
        setupPlayer(url: url)
    }
    
    private func savePlayback() {
        playback.delay = delay
        playback.rate = rate
        let url = rootURL.appendingPathComponent(FileNames.sasayakiPlayback)
        sasayakiPersistenceLogger.notice(
            "sasayaki.save.start book=\(self.rootURL.lastPathComponent, privacy: .public) path=\(url.path, privacy: .public) position=\(self.playback.lastPosition, privacy: .public) delay=\(self.playback.delay, privacy: .public) rate=\(self.playback.rate, privacy: .public)"
        )
        do {
            try BookStorage.save(playback, inside: rootURL, as: FileNames.sasayakiPlayback)
            sasayakiPersistenceLogger.notice(
                "sasayaki.save.success book=\(self.rootURL.lastPathComponent, privacy: .public) path=\(url.path, privacy: .public) position=\(self.playback.lastPosition, privacy: .public)"
            )
        } catch {
            sasayakiPersistenceLogger.error(
                "sasayaki.save.failure book=\(self.rootURL.lastPathComponent, privacy: .public) path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
    
    private func updateCue(for time: Double) {
        guard hasAudio, hasMatch, !chapterTransition else { return }
        
        let lookupTime = time - delay
        guard let cue = timeline.cue(at: lookupTime) else {
            clearDisplayedCue()
            return
        }
        
        if cue.id == currentCue?.id {
            return
        }
        
        let currentIndex = getCurrentIndex()
        if cue.chapterIndex == currentIndex {
            displayCue(cue, reveal: autoScroll && hasPlayedOnce)
        } else if autoScroll, hasPlayedOnce {
            currentCue = cue
            pendingCue = cue
            loadChapter(cue.chapterIndex)
        } else {
            clearDisplayedCue()
        }
    }
    
    private func displayCue(_ cue: SasayakiMatch, reveal: Bool) {
        currentCue = cue
        bridge.send(.highlightSasayakiCue(id: cue.id, reveal: reveal))
    }
    
    private func clearDisplayedCue() {
        guard currentCue != nil else { return }
        currentCue = nil
        bridge.send(.clearSasayakiCue)
    }
    
    
    
}
