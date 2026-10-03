// test-sources: Features/Video/Subtitles/EmbeddedSubtitlePayloadParser.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfter: Int
    private var checks = 0

    init(cancelAfter: Int) {
        self.cancelAfter = cancelAfter
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelAfter
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }
}

@main
private enum VideoEmbeddedSubtitlePayloadTests {
    static func main() {
        expect(
            EmbeddedSubtitlePayloadParser.text(
                from: "75,1,SUB-JPO,,0,0,0,,{\\i1}今度の中間テスト{\\i0}\\Nあなたには負けませんわよ",
                codec: "ass"
            ) == "今度の中間テスト\nあなたには負けませんわよ",
            "ASS packets should drop event metadata and override tags"
        )
        expect(
            EmbeddedSubtitlePayloadParser.text(
                from: "0,0,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100 0 100{\\p0}",
                codec: "ass"
            ).isEmpty,
            "ASS vector drawings should not leak path commands into lookup or transcript text"
        )
        expect(
            EmbeddedSubtitlePayloadParser.text(
                from: "0,0,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}{\\i1}查词文本{\\i0}",
                codec: "ass"
            ) == "查词文本",
            "text following an ASS drawing segment should remain available for lookup"
        )
        expect(
            EmbeddedSubtitlePayloadParser.text(
                from: "星を見ています。",
                codec: "subrip"
            ) == "星を見ています。",
            "plain subtitle packets should retain their text"
        )
        expect(
            EmbeddedSubtitlePayloadParser.text(
                from: "星<br />空",
                codec: "subrip"
            ) == "星\n空",
            "embedded HTML line breaks should become subtitle hard line breaks before tag stripping"
        )
        expect(
            EmbeddedSubtitlePayloadParser.supportsText(codec: "ass")
                && EmbeddedSubtitlePayloadParser.supportsText(codec: "subrip")
                && !EmbeddedSubtitlePayloadParser.supportsText(codec: "hdmv_pgs_subtitle"),
            "bitmap subtitle tracks should be rejected before extraction"
        )

        let codecPrivate = """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,50,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1

        [Events]
        Format: Text, End, Style, Start, Layer, Name, MarginL, MarginR, MarginV, Effect
        """.data(using: .utf8)
        let packetText = "42,3,Default,Actor,0010,0020,0030,fx,{\\i1}重建字幕{\\i0},with comma"
        let packet = EmbeddedSubtitlePacketRecord(
            rawPayload: Data(packetText.utf8),
            presentationTimestamp: 1250,
            decodingTimestamp: 1200,
            packetDuration: 2500,
            timeBaseNumerator: 1,
            timeBaseDenominator: 1000,
            packetFlags: 1,
            filePosition: 2048,
            startTime: 1.25,
            endTime: 3.75
        )
        let rebuiltData = EmbeddedSubtitlePayloadParser.reconstructedASSData(
            codecPrivate: codecPrivate,
            packets: [packet],
            codec: "ass"
        )
        let rebuilt = rebuiltData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        expect(
            rebuilt.contains("[V4+ Styles]")
                && rebuilt.contains("Style: Default,Arial,50")
                && rebuilt.contains(
                    "Dialogue: {\\i1}重建字幕{\\i0},with comma,0:00:03.75,Default,0:00:01.25,3,Actor,0010,0020,0030,fx"
                ),
            "embedded ASS reconstruction should preserve the codec-private header, packet text commas, timing, and reordered event fields"
        )
        expect(
            packet.presentationTimestamp == 1250
                && packet.decodingTimestamp == 1200
                && packet.packetDuration == 2500
                && packet.timeBaseNumerator == 1
                && packet.timeBaseDenominator == 1000
                && packet.packetFlags == 1
                && packet.filePosition == 2048,
            "embedded packet records should retain the raw demux metadata"
        )

        let defaultFormatHeader = """
        [Script Info]
        ScriptType: v4.00+
        [Events]
        """.data(using: .utf8)
        let defaultFormatData = EmbeddedSubtitlePayloadParser.reconstructedASSData(
            codecPrivate: defaultFormatHeader,
            packets: [packet],
            codec: "ass"
        )
        let defaultFormat = defaultFormatData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        expect(
            defaultFormat.contains("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")
                && defaultFormat.contains(
                    "Dialogue: 3,0:00:01.25,0:00:03.75,Default,Actor,0010,0020,0030,fx,{\\i1}重建字幕{\\i0},with comma"
                ),
            "embedded ASS reconstruction should supply the canonical event format when CodecPrivate omits it"
        )

        func invalidTimestampPacket(
            _ label: String,
            startTime: TimeInterval,
            endTime: TimeInterval
        ) -> EmbeddedSubtitlePacketRecord {
            EmbeddedSubtitlePacketRecord(
                rawPayload: Data("0,0,Default,,0,0,0,,\(label)".utf8),
                presentationTimestamp: 0,
                decodingTimestamp: 0,
                packetDuration: 0,
                timeBaseNumerator: 1,
                timeBaseDenominator: 1_000,
                packetFlags: 0,
                filePosition: 0,
                startTime: startTime,
                endTime: endTime
            )
        }
        let invalidTimestampPackets = [
            invalidTimestampPacket("Invalid NaN", startTime: .nan, endTime: 1),
            invalidTimestampPacket("Invalid infinity", startTime: 1, endTime: .infinity),
            invalidTimestampPacket(
                "Invalid overflow",
                startTime: Double(Int.max),
                endTime: Double(Int.max)
            ),
            invalidTimestampPacket("Invalid negative", startTime: -1, endTime: 1),
        ]
        let mixedTimestampData = EmbeddedSubtitlePayloadParser.reconstructedASSData(
            codecPrivate: defaultFormatHeader,
            packets: invalidTimestampPackets + [packet],
            codec: "ass"
        )
        let mixedTimestampASS = mixedTimestampData.map {
            String(decoding: $0, as: UTF8.self)
        } ?? ""
        expect(
            mixedTimestampASS.contains("重建字幕")
                && !mixedTimestampASS.contains("Invalid NaN")
                && !mixedTimestampASS.contains("Invalid infinity")
                && !mixedTimestampASS.contains("Invalid overflow")
                && !mixedTimestampASS.contains("Invalid negative"),
            "embedded ASS reconstruction should skip packets with invalid timestamp ranges"
        )
        expect(
            EmbeddedSubtitlePayloadParser.reconstructedASSData(
                codecPrivate: defaultFormatHeader,
                packets: invalidTimestampPackets,
                codec: "ass"
            ) == nil,
            "embedded ASS reconstruction should return nil when every packet timestamp is invalid"
        )

        let cancellablePackets = (0..<200).map { index in
            EmbeddedSubtitlePacketRecord(
                rawPayload: Data("\(index),0,Default,,0,0,0,,Packet \(index)".utf8),
                presentationTimestamp: Int64(index),
                decodingTimestamp: Int64(index),
                packetDuration: 1,
                timeBaseNumerator: 1,
                timeBaseDenominator: 1_000,
                packetFlags: 0,
                filePosition: Int64(index),
                startTime: Double(index),
                endTime: Double(index) + 0.5
            )
        }
        let cancellation = CancellationProbe(cancelAfter: 16)
        var didCancelReconstruction = false
        do {
            _ = try EmbeddedSubtitlePayloadParser.reconstructedASSData(
                codecPrivate: defaultFormatHeader,
                packets: cancellablePackets,
                codec: "ass",
                isCancelled: { cancellation.isCancelled() }
            )
        } catch is CancellationError {
            didCancelReconstruction = true
        } catch {
            fputs("FAIL: cancellable embedded reconstruction threw \(error)\n", stderr)
            exit(1)
        }
        expect(
            didCancelReconstruction && cancellation.checkCount == 16,
            "embedded ASS reconstruction should observe cancellation inside the packet loop"
        )
        print("Video embedded subtitle payload tests passed")
    }
}
