#import "FFmpegAudioBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <AetherLibavcodec/avcodec.h>
#import <AetherLibavformat/avformat.h>
#import <AetherLibavutil/avutil.h>
#import <AetherLibavutil/dict.h>
#import <AetherLibswresample/swresample.h>

@implementation SMPFFmpegAudioInfo
- (instancetype)initWithDuration:(double)duration
                      sampleRate:(double)sampleRate
                    channelCount:(NSInteger)channelCount
                         bitrate:(NSInteger)bitrate
                       codecName:(NSString *)codecName
                            tags:(NSDictionary<NSString *, NSString *> *)tags
                     artworkData:(NSData *)artworkData {
    self = [super init];
    if (self) {
        _duration = duration;
        _sampleRate = sampleRate;
        _channelCount = channelCount;
        _bitrate = bitrate;
        _codecName = [codecName copy];
        _tags = [tags copy];
        _artworkData = [artworkData copy];
    }
    return self;
}
@end

static NSError *SMPError(int code, NSString *message) {
    return [NSError errorWithDomain:@"SimpleMediaPlayer.FFmpegAudio"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *SMPAVError(int code) {
    char message[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, message, sizeof(message));
    return SMPError(code, [NSString stringWithUTF8String:message]);
}

@implementation SMPAudioCacheSizeLimit

+ (NSNumber *)maximumFramesForFormat:(AVAudioFormat *)format
                        maxFileBytes:(int64_t)maxFileBytes
                               error:(NSError **)error {
    static NSCache<AVAudioFormat *, NSDictionary<NSString *, NSNumber *> *> *sizes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sizes = [[NSCache alloc] init];
        sizes.countLimit = 64;
    });
    NSDictionary<NSString *, NSNumber *> *size = [sizes objectForKey:format];
    if (!size) {
        NSURL *probeURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.caf", NSUUID.UUID.UUIDString]];
        NSError *failure = nil;
        AVAudioFormat *storedFormat = nil;
        @autoreleasepool {
            AVAudioFile *probe = [[AVAudioFile alloc] initForWriting:probeURL
                                                          settings:format.settings
                                                      commonFormat:format.commonFormat
                                                       interleaved:format.isInterleaved
                                                             error:&failure];
            storedFormat = probe.fileFormat;
            // Closing the zero-frame writer finalizes the same CAF header used for decoded caches.
            probe = nil;
        }
        NSDictionary<NSFileAttributeKey, id> *attributes = storedFormat
            ? [[NSFileManager defaultManager] attributesOfItemAtPath:probeURL.path error:&failure] : nil;
        [[NSFileManager defaultManager] removeItemAtURL:probeURL error:nil];
        NSNumber *headerBytes = attributes[NSFileSize];
        int64_t bytesPerFrame = storedFormat ? storedFormat.streamDescription->mBytesPerFrame : 0;
        int64_t channels = storedFormat.isInterleaved ? 1 : storedFormat.channelCount;
        if (!headerBytes || headerBytes.longLongValue <= 0 || bytesPerFrame <= 0
            || channels <= 0 || bytesPerFrame > INT64_MAX / channels) {
            if (error) *error = failure ?: SMPError(EINVAL, @"Could not determine the decoded cache file size.");
            return nil;
        }
        size = @{@"header": headerBytes, @"frame": @(bytesPerFrame * channels)};
        [sizes setObject:size forKey:format];
    }
    int64_t headerBytes = size[@"header"].longLongValue;
    if (maxFileBytes < headerBytes) {
        if (error) *error = SMPError(EFBIG, @"The decoded audio exceeds the cache size limit.");
        return nil;
    }
    return @((maxFileBytes - headerBytes) / size[@"frame"].longLongValue);
}

@end

static NSString *SMPTag(AVDictionary *metadata, const char *key) {
    AVDictionaryEntry *entry = av_dict_get(metadata, key, NULL, 0);
    return entry && entry->value ? [NSString stringWithUTF8String:entry->value] : nil;
}

