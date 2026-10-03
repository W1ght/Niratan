#define GL_SILENCE_DEPRECATION
#import "HSMpvClient.h"

#include <atomic>
#include <cstdint>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#import <CoreVideo/CoreVideo.h>
#import <OpenGL/gl.h>
#import <OpenGL/OpenGL.h>
#import <QuartzCore/QuartzCore.h>
#include <libavcodec/packet.h>
#include <libavcodec/version_major.h>
#include <libavformat/avformat.h>
#include <libavformat/version_major.h>
#include <libavutil/version.h>
#import <mpv/client.h>
#import <mpv/render.h>
#import <mpv/render_gl.h>

static NSString * const HSMpvErrorDomain = @"moe.shishamo.hoshi.video.mpv";
static NSNotificationName const HSMpvWindowFullScreenTransitionDidFailNotification =
    @"moe.shishamo.hoshi.video.fullScreenTransitionDidFail";
static NSString * const HSMpvInternalASSSubtitleEffectsTitle =
    @"__niratan_internal_ass_effects__";
static const CFTimeInterval HSMpvTimePositionStateEmitInterval = 0.20;
static const double HSMpvTimePositionImmediateEmitDelta = 0.50;
static NSImage *HSMpvAmbientImageFromNode(mpv_node *node, NSInteger maximumDimension);
static void HSMpvSetHTTPHeaders(
    mpv_handle *handle,
    NSDictionary<NSString *, NSString *> *headers
);
static NSDictionary<NSString *, NSString *> * _Nullable HSMpvMergedHTTPHeaders(
    NSDictionary<NSString *, NSString *> *videoHeaders,
    NSDictionary<NSString *, NSString *> *audioHeaders
);
static int HSMpvSetHTTPHeaderOption(
    mpv_handle *handle,
    NSDictionary<NSString *, NSString *> *headers
);

#ifndef GL_DRAW_FRAMEBUFFER_BINDING
#define GL_DRAW_FRAMEBUFFER_BINDING 0x8CA6
#endif

@implementation HSMpvTrackInfo
@end

@implementation HSExtractedSubtitleCue
@end

@implementation HSExtractedSubtitleTrack
@end

@implementation HSMpvAudioClipExporter

+ (BOOL)exportAudioFromURL:(NSURL *)sourceURL
    toURL:(NSURL *)outputURL
    startTime:(double)startTime
    endTime:(double)endTime
    httpHeaders:(NSDictionary<NSString *, NSString *> *)httpHeaders
    audioTrackID:(nullable NSNumber *)audioTrackID
    errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    if (endTime <= startTime) {
        if (errorMessage) *errorMessage = @"Unable to determine the video audio range.";
        return NO;
    }

    mpv_handle *encoder = mpv_create();
    if (!encoder) {
        if (errorMessage) *errorMessage = @"The bundled audio encoder is unavailable.";
        return NO;
    }

    int headerStatus = HSMpvSetHTTPHeaderOption(encoder, httpHeaders);
    if (headerStatus < 0) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:
                @"The bundled audio encoder rejected HTTP headers: %s",
                mpv_error_string(headerStatus)];
        }
        mpv_terminate_destroy(encoder);
        return NO;
    }

    NSString *start = [NSString stringWithFormat:@"%.6f", MAX(0, startTime)];
    NSString *end = [NSString stringWithFormat:@"%.6f", endTime];
    NSString *track = audioTrackID ? audioTrackID.stringValue : @"auto";
    NSMutableArray<NSArray<NSString *> *> *options = [@[
        @[@"config", @"no"], @[@"vid", @"no"], @[@"sid", @"no"],
        @[@"aid", track], @[@"audio-channels", @"mono"],
        @[@"start", start], @[@"end", end], @[@"o", outputURL.path]
    ] mutableCopy];
    if ([outputURL.pathExtension.lowercaseString isEqualToString:@"wav"]) {
        [options addObjectsFromArray:@[
            @[@"oac", @"pcm_s16le"], @[@"of", @"wav"]
        ]];
    } else {
        [options addObjectsFromArray:@[
            @[@"oac", @"aac"], @[@"of", @"mp4"], @[@"oacopts", @"b=64k"]
        ]];
    }
    for (NSArray<NSString *> *option in options) {
        int optionStatus = mpv_set_option_string(
            encoder, option[0].UTF8String, option[1].UTF8String
        );
        if (optionStatus < 0) {
            if (errorMessage) {
                *errorMessage = [NSString stringWithFormat:@"The bundled audio encoder rejected %@: %s",
                    option[0], mpv_error_string(optionStatus)];
            }
            mpv_terminate_destroy(encoder);
            return NO;
        }
    }

    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    int status = mpv_initialize(encoder);
    if (status < 0) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:@"The bundled audio encoder could not start: %s",
                mpv_error_string(status)];
        }
        mpv_terminate_destroy(encoder);
        return NO;
    }

    const char *source = sourceURL.isFileURL
        ? sourceURL.fileSystemRepresentation
        : sourceURL.absoluteString.UTF8String;
    const char *command[] = {"loadfile", source, NULL};
    status = mpv_command(encoder, command);
    if (status < 0) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:@"The video audio could not be opened: %s",
                mpv_error_string(status)];
        }
        mpv_terminate_destroy(encoder);
        return NO;
    }

    BOOL completed = NO;
    NSString *failure = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        mpv_event *event = mpv_wait_event(encoder, 0.25);
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *endFile = (mpv_event_end_file *)event->data;
            if (endFile && endFile->error < 0) {
                failure = [NSString stringWithFormat:@"The video audio export failed: %s",
                    mpv_error_string(endFile->error)];
            }
            completed = YES;
        } else if (event->event_id == MPV_EVENT_SHUTDOWN) {
            failure = @"The bundled audio encoder stopped unexpectedly.";
            completed = YES;
        }
    }
    if (!completed) failure = @"The video audio export timed out.";
    mpv_terminate_destroy(encoder);

    NSNumber *fileSize = nil;
    [outputURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
    if (failure || fileSize.longLongValue <= 0) {
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
        if (errorMessage) *errorMessage = failure ?: @"The exported video audio clip is empty.";
        return NO;
    }
    return YES;
}

@end

static BOOL HSMpvSetThumbnailOption(
    mpv_handle *handle,
    NSString *name,
    NSString *value,
    NSString **errorMessage
) {
    int status = mpv_set_option_string(handle, name.UTF8String, value.UTF8String);
    if (status < 0) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:@"The bundled video thumbnailer rejected %@: %s",
                name, mpv_error_string(status)];
        }
        return NO;
    }
    return YES;
}

static BOOL HSMpvThumbnailIsCancelled(HSMpvCancellationHandler isCancelled) {
    return isCancelled ? isCancelled() : NO;
}

static NSData *HSMpvPNGDataFromImage(NSImage *image) {
    NSData *tiffData = image.TIFFRepresentation;
    if (!tiffData) {
        return nil;
    }
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:tiffData];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSData *HSMpvPNGDataByLimitingMaximumDimension(
    NSData *pngData,
    NSInteger maximumDimension
) {
    if (maximumDimension <= 0) {
        return pngData;
    }
    NSImageRep *imageRep = [NSBitmapImageRep imageRepWithData:pngData];
    if (![imageRep isKindOfClass:NSBitmapImageRep.class]) {
        return pngData;
    }
    NSBitmapImageRep *bitmap = (NSBitmapImageRep *)imageRep;
    NSInteger width = bitmap.pixelsWide;
    NSInteger height = bitmap.pixelsHigh;
    NSInteger longestSide = MAX(width, height);
    if (width <= 0 || height <= 0 || longestSide <= maximumDimension) {
        return pngData;
    }

    CGFloat scale = (CGFloat)maximumDimension / (CGFloat)longestSide;
    NSInteger outputWidth = MAX(1, (NSInteger)floor((CGFloat)width * scale));
    NSInteger outputHeight = MAX(1, (NSInteger)floor((CGFloat)height * scale));
    NSImage *source = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [source addRepresentation:bitmap];
    NSImage *scaled = [[NSImage alloc] initWithSize:NSMakeSize(outputWidth, outputHeight)];
    [scaled lockFocus];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    [source drawInRect:NSMakeRect(0, 0, outputWidth, outputHeight)
        fromRect:NSZeroRect
        operation:NSCompositingOperationCopy
        fraction:1.0];
    [scaled unlockFocus];
    return HSMpvPNGDataFromImage(scaled) ?: pngData;
}

static NSURL *HSMpvCreateThumbnailOutputDirectory(NSString **errorMessage) {
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory()]
        .URLByStandardizingPath;
    directory = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"hoshi-video-thumbnail-%@", NSUUID.UUID.UUIDString]
        isDirectory:YES];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
        withIntermediateDirectories:YES
        attributes:nil
        error:&error]) {
        if (errorMessage) {
            *errorMessage = error.localizedDescription;
        }
        return nil;
    }
    return directory;
}

static NSData *HSMpvFirstPNGDataInDirectory(NSURL *directory) {
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:nil
        options:NSDirectoryEnumerationSkipsHiddenFiles
        error:nil];
    NSArray<NSURL *> *pngFiles = [contents filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
            (void)bindings;
            return [url.pathExtension caseInsensitiveCompare:@"png"] == NSOrderedSame;
        }]
    ];
    NSURL *first = [pngFiles sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent localizedStandardCompare:right.lastPathComponent];
    }].firstObject;
    return first ? [NSData dataWithContentsOfURL:first] : nil;
}

static NSData *HSMpvRenderThumbnailPNGData(
    NSURL *url,
    NSInteger maximumDimension,
    double time,
    HSMpvCancellationHandler isCancelled,
    NSString **errorMessage
) {
    NSString *failure = nil;
    if (HSMpvThumbnailIsCancelled(isCancelled)) {
        if (errorMessage) {
            *errorMessage = @"The video thumbnail was cancelled.";
        }
        return nil;
    }

    NSURL *outputDirectory = HSMpvCreateThumbnailOutputDirectory(&failure);
    if (!outputDirectory) {
        if (errorMessage) {
            *errorMessage = failure ?: @"The video thumbnail output directory could not be created.";
        }
        return nil;
    }
    if (HSMpvThumbnailIsCancelled(isCancelled)) {
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = @"The video thumbnail was cancelled.";
        }
        return nil;
    }

    mpv_handle *thumbnailer = mpv_create();
    if (!thumbnailer) {
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = @"The bundled video thumbnailer is unavailable.";
        }
        return nil;
    }
    if (HSMpvThumbnailIsCancelled(isCancelled)) {
        mpv_terminate_destroy(thumbnailer);
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = @"The video thumbnail was cancelled.";
        }
        return nil;
    }

    NSString *startTime = [NSString stringWithFormat:@"%.6f", MAX(0, time)];
    NSArray<NSArray<NSString *> *> *options = @[
        @[@"config", @"no"],
        @[@"osc", @"no"],
        @[@"input-default-bindings", @"no"],
        @[@"input-cursor", @"no"],
        @[@"sid", @"no"],
        @[@"audio", @"no"],
        @[@"vo", @"image"],
        @[@"vo-image-format", @"png"],
        @[@"vo-image-outdir", outputDirectory.path],
        @[@"frames", @"1"],
        @[@"start", startTime]
    ];
    for (NSArray<NSString *> *option in options) {
        if (HSMpvThumbnailIsCancelled(isCancelled)) {
            mpv_terminate_destroy(thumbnailer);
            [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
            if (errorMessage) {
                *errorMessage = @"The video thumbnail was cancelled.";
            }
            return nil;
        }
        if (!HSMpvSetThumbnailOption(thumbnailer, option[0], option[1], &failure)) {
            mpv_terminate_destroy(thumbnailer);
            [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
            if (errorMessage) {
                *errorMessage = failure;
            }
            return nil;
        }
    }
    if (HSMpvThumbnailIsCancelled(isCancelled)) {
        mpv_terminate_destroy(thumbnailer);
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = @"The video thumbnail was cancelled.";
        }
        return nil;
    }

    int status = mpv_initialize(thumbnailer);
    if (status < 0) {
        mpv_terminate_destroy(thumbnailer);
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:@"The bundled video thumbnailer could not start: %s",
                mpv_error_string(status)];
        }
        return nil;
    }
    if (HSMpvThumbnailIsCancelled(isCancelled)) {
        mpv_terminate_destroy(thumbnailer);
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = @"The video thumbnail was cancelled.";
        }
        return nil;
    }

    const char *loadCommand[] = {"loadfile", url.fileSystemRepresentation, "replace", NULL};
    status = mpv_command(thumbnailer, loadCommand);
    if (status < 0) {
        mpv_terminate_destroy(thumbnailer);
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = [NSString stringWithFormat:@"The video thumbnail could not be opened: %s",
                mpv_error_string(status)];
        }
        return nil;
    }
    if (HSMpvThumbnailIsCancelled(isCancelled)) {
        mpv_terminate_destroy(thumbnailer);
        [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
        if (errorMessage) {
            *errorMessage = @"The video thumbnail was cancelled.";
        }
        return nil;
    }

    BOOL completed = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        if (HSMpvThumbnailIsCancelled(isCancelled)) {
            failure = @"The video thumbnail was cancelled.";
            completed = YES;
            break;
        }
        mpv_event *event = mpv_wait_event(thumbnailer, 0.1);
        if (!event || event->event_id == MPV_EVENT_NONE) {
            continue;
        }
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *endFile = (mpv_event_end_file *)event->data;
            if (endFile && endFile->error < 0) {
                failure = [NSString stringWithFormat:@"The video thumbnail could not be rendered: %s",
                    mpv_error_string(endFile->error)];
            }
            completed = YES;
        } else if (event->event_id == MPV_EVENT_SHUTDOWN) {
            failure = @"The bundled video thumbnailer stopped unexpectedly.";
            completed = YES;
        }
    }
    if (!completed) {
        failure = @"The video thumbnail timed out while rendering.";
    }

    mpv_terminate_destroy(thumbnailer);
    BOOL cancelled = HSMpvThumbnailIsCancelled(isCancelled)
        || [failure isEqualToString:@"The video thumbnail was cancelled."];
    NSData *pngData = (failure || cancelled) ? nil : HSMpvFirstPNGDataInDirectory(outputDirectory);
    [[NSFileManager defaultManager] removeItemAtURL:outputDirectory error:nil];
    if (pngData) {
        return HSMpvPNGDataByLimitingMaximumDimension(pngData, maximumDimension);
    }
    if (errorMessage) {
        *errorMessage = failure ?: @"The video thumbnail frame could not be encoded.";
    }
    return nil;
}

@implementation HSMpvThumbnailGenerator

+ (nullable NSData *)thumbnailPNGDataForURL:(NSURL *)url
    maximumDimension:(NSInteger)maximumDimension
    time:(double)time
    isCancelled:(HSMpvCancellationHandler)isCancelled
    errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    double requestedTime = MAX(0, time);
    NSString *lastError = nil;
    NSData *data = HSMpvRenderThumbnailPNGData(
        url,
        maximumDimension,
        requestedTime,
        isCancelled,
        &lastError
    );
    if (!data && requestedTime > 0 && !HSMpvThumbnailIsCancelled(isCancelled)) {
        data = HSMpvRenderThumbnailPNGData(
            url,
            maximumDimension,
            0,
            isCancelled,
            &lastError
        );
    }
    if (!data && errorMessage) {
        *errorMessage = lastError;
    }
    return data;
}

@end

static BOOL HSMpvSubtitleExtractionIsCancelled(HSMpvCancellationHandler isCancelled) {
    return isCancelled && isCancelled();
}

static void HSMpvSetSubtitleExtractionCancellationError(
    NSError * _Nullable * _Nullable error
) {
    if (error) {
        *error = [NSError errorWithDomain:@"HoshiVideoSubtitleExtraction" code:4 userInfo:@{
            NSLocalizedDescriptionKey: NSLocalizedString(@"Subtitle extraction was cancelled.", nil)
        }];
    }
}

