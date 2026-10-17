#import "PitchShiftAudioUnit.h"
#import <AudioToolbox/AUAudioUnitImplementation.h>

#define SIGNALSMITH_USE_ACCELERATE
// Keep the upstream header unchanged; its long seed converts to the RNG's unsigned seed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#include "../Vendor/SignalsmithStretch/signalsmith-stretch.h"
#pragma clang diagnostic pop

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace {
constexpr AUAudioChannelCount maximumChannels = 32;
constexpr AUAudioFrameCount maximumBufferFrames = 65536;
constexpr double defaultLatency = 0.12;
using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

static_assert(std::atomic<float>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);

struct BufferListDeleter {
    void operator()(AudioBufferList *list) const { std::free(list); }
};

/// Only requests and reported latency cross threads. DSP state belongs to the render thread.
/// Allocation/deallocation obey AUAudioUnit's stopped-rendering lifecycle contract.
struct PitchRenderState {
    std::atomic<float> requestedCents{0};
    std::atomic<uint64_t> resetGeneration{0};
    std::atomic<double> latencySeconds{defaultLatency};
    std::unique_ptr<Stretch> stretch;
    std::unique_ptr<AudioBufferList, BufferListDeleter> inputList;
    std::vector<float> inputStorage;
    std::vector<float> outputStorage;
    std::vector<const float *> inputs;
    std::vector<float *> outputs;
    AUAudioChannelCount channels = 0;
    AUAudioFrameCount maximumFrames = 0;
    uint64_t appliedResetGeneration = 0;
    float appliedCents = 0;

    void allocate(double sampleRate, AUAudioChannelCount channelCount, AUAudioFrameCount frameCount) {
        channels = channelCount;
        maximumFrames = frameCount;
        stretch = std::make_unique<Stretch>(1);
        stretch->presetDefault(static_cast<int>(channels), static_cast<float>(sampleRate), false);
        appliedCents = requestedCents.load(std::memory_order_relaxed);
        stretch->setTransposeSemitones(appliedCents / 100);
        appliedResetGeneration = resetGeneration.load(std::memory_order_relaxed);
        latencySeconds.store((stretch->inputLatency() + stretch->outputLatency()) / sampleRate,
                             std::memory_order_relaxed);

        const size_t samples = static_cast<size_t>(channels) * maximumFrames;
        inputStorage.resize(samples);
        outputStorage.resize(samples);
        inputs.resize(channels);
        outputs.resize(channels);
        inputList.reset(static_cast<AudioBufferList *>(std::calloc(
            1, offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer))));
        if (!inputList) throw std::bad_alloc();
    }

    void deallocate() {
        stretch.reset();
        inputList.reset();
        std::vector<float>().swap(inputStorage);
        std::vector<float>().swap(outputStorage);
        std::vector<const float *>().swap(inputs);
        std::vector<float *>().swap(outputs);
        channels = 0;
        maximumFrames = 0;
    }

    void applyReset(uint64_t generation) {
        if (generation != appliedResetGeneration) {
            stretch->reset();
            appliedResetGeneration = generation;
        }
    }

    AUAudioUnitStatus discardResetBlock(uint64_t generation, AudioUnitRenderActionFlags *flags,
                                        AUAudioFrameCount frames) {
        applyReset(generation);
        for (AUAudioChannelCount channel = 0; channel < channels; ++channel) {
            std::memset(outputs[channel], 0, frames * sizeof(float));
        }
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    AUAudioUnitStatus render(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                             AUAudioFrameCount frames, NSInteger bus, AudioBufferList *output,
                             AURenderPullInputBlock __unsafe_unretained pullInput) {
        if (!stretch || !inputList) return kAudioUnitErr_Uninitialized;
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        if (frames > maximumFrames) return kAudioUnitErr_TooManyFramesToProcess;
        if (!pullInput) return kAudioUnitErr_NoConnection;
        if (!output || output->mNumberBuffers != channels) return kAudioUnitErr_FormatNotSupported;
        if (frames == 0) return noErr;

        // Bind this input request to its transport generation before calling upstream.
        // Acquire also publishes pitch changes made before that transport operation.
        const uint64_t generation = resetGeneration.load(std::memory_order_acquire);
        applyReset(generation);
        const UInt32 bytes = frames * sizeof(float);
        inputList->mNumberBuffers = channels;
        for (AUAudioChannelCount channel = 0; channel < channels; ++channel) {
            auto &input = inputList->mBuffers[channel];
            input.mNumberChannels = 1;
            input.mDataByteSize = bytes;
            input.mData = inputStorage.data() + static_cast<size_t>(channel) * maximumFrames;
            auto &destination = output->mBuffers[channel];
            if (destination.mNumberChannels != 1) return kAudioUnitErr_FormatNotSupported;
            if (destination.mData && destination.mDataByteSize < bytes) return kAudio_ParamError;
            if (!destination.mData) {
                destination.mData = outputStorage.data() + static_cast<size_t>(channel) * maximumFrames;
            }
            destination.mDataByteSize = bytes;
            outputs[channel] = static_cast<float *>(destination.mData);
        }

        AudioUnitRenderActionFlags inputFlags = *flags & ~kAudioUnitRenderAction_OutputIsSilence;
        const AUAudioUnitStatus status = pullInput(&inputFlags, timestamp, frames, 0, inputList.get());
        if (status != noErr) return status;
        const uint64_t afterPull = resetGeneration.load(std::memory_order_acquire);
        if (afterPull != generation) return discardResetBlock(afterPull, flags, frames);
        if (inputList->mNumberBuffers != channels) return kAudioUnitErr_FormatNotSupported;
        const bool silent = inputFlags & kAudioUnitRenderAction_OutputIsSilence;
        for (AUAudioChannelCount channel = 0; channel < channels; ++channel) {
            float *storage = inputStorage.data() + static_cast<size_t>(channel) * maximumFrames;
            const auto &source = inputList->mBuffers[channel];
            if (silent) {
                std::memset(storage, 0, bytes);
            } else {
                if (source.mNumberChannels != 1 || !source.mData || source.mDataByteSize < bytes) {
                    return kAudioUnitErr_FormatNotSupported;
                }
                // Pulls may replace mData, and the stretcher requires separate input/output buffers.
                std::memmove(storage, source.mData, bytes);
            }
            inputs[channel] = storage;
        }

        const float cents = requestedCents.load(std::memory_order_relaxed);
        if (cents != appliedCents) {
            stretch->setTransposeSemitones(cents / 100);
            appliedCents = cents;
        }
        stretch->process(inputs.data(), static_cast<int>(frames), outputs.data(), static_cast<int>(frames));
        const uint64_t afterProcess = resetGeneration.load(std::memory_order_acquire);
        if (afterProcess != generation) return discardResetBlock(afterProcess, flags, frames);
        // Silent input can still produce a delayed tail. Never propagate its silence flag.
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
};

AudioComponentDescription componentDescription() {
    return {kAudioUnitType_Effect, 'smpt', 'Log5', kAudioComponentFlag_SandboxSafe, 0};
}

BOOL failAllocation(NSError **error, OSStatus status) {
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    return NO;
}
} // namespace

@interface SMPPitchAudioUnit : AUAudioUnit
@property (nonatomic) float requestedPitchCents;
- (void)requestReset;
@end

@implementation SMPPitchAudioUnit {
    AUAudioUnitBusArray *_inputBusses;
    AUAudioUnitBusArray *_outputBusses;
    std::unique_ptr<PitchRenderState> _state;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (self) {
        _state = std::make_unique<PitchRenderState>();
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
        AUAudioUnitBus *input = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
        if (!input) return nil;
        AUAudioUnitBus *output = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
        if (!output) return nil;
        input.maximumChannelCount = maximumChannels;
        output.maximumChannelCount = maximumChannels;
        _inputBusses = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput
                                                            busses:@[input]];
        _outputBusses = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput
                                                             busses:@[output]];
    }
    return self;
}

