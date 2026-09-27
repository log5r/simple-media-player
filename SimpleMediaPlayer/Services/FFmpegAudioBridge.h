#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SMPFFmpegAudioInfo : NSObject
@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSInteger channelCount;
@property (nonatomic, readonly) NSInteger bitrate;
@property (nonatomic, copy, readonly) NSString *codecName;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *tags;
@property (nonatomic, copy, nullable, readonly) NSData *artworkData;
@end

@interface SMPFFmpegAudio : NSObject
+ (nullable SMPFFmpegAudioInfo *)probeURL:(NSURL *)url error:(NSError **)error;
+ (BOOL)decodeURL:(NSURL *)url
             toCAF:(NSURL *)destinationURL
          maxBytes:(int64_t)maxBytes
      shouldCancel:(BOOL (^)(void))shouldCancel
             error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
