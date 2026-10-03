// test-sources: Models/Anki.swift Features/Video/VideoAudioClipRange.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VideoMediaMiningTests {
    static func main() {
        let screenshot = URL(fileURLWithPath: "/tmp/hoshi-shot.png")
        let audio = URL(fileURLWithPath: "/tmp/hoshi-clip.m4a")
        let context = VideoMiningContext(
            fileName: "Episode 1.mkv",
            cueText: "字幕",
            cueStart: 12,
            cueEnd: 15,
            previousCueText: nil,
            nextCueText: nil,
            screenshotURL: screenshot,
            audioClipURL: audio,
            audioClipErrorMessage: nil
        )

        expect(
            context.value(for: .videoScreenshot) == screenshot.path,
            "screenshot handlebar should expose the captured file"
        )
        expect(
            context.value(for: .videoAudioClip) == audio.path,
            "audio clip handlebar should expose the captured file"
        )
        let directContext = VideoMiningContext(
            fileName: "Episode 1.mkv",
            cueText: "字幕",
            cueStart: 12,
            cueEnd: 15,
            previousCueText: nil,
            nextCueText: nil,
            screenshotFilename: "hoshi_video_frame_direct.png",
            audioClipFilename: "hoshi_video_audio_direct.m4a",
            screenshotURL: screenshot,
            audioClipURL: audio,
            audioClipErrorMessage: nil
        )
        expect(
            directContext.value(for: .videoScreenshot) == "hoshi_video_frame_direct.png",
            "direct screenshot handlebar should prefer the Anki media filename"
        )
        expect(
            directContext.value(for: .videoAudioClip) == "hoshi_video_audio_direct.m4a",
            "direct audio handlebar should prefer the Anki media filename"
        )
        let filenames = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/Users/me/Show Episode 1.mkv"),
            cueStart: 12.345,
            cueEnd: 15.678,
            audioStart: 12.265,
            audioEnd: 15.758,
            screenshotFormat: .png
        )
        let sameFilenames = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/Users/me/Show Episode 1.mkv"),
            cueStart: 12.345,
            cueEnd: 15.678,
            audioStart: 12.265,
            audioEnd: 15.758,
            screenshotFormat: .png
        )
        expect(filenames == sameFilenames, "video direct media filenames should be deterministic")
        expect(
            filenames.screenshot == "hoshi_video_frame_6c7af43fe8d969c7758b8849f26bee002041cb06_12345-15678.png",
            "screenshot filename should use source-path SHA and cue millisecond range"
        )
        expect(
            filenames.audioClip == "hoshi_video_audio_6c7af43fe8d969c7758b8849f26bee002041cb06_12265-15758.m4a",
            "audio filename should use source-path SHA and clip millisecond range"
        )
        let mp3Filenames = VideoMiningContext.deterministicMediaFilenames(
            videoURL: URL(fileURLWithPath: "/Users/me/Show Episode 1.mkv"),
            cueStart: 12.345,
            cueEnd: 15.678,
            audioStart: 12.265,
            audioEnd: 15.758,
            screenshotFormat: .jpeg,
            screenshotQuality: 0.55,
            audioFormat: .mp3,
            audioBitrateKbps: 96
        )
        expect(
            mp3Filenames.audioClip.hasSuffix(".mp3"),
            "selected audio compression format should control the deterministic extension"
        )
        expect(
            mp3Filenames.screenshot.contains("_q55.jpg")
                && mp3Filenames.audioClip.contains("_96k.mp3"),
            "non-default quality should produce distinct reusable media filenames"
        )
        expect(
            filenames.screenshot.allSatisfy { $0.isASCII }
                && filenames.audioClip.allSatisfy { $0.isASCII },
            "direct media filenames should stay ASCII"
        )
        expect(
            Handlebars.videoScreenshot.isVideoSpecific,
            "screenshot handlebar should be video-specific"
        )
        expect(
            Handlebars.videoAudioClip.isVideoSpecific,
            "audio handlebar should be video-specific"
        )

        let range = VideoAudioClipRange.resolve(
            cueStart: 0.05,
            cueEnd: 4.0,
            subtitleDelay: 0.2,
            duration: 4.25
        )
        expect(abs((range?.start ?? -1) - 0.13) < 0.0001, "clip start should apply delay and padding")
        expect(abs((range?.end ?? -1) - 4.25) < 0.0001, "clip end should clamp to duration")
        expect(VideoAudioClipRange.resolve(
            cueStart: 2,
            cueEnd: 1,
            subtitleDelay: 0,
            duration: 10
        ) == nil, "invalid cue ranges should not export")
        print("Video media mining tests passed")
    }
}