static NSString *SMPTagInFile(AVStream *stream, AVFormatContext *format, NSString *key) {
    NSString *value = SMPTag(stream->metadata, key.UTF8String) ?: SMPTag(format->metadata, key.UTF8String);
    if (value.length) return value;
    NSString *asfKey = [@{
        @"album_artist": @"WM/AlbumArtist", @"genre": @"WM/Genre", @"date": @"WM/Year",
        @"track": @"WM/TrackNumber", @"disc": @"WM/PartOfSet", @"composer": @"WM/Composer",
        @"lyrics": @"WM/Lyrics"
    } objectForKey:key];
    return asfKey ? (SMPTag(stream->metadata, asfKey.UTF8String)
                     ?: SMPTag(format->metadata, asfKey.UTF8String)) : nil;
}

static int SMPOpen(NSURL *url, AVFormatContext **format, AVCodecContext **codec, int *streamIndex) {
    int result = avformat_open_input(format, url.fileSystemRepresentation, NULL, NULL);
    if (result < 0) return result;
    result = avformat_find_stream_info(*format, NULL);
    if (result < 0) return result;
    result = av_find_best_stream(*format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (result < 0) return result;
    *streamIndex = result;
    AVCodecParameters *parameters = (*format)->streams[result]->codecpar;
    const AVCodec *decoder = avcodec_find_decoder(parameters->codec_id);
    if (!decoder) return AVERROR_DECODER_NOT_FOUND;
    *codec = avcodec_alloc_context3(decoder);
    if (!*codec) return AVERROR(ENOMEM);
    result = avcodec_parameters_to_context(*codec, parameters);
    if (result < 0) return result;
    return avcodec_open2(*codec, decoder, NULL);
}

static BOOL SMPConvertDecodedFrame(AVFrame *frame, NSURL *destinationURL, int64_t maxBytes,
                                   AVAudioFile * __strong *output, AVAudioFormat * __strong *outputFormat,
                                   SwrContext **resampler, int64_t *writtenFrames,
                                   int64_t *maximumFileFrames, NSError **failure) {
    if (frame && (frame->ch_layout.nb_channels < 1 || frame->ch_layout.nb_channels > 8
                  || frame->sample_rate <= 0 || frame->nb_samples < 0)) {
        *failure = SMPError(EINVAL, @"Unsupported audio channel layout, sample rate, or frame size.");
        return NO;
    }
    if (!*outputFormat) {
        int channels = frame->ch_layout.nb_channels;
        *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                         sampleRate:frame->sample_rate
                                                           channels:channels
                                                        interleaved:NO];
        if (!*outputFormat) {
            *failure = SMPError(EINVAL, @"Could not create an audio output format.");
            return NO;
        }
        NSNumber *maximumFrames = [SMPAudioCacheSizeLimit maximumFramesForFormat:*outputFormat
                                                                   maxFileBytes:maxBytes error:failure];
        if (!maximumFrames) return NO;
        *maximumFileFrames = maximumFrames.longLongValue;
        if (destinationURL) {
            *output = [[AVAudioFile alloc] initForWriting:destinationURL
                                                settings:(*outputFormat).settings
                                            commonFormat:AVAudioPCMFormatFloat32
                                             interleaved:NO
                                                   error:failure];
            if (!*output) return NO;
        }
        AVChannelLayout outputLayout;
        av_channel_layout_default(&outputLayout, channels);
        int result = swr_alloc_set_opts2(resampler, &outputLayout, AV_SAMPLE_FMT_FLTP,
                                         frame->sample_rate, &frame->ch_layout,
                                         frame->format, frame->sample_rate, 0, NULL);
        av_channel_layout_uninit(&outputLayout);
        if (result < 0 || !*resampler) {
            *failure = result < 0 ? SMPAVError(result) : SMPError(ENOMEM, @"Could not create an audio resampler.");
            return NO;
        }
        result = swr_init(*resampler);
        if (result < 0) { *failure = SMPAVError(result); return NO; }
    }

    int capacity = swr_get_out_samples(*resampler, frame ? frame->nb_samples : 0);
    if (!frame && capacity == 0) return YES;
    if (capacity <= 0) {
        *failure = SMPError(EINVAL, @"Invalid decoded audio frame size.");
        return NO;
    }
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:*outputFormat
                                                            frameCapacity:(AVAudioFrameCount)capacity];
    if (!buffer) { *failure = SMPError(ENOMEM, @"Could not allocate an audio output buffer."); return NO; }
    int converted = swr_convert(*resampler, (uint8_t **)buffer.floatChannelData,
                                capacity, frame ? (const uint8_t **)frame->extended_data : NULL,
                                frame ? frame->nb_samples : 0);
    if (converted < 0) { *failure = SMPAVError(converted); return NO; }
    buffer.frameLength = (AVAudioFrameCount)converted;
    int64_t maximumFrames = maxBytes / ((*outputFormat).channelCount * sizeof(float));
    if (converted > maximumFrames - *writtenFrames || converted > *maximumFileFrames - *writtenFrames) {
        *failure = SMPError(EFBIG, @"The decoded audio exceeds the cache size limit.");
        return NO;
    }
    *writtenFrames += converted;
    if (*output && converted > 0 && ![*output writeFromBuffer:buffer error:failure]) return NO;
    return YES;
}

