//
//  reader.js
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

window.hoshiReader = {
    ttuRegexNegated: /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]+/gimu,
    ttuRegex: /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\p{Radical}\p{Unified_Ideograph}]/iu,
    activeCueId: null,
    cueWrappers: new Map(),
    nodeStartOffsets: new WeakMap(),
    nodeStartRawOffsets: new WeakMap(),
    horizontalPageColumns: 1,
    horizontalSpreadPageSize: null,
    horizontalTerminalPageTarget: null,
    horizontalContentMetricsCache: null,
    
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
    
    countRawChars(text) {
        return Array.from(text).length;
    },
    
    normalizeText(text) {
        return text.replace(this.ttuRegexNegated, '');
    },
    
    isMatchableChar(char) {
        return this.ttuRegex.test(char || '');
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
    
    buildNodeOffsets() {
        const offsets = new WeakMap();
        const rawOffsets = new WeakMap();
        const walker = this.createWalker();
        let count = 0;
        let rawCount = 0;
        let node;
        
        while (node = walker.nextNode()) {
            offsets.set(node, count);
            rawOffsets.set(node, rawCount);
            count += this.countChars(node.textContent);
            rawCount += this.countRawChars(node.textContent);
        }
        
        this.nodeStartOffsets = offsets;
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
                var rect = this.getRect(range);
                if ((vertical ? rect.top : rect.left) < 0) {
                    exploredChars += nodeLen;
                }
            }
        }
        
        return totalChars > 0 ? exploredChars / totalChars : 0;
    },
    
    registerSnapScroll(initialScroll) {
        if (window.snapScrollRegistered) {
            return;
        }
        window.snapScrollRegistered = true;
        window.lastPageScroll = initialScroll;
        
        var context = this.getScrollContext();
        context.scrollEl.addEventListener('scroll', function () {
            if (context.vertical) {
                var currentScroll = context.scrollEl.scrollTop;
                var snappedScroll = Math.round(currentScroll / context.pageSize) * context.pageSize;
                if (Math.abs(currentScroll - snappedScroll) > 1) {
                    context.scrollEl.scrollTop = window.lastPageScroll;
                } else {
                    window.lastPageScroll = snappedScroll;
                }
            } else {
                var currentScroll = context.scrollEl.scrollLeft;
                var snappedScroll = Math.round(currentScroll / context.pageSize) * context.pageSize;
                if (Math.abs(currentScroll - snappedScroll) > 1) {
                    context.scrollEl.scrollLeft = window.lastPageScroll;
                } else {
                    window.lastPageScroll = snappedScroll;
                }
            }
        }, { passive: true });
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

    registerWheelNavigation(enabled) {
        window.hoshiWheelNavigationEnabled = !!enabled;
        if (window.hoshiWheelNavigationRegistered) {
            return;
        }
        window.hoshiWheelNavigationRegistered = true;
        window.hoshiLastWheelNavigationTime = 0;

        const isIgnoredTarget = (target) => {
            const element = target instanceof Element ? target : target?.parentElement;
            if (!element) {
                return false;
            }
            return !!element.closest([
                'input',
                'textarea',
                'select',
                'button',
                '[contenteditable="true"]',
                '[data-hoshi-popup]',
                '.popup',
                '.dictionary-popup',
                '.popover',
                '[role="dialog"]'
            ].join(','));
        };

        document.addEventListener('wheel', function (event) {
            if (!window.hoshiWheelNavigationEnabled) {
                return;
            }
            if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) {
                return;
            }
            if (Math.abs(event.deltaX) > Math.abs(event.deltaY) || event.deltaY === 0) {
                return;
            }
            if (isIgnoredTarget(event.target)) {
                return;
            }
            if (window.getSelection && window.getSelection()?.isCollapsed === false) {
                return;
            }

            const now = Date.now();
            if (now - window.hoshiLastWheelNavigationTime < 170) {
                event.preventDefault();
                return;
            }

            const direction = event.deltaY > 0 ? 'forward' : 'backward';
            window.hoshiLastWheelNavigationTime = now;
            event.preventDefault();
            window.webkit?.messageHandlers?.wheelNavigation?.postMessage(direction);
        }, { passive: false });
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
        window.webkit?.messageHandlers?.restoreCompleted?.postMessage(null);
        this.registerPageTracking();
    },

    pageCount(context) {
        if (context.pageSize <= 0 || context.maxScroll <= context.limitTolerance) {
            return 1;
        }
        // The last page may be a partial step that stops at maxScroll.
        return Math.ceil((context.maxScroll - context.limitTolerance) / context.pageSize) + 1;
    },

    currentPageIndex() {
        const context = this.getScrollContext();
        if (context.pageSize <= 0) {
            return 0;
        }
        const pageCount = this.pageCount(context);
        const scroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
        if (scroll >= context.maxScroll - context.limitTolerance) {
            return pageCount - 1;
        }
        return Math.min(pageCount - 1, Math.max(0, Math.round(scroll / context.pageSize)));
    },

    notifyPageChanged() {
        window.webkit?.messageHandlers?.pageChanged?.postMessage(this.currentPageIndex());
    },

    registerPageTracking() {
        if (!window.webkit?.messageHandlers?.pageChanged) {
            return;
        }
        if (!this.pageTrackingRegistered) {
            this.pageTrackingRegistered = true;
            let frame = null;
            this.getScrollContext().scrollEl.addEventListener('scroll', () => {
                if (frame === null) {
                    frame = requestAnimationFrame(() => {
                        frame = null;
                        this.notifyPageChanged();
                    });
                }
            }, { passive: true });
        }
        this.notifyPageChanged();
    },

    // Spine-local character offset at which each page starts, measured on an
    // unscrolled document laid out exactly like the visible Reader.
    calculatePageStarts() {
        const context = this.getScrollContext();
        const { vertical, pageSize } = context;
        if (pageSize <= 0) {
            return [0];
        }
        const pageCount = this.pageCount(context);
        const starts = new Array(pageCount).fill(null);
        const walker = this.createWalker();
        const range = document.createRange();
        const pageOf = position => Math.min(pageCount - 1, Math.max(0, Math.floor(position / pageSize)));
        let totalChars = 0;
        let node;

        while (node = walker.nextNode()) {
            const nodeLen = this.countChars(node.textContent);
            if (!nodeLen) {
                continue;
            }
            const nodeStart = this.nodeStartOffsets.get(node) ?? totalChars;
            totalChars = nodeStart + nodeLen;
            range.selectNodeContents(node);
            for (const rect of range.getClientRects()) {
                if (!rect.width || !rect.height) {
                    continue;
                }
                const page = pageOf(vertical ? rect.top : rect.left);
                if (starts[page] !== null) {
                    continue;
                }
                let low = 0;
                let high = node.textContent.length;
                while (low < high) {
                    const mid = (low + high) >> 1;
                    range.setStart(node, mid);
                    range.setEnd(node, Math.min(mid + 1, node.textContent.length));
                    const charRect = this.getRect(range);
                    if ((vertical ? charRect.top : charRect.left) >= page * pageSize) {
                        high = mid;
                    } else {
                        low = mid + 1;
                    }
                }
                starts[page] = nodeStart + this.countChars(node.textContent.slice(0, low));
                range.selectNodeContents(node);
            }
        }

        for (let page = pageCount - 1; page >= 0; page--) {
            starts[page] ??= starts[page + 1] ?? totalChars;
        }
        for (let page = 1; page < pageCount; page++) {
            starts[page] = Math.max(starts[page], starts[page - 1]);
        }
        return starts;
    },

    forEachContentRect(visitor) {
        const range = document.createRange();
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
            acceptNode: (node) => {
                if (node.nodeType === Node.TEXT_NODE) {
                    const parent = node.parentElement;
                    if (!parent || parent.closest('script, style, noscript, #hoshi-reader-spread-end-spacer')) {
                        return NodeFilter.FILTER_REJECT;
                    }
                    return this.isFurigana(node) || !node.textContent || !node.textContent.trim()
                        ? NodeFilter.FILTER_REJECT
                        : NodeFilter.FILTER_ACCEPT;
                }

                if (node.nodeType === Node.ELEMENT_NODE) {
                    if (node.closest?.('#hoshi-reader-spread-end-spacer')) {
                        return NodeFilter.FILTER_REJECT;
                    }
                    if (node.matches?.('img, svg')) {
                        return NodeFilter.FILTER_ACCEPT;
                    }
                }

                return NodeFilter.FILTER_SKIP;
            }
        });

        let node;
        while (node = walker.nextNode()) {
            if (node.nodeType === Node.TEXT_NODE) {
                range.selectNodeContents(node);
                for (const rect of range.getClientRects()) {
                    if (visitor(rect, node) === false) {
                        return false;
                    }
                }
            } else {
                for (const rect of node.getClientRects()) {
                    if (visitor(rect, node) === false) {
                        return false;
                    }
                }
            }
        }
        return true;
    },

    horizontalContentMetrics(scrollEl) {
        if (this.horizontalContentMetricsCache) {
            return this.horizontalContentMetricsCache;
        }

        const scrollLeft = scrollEl.scrollLeft || 0;
        const metrics = {
            maxEnd: 0,
            terminalOffset: null,
            terminalRect: null
        };
        this.forEachContentRect((rect) => {
            if (Number.isFinite(rect.left) && Number.isFinite(rect.right)) {
                metrics.maxEnd = Math.max(metrics.maxEnd, rect.right + scrollLeft);
                metrics.terminalOffset = ((rect.left + rect.right) / 2) + scrollLeft;
                metrics.terminalRect = {
                    left: rect.left + scrollLeft,
                    right: rect.right + scrollLeft,
                    top: rect.top,
                    bottom: rect.bottom
                };
            }
        });

        this.horizontalContentMetricsCache = metrics;
        return metrics;
    },

    horizontalContentEndOffset(scrollEl) {
        return this.horizontalContentMetrics(scrollEl).maxEnd;
    },

    horizontalTerminalContentOffset(scrollEl) {
        return this.horizontalContentMetrics(scrollEl).terminalOffset;
    },

    visibleContentBounds(scrollEl) {
        if (this.horizontalPageColumns <= 1 || this.isVertical()) {
            return { left: 0, right: window.innerWidth, top: 0, bottom: window.innerHeight };
        }

        const style = window.getComputedStyle(scrollEl);
        return {
            left: parseFloat(style.paddingLeft) || 0,
            right: window.innerWidth - (parseFloat(style.paddingRight) || 0),
            top: 0,
            bottom: window.innerHeight
        };
    },

    rectIntersectsViewport(rect, bounds) {
        const visibleBounds = bounds || { left: 0, right: window.innerWidth, top: 0, bottom: window.innerHeight };
        return Number.isFinite(rect.left)
            && Number.isFinite(rect.right)
            && Number.isFinite(rect.top)
            && Number.isFinite(rect.bottom)
            && rect.right > visibleBounds.left
            && rect.left < visibleBounds.right
            && rect.bottom > visibleBounds.top
            && rect.top < visibleBounds.bottom;
    },

    hasTerminalContentInViewport(context) {
        const terminalRect = context.contentMetrics?.terminalRect;
        if (!terminalRect) {
            return false;
        }

        const scrollLeft = context.scrollEl.scrollLeft || 0;
        return this.rectIntersectsViewport({
            left: terminalRect.left - scrollLeft,
            right: terminalRect.right - scrollLeft,
            top: terminalRect.top,
            bottom: terminalRect.bottom
        }, context.visibleBounds);
    },

    hasVisibleContentInViewport(context) {
        let visible = false;
        this.forEachContentRect((rect) => {
            if (this.rectIntersectsViewport(rect, context.visibleBounds)) {
                visible = true;
                return false;
            }
        });

        return visible;
    },

    ensureHorizontalSpreadScrollExtent(maxScroll, viewportSize) {
        const spacerID = 'hoshi-reader-spread-end-spacer';
        document.getElementById(spacerID)?.remove();
        if (maxScroll <= 0 || viewportSize <= 0) {
            return;
        }

        const requiredEnd = maxScroll + viewportSize;
        const currentEnd = Math.max(
            document.documentElement.scrollWidth,
            document.body.scrollWidth,
            window.innerWidth
        );
        if (currentEnd >= requiredEnd - 1) {
            return;
        }

        const spacer = document.createElement('div');
        spacer.id = spacerID;
        spacer.setAttribute('aria-hidden', 'true');
        spacer.style.position = 'absolute';
        spacer.style.left = `${requiredEnd - 1}px`;
        spacer.style.top = '0';
        spacer.style.width = '1px';
        spacer.style.height = '1px';
        spacer.style.opacity = '0';
        spacer.style.pointerEvents = 'none';
        spacer.style.userSelect = 'none';
        document.body.appendChild(spacer);
    },

    getScrollContext() {
        var vertical = this.isVertical();
        var scrollEl = document.body;
        var viewportSize = vertical ? this.pageHeight : this.pageWidth;
        var scrollViewportSize = vertical ? (scrollEl.clientHeight || window.innerHeight) : (scrollEl.clientWidth || window.innerWidth);
        var scrollStartPadding = vertical ? 0 : (parseFloat(window.getComputedStyle(scrollEl).paddingLeft) || 0);
        var scrollEndPadding = vertical ? 0 : (parseFloat(window.getComputedStyle(scrollEl).paddingRight) || 0);
        var pageSize = vertical ? this.pageHeight : this.pageWidth;
        if (this.horizontalPageColumns > 1 && !vertical && this.horizontalSpreadPageSize > 0) {
            pageSize = this.horizontalSpreadPageSize;
        }
        var totalSize = vertical ? scrollEl.scrollHeight : scrollEl.scrollWidth;
        var rawMaxScroll = Math.max(0, totalSize - viewportSize);
        var maxScroll = rawMaxScroll;
        var limitTolerance = 1;
        var contentMetrics = null;
        var visibleBounds = { left: 0, right: window.innerWidth, top: 0, bottom: window.innerHeight };
        if (pageSize > 0 && this.horizontalPageColumns > 1 && !vertical) {
            contentMetrics = this.horizontalContentMetrics(scrollEl);
            visibleBounds = this.visibleContentBounds(scrollEl);
            maxScroll = Math.floor(Math.max(0, contentMetrics.maxEnd - 1) / pageSize) * pageSize;
            this.ensureHorizontalSpreadScrollExtent(maxScroll, scrollViewportSize + scrollStartPadding + scrollEndPadding);
            limitTolerance = Math.max(1, scrollStartPadding + scrollEndPadding + 1);
        }
        return { vertical, scrollEl, pageSize, viewportSize, maxScroll, limitTolerance, contentMetrics, visibleBounds };
    },
    
    setScrollOffset(context, scroll) {
        var clampedScroll = Math.min(Math.max(0, scroll), context.maxScroll);
        if (context.vertical) {
            context.scrollEl.scrollTop = clampedScroll;
        } else {
            context.scrollEl.scrollLeft = clampedScroll;
        }
        return context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
    },
    
    alignToPage(context, anchor) {
        if (context.pageSize <= 0) {
            return 0;
        }
        var pageIndex = Math.floor(Math.max(0, anchor) / context.pageSize);
        return Math.min(Math.max(0, pageIndex * context.pageSize), context.maxScroll);
    },
    
    paginate(direction) {
        var context = this.getScrollContext();
        if (context.pageSize <= 0) return "limit";
        var currentScroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;

        if (direction === "forward") {
            if (this.horizontalPageColumns > 1 && !context.vertical && this.hasTerminalContentInViewport(context)) {
                this.horizontalTerminalPageTarget = null;
                return "limit";
            }
            if (this.horizontalTerminalPageTarget && currentScroll > this.horizontalTerminalPageTarget.before + 1) {
                this.horizontalTerminalPageTarget = null;
                return "limit";
            }
            if (currentScroll >= (context.maxScroll - context.limitTolerance)) {
                this.horizontalTerminalPageTarget = null;
                return "limit";
            }

            var targetScroll = Math.min(currentScroll + context.pageSize, context.maxScroll);
            if (targetScroll < (context.maxScroll - 1)) {
                targetScroll = Math.round(targetScroll / context.pageSize) * context.pageSize;
            }
            const isTerminalTarget = targetScroll >= (context.maxScroll - context.limitTolerance);
            if (this.horizontalPageColumns > 1 && !context.vertical && isTerminalTarget) {
                if ((context.contentMetrics?.maxEnd || 0) <= currentScroll + context.viewportSize + context.limitTolerance) {
                    this.horizontalTerminalPageTarget = null;
                    return "limit";
                }
            }
            var actualScroll = this.setScrollOffset(context, targetScroll);
            window.lastPageScroll = actualScroll;
            if (isTerminalTarget && !this.hasVisibleContentInViewport(context)) {
                this.setScrollOffset(context, currentScroll);
                window.lastPageScroll = currentScroll;
                this.horizontalTerminalPageTarget = null;
                return "limit";
            }
            if (targetScroll >= (context.maxScroll - context.limitTolerance) && actualScroll <= currentScroll + 1) {
                this.horizontalTerminalPageTarget = null;
                return "limit";
            }
            if (this.horizontalPageColumns > 1 && !context.vertical && isTerminalTarget) {
                this.horizontalTerminalPageTarget = { before: currentScroll, target: targetScroll };
            } else {
                this.horizontalTerminalPageTarget = null;
            }
            return "scrolled";
        }

        this.horizontalTerminalPageTarget = null;
        if (currentScroll <= 1) {
            return "limit";
        }

        var targetScroll = Math.round((currentScroll - context.pageSize) / context.pageSize) * context.pageSize;
        window.lastPageScroll = this.setScrollOffset(context, targetScroll);
        return "scrolled";
    },
    
    scrollToRange(range) {
        const context = this.getScrollContext();
        if (context.pageSize <= 0) {
            return false;
        }
        
        this.horizontalTerminalPageTarget = null;
        const rect = this.getRect(range);
        const currentScroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
        const anchor = (context.vertical ? (rect.top + rect.bottom) / 2 : (rect.left + rect.right) / 2) + currentScroll;
        const targetScroll = this.alignToPage(context, anchor);
        
        if (targetScroll === currentScroll) {
            return false;
        }
        
        window.lastPageScroll = targetScroll;
        this.setScrollOffset(context, targetScroll);
        requestAnimationFrame(() => {
            this.setScrollOffset(context, targetScroll);
        });
        
        return true;
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
        
        if (reveal) {
            const range = document.createRange();
            range.selectNodeContents(wrappers[0]);
            if (this.scrollToRange(range)) {
                return this.calculateProgress();
            }
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
    
    async restoreProgress(progress) {
        await document.fonts.ready;
        this.horizontalTerminalPageTarget = null;
        var context = this.getScrollContext();
        
        if (context.pageSize <= 0) {
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return;
        }
        
        if (progress <= 0) {
            this.setScrollOffset(context, 0);
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return;
        }
        
        if (progress >= 0.99) {
            var lastPage = Math.floor(context.maxScroll / context.pageSize) * context.pageSize;
            if (this.horizontalPageColumns > 1 && !context.vertical) {
                const terminalOffset = this.horizontalTerminalContentOffset(context.scrollEl);
                if (terminalOffset !== null) {
                    lastPage = this.alignToPage(context, terminalOffset);
                }
            }
            lastPage = Math.max(0, lastPage);
            this.setScrollOffset(context, lastPage);
            requestAnimationFrame(() => {
                let actualLastPage = this.setScrollOffset(context, lastPage);
                if (this.horizontalPageColumns > 1 && !context.vertical) {
                    while (actualLastPage > 0 && !this.hasVisibleContentInViewport(context)) {
                        actualLastPage = this.setScrollOffset(context, actualLastPage - context.pageSize);
                    }
                }
                this.registerSnapScroll(actualLastPage);
                requestAnimationFrame(() => this.notifyRestoreComplete());
            });
            return;
        }
        
        var walker = this.createWalker();
        var totalChars = 0;
        var node;
        
        while (node = walker.nextNode()) {
            totalChars += this.countChars(node.textContent);
        }
        
        if (totalChars <= 0) {
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return;
        }
        
        var targetCharCount = Math.ceil(totalChars * progress);
        var runningSum = 0;
        var targetNode = null;
        
        walker = this.createWalker();
        while (node = walker.nextNode()) {
            runningSum += this.countChars(node.textContent);
            if (runningSum > targetCharCount) {
                targetNode = node;
                break;
            }
        }
        
        if (targetNode) {
            var range = document.createRange();
            range.setStart(targetNode, 0);
            range.setEnd(targetNode, 1);
            var rect = this.getRect(range);
            var anchor = (context.vertical ? rect.top : rect.left) + (context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft);
            var targetScroll = this.alignToPage(context, anchor);
            
            this.setScrollOffset(context, targetScroll);
            requestAnimationFrame(() => {
                this.setScrollOffset(context, targetScroll);
                this.registerSnapScroll(targetScroll);
            });
        } else {
            this.registerSnapScroll(0);
        }
        
        requestAnimationFrame(() => {
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
    },
    
    async jumpToFragment(fragment) {
        await document.fonts.ready;
        var context = this.getScrollContext();
        var rawFragment = (fragment || '').trim();
        var target = rawFragment && (document.getElementById(rawFragment) || document.getElementsByName(rawFragment)[0]);
        
        if (context.pageSize <= 0 || !target) {
            this.registerSnapScroll(0);
            this.notifyRestoreComplete();
            return false;
        }
        
        var rect = this.getRect(target);
        var currentScroll = context.vertical ? context.scrollEl.scrollTop : context.scrollEl.scrollLeft;
        var anchor = (context.vertical ? rect.top : rect.left) + currentScroll;
        var targetScroll = this.alignToPage(context, anchor);
        
        this.setScrollOffset(context, targetScroll);
        
        requestAnimationFrame(() => {
            this.setScrollOffset(context, targetScroll);
            this.registerSnapScroll(targetScroll);
            requestAnimationFrame(() => this.notifyRestoreComplete());
        });
        
        return true;
    }
};
