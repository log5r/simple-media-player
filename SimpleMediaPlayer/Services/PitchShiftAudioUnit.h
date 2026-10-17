#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pitch-only processing with a constant delay, including at zero cents.
/// Graph changes remain the caller's responsibility; pitch and reset requests are atomic.
NS_SWIFT_SENDABLE
@interface SMPPitchEffect : NSObject
@property (nonatomic, readonly) AVAudioUnitEffect *node;
@property (nonatomic) float pitchCents;
@property (nonatomic, readonly) NSTimeInterval latency;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