- (AUAudioUnitBusArray *)inputBusses { return _inputBusses; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusses; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    AVAudioFormat *input = _inputBusses[0].format;
    AVAudioFormat *output = _outputBusses[0].format;
    if (input.commonFormat != AVAudioPCMFormatFloat32 || input.interleaved ||
        output.commonFormat != AVAudioPCMFormatFloat32 || output.interleaved ||
        input.channelCount != output.channelCount || input.sampleRate != output.sampleRate ||
        input.channelCount == 0 || input.channelCount > maximumChannels ||
        !std::isfinite(input.sampleRate) || input.sampleRate < 8000 || input.sampleRate > 384000 ||
        self.maximumFramesToRender == 0 || self.maximumFramesToRender > maximumBufferFrames) {
        return failAllocation(error, kAudioUnitErr_FormatNotSupported);
    }
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    try {
        _state->allocate(input.sampleRate, input.channelCount, self.maximumFramesToRender);
    } catch (const std::bad_alloc &) {
        _state->deallocate();
        [super deallocateRenderResources];
        return failAllocation(error, kAudio_MemFullError);
    }
    return YES;
}

- (void)deallocateRenderResources {
    _state->deallocate();
    [super deallocateRenderResources];
}

- (AUInternalRenderBlock)internalRenderBlock {
    PitchRenderState *state = _state.get();
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frames, NSInteger bus, AudioBufferList *output,
                              const AURenderEvent *events, AURenderPullInputBlock __unsafe_unretained pullInput) {
        (void)events;
        return state->render(flags, timestamp, frames, bus, output, pullInput);
    };
}

- (NSTimeInterval)latency { return _state->latencySeconds.load(std::memory_order_relaxed); }
- (NSTimeInterval)tailTime { return self.latency; }
- (float)requestedPitchCents { return _state->requestedCents.load(std::memory_order_relaxed); }
- (void)setRequestedPitchCents:(float)cents {
    if (std::isfinite(cents)) {
        _state->requestedCents.store(std::max(-2400.0f, std::min(2400.0f, cents)), std::memory_order_relaxed);
    }
}
- (void)reset {
    [super reset];
    [self requestReset];
}
- (void)requestReset {
    _state->resetGeneration.fetch_add(1, std::memory_order_release);
}
@end

@implementation SMPPitchEffect {
    SMPPitchAudioUnit *_pitchAudioUnit;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [AUAudioUnit registerSubclass:[SMPPitchAudioUnit class]
                  asComponentDescription:componentDescription()
                                    name:@"SimpleMediaPlayer: Pitch" version:0x00010400];
        });
        _node = [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:componentDescription()];
        _pitchAudioUnit = (SMPPitchAudioUnit *)_node.AUAudioUnit;
    }
    return self;
}
- (float)pitchCents { return _pitchAudioUnit.requestedPitchCents; }
- (void)setPitchCents:(float)cents { _pitchAudioUnit.requestedPitchCents = cents; }
- (NSTimeInterval)latency { return _pitchAudioUnit.latency; }
- (void)reset { [_pitchAudioUnit requestReset]; }
@end