static BOOL HSMpvValidateFFmpegRuntimeVersions(
    NSError * _Nullable * _Nullable error
) {
    typedef unsigned (*VersionFunction)(void);
    VersionFunction codecVersion = (VersionFunction)dlsym(RTLD_DEFAULT, "avcodec_version");
    VersionFunction formatVersion = (VersionFunction)dlsym(RTLD_DEFAULT, "avformat_version");
    VersionFunction utilVersion = (VersionFunction)dlsym(RTLD_DEFAULT, "avutil_version");
    if (!codecVersion || !formatVersion || !utilVersion) {
        if (error) {
            *error = [NSError errorWithDomain:@"HoshiVideoSubtitleExtraction" code:1 userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"The bundled subtitle extractor is unavailable.", nil),
                NSDebugDescriptionErrorKey: @"Required FFmpeg version symbols are unavailable."
            }];
        }
        return NO;
    }

    unsigned codecMajor = codecVersion() >> 16;
    unsigned formatMajor = formatVersion() >> 16;
    unsigned utilMajor = utilVersion() >> 16;
    if (codecMajor != LIBAVCODEC_VERSION_MAJOR
        || formatMajor != LIBAVFORMAT_VERSION_MAJOR
        || utilMajor != LIBAVUTIL_VERSION_MAJOR) {
        if (error) {
            NSString *debugDescription = [NSString stringWithFormat:
                @"FFmpeg ABI mismatch: compiled against avcodec/avformat/avutil %d/%d/%d, but loaded %u/%u/%u.",
                LIBAVCODEC_VERSION_MAJOR,
                LIBAVFORMAT_VERSION_MAJOR,
                LIBAVUTIL_VERSION_MAJOR,
                codecMajor,
                formatMajor,
                utilMajor];
            *error = [NSError errorWithDomain:@"HoshiVideoSubtitleExtraction" code:5 userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"The bundled subtitle extractor is unavailable.", nil),
                NSDebugDescriptionErrorKey: debugDescription
            }];
        }
        return NO;
    }
    return YES;
}

@implementation HSSubtitleTrackExtractor

+ (nullable HSExtractedSubtitleTrack *)extractTextSubtitleFromURL:(NSURL *)url
    streamIndex:(NSInteger)streamIndex
    isCancelled:(HSMpvCancellationHandler)isCancelled
    error:(NSError * _Nullable * _Nullable)error {
    if (!HSMpvValidateFFmpegRuntimeVersions(error)) {
        return nil;
    }

    typedef int (*OpenInputFunction)(AVFormatContext **, const char *, const AVInputFormat *, AVDictionary **);
    typedef int (*FindStreamInfoFunction)(AVFormatContext *, AVDictionary **);
    typedef AVPacket *(*PacketAllocFunction)(void);
    typedef void (*PacketFreeFunction)(AVPacket **);
    typedef void (*PacketUnrefFunction)(AVPacket *);
    typedef int (*ReadFrameFunction)(AVFormatContext *, AVPacket *);
    typedef void (*CloseInputFunction)(AVFormatContext **);

    OpenInputFunction openInput = (OpenInputFunction)dlsym(RTLD_DEFAULT, "avformat_open_input");
    FindStreamInfoFunction findStreamInfo = (FindStreamInfoFunction)dlsym(RTLD_DEFAULT, "avformat_find_stream_info");
    PacketAllocFunction packetAlloc = (PacketAllocFunction)dlsym(RTLD_DEFAULT, "av_packet_alloc");
    PacketFreeFunction packetFree = (PacketFreeFunction)dlsym(RTLD_DEFAULT, "av_packet_free");
    PacketUnrefFunction packetUnref = (PacketUnrefFunction)dlsym(RTLD_DEFAULT, "av_packet_unref");
    ReadFrameFunction readFrame = (ReadFrameFunction)dlsym(RTLD_DEFAULT, "av_read_frame");
    CloseInputFunction closeInput = (CloseInputFunction)dlsym(RTLD_DEFAULT, "avformat_close_input");
    if (!openInput || !findStreamInfo || !packetAlloc || !packetFree
        || !packetUnref || !readFrame || !closeInput) {
        if (error) {
            *error = [NSError errorWithDomain:@"HoshiVideoSubtitleExtraction" code:1 userInfo:@{
            NSLocalizedDescriptionKey: NSLocalizedString(@"The bundled subtitle extractor is unavailable.", nil)
            }];
        }
        return nil;
    }

    if (HSMpvSubtitleExtractionIsCancelled(isCancelled)) {
        HSMpvSetSubtitleExtractionCancellationError(error);
        return nil;
    }

    AVFormatContext *context = NULL;
    if (openInput(&context, url.fileSystemRepresentation, NULL, NULL) < 0
        || !context) {
        if (context) closeInput(&context);
        if (error) {
            *error = [NSError errorWithDomain:@"HoshiVideoSubtitleExtraction" code:2 userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"The selected subtitle track could not be read.", nil)
            }];
        }
        return nil;
    }
    if (HSMpvSubtitleExtractionIsCancelled(isCancelled)) {
        closeInput(&context);
        HSMpvSetSubtitleExtractionCancellationError(error);
        return nil;
    }
    if (findStreamInfo(context, NULL) < 0) {
        closeInput(&context);
        if (error) {
            *error = [NSError errorWithDomain:@"HoshiVideoSubtitleExtraction" code:2 userInfo:@{
                NSLocalizedDescriptionKey: NSLocalizedString(@"The selected subtitle track could not be read.", nil)
            }];
        }
        return nil;
    }
    if (HSMpvSubtitleExtractionIsCancelled(isCancelled)) {
        closeInput(&context);
        HSMpvSetSubtitleExtractionCancellationError(error);
        return nil;
    }

    AVStream *targetStream = NULL;
    for (unsigned int index = 0; index < context->nb_streams; index++) {
        if (context->streams[index] && context->streams[index]->index == streamIndex) {
            targetStream = context->streams[index];
            break;
        }
    }
    if (!targetStream || targetStream->time_base.den == 0) {
        closeInput(&context);
        if (error) {
            *error = [NSError errorWithDomain:@"HoshiVideoSubtitleExtraction" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"The selected subtitle track is no longer available."
            }];
        }
        return nil;
    }

    NSData *codecPrivateData = nil;
    if (targetStream->codecpar
        && targetStream->codecpar->extradata
        && targetStream->codecpar->extradata_size > 0) {
        codecPrivateData = [NSData dataWithBytes:targetStream->codecpar->extradata
            length:(NSUInteger)targetStream->codecpar->extradata_size];
    }

    NSMutableArray<HSExtractedSubtitleCue *> *result = [NSMutableArray array];
    AVPacket *packet = packetAlloc();
    if (!packet) {
        closeInput(&context);
        return nil;
    }
    BOOL wasCancelled = NO;
    while (!HSMpvSubtitleExtractionIsCancelled(isCancelled)
        && readFrame(context, packet) >= 0) {
        if (HSMpvSubtitleExtractionIsCancelled(isCancelled)) {
            packetUnref(packet);
            wasCancelled = YES;
            break;
        }
        if (packet->stream_index == streamIndex
            && packet->pts != AV_NOPTS_VALUE
            && packet->data
            && packet->size > 0) {
            NSData *rawPayload = [NSData dataWithBytes:packet->data
                length:(NSUInteger)packet->size];
            NSString *text = [[NSString alloc] initWithBytes:packet->data
                length:(NSUInteger)packet->size
                encoding:NSUTF8StringEncoding];
            if (rawPayload.length > 0) {
                double scale = (double)targetStream->time_base.num
                    / (double)targetStream->time_base.den;
                HSExtractedSubtitleCue *cue = [[HSExtractedSubtitleCue alloc] init];
                cue.startTime = MAX(0, packet->pts * scale);
                cue.endTime = cue.startTime + (packet->duration > 0
                    ? packet->duration * scale
                    : 10);
                cue.text = text ?: @"";
                cue.rawPayload = rawPayload;
                cue.presentationTimestamp = packet->pts;
                cue.decodingTimestamp = packet->dts;
                cue.packetDuration = packet->duration;
                cue.timeBaseNumerator = targetStream->time_base.num;
                cue.timeBaseDenominator = targetStream->time_base.den;
                cue.packetFlags = packet->flags;
                cue.filePosition = packet->pos;
                [result addObject:cue];
            }
        }
        packetUnref(packet);
    }
    wasCancelled = wasCancelled || HSMpvSubtitleExtractionIsCancelled(isCancelled);
    packetFree(&packet);
    closeInput(&context);
    if (wasCancelled) {
        HSMpvSetSubtitleExtractionCancellationError(error);
        return nil;
    }
    HSExtractedSubtitleTrack *track = [[HSExtractedSubtitleTrack alloc] init];
    track.codecPrivateData = codecPrivateData;
    track.packets = result;
    return track;
}

@end

@implementation HSMpvChapterInfo
@end

@implementation HSMpvSubtitleCueInfo
@end

static HSMpvSubtitleCueInfo *HSMpvCopySubtitleCueInfo(HSMpvSubtitleCueInfo *source) {
    HSMpvSubtitleCueInfo *copy = [[HSMpvSubtitleCueInfo alloc] init];
    copy.cueID = source.cueID;
    copy.startTime = source.startTime;
    copy.endTime = source.endTime;
    copy.text = source.text;
    return copy;
}

static void *HSMpvGetOpenGLProcAddress(void *context, const char *name) {
    CFStringRef symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    void *address = bundle ? CFBundleGetFunctionPointerForName(bundle, symbol) : NULL;
    CFRelease(symbol);
    return address;
}

@class HSMpvRenderContextState;

@interface HSMpvOpenGLLayer : CAOpenGLLayer
@property (nonatomic, strong, readonly) HSMpvRenderContextState *renderContextState;
@property (nonatomic, readonly) BOOL hasRenderContext;
@property (atomic, assign) BOOL forceDraw;
@property (atomic, assign) BOOL needsFlip;
@property (atomic, assign) BOOL usesImmediateSwapReporting;
@property (atomic, assign, getter=isInLiveResize) BOOL inLiveResize;
- (instancetype)initForReplacementFromLayer:(HSMpvOpenGLLayer *)layer;
- (void)performWithLockedOpenGLContext:(void (^)(void))body;
- (void)setRenderContext:(nullable mpv_render_context *)renderContext;
- (void)withRenderContext:(void (^)(mpv_render_context *renderContext))body;
- (void)requestRender;
- (void)requestForcedRender;
- (void)beginLiveResize;
- (void)endLiveResize;
- (void)resetLiveResizeState;
- (void)configureDisplayLinkForScreen:(NSScreen *)screen;
- (void)stopDisplayLink;
- (double)displayRefreshRate;
- (void)reportSwapForDisplayLink;
@end

static CVReturn HSMpvDisplayLinkCallback(
    CVDisplayLinkRef displayLink,
    const CVTimeStamp *now,
    const CVTimeStamp *outputTime,
    CVOptionFlags flagsIn,
    CVOptionFlags *flagsOut,
    void *context
) {
    (void)displayLink;
    (void)now;
    (void)outputTime;
    (void)flagsIn;
    (void)flagsOut;
    HSMpvOpenGLLayer *layer = (__bridge HSMpvOpenGLLayer *)context;
    [layer reportSwapForDisplayLink];
    return kCVReturnSuccess;
}

@interface HSMpvMainThreadPriorityLock : NSObject
- (void)beforeLocking;
- (void)afterLocked;
@end

@implementation HSMpvMainThreadPriorityLock {
    NSCondition *_condition;
    BOOL _mainThreadNeedsLock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (void)beforeLocking {
    [_condition lock];
    if (NSThread.isMainThread) {
        _mainThreadNeedsLock = YES;
    } else {
        while (_mainThreadNeedsLock) {
            [_condition wait];
        }
    }
    [_condition unlock];
}

- (void)afterLocked {
    if (!NSThread.isMainThread) {
        return;
    }
    [_condition lock];
    _mainThreadNeedsLock = NO;
    [_condition broadcast];
    [_condition unlock];
}

@end

@interface HSMpvRenderContextState : NSObject
- (BOOL)hasContext;
- (void)setContext:(nullable mpv_render_context *)context;
- (nullable mpv_render_context *)takeContextForTransfer;
- (void)withContext:(void (^)(mpv_render_context *context))body;
- (void)invalidateAndPerform:(void (^)(mpv_render_context *context))body;
@end

@implementation HSMpvRenderContextState {
    pthread_rwlock_t _lifetimeLock;
    NSLock *_renderAPILock;
    mpv_render_context *_context;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        pthread_rwlock_init(&_lifetimeLock, NULL);
        _renderAPILock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    pthread_rwlock_destroy(&_lifetimeLock);
}

- (BOOL)hasContext {
    pthread_rwlock_rdlock(&_lifetimeLock);
    BOOL hasContext = _context != NULL;
    pthread_rwlock_unlock(&_lifetimeLock);
    return hasContext;
}

- (void)setContext:(mpv_render_context *)context {
    pthread_rwlock_wrlock(&_lifetimeLock);
    _context = context;
    pthread_rwlock_unlock(&_lifetimeLock);
}

- (mpv_render_context *)takeContextForTransfer {
    pthread_rwlock_wrlock(&_lifetimeLock);
    mpv_render_context *context = _context;
    _context = NULL;
    pthread_rwlock_unlock(&_lifetimeLock);
    return context;
}

- (void)withContext:(void (^)(mpv_render_context *context))body {
    pthread_rwlock_rdlock(&_lifetimeLock);
    mpv_render_context *context = _context;
    if (context) {
        [_renderAPILock lock];
        body(context);
        [_renderAPILock unlock];
    }
    pthread_rwlock_unlock(&_lifetimeLock);
}

- (void)invalidateAndPerform:(void (^)(mpv_render_context *context))body {
    pthread_rwlock_wrlock(&_lifetimeLock);
    mpv_render_context *context = _context;
    _context = NULL;
    if (context) {
        body(context);
    }
    pthread_rwlock_unlock(&_lifetimeLock);
}

@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@implementation HSMpvOpenGLLayer {
    CGLPixelFormatObj _pixelFormat;
    CGLContextObj _context;
    dispatch_queue_t _mpvGLQueue;
    NSRecursiveLock *_displayLock;
    HSMpvMainThreadPriorityLock *_mainThreadPriorityLock;
    HSMpvRenderContextState *_renderContextState;
    GLint _bufferDepth;
    GLint _framebufferID;
    CVDisplayLinkRef _displayLink;
    CGDirectDisplayID _currentDisplayID;
    BOOL _usesImmediateSwapReporting;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _bufferDepth = 8;
        _framebufferID = 1;
        self.usesImmediateSwapReporting = YES;
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INTERACTIVE,
            0
        );
        _mpvGLQueue = dispatch_queue_create("moe.shishamo.hoshi.video.mpvgl", queueAttributes);
        self.asynchronous = NO;
        self.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        self.needsDisplayOnBoundsChange = NO;
        self.backgroundColor = NSColor.blackColor.CGColor;
        self.contentsGravity = kCAGravityResizeAspectFill;
        _displayLock = [[NSRecursiveLock alloc] init];
        _mainThreadPriorityLock = [[HSMpvMainThreadPriorityLock alloc] init];
        _renderContextState = [[HSMpvRenderContextState alloc] init];
        [self createOpenGLObjects];
    }
    return self;
}

