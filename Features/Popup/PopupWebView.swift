//
//  PopupWebView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import AppKit
import WebKit

class AudioHandler: NSObject, WKURLSchemeHandler {
    private var tasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestUrl = task.request.url,
              let components = URLComponents(url: requestUrl, resolvingAgainstBaseURL: false),
              let targetUrlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let targetUrl = URL(string: targetUrlString) else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let taskId = ObjectIdentifier(task)
        tasks.insert(taskId)

        Task {
            do {
                let timeout = targetUrl.host == "localhost" ? 5.0 : 4.0
                let request = URLRequest(url: targetUrl, timeoutInterval: timeout)
                let (data, _) = try await URLSession.shared.data(for: request)

                await MainActor.run {
                    guard self.tasks.contains(taskId) else { return }

                    let response = HTTPURLResponse(
                        url: requestUrl,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Access-Control-Allow-Origin": "*",
                            "Content-Type": "application/json"
                        ]
                    )!
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                }
            } catch {
                await MainActor.run {
                    guard self.tasks.contains(taskId) else { return }
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        tasks.remove(ObjectIdentifier(task))
    }
}

class ImageHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestUrl = task.request.url,
              let components = URLComponents(url: requestUrl, resolvingAgainstBaseURL: false),
              let dictionary = components.queryItems?.first(where: { $0.name == "dictionary" })?.value,
              let mediaPath = components.queryItems?.first(where: { $0.name == "path" })?.value else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        LookupEngine.shared.withMediaFile(dictName: dictionary, mediaPath: mediaPath) { data in
            let mime = mimeType(for: mediaPath)
            Task { @MainActor in
                guard !data.isEmpty else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }

                let response = URLResponse(
                    url: requestUrl,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func mimeType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }
}

class DocumentResourceHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }

        let fileName = url.deletingPathExtension().lastPathComponent
        do {
            guard let fontFile = try FontManager.shared.fontUrl(name: fileName, verticalWriting: false) else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }

            let data = try Data(contentsOf: fontFile, options: .mappedIfSafe)
            let response = URLResponse(
                url: url,
                mimeType: mimeType(for: fontFile),
                expectedContentLength: data.count,
                textEncodingName: nil
            )

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "font/ttf"
        }
    }
}

struct DictionaryEntryNavigationCommand: Equatable {
    let sequence: Int
    let direction: Int
    let count: Int
}

struct PopupAnkiNoteCommand: Equatable {
    let sequence: Int
    let entryIndex: Int
    let noteID: Int64
}

struct PopupInlineLookupResult {
    let entries: [[String: Any]]
    let matchedCharacterCount: Int
}

private final class NativePopupWKWebView: HoshiShiftHoverWKWebView {
    var onLayoutChanged: (() -> Void)?

    override func layout() {
        super.layout()
        onLayoutChanged?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayoutChanged?()
    }
}

struct PopupWebView: NSViewRepresentable {
    @Environment(UserConfig.self) private var userConfig

    let content: String
    let position: CGPoint
    var scale: CGFloat = 1.0
    var twoColumnLayout: Bool = false
    var clearSelection: Bool
    var hoverLookupDelayMs: Int = 45
    var dictionaryStyles: [String: String] = [:]
    var lookupEntries: [[String: Any]] = []
    var scanNonJapaneseText: Bool = true
    var scanLength: Int = 16
    var profileID: String = HoshiProfile.defaultJapanese.id
    var contentLanguageID: String = ContentLanguageProfile.japanese.rawValue
    var backTrigger: Bool = false
    var forwardTrigger: Bool = false
    var dictionaryEntryNavigationCommand: DictionaryEntryNavigationCommand?
    var ankiNoteCommand: PopupAnkiNoteCommand?
    var onMine: (([String: String]) async -> AnkiMiningResult)? = nil
    var onMiningFeedback: ((AnkiMiningResult) -> Void)? = nil
    var onPrepareContextMining: (([String: String]) -> Void)? = nil
    var onTextSelected: ((SelectionData) -> Int?)? = nil
    var onQueryTextSelected: ((String) -> PopupInlineLookupResult?)? = nil
    var onTapOutside: (() -> Void)? = nil
    var onSwipeDismiss: (() -> Void)? = nil
    var onRedirect: ((String) -> [[String: Any]])? = nil
    var onKanjiRedirect: ((String) -> [String: Any]?)? = nil
    var scrollViewBounces: Bool = false
    var onScrollViewOffsetChanged: ((CGFloat) -> Void)? = nil
    var onScrollViewWillBeginDragging: (() -> Void)? = nil
    var onScrollViewDidEndDragging: (() -> Void)? = nil
    var onScrollViewDidEndDecelerating: (() -> Void)? = nil

