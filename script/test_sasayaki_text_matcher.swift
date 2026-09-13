import Foundation

@main
struct SasayakiTextMatcherTests {
    static func cue(_ id: String, _ text: String, at start: Double = 0, duration: Double = 3) -> SasayakiCue {
        .init(id: id, startTime: start, endTime: start + duration, text: text)
    }

    static func main() {
        let first = "朝になって旅人たちは静かな森の奥へ出発した。"
        let second = "私は小さな灯りを頼りに暗い廊下を歩いていた。"
        let third = "窓の外には雪に覆われた山々がどこまでも続いていた。"
        let source = String(repeating: "序文の説明がここにあります", count: 30) + first + second
            + String(repeating: "音声では省略されている挿話です", count: 40) + third
        let result = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 3, markup: source)],
            cues: [cue("intro", "音声版の制作会社からのお知らせです"),
                   cue("first", first), cue("second", second.replacingOccurrences(of: "灯り", with: "明かり"), at: 4),
                   cue("third", third, at: 8)], searchWindow: 50
        )
        precondition(result.matches.map(\.id) == ["first", "second", "third"], "Recover globally after narration and an omitted passage, tolerate an ASR spelling error")
        precondition(result.unmatched == 1)
        let secondMatch = result.matches[1]
        let normalized = Array(ReaderCharacterNormalizer.filteredText(from: source))
        precondition(String(normalized[secondMatch.start..<(secondMatch.start + secondMatch.length)]) == ReaderCharacterNormalizer.filteredText(from: second), "Fuzzy highlights use source offsets and length")
        precondition(result.matches.allSatisfy { $0.chapterIndex == 3 })

        let english = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: "<body><ruby>HELLO<rt>reading</rt></ruby> ＷＯＲＬＤ. Alice crossed the unusually quiet street.</body>")],
            cues: [cue("hello", "Hello world"), cue("alice", "Alice crosses the unusually quiet street", at: 4)], searchWindow: 50
        )
        precondition(english.matches.count == 2)
        precondition(english.matches[0].start == 0 && english.matches[0].length == 10, "Width/case folding preserves Reader coordinates and omits ruby")

        let noMatch = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: source)],
            cues: [cue("wrong", "On the moon a machine counted seventeen different colors."), cue("short", "そうです")], searchWindow: 50
        )
        precondition(noMatch.matches.isEmpty && noMatch.unmatched == 2, "Unrelated recordings remain unmatched")

        let repeated = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: String(repeating: "前置き", count: 100) + first + String(repeating: "別の場面", count: 100) + first)],
            cues: [cue("repeated", first)], searchWindow: 50
        )
        precondition(repeated.matches.isEmpty, "Ambiguous repeated global passages cannot move the cursor")

        let globalFuzzy = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: String(repeating: "前置き", count: 200) + third)],
            cues: [cue("anchor", third.replacingOccurrences(of: "雪", with: "霧"))], searchWindow: 50
        )
        precondition(globalFuzzy.matches.count == 1, "Multiple exact anchors can recover an imperfect transcript far from the cursor")

        let longText = first + second + third + "村の広場には色とりどりの商品が並び大勢の人が集まっていた。" + "遠くの時計塔から正午を知らせる鐘の音がゆっくりと聞こえてきた。" + "旅人は鞄から古い地図を取り出して次に向かう場所を確認した。"
        let legacy = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: longText)],
            cues: [cue("long", longText.replacingOccurrences(of: "灯り", with: "明かり"), duration: 90)], searchWindow: 50
        )
        precondition(legacy.matches.count > 2 && legacy.unmatched == 0, "Legacy long ASR results are aligned in bounded sentence pieces")
        precondition(legacy.matches.first?.startTime == 0 && legacy.matches.last?.endTime == 90)
        precondition(Set(legacy.matches.map(\.id)).count == legacy.matches.count)
        for pair in zip(legacy.matches, legacy.matches.dropFirst()) {
            precondition(pair.0.endTime <= pair.1.startTime && pair.0.start + pair.0.length <= pair.1.start)
        }

        let crossing = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 1, markup: "森の奥には誰も知らない"), .init(chapterIndex: 2, markup: "古い遺跡が残されていた")],
            cues: [cue("crossing", "森の奥には誰も知らない古い遺跡が残されていた")], searchWindow: 50
        )
        precondition(crossing.matches.isEmpty, "Never produce a highlight extending outside one Reader chapter")

        let boundedSource = first + "多分。" + second
        let bounded = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 4, markup: boundedSource)],
            cues: [cue("left", first), cue("reading", "たぶん", at: 3, duration: 1),
                   cue("right", second, at: 4)], searchWindow: 50
        )
        precondition(bounded.matches.map(\.id) == ["left", "reading", "right"] && bounded.unmatched == 0,
                     "Nearby anchors can recover a kana/kanji cue with no shared characters")
        let leftLength = ReaderCharacterNormalizer.readableCharacterCount(in: first)
        let rightLength = ReaderCharacterNormalizer.readableCharacterCount(in: second)
        precondition(bounded.matches[0].start == 0 && bounded.matches[0].length == leftLength
                     && bounded.matches[2].start == leftLength + 2 && bounded.matches[2].length == rightLength,
                     "Gap recovery must not move either reliable exact anchor")
        precondition(bounded.matches[1].start == leftLength && bounded.matches[1].length == 2
                     && bounded.matches[1].contextInferred == true,
                     "Text-free gap recovery uses Reader coordinates and records that the position was inferred")
        precondition(bounded.matches[0].contextInferred != true && bounded.matches[2].contextInferred != true,
                     "Text-backed anchors must not be counted as proportional inference")
        precondition(bounded.matches.map(\.startTime) == [0, 3, 4]
                     && bounded.matches.map(\.endTime) == [3, 4, 7],
                     "Filling a text gap preserves the subtitle's original timing")

        let spellingSource = first + "今日は学校へ行く。意外と近い。ドラゴン。" + second
        let spelling = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 4, markup: spellingSource)],
            cues: [cue("left", first), cue("kana", "きょうは学校へ行く", at: 3, duration: 2),
                   cue("homophone", "以外と近い", at: 5, duration: 2),
                   cue("katakana", "どらごん", at: 7, duration: 1), cue("right", second, at: 8)],
            searchWindow: 50
        )
        precondition(spelling.matches.map(\.id) == ["left", "kana", "homophone", "katakana", "right"],
                     "A bounded second pass recovers kana spellings, homophones and katakana variants")
        for pair in zip(spelling.matches, spelling.matches.dropFirst()) {
            precondition(pair.0.start + pair.0.length <= pair.1.start,
                         "Recovered phrases keep subtitle order and do not overlap their neighbors")
        }
        precondition(spelling.matches.last?.start == ReaderCharacterNormalizer.readableCharacterCount(in: spellingSource) - rightLength,
                     "Spelling recovery must preserve the following exact anchor's source offset")

        let publisher = "この音声作品は北の星出版の制作でお届けします"
        let preface = String(repeating: "前書きの説明です", count: 40)
        let credits = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 2, markup: preface + first + second),
                       .init(chapterIndex: 10, markup: publisher)],
            cues: [cue("publisher", publisher), cue("body-one", first, at: 4),
                   cue("body-two", second, at: 8)], searchWindow: 50
        )
        precondition(credits.matches.map(\.id) == ["body-one", "body-two"] && credits.unmatched == 1,
                     "Opening publisher credits found only in the final colophon cannot strand the cursor at the book's end")
        precondition(credits.matches.allSatisfy { $0.chapterIndex == 2 }
                     && credits.matches.first?.start == ReaderCharacterNormalizer.readableCharacterCount(in: preface),
                     "Narration after rejected credits must recover the real body position")

        let chapterGap = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 1, markup: first + "多分。"),
                       .init(chapterIndex: 2, markup: "然うか。" + second)],
            cues: [cue("left", first), cue("gap", "たぶん", at: 3, duration: 1),
                   cue("right", second, at: 4)], searchWindow: 50
        )
        precondition(chapterGap.matches.map(\.id) == ["left", "right"] && chapterGap.unmatched == 1,
                     "Anchors in different Reader chapters cannot justify a proportional gap match")
        precondition(chapterGap.matches.last?.chapterIndex == 2 && chapterGap.matches.last?.start == 3,
                     "The next chapter keeps its own Reader character coordinates")

        let announcement = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: first + "夕暮れの街で旅人は一息ついた。" + second)],
            cues: [cue("left", first), cue("advert", "This is an advertisement.", at: 3, duration: 2),
                   cue("right", second, at: 5)], searchWindow: 50
        )
        precondition(announcement.matches.map(\.id) == ["left", "right"] && announcement.unmatched == 1,
                     "An unrelated English announcement must not be inferred into a Japanese text gap")

        let omitted = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: first + String(repeating: "資料記録書類参考一覧", count: 10) + second)],
            cues: [cue("left", first), cue("gap", "たぶん", at: 3, duration: 1),
                   cue("right", second, at: 4)], searchWindow: 50
        )
        precondition(omitted.matches.map(\.id) == ["left", "right"] && omitted.unmatched == 1,
                     "A short unmatched cue cannot consume a long omitted body passage")

        let discontinuity = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: boundedSource)],
            cues: [cue("left", first), cue("gap", "たぶん", at: 30, duration: 1),
                   cue("right", second, at: 31)], searchWindow: 50
        )
        precondition(discontinuity.matches.map(\.id) == ["left", "right"] && discontinuity.unmatched == 1,
                     "A long interruption in the audio must prevent text-free interpolation")

        let unordered = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: boundedSource)],
            cues: [cue("left", first, at: 10), cue("gap", "たぶん", at: 0, duration: 1),
                   cue("right", second, at: 14)], searchWindow: 50
        )
        precondition(unordered.matches.map(\.id) == ["left", "right"],
                     "Out-of-order timestamps cannot justify context-only interpolation")

        let legacyJSON = Data(#"{"matches":[{"id":"old","startTime":0,"endTime":1,"text":"test","chapterIndex":0,"start":0,"length":4}],"unmatched":0}"#.utf8)
        let legacyData = try! JSONDecoder().decode(SasayakiMatchData.self, from: legacyJSON)
        precondition(legacyData.matches[0].contextInferred == nil,
                     "Existing match sidecars remain readable without context-inference metadata")

        let unbounded = SasayakiTextMatcher.match(
            chapters: [.init(chapterIndex: 0, markup: "多分。" + first + second + "然うか。")],
            cues: [cue("head", "たぶん", duration: 1), cue("left", first, at: 1),
                   cue("right", second, at: 4), cue("tail", "そうか", at: 7, duration: 1)], searchWindow: 50
        )
        precondition(unbounded.matches.map(\.id) == ["left", "right"] && unbounded.unmatched == 2,
                     "Short unrecognized opening and ending cues need evidence on both sides before they may be inferred")
        print("Sasayaki text matcher tests passed")
    }
}
