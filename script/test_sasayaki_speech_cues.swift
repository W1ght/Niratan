// test-sources: Features/Sasayaki/SasayakiSpeechEngine.swift Models/Sasayaki.swift
import Foundation

@main struct SasayakiSpeechCueTests {
    static func main() {
        let tokens = [
            SasayakiTimedText(text: "今日は", start: 298, end: 299),
            SasayakiTimedText(text: "いい天気です。", start: 299, end: 301),
            SasayakiTimedText(text: "本を", start: 301, end: 302),
            SasayakiTimedText(text: "読みます。", start: 302, end: 304)
        ]
        let first = SasayakiSpeechCueBuilder.build(tokens, ownedRange: 0..<300, idPrefix: "a")
        let second = SasayakiSpeechCueBuilder.build(tokens, ownedRange: 300..<600, idPrefix: "b")
        precondition((first + second).map(\.text).joined() == "今日はいい天気です。本を読みます。", "Overlap tokens must have one owner without losing boundary words")
        precondition(first.first?.startTime == 298 && second.last?.endTime == 304, "Original absolute audio times survive splitting")
        let english = SasayakiSpeechCueBuilder.build([
            .init(text: "Hello ", start: 10, end: 11), .init(text: "world.", start: 11, end: 12),
            .init(text: " Another sentence.", start: 13, end: 15)
        ], ownedRange: 0..<20, idPrefix: "en")
        precondition(english.map(\.text) == ["Hello world.", "Another sentence."])
        precondition(SasayakiSpeechCueBuilder.build([.init(text: "bad", start: .nan, end: 4)], ownedRange: 0..<10, idPrefix: "bad").isEmpty)
        print("Sasayaki word timestamp cue tests passed")
    }
}
