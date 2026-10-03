//
//  selection.js
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

// https://github.com/yomidevs/yomitan/blob/ddbe4a2c0bf778583b38962d4b0b85442dfa8f6a/ext/js/language/CJK-util.js#L19
const CJK_UNIFIED_IDEOGRAPHS_RANGE = [0x4e00, 0x9fff];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_A_RANGE = [0x3400, 0x4dbf];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_B_RANGE = [0x20000, 0x2a6df];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_C_RANGE = [0x2a700, 0x2b73f];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_D_RANGE = [0x2b740, 0x2b81f];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_E_RANGE = [0x2b820, 0x2ceaf];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_F_RANGE = [0x2ceb0, 0x2ebef];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_G_RANGE = [0x30000, 0x3134f];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_H_RANGE = [0x31350, 0x323af];
const CJK_UNIFIED_IDEOGRAPHS_EXTENSION_I_RANGE = [0x2ebf0, 0x2ee5f];
const CJK_COMPATIBILITY_IDEOGRAPHS_RANGE = [0xf900, 0xfaff];
const CJK_COMPATIBILITY_IDEOGRAPHS_SUPPLEMENT_RANGE = [0x2f800, 0x2fa1f];
const CJK_IDEOGRAPH_RANGES = [
    CJK_UNIFIED_IDEOGRAPHS_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_A_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_B_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_C_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_D_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_E_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_F_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_G_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_H_RANGE,
    CJK_UNIFIED_IDEOGRAPHS_EXTENSION_I_RANGE,
    CJK_COMPATIBILITY_IDEOGRAPHS_RANGE,
    CJK_COMPATIBILITY_IDEOGRAPHS_SUPPLEMENT_RANGE,
];

// https://github.com/yomidevs/yomitan/blob/ddbe4a2c0bf778583b38962d4b0b85442dfa8f6a/ext/js/language/CJK-util.js#L60
const FULLWIDTH_CHARACTER_RANGES = [
    [0xff10, 0xff19], // Fullwidth numbers
    [0xff21, 0xff3a], // Fullwidth upper case Latin letters
    [0xff41, 0xff5a], // Fullwidth lower case Latin letters

    [0xff01, 0xff0f], // Fullwidth punctuation 1
    [0xff1a, 0xff1f], // Fullwidth punctuation 2
    [0xff3b, 0xff3f], // Fullwidth punctuation 3
    [0xff5b, 0xff60], // Fullwidth punctuation 4
    [0xffe0, 0xffee], // Currency markers
];

// https://github.com/yomidevs/yomitan/blob/ddbe4a2c0bf778583b38962d4b0b85442dfa8f6a/ext/js/language/ja/japanese.js#L44
const JAPANESE_RANGES = [
    [0x3040, 0x309f], // Hiragana
    [0x30a0, 0x30ff], // Katakana

    ...CJK_IDEOGRAPH_RANGES, // CJK_IDEOGRAPH_RANGES

    [0xff66, 0xff9f], // Halfwidth katakana

    [0x30fb, 0x30fc], // Katakana punctuation
    [0xff61, 0xff65], // Kana punctuation

    [0x3000, 0x303f], // CJK_PUNCTUATION_RANGE
    ...FULLWIDTH_CHARACTER_RANGES, // FULLWIDTH_CHARACTER_RANGES
];

const EnglishScanDelimiters = '"“”„‟\'‘’‚‛«»‹›!?—–-‐‑‒/\\|@#$%^&*_+=~`<>';
const EnglishWordInternalDelimiters = '\'’`-‐‑';

function isEnglishWordChar(char) {
    return !!char && /[A-Za-z0-9]/.test(char);
}