- (instancetype)initWithLayer:(id)layer {
    if (![layer isKindOfClass:HSMpvOpenGLLayer.class]) {
        return nil;
    }

    // Core Animation requires subclasses to copy their custom ivars before
    // calling super so any shadow initialization hooks see valid GL/state.
    HSMpvOpenGLLayer *previousLayer = (HSMpvOpenGLLayer *)layer;
    _pixelFormat = previousLayer->_pixelFormat
        ? CGLRetainPixelFormat(previousLayer->_pixelFormat)
        : NULL;
    _context = previousLayer->_context
        ? CGLRetainContext(previousLayer->_context)
        : NULL;
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL,
        QOS_CLASS_USER_INTERACTIVE,
        0
    );
    _mpvGLQueue = dispatch_queue_create(
        "moe.shishamo.hoshi.video.mpvgl.shadow",
        queueAttributes
    );
    _displayLock = previousLayer->_displayLock;
    _mainThreadPriorityLock = [[HSMpvMainThreadPriorityLock alloc] init];
    _renderContextState = previousLayer->_renderContextState;
    _bufferDepth = previousLayer->_bufferDepth;
    _framebufferID = previousLayer->_framebufferID;
    _displayLink = NULL;
    _currentDisplayID = 0;

    self = [super initWithLayer:layer];
    if (!self) {
        return nil;
    }
    self.forceDraw = previousLayer.forceDraw;
    self.needsFlip = previousLayer.needsFlip;
    self.usesImmediateSwapReporting = previousLayer.usesImmediateSwapReporting;
    self.inLiveResize = previousLayer.inLiveResize;
    self.asynchronous = previousLayer.asynchronous;
    self.autoresizingMask = previousLayer.autoresizingMask;
    self.backgroundColor = previousLayer.backgroundColor;
    self.wantsExtendedDynamicRangeContent = previousLayer.wantsExtendedDynamicRangeContent;
    self.contentsGravity = previousLayer.contentsGravity;
    self.contentsFormat = previousLayer.contentsFormat;
    return self;
}

- (instancetype)initForReplacementFromLayer:(HSMpvOpenGLLayer *)layer {
    // `initWithLayer:` is reserved for shadow/presentation copies created by
    // Core Animation. Build a real model layer through the designated init,
    // retaining only the GL objects that bind libmpv to its creation context.
    self = [super init];
    if (!self) {
        return nil;
    }

    _pixelFormat = layer->_pixelFormat
        ? CGLRetainPixelFormat(layer->_pixelFormat)
        : NULL;
    _context = layer->_context
        ? CGLRetainContext(layer->_context)
        : NULL;
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL,
        QOS_CLASS_USER_INTERACTIVE,
        0
    );
    _mpvGLQueue = dispatch_queue_create(
        "moe.shishamo.hoshi.video.mpvgl.replacement",
        queueAttributes
    );
    _displayLock = layer->_displayLock;
    _mainThreadPriorityLock = [[HSMpvMainThreadPriorityLock alloc] init];
    _renderContextState = [[HSMpvRenderContextState alloc] init];
    _bufferDepth = layer->_bufferDepth;
    _framebufferID = layer->_framebufferID;
    _displayLink = NULL;
    _currentDisplayID = 0;
    self.forceDraw = layer.forceDraw;
    self.needsFlip = layer.needsFlip;
    self.usesImmediateSwapReporting = layer.usesImmediateSwapReporting;
    self.inLiveResize = NO;
    self.asynchronous = NO;
    self.autoresizingMask = layer.autoresizingMask;
    self.needsDisplayOnBoundsChange = layer.needsDisplayOnBoundsChange;
    self.backgroundColor = layer.backgroundColor;
    self.contentsGravity = layer.contentsGravity;
    self.contentsFormat = layer.contentsFormat;
    self.contentsScale = layer.contentsScale;
    self.colorspace = layer.colorspace;
    self.wantsExtendedDynamicRangeContent = layer.wantsExtendedDynamicRangeContent;
    return self;
}

- (HSMpvRenderContextState *)renderContextState {
    return _renderContextState;
}

- (void)setRenderContext:(mpv_render_context *)renderContext {
    [_renderContextState setContext:renderContext];
}

- (BOOL)hasRenderContext {
    return [_renderContextState hasContext];
}

- (void)withRenderContext:(void (^)(mpv_render_context *renderContext))body {
    [_renderContextState withContext:body];
}

- (void)dealloc {
    [self stopDisplayLink];
    if (_displayLink) {
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
    if (_context) {
        CGLSetCurrentContext(NULL);
        CGLReleaseContext(_context);
    }
    if (_pixelFormat) {
        CGLReleasePixelFormat(_pixelFormat);
    }
}

- (void)configureDisplayLinkForScreen:(NSScreen *)screen {
    NSNumber *displayNumber = screen.deviceDescription[@"NSScreenNumber"];
    if (!displayNumber) {
        [self stopDisplayLink];
        return;
    }
    CGDirectDisplayID displayID = (CGDirectDisplayID)displayNumber.unsignedIntValue;
    if (!_displayLink) {
        CVReturn createStatus = CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
        if (createStatus != kCVReturnSuccess || !_displayLink) {
            self.usesImmediateSwapReporting = YES;
            return;
        }
        CVReturn callbackStatus = CVDisplayLinkSetOutputCallback(
            _displayLink,
            HSMpvDisplayLinkCallback,
            (__bridge void *)self
        );
        if (callbackStatus != kCVReturnSuccess) {
            CVDisplayLinkRelease(_displayLink);
            _displayLink = NULL;
            self.usesImmediateSwapReporting = YES;
            return;
        }
    }

    BOOL displayChanged = _currentDisplayID != displayID;
    if (displayChanged && CVDisplayLinkIsRunning(_displayLink)) {
        CVDisplayLinkStop(_displayLink);
    }
    if (displayChanged) {
        CVReturn displayStatus = CVDisplayLinkSetCurrentCGDisplay(_displayLink, displayID);
        if (displayStatus != kCVReturnSuccess) {
            _currentDisplayID = 0;
            self.usesImmediateSwapReporting = YES;
            return;
        }
        _currentDisplayID = displayID;
    }

    if (self.hasRenderContext && !CVDisplayLinkIsRunning(_displayLink)) {
        CVReturn startStatus = CVDisplayLinkStart(_displayLink);
        self.usesImmediateSwapReporting = startStatus != kCVReturnSuccess;
    } else if (self.hasRenderContext && CVDisplayLinkIsRunning(_displayLink)) {
        self.usesImmediateSwapReporting = NO;
    }
}

- (void)stopDisplayLink {
    if (_displayLink && CVDisplayLinkIsRunning(_displayLink)) {
        CVDisplayLinkStop(_displayLink);
    }
    self.usesImmediateSwapReporting = YES;
}

- (double)displayRefreshRate {
    if (!_displayLink) {
        return 0;
    }
    double actualPeriod = CVDisplayLinkGetActualOutputVideoRefreshPeriod(_displayLink);
    if (actualPeriod > 0) {
        return 1.0 / actualPeriod;
    }
    CVTime nominalPeriod = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(_displayLink);
    if ((nominalPeriod.flags & kCVTimeIsIndefinite) == 0
        && nominalPeriod.timeValue > 0
        && nominalPeriod.timeScale > 0) {
        return (double)nominalPeriod.timeScale / (double)nominalPeriod.timeValue;
    }
    return 0;
}

- (void)reportSwapForDisplayLink {
    if (self.usesImmediateSwapReporting) {
        return;
    }
    [self performWithLockedOpenGLContext:^{
        [self withRenderContext:^(mpv_render_context *renderContext) {
            mpv_render_context_report_swap(renderContext);
        }];
    }];
}

- (void)createOpenGLObjects {
    CGLPixelFormatAttribute highDepthAttributes[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated,
        kCGLPFADoubleBuffer,
        kCGLPFAColorSize,
        (CGLPixelFormatAttribute)64,
        kCGLPFAColorFloat,
        kCGLPFASupportsAutomaticGraphicsSwitching,
        (CGLPixelFormatAttribute)0
    };
    GLint pixelFormatCount = 0;
    CGLError pixelFormatError = CGLChoosePixelFormat(
        highDepthAttributes,
        &_pixelFormat,
        &pixelFormatCount
    );
    if (pixelFormatError == kCGLNoError && _pixelFormat) {
        _bufferDepth = 16;
        self.contentsFormat = kCAContentsFormatRGBA16Float;
    } else {
        if (_pixelFormat) {
            CGLReleasePixelFormat(_pixelFormat);
            _pixelFormat = NULL;
        }
        CGLPixelFormatAttribute standardDepthAttributes[] = {
            kCGLPFAOpenGLProfile,
            (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            (CGLPixelFormatAttribute)0
        };
        _bufferDepth = 8;
        pixelFormatError = CGLChoosePixelFormat(
            standardDepthAttributes,
            &_pixelFormat,
            &pixelFormatCount
        );
    }
    if (pixelFormatError != kCGLNoError || !_pixelFormat) {
        return;
    }
    CGLError contextError = CGLCreateContext(_pixelFormat, NULL, &_context);
    if (contextError != kCGLNoError) {
        _context = NULL;
        return;
    }
    if (_context) {
        GLint swapInterval = 1;
        (void)CGLSetParameter(_context, kCGLCPSwapInterval, &swapInterval);
        (void)CGLEnable(_context, kCGLCEMPEngine);
    }
}

- (BOOL)isReady {
    return _context != NULL && _pixelFormat != NULL;
}

- (void)performWithLockedOpenGLContext:(void (^)(void))body {
    if (!body) {
        return;
    }
    if (!_context) {
        body();
        return;
    }
    CGLLockContext(_context);
    CGLSetCurrentContext(_context);
    body();
    CGLUnlockContext(_context);
}

- (void)requestRender {
    [self requestRenderForcingFrame:NO];
}

- (void)requestForcedRender {
    [self requestRenderForcingFrame:YES];
}

- (void)beginLiveResize {
    self.inLiveResize = YES;
    self.asynchronous = YES;
    [self requestForcedRender];
}

- (void)endLiveResize {
    self.inLiveResize = NO;
    [self requestForcedRender];
}

- (void)resetLiveResizeState {
    self.inLiveResize = NO;
    self.asynchronous = NO;
}

- (void)requestRenderForcingFrame:(BOOL)force {
    dispatch_async(_mpvGLQueue, ^{
        if (force) {
            self.forceDraw = YES;
        }
        self.needsFlip = YES;
        [self display];
    });
}

- (void)display {
    // Playback can keep the GL queue almost continuously busy. Give AppKit's
    // main-thread layout/display work a turn before the background queue takes
    // this lock again, matching IINA's starvation guard.
    [_mainThreadPriorityLock beforeLocking];
    [_displayLock lock];
    [_mainThreadPriorityLock afterLocked];

    BOOL isUpdate = self.needsFlip;
    if (NSThread.isMainThread) {
        [super display];
    } else {
        [CATransaction begin];
        [super display];
        [CATransaction commit];
    }
    [CATransaction flush];

    if (isUpdate && self.needsFlip) {
        [self performWithLockedOpenGLContext:^{
            [self withRenderContext:^(mpv_render_context *renderContext) {
                uint64_t flags = mpv_render_context_update(renderContext);
                if ((flags & MPV_RENDER_UPDATE_FRAME) == 0) {
                    return;
                }
                int skip = 1;
                mpv_render_param parameters[] = {
                    { MPV_RENDER_PARAM_SKIP_RENDERING, &skip },
                    { MPV_RENDER_PARAM_INVALID, NULL }
                };
                mpv_render_context_render(renderContext, parameters);
            }];
        }];
    }
    [_displayLock unlock];
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    (void)mask;
    return _pixelFormat ? CGLRetainPixelFormat(_pixelFormat) : NULL;
}

- (void)releaseCGLPixelFormat:(CGLPixelFormatObj)pixelFormat {
    if (pixelFormat) {
        CGLReleasePixelFormat(pixelFormat);
    }
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat {
    (void)pixelFormat;
    return _context ? CGLRetainContext(_context) : NULL;
}

- (void)releaseCGLContext:(CGLContextObj)context {
    if (context) {
        CGLReleaseContext(context);
    }
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)context
    pixelFormat:(CGLPixelFormatObj)pixelFormat
    forLayerTime:(CFTimeInterval)time
    displayTime:(const CVTimeStamp *)timeStamp {
    (void)pixelFormat;
    (void)time;
    (void)timeStamp;
    if (self.inLiveResize && NSThread.isMainThread) {
        return NO;
    }
    if (!self.inLiveResize) {
        self.asynchronous = NO;
    }
    CGLSetCurrentContext(context);
    __block uint64_t flags = 0;
    [self withRenderContext:^(mpv_render_context *renderContext) {
        flags = mpv_render_context_update(renderContext);
    }];
    return self.forceDraw || ((flags & MPV_RENDER_UPDATE_FRAME) != 0);
}

- (void)drawInCGLContext:(CGLContextObj)context
    pixelFormat:(CGLPixelFormatObj)pixelFormat
    forLayerTime:(CFTimeInterval)time
    displayTime:(const CVTimeStamp *)timeStamp {
    (void)pixelFormat;
    (void)time;
    (void)timeStamp;
    self.needsFlip = NO;
    self.forceDraw = NO;
    CGLSetCurrentContext(context);
    glClear(GL_COLOR_BUFFER_BIT);
    __block BOOL renderedFrame = NO;
    [self withRenderContext:^(mpv_render_context *renderContext) {
        renderedFrame = YES;
        GLint framebufferID = 0;
        GLint viewport[4] = { 0, 0, 0, 0 };
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebufferID);
        glGetIntegerv(GL_VIEWPORT, viewport);
        if (framebufferID != 0) {
            _framebufferID = framebufferID;
        }
        mpv_opengl_fbo framebuffer = {
            .fbo = _framebufferID,
            .w = viewport[2],
            .h = viewport[3],
            .internal_format = 0
        };
        int flip = 1;
        mpv_render_param parameters[] = {
            { MPV_RENDER_PARAM_OPENGL_FBO, &framebuffer },
            { MPV_RENDER_PARAM_FLIP_Y, &flip },
            { MPV_RENDER_PARAM_DEPTH, &_bufferDepth },
            { MPV_RENDER_PARAM_INVALID, NULL }
        };
        mpv_render_context_render(renderContext, parameters);
        glFlush();
        if (self.usesImmediateSwapReporting) {
            mpv_render_context_report_swap(renderContext);
        }
    }];
    if (!renderedFrame) {
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        glFlush();
    }
}

@end
#pragma clang diagnostic pop

@interface HSMpvOpenGLView ()
@property (nonatomic, strong) HSMpvOpenGLLayer *openGLLayer;
@property (nonatomic, readonly) BOOL hasRenderContext;
@property (nonatomic, copy, nullable) void (^displayConfigurationHandler)(
    HSMpvOpenGLView *view,
    NSScreen *screen
);
@property (nonatomic, weak, nullable) NSScreen *configuredScreen;
- (void)performWithLockedOpenGLContext:(void (^)(void))body;
- (void)setRenderContext:(nullable mpv_render_context *)renderContext;
- (void)replaceRenderLayerWithCopyOfLayer:(HSMpvOpenGLLayer *)sourceLayer;
- (void)requestRender;
- (void)requestForcedRender;
- (void)stopDisplayLink;
- (BOOL)updateBackingConfiguration;
- (void)scheduleCoalescedLayoutRender;
- (void)invalidateCoalescedLayoutRender;
@end

@implementation HSMpvOpenGLView {
    uint64_t _layoutRenderGeneration;
    NSSize _lastLayoutSize;
    BOOL _fullScreenTransitionInProgress;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        self.wantsBestResolutionOpenGLSurface = YES;
        self.wantsExtendedDynamicRangeOpenGLSurface = YES;
#pragma clang diagnostic pop
        self.wantsLayer = YES;
        _openGLLayer = [[HSMpvOpenGLLayer alloc] init];
        _openGLLayer.frame = self.bounds;
        self.layer = _openGLLayer;
        _lastLayoutSize = self.bounds.size;
        [self updateBackingConfiguration];
    }
    return self;
}

- (void)dealloc {
    [self invalidateCoalescedLayoutRender];
    [self.openGLLayer resetLiveResizeState];
    [self stopDisplayLink];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isOpaque {
    return YES;
}

- (void)notifyReadyIfPossible {
    if (self.hasRenderContext
        || !self.window
        || !self.openGLLayer.isReady
        || NSIsEmptyRect(self.bounds)
        || !self.onReady) {
        return;
    }

    [self.openGLLayer performWithLockedOpenGLContext:^{}];
    if (!self.hasRenderContext) {
        self.onReady(self);
    }
}

- (BOOL)hasRenderContext {
    return self.openGLLayer.hasRenderContext;
}

- (void)setRenderContext:(mpv_render_context *)renderContext {
    if (!renderContext) {
        [self stopDisplayLink];
    }
    [self.openGLLayer setRenderContext:renderContext];
    if (renderContext) {
        if (self.window.inLiveResize) {
            [self.openGLLayer beginLiveResize];
        } else {
            [self.openGLLayer resetLiveResizeState];
        }
        NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
        if (screen) {
            [self.openGLLayer configureDisplayLinkForScreen:screen];
        }
    }
}

- (void)performWithLockedOpenGLContext:(void (^)(void))body {
    [self.openGLLayer performWithLockedOpenGLContext:body];
}

- (void)requestRender {
    [self.openGLLayer requestRender];
}

- (void)requestForcedRender {
    [self.openGLLayer requestForcedRender];
}

- (void)stopDisplayLink {
    [self.openGLLayer stopDisplayLink];
}

- (void)replaceRenderLayerWithCopyOfLayer:(HSMpvOpenGLLayer *)sourceLayer {
    if (!sourceLayer || sourceLayer == self.openGLLayer) {
        return;
    }
    [self invalidateCoalescedLayoutRender];
    [self.openGLLayer stopDisplayLink];
    HSMpvOpenGLLayer *replacementLayer =
        [[HSMpvOpenGLLayer alloc] initForReplacementFromLayer:sourceLayer];
    replacementLayer.frame = self.bounds;
    self.openGLLayer = replacementLayer;
    self.layer = replacementLayer;
    [self updateBackingConfiguration];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.openGLLayer resetLiveResizeState];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidChangeBackingPropertiesNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidChangeScreenNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowWillStartLiveResizeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidEndLiveResizeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidEnterFullScreenNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidExitFullScreenNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowWillEnterFullScreenNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowWillExitFullScreenNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:HSMpvWindowFullScreenTransitionDidFailNotification
                                                  object:nil];
    _fullScreenTransitionInProgress = NO;
    [self invalidateCoalescedLayoutRender];
    if (self.window) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowBackingPropertiesDidChange:)
                                                     name:NSWindowDidChangeBackingPropertiesNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowScreenDidChange:)
                                                     name:NSWindowDidChangeScreenNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillStartLiveResize:)
                                                     name:NSWindowWillStartLiveResizeNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidEndLiveResize:)
                                                     name:NSWindowDidEndLiveResizeNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowFullScreenTransitionDidEnd:)
                                                     name:NSWindowDidEnterFullScreenNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowFullScreenTransitionDidEnd:)
                                                     name:NSWindowDidExitFullScreenNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowFullScreenTransitionWillStart:)
                                                     name:NSWindowWillEnterFullScreenNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowFullScreenTransitionWillStart:)
                                                     name:NSWindowWillExitFullScreenNotification
                                                   object:self.window];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowFullScreenTransitionDidEnd:)
                                                     name:HSMpvWindowFullScreenTransitionDidFailNotification
                                                   object:self.window];
    }
    [self updateBackingConfiguration];
    [self notifyReadyIfPossible];
}

