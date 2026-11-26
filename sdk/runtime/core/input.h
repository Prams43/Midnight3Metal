#pragma once
#include <cstdint>

namespace input {

// the console controller's report, analog buttons are 0-255
struct Pad {
    bool connected = false;
    uint16_t buttons = 0;  // dpad up/down/left/right, start, back, left thumb, right thumb
    uint8_t analog[8] = {};  // A B X Y black white left trigger right trigger
    int16_t lx = 0, ly = 0, rx = 0, ry = 0;
};

void Init();  // window thread, before boot
// the controller on that port, then GameInfo::pad
Pad Poll(int port);
void Rumble(int port, uint16_t left, uint16_t right);
// Feed host key events (virtual-key codes on Windows). Kept for the Win32 window path.
void OnKey(uint32_t vk, bool down);
// Feed platform-neutral SDL scancodes, e.g. from an iOS touch-control frontend.
void OnScancode(uint32_t scancode, bool down);
// Platform-neutral controls. Confirm maps to the Xbox A button; MenuBack maps
// to Back, while Start maps to the report's documented Start bit.
// ShoulderL/ShoulderR map to White (L1) and Black (R1); TriggerL/TriggerR map
// to Left Trigger (L2) and Right Trigger (R2).
enum class VirtualControl : uint8_t {
    DpadUp, DpadDown, DpadLeft, DpadRight, Confirm, MenuBack, Start,
    FaceA, FaceB, FaceX, FaceY, ShoulderL, ShoulderR,
    TriggerL, TriggerR,
    Accelerate, Brake, SteerLeft, SteerRight, Count
};
// Set/release one held action; callers should pair each press with a release.
void SetVirtualControl(VirtualControl control, bool down);
// Set the virtual left analog stick axes in [-1.0, 1.0] (+x right, +y up).
void SetVirtualLeftStick(float x, float y);

}  // namespace input
