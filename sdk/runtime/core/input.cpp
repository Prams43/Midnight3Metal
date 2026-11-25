// controllers through SDL: Xbox, PlayStation and Switch pads read into the console controller's report
#include "core/input.h"

#include <algorithm>
#include <atomic>
#include <iterator>
#include <mutex>

#include <SDL3/SDL.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

#if !defined(__APPLE__) || !TARGET_OS_IPHONE
#define MC3_INPUT_HAS_SDL_KEYBOARD_FALLBACK 1
#else
#define MC3_INPUT_HAS_SDL_KEYBOARD_FALLBACK 0
#endif

#include "app/app.h"
#include "core/log.h"

namespace input {

namespace {

// a controller takes the lowest free port when it is plugged in and keeps it until it is unplugged
std::mutex g_lock;
bool g_sdl = false;
SDL_Gamepad* g_pads[4] = {};
std::atomic<bool> g_virtual_keys[SDL_SCANCODE_COUNT] = {};
std::atomic<bool> g_virtual_controls[static_cast<size_t>(VirtualControl::Count)] = {};

void AddPad(SDL_JoystickID id) {
    for (SDL_Gamepad* pad : g_pads)
        if (pad && SDL_GetGamepadID(pad) == id) return;
    SDL_Gamepad** slot = std::find(std::begin(g_pads), std::end(g_pads), nullptr);
    if (slot == std::end(g_pads)) return;
    *slot = SDL_OpenGamepad(id);
    const char* name = *slot ? SDL_GetGamepadName(*slot) : SDL_GetError();
    LOGI("input: controller %d %s: %s", int(slot - g_pads) + 1, *slot ? "plugged in" : "failed to open", name ? name : "");
}

void RemovePad(SDL_JoystickID id) {
    for (int i = 0; i < 4; i++) {
        if (!g_pads[i] || SDL_GetGamepadID(g_pads[i]) != id) continue;
        SDL_CloseGamepad(g_pads[i]);
        g_pads[i] = nullptr;
        LOGI("input: controller %d unplugged", i + 1);
    }
}

// once a millisecond at most, however many ports and threads read
void UpdatePads() {
    if (!g_sdl) return;
    static uint64_t last = 0;
    uint64_t now = SDL_GetTicks();
    if (now == last) return;
    last = now;
    SDL_PumpEvents();
    SDL_Event e;
    while (SDL_PeepEvents(&e, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) == 1) {
        if (e.type == SDL_EVENT_GAMEPAD_ADDED) AddPad(e.gdevice.which);
        else if (e.type == SDL_EVENT_GAMEPAD_REMOVED) RemovePad(e.gdevice.which);
    }
}

bool VirtualKeyDown(SDL_Scancode key) {
    return key >= 0 && key < SDL_SCANCODE_COUNT && g_virtual_keys[key].load(std::memory_order_relaxed);
}

bool VirtualControlDown(VirtualControl control) {
    const size_t index = static_cast<size_t>(control);
    return index < static_cast<size_t>(VirtualControl::Count) &&
           g_virtual_controls[index].load(std::memory_order_relaxed);
}

void MergeVirtualControls(Pad& p) {
    const auto down = [](SDL_Scancode key) { return VirtualKeyDown(key); };
    const bool dpad_up = down(SDL_SCANCODE_UP) || VirtualControlDown(VirtualControl::DpadUp);
    const bool dpad_down = down(SDL_SCANCODE_DOWN) || VirtualControlDown(VirtualControl::DpadDown);
    const bool dpad_left = down(SDL_SCANCODE_LEFT) || VirtualControlDown(VirtualControl::DpadLeft);
    const bool dpad_right = down(SDL_SCANCODE_RIGHT) || VirtualControlDown(VirtualControl::DpadRight);
    const bool confirm = down(SDL_SCANCODE_SPACE) || VirtualControlDown(VirtualControl::Confirm);
    const bool back = down(SDL_SCANCODE_BACKSPACE) || VirtualControlDown(VirtualControl::MenuBack);
    const bool start = VirtualControlDown(VirtualControl::Start);
    const bool face_a = down(SDL_SCANCODE_RETURN) || down(SDL_SCANCODE_Z) || VirtualControlDown(VirtualControl::FaceA);
    const bool face_b = down(SDL_SCANCODE_ESCAPE) || down(SDL_SCANCODE_X) || VirtualControlDown(VirtualControl::FaceB);
    const bool face_x = down(SDL_SCANCODE_C) || VirtualControlDown(VirtualControl::FaceX);
    const bool face_y = down(SDL_SCANCODE_V) || VirtualControlDown(VirtualControl::FaceY);
    const bool shoulder_l = down(SDL_SCANCODE_Q) || VirtualControlDown(VirtualControl::ShoulderL);
    const bool shoulder_r = down(SDL_SCANCODE_E) || VirtualControlDown(VirtualControl::ShoulderR);
    const bool accelerate = down(SDL_SCANCODE_W) || VirtualControlDown(VirtualControl::Accelerate);
    const bool brake = down(SDL_SCANCODE_S) || VirtualControlDown(VirtualControl::Brake);
    const bool steer_right = down(SDL_SCANCODE_D) || VirtualControlDown(VirtualControl::SteerRight);
    const bool steer_left = down(SDL_SCANCODE_A) || VirtualControlDown(VirtualControl::SteerLeft);
    // Virtual input is exposed only on port 0.
#if defined(__APPLE__) && TARGET_OS_IPHONE
    // On iOS there is no keyboard fallback, so keep port 0 permanently connected
    // for virtual touch controls; otherwise releasing a button disconnects XInput
    // and causes the game to repeatedly reopen the controller handle.
    p.connected = true;
#endif
    const bool active = dpad_up || dpad_down || dpad_left || dpad_right || confirm || back || start || face_a || face_b ||
                        face_x || face_y || shoulder_l || shoulder_r || accelerate || brake || steer_left || steer_right;
    if (!active) return; // A touch press makes the synthesized controller available for this poll.
    p.connected = true;
    p.buttons |= uint16_t(dpad_up) << 0;
    p.buttons |= uint16_t(dpad_down) << 1;
    p.buttons |= uint16_t(dpad_left) << 2;
    p.buttons |= uint16_t(dpad_right) << 3;
    // Report bit 4 is Start and bit 5 is Back; A/B are analog-button slots.
    p.buttons |= uint16_t(start) << 4;
    p.buttons |= uint16_t(back) << 5;
    if (face_a || confirm) p.analog[0] = 0xFF;
    if (face_b || back) p.analog[1] = 0xFF; // Keep menu back usable in-game as Xbox B.
    if (face_x) p.analog[2] = 0xFF;
    if (face_y) p.analog[3] = 0xFF;
    if (shoulder_l) p.analog[4] = 0xFF;
    if (shoulder_r) p.analog[5] = 0xFF;
    // D-pad is digital navigation only; driving axes come from steering/throttle controls.
    if (steer_right != steer_left) p.lx = steer_right ? 32767 : -32768;
    if (accelerate != brake) p.ly = accelerate ? 32767 : -32768;
}
#ifdef _WIN32
static std::atomic<bool> g_key_state[256] = {};

void MergeWindowsKeyboard(Pad& p) {
    // The title can ask for the same controller report hundreds of times in one
    // frame. GetAsyncKeyState crosses into win32u on every key; sample each key
    // at most once per millisecond. Poll is serialized by g_lock.
    static uint64_t sampled_at = ~0ull;
    static bool known[256] = {};
    static bool direct[256] = {};
    const uint64_t now = SDL_GetTicks();
    if (now != sampled_at) {
        sampled_at = now;
        std::fill(std::begin(known), std::end(known), false);
    }
    auto key_down = [&](int vk) {
        const bool valid = vk >= 0 && vk < 256;
        if (valid && !known[vk]) {
            direct[vk] = (GetAsyncKeyState(vk) & 0x8000) != 0;
            known[vk] = true;
        }
        return (valid && direct[vk]) || (valid && g_key_state[vk].load(std::memory_order_relaxed));
    };
    p.connected = true;
    p.buttons |= uint16_t(key_down(VK_UP)) << 0;
    p.buttons |= uint16_t(key_down(VK_DOWN)) << 1;
    p.buttons |= uint16_t(key_down(VK_LEFT)) << 2;
    p.buttons |= uint16_t(key_down(VK_RIGHT)) << 3;
    p.buttons |= uint16_t(key_down(VK_SPACE)) << 4;
    p.buttons |= uint16_t(key_down(VK_BACK)) << 5;
    p.buttons |= uint16_t(key_down('F')) << 6;
    if (key_down(VK_RETURN) || key_down('Z')) p.analog[0] = 0xFF;
    if (key_down(VK_ESCAPE) || key_down('X')) p.analog[1] = 0xFF;
    if (key_down('C')) p.analog[2] = 0xFF;
    if (key_down('V')) p.analog[3] = 0xFF;
    if (key_down('Q')) p.analog[4] = 0xFF;
    if (key_down('E')) p.analog[5] = 0xFF;
    if (key_down(VK_LSHIFT)) p.analog[6] = 0xFF;
    if (key_down(VK_RSHIFT)) p.analog[7] = 0xFF;
    if (key_down('D') || key_down(VK_RIGHT)) p.lx = 32767;
    else if (key_down('A') || key_down(VK_LEFT)) p.lx = -32768;
    if (key_down('W') || key_down(VK_UP)) p.ly = 32767;
    else if (key_down('S') || key_down(VK_DOWN)) p.ly = -32768;
}
#endif

}  // namespace

void Init() {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    // On iOS, SDL_Init conflicts with the UIKit main event loop and crashes on launch.
    // Virtual controls (SetVirtualControl / Poll) work entirely without SDL —
    // SDL is only needed for physical gamepad support on desktop/Windows.
    // Physical MFi/controller support can be added later via GameController.framework.
    LOGI("input: iOS mode — virtual controls only, SDL skipped");
    return;
#else
    // WGI reads the triggers apart and HIDAPI takes PlayStation and Switch pads. Reads come from the guest's threads,
    // so SDL's own thread takes the device notices.
    SDL_SetHint(SDL_HINT_JOYSTICK_THREAD, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_WGI, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_RAWINPUT, "0");
    SDL_SetHint(SDL_HINT_XINPUT_ENABLED, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_DIRECTINPUT, "0");
    if (!SDL_Init(SDL_INIT_GAMEPAD)) {
        LOGE("input: SDL failed to start, no controllers: %s", SDL_GetError());
        return;
    }
    int v = SDL_GetVersion();
    LOGI("input: SDL %d.%d.%d", SDL_VERSIONNUM_MAJOR(v), SDL_VERSIONNUM_MINOR(v), SDL_VERSIONNUM_MICRO(v));
    std::lock_guard lock(g_lock);
    g_sdl = true;
    int count = 0;
    if (SDL_JoystickID* ids = SDL_GetGamepads(&count)) {
        for (int i = 0; i < count; i++) AddPad(ids[i]);
        SDL_free(ids);
    }
#endif
}

void OnKey(uint32_t vk, bool down) {
#ifdef _WIN32
    if (vk < 256) g_key_state[vk].store(down, std::memory_order_relaxed);
#else
    (void)vk;
    (void)down;
#endif
}

void OnScancode(uint32_t scancode, bool down) {
    if (scancode < SDL_SCANCODE_COUNT) g_virtual_keys[scancode].store(down, std::memory_order_relaxed);
}

void SetVirtualControl(VirtualControl control, bool down) {
    const size_t index = static_cast<size_t>(control);
    if (index < static_cast<size_t>(VirtualControl::Count))
        g_virtual_controls[index].store(down, std::memory_order_relaxed);

#if defined(__APPLE__) && TARGET_OS_IPHONE
    // iOS input verification: log every button event to confirm touch overlay routing.
    // Remove or disable once input routing is verified end-to-end.
    static const char* kControlNames[] = {
        "DpadUp", "DpadDown", "DpadLeft", "DpadRight",
        "Confirm", "MenuBack", "Start",
        "FaceA", "FaceB", "FaceX", "FaceY",
        "ShoulderL", "ShoulderR",
        "Accelerate", "Brake", "SteerLeft", "SteerRight"
    };
    const char* name = index < std::size(kControlNames) ? kControlNames[index] : "Unknown";
    LOGD("input: SetVirtualControl %s %s", name, down ? "DOWN" : "UP");
#endif
}

Pad Poll(int port) {
    Pad p;
    {
        std::lock_guard lock(g_lock);
        UpdatePads();
        if (SDL_Gamepad* pad = port >= 0 && port < 4 ? g_pads[port] : nullptr) {
            p.connected = true;
            constexpr SDL_GamepadButton kButtons[] = {
                SDL_GAMEPAD_BUTTON_DPAD_UP,   SDL_GAMEPAD_BUTTON_DPAD_DOWN,  SDL_GAMEPAD_BUTTON_DPAD_LEFT,
                SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_START,     SDL_GAMEPAD_BUTTON_BACK,
                SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK};
            for (int i = 0; i < 8; i++) p.buttons |= uint16_t(SDL_GetGamepadButton(pad, kButtons[i]) << i);
            // A B X Y black white
            constexpr SDL_GamepadButton kAnalog[] = {SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST,
                                                     SDL_GAMEPAD_BUTTON_WEST,  SDL_GAMEPAD_BUTTON_NORTH,
                                                     SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER};
            for (int i = 0; i < 6; i++) p.analog[i] = SDL_GetGamepadButton(pad, kAnalog[i]) ? 0xFF : 0;
            auto axis = [&](SDL_GamepadAxis a) { return int(SDL_GetGamepadAxis(pad, a)); };
            // 0 to 32767 into 0 to 255
            p.analog[6] = uint8_t(std::max(axis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER), 0) >> 7);
            p.analog[7] = uint8_t(std::max(axis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER), 0) >> 7);
            // SDL's sticks have y down
            // not plain negation: -32768 has no positive
            p.lx = int16_t(axis(SDL_GAMEPAD_AXIS_LEFTX));
            p.ly = int16_t(-1 - axis(SDL_GAMEPAD_AXIS_LEFTY));
            p.rx = int16_t(axis(SDL_GAMEPAD_AXIS_RIGHTX));
            p.ry = int16_t(-1 - axis(SDL_GAMEPAD_AXIS_RIGHTY));
        } else if (port == 0) {
#if MC3_INPUT_HAS_SDL_KEYBOARD_FALLBACK
            // Keyboard fallback for development systems without a controller.
            const bool* key = SDL_GetKeyboardState(nullptr);
            p.connected = true;
            p.buttons |= uint16_t(key[SDL_SCANCODE_UP]) << 0;
            p.buttons |= uint16_t(key[SDL_SCANCODE_DOWN]) << 1;
            p.buttons |= uint16_t(key[SDL_SCANCODE_LEFT]) << 2;
            p.buttons |= uint16_t(key[SDL_SCANCODE_RIGHT]) << 3;
            p.buttons |= uint16_t(key[SDL_SCANCODE_SPACE]) << 4;
            p.buttons |= uint16_t(key[SDL_SCANCODE_BACKSPACE]) << 5;
            p.buttons |= uint16_t(key[SDL_SCANCODE_F]) << 6;
            p.analog[0] = (key[SDL_SCANCODE_RETURN] || key[SDL_SCANCODE_Z]) ? 0xFF : 0;
            p.analog[1] = (key[SDL_SCANCODE_ESCAPE] || key[SDL_SCANCODE_X]) ? 0xFF : 0;
            p.analog[2] = key[SDL_SCANCODE_C] ? 0xFF : 0;
            p.analog[3] = key[SDL_SCANCODE_V] ? 0xFF : 0;
            p.analog[4] = key[SDL_SCANCODE_Q] ? 0xFF : 0;
            p.analog[5] = key[SDL_SCANCODE_E] ? 0xFF : 0;
            p.analog[6] = key[SDL_SCANCODE_LSHIFT] ? 0xFF : 0;
            p.analog[7] = key[SDL_SCANCODE_RSHIFT] ? 0xFF : 0;
            p.lx = key[SDL_SCANCODE_D] ? 32767 : key[SDL_SCANCODE_A] ? -32768 : 0;
            p.ly = key[SDL_SCANCODE_W] ? 32767 : key[SDL_SCANCODE_S] ? -32768 : 0;
#endif
        }
        if (port == 0) {
            MergeVirtualControls(p);
#ifdef _WIN32
            // Keep the host keyboard usable when SDL has claimed port 0 for a physical or virtual pad.
            // MC3's title screen consumes events produced from XInputGetState, so writing its translated
            // button words later in the frame is insufficient for Start.
            MergeWindowsKeyboard(p);
            const uint32_t report = p.buttons | (uint32_t(p.analog[0]) << 16) | (uint32_t(p.analog[1]) << 24);
            static std::atomic<uint32_t> last_merged_report{~0u};
            const uint32_t old_report = last_merged_report.exchange(report);
            if (old_report != report)
                LOGE("input: merged report buttons=%04X A=%u B=%u", p.buttons, p.analog[0], p.analog[1]);
#endif
        }
    }
    if (app::kGame.pad) app::kGame.pad(port, p);
    return p;
}

// the motors run until set again
void Rumble(int port, uint16_t left, uint16_t right) {
    if (app::kGame.rumble) app::kGame.rumble(port, left, right);
    std::lock_guard lock(g_lock);
    if (port >= 0 && port < 4 && g_pads[port]) SDL_RumbleGamepad(g_pads[port], left, right, 0);
}

}  // namespace input
