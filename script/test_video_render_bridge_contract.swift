import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func sourceBlock(
    _ source: String,
    from startMarker: String,
    to endMarker: String
) -> String? {
    guard let start = source.range(of: startMarker),
          let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

func containsInOrder(_ source: String, _ markers: [String]) -> Bool {
    var searchStart = source.startIndex
    for marker in markers {
        guard let range = source.range(of: marker, range: searchStart..<source.endIndex) else {
            return false
        }
        searchStart = range.upperBound
    }
    return true
}

let clientHeader = try source("Features/Video/Playback/HSMpvClient.h")
let clientImpl = try source("Features/Video/Playback/HSMpvClient.mm")
let renderView = try source("Features/Video/Playback/MpvRenderView.swift")
let engine = try source("Features/Video/Playback/MpvPlayerEngine.swift")
let displayBlock = sourceBlock(
    clientImpl,
    from: "- (void)display {",
    to: "- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:"
)
let layerCopyBlock = sourceBlock(
    clientImpl,
    from: "- (instancetype)initWithLayer:(id)layer {",
    to: "- (void)dealloc"
)
let viewDidMoveBlock = sourceBlock(
    clientImpl,
    from: "- (void)viewDidMoveToWindow {",
    to: "- (void)windowBackingPropertiesDidChange:"
)
let notifyReadyBlock = sourceBlock(
    clientImpl,
    from: "- (void)notifyReadyIfPossible {",
    to: "- (BOOL)hasRenderContext"
)
let renderContextStateBlock = sourceBlock(
    clientImpl,
    from: "@implementation HSMpvRenderContextState {",
    to: "#pragma clang diagnostic push"
)
let displayLinkReportBlock = sourceBlock(
    clientImpl,
    from: "- (void)reportSwapForDisplayLink {",
    to: "- (void)createOpenGLObjects"
)
let canDrawBlock = sourceBlock(
    clientImpl,
    from: "- (BOOL)canDrawInCGLContext:",
    to: "- (void)drawInCGLContext:"
)
let drawBlock = sourceBlock(
    clientImpl,
    from: "- (void)drawInCGLContext:",
    to: "@end\n#pragma clang diagnostic pop"
)
let detachBlock = sourceBlock(
    clientImpl,
    from: "- (void)detachFromView {",
    to: "- (void)installDisplayConfigurationCallbackForView:"
)
let attachBlock = sourceBlock(
    clientImpl,
    from: "- (BOOL)attachToView:(HSMpvOpenGLView *)view {",
    to: "- (void)detachFromView"
)
let sdrConfigurationBlock = sourceBlock(
    clientImpl,
    from: "- (void)applySDRDisplayColorConfigurationForView:(HSMpvOpenGLView *)view\n    screen:(NSScreen *)screen {",
    to: "- (BOOL)applyHDRDisplayColorConfigurationForView:"
)
let installUpdateCallbackBlock = sourceBlock(
    clientImpl,
    from: "- (void)installRenderUpdateCallbackForView:(HSMpvOpenGLView *)view {",
    to: "- (void)clearRenderUpdateCallback"
)
let clearUpdateCallbackBlock = sourceBlock(
    clientImpl,
    from: "- (void)clearRenderUpdateCallback {",
    to: "- (void)releaseRenderUpdateContext"
)
let fullScreenCompletionBlock = sourceBlock(
    clientImpl,
    from: "- (void)windowFullScreenTransitionDidEnd:",
    to: "- (BOOL)updateBackingConfiguration"
)
let viewLayoutBlock = sourceBlock(
    clientImpl,
    from: "- (void)layout {",
    to: "- (void)scheduleCoalescedLayoutRender"
)
let displayLinkStopRange = clientImpl.range(of: "[renderLayer stopDisplayLink]")
let renderContextFreeRange = clientImpl.range(of: "mpv_render_context_free(context)")

require(
    clientHeader.contains("@interface HSMpvOpenGLView : NSView")
        && !clientHeader.contains("@interface HSMpvOpenGLView : NSOpenGLView"),
    "video render host should be an NSView backed by a CAOpenGLLayer, not an NSOpenGLView"
)
require(
    clientImpl.contains("@interface HSMpvOpenGLLayer : CAOpenGLLayer")
        && clientImpl.contains("copyCGLPixelFormatForDisplayMask:")
        && clientImpl.contains("copyCGLContextForPixelFormat:")
        && clientImpl.contains("drawInCGLContext:(CGLContextObj)context")
        && clientImpl.contains("forLayerTime:(CFTimeInterval)time")
        && clientImpl.contains("displayTime:(const CVTimeStamp *)timeStamp")
        && !clientImpl.contains("- (void)drawRect:"),
    "video rendering should move from NSOpenGLView.drawRect to a CAOpenGLLayer draw path"
)
require(
    clientImpl.contains("MPV_RENDER_PARAM_ADVANCED_CONTROL")
        && clientImpl.contains("mpv_render_context_update")
        && clientImpl.contains("mpv_render_context_report_swap")
        && clientImpl.contains("MPV_RENDER_PARAM_DEPTH")
        && clientImpl.contains("MPV_RENDER_PARAM_SKIP_RENDERING")
        && clientImpl.contains("MPV_RENDER_UPDATE_FRAME"),
    "video render bridge should use libmpv advanced_control with update/report_swap so mpv does not wait on stale draws"
)
require(
    clientImpl.contains("dispatch_queue_create(\"moe.shishamo.hoshi.video.mpvgl\"")
        && clientImpl.contains("dispatch_async(_mpvGLQueue")
        && clientImpl.contains("- (void)display")
        && clientImpl.contains("[CATransaction begin]")
        && !clientImpl.contains("dispatch_async(dispatch_get_main_queue(), ^{\n        if (target.generation != generation) {\n            return;\n        }\n        HSMpvOpenGLView *view = target.view;\n        [view setNeedsDisplay:YES];")
        && !clientImpl.contains("dispatch_async(dispatch_get_main_queue(), ^{\n        self.renderScheduled = NO;\n        [self setNeedsDisplay];"),
    "mpv render updates should run through a dedicated layer GL queue and display path instead of forcing every frame onto the main queue"
)
require(
    clientImpl.contains("@interface HSMpvMainThreadPriorityLock : NSObject")
        && clientImpl.contains("NSCondition *_condition;")
        && clientImpl.contains("_mainThreadNeedsLock = YES;")
        && clientImpl.contains("while (_mainThreadNeedsLock)")
        && clientImpl.contains("[_condition broadcast];")
        && displayBlock.map {
            containsInOrder(
                $0,
                [
                    "[_mainThreadPriorityLock beforeLocking];",
                    "[_displayLock lock];",
                    "[_mainThreadPriorityLock afterLocked];",
                    "[CATransaction flush];",
                    "mpv_render_context_update(renderContext)",
                    "mpv_render_context_render(renderContext, parameters);",
                    "[_displayLock unlock];",
                ]
            )
                && $0.components(separatedBy: "[_displayLock unlock];").count == 2
        } == true,
    "the render display lock should give AppKit's main thread priority over the continuously active mpv GL queue"
)
require(
    clientImpl.contains("kCGLPFAOpenGLProfile")
        && clientImpl.contains("kCGLOGLPVersion_3_2_Core")
        && clientImpl.contains("kCGLPFAAccelerated")
        && !clientImpl.contains("fallbackAttributes")
        && !clientImpl.contains("kCGLRendererGenericFloatID"),
    "video render bridge should take the IINA-style accelerated OpenGL layer path directly instead of falling back to a software/legacy pixel format"
)
require(
    clientImpl.contains("CGLEnable(_context, kCGLCEMPEngine)"),
    "the IINA-aligned OpenGL context should enable Apple's multithreaded GL engine"
)
require(
    clientImpl.contains("self.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;")
        && !clientImpl.contains("self.openGLLayer.frame = self.bounds;\n    BOOL backingConfigurationChanged")
        && viewLayoutBlock?.contains("[self requestForcedRender];") == false
        && viewLayoutBlock?.contains("[self scheduleCoalescedLayoutRender];") == true
        && clientImpl.contains("generation != strongSelf->_layoutRenderGeneration"),
    "window geometry changes should resize the stable layer and coalesce a final draw instead of forcing mpv on every layout tick"
)
require(
    notifyReadyBlock.map {
        containsInOrder(
            $0,
            [
                "if (self.hasRenderContext",
                "return;",
                "performWithLockedOpenGLContext",
                "if (!self.hasRenderContext)",
                "self.onReady(self);",
            ]
        )
    } == true,
    "layout should never reacquire the OpenGL context lock after the render view is already attached"
)
require(
    layerCopyBlock.map {
        $0.contains("CGLRetainPixelFormat")
            && $0.contains("CGLRetainContext")
            && $0.contains("_displayLock = previousLayer->_displayLock;")
            && $0.contains("_renderContextState = previousLayer->_renderContextState;")
            && containsInOrder(
                $0,
                [
                    "CGLRetainPixelFormat(previousLayer->_pixelFormat)",
                    "CGLRetainContext(previousLayer->_context)",
                    "_displayLock = previousLayer->_displayLock;",
                    "_renderContextState = previousLayer->_renderContextState;",
                    "self = [super initWithLayer:layer];",
                    "self.wantsExtendedDynamicRangeContent = previousLayer.wantsExtendedDynamicRangeContent;",
                ]
            )
            && !$0.contains("self.renderContext = previousLayer.renderContext;")
            && $0.contains("self.wantsExtendedDynamicRangeContent = previousLayer.wantsExtendedDynamicRangeContent;")
            && $0.contains("self.inLiveResize = previousLayer.inLiveResize;")
    } == true,
    "Core Animation shadow copies should retain the GL objects and share an invalidatable render-context state"
)
require(
    layerCopyBlock.map {
        containsInOrder(
            $0,
            [
                "- (instancetype)initForReplacementFromLayer:",
                "self = [super init];",
                "CGLRetainPixelFormat(layer->_pixelFormat)",
                "CGLRetainContext(layer->_context)",
                "_renderContextState = [[HSMpvRenderContextState alloc] init];",
                "self.inLiveResize = NO;",
                "self.asynchronous = NO;",
            ]
        )
            && !$0.contains("self = [self initWithLayer:layer];")
    } == true,
    "an actual replacement model layer should retain the creation CGL objects but own fresh lifetime state"
)
require(
    clientImpl.contains("@interface HSMpvRenderContextState : NSObject")
        && renderContextStateBlock.map {
            $0.contains("pthread_rwlock_t _lifetimeLock;")
                && $0.contains("NSLock *_renderAPILock;")
                && $0.contains("pthread_rwlock_rdlock(&_lifetimeLock);")
                && $0.contains("pthread_rwlock_wrlock(&_lifetimeLock);")
                && containsInOrder(
                    $0,
                    [
                        "- (void)withContext:",
                        "pthread_rwlock_rdlock(&_lifetimeLock);",
                        "[_renderAPILock lock];",
                        "body(context);",
                        "[_renderAPILock unlock];",
                        "pthread_rwlock_unlock(&_lifetimeLock);",
                    ]
                )
                && containsInOrder(
                    $0,
                    [
                        "- (mpv_render_context *)takeContextForTransfer",
                        "pthread_rwlock_wrlock(&_lifetimeLock);",
                        "_context = NULL;",
                        "pthread_rwlock_unlock(&_lifetimeLock);",
                        "return context;",
                    ]
                )
                && containsInOrder(
                    $0,
                    [
                        "- (void)invalidateAndPerform:",
                        "pthread_rwlock_wrlock(&_lifetimeLock);",
                        "_context = NULL;",
                        "body(context);",
                        "pthread_rwlock_unlock(&_lifetimeLock);",
                    ]
                )
        } == true
        && clientImpl.contains("HSMpvOpenGLLayer *_renderLayer;")
        && clientImpl.contains("HSMpvRenderContextState *_renderContextState;"),
    "model, shadow layers, and the client should share a read/write-locked render-context lifetime"
)
require(
    displayLinkReportBlock.map {
        containsInOrder(
            $0,
            [
                "performWithLockedOpenGLContext",
                "withRenderContext",
                "mpv_render_context_report_swap",
            ]
        )
    } == true
        && canDrawBlock.map {
            containsInOrder($0, ["withRenderContext", "mpv_render_context_update"])
        } == true
        && drawBlock.map {
            containsInOrder(
                $0,
                [
                    "withRenderContext",
                    "mpv_render_context_render",
                    "mpv_render_context_report_swap",
                ]
            )
        } == true
        && sdrConfigurationBlock.map {
            containsInOrder($0, ["withContext", "mpv_render_context_set_parameter"])
        } == true
        && installUpdateCallbackBlock.map {
            containsInOrder(
                $0,
                [
                    "performWithLockedOpenGLContext",
                    "withContext",
                    "mpv_render_context_set_update_callback",
                ]
            )
        } == true
        && clearUpdateCallbackBlock.map {
            containsInOrder(
                $0,
                [
                    "performWithLockedOpenGLContext",
                    "withContext",
                    "mpv_render_context_set_update_callback",
                ]
            )
        } == true,
    "every render-context borrow should use the creation CGL context and the serialized shared lifetime lock"
)
require(
    attachBlock.map {
        containsInOrder(
            $0,
            [
                "if (_renderContext && _view != view)",
                "[self clearRenderUpdateCallback];",
                "[previousLayer stopDisplayLink];",
                "[view replaceRenderLayerWithCopyOfLayer:previousLayer];",
                "performWithLockedOpenGLContext",
                "takeContextForTransfer",
                "_renderLayer = view.openGLLayer;",
                "_renderContextState = _renderLayer.renderContextState;",
                "[view setRenderContext:transferredContext];",
                "[self installRenderUpdateCallbackForView:view];",
            ]
        )
            && !$0.contains("[self detachFromView];")
    } == true,
    "replacing the render view should transfer ownership to a fresh state on a layer retaining the creation CGL context"
)
require(
    clientImpl.contains(
        "[self.openGLLayer setRenderContext:renderContext];\n"
            + "    if (renderContext) {\n"
            + "        if (self.window.inLiveResize) {"
    ),
    "a replacement layer should enter live-resize mode only after its render context has been published"
)
require(
    detachBlock.map {
        containsInOrder(
            $0,
            [
                "_renderContextState ?: renderLayer.renderContextState",
                "[renderLayer stopDisplayLink];",
                "performWithLockedOpenGLContext",
                "invalidateAndPerform",
                "mpv_render_context_free(context);",
                "_renderContextState = nil;",
                "_renderLayer = nil;",
            ]
        )
    } == true,
    "detach should keep the layer/state alive, take the CGL lock first, invalidate all shadow copies, and only then free mpv"
)
require(
    clientImpl.contains("wantsBestResolutionOpenGLSurface = YES"),
    "video render host should request a best-resolution OpenGL surface"
)
require(
    clientImpl.contains("- (BOOL)isOpaque {\n    return YES;\n}"),
    "the full-bounds black video surface should report itself opaque to avoid compositing content underneath"
)
require(
    clientImpl.contains("backingScaleFactor")
        && clientImpl.contains("contentsScale")
        && clientImpl.contains("NSWindowDidChangeBackingPropertiesNotification"),
    "video render host should follow the active window backing scale"
)
require(
    clientImpl.contains("kCGLPFAColorSize")
        && clientImpl.contains("kCGLPFAColorFloat")
        && clientImpl.contains("kCAContentsFormatRGBA16Float")
        && clientImpl.contains("_bufferDepth = 16")
        && clientImpl.contains("_bufferDepth = 8"),
    "video render host should prefer a half-float framebuffer and fall back to 8-bit"
)
require(
    clientImpl.contains("MPV_RENDER_PARAM_ICC_PROFILE")
        && clientImpl.contains("icc-profile-auto"),
    "SDR output should provide the active display ICC profile to libmpv"
)
require(
    clientImpl.contains("wantsExtendedDynamicRangeOpenGLSurface = YES")
        && clientImpl.contains("wantsExtendedDynamicRangeContent"),
    "the render host should support EDR while keeping content state explicit"
)
require(
    clientImpl.contains("target-prim")
        && clientImpl.contains("target-trc")
        && clientImpl.contains("kCGColorSpaceITUR_2100_PQ"),
    "HDR output should configure mpv and the layer for PQ EDR"
)
require(
    clientImpl.contains("applySDRDisplayColorConfiguration"),
    "HDR disable or fallback should restore calibrated SDR output"
)
require(
    clientImpl.contains("CVDisplayLinkCreateWithActiveCGDisplays")
        && clientImpl.contains("CVDisplayLinkSetCurrentCGDisplay")
        && clientImpl.contains("CVDisplayLinkSetOutputCallback"),
    "video render pacing should follow the active display"
)
require(
    clientImpl.contains("display-fps-override"),
    "libmpv should receive the active display refresh rate"
)
require(
    displayLinkStopRange != nil
        && renderContextFreeRange != nil
        && displayLinkStopRange!.lowerBound < renderContextFreeRange!.lowerBound,
    "display link should stop before the render context is freed"
)
require(
    clientImpl.contains("usesImmediateSwapReporting"),
    "display-link failure should preserve immediate swap reporting"
)
require(
    clientImpl.contains("@property (atomic, assign, getter=isInLiveResize) BOOL inLiveResize;")
        && clientImpl.contains("- (void)beginLiveResize;")
        && clientImpl.contains("- (void)endLiveResize;")
        && clientImpl.contains("- (void)resetLiveResizeState;"),
    "the OpenGL layer should own an explicit live-resize lifecycle"
)
require(
    clientImpl.contains("self.inLiveResize = YES;\n    self.asynchronous = YES;\n    [self requestForcedRender];")
        && clientImpl.contains("self.inLiveResize = NO;\n    [self requestForcedRender];"),
    "live resize should enable asynchronous drawing immediately and force a background draw at both boundaries"
)
require(
    clientImpl.contains("if (self.inLiveResize && NSThread.isMainThread) {\n        return NO;\n    }")
        && clientImpl.contains("if (!self.inLiveResize) {\n        self.asynchronous = NO;\n    }"),
    "live resize should reject main-thread layer draws and restore synchronous mode from the forced background draw"
)
require(
    clientImpl.contains("self.inLiveResize = NO;\n    self.asynchronous = NO;")
        && clientImpl.contains("[self.openGLLayer resetLiveResizeState];"),
    "detaching the render view should always restore the layer's non-live-resize state"
)
require(
    clientImpl.contains("name:NSWindowWillStartLiveResizeNotification")
        && clientImpl.contains("name:NSWindowDidEndLiveResizeNotification")
        && clientImpl.contains("selector:@selector(windowWillStartLiveResize:)")
        && clientImpl.contains("selector:@selector(windowDidEndLiveResize:)")
        && clientImpl.contains("object:self.window")
        && clientImpl.contains("[self.openGLLayer beginLiveResize];")
        && clientImpl.contains("[self.openGLLayer endLiveResize];"),
    "the render view should observe live-resize notifications only from its own window"
)
require(
    viewDidMoveBlock.map {
        containsInOrder(
            $0,
            [
                "name:NSWindowDidEnterFullScreenNotification",
                "object:nil",
                "name:NSWindowDidExitFullScreenNotification",
                "object:nil",
                "name:NSWindowWillEnterFullScreenNotification",
                "object:nil",
                "name:NSWindowWillExitFullScreenNotification",
                "object:nil",
                "name:HSMpvWindowFullScreenTransitionDidFailNotification",
                "object:nil",
                "selector:@selector(windowFullScreenTransitionDidEnd:)",
                "name:NSWindowDidEnterFullScreenNotification",
                "object:self.window",
                "selector:@selector(windowFullScreenTransitionDidEnd:)",
                "name:NSWindowDidExitFullScreenNotification",
                "object:self.window",
                "selector:@selector(windowFullScreenTransitionWillStart:)",
                "name:NSWindowWillEnterFullScreenNotification",
                "object:self.window",
                "selector:@selector(windowFullScreenTransitionWillStart:)",
                "name:NSWindowWillExitFullScreenNotification",
                "object:self.window",
                "selector:@selector(windowFullScreenTransitionDidEnd:)",
                "name:HSMpvWindowFullScreenTransitionDidFailNotification",
                "object:self.window",
            ]
        )
    } == true
        && fullScreenCompletionBlock.map {
            containsInOrder(
                $0,
                [
                    "self.needsLayout = YES;",
                    "[self layoutSubtreeIfNeeded];",
                    "_fullScreenTransitionInProgress = NO;",
                    "[self requestForcedRender];",
                ]
            )
        } == true,
    "native fullscreen completion and failure should commit final layout and force one backing-size frame"
)
require(
    renderView.contains("HSMpvOpenGLView(frame:")
        && engine.contains("func attach(to view: HSMpvOpenGLView) -> Bool")
        && renderView.contains("view.onReady = nil")
        && renderView.contains("detachRenderView(ifAttachedTo: nsView)")
        && engine.contains("func detachRenderView(ifAttachedTo view: HSMpvOpenGLView)")
        && engine.contains("guard attachedRenderView === view else { return }")
        && engine.contains("var renderDetachGeneration: UInt64 = 0")
        && engine.contains("Task.sleep(for: .milliseconds(100))")
        && engine.contains("self.renderDetachGeneration == generation")
        && engine.contains("self.attachedRenderView == nil"),
    "SwiftUI should keep the same narrow NSViewRepresentable boundary around the native mpv render host"
)

print("Video render bridge contract tests passed")
