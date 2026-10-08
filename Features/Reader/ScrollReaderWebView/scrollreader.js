//
//  scrollreader.js
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

window.hoshiReader = {
    ttuRegexNegated: /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]+/gimu,
    ttuRegex: /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]/iu,
    sharedRegexNegated: /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ가-힣ㄱ-ㆎ\p{Radical}\p{Unified_Ideograph}]+/gimu,
    sharedRegex: /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ가-힣ㄱ-ㆎ\p{Radical}\p{Unified_Ideograph}]/iu,
    sharedSyncCoordinates: false,
    activeCueId: null,
    cueWrappers: new Map(),
    nodeStartOffsets: new WeakMap(),
    nodeStartNativeOffsets: new WeakMap(),
    nodeStartRawOffsets: new WeakMap(),
    
    isVertical() {
        return window.getComputedStyle(document.body).writingMode === "vertical-rl";
    },
    
    isFurigana(node) {
        const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
        return !!el?.closest('rt, rp');
    },
    
    countChars(text) {
        return Array.from(this.normalizeText(text)).length;
    },

    countNativeChars(text) {
        return Array.from(text.replace(this.ttuRegexNegated, '')).length;
    },
    
    countRawChars(text) {
        return Array.from(text).length;
    },
    
    normalizeText(text) {
        return text.replace(this.sharedSyncCoordinates ? this.sharedRegexNegated : this.ttuRegexNegated, '');
    },
    
    isMatchableChar(char) {
        return (this.sharedSyncCoordinates ? this.sharedRegex : this.ttuRegex).test(char || '');
    },

    rangeForCharacter(node, characterIndex) {
        // Bookmarks count normalized code points; DOM Range offsets count UTF-16 units.
        let index = 0;
        let offset = 0;
        for (const char of node.textContent) {
            const next = offset + char.length;
            if (this.isMatchableChar(char)) {
                if (index === characterIndex) {
                    const range = document.createRange();
                    range.setStart(node, offset);
                    range.setEnd(node, next);
                    return range;
                }
                index += 1;
            }
            offset = next;
        }
        return null;
    },
    
    createWalker(rootNode) {
        const root = rootNode || document.body;
        
        return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => this.isFurigana(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        });
    },
    
    getRect(target) {
        const rect = target.getClientRects()[0];
        return rect || target.getBoundingClientRect();
    },
    
    scrollToTarget(target) {
        const rect = this.getRect(target);
        
        if (this.isVertical()) {
            if (rect.left >= 0 && rect.right <= window.innerWidth) {
                return false;
            }
            
            target.scrollIntoView({ block: 'start', inline: 'nearest' });
            return true;
        }
        
        if (rect.top >= 0 && rect.bottom <= window.innerHeight) {
            return false;
        }
        
        target.scrollIntoView({ block: 'start', inline: 'nearest' });
        return true;
    },
    
    buildNodeOffsets() {
        const offsets = new WeakMap();
        const nativeOffsets = new WeakMap();
        const rawOffsets = new WeakMap();
        const walker = this.createWalker();
        let count = 0;
        let nativeCount = 0;
        let rawCount = 0;
        let node;
        
        while (node = walker.nextNode()) {
            offsets.set(node, count);
            nativeOffsets.set(node, nativeCount);
            rawOffsets.set(node, rawCount);
            count += this.countChars(node.textContent);
            nativeCount += this.countNativeChars(node.textContent);
            rawCount += this.countRawChars(node.textContent);
        }
        
        this.nodeStartOffsets = offsets;
        this.nodeStartNativeOffsets = nativeOffsets;
        this.nodeStartRawOffsets = rawOffsets;
    },
    
    calculateProgress() {
        var vertical = this.isVertical();
        var walker = this.createWalker();
        var totalChars = 0;
        var exploredChars = 0;
        var node;
        
        while (node = walker.nextNode()) {
            var nodeLen = this.countChars(node.textContent);
            totalChars += nodeLen;
            
            if (nodeLen > 0) {
                var range = document.createRange();
                range.selectNodeContents(node);
                var rect = range.getBoundingClientRect();
                if (vertical ? (rect.left > window.innerWidth) : (rect.bottom < 0)) {
                    exploredChars += nodeLen;
                }
            }
        }
        
        return totalChars > 0 ? exploredChars / totalChars : 0;
    },
    
    collectSasayakiCueRanges(cues) {
        const cueRanges = new Map();
        if (!cues.length) {
            return [];
        }
        
        let index = 0;
        let current = cues[0];
        let start = current.start;
        let end = start + current.length;
        let cursor = 0;
        let segment = null;
        
        const flushSegment = (node) => {
            if (!segment) {
                return;
            }
            
            const ranges = cueRanges.get(segment.id) || [];
            ranges.push({ node, start: segment.start, end: segment.end });
            cueRanges.set(segment.id, ranges);
            segment = null;
        };
        
        const advanceCue = () => {
            index += 1;
            current = cues[index];
            if (current) {
                start = current.start;
                end = start + current.length;
            }
        };
        
        let node;
        const walker = this.createWalker();
        while (current && (node = walker.nextNode())) {
            const text = node.textContent;
            let i = 0;
            while (i < text.length && current) {
                const char = String.fromCodePoint(text.codePointAt(i));
                const next = i + char.length;
                if (this.isMatchableChar(char)) {
                    if (cursor >= start && cursor < end) {
                        if (!segment) {
                            segment = { id: current.id, start: i, end: next };
                        } else {
                            segment.end = next;
                        }
                    } else {
                        flushSegment(node);
                    }
                    cursor += 1;
                    if (cursor === end) {
                        flushSegment(node);
                        advanceCue();
                    }
                } else if (segment) {
                    segment.end = next;
                } else if (cursor > start && cursor < end) {
                    segment = { id: current.id, start: i, end: next };
                }
                i = next;
            }
            flushSegment(node);
        }
        
        return cues.map(cue => ({
            id: cue.id,
            ranges: cueRanges.get(cue.id) || []
        }));
    },
    
    applySasayakiCues(cues) {
        this.resetSasayakiCues();
        
        const cueRanges = this.collectSasayakiCueRanges(cues);
        const range = document.createRange();
        for (let i = cueRanges.length - 1; i >= 0; i--) {
            const { id, ranges } = cueRanges[i];
            if (!ranges.length) {
                continue;
            }
            
            const wrappers = [];
            for (let j = ranges.length - 1; j >= 0; j--) {
                const segment = ranges[j];
                range.setStart(segment.node, segment.start);
                range.setEnd(segment.node, segment.end);
                
                const wrapper = document.createElement('span');
                wrapper.className = 'hoshi-sasayaki-cue';
                wrapper.appendChild(range.extractContents());
                range.insertNode(wrapper);
                
                wrappers.push(wrapper);
            }
            wrappers.reverse();
            this.cueWrappers.set(id, wrappers);
        }
        
        this.buildNodeOffsets();
    },
    
    highlightSasayakiCue(cueId, reveal) {
        this.clearSasayakiCue();
        
        const wrappers = this.cueWrappers.get(cueId);
        if (!wrappers?.length) {
            return null;
        }
        
        this.activeCueId = cueId;
        wrappers.forEach(wrapper => wrapper.classList.add('hoshi-sasayaki-active'));
        
        if (reveal && this.scrollToTarget(wrappers[0])) {
            return this.calculateProgress();
        }
        
        return null;
    },
    
    clearSasayakiCue() {
        if (!this.activeCueId) {
            return;
        }
        
        const wrappers = this.cueWrappers.get(this.activeCueId) || [];
        wrappers.forEach(wrapper => wrapper.classList.remove('hoshi-sasayaki-active'));
        this.activeCueId = null;
    },
    
    resetSasayakiCues() {
        this.cueWrappers.forEach(wrappers => this.unwrap(wrappers));
        this.cueWrappers.clear();
        this.activeCueId = null;
    },
    
    unwrap(wrappers) {
        wrappers.forEach(wrapper => {
            const parent = wrapper.parentNode;
            if (!parent) {
                return;
            }
            while (wrapper.firstChild) {
                parent.insertBefore(wrapper.firstChild, wrapper);
            }
            parent.removeChild(wrapper);
            parent.normalize();
        });
    },
    
    registerCopyText() {
        if (window.copyTextRegistered) {
            return;
        }
        window.copyTextRegistered = true
        document.addEventListener('copy', function (event) {
            const text = window.hoshiReader.getCopyText();
            if (!text) {
                return;
            }
            event.preventDefault();
            event.clipboardData.setData('text/plain', text);
        }, true);
    },

    getCopyText() {
        const selection = window.getSelection();
        if (selection && selection.rangeCount > 0 && !selection.isCollapsed) {
            const fragment = selection.getRangeAt(0).cloneContents();
            fragment.querySelectorAll('rt, rp').forEach(el => el.remove());
            const text = fragment.textContent?.trim();
            if (text) {
                return text;
            }
        }

        return window.hoshiSelection?.selection?.text?.trim() || '';
    },
    
    notifyRestoreComplete() {
        window.webkit?.messageHandlers?.restoreCompleted?.postMessage(window.hoshiReaderRestoreToken ?? null);
    },

    async restoreProgress(progress) {
        await document.fonts.ready;
        if (progress <= 0) {
            this.notifyRestoreComplete();
            return;
        }
        
        var vertical = this.isVertical();
        var walker = this.createWalker();
        var totalChars = 0;
        var node;
        
        while (node = walker.nextNode()) {
            totalChars += this.countChars(node.textContent);
        }
        
        if (totalChars <= 0) {
            this.notifyRestoreComplete();
            return;
        }
        
        // A near-end fraction may round to totalChars, past the final readable glyph.
        var targetCharCount = Math.min(Math.ceil(totalChars * progress), totalChars - 1);
        var runningSum = 0;
        var targetNode = null;
        var targetOffset = 0;
        
        walker = this.createWalker();
        while (node = walker.nextNode()) {
            targetNode = node;
            var nodeLength = this.countChars(node.textContent);
            if (runningSum + nodeLength > targetCharCount) {
                targetOffset = targetCharCount - runningSum;
                break;
            }
            runningSum += nodeLength;
        }
        
        if (targetNode) {
            if (progress >= 0.999999) {
                targetNode.parentElement?.scrollIntoView({ block: 'end', behavior: 'instant' });
                // A large paragraph's end can leave its final readable glyph
                // outside the viewport in vertical writing. Keep the end
                // alignment, then bring that precise glyph into view.
                const range = this.rangeForCharacter(targetNode, targetOffset);
                if (range) {
                    const rect = range.getBoundingClientRect();
                    if (rect.width > 0 && rect.height > 0) {
                        const left = vertical
                            ? (rect.left < 0 ? Math.floor(rect.left) : Math.max(0, Math.ceil(rect.right - window.innerWidth)))
                            : 0;
                        const top = vertical
                            ? 0
                            : (rect.top < 0 ? Math.floor(rect.top) : Math.max(0, Math.ceil(rect.bottom - window.innerHeight)));
                        if (left || top) {
                            window.scrollBy({ left, top, behavior: 'instant' });
                        }
                    }
                }
            } else {
                const range = this.rangeForCharacter(targetNode, targetOffset);
                if (range) {
                    const rect = range.getBoundingClientRect();
                    window.scrollBy({
                        left: vertical ? rect.right - window.innerWidth : 0,
                        top: vertical ? 0 : rect.top,
                        behavior: 'instant'
                    });
                }
            }
        }
        
        requestAnimationFrame(() => {
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
    },
    
    async jumpToFragment(fragment) {
        await document.fonts.ready;
        var rawFragment = (fragment || '').trim();
        var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
        
        if (!target) {
            this.notifyRestoreComplete();
            return false;
        }
        
        target.scrollIntoView();
        requestAnimationFrame(() => {
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
        return true;
    }
};