window.hoshiSelection = {
    language: 'ja',
    selection: null,
    highlight: null,
    shiftKeyPressed: false,
    hoverTimer: null,
    lastPointer: null,
    shiftHoverConfig: null,
    fallbackHighlights: [],
    miningContextCache: new WeakMap(),
    scanDelimiters: '。、！？…‥「」『』（）()【】〈〉《》〔〕｛｝{}［］[]・：；:;，,.─\n\r',
    sentenceDelimiters: '。！？.!?\n\r',
    trailingSentenceChars: '。、！？…‥」』）)】〉》〕｝}］]',
    brackets: {'「':'」', '『': '』', '（':'）', '(':')', '【':'】', '〈':'〉', '《':'》', '〔':'〕', '｛':'｝', '{':'}', '［':'］', '[':']'},

    notifySelectionState(hasSelection) {
        lastHasSelection = hasSelection;
        try { window.webkit?.messageHandlers?.selectionState?.postMessage(hasSelection); } catch {}
    },

    isVertical() {
        return window.getComputedStyle(document.body).writingMode === "vertical-rl";
    },

    // https://github.com/yomidevs/yomitan/blob/ddbe4a2c0bf778583b38962d4b0b85442dfa8f6a/ext/js/language/ja/japanese.js#L307
    isCodePointJapanese(codePoint) {
        return JAPANESE_RANGES.some(([start, end]) => codePoint >= start && codePoint <= end);
    },

    isScanBoundary(char) {
        return /^[\s\u3000]$/.test(char) ||
        this.scanDelimiters.includes(char) ||
        (window.scanNonJapaneseText === false && !this.isCodePointJapanese(char.codePointAt(0)));
    },

    isEnglishScanBoundaryAt(text, offset) {
        const char = text[offset];
        const isInternal = EnglishWordInternalDelimiters.includes(char) &&
            isEnglishWordChar(text[offset - 1]) &&
            isEnglishWordChar(text[offset + 1]);
        return this.scanDelimiters.includes(char) ||
            (EnglishScanDelimiters.includes(char) && !isInternal);
    },

    isScanBoundaryAt(text, offset) {
        if (this.language === 'en') {
            return this.isEnglishScanBoundaryAt(text, offset);
        }
        return this.isScanBoundary(text[offset]);
    },

    isHitBoundaryAt(text, offset) {
        if (this.language === 'en') {
            return /^[\s\u3000]$/.test(text[offset]) || this.isEnglishScanBoundaryAt(text, offset);
        }
        return this.isScanBoundary(text[offset]);
    },

    findEnglishWordStart(hit) {
        const text = hit.node.textContent;
        let offset = hit.offset;
        while (offset > 0 && !this.isHitBoundaryAt(text, offset - 1)) {
            offset -= 1;
        }
        return { node: hit.node, offset };
    },

    isFurigana(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('rt, rp');
    },

    revealFurigana(ruby) {
        const group = [ruby];
        for (const direction of ['previousSibling', 'nextSibling']) {
            let node = ruby[direction];
            while (node && (node.localName === 'ruby' ||
                            (node.nodeType === Node.TEXT_NODE && /^[\t\n\r ]*$/.test(node.nodeValue)))) {
                if (node.localName === 'ruby') {
                    group.push(node);
                }
                node = node[direction];
            }
        }
        group.forEach(el => el.classList.remove('furigana-hidden'));
    },

    findParagraph(node) {
        let el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return el?.closest('p, .kanji-entry li, .glossary-content, .expr-tag, .dictionary-query-source') || null;
    },

    createWalker(rootNode) {
        const root = rootNode || document.body;

        return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => this.isFurigana(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        });
    },

    miningContextScope(node) {
        const element = node?.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return element?.closest('.glossary-content') || document.body;
    },

    miningContextBlock(node, scope) {
        const element = node.parentElement;
        return element?.closest('p, li, blockquote, h1, h2, h3, h4, h5, h6, figcaption, pre') || scope;
    },

    isMiningContextTextNode(node) {
        const element = node.parentElement;
        return !!element && !element.closest('rt, rp, script, style, noscript, svg, button');
    },

    miningContextSentences(text) {
        const ranges = [];
        let start = 0;
        const append = (end) => {
            let trimmedStart = start;
            let trimmedEnd = end;
            while (trimmedStart < trimmedEnd && /\s/.test(text[trimmedStart])) trimmedStart += 1;
            while (trimmedEnd > trimmedStart && /\s/.test(text[trimmedEnd - 1])) trimmedEnd -= 1;
            if (trimmedStart < trimmedEnd) {
                ranges.push({
                    start: trimmedStart,
                    end: trimmedEnd,
                    text: text.slice(trimmedStart, trimmedEnd)
                });
            }
            start = end;
        };

        for (let i = 0; i < text.length; i++) {
            if (!this.sentenceDelimiters.includes(text[i])) continue;
            let end = i + 1;
            while (end < text.length && this.trailingSentenceChars.includes(text[end])) end += 1;
            append(end);
            i = end - 1;
        }
        append(text.length);
        return ranges;
    },

    miningContextData(scope) {
        const cached = this.miningContextCache.get(scope);
        if (cached) return cached;
        const walker = this.createWalker(scope);
        let text = '';
        let previousBlock = null;
        const nodeOffsets = new WeakMap();
        let node;
        while (node = walker.nextNode()) {
            if (!this.isMiningContextTextNode(node)) continue;
            const block = this.miningContextBlock(node, scope);
            if (text && previousBlock && block !== previousBlock) text += '\n';
            nodeOffsets.set(node, text.length);
            text += node.textContent;
            previousBlock = block;
        }
        const data = {
            nodeOffsets,
            sentenceRanges: this.miningContextSentences(text)
        };
        this.miningContextCache.set(scope, data);
        return data;
    },

    miningContextForSelection(targetNode, targetOffset) {
        const scope = this.miningContextScope(targetNode);
        let data = this.miningContextData(scope);
        if (!data.nodeOffsets.has(targetNode)) {
            this.miningContextCache.delete(scope);
            data = this.miningContextData(scope);
        }
        const { nodeOffsets, sentenceRanges } = data;
        const nodeOffset = nodeOffsets.get(targetNode);
        const targetTextOffset = nodeOffset === undefined ? null : nodeOffset + targetOffset;
        if (targetTextOffset === null) return null;
        const currentIndex = sentenceRanges.findIndex(({ start, end }) =>
            targetTextOffset >= start && targetTextOffset <= end
        );
        if (currentIndex < 0) return null;

        return {
            currentIndex,
            sentences: sentenceRanges.map(({ start, text }, index) => ({
                id: String(index),
                text,
                ...(index === currentIndex ? { targetLocation: Math.max(0, targetTextOffset - start) } : {})
            }))
        };
    },

    inCharRange(charRange, x, y) {
        const rects = charRange.getClientRects();
        if (rects.length) {
            for (const rect of rects) {
                if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
                    return true;
                }
            }
            return false;
        }
        const rect = charRange.getBoundingClientRect();
        return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
    },

    getCaretRange(x, y) {
        if (document.caretPositionFromPoint) {
            const pos = document.caretPositionFromPoint(x, y);
            if (!pos) {
                return null;
            }

            const range = document.createRange();
            range.setStart(pos.offsetNode, pos.offset);
            range.collapse(true);
            return range;
        } else {
            const element = document.elementFromPoint(x, y);
            if (!element) {
                return null;
            }

            const container = element.closest('p, div, span, ruby, a') || document.body;
            const walker = this.createWalker(container);

            const range = document.createRange();
            let node;
            while (node = walker.nextNode()) {
                for (let i = 0; i < node.textContent.length; i++) {
                    range.setStart(node, i);
                    range.setEnd(node, i + 1);
                    if (this.inCharRange(range, x, y)) {
                        range.collapse(true);
                        return range;
                    }
                }
            }
            return document.caretRangeFromPoint(x, y);
        }
    },

    getCharacterAtPoint(x, y) {
        const range = this.getCaretRange(x, y);
        if (!range) {
            return null;
        }

        const node = range.startContainer;
        if (node.nodeType !== Node.TEXT_NODE) {
            return null;
        }

        if (this.isFurigana(node)) {
            return null;
        }

        const text = node.textContent;
        const caret = range.startOffset;

        for (const offset of [caret, caret - 1, caret + 1]) {
            if (offset < 0 || offset >= text.length) {
                continue;
            }

            const charRange = document.createRange();
            charRange.setStart(node, offset);
            charRange.setEnd(node, offset + 1);
            if (this.inCharRange(charRange, x, y)) {
                if (this.isHitBoundaryAt(text, offset)) {
                    return null;
                }
                return { node, offset };
            }
        }

        return null;
    },

    getSentence(startNode, startOffset) {
        const container = this.findParagraph(startNode) || document.body;
        const walker = this.createWalker(container);
        walker.currentNode = startNode;
        const partsBefore = [];
        let node = startNode;
        let limit = startOffset;

        while (node) {
            const text = node.textContent;
            let foundStart = false;
            for (let i = limit - 1; i >= 0; i--) {
                if (this.sentenceDelimiters.includes(text[i])) {
                    partsBefore.push(text.slice(i + 1, limit));
                    foundStart = true;
                    break;
                }
            }

            if (foundStart) {
                break;
            }

            partsBefore.push(text.slice(0, limit));
            node = walker.previousNode();
            if (node) limit = node.textContent.length;
        }

        walker.currentNode = startNode;
        const partsAfter = [];
        node = startNode;
        let start = startOffset;

        while (node) {
            const text = node.textContent;
            let foundEnd = false;

            for (let i = start; i < text.length; i++) {
                if (this.sentenceDelimiters.includes(text[i])) {
                    let end = i + 1;

                    while (end < text.length) {
                        if (!this.trailingSentenceChars.includes(text[end])) break;
                        end += 1;
                    }
                    partsAfter.push(text.slice(start, end));
                    foundEnd = true;
                    break;
                }
            }

            if (foundEnd) {
                break;
            }

            partsAfter.push(text.slice(start));

            node = walker.nextNode();
            start = 0;
        }

        let sentence = (partsBefore.reverse().join('') + partsAfter.join('')).trim();

        const closeBrackets = new Set(Object.values(this.brackets));
        const openBrackets = new Set(Object.keys(this.brackets));
        let stack = [];
        let unmatchedClose = [];

        for (let i = 0; i < sentence.length; i++) {
            const ch = sentence[i];
            if (openBrackets.has(ch)) {
                stack.push(ch);
            } else if (closeBrackets.has(ch)) {
                if (stack.length > 0 && this.brackets[stack[stack.length-1]] === ch) {
                    stack.pop();
                } else {
                    unmatchedClose.push(ch);
                }
            }
        }

        let startSlice = 0;
        while (stack.length > 0 && startSlice < sentence.length - 1) {
            // Stack consists of unmatched open brackets arranged from start to end
            if (stack[0] === sentence[startSlice]) {
                stack.shift();
            } else break;
            startSlice++;
        }

        let endSlice = sentence.length - 1;
        let endIdx = sentence.length - 1;
        while (unmatchedClose.length > 0 && endIdx > startSlice) {
            if (unmatchedClose[unmatchedClose.length - 1] === sentence[endIdx]) {
                unmatchedClose.pop();
                endSlice = endIdx - 1;
                // sentenceDelimiters used as trailingSentenceDelimiters as it does not have any overlap with brackets
            } else if (!this.sentenceDelimiters.includes(sentence[endIdx])) break;
            endIdx--;
        }
        return sentence.slice(startSlice, endSlice + 1).trim();
    },
    selectTextAtPoint(x, y, maxLength, toggleOnSameSelection = true, onSelection = null) {
        const el = document.elementFromPoint(x, y);
        if (el?.closest('a')) {
            return 'link';
        }
        if (el?.closest('img, image, .blur-wrapper')) {
            return 'image';
        }

        const rawHit = this.getCharacterAtPoint(x, y);

        if (!rawHit) {
            this.clearSelection();
            return null;
        }
        const hit = this.language === 'en' ? this.findEnglishWordStart(rawHit) : rawHit;

        if (this.selection &&
            hit.node === this.selection.startNode &&
            hit.offset === this.selection.startOffset) {
            if (toggleOnSameSelection) {
                this.clearSelection();
                return null;
            }
            return this.selection.text;
        }

        this.clearSelection();

        const container = this.findParagraph(hit.node) || document.body;
        const walker = this.createWalker(container);

        let text = '';
        let node = hit.node;
        let offset = hit.offset;
        let ranges = [];

        walker.currentNode = node;
        while (text.length < maxLength && node) {
            const content = node.textContent;
            const start = offset;

            while (offset < content.length && text.length < maxLength) {
                const char = content[offset];
                if (this.isScanBoundaryAt(content, offset)) {
                    break;
                }
                text += char;
                offset++;
            }

            if (offset > start) {
                ranges.push({ node, start, end: offset });
            }

            if (offset < content.length || text.length >= maxLength) {
                break;
            }

            node = walker.nextNode();
            offset = 0;
        }

        if (!text) {
            return null;
        }

        this.selection = {
            startNode: hit.node,
            startOffset: hit.offset,
            ranges,
            text
        };

        const sentence = this.getSentence(hit.node, hit.offset);
        const normalizedOffset = window.hoshiReader ? this.getNormalizedOffset(hit.node, hit.offset) : null;
        const payload = {
            text,
            sentence,
            rect: this.getSelectionRect(x, y),
            normalizedOffset,
            miningContext: this.miningContextForSelection(hit.node, hit.offset)
        };
        if (onSelection) {
            onSelection(payload);
        } else {
            webkit.messageHandlers.textSelected.postMessage(payload);
        }

        return text;
    },

    selectText(x, y, maxLength) {
        const furigana = document.elementFromPoint(x, y)?.closest('ruby.furigana-hidden');
        if (furigana) {
            this.revealFurigana(furigana);
            this.clearSelection();
            return 'furigana';
        }
        return this.selectTextAtPoint(x, y, maxLength, true);
    },

    selectTextIfAllowed(x, y, maxLength, requireShift) {
        if (requireShift && !this.shiftKeyPressed) {
            this.clearSelection();
            return null;
        }
        return this.selectTextAtPoint(x, y, maxLength, true);
    },

    triggerShiftHoverLookup() {
        if (!this.shiftHoverConfig || !this.lastPointer || !this.shiftKeyPressed) {
            return;
        }

        if (this.hoverTimer) {
            clearTimeout(this.hoverTimer);
        }

        const { maxLength, hoverDelayMs } = this.shiftHoverConfig;
        const { x, y } = this.lastPointer;
        this.hoverTimer = setTimeout(() => {
            if (!this.shiftKeyPressed) {
                return;
            }
            this.selectTextAtPoint(x, y, maxLength, false);
        }, hoverDelayMs);
    },

    registerModifierTracking() {
        if (window.hoshiModifierTrackingRegistered) {
            return;
        }
        window.hoshiModifierTrackingRegistered = true;

        const updateModifierState = (pressed) => {
            this.shiftKeyPressed = pressed;
        };

        document.addEventListener('keydown', (event) => {
            if (event.key === 'Shift') {
                updateModifierState(true);
                this.triggerShiftHoverLookup();
            }
        }, true);

        document.addEventListener('keyup', (event) => {
            if (event.key === 'Shift') {
                updateModifierState(false);
            }
        }, true);

        window.addEventListener('blur', () => updateModifierState(false));
        document.addEventListener('visibilitychange', () => {
            if (document.hidden) {
                updateModifierState(false);
            }
        });
    },

    registerShiftHoverLookup(maxLength, hoverDelayMs) {
        if (window.hoshiShiftHoverLookupRegistered) {
            return;
        }
        window.hoshiShiftHoverLookupRegistered = true;
        this.shiftHoverConfig = { maxLength, hoverDelayMs };
        this.setNativeShiftPressed = (pressed) => {
            const wasPressed = this.shiftKeyPressed;
            this.shiftKeyPressed = Boolean(pressed);
            if (!this.shiftKeyPressed) {
                if (this.hoverTimer) {
                    clearTimeout(this.hoverTimer);
                    this.hoverTimer = null;
                }
                return;
            }
            if (!wasPressed) {
                this.triggerShiftHoverLookup();
            }
        };

        document.addEventListener('mousemove', (event) => {
            this.lastPointer = { x: event.clientX, y: event.clientY };
            this.shiftKeyPressed = event.shiftKey;
            if (!this.shiftKeyPressed) {
                return;
            }

            const target = event.target?.nodeType === Node.TEXT_NODE ? event.target.parentElement : event.target;
            if (!target || !target.closest('body')) {
                return;
            }

            this.triggerShiftHoverLookup();
        }, true);
    },

    clearFallbackHighlights() {
        if (!this.fallbackHighlights.length) {
            return;
        }

        this.fallbackHighlights.forEach(span => {
            const parent = span.parentNode;
            if (!parent) {
                return;
            }
            while (span.firstChild) {
                parent.insertBefore(span.firstChild, span);
            }
            parent.removeChild(span);
            parent.normalize();
        });
        this.fallbackHighlights = [];
        this.miningContextCache = new WeakMap();
    },

    applyFallbackHighlights(ranges) {
        this.clearFallbackHighlights();

        const wrappers = [];
        Array.from(ranges).reverse().forEach(range => {
            const node = range.startContainer;
            const start = range.startOffset;
            const end = range.endOffset;

            if (!node || node.nodeType !== Node.TEXT_NODE || start >= end) {
                return;
            }

            let target = node;
            if (start > 0) {
                target = target.splitText(start);
            }
            if ((end - start) < target.length) {
                target.splitText(end - start);
            }

            const span = document.createElement('span');
            span.className = 'hoshi-highlight-fallback';
            span.style.backgroundColor = 'rgba(160, 160, 160, 0.4)';
            span.style.color = 'inherit';
            target.parentNode?.replaceChild(span, target);
            span.appendChild(target);
            wrappers.push(span);
        });

        this.fallbackHighlights = wrappers.reverse();
        this.miningContextCache = new WeakMap();
    },

    getSelectionRect(x, y) {
        if (!this.selection?.ranges.length) {
            return null;
        }

        const first = this.selection.ranges[0];
        const range = document.createRange();
        range.setStart(first.node, first.start);
        range.setEnd(first.node, first.start + 1);

        const rects = Array.from(range.getClientRects());
        const rect = rects.find(rect => x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) ?? range.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
    },

    highlightSelection(charCount) {
        const supportsCSSHighlights = !!CSS.highlights && typeof Highlight !== 'undefined';
        if (supportsCSSHighlights) {
            if (!this.highlight) {
                this.highlight = new Highlight();
                CSS.highlights.set('hoshi-selection', this.highlight);
            }
            this.highlight.clear();
        }

        if (!this.selection?.ranges.length) {
            return;
        }

        const highlights = [];
        let remaining = charCount;

        for (const r of this.selection.ranges) {
            if (remaining <= 0) {
                break;
            }

            let end = r.start;
            while (end < r.end && remaining > 0) {
                const char = String.fromCodePoint(r.node.textContent.codePointAt(end));
                end += char.length;
                remaining--;
            }

            const range = document.createRange();
            range.setStart(r.node, r.start);
            range.setEnd(r.node, end);
            highlights.push(range);
        }

        this.clearFallbackHighlights();

        if (supportsCSSHighlights) {
            highlights.forEach(range => this.highlight.add(range));
            this.notifySelectionState(true);
            return;
        }

        this.applyFallbackHighlights(highlights);
        this.notifySelectionState(true);
    },

    getNormalizedOffset(targetNode, offset) {
        let count = window.hoshiReader.nodeStartOffsets.get(targetNode) ?? 0;
        const text = targetNode.textContent;
        for (let i = 0; i < offset;) {
            const char = String.fromCodePoint(text.codePointAt(i));
            if (window.hoshiReader.isMatchableChar(char)) {
                count++;
            }
            i += char.length;
        }
        return count;
    },

    clearLookupSelection() {
        this.highlight?.clear();
        this.clearFallbackHighlights();
        this.selection = null;
        this.notifySelectionState(false);
    },

    clearSelection() {
        window.getSelection()?.removeAllRanges();
        this.clearLookupSelection();
    }
};

let lastHasSelection = false;
document.addEventListener('selectionchange', () => {
    const s = getSelection();
    const hasSelection = !!s && !s.isCollapsed;
    if (hasSelection === lastHasSelection) return;
    window.hoshiSelection.notifySelectionState(hasSelection);
});
