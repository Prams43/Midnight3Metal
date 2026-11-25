// Apple audio output using Audio Queue Services.
// Supports a hot-swap render callback so the XDK dsound mixer can take over from
// the initial silent callback installed by the app host at startup.
#include <AudioToolbox/AudioToolbox.h>

#include <array>
#include <atomic>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>

#include "audio/audio.h"
#include "core/log.h"

namespace audio {
namespace {

constexpr UInt32 kFramesPerBuffer = kRate / 100;
constexpr UInt32 kBufferCount = 3;

// Global hot-swappable render callback. Protected by a simple spinlock via
// std::atomic so dsound can replace it without restarting the audio queue.
std::mutex g_render_mutex;
std::function<void(float*, uint32_t)> g_render;
std::atomic<bool> g_queue_started{false};

struct QueueState {
    std::array<AudioQueueBufferRef, kBufferCount> buffers{};
};

void FillBuffer(void* opaque, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    {
        std::lock_guard<std::mutex> lk(g_render_mutex);
        if (g_render) {
            g_render(reinterpret_cast<float*>(buffer->mAudioData), kFramesPerBuffer);
        } else {
            std::memset(buffer->mAudioData, 0, kFramesPerBuffer * 2 * sizeof(float));
        }
    }
    buffer->mAudioDataByteSize = kFramesPerBuffer * 2 * sizeof(float);
    const OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
    if (status != noErr) LOGE("audio: AudioQueueEnqueueBuffer failed: %d", int(status));
}

}  // namespace

// Called by ViewController at startup (with a silent or frame-counter callback)
// and again by dsound::Start() to wire in the real mixer — the second call just
// swaps the callback without touching the AudioQueue.
void StartOutput(std::function<void(float*, uint32_t)> render) {
    // If already running, just hot-swap the render callback.
    if (g_queue_started.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lk(g_render_mutex);
        g_render = std::move(render);
        LOGI("audio: render callback swapped (dsound mixer active)");
        return;
    }

    {
        std::lock_guard<std::mutex> lk(g_render_mutex);
        g_render = std::move(render);
    }

    auto state = std::make_unique<QueueState>();
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
        // Prime buffer with silence
        std::memset(buffer->mAudioData, 0, kFramesPerBuffer * 2 * sizeof(float));
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
    g_queue_started.store(true, std::memory_order_release);
    // The runtime has no audio stop hook; retain queue state for process lifetime.
    state.release();
    LOGI("audio: AudioQueue started (%u Hz stereo float)", unsigned(kRate));
}

}  // namespace audio