    private static let swipeDismissJs = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "openLink")
        config.userContentController.add(context.coordinator, name: "textSelected")
        config.userContentController.add(context.coordinator, name: "tapOutside")
        config.userContentController.add(context.coordinator, name: "swipeDismiss")
        config.userContentController.add(context.coordinator, name: "playWordAudio")
        config.userContentController.add(context.coordinator, name: "audioSourceMenu")
        config.userContentController.add(context.coordinator, name: "buttonFrames")
        config.userContentController.add(context.coordinator, name: "prepareContextMining")
        config.userContentController.add(context.coordinator, name: "miningFeedback")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "mineEntry")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "openAnkiNote")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "duplicateCheck")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "getEntries")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "lookupRedirect")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "kanjiRedirect")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "queryTextSelected")
        config.setURLSchemeHandler(AudioHandler(), forURLScheme: "audio")
        config.setURLSchemeHandler(ImageHandler(), forURLScheme: "image")
        config.setURLSchemeHandler(DocumentResourceHandler(), forURLScheme: "local-resources")
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = NativePopupWKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.onLayoutChanged = { [weak coordinator = context.coordinator, weak webView] in
            guard let webView else { return }
            coordinator?.requestButtonFrameSync(in: webView)
        }
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let loadConfiguration = "\(profileID)|\(contentLanguageID)|\(scanNonJapaneseText)|\(scanLength)|\(hoverLookupDelayMs)|\(kanjiLookupEnabled)"
        if !context.coordinator.wasLoaded
            || context.coordinator.currentContent != content
            || context.coordinator.loadConfiguration != loadConfiguration {
            context.coordinator.currentContent = content
            context.coordinator.loadConfiguration = loadConfiguration
            context.coordinator.wasLoaded = true
            context.coordinator.scale = scale
            let html = constructHtml(content: content)
            (webView as? NativePopupWKWebView)?.relinquishTextInputFocus()
            webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }

        if context.coordinator.scale != scale {
            context.coordinator.scale = scale
            webView.evaluateJavaScript("""
            \(scaleCSSSetPropertyScript(for: scale))
            if (typeof syncButtonFrames === 'function') requestAnimationFrame(syncButtonFrames);
            """)
        }

        if context.coordinator.lastTwoColumnLayout != twoColumnLayout {
            context.coordinator.lastTwoColumnLayout = twoColumnLayout
            webView.evaluateJavaScript("window.hoshiSetTwoColumnLayout?.(\(twoColumnLayout ? "true" : "false"))")
        }

        if context.coordinator.clearSelection != clearSelection {
            context.coordinator.clearSelection = clearSelection
            webView.evaluateJavaScript("window.hoshiSelection.clearSelection()")
        }

        if context.coordinator.lastBackTrigger != backTrigger {
            context.coordinator.lastBackTrigger = backTrigger
            webView.evaluateJavaScript("window.navigateBack()")
        }

        if context.coordinator.lastForwardTrigger != forwardTrigger {
            context.coordinator.lastForwardTrigger = forwardTrigger
            webView.evaluateJavaScript("window.navigateForward()")
        }

        if context.coordinator.lastDictionaryEntryNavigationSequence != dictionaryEntryNavigationCommand?.sequence,
           let command = dictionaryEntryNavigationCommand {
            context.coordinator.lastDictionaryEntryNavigationSequence = command.sequence
            webView.evaluateJavaScript("window.hoshiMoveDictionaryEntry(\(command.direction), \(command.count))")
        }

        if context.coordinator.lastAnkiNoteCommandSequence != ankiNoteCommand?.sequence,
           let command = ankiNoteCommand {
            context.coordinator.lastAnkiNoteCommandSequence = command.sequence
            webView.evaluateJavaScript(
                "window.hoshiShowAnkiNoteButton(\(command.entryIndex), '\(command.noteID)')"
            )
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        (webView as? NativePopupWKWebView)?.relinquishTextInputFocus()
        Task {
            await WordAudioPlayer.shared.stop(id: coordinator.id)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "openLink")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "textSelected")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tapOutside")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "swipeDismiss")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playWordAudio")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "audioSourceMenu")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "buttonFrames")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "prepareContextMining")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "miningFeedback")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mineEntry", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "openAnkiNote", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "duplicateCheck", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "getEntries", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lookupRedirect", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kanjiRedirect", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "queryTextSelected", contentWorld: .page)
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        var parent: PopupWebView
        var currentContent: String = ""
        var loadConfiguration = ""
        var wasLoaded = false
        var clearSelection = false
        var lastBackTrigger = false
        var lastForwardTrigger = false
        var lastTwoColumnLayout: Bool?
        var lastDictionaryEntryNavigationSequence: Int?
        var lastAnkiNoteCommandSequence: Int?
        var scale: CGFloat = 1
        var entries: [[String: Any]] = []
        weak var webView: WKWebView?
        private var buttons: [String: NSButton] = [:]
        private var pendingButtonFrameSync = false
        let id = UUID()

        init(parent: PopupWebView) {
            self.parent = parent
        }

        private func updateButtons(_ frames: [[String: Any]], in webView: WKWebView) {
            var activeKeys = Set<String>()
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13 * scale, weight: .medium)

            for frame in frames {
                guard let kind = frame["kind"] as? String,
                      let entryIndex = frame["entryIndex"] as? Int,
                      let x = frame["x"] as? CGFloat,
                      let y = frame["y"] as? CGFloat,
                      let width = frame["width"] as? CGFloat,
                      let height = frame["height"] as? CGFloat,
                      width > 0, height > 0 else {
                    continue
                }

                let key = "\(kind)-\(entryIndex)"
                activeKeys.insert(key)

                let button: NSButton
                if let existing = buttons[key] {
                    button = existing
                } else {
                    button = NSButton()
                    button.isBordered = false
                    button.bezelStyle = .regularSquare
                    button.imagePosition = .imageOnly
                    button.setButtonType(.momentaryChange)
                    button.target = self
                    button.action = #selector(buttonTapped(_:))
                    button.contentTintColor = .secondaryLabelColor
                    buttons[key] = button
                    webView.addSubview(button)
                }

                button.identifier = NSUserInterfaceItemIdentifier("\(kind):\(entryIndex)")
                button.toolTip = switch kind {
                case "audio": String(localized: "Play Audio")
                case "context": String(localized: "Select Context")
                case "viewNote": String(localized: "View added note in Anki")
                default: String(localized: "Add to Anki")
                }
                button.setAccessibilityLabel(button.toolTip)
                button.frame = CGRect(x: x, y: webView.bounds.height - y - height, width: width, height: height)
                let state = frame["state"] as? String ?? "default"
                button.image = NSImage(systemSymbolName: symbolName(kind: kind, state: state), accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                button.isEnabled = frame["enabled"] as? Bool ?? true
                button.alphaValue = button.isEnabled ? 0.85 : 0.55
            }

            for key in buttons.keys.filter({ !activeKeys.contains($0) }) {
                buttons.removeValue(forKey: key)?.removeFromSuperview()
            }
        }

        /// Mac counterpart of upstream's long-press audio menu: lists every result of every enabled source.
        private func showAudioSourceMenu(_ body: [String: Any], in webView: WKWebView) {
            guard let entryIndex = body["entryIndex"] as? Int else { return }
            let names = body["names"] as? [String] ?? []
            let selected = body["selected"] as? Int ?? -1
            let x = body["x"] as? CGFloat ?? 0
            let y = body["y"] as? CGFloat ?? 0

            let menu = NSMenu()
            if names.isEmpty {
                let item = NSMenuItem(title: String(localized: "No audio found"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for (index, name) in names.enumerated() {
                    let item = NSMenuItem(title: name, action: #selector(audioSourceSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.state = index == selected ? .on : .off
                    item.representedObject = [entryIndex, index]
                    menu.addItem(item)
                }
            }
            let location = webView.isFlipped ? NSPoint(x: x, y: y) : NSPoint(x: x, y: webView.bounds.height - y)
            menu.popUp(positioning: nil, at: location, in: webView)
        }

        @objc private func audioSourceSelected(_ sender: NSMenuItem) {
            guard let indices = sender.representedObject as? [Int], indices.count == 2 else { return }
            webView?.evaluateJavaScript("playEntryAudio(\(indices[0]), \(indices[1]))")
        }

        private func symbolName(kind: String, state: String) -> String {
            if kind == "audio" {
                return state == "error" ? "speaker.slash" : "speaker.wave.2"
            }
            if kind == "context" {
                return "rectangle.stack.badge.plus"
            }
            if kind == "viewNote" {
                return "magnifyingglass"
            }
            return state == "duplicate" ? "plus.square.on.square" : "plus.square"
        }

        @objc private func buttonTapped(_ sender: NSButton) {
            guard let identifier = sender.identifier?.rawValue,
                  let separator = identifier.firstIndex(of: ":"),
                  let entryIndex = Int(identifier[identifier.index(after: separator)...]) else { return }
            let kind = String(identifier[..<separator])
            let action = switch kind {
            case "audio": "playEntryAudio"
            case "context": "prepareContextMiningAtIndex"
            case "viewNote": "openAnkiNoteAtIndex"
            default: "mineEntryAtIndex"
            }
            webView?.evaluateJavaScript("\(action)(\(entryIndex))")
        }

        func requestButtonFrameSync(in webView: WKWebView) {
            guard !pendingButtonFrameSync else { return }
            pendingButtonFrameSync = true
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.pendingButtonFrameSync = false
                webView.evaluateJavaScript("if (typeof syncButtonFrames === 'function') requestAnimationFrame(syncButtonFrames);")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            entries = parent.lookupEntries
            let duplicateSymbolDataURL = PopupSystemSymbolRenderer.duplicateSymbolDataURL ?? ""
            let viewNoteSymbolDataURL = PopupSystemSymbolRenderer.viewNoteSymbolDataURL ?? ""
            webView.callAsyncJavaScript(
                """
                window.hoshiUseViewportButtonFrames = true;
                window.hoshiUseInlineActionButtons = true;
                window.hoshiInlineButtonSymbols = {
                    duplicate: duplicateSymbolDataURL || null,
                    viewNote: viewNoteSymbolDataURL || null
                };
                window.contextMiningAvailable = contextMiningAvailable;
                window.contextMiningLabel = contextMiningLabel;
                window.viewAnkiNoteLabel = viewAnkiNoteLabel;
                window.hoshiLabels = hoshiLabels;
                window.dictionaryStyles = dictionaryStyles;
                window.entryCount = entryCount;
                window.twoColumnLayout = twoColumnLayout;
                window.hoshiSelection.registerModifierTracking();
                window.hoshiSelection.registerShiftHoverLookup(16, hoverLookupDelayMs);
                window.renderPopup();
                window.hoshiSetTwoColumnLayout?.(twoColumnLayout);
                """,
                arguments: [
                    "dictionaryStyles": parent.dictionaryStyles,
                    "entryCount": entries.count,
                    "twoColumnLayout": parent.twoColumnLayout,
                    "hoverLookupDelayMs": parent.hoverLookupDelayMs,
                    "contextMiningAvailable": parent.onPrepareContextMining != nil,
                    "contextMiningLabel": String(localized: "Select Context"),
                    "viewAnkiNoteLabel": String(localized: "View added note in Anki"),
                    "hoshiLabels": [
                        "average": String(localized: "Average"),
                        "playAudio": String(localized: "Play Audio"),
                        "addToAnki": String(localized: "Add to Anki"),
                        "preparingCard": String(localized: "Preparing card…"),
                        "unknownError": String(localized: "Unknown error"),
                        "prepareCardFailed": String(localized: "Unable to prepare the card: %@"),
                    ],
                    "duplicateSymbolDataURL": duplicateSymbolDataURL,
                    "viewNoteSymbolDataURL": viewNoteSymbolDataURL,
                ],
                in: nil,
                in: .page,
                completionHandler: { _ in
                    webView.evaluateJavaScript("window.hoshiResetDictionaryEntryFocus?.();")
                }
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            if message.name == "mineEntry", let content = message.body as? [String: String] {
                let result = await parent.onMine?(content) ?? .failed(String(localized: "Unable to add card."))
                return (result.webPayload, nil)
            }
            if message.name == "openAnkiNote",
               let noteIDStrings = message.body as? [String] {
                let noteIDs = noteIDStrings.compactMap(Int64.init)
                (message.webView as? NativePopupWKWebView)?.relinquishTextInputFocus()
                await Task.yield()
                return (await AnkiManager.shared.openNotesInAnki(noteIDs), nil)
            }
            if message.name == "duplicateCheck", let word = message.body as? String {
                return (await AnkiManager.shared.duplicateLookup(word: word).webPayload, nil)
            }
            if message.name == "getEntries", let body = message.body as? [String: Any] {
                let start = body["start"] as? Int ?? 0
                let count = body["count"] as? Int ?? 0
                guard start >= 0, count >= 0, start + count <= entries.count else {
                    return ([], nil)
                }
                return (Array(entries[start..<start + count]), nil)
            }
            if message.name == "lookupRedirect", let query = message.body as? String {
                entries = parent.onRedirect?(query) ?? []
                return (entries.count, nil)
            }
            if message.name == "kanjiRedirect", let kanji = message.body as? String {
                return (parent.onKanjiRedirect?(kanji) ?? nil, nil)
            }
            if message.name == "queryTextSelected",
               let body = message.body as? [String: Any],
               let query = body["text"] as? String,
               let result = parent.onQueryTextSelected?(query) {
                entries = result.entries
                return ([
                    "entryCount": entries.count,
                    "matchedCharacterCount": result.matchedCharacterCount,
                ], nil)
            }
            return (nil, nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "openLink", let urlString = message.body as? String,
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            } else if message.name == "tapOutside" {
                parent.onTapOutside?()
                message.webView?.evaluateJavaScript("window.hoshiSelection.clearLookupSelection?.()")
            } else if message.name == "swipeDismiss" {
                parent.onSwipeDismiss?()
            } else if message.name == "audioSourceMenu",
                      let body = message.body as? [String: Any],
                      let webView = message.webView {
                showAudioSourceMenu(body, in: webView)
            } else if message.name == "buttonFrames",
                      let frames = message.body as? [[String: Any]] {
                guard let webView = message.webView else { return }
                updateButtons(frames, in: webView)
            } else if message.name == "prepareContextMining",
                      let content = message.body as? [String: String] {
                parent.onPrepareContextMining?(content)
            } else if message.name == "miningFeedback",
                      let body = message.body as? [String: String],
                      let statusValue = body["status"],
                      let status = AnkiMiningStatus(rawValue: statusValue) {
                let result = AnkiMiningResult(
                    status: status,
                    message: body["message"] ?? "",
                    noteID: body["noteID"].flatMap(Int64.init)
                )
                if status == .failed {
                    print("Popup Anki mining failed before submission: \(result.message)")
                }
                parent.onMiningFeedback?(result)
            } else if message.name == "textSelected" {
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let sentence = body["sentence"] as? String,
                      let rectData = body["rect"] as? [String: Any],
                      let x = rectData["x"] as? CGFloat,
                      let y = rectData["y"] as? CGFloat,
                      let w = rectData["width"] as? CGFloat,
                      let h = rectData["height"] as? CGFloat else {
                    return
                }
                let rect = CGRect(x: parent.position.x + x, y: parent.position.y + y, width: w, height: h)
                let selectionData = SelectionData(
                    text: text,
                    sentence: sentence,
                    rect: rect,
                    miningContext: MiningContextSelection.decode(body["miningContext"])
                )

                if let highlightCount = parent.onTextSelected?(selectionData) {
                    message.webView?.evaluateJavaScript("window.hoshiSelection.highlightSelection(\(highlightCount))")
                }
            } else if message.name == "playWordAudio",
                      let content = message.body as? [String: Any],
                      let urlString = content["url"] as? String {
                let requestedMode = (content["mode"] as? String).flatMap(AudioPlaybackMode.init) ?? .interrupt
                Task(priority: .userInitiated) {
                    await WordAudioPlayer.shared.play(urlString: urlString, requestedMode: requestedMode, id: self.id)
                }
            }
        }
    }

    private var kanjiLookupEnabled: Bool {
        onKanjiRedirect != nil && LookupEngine.shared.hasKanjiDictionaries
    }

    private func constructHtml(content: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <link rel="stylesheet" href="popup.css">
            <style>
                \(FontManager.shared.fontfaceCSS)
                :root {
                    \(scaleCSSDeclarations(for: scale))
                }
            </style>
            <script>
                window.scanNonJapaneseText = \(scanNonJapaneseText);
                window.scanLength = \(scanLength);
                window.kanjiLookupEnabled = \(kanjiLookupEnabled);
                window.twoColumnLayout = \(twoColumnLayout);
            </script>
            <script src="selection.js"></script>
            <script>window.hoshiSelection.language = '\(contentLanguageID)';</script>
            <script src="popup.js"></script>
        </head>
        <body>
            \(content)
            <div class="overlay">
                <div class="overlay-close" onclick="closeOverlay()">×</div>
                <div class="overlay-content"></div>
            </div>
        </body>
        </html>
        """
    }

    private func scaleCSSDeclarations(for scale: CGFloat) -> String {
        scaleCSSVariables(for: scale)
            .map { "\($0.key): \($0.value);" }
            .joined(separator: "\n                    ")
    }

    private func scaleCSSSetPropertyScript(for scale: CGFloat) -> String {
        scaleCSSVariables(for: scale)
            .map {
                """
                document.documentElement.style.setProperty('\($0.key)', '\($0.value)');
                document.body?.style.setProperty('\($0.key)', '\($0.value)');
                """
            }
            .joined(separator: "\n            ")
    }

    private func scaleCSSVariables(for scale: CGFloat) -> [(key: String, value: String)] {
        func number(_ value: CGFloat) -> String {
            String(format: "%.3f", Double(value))
        }

        func px(_ value: CGFloat) -> String {
            "\(number(value * scale))px"
        }

        return [
            ("--popup-scale", number(scale)),
            ("--popup-root-font-size", px(16)),
            ("--popup-body-font-size", px(15)),
            ("--popup-dictionary-font-size", px(14)),
            ("--popup-expression-font-size", px(26)),
            ("--popup-expression-reading-size", px(13)),
            ("--popup-tag-font-size", px(11)),
            ("--popup-small-tag-font-size", px(10)),
            ("--popup-dict-label-font-size", px(10)),
            ("--popup-pitch-font-size", px(13)),
            ("--popup-arrow-size", px(8)),
            ("--popup-overlay-close-size", px(20)),
            ("--popup-button-size", px(28)),
            ("--popup-space-1", px(1)),
            ("--popup-space-2", px(2)),
            ("--popup-space-3", px(3)),
            ("--popup-space-4", px(4)),
            ("--popup-space-5", px(5)),
            ("--popup-space-6", px(6)),
            ("--popup-space-8", px(8)),
            ("--popup-space-10", px(10)),
            ("--popup-space-18", px(18)),
            ("--popup-space-20", px(20)),
            ("--popup-space-neg-2", px(-2)),
            ("--popup-space-neg-4", px(-4))
        ]
    }
}