- (void)windowBackingPropertiesDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateBackingConfiguration];
}

- (void)windowScreenDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateBackingConfiguration];
}

- (void)windowWillStartLiveResize:(NSNotification *)notification {
    (void)notification;
    [self invalidateCoalescedLayoutRender];
    [self.openGLLayer beginLiveResize];
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
    (void)notification;
    [self invalidateCoalescedLayoutRender];
    [self.openGLLayer endLiveResize];
}

- (void)windowFullScreenTransitionWillStart:(NSNotification *)notification {
    (void)notification;
    _fullScreenTransitionInProgress = YES;
    [self invalidateCoalescedLayoutRender];
}

- (void)windowFullScreenTransitionDidEnd:(NSNotification *)notification {
    (void)notification;
    self.needsLayout = YES;
    [self layoutSubtreeIfNeeded];
    _fullScreenTransitionInProgress = NO;
    [self invalidateCoalescedLayoutRender];
    [self updateBackingConfiguration];
    [self notifyReadyIfPossible];
    [self requestForcedRender];
}

- (BOOL)updateBackingConfiguration {
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    CGFloat scale = MAX(screen.backingScaleFactor, 1.0);
    BOOL scaleChanged = fabs(self.openGLLayer.contentsScale - scale) > DBL_EPSILON;
    BOOL screenChanged = self.configuredScreen != screen;
    if (scaleChanged) {
        self.openGLLayer.contentsScale = scale;
    }
    if (screenChanged) {
        self.configuredScreen = screen;
        [self.openGLLayer configureDisplayLinkForScreen:screen];
    }
    if (screen && self.displayConfigurationHandler && (scaleChanged || screenChanged)) {
        self.displayConfigurationHandler(self, screen);
    }
    if (scaleChanged) {
        [self requestForcedRender];
    }
    return scaleChanged || screenChanged;
}

- (void)layout {
    [super layout];
    NSSize layoutSize = self.bounds.size;
    BOOL sizeChanged = !NSEqualSizes(layoutSize, _lastLayoutSize);
    _lastLayoutSize = layoutSize;
    [self updateBackingConfiguration];
    [self notifyReadyIfPossible];
    if (sizeChanged
        && !self.window.inLiveResize
        && !_fullScreenTransitionInProgress) {
        [self scheduleCoalescedLayoutRender];
    }
}

- (void)scheduleCoalescedLayoutRender {
    uint64_t generation = ++_layoutRenderGeneration;
    __weak HSMpvOpenGLView *weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
        dispatch_get_main_queue(),
        ^{
            HSMpvOpenGLView *strongSelf = weakSelf;
            if (!strongSelf
                || generation != strongSelf->_layoutRenderGeneration
                || strongSelf.window.inLiveResize
                || strongSelf->_fullScreenTransitionInProgress) {
                return;
            }
            [strongSelf requestForcedRender];
        }
    );
}

- (void)invalidateCoalescedLayoutRender {
    ++_layoutRenderGeneration;
}

@end

@interface HSMpvRenderUpdateTarget : NSObject
@property (atomic, weak, nullable) HSMpvOpenGLView *view;
@property (atomic) uint64_t generation;
@end

@implementation HSMpvRenderUpdateTarget
@end

@interface HSMpvClient () {
    mpv_handle *_handle;
    mpv_render_context *_renderContext;
    HSMpvOpenGLLayer *_renderLayer;
    HSMpvRenderContextState *_renderContextState;
    HSMpvRenderUpdateTarget *_renderUpdateTarget;
    void *_renderUpdateContext;
    dispatch_queue_t _eventQueue;
    dispatch_queue_t _ambientPreviewQueue;
    __weak HSMpvOpenGLView *_view;
    double _currentTime;
    double _duration;
    BOOL _paused;
    BOOL _loaded;
    BOOL _shuttingDown;
    double _speed;
    double _volume;
    BOOL _muted;
    double _subtitleDelay;
    double _audioDelay;
    NSString *_loopMode;
    double _abLoopStart;
    double _abLoopEnd;
    NSString *_aspectRatio;
    NSInteger _rotation;
    std::atomic<NSInteger> _sourceVideoRotation;
    NSInteger _videoWidth;
    NSInteger _videoHeight;
    BOOL _hdrEnhancementEnabled;
    NSString *_videoPrimaries;
    NSString *_videoGamma;
    double _lastSubtitleRefreshTime;
    CFTimeInterval _lastTimePositionStateEmitClock;
    double _lastEmittedStateTimePosition;
    NSUInteger _subtitleCueSignature;
    NSUInteger _subtitleCueCount;
    NSRecursiveLock *_subtitleCueLock;
    NSMutableArray<HSMpvSubtitleCueInfo *> *_fallbackSubtitleCues;
    std::atomic<uint64_t> _loadGeneration;
    std::atomic_bool _nativeSubtitleRenderingEnabled;
    std::atomic<int64_t> _internalASSSubtitleEffectsTrackID;
    std::atomic<int64_t> _internalASSSubtitleLogicalTrackID;
    NSString *_pendingRemoteAudioURLString;
    NSString *_expectedRemoteAudioURLString;
    BOOL _remoteAudioAttachmentReported;
}
- (void)startEventLoop;
- (void)runEventLoop;
- (void)installRenderUpdateCallbackForView:(HSMpvOpenGLView *)view;
- (void)clearRenderUpdateCallback;
- (void)releaseRenderUpdateContext;
- (void)installDisplayConfigurationCallbackForView:(HSMpvOpenGLView *)view;
- (void)refreshDisplayColorConfiguration;
- (void)applyDisplayColorConfigurationForView:(HSMpvOpenGLView *)view
    screen:(NSScreen *)screen;
- (void)applySDRDisplayColorConfigurationForView:(HSMpvOpenGLView *)view
    screen:(NSScreen *)screen;
- (BOOL)applyHDRDisplayColorConfigurationForView:(HSMpvOpenGLView *)view
    screen:(NSScreen *)screen;
- (void)handleEvent:(mpv_event *)event;
- (void)handlePropertyChange:(mpv_event_property *)property;
- (BOOL)loadRemoteAudioURLString:(NSString *)audioURLString;
- (void)loadPendingRemoteAudioIfNeeded;
- (void)scheduleRemoteAudioAttachmentDeadline;
- (void)emitRemoteAudioStateAttached:(BOOL)attached
    errorMessage:(nullable NSString *)errorMessage;
- (BOOL)shouldEmitTimePositionState;
- (void)emitStateWithError:(nullable NSString *)errorMessage;
- (void)emitTracksFromNode:(mpv_node *)node;
- (void)emitChaptersFromNode:(mpv_node *)node;
- (void)emitSubtitleCuesFromNode:(nullable mpv_node *)node;
- (void)emitSubtitleCueSnapshot:(NSArray<HSMpvSubtitleCueInfo *> *)cues;
- (void)resetSubtitleCueCache;
- (NSArray<HSMpvSubtitleCueInfo *> *)upsertFallbackSubtitleCueWithText:(NSString *)text
    startTime:(double)startTime
    endTime:(double)endTime;
- (NSArray<HSMpvSubtitleCueInfo *> *)fallbackSubtitleCueSnapshot;
- (void)refreshSubtitleCues;
- (void)refreshCurrentSubtitleCue;
- (BOOL)isCurrentLoadGeneration:(uint64_t)guardedLoadGeneration;
- (void)clearASSSubtitleEffectsRestoringLogicalTrack:(BOOL)restoreLogicalTrack;
@end

static void HSMpvRenderUpdate(void *context) {
    if (!context) {
        return;
    }
    HSMpvRenderUpdateTarget *target = (__bridge HSMpvRenderUpdateTarget *)context;
    uint64_t generation = target.generation;
    if (target.generation != generation) {
        return;
    }
    HSMpvOpenGLView *view = target.view;
    [view requestRender];
}

@implementation HSMpvClient

+ (nullable instancetype)makeClientWithErrorMessage:(NSString **)errorMessage {
    NSError *error = nil;
    HSMpvClient *client = [[self alloc] initWithError:&error];
    if (!client && errorMessage) {
        *errorMessage = error.localizedDescription;
    }
    return client;
}

- (nullable instancetype)initWithError:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    _eventQueue = dispatch_queue_create("moe.shishamo.hoshi.video.mpv-events", DISPATCH_QUEUE_SERIAL);
    _ambientPreviewQueue = dispatch_queue_create(
        "moe.shishamo.hoshi.video.ambient-preview",
        DISPATCH_QUEUE_SERIAL
    );
    _renderUpdateTarget = [[HSMpvRenderUpdateTarget alloc] init];
    _loadGeneration.store(0, std::memory_order_release);
    _nativeSubtitleRenderingEnabled.store(false, std::memory_order_release);
    _internalASSSubtitleEffectsTrackID.store(0, std::memory_order_release);
    _internalASSSubtitleLogicalTrackID.store(0, std::memory_order_release);
    _handle = mpv_create();
    if (!_handle) {
        if (error) {
            *error = [NSError errorWithDomain:HSMpvErrorDomain code:-1 userInfo:@{
                NSLocalizedDescriptionKey: @"Unable to create the video playback engine."
            }];
        }
        return nil;
    }

    mpv_set_option_string(_handle, "config", "no");
    mpv_set_option_string(_handle, "osc", "no");
    mpv_set_option_string(_handle, "input-default-bindings", "no");
    mpv_set_option_string(_handle, "input-cursor", "no");
    mpv_set_option_string(_handle, "sid", "no");
    mpv_set_option_string(_handle, "vo", "libmpv");
    mpv_set_option_string(_handle, "keep-open", "yes");

    int status = mpv_initialize(_handle);
    if (status < 0) {
        if (error) {
            NSString *message = [NSString stringWithUTF8String:mpv_error_string(status)];
            *error = [NSError errorWithDomain:HSMpvErrorDomain code:status userInfo:@{
                NSLocalizedDescriptionKey: message
            }];
        }
        mpv_destroy(_handle);
        _handle = NULL;
        return nil;
    }

    mpv_observe_property(_handle, 1, "time-pos", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 2, "duration", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 3, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(_handle, 4, "speed", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 5, "volume", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 6, "mute", MPV_FORMAT_FLAG);
    mpv_observe_property(_handle, 7, "sub-delay", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 8, "track-list", MPV_FORMAT_NODE);
    mpv_observe_property(_handle, 9, "audio-delay", MPV_FORMAT_DOUBLE);
    mpv_observe_property(_handle, 10, "chapter-list", MPV_FORMAT_NODE);
    mpv_observe_property(_handle, 11, "video-rotate", MPV_FORMAT_INT64);
    mpv_observe_property(_handle, 12, "video-params", MPV_FORMAT_NODE);
    mpv_observe_property(_handle, 13, "osd-dimensions", MPV_FORMAT_NODE);
    _speed = 1.0;
    _volume = 100.0;
    _loopMode = @"none";
    _abLoopStart = NAN;
    _abLoopEnd = NAN;
    _aspectRatio = @"-1";
    _lastEmittedStateTimePosition = NAN;
    _subtitleCueLock = [[NSRecursiveLock alloc] init];
    _fallbackSubtitleCues = [NSMutableArray array];
    [self startEventLoop];
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (BOOL)attachToView:(HSMpvOpenGLView *)view {
    if (!_handle || _shuttingDown) {
        return NO;
    }
    if (_renderContext && _view != view) {
        // Keep the active video chain alive while SwiftUI replaces its host.
        // The new model layer retains the exact CGL objects used at render-
        // context creation, but receives fresh lifetime state. Taking the old
        // state under the creation CGL lock waits for every old shadow/API
        // borrower and makes all subsequent old-layer draws no-ops.
        HSMpvOpenGLView *previousView = _view;
        HSMpvOpenGLLayer *previousLayer = _renderLayer;
        HSMpvRenderContextState *previousState = _renderContextState;
        [self clearRenderUpdateCallback];
        _view.displayConfigurationHandler = nil;
        [previousLayer stopDisplayLink];
        [view replaceRenderLayerWithCopyOfLayer:previousLayer];
        __block mpv_render_context *transferredContext = NULL;
        [previousLayer performWithLockedOpenGLContext:^{
            transferredContext = [previousState takeContextForTransfer];
        }];
        if (transferredContext != _renderContext) {
            [previousState setContext:_renderContext];
            [previousView setRenderContext:_renderContext];
            if (previousView) {
                [self installRenderUpdateCallbackForView:previousView];
                [self installDisplayConfigurationCallbackForView:previousView];
            }
            [self emitStateWithError:@"Unable to transfer the video rendering surface."];
            return NO;
        }
        _view = view;
        _renderLayer = view.openGLLayer;
        _renderContextState = _renderLayer.renderContextState;
        [view setRenderContext:transferredContext];
        [self installRenderUpdateCallbackForView:view];
        [self installDisplayConfigurationCallbackForView:view];
        [view requestForcedRender];
        return YES;
    }
    if (_renderContext) {
        [view requestForcedRender];
        return YES;
    }
    _renderLayer = view.openGLLayer;
    _renderContextState = _renderLayer.renderContextState;
    __block int createStatus = 0;
    [view performWithLockedOpenGLContext:^{
        mpv_opengl_init_params openGL = {
            .get_proc_address = HSMpvGetOpenGLProcAddress,
            .get_proc_address_ctx = NULL
        };
        const char *apiType = MPV_RENDER_API_TYPE_OPENGL;
        int advancedControl = 1;
        mpv_render_param parameters[] = {
            { MPV_RENDER_PARAM_API_TYPE, (void *)apiType },
            { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &openGL },
            { MPV_RENDER_PARAM_ADVANCED_CONTROL, &advancedControl },
            { MPV_RENDER_PARAM_INVALID, NULL }
        };
        createStatus = mpv_render_context_create(&_renderContext, _handle, parameters);
    }];
    if (createStatus < 0) {
        _renderLayer = nil;
        _renderContextState = nil;
        [self emitStateWithError:@"Unable to create the video rendering surface."];
        return NO;
    }
    _view = view;
    [view setRenderContext:_renderContext];
    [self installRenderUpdateCallbackForView:view];
    [self installDisplayConfigurationCallbackForView:view];
    [view requestForcedRender];
    return YES;
}

- (void)detachFromView {
    if (_renderContext) {
        HSMpvOpenGLView *view = _view;
        HSMpvOpenGLLayer *renderLayer = _renderLayer ?: view.openGLLayer;
        HSMpvRenderContextState *renderContextState =
            _renderContextState ?: renderLayer.renderContextState;
        [self clearRenderUpdateCallback];
        view.displayConfigurationHandler = nil;
        [renderLayer stopDisplayLink];
        if (renderLayer) {
            [renderLayer performWithLockedOpenGLContext:^{
                [renderContextState invalidateAndPerform:^(mpv_render_context *context) {
                    mpv_render_context_free(context);
                }];
            }];
        } else {
            [renderContextState invalidateAndPerform:^(mpv_render_context *context) {
                mpv_render_context_free(context);
            }];
        }
        _renderContext = NULL;
        _renderContextState = nil;
        _renderLayer = nil;
        [self releaseRenderUpdateContext];
    }
    _view = nil;
}

- (void)installDisplayConfigurationCallbackForView:(HSMpvOpenGLView *)view {
    __weak HSMpvClient *weakSelf = self;
    view.displayConfigurationHandler = ^(HSMpvOpenGLView *renderView, NSScreen *screen) {
        HSMpvClient *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf applyDisplayColorConfigurationForView:renderView screen:screen];
    };
    BOOL displayConfigurationChanged = [view updateBackingConfiguration];
    if (!displayConfigurationChanged) {
        NSScreen *screen = view.window.screen ?: NSScreen.mainScreen;
        if (screen) {
            view.displayConfigurationHandler(view, screen);
        }
    }
}

