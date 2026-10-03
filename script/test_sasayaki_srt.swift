// test-sources: Models/Sasayaki.swift Features/Sasayaki/SasayakiParser.swift Features/Sasayaki/SasayakiSRT.swift
import Foundation

@main
struct SasayakiSRTTests {
    static func main() {
        let cues = [
            SasayakiCue(id: "later", startTime: 3600.9996, endTime: 3602.125, text: "Hello\nworld"),
            SasayakiCue(id: "first", startTime: 0.125, endTime: 2.75, text: "こんにちは。"),
            SasayakiCue(id: "bad", startTime: .nan, endTime: 4, text: "invalid")
        ]
        let srt = SasayakiSRT.encode(cues)
        precondition(srt.contains("01:00:01,000 --> 01:00:02,125"))
        precondition(!srt.contains("invalid"))
        let decoded = SasayakiParser.parseCues(from: Data(srt.utf8))
        precondition(decoded.count == 2)
        precondition(decoded[0].text == "こんにちは。")
        precondition(decoded[0].startTime == 0.125 && decoded[0].endTime == 2.75)
        precondition(decoded[1].text == "Hello world")
        precondition(SasayakiSRT.encode([]).isEmpty)
        let imported = SasayakiParser.parseCues(from: Data("\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,000\r\n第一行\r\n第二行\r\n \r\n2\r\ninvalid --> timestamp\r\nbad\r\n\r\n3\r\n00:00:04,000 --> 00:00:05,000\r\nGood\r\n".utf8))
        precondition(imported.count == 2 && imported[0].text == "第一行 第二行" && imported[1].text == "Good")
        precondition(SasayakiParser.parseCues(from: Data("1\n00:99:01,000 --> 00:00:02,000\nbad".utf8)).isEmpty)
        print("Sasayaki SRT round-trip tests passed")
    }
}
