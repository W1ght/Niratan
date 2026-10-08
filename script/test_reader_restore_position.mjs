import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

for (const path of [
    'Features/Reader/ReaderWebView/reader.js',
    'Features/Reader/ScrollReaderWebView/scrollreader.js',
]) {
    const window = { getComputedStyle: () => ({ writingMode: 'horizontal-tb' }), innerWidth: 1000 };
    const document = {
        createRange() {
            return {
                setStart(node, offset) { this.node = node; this.start = offset; },
                setEnd(node, offset) { assert.equal(this.node, node); this.end = offset; },
                getBoundingClientRect() { return { left: this.start, right: this.end, top: this.start, bottom: this.end }; },
                getClientRects() { return [this.getBoundingClientRect()]; },
            };
        },
        fonts: { ready: Promise.resolve() },
    };
    vm.runInNewContext(readFileSync(path, 'utf8'), { window, document, requestAnimationFrame: callback => callback() });
    const reader = window.hoshiReader;
    const node = { textContent: '😀 A𠮷 / B' };
    for (const [characterIndex, start, end, text] of [
        [0, 3, 4, 'A'],
        [1, 4, 6, '𠮷'],
        [2, 9, 10, 'B'],
    ]) {
        const range = reader.rangeForCharacter(node, characterIndex);
        assert.equal(range.start, start, `${path}: UTF-16 start for ${text}`);
        assert.equal(range.end, end, `${path}: UTF-16 end for ${text}`);
        assert.equal(node.textContent.slice(range.start, range.end), text);
    }
    assert.equal(reader.rangeForCharacter(node, 3), null);
    assert.equal(reader.countChars(node.textContent), 3, 'restore precision must preserve existing character coordinates');
    const sharedNode = { textContent: '😀 가A나𠮷다' };
    assert.equal(reader.countChars(sharedNode.textContent), 2, 'ordinary local books retain their native basis');
    reader.sharedSyncCoordinates = true;
    assert.equal(reader.countChars(sharedNode.textContent), 5, 'shared books use Hoshi DOM character rules');
    assert.equal(reader.countNativeChars(sharedNode.textContent), 2, 'local highlight anchors retain their native basis');
    const sharedRange = reader.rangeForCharacter(sharedNode, 2);
    assert.equal(sharedNode.textContent.slice(sharedRange.start, sharedRange.end), '나');
    const secondNode = { textContent: 'B가' };
    reader.createWalker = () => {
        const nodes = [sharedNode, secondNode];
        return { nextNode() { return nodes.shift() ?? null; } };
    };
    reader.buildNodeOffsets();
    assert.equal(reader.nodeStartOffsets.get(secondNode), 5);
    assert.equal(reader.nodeStartNativeOffsets.get(secondNode), 2);
    assert.equal(reader.nodeStartRawOffsets.get(secondNode), 7);
    reader.sharedSyncCoordinates = false;
    const longParagraph = { textContent: 'A'.repeat(5000), parentElement: { scrollIntoView() { throw new Error('Restoring an interior character must not jump to the paragraph start'); } } };
    reader.createWalker = () => {
        let available = true;
        return { nextNode() { if (!available) return null; available = false; return longParagraph; } };
    };
    reader.notifyRestoreComplete = () => {};
    reader.registerSnapScroll = () => {};
    reader.getScrollContext = () => ({ vertical: false, pageSize: 1000, maxScroll: 4000, scrollEl: { scrollLeft: 0, scrollTop: 0 } });
    let restoredOffset;
    reader.setScrollOffset = (_, offset) => (restoredOffset = offset);
    window.scrollBy = offsets => { restoredOffset = offsets.top; };
    await reader.restoreProgress(0.6);
    assert.equal(restoredOffset, 3000, `${path}: restoring inside a paragraph targets its interior page/line`);
    if (path.includes('ScrollReaderWebView')) {
        const shortParagraph = { textContent: 'AB', parentElement: longParagraph.parentElement };
        const trailingWhitespace = { textContent: '\n ', parentElement: longParagraph.parentElement };
        reader.createWalker = () => {
            const nodes = [shortParagraph, trailingWhitespace];
            return { nextNode() { return nodes.shift() ?? null; } };
        };
        restoredOffset = undefined;
        await reader.restoreProgress(0.9);
        assert.equal(restoredOffset, 1, 'a near-end fraction must restore the final readable glyph before trailing whitespace');

        // Preserve paragraph-end alignment while independently observing the
        // final glyph's viewport intersection, including the actual Alice
        // vertical-continuous failure geometry from native WebKit.
        window.innerWidth = 1200;
        window.innerHeight = 760;
        for (const [name, vertical, initial] of [
            ['Alice last glyph left of viewport', true, { left: -21.203125, right: -0.78125, top: 395, bottom: 409 }],
            ['vertical glyph beyond right edge', true, { left: 1205, right: 1225, top: 395, bottom: 409 }],
            ['horizontal glyph below viewport', false, { left: 450, right: 470, top: 770, bottom: 784 }],
            ['horizontal glyph above viewport', false, { left: 450, right: 470, top: -20, bottom: -6 }],
            ['already visible terminal glyph', true, { left: 450, right: 470, top: 395, bottom: 409 }],
        ]) {
            const events = [];
            const shifted = { left: 0, top: 0 };
            const terminal = {
                textContent: 'ABd',
                parentElement: { scrollIntoView(options) { assert.equal(options.block, 'end'); events.push('parent-end'); } },
            };
            reader.createWalker = () => {
                const nodes = [terminal, { textContent: '\n ' }];
                return { nextNode() { return nodes.shift() ?? null; } };
            };
            window.getComputedStyle = () => ({ writingMode: vertical ? 'vertical-rl' : 'horizontal-tb' });
            const observedRect = () => ({
                left: initial.left - shifted.left, right: initial.right - shifted.left,
                top: initial.top - shifted.top, bottom: initial.bottom - shifted.top,
                width: initial.right - initial.left, height: initial.bottom - initial.top,
            });
            document.createRange = () => ({
                setStart(node, offset) { assert.equal(node, terminal); assert.equal(offset, 2); },
                setEnd(node, offset) { assert.equal(node, terminal); assert.equal(offset, 3); },
                getBoundingClientRect: observedRect,
            });
            window.scrollBy = ({ left, top }) => {
                shifted.left += left;
                shifted.top += top;
                events.push('glyph-scroll');
            };
            reader.notifyRestoreComplete = () => events.push('completed');
            await reader.restoreProgress(1);
            const rect = observedRect();
            assert.ok(rect.right > 0 && rect.left < window.innerWidth && rect.bottom > 0 && rect.top < window.innerHeight,
                `${name}: final readable glyph intersects the viewport`);
            assert.equal(events[0], 'parent-end', `${name}: original paragraph-end alignment is retained`);
            assert.equal(events.at(-1), 'completed', `${name}: completion follows glyph correction`);
            if (name.startsWith('already visible')) assert.equal(events.length, 2, 'visible EOF must not add scrolling');
        }
    }
    console.log(`PASS ${path}: precise normalized-character DOM range`);
}