- (void)refreshDisplayColorConfiguration {
    dispatch_block_t refresh = ^{
        HSMpvOpenGLView *view = self->_view;
        NSScreen *screen = view.window.screen ?: NSScreen.mainScreen;
        if (view && screen) {
            [self applyDisplayColorConfigurationForView:view screen:screen];
        }
    };
    if (NSThread.isMainThread) {
        refresh();
    } else {
        dispatch_async(dispatch_get_main_queue(), refresh);
    }
}

- (void)applyDisplayColorConfigurationForView:(HSMpvOpenGLView *)view
    screen:(NSScreen *)screen {
    double displayRefreshRate = [view.openGLLayer displayRefreshRate];
    if (_handle && isfinite(displayRefreshRate) && displayRefreshRate > 0) {
        mpv_set_property(
            _handle,
            "display-fps-override",
            MPV_FORMAT_DOUBLE,
            &displayRefreshRate
        );
    }
    if (![self applyHDRDisplayColorConfigurationForView:view screen:screen]) {
        [self applySDRDisplayColorConfigurationForView:view screen:screen];
    }
    [view requestForcedRender];
}

- (void)applySDRDisplayColorConfigurationForView:(HSMpvOpenGLView *)view
    screen:(NSScreen *)screen {
    NSColorSpace *colorSpace = screen.colorSpace ?: NSColorSpace.sRGBColorSpace;
    view.openGLLayer.colorspace = colorSpace.CGColorSpace;
    view.openGLLayer.wantsExtendedDynamicRangeContent = NO;

    if (!_handle || !_renderContext) {
        return;
    }

    mpv_set_property_string(_handle, "target-prim", "auto");
    mpv_set_property_string(_handle, "target-trc", "auto");
    mpv_set_property_string(_handle, "target-peak", "auto");
    mpv_set_property_string(_handle, "tone-mapping", "auto");

    NSData *iccData = colorSpace.ICCProfileData;
    if (!iccData.length) {
        mpv_set_property_string(_handle, "icc-profile-auto", "no");
        return;
    }

    __block int iccStatus = MPV_ERROR_UNSUPPORTED;
    HSMpvRenderContextState *renderContextState = _renderContextState;
    [view performWithLockedOpenGLContext:^{
        [renderContextState withContext:^(mpv_render_context *renderContext) {
            mpv_byte_array iccProfile = {
                .data = (void *)iccData.bytes,
                .size = iccData.length
            };
            mpv_render_param parameter = {
                MPV_RENDER_PARAM_ICC_PROFILE,
                &iccProfile
            };
            iccStatus = mpv_render_context_set_parameter(renderContext, parameter);
        }];
    }];
    mpv_set_property_string(
        _handle,
        "icc-profile-auto",
        iccStatus >= 0 ? "yes" : "no"
    );
}

- (BOOL)applyHDRDisplayColorConfigurationForView:(HSMpvOpenGLView *)view
    screen:(NSScreen *)screen {
    if (!_hdrEnhancementEnabled
        || screen.maximumPotentialExtendedDynamicRangeColorComponentValue <= 1.0
        || (![_videoGamma isEqualToString:@"pq"] && ![_videoGamma isEqualToString:@"hlg"])) {
        return NO;
    }

    CFStringRef colorSpaceName = NULL;
    if ([_videoPrimaries isEqualToString:@"bt.2020"]) {
        colorSpaceName = kCGColorSpaceITUR_2100_PQ;
    } else if ([_videoPrimaries isEqualToString:@"display-p3"]) {
        colorSpaceName = kCGColorSpaceDisplayP3_PQ;
    } else {
        return NO;
    }

    CGColorSpaceRef hdrColorSpace = CGColorSpaceCreateWithName(colorSpaceName);
    if (!hdrColorSpace) {
        return NO;
    }
    view.openGLLayer.colorspace = hdrColorSpace;
    CGColorSpaceRelease(hdrColorSpace);
    view.openGLLayer.wantsExtendedDynamicRangeContent = YES;

    if (_handle) {
        mpv_set_property_string(_handle, "icc-profile-auto", "no");
        mpv_set_property_string(_handle, "target-prim", _videoPrimaries.UTF8String);
        mpv_set_property_string(_handle, "target-trc", "pq");
        mpv_set_property_string(_handle, "target-peak", "auto");
        mpv_set_property_string(_handle, "tone-mapping", "auto");
    }
    return YES;
}

- (void)installRenderUpdateCallbackForView:(HSMpvOpenGLView *)view {
    if (!_renderContext) {
        return;
    }
    if (!_renderUpdateContext) {
        _renderUpdateContext = (void *)CFBridgingRetain(_renderUpdateTarget);
    }
    _renderUpdateTarget.view = view;
    _renderUpdateTarget.generation += 1;
    HSMpvOpenGLLayer *renderLayer = _renderLayer;
    HSMpvRenderContextState *renderContextState = _renderContextState;
    [renderLayer performWithLockedOpenGLContext:^{
        [renderContextState withContext:^(mpv_render_context *renderContext) {
            mpv_render_context_set_update_callback(
                renderContext,
                HSMpvRenderUpdate,
                self->_renderUpdateContext
            );
        }];
    }];
}

- (void)clearRenderUpdateCallback {
    if (_renderContext) {
        HSMpvOpenGLLayer *renderLayer = _renderLayer;
        HSMpvRenderContextState *renderContextState = _renderContextState;
        [renderLayer performWithLockedOpenGLContext:^{
            [renderContextState withContext:^(mpv_render_context *renderContext) {
                mpv_render_context_set_update_callback(renderContext, NULL, NULL);
            }];
        }];
    }
    _renderUpdateTarget.view = nil;
    _renderUpdateTarget.generation += 1;
}

- (void)releaseRenderUpdateContext {
    if (!_renderUpdateContext) {
        return;
    }
    CFRelease((CFTypeRef)_renderUpdateContext);
    _renderUpdateContext = NULL;
}

- (void)loadFile:(NSURL *)url {
    if (!_handle || _shuttingDown) {
        return;
    }
    [self clearASSSubtitleEffectsRestoringLogicalTrack:NO];
    _loadGeneration.fetch_add(1, std::memory_order_acq_rel);
    _currentTime = 0;
    _duration = 0;
    _loaded = NO;
    _videoWidth = 0;
    _videoHeight = 0;
    _sourceVideoRotation.store(0, std::memory_order_release);
    _videoPrimaries = nil;
    _videoGamma = nil;
    [self refreshDisplayColorConfiguration];
    _lastSubtitleRefreshTime = -1;
    _lastTimePositionStateEmitClock = 0;
    _lastEmittedStateTimePosition = NAN;
    _pendingRemoteAudioURLString = nil;
    _expectedRemoteAudioURLString = nil;
    _remoteAudioAttachmentReported = NO;
    [self resetSubtitleCueCache];
    [self emitSubtitleCuesFromNode:NULL];
    const char *command[] = { "loadfile", url.fileSystemRepresentation, "replace", NULL };
    int status = mpv_command(_handle, command);
    if (status < 0) {
        [self emitStateWithError:[NSString stringWithUTF8String:mpv_error_string(status)]];
    }
}

- (void)loadSourceURLString:(NSString *)urlString
    headers:(NSDictionary<NSString *, NSString *> *)headers
    audioURLString:(nullable NSString *)audioURLString
    audioHeaders:(NSDictionary<NSString *, NSString *> *)audioHeaders {
    if (!_handle || _shuttingDown) {
        return;
    }
    [self clearASSSubtitleEffectsRestoringLogicalTrack:NO];
    _loadGeneration.fetch_add(1, std::memory_order_acq_rel);
    _currentTime = 0;
    _duration = 0;
    _loaded = NO;
    _videoWidth = 0;
    _videoHeight = 0;
    _sourceVideoRotation.store(0, std::memory_order_release);
    _videoPrimaries = nil;
    _videoGamma = nil;
    [self refreshDisplayColorConfiguration];
    _lastSubtitleRefreshTime = -1;
    _lastTimePositionStateEmitClock = 0;
    _lastEmittedStateTimePosition = NAN;
    _pendingRemoteAudioURLString = nil;
    _expectedRemoteAudioURLString = nil;
    _remoteAudioAttachmentReported = NO;
    [self resetSubtitleCueCache];
    [self emitSubtitleCuesFromNode:NULL];

    NSDictionary<NSString *, NSString *> *mergedHeaders = HSMpvMergedHTTPHeaders(
        headers,
        audioURLString.length > 0 ? audioHeaders : @{}
    );
    BOOL hasHeaderConflict = mergedHeaders == nil;
    HSMpvSetHTTPHeaders(_handle, mergedHeaders ?: headers);

    const char *command[] = { "loadfile", urlString.UTF8String, "replace", NULL };
    int status = mpv_command(_handle, command);
    if (status < 0) {
        [self emitStateWithError:[NSString stringWithUTF8String:mpv_error_string(status)]];
        return;
    }
    if (hasHeaderConflict) {
        [self emitRemoteAudioStateAttached:NO
            errorMessage:@"Remote video and audio require conflicting HTTP headers."];
        return;
    }
    if (audioURLString.length > 0) {
        _expectedRemoteAudioURLString = [audioURLString copy];
        if (![self loadRemoteAudioURLString:audioURLString]) {
            _pendingRemoteAudioURLString = [audioURLString copy];
        } else {
            [self scheduleRemoteAudioAttachmentDeadline];
        }
    }
}

- (BOOL)loadRemoteAudioURLString:(NSString *)audioURLString {
    if (!_handle || _shuttingDown || audioURLString.length == 0) {
        return NO;
    }
    const char *audioCommand[] = { "audio-add", audioURLString.UTF8String, "select", NULL };
    int audioStatus = mpv_command(_handle, audioCommand);
    if (audioStatus < 0) {
        NSLog(@"Failed to load external remote audio stream: %s", mpv_error_string(audioStatus));
        return NO;
    }
    return YES;
}

- (void)loadPendingRemoteAudioIfNeeded {
    NSString *audioURLString = _pendingRemoteAudioURLString;
    if (audioURLString.length == 0) {
        return;
    }
    if ([self loadRemoteAudioURLString:audioURLString]) {
        _pendingRemoteAudioURLString = nil;
        [self scheduleRemoteAudioAttachmentDeadline];
    } else if (_loaded) {
        _pendingRemoteAudioURLString = nil;
        [self emitRemoteAudioStateAttached:NO
            errorMessage:@"The external remote audio stream could not be attached."];
    }
}

- (void)scheduleRemoteAudioAttachmentDeadline {
    if (_expectedRemoteAudioURLString.length == 0) {
        return;
    }
    uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
                return;
            }
            [self emitRemoteAudioStateAttached:NO
                errorMessage:@"The external remote audio stream did not become available."];
        }
    );
}

- (void)emitRemoteAudioStateAttached:(BOOL)attached
    errorMessage:(nullable NSString *)errorMessage {
    @synchronized (self) {
        if (_remoteAudioAttachmentReported) {
            return;
        }
        _remoteAudioAttachmentReported = YES;
    }
    void (^handler)(BOOL, NSString * _Nullable) = self.remoteAudioStateHandler;
    if (!handler) {
        return;
    }
    uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
            return;
        }
        handler(attached, errorMessage);
    });
}

- (BOOL)isCurrentLoadGeneration:(uint64_t)guardedLoadGeneration {
    return guardedLoadGeneration == _loadGeneration.load(std::memory_order_acquire);
}

- (void)setPaused:(BOOL)paused {
    if (!_handle || _shuttingDown) {
        return;
    }
    int value = paused ? 1 : 0;
    mpv_set_property(_handle, "pause", MPV_FORMAT_FLAG, &value);
}

- (void)seekTo:(double)seconds {
    if (!_handle || _shuttingDown) {
        return;
    }
    NSString *value = [NSString stringWithFormat:@"%.6f", seconds];
    const char *command[] = { "seek", value.UTF8String, "absolute+exact", NULL };
    mpv_command_async(_handle, 0, command);
}

- (void)setSpeed:(double)speed {
    if (!_handle || _shuttingDown) {
        return;
    }
    mpv_set_property(_handle, "speed", MPV_FORMAT_DOUBLE, &speed);
}

- (void)setVolume:(double)volume {
    if (!_handle || _shuttingDown) {
        return;
    }
    mpv_set_property(_handle, "volume", MPV_FORMAT_DOUBLE, &volume);
}

- (void)setMuted:(BOOL)muted {
    if (!_handle || _shuttingDown) {
        return;
    }
    int value = muted ? 1 : 0;
    mpv_set_property(_handle, "mute", MPV_FORMAT_FLAG, &value);
}

- (void)setSubtitleDelay:(double)delay {
    if (!_handle || _shuttingDown) {
        return;
    }
    mpv_set_property(_handle, "sub-delay", MPV_FORMAT_DOUBLE, &delay);
}