@implementation SMPFFmpegAudio

+ (SMPFFmpegAudioInfo *)probeURL:(NSURL *)url error:(NSError **)error {
    AVFormatContext *format = NULL;
    AVCodecContext *codec = NULL;
    int streamIndex = -1;
    int result = SMPOpen(url, &format, &codec, &streamIndex);
    if (result < 0) {
        if (error) *error = SMPAVError(result);
        avcodec_free_context(&codec);
        avformat_close_input(&format);
        return nil;
    }

    AVStream *stream = format->streams[streamIndex];
    AVCodecParameters *parameters = stream->codecpar;
    double duration = 0;
    if (stream->duration > 0 && stream->duration != AV_NOPTS_VALUE) {
        duration = stream->duration * av_q2d(stream->time_base);
    } else if (format->duration > 0 && format->duration != AV_NOPTS_VALUE) {
        duration = (double)format->duration / AV_TIME_BASE;
    }
    NSMutableDictionary<NSString *, NSString *> *tags = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"title", @"artist", @"album", @"album_artist", @"genre",
                           @"date", @"track", @"disc", @"composer", @"comment", @"lyrics"]) {
        NSString *value = SMPTagInFile(stream, format, key);
        if (value.length) tags[key] = value;
    }

    NSData *artwork = nil;
    for (unsigned index = 0; index < format->nb_streams; ++index) {
        AVStream *candidate = format->streams[index];
        if ((candidate->disposition & AV_DISPOSITION_ATTACHED_PIC) && candidate->attached_pic.size > 0) {
            artwork = [NSData dataWithBytes:candidate->attached_pic.data length:candidate->attached_pic.size];
            break;
        }
    }
    SMPFFmpegAudioInfo *info = [[SMPFFmpegAudioInfo alloc]
        initWithDuration:duration
              sampleRate:parameters->sample_rate
            channelCount:parameters->ch_layout.nb_channels
                 bitrate:parameters->bit_rate ?: format->bit_rate
               codecName:[NSString stringWithUTF8String:avcodec_get_name(parameters->codec_id)]
                    tags:tags
             artworkData:artwork];
    avcodec_free_context(&codec);
    avformat_close_input(&format);
    return info;
}

