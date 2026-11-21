// Apple audio output using Audio Queue Services. Intended for the future iOS target;
// the current project CMake still builds only its Windows/XAudio2 host.
#include <AudioToolbox/AudioToolbox.h>

#include <array>
#include <functional>
#include <memory>
#include <utility>

#include "audio/audio.h"
#include "core/log.h"

namespace audio {
namespace {

constexpr UInt32 kFramesPerBuffer = kRate / 100;
constexpr UInt32 kBufferCount = 3;

struct QueueState {
    std::function<void(float*, uint32_t)> render;
    std::array<AudioQueueBufferRef, kBufferCount> buffers{};
};

void FillBuffer(void* opaque, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    auto& state = *static_cast<QueueState*>(opaque);
    state.render(reinterpret_cast<float*>(buffer->mAudioData), kFramesPerBuffer);
    buffer->mAudioDataByteSize = kFramesPerBuffer * 2 * sizeof(float);
    const OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
    if (status != noErr) LOGE("audio: AudioQueueEnqueueBuffer failed: %d", int(status));
}

}  // namespace

void StartOutput(std::function<void(float*, uint32_t)> render) {
    auto state = std::make_unique<QueueState>(QueueState{std::move(render), {}});
    AudioStreamBasicDescription format{};
    format.mSampleRate = kRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 2 * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2 * sizeof(float);
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 8 * sizeof(float);

    AudioQueueRef queue = nullptr;
    OSStatus status = AudioQueueNewOutput(&format, FillBuffer, state.get(), nullptr, nullptr, 0, &queue);
    if (status != noErr) {
        LOGE("audio: AudioQueueNewOutput failed: %d", int(status));
        return;
    }
    for (auto& buffer : state->buffers) {
        status = AudioQueueAllocateBuffer(queue, kFramesPerBuffer * 2 * sizeof(float), &buffer);
        if (status != noErr) {
            LOGE("audio: AudioQueueAllocateBuffer failed: %d", int(status));
            AudioQueueDispose(queue, true);
            return;
        }
        state->render(reinterpret_cast<float*>(buffer->mAudioData), kFramesPerBuffer);
        buffer->mAudioDataByteSize = kFramesPerBuffer * 2 * sizeof(float);
        status = AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
        if (status != noErr) {
            LOGE("audio: AudioQueueEnqueueBuffer failed: %d", int(status));
            AudioQueueDispose(queue, true);
            return;
        }
    }
    status = AudioQueueStart(queue, nullptr);
    if (status != noErr) {
        LOGE("audio: AudioQueueStart failed: %d", int(status));
        AudioQueueDispose(queue, true);
        return;
    }
    // The runtime currently has no audio stop hook; retain callback state for process lifetime.
    state.release();
}

}  // namespace audio