- (void)setAudioDelay:(double)delay {
    if (!_handle || _shuttingDown) {
        return;
    }
    _audioDelay = delay;
    mpv_set_property(_handle, "audio-delay", MPV_FORMAT_DOUBLE, &delay);
    [self emitStateWithError:nil];
}

- (void)setLoopMode:(NSString *)mode {
    if (!_handle || _shuttingDown) {
        return;
    }
    _loopMode = [mode isEqualToString:@"file"] ? @"file" : @"none";
    mpv_set_property_string(
        _handle,
        "loop-file",
        [_loopMode isEqualToString:@"file"] ? "inf" : "no"
    );
    [self emitStateWithError:nil];
}

- (void)setABLoopStart:(nullable NSNumber *)start end:(nullable NSNumber *)end {
    if (!_handle || _shuttingDown) {
        return;
    }
    _abLoopStart = start ? start.doubleValue : NAN;
    _abLoopEnd = end ? end.doubleValue : NAN;
    mpv_set_property_string(
        _handle,
        "ab-loop-a",
        start ? start.stringValue.UTF8String : "no"
    );
    mpv_set_property_string(
        _handle,
        "ab-loop-b",
        end ? end.stringValue.UTF8String : "no"
    );
    [self emitStateWithError:nil];
}

- (void)setAspectRatio:(NSString *)aspectRatio {
    if (!_handle || _shuttingDown) {
        return;
    }
    _aspectRatio = aspectRatio.length > 0 ? aspectRatio.copy : @"-1";
    mpv_set_property_string(
        _handle,
        "video-aspect-override",
        _aspectRatio.UTF8String
    );
    [self emitStateWithError:nil];
}

- (void)setRotation:(NSInteger)degrees {
    if (!_handle || _shuttingDown) {
        return;
    }
    int64_t value = (int64_t)(((degrees % 360) + 360) % 360);
    _rotation = (NSInteger)value;
    mpv_set_property(_handle, "video-rotate", MPV_FORMAT_INT64, &value);
    [self emitStateWithError:nil];
}

- (void)setHardwareDecodingEnabled:(BOOL)enabled {
    if (!_handle || _shuttingDown) {
        return;
    }
    mpv_set_property_string(_handle, "hwdec", enabled ? "auto-safe" : "no");
}

- (void)setDeinterlacingEnabled:(BOOL)enabled {
    if (!_handle || _shuttingDown) {
        return;
    }
    int value = enabled ? 1 : 0;
    mpv_set_property(_handle, "deinterlace", MPV_FORMAT_FLAG, &value);
}

- (void)setHDREnhancementEnabled:(BOOL)enabled {
    if (!_handle || _shuttingDown) {
        return;
    }
    _hdrEnhancementEnabled = enabled;
    mpv_set_property_string(_handle, "hdr-compute-peak", enabled ? "yes" : "no");
    mpv_set_property_string(_handle, "tone-mapping", "auto");
    [self refreshDisplayColorConfiguration];
}

- (BOOL)setVideoShaderURLs:(NSArray<NSURL *> *)shaderURLs
    errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    if (!_handle || _shuttingDown) {
        if (errorMessage) {
            *errorMessage = @"The video engine is unavailable.";
        }
        return NO;
    }

    const char *clearCommand[] = {"change-list", "glsl-shaders", "clr", "", NULL};
    int status = mpv_command(_handle, clearCommand);
    if (status < 0) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithUTF8String:mpv_error_string(status)];
        }
        return NO;
    }

    for (NSURL *url in shaderURLs) {
        if (!url.isFileURL) {
            if (errorMessage) {
                *errorMessage = @"The video shader path is invalid.";
            }
            return NO;
        }
        const char *appendCommand[] = {
            "change-list",
            "glsl-shaders",
            "append",
            url.fileSystemRepresentation,
            NULL,
        };
        status = mpv_command(_handle, appendCommand);
        if (status < 0) {
            const char *rollbackCommand[] = {"change-list", "glsl-shaders", "clr", "", NULL};
            mpv_command(_handle, rollbackCommand);
            if (errorMessage) {
                *errorMessage = [NSString stringWithUTF8String:mpv_error_string(status)];
            }
            return NO;
        }
    }
    return YES;
}

- (void)setVideoEqualizer:(NSString *)adjustment value:(double)value {
    if (!_handle || _shuttingDown) {
        return;
    }
    NSSet<NSString *> *supportedAdjustments = [NSSet setWithObjects:
        @"brightness",
        @"contrast",
        @"saturation",
        @"gamma",
        @"hue",
        nil
    ];
    if (![supportedAdjustments containsObject:adjustment]) {
        return;
    }
    double normalized = isfinite(value) ? MIN(MAX(value, -100.0), 100.0) : 0.0;
    NSString *valueString = [NSString stringWithFormat:@"%.0f", normalized];
    mpv_set_property_string(_handle, adjustment.UTF8String, valueString.UTF8String);
}

- (void)seekToChapter:(NSInteger)index {
    if (!_handle || _shuttingDown) {
        return;
    }
    int64_t value = (int64_t)index;
    mpv_set_property(_handle, "chapter", MPV_FORMAT_INT64, &value);
}

static mpv_node *HSMpvMapValue(mpv_node *node, const char *key) {
    if (!node || node->format != MPV_FORMAT_NODE_MAP || !node->u.list) {
        return NULL;
    }
    for (int index = 0; index < node->u.list->num; index++) {
        if (node->u.list->keys[index] && strcmp(node->u.list->keys[index], key) == 0) {
            return &node->u.list->values[index];
        }
    }
    return NULL;
}

static BOOL HSMpvNodeDoubleValue(mpv_node *node, double *value) {
    if (!node || !value) {
        return NO;
    }
    if (node->format == MPV_FORMAT_DOUBLE) {
        *value = node->u.double_;
        return isfinite(*value);
    }
    if (node->format == MPV_FORMAT_INT64) {
        *value = (double)node->u.int64;
        return isfinite(*value);
    }
    return NO;
}

static NSString *HSMpvNodeStringValue(mpv_node *node) {
    if (!node || node->format != MPV_FORMAT_STRING || !node->u.string) {
        return nil;
    }
    return [NSString stringWithUTF8String:node->u.string];
}

static NSSize HSMpvVideoDisplaySizeFromNode(mpv_node *node) {
    double width = 0;
    double height = 0;
    BOOL hasDisplayWidth = HSMpvNodeDoubleValue(HSMpvMapValue(node, "dw"), &width);
    BOOL hasDisplayHeight = HSMpvNodeDoubleValue(HSMpvMapValue(node, "dh"), &height);
    if (!hasDisplayWidth || !hasDisplayHeight || width <= 0 || height <= 0) {
        hasDisplayWidth = HSMpvNodeDoubleValue(HSMpvMapValue(node, "w"), &width);
        hasDisplayHeight = HSMpvNodeDoubleValue(HSMpvMapValue(node, "h"), &height);
    }
    if (!hasDisplayWidth || !hasDisplayHeight || width <= 0 || height <= 0) {
        return NSZeroSize;
    }
    return NSMakeSize(width, height);
}

static NSImage *HSMpvAmbientImageFromNode(mpv_node *node, NSInteger maximumDimension) {
    mpv_node *widthNode = HSMpvMapValue(node, "w");
    mpv_node *heightNode = HSMpvMapValue(node, "h");
    mpv_node *strideNode = HSMpvMapValue(node, "stride");
    mpv_node *formatNode = HSMpvMapValue(node, "format");
    mpv_node *dataNode = HSMpvMapValue(node, "data");
    if (!widthNode || !heightNode || !strideNode || !formatNode || !dataNode
        || widthNode->format != MPV_FORMAT_INT64
        || heightNode->format != MPV_FORMAT_INT64
        || strideNode->format != MPV_FORMAT_INT64
        || formatNode->format != MPV_FORMAT_STRING
        || dataNode->format != MPV_FORMAT_BYTE_ARRAY
        || !dataNode->u.ba || !dataNode->u.ba->data) {
        return nil;
    }

    NSInteger width = (NSInteger)widthNode->u.int64;
    NSInteger height = (NSInteger)heightNode->u.int64;
    NSInteger stride = (NSInteger)strideNode->u.int64;
    NSString *format = [NSString stringWithUTF8String:formatNode->u.string ?: ""];
    if (width <= 0 || height <= 0 || stride == 0 || maximumDimension <= 0) {
        return nil;
    }
    BOOL blueFirst = [format isEqualToString:@"bgr0"] || [format isEqualToString:@"bgra"];
    BOOL redFirst = [format isEqualToString:@"rgb0"] || [format isEqualToString:@"rgba"];
    if (!blueFirst && !redFirst) {
        return nil;
    }

    CGFloat scale = MIN(1.0, (CGFloat)maximumDimension / (CGFloat)MAX(width, height));
    NSInteger outputWidth = MAX(1, (NSInteger)floor((CGFloat)width * scale));
    NSInteger outputHeight = MAX(1, (NSInteger)floor((CGFloat)height * scale));
    NSMutableData *rgbaData = [NSMutableData dataWithLength:(NSUInteger)(outputWidth * outputHeight * 4)];
    const uint8_t *source = (const uint8_t *)dataNode->u.ba->data;
    uint8_t *destination = (uint8_t *)rgbaData.mutableBytes;
    NSInteger absoluteStride = labs(stride);
    if ((NSUInteger)(absoluteStride * height) > dataNode->u.ba->size) {
        return nil;
    }

    for (NSInteger y = 0; y < outputHeight; y++) {
        NSInteger sourceY = MIN(height - 1, (NSInteger)floor((CGFloat)y / scale));
        const uint8_t *sourceRow = stride > 0
            ? source + sourceY * stride
            : source + (height - 1 - sourceY) * absoluteStride;
        for (NSInteger x = 0; x < outputWidth; x++) {
            NSInteger sourceX = MIN(width - 1, (NSInteger)floor((CGFloat)x / scale));
            const uint8_t *pixel = sourceRow + sourceX * 4;
            uint8_t *output = destination + (y * outputWidth + x) * 4;
            output[0] = blueFirst ? pixel[2] : pixel[0];
            output[1] = pixel[1];
            output[2] = blueFirst ? pixel[0] : pixel[2];
            output[3] = 255;
        }
    }

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgbaData);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)(
        (uint32_t)kCGImageAlphaPremultipliedLast
        | (uint32_t)kCGBitmapByteOrder32Big
    );
    CGImageRef image = CGImageCreate(
        outputWidth,
        outputHeight,
        8,
        32,
        outputWidth * 4,
        colorSpace,
        bitmapInfo,
        provider,
        NULL,
        true,
        kCGRenderingIntentDefault
    );
    NSImage *result = image
        ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(outputWidth, outputHeight)]
        : nil;
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return result;
}

- (void)captureAmbientPreviewWithMaximumDimension:(NSInteger)maximumDimension
    completion:(void (^)(NSImage * _Nullable image, NSInteger generation))completion {
    if (!completion) {
        return;
    }
    uint64_t guardedGeneration = _loadGeneration.load(std::memory_order_acquire);
    dispatch_async(_ambientPreviewQueue, ^{
        NSImage *image = nil;
        if (self->_handle && !self->_shuttingDown) {
            const char *command[] = { "screenshot-raw", "video", NULL };
            mpv_node result = {0};
            int status = mpv_command_ret(self->_handle, command, &result);
            if (status >= 0) {
                image = HSMpvAmbientImageFromNode(&result, maximumDimension);
                mpv_free_node_contents(&result);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(image, (NSInteger)guardedGeneration);
        });
    });
}

- (BOOL)captureScreenshotToURL:(NSURL *)url errorMessage:(NSString **)errorMessage {
    if (!_handle || _shuttingDown) {
        if (errorMessage) {
            *errorMessage = @"Video playback is not available.";
        }
        return NO;
    }
    const char *command[] = {
        "screenshot-to-file",
        url.fileSystemRepresentation,
        "video",
        NULL
    };
    int status = mpv_command(_handle, command);
    if (status < 0) {
        if (errorMessage) {
            *errorMessage = [NSString stringWithUTF8String:mpv_error_string(status)];
        }
        return NO;
    }
    return YES;
}