+ (BOOL)processURL:(NSURL *)url
             toCAF:(NSURL *)destinationURL
          maxBytes:(int64_t)maxBytes
      shouldCancel:(BOOL (^)(void))shouldCancel
             error:(NSError **)error {
    AVFormatContext *format = NULL;
    AVCodecContext *codec = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    SwrContext *resampler = NULL;
    int streamIndex = -1;
    int result = SMPOpen(url, &format, &codec, &streamIndex);
    BOOL success = NO;
    NSError *failure = nil;
    AVAudioFile *output = nil;
    AVAudioFormat *outputFormat = nil;
    int64_t writtenFrames = 0;
    int64_t maximumFileFrames = 0;

    if (result < 0) { failure = SMPAVError(result); goto cleanup; }
    if (maxBytes <= 0) { failure = SMPError(EFBIG, @"Invalid decoded audio size limit."); goto cleanup; }
    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (!packet || !frame) { failure = SMPError(ENOMEM, @"Could not allocate an audio decoder buffer."); goto cleanup; }

    while ((result = av_read_frame(format, packet)) >= 0) {
        if (shouldCancel()) { failure = SMPError(NSUserCancelledError, @"Audio conversion cancelled."); goto cleanup; }
        if (packet->stream_index != streamIndex) { av_packet_unref(packet); continue; }
        result = avcodec_send_packet(codec, packet);
        av_packet_unref(packet);
        if (result < 0) { failure = SMPAVError(result); goto cleanup; }

        while ((result = avcodec_receive_frame(codec, frame)) >= 0) {
            if (shouldCancel()) { failure = SMPError(NSUserCancelledError, @"Audio conversion cancelled."); goto cleanup; }
            if (!SMPConvertDecodedFrame(frame, destinationURL, maxBytes, &output, &outputFormat,
                                        &resampler, &writtenFrames, &maximumFileFrames, &failure)) goto cleanup;
            av_frame_unref(frame);
        }
        if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
            failure = SMPAVError(result); goto cleanup;
        }
    }
    if (result != AVERROR_EOF) { failure = SMPAVError(result); goto cleanup; }
    if (shouldCancel()) { failure = SMPError(NSUserCancelledError, @"Audio conversion cancelled."); goto cleanup; }
    result = avcodec_send_packet(codec, NULL);
    if (result < 0) { failure = SMPAVError(result); goto cleanup; }
    while ((result = avcodec_receive_frame(codec, frame)) >= 0) {
        if (shouldCancel()) { failure = SMPError(NSUserCancelledError, @"Audio conversion cancelled."); goto cleanup; }
        if (!SMPConvertDecodedFrame(frame, destinationURL, maxBytes, &output, &outputFormat,
                                    &resampler, &writtenFrames, &maximumFileFrames, &failure)) goto cleanup;
        av_frame_unref(frame);
    }
    if (result != AVERROR_EOF) { failure = SMPAVError(result); goto cleanup; }
    if (resampler) {
        int64_t previousFrames;
        do {
            if (shouldCancel()) { failure = SMPError(NSUserCancelledError, @"Audio conversion cancelled."); goto cleanup; }
            previousFrames = writtenFrames;
            if (!SMPConvertDecodedFrame(NULL, destinationURL, maxBytes, &output, &outputFormat,
                                        &resampler, &writtenFrames, &maximumFileFrames, &failure)) goto cleanup;
        } while (writtenFrames > previousFrames);
    }
    if (shouldCancel()) { failure = SMPError(NSUserCancelledError, @"Audio conversion cancelled."); goto cleanup; }
    if (writtenFrames == 0) {
        failure = SMPError(EINVAL, @"The file contains no decodable audio."); goto cleanup;
    }
    success = YES;

cleanup:
    swr_free(&resampler);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&codec);
    avformat_close_input(&format);
    if (!success && error) *error = failure ?: SMPError(EINVAL, @"Audio decoding failed.");
    return success;
}

+ (BOOL)validateURL:(NSURL *)url
          maxBytes:(int64_t)maxBytes
      shouldCancel:(BOOL (^)(void))shouldCancel
             error:(NSError **)error {
    return [self processURL:url toCAF:nil maxBytes:maxBytes shouldCancel:shouldCancel error:error];
}

+ (BOOL)decodeURL:(NSURL *)url
             toCAF:(NSURL *)destinationURL
          maxBytes:(int64_t)maxBytes
      shouldCancel:(BOOL (^)(void))shouldCancel
             error:(NSError **)error {
    return [self processURL:url toCAF:destinationURL maxBytes:maxBytes shouldCancel:shouldCancel error:error];
}

@end
