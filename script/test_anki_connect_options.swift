// test-sources: Models/Anki.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func scopeOptions(_ options: [String: Any]) -> [String: Any]? {
    options["duplicateScopeOptions"] as? [String: Any]
}

@main
struct AnkiConnectOptionsTests {
    static func main() {
        let collection = DuplicateScope.collection.ankiConnectOptions(
            deck: "日本語::語彙", allowDuplicates: false, checkAllModels: false
        )
        expect(collection["allowDuplicate"] as? Bool == false, "allowDuplicate should be forwarded")
        expect(collection["duplicateScope"] as? String == "collection", "collection scope")
        expect(scopeOptions(collection) == nil, "collection without checkAllModels needs no scope options")

        let deck = DuplicateScope.deck.ankiConnectOptions(
            deck: "日本語::語彙", allowDuplicates: true, checkAllModels: false
        )
        expect(deck["allowDuplicate"] as? Bool == true, "allowDuplicate true should be forwarded")
        expect(deck["duplicateScope"] as? String == "deck", "deck scope")
        expect(scopeOptions(deck) == nil, "deck scope checks only the target deck")

        let root = DuplicateScope.deckroot.ankiConnectOptions(
            deck: "日本語::語彙::N1", allowDuplicates: false, checkAllModels: false
        )
        expect(root["duplicateScope"] as? String == "deck", "deck root is a deck scope in AnkiConnect")
        expect(scopeOptions(root)?["deckName"] as? String == "日本語", "deck root should check the top-level deck")
        expect(scopeOptions(root)?["checkChildren"] as? Bool == true, "deck root should include child decks")
        expect(scopeOptions(root)?["checkAllModels"] == nil, "checkAllModels is opt-in")

        let flatRoot = DuplicateScope.deckroot.ankiConnectOptions(
            deck: "Mining", allowDuplicates: false, checkAllModels: false
        )
        expect(scopeOptions(flatRoot)?["deckName"] as? String == "Mining", "a deck without children is its own root")

        let allModels = DuplicateScope.collection.ankiConnectOptions(
            deck: "Mining", allowDuplicates: false, checkAllModels: true
        )
        expect(allModels["duplicateScope"] as? String == "collection", "checkAllModels keeps the scope")
        expect(scopeOptions(allModels)?["checkAllModels"] as? Bool == true, "checkAllModels should be forwarded")
        expect(scopeOptions(allModels)?["deckName"] == nil, "collection scope should not name a deck")

        let rootAllModels = DuplicateScope.deckroot.ankiConnectOptions(
            deck: "A::B", allowDuplicates: false, checkAllModels: true
        )
        let merged = scopeOptions(rootAllModels)
        expect(
            merged?["deckName"] as? String == "A"
                && merged?["checkChildren"] as? Bool == true
                && merged?["checkAllModels"] as? Bool == true,
            "deck root and checkAllModels should share one duplicateScopeOptions object"
        )

        for scope in DuplicateScope.allCases {
            let options = scope.ankiConnectOptions(deck: "X", allowDuplicates: false, checkAllModels: false)
            expect(JSONSerialization.isValidJSONObject(options), "\(scope) options must serialize for AnkiConnect")
        }

        print("AnkiConnect options tests passed")
    }
}