- (int64_t)existingExternalSubtitleTrackIDForURL:(NSURL *)url {
    int64_t count = 0;
    if (mpv_get_property(_handle, "track-list/count", MPV_FORMAT_INT64, &count) < 0) {
        return 0;
    }
    NSString *targetPath = url.URLByResolvingSymlinksInPath.path;
    for (int64_t index = 0; index < count; index++) {
        NSString *prefix = [NSString stringWithFormat:@"track-list/%lld/", index];
        char *type = mpv_get_property_string(_handle, [prefix stringByAppendingString:@"type"].UTF8String);
        BOOL isSubtitle = type && strcmp(type, "sub") == 0;
        mpv_free(type);
        if (!isSubtitle) {
            continue;
        }
        char *title = mpv_get_property_string(_handle, [prefix stringByAppendingString:@"title"].UTF8String);
        BOOL isInternalEffectsTrack = title
            && strcmp(title, HSMpvInternalASSSubtitleEffectsTitle.UTF8String) == 0;
        mpv_free(title);
        if (isInternalEffectsTrack) {
            continue;
        }
        char *filename = mpv_get_property_string(
            _handle,
            [prefix stringByAppendingString:@"external-filename"].UTF8String
        );
        NSString *path = filename ? [NSString stringWithUTF8String:filename] : nil;
        mpv_free(filename);
        if (path.length == 0
            || ![[NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path isEqualToString:targetPath]) {
            continue;
        }
        int64_t trackID = 0;
        if (mpv_get_property(_handle, [prefix stringByAppendingString:@"id"].UTF8String, MPV_FORMAT_INT64, &trackID) >= 0
            && trackID > 0) {
            return trackID;
        }
    }
    return 0;
}

- (void)loadExternalSubtitle:(NSURL *)url {
    if (!_handle || _shuttingDown) {
        return;
    }
    [self clearASSSubtitleEffectsRestoringLogicalTrack:NO];
    [self resetSubtitleCueCache];
    [self emitSubtitleCuesFromNode:NULL];
    // mpv's `sub-auto` may already have loaded a same-name file before the
    // Swift track snapshot catches up; reuse it instead of adding a duplicate.
    int64_t existingTrackID = [self existingExternalSubtitleTrackIDForURL:url];
    if (existingTrackID > 0) {
        mpv_set_property(_handle, "sid", MPV_FORMAT_INT64, &existingTrackID);
        mpv_set_property_string(
            _handle,
            "sub-visibility",
            _nativeSubtitleRenderingEnabled.load(std::memory_order_acquire) ? "yes" : "no"
        );
        [self refreshSubtitleCues];
        return;
    }
    const char *command[] = {
        "sub-add",
        url.fileSystemRepresentation,
        "select",
        NULL
    };
    int status = mpv_command(_handle, command);
    if (status < 0) {
        NSString *absoluteString = url.absoluteString;
        const char *urlCommand[] = {
            "sub-add",
            absoluteString.UTF8String,
            "select",
            NULL
        };
        status = mpv_command(_handle, urlCommand);
    }
    if (status < 0) {
        NSLog(
            @"Failed to load external subtitle into mpv: %@ (%s)",
            url.path,
            mpv_error_string(status)
        );
        return;
    }
    mpv_set_property_string(
        _handle,
        "sub-visibility",
        _nativeSubtitleRenderingEnabled.load(std::memory_order_acquire) ? "yes" : "no"
    );
    [self refreshSubtitleCues];
}

- (void)selectTrackType:(NSString *)type trackID:(nullable NSNumber *)trackID {
    if (!_handle || _shuttingDown) {
        return;
    }
    NSString *property = nil;
    if ([type isEqualToString:@"audio"]) {
        property = @"aid";
    } else if ([type isEqualToString:@"subtitle"]) {
        property = @"sid";
    } else if ([type isEqualToString:@"video"]) {
        property = @"vid";
    }
    if (!property) {
        return;
    }
    if ([type isEqualToString:@"subtitle"]) {
        [self clearASSSubtitleEffectsRestoringLogicalTrack:NO];
    }
    NSString *value = trackID ? trackID.stringValue : @"no";
    if ([type isEqualToString:@"subtitle"]) {
        [self resetSubtitleCueCache];
        [self emitSubtitleCuesFromNode:NULL];
        mpv_set_property_string(
            _handle,
            "sub-visibility",
            (_nativeSubtitleRenderingEnabled.load(std::memory_order_acquire) && trackID)
                ? "yes"
                : "no"
        );
    }
    int status = mpv_set_property_string(
        _handle,
        property.UTF8String,
        value.UTF8String
    );
    (void)status;
}

- (void)setNativeSubtitleRenderingEnabled:(BOOL)enabled {
    _nativeSubtitleRenderingEnabled.store(enabled, std::memory_order_release);
    if (!_handle || _shuttingDown) {
        return;
    }
    mpv_set_property_string(_handle, "sub-visibility", enabled ? "yes" : "no");
}

- (BOOL)installASSSubtitleEffectsFromURL:(NSURL *)url
    logicalTrackID:(nullable NSNumber *)logicalTrackID
    errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    if (!_handle || _shuttingDown || !url.isFileURL) {
        if (errorMessage) {
            *errorMessage = @"The ASS effects subtitle could not be installed.";
        }
        return NO;
    }

    int64_t previousLogicalTrackID = _internalASSSubtitleLogicalTrackID.load(
        std::memory_order_acquire
    );
    [self clearASSSubtitleEffectsRestoringLogicalTrack:NO];

    int64_t resolvedLogicalTrackID = logicalTrackID.longLongValue;
    if (resolvedLogicalTrackID <= 0) {
        resolvedLogicalTrackID = previousLogicalTrackID;
    }
    if (resolvedLogicalTrackID <= 0) {
        int64_t selectedTrackID = 0;
        if (mpv_get_property(_handle, "sid", MPV_FORMAT_INT64, &selectedTrackID) >= 0) {
            resolvedLogicalTrackID = selectedTrackID;
        }
    }
    if (resolvedLogicalTrackID <= 0) {
        if (errorMessage) {
            *errorMessage = @"The original ASS subtitle track could not be identified.";
        }
        return NO;
    }

    // Publish the logical selection before `sub-add`: mpv may deliver the
    // resulting track-list event on its event queue before this command
    // returns. That intermediate snapshot must still map the hidden effects
    // track back to the user-selected ASS track.
    _internalASSSubtitleLogicalTrackID.store(
        resolvedLogicalTrackID,
        std::memory_order_release
    );

    const char *command[] = {
        "sub-add",
        url.fileSystemRepresentation,
        "select",
        HSMpvInternalASSSubtitleEffectsTitle.UTF8String,
        NULL
    };
    int status = mpv_command(_handle, command);
    if (status < 0) {
        NSString *absoluteString = url.absoluteString;
        const char *urlCommand[] = {
            "sub-add",
            absoluteString.UTF8String,
            "select",
            HSMpvInternalASSSubtitleEffectsTitle.UTF8String,
            NULL
        };
        status = mpv_command(_handle, urlCommand);
    }
    if (status < 0) {
        _internalASSSubtitleLogicalTrackID.store(0, std::memory_order_release);
        if (resolvedLogicalTrackID > 0) {
            NSString *logicalID = [NSString stringWithFormat:@"%lld", resolvedLogicalTrackID];
            mpv_set_property_string(_handle, "sid", logicalID.UTF8String);
        }
        if (errorMessage) {
            *errorMessage = [NSString stringWithUTF8String:mpv_error_string(status)];
        }
        return NO;
    }

    int64_t effectsTrackID = 0;
    if (mpv_get_property(_handle, "sid", MPV_FORMAT_INT64, &effectsTrackID) < 0
        || effectsTrackID <= 0) {
        const char *removeCurrent[] = {"sub-remove", NULL};
        mpv_command(_handle, removeCurrent);
        _internalASSSubtitleEffectsTrackID.store(0, std::memory_order_release);
        _internalASSSubtitleLogicalTrackID.store(0, std::memory_order_release);
        if (resolvedLogicalTrackID > 0) {
            NSString *logicalID = [NSString stringWithFormat:@"%lld", resolvedLogicalTrackID];
            mpv_set_property_string(_handle, "sid", logicalID.UTF8String);
        }
        if (errorMessage) {
            *errorMessage = @"The ASS effects subtitle track could not be identified.";
        }
        return NO;
    }

    _internalASSSubtitleEffectsTrackID.store(effectsTrackID, std::memory_order_release);
    [self resetSubtitleCueCache];
    [self emitSubtitleCuesFromNode:NULL];
    return YES;
}

- (void)clearASSSubtitleEffects {
    [self clearASSSubtitleEffectsRestoringLogicalTrack:YES];
}

- (void)clearASSSubtitleEffectsRestoringLogicalTrack:(BOOL)restoreLogicalTrack {
    int64_t effectsTrackID = _internalASSSubtitleEffectsTrackID.exchange(
        0,
        std::memory_order_acq_rel
    );
    int64_t logicalTrackID = _internalASSSubtitleLogicalTrackID.exchange(
        0,
        std::memory_order_acq_rel
    );
    if (!_handle || _shuttingDown) {
        return;
    }
    if (effectsTrackID > 0) {
        NSString *effectsID = [NSString stringWithFormat:@"%lld", effectsTrackID];
        const char *removeCommand[] = {"sub-remove", effectsID.UTF8String, NULL};
        mpv_command(_handle, removeCommand);
    }
    if (restoreLogicalTrack && logicalTrackID > 0) {
        NSString *logicalID = [NSString stringWithFormat:@"%lld", logicalTrackID];
        mpv_set_property_string(_handle, "sid", logicalID.UTF8String);
    }
    [self resetSubtitleCueCache];
}

- (void)shutdown {
    if (_shuttingDown) {
        return;
    }
    [self clearASSSubtitleEffectsRestoringLogicalTrack:NO];
    _shuttingDown = YES;
    if (_handle) {
        mpv_wakeup(_handle);
        dispatch_sync(_eventQueue, ^{});
        // A screenshot-raw command may still be copying pixels on the preview queue.
        // Wait for it before destroying the shared mpv client handle.
        dispatch_sync(_ambientPreviewQueue, ^{});
    }
    [self detachFromView];
    if (_handle) {
        mpv_terminate_destroy(_handle);
        _handle = NULL;
    }
}

- (void)startEventLoop {
    dispatch_async(_eventQueue, ^{
        [self runEventLoop];
    });
}

- (void)runEventLoop {
    while (_handle && !_shuttingDown) {
        mpv_event *event = mpv_wait_event(_handle, -1);
        if (!event) {
            continue;
        }
        if (event->event_id == MPV_EVENT_NONE) {
            if (_shuttingDown) {
                return;
            }
            continue;
        }
        [self handleEvent:event];
    }
}

- (void)handleEvent:(mpv_event *)event {
    switch (event->event_id) {
        case MPV_EVENT_FILE_LOADED:
            _loaded = YES;
            if (_pendingRemoteAudioURLString.length > 0) {
                [self loadPendingRemoteAudioIfNeeded];
            }
            [self refreshSubtitleCues];
            [self emitStateWithError:nil];
            break;
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *end = (mpv_event_end_file *)event->data;
            if (end && end->error < 0) {
                [self emitStateWithError:[NSString stringWithUTF8String:mpv_error_string(end->error)]];
            } else if (end && end->reason == MPV_END_FILE_REASON_EOF) {
                void (^handler)(void) = self.playbackEndedHandler;
                if (handler) {
                    uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
                            return;
                        }
                        handler();
                    });
                }
            }
            break;
        }
        case MPV_EVENT_PROPERTY_CHANGE:
            [self handlePropertyChange:(mpv_event_property *)event->data];
            break;
        default:
            break;
    }
}

- (void)handlePropertyChange:(mpv_event_property *)property {
    if (!property || !property->data || !property->name) {
        return;
    }
    BOOL shouldEmitState = YES;
    if (strcmp(property->name, "time-pos") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _currentTime = *(double *)property->data;
        if (_lastSubtitleRefreshTime < 0
            || fabs(_currentTime - _lastSubtitleRefreshTime) >= 0.25) {
            _lastSubtitleRefreshTime = _currentTime;
            [self refreshSubtitleCues];
        }
        shouldEmitState = [self shouldEmitTimePositionState];
    } else if (strcmp(property->name, "duration") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _duration = *(double *)property->data;
    } else if (strcmp(property->name, "pause") == 0 && property->format == MPV_FORMAT_FLAG) {
        _paused = *(int *)property->data != 0;
    } else if (strcmp(property->name, "speed") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _speed = *(double *)property->data;
    } else if (strcmp(property->name, "volume") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _volume = *(double *)property->data;
    } else if (strcmp(property->name, "mute") == 0 && property->format == MPV_FORMAT_FLAG) {
        _muted = *(int *)property->data != 0;
    } else if (strcmp(property->name, "sub-delay") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _subtitleDelay = *(double *)property->data;
    } else if (strcmp(property->name, "audio-delay") == 0 && property->format == MPV_FORMAT_DOUBLE) {
        _audioDelay = *(double *)property->data;
    } else if (strcmp(property->name, "track-list") == 0 && property->format == MPV_FORMAT_NODE) {
        [self emitTracksFromNode:(mpv_node *)property->data];
        [self refreshSubtitleCues];
    } else if (strcmp(property->name, "chapter-list") == 0 && property->format == MPV_FORMAT_NODE) {
        [self emitChaptersFromNode:(mpv_node *)property->data];
    } else if (strcmp(property->name, "video-rotate") == 0 && property->format == MPV_FORMAT_INT64) {
        _rotation = (NSInteger)*(int64_t *)property->data;
    } else if (strcmp(property->name, "video-params") == 0 && property->format == MPV_FORMAT_NODE) {
        mpv_node *videoParams = (mpv_node *)property->data;
        NSSize displaySize = HSMpvVideoDisplaySizeFromNode(videoParams);
        _videoWidth = displaySize.width > 0 ? (NSInteger)llround(displaySize.width) : 0;
        _videoHeight = displaySize.height > 0 ? (NSInteger)llround(displaySize.height) : 0;
        NSString *primaries = HSMpvNodeStringValue(HSMpvMapValue(videoParams, "primaries"));
        NSString *gamma = HSMpvNodeStringValue(HSMpvMapValue(videoParams, "gamma"));
        double sourceRotation = 0;
        if (HSMpvNodeDoubleValue(HSMpvMapValue(videoParams, "rotate"), &sourceRotation)) {
            _sourceVideoRotation.store(
                (NSInteger)llround(sourceRotation),
                std::memory_order_release
            );
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_videoPrimaries = primaries;
            self->_videoGamma = gamma;
            [self refreshDisplayColorConfiguration];
        });
    } else if (strcmp(property->name, "osd-dimensions") == 0
               && property->format == MPV_FORMAT_NODE) {
        mpv_node *osdDimensions = (mpv_node *)property->data;
        double osdWidth = 0;
        double osdHeight = 0;
        double topMargin = 0;
        double bottomMargin = 0;
        double leftMargin = 0;
        double rightMargin = 0;
        BOOL hasGeometry = HSMpvNodeDoubleValue(HSMpvMapValue(osdDimensions, "w"), &osdWidth)
            && HSMpvNodeDoubleValue(HSMpvMapValue(osdDimensions, "h"), &osdHeight)
            && HSMpvNodeDoubleValue(HSMpvMapValue(osdDimensions, "mt"), &topMargin)
            && HSMpvNodeDoubleValue(HSMpvMapValue(osdDimensions, "mb"), &bottomMargin)
            && HSMpvNodeDoubleValue(HSMpvMapValue(osdDimensions, "ml"), &leftMargin)
            && HSMpvNodeDoubleValue(HSMpvMapValue(osdDimensions, "mr"), &rightMargin);
        HSMpvVideoGeometryHandler handler = self.videoGeometryHandler;
        if (handler && hasGeometry) {
            uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
                    return;
                }
                handler(
                    osdWidth,
                    osdHeight,
                    topMargin,
                    bottomMargin,
                    leftMargin,
                    rightMargin
                );
            });
        }
        shouldEmitState = NO;
    }
    if (!shouldEmitState) {
        return;
    }
    [self emitStateWithError:nil];
}

- (BOOL)shouldEmitTimePositionState {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    BOOL shouldEmit = _lastTimePositionStateEmitClock <= 0
        || !isfinite(_lastEmittedStateTimePosition)
        || fabs(_currentTime - _lastEmittedStateTimePosition) >= HSMpvTimePositionImmediateEmitDelta
        || now - _lastTimePositionStateEmitClock >= HSMpvTimePositionStateEmitInterval;
    if (shouldEmit) {
        _lastTimePositionStateEmitClock = now;
        _lastEmittedStateTimePosition = _currentTime;
    }
    return shouldEmit;
}

- (void)emitChaptersFromNode:(mpv_node *)node {
    if (!node || node->format != MPV_FORMAT_NODE_ARRAY || !node->u.list) {
        return;
    }
    NSMutableArray<HSMpvChapterInfo *> *chapters = [NSMutableArray array];
    mpv_node_list *list = node->u.list;
    for (int index = 0; index < list->num; index++) {
        mpv_node item = list->values[index];
        if (item.format != MPV_FORMAT_NODE_MAP || !item.u.list) {
            continue;
        }
        HSMpvChapterInfo *chapter = [[HSMpvChapterInfo alloc] init];
        chapter.chapterID = index;
        chapter.title = [NSString stringWithFormat:@"Chapter %d", index + 1];
        mpv_node_list *map = item.u.list;
        for (int field = 0; field < map->num; field++) {
            const char *key = map->keys[field];
            mpv_node value = map->values[field];
            if (!key) {
                continue;
            }
            if (strcmp(key, "title") == 0 && value.format == MPV_FORMAT_STRING) {
                chapter.title = [NSString stringWithUTF8String:value.u.string];
            } else if (strcmp(key, "time") == 0) {
                if (value.format == MPV_FORMAT_DOUBLE) {
                    chapter.startTime = value.u.double_;
                } else if (value.format == MPV_FORMAT_INT64) {
                    chapter.startTime = (double)value.u.int64;
                }
            }
        }
        [chapters addObject:chapter];
    }
    void (^handler)(NSArray<HSMpvChapterInfo *> *) = self.chapterHandler;
    if (handler) {
        NSArray<HSMpvChapterInfo *> *snapshot = chapters.copy;
        uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
                return;
            }
            handler(snapshot);
        });
    }
}

- (void)emitTracksFromNode:(mpv_node *)node {
    if (!node || node->format != MPV_FORMAT_NODE_ARRAY || !node->u.list) {
        return;
    }
    NSMutableArray<HSMpvTrackInfo *> *tracks = [NSMutableArray array];
    BOOL hasSelectedInternalASSEffects = NO;
    mpv_node_list *list = node->u.list;
    for (int index = 0; index < list->num; index++) {
        mpv_node item = list->values[index];
        if (item.format != MPV_FORMAT_NODE_MAP || !item.u.list) {
            continue;
        }
        HSMpvTrackInfo *track = [[HSMpvTrackInfo alloc] init];
        track.ffIndex = -1;
        mpv_node_list *map = item.u.list;
        for (int field = 0; field < map->num; field++) {
            const char *key = map->keys[field];
            mpv_node value = map->values[field];
            if (!key) {
                continue;
            }
            if (strcmp(key, "id") == 0 && value.format == MPV_FORMAT_INT64) {
                track.trackID = (NSInteger)value.u.int64;
            } else if (strcmp(key, "type") == 0 && value.format == MPV_FORMAT_STRING) {
                track.type = [NSString stringWithUTF8String:value.u.string];
            } else if (strcmp(key, "title") == 0 && value.format == MPV_FORMAT_STRING) {
                track.title = [NSString stringWithUTF8String:value.u.string];
            } else if (strcmp(key, "lang") == 0 && value.format == MPV_FORMAT_STRING) {
                track.language = [NSString stringWithUTF8String:value.u.string];
            } else if (strcmp(key, "codec") == 0 && value.format == MPV_FORMAT_STRING) {
                track.codec = [NSString stringWithUTF8String:value.u.string];
            } else if (strcmp(key, "ff-index") == 0 && value.format == MPV_FORMAT_INT64) {
                track.ffIndex = (NSInteger)value.u.int64;
            } else if (strcmp(key, "external-filename") == 0 && value.format == MPV_FORMAT_STRING) {
                track.externalFilename = [NSString stringWithUTF8String:value.u.string];
            } else if (strcmp(key, "image") == 0 && value.format == MPV_FORMAT_FLAG) {
                track.image = value.u.flag != 0;
            } else if (strcmp(key, "selected") == 0 && value.format == MPV_FORMAT_FLAG) {
                track.selected = value.u.flag != 0;
            }
        }
        if (track.type.length == 0) {
            continue;
        }
        if ([track.type isEqualToString:@"sub"]
            && [track.title isEqualToString:HSMpvInternalASSSubtitleEffectsTitle]) {
            _internalASSSubtitleEffectsTrackID.store(
                (int64_t)track.trackID,
                std::memory_order_release
            );
            hasSelectedInternalASSEffects = track.isSelected;
            continue;
        }
        if (track.title.length == 0) {
            track.title = [NSString stringWithFormat:@"%@ %ld",
                track.type.capitalizedString,
                (long)track.trackID];
        }
        [tracks addObject:track];
    }
    int64_t logicalSubtitleTrackID = _internalASSSubtitleLogicalTrackID.load(
        std::memory_order_acquire
    );
    if (hasSelectedInternalASSEffects && logicalSubtitleTrackID > 0) {
        for (HSMpvTrackInfo *track in tracks) {
            if ([track.type isEqualToString:@"sub"]
                && track.trackID == logicalSubtitleTrackID) {
                track.selected = YES;
                break;
            }
        }
    }
    BOOL shouldRenderNativeImageSubtitles = NO;
    BOOL hasSelectedSubtitle = NO;
    BOOL hasExpectedRemoteAudio = NO;
    for (HSMpvTrackInfo *track in tracks) {
        if ([track.type isEqualToString:@"sub"] && track.isSelected && track.isImage) {
            shouldRenderNativeImageSubtitles = YES;
        }
        if ([track.type isEqualToString:@"sub"] && track.isSelected) {
            hasSelectedSubtitle = YES;
        }
        if ([track.type isEqualToString:@"audio"]
            && track.externalFilename.length > 0
            && _expectedRemoteAudioURLString.length > 0
            && [track.externalFilename isEqualToString:_expectedRemoteAudioURLString]) {
            hasExpectedRemoteAudio = YES;
        }
    }
    if (hasExpectedRemoteAudio) {
        [self emitRemoteAudioStateAttached:YES errorMessage:nil];
    }
    if (_handle && !_shuttingDown) {
        mpv_set_property_string(
            _handle,
            "sub-visibility",
            (shouldRenderNativeImageSubtitles
                || hasSelectedInternalASSEffects
                || (hasSelectedSubtitle
                    && _nativeSubtitleRenderingEnabled.load(std::memory_order_acquire)))
                ? "yes"
                : "no"
        );
    }
    void (^handler)(NSArray<HSMpvTrackInfo *> *) = self.trackHandler;
    if (handler) {
        NSArray<HSMpvTrackInfo *> *snapshot = tracks.copy;
        uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
                return;
            }
            handler(snapshot);
        });
    }
}

- (void)emitSubtitleCuesFromNode:(nullable mpv_node *)node {
    NSMutableArray<HSMpvSubtitleCueInfo *> *cues = [NSMutableArray array];
    if (node && node->format == MPV_FORMAT_NODE_ARRAY && node->u.list) {
        mpv_node_list *list = node->u.list;
        for (int index = 0; index < list->num; index++) {
            mpv_node item = list->values[index];
            if (item.format != MPV_FORMAT_NODE_MAP || !item.u.list) {
                continue;
            }
            HSMpvSubtitleCueInfo *cue = [[HSMpvSubtitleCueInfo alloc] init];
            cue.endTime = NAN;
            mpv_node_list *map = item.u.list;
            for (int field = 0; field < map->num; field++) {
                const char *key = map->keys[field];
                mpv_node value = map->values[field];
                if (!key) {
                    continue;
                }
                if (strcmp(key, "text") == 0 && value.format == MPV_FORMAT_STRING) {
                    cue.text = [NSString stringWithUTF8String:value.u.string];
                } else if (strcmp(key, "start") == 0) {
                    if (value.format == MPV_FORMAT_DOUBLE) {
                        cue.startTime = value.u.double_;
                    } else if (value.format == MPV_FORMAT_INT64) {
                        cue.startTime = (double)value.u.int64;
                    }
                } else if (strcmp(key, "end") == 0) {
                    if (value.format == MPV_FORMAT_DOUBLE) {
                        cue.endTime = value.u.double_;
                    } else if (value.format == MPV_FORMAT_INT64) {
                        cue.endTime = (double)value.u.int64;
                    }
                }
            }
            if (cue.text.length == 0) {
                continue;
            }
            if (isnan(cue.endTime)) {
                cue.endTime = cue.startTime + 10;
            }
            cue.cueID = [NSString stringWithFormat:@"embedded-%d-%.6f", index, cue.startTime];
            [cues addObject:cue];
        }
    }

    [self emitSubtitleCueSnapshot:cues];
}

- (void)emitSubtitleCueSnapshot:(NSArray<HSMpvSubtitleCueInfo *> *)cues {
    NSUInteger signature = 17;
    for (HSMpvSubtitleCueInfo *cue in cues) {
        signature = signature * 31u ^ cue.cueID.hash;
        signature = signature * 31u ^ cue.text.hash;
        signature = signature * 31u ^ @(cue.endTime).hash;
    }
    [_subtitleCueLock lock];
    if (_subtitleCueCount == cues.count && _subtitleCueSignature == signature) {
        [_subtitleCueLock unlock];
        return;
    }
    _subtitleCueCount = cues.count;
    _subtitleCueSignature = signature;
    [_subtitleCueLock unlock];

    if (_handle && !_shuttingDown) {
        mpv_set_property_string(
            _handle,
            "sub-visibility",
            _nativeSubtitleRenderingEnabled.load(std::memory_order_acquire) ? "yes" : "no"
        );
    }
    void (^handler)(NSArray<HSMpvSubtitleCueInfo *> *) = self.subtitleCueHandler;
    if (handler) {
        NSArray<HSMpvSubtitleCueInfo *> *snapshot = cues.copy;
        uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
                return;
            }
            handler(snapshot);
        });
    }
}

- (void)resetSubtitleCueCache {
    [_subtitleCueLock lock];
    _subtitleCueSignature = 0;
    _subtitleCueCount = 0;
    _fallbackSubtitleCues = [NSMutableArray array];
    [_subtitleCueLock unlock];
}

- (NSArray<HSMpvSubtitleCueInfo *> *)upsertFallbackSubtitleCueWithText:(NSString *)text
    startTime:(double)startTime
    endTime:(double)endTime {
    NSString *cueID = [NSString stringWithFormat:
        @"embedded-%.6f-%lu",
        startTime,
        (unsigned long)text.hash
    ];
    [_subtitleCueLock lock];
    NSUInteger existingIndex = [_fallbackSubtitleCues indexOfObjectPassingTest:
        ^BOOL(HSMpvSubtitleCueInfo *cue, NSUInteger index, BOOL *stop) {
            return [cue.cueID isEqualToString:cueID];
        }
    ];
    HSMpvSubtitleCueInfo *cue = existingIndex == NSNotFound
        ? [[HSMpvSubtitleCueInfo alloc] init]
        : _fallbackSubtitleCues[existingIndex];
    cue.cueID = cueID;
    cue.startTime = startTime;
    cue.endTime = endTime;
    cue.text = text;
    if (existingIndex == NSNotFound) {
        [_fallbackSubtitleCues addObject:cue];
        [_fallbackSubtitleCues sortUsingComparator:
            ^NSComparisonResult(HSMpvSubtitleCueInfo *left, HSMpvSubtitleCueInfo *right) {
                if (left.startTime < right.startTime) {
                    return NSOrderedAscending;
                }
                if (left.startTime > right.startTime) {
                    return NSOrderedDescending;
                }
                return NSOrderedSame;
            }
        ];
    }
    NSArray<HSMpvSubtitleCueInfo *> *snapshot = [self fallbackSubtitleCueSnapshot];
    [_subtitleCueLock unlock];
    return snapshot;
}

- (NSArray<HSMpvSubtitleCueInfo *> *)fallbackSubtitleCueSnapshot {
    [_subtitleCueLock lock];
    NSMutableArray<HSMpvSubtitleCueInfo *> *snapshot = [NSMutableArray arrayWithCapacity:_fallbackSubtitleCues.count];
    for (HSMpvSubtitleCueInfo *cue in _fallbackSubtitleCues) {
        [snapshot addObject:HSMpvCopySubtitleCueInfo(cue)];
    }
    [_subtitleCueLock unlock];
    return snapshot.copy;
}

- (void)refreshSubtitleCues {
    if (!_handle || _shuttingDown) {
        return;
    }
    if (_internalASSSubtitleEffectsTrackID.load(std::memory_order_acquire) > 0) {
        [self emitSubtitleCuesFromNode:NULL];
        return;
    }
    mpv_node node = {0};
    int status = mpv_get_property(_handle, "sub-lines", MPV_FORMAT_NODE, &node);
    if (status >= 0) {
        [self emitSubtitleCuesFromNode:&node];
        mpv_free_node_contents(&node);
    } else if (status == MPV_ERROR_PROPERTY_NOT_FOUND) {
        [self refreshCurrentSubtitleCue];
    } else {
        [self emitSubtitleCuesFromNode:NULL];
    }
}

- (void)refreshCurrentSubtitleCue {
    char *textValue = NULL;
    double startTime = 0;
    double endTime = 0;
    int textStatus = mpv_get_property(
        _handle,
        "sub-text",
        MPV_FORMAT_STRING,
        &textValue
    );
    int startStatus = mpv_get_property(
        _handle,
        "sub-start",
        MPV_FORMAT_DOUBLE,
        &startTime
    );
    int endStatus = mpv_get_property(
        _handle,
        "sub-end",
        MPV_FORMAT_DOUBLE,
        &endTime
    );

    if (textStatus >= 0 && startStatus >= 0 && textValue && textValue[0] != '\0') {
        NSString *text = [NSString stringWithUTF8String:textValue];
        NSArray<HSMpvSubtitleCueInfo *> *snapshot = [self upsertFallbackSubtitleCueWithText:text
            startTime:startTime
            endTime:endStatus >= 0 && endTime >= startTime
            ? endTime
            : startTime + 10];
        [self emitSubtitleCueSnapshot:snapshot];
    } else {
        [self emitSubtitleCueSnapshot:[self fallbackSubtitleCueSnapshot]];
    }
    if (textValue) {
        mpv_free(textValue);
    }
}

- (void)emitStateWithError:(nullable NSString *)errorMessage {
    HSMpvStateHandler handler = self.stateHandler;
    if (!handler) {
        return;
    }
    double currentTime = _currentTime;
    double duration = _duration;
    BOOL playing = !_paused && _loaded;
    BOOL loaded = _loaded;
    double speed = _speed;
    double volume = _volume;
    BOOL muted = _muted;
    double subtitleDelay = _subtitleDelay;
    double audioDelay = _audioDelay;
    NSString *loopMode = _loopMode ?: @"none";
    double abLoopStart = _abLoopStart;
    double abLoopEnd = _abLoopEnd;
    NSString *aspectRatio = _aspectRatio ?: @"-1";
    NSInteger rotation = _rotation;
    NSInteger videoWidth = _videoWidth;
    NSInteger videoHeight = _videoHeight;
    uint64_t guardedLoadGeneration = _loadGeneration.load(std::memory_order_acquire);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isCurrentLoadGeneration:guardedLoadGeneration]) {
            return;
        }
        handler(
            currentTime,
            duration,
            playing,
            loaded,
            speed,
            volume,
            muted,
            subtitleDelay,
            audioDelay,
            loopMode,
            abLoopStart,
            abLoopEnd,
            aspectRatio,
            rotation,
            videoWidth,
            videoHeight,
            errorMessage
        );
    });
}

- (NSInteger)sourceVideoRotation {
    return _sourceVideoRotation.load(std::memory_order_acquire);
}

@end

static void HSMpvSetHTTPHeaders(
    mpv_handle *handle,
    NSDictionary<NSString *, NSString *> *headers
) {
    if (!handle) {
        return;
    }
    if (headers.count == 0) {
        mpv_set_property_string(handle, "http-header-fields", "");
        return;
    }

    mpv_node_list list;
    memset(&list, 0, sizeof(list));
    list.num = (int)headers.count;
    list.values = (mpv_node *)calloc(headers.count, sizeof(mpv_node));
    if (!list.values) {
        return;
    }

    NSUInteger index = 0;
    for (NSString *key in headers) {
        NSString *field = [NSString stringWithFormat:@"%@: %@", key, headers[key]];
        list.values[index].format = MPV_FORMAT_STRING;
        list.values[index].u.string = strdup(field.UTF8String);
        index += 1;
    }

    mpv_node node;
    memset(&node, 0, sizeof(node));
    node.format = MPV_FORMAT_NODE_ARRAY;
    node.u.list = &list;
    mpv_set_property(handle, "http-header-fields", MPV_FORMAT_NODE, &node);

    for (int item = 0; item < list.num; item++) {
        free(list.values[item].u.string);
    }
    free(list.values);
}

static NSDictionary<NSString *, NSString *> * _Nullable HSMpvMergedHTTPHeaders(
    NSDictionary<NSString *, NSString *> *videoHeaders,
    NSDictionary<NSString *, NSString *> *audioHeaders
) {
    NSMutableDictionary<NSString *, NSString *> *merged = [videoHeaders mutableCopy];
    NSMutableDictionary<NSString *, NSString *> *canonicalKeys = [NSMutableDictionary dictionary];
    for (NSString *key in videoHeaders) {
        canonicalKeys[key.lowercaseString] = key;
    }
    for (NSString *key in audioHeaders) {
        NSString *canonicalKey = canonicalKeys[key.lowercaseString];
        NSString *audioValue = audioHeaders[key];
        if (canonicalKey) {
            if (![merged[canonicalKey] isEqualToString:audioValue]) {
                return nil;
            }
            continue;
        }
        merged[key] = audioValue;
        canonicalKeys[key.lowercaseString] = key;
    }
    return merged.copy;
}

static int HSMpvSetHTTPHeaderOption(
    mpv_handle *handle,
    NSDictionary<NSString *, NSString *> *headers
) {
    if (!handle || headers.count == 0) {
        return 0;
    }
    mpv_node_list list;
    memset(&list, 0, sizeof(list));
    list.num = (int)headers.count;
    list.values = (mpv_node *)calloc(headers.count, sizeof(mpv_node));
    if (!list.values) {
        return MPV_ERROR_NOMEM;
    }
    NSUInteger index = 0;
    for (NSString *key in headers) {
        NSString *field = [NSString stringWithFormat:@"%@: %@", key, headers[key]];
        list.values[index].format = MPV_FORMAT_STRING;
        list.values[index].u.string = strdup(field.UTF8String);
        index += 1;
    }
    mpv_node node;
    memset(&node, 0, sizeof(node));
    node.format = MPV_FORMAT_NODE_ARRAY;
    node.u.list = &list;
    int status = mpv_set_option(handle, "http-header-fields", MPV_FORMAT_NODE, &node);
    for (int item = 0; item < list.num; item++) {
        free(list.values[item].u.string);
    }
    free(list.values);
    return status;
}
