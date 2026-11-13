#ifndef DARTPAD_VGAMEPAD_H
#define DARTPAD_VGAMEPAD_H

#include <stdint.h>

#ifdef _WIN32
  #ifdef DARTPAD_VGAMEPAD_EXPORTS
    #define DARTPAD_API __declspec(dllexport)
  #else
    #define DARTPAD_API __declspec(dllimport)
  #endif
#else
  #define DARTPAD_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Device type constants:
/// 0 = Xbox 360 Virtual Controller
/// 1 = DualShock 4 Virtual Controller
typedef enum {
  DARTPAD_DEVICE_XBOX360 = 0,
  DARTPAD_DEVICE_DS4 = 1
} DartPadDeviceType;

/// Initializes the virtual gamepad driver connection and spawns a virtual device.
/// Returns 0 on success, negative error code on failure.
DARTPAD_API int32_t dartpad_vgamepad_init(int32_t device_type);

/// Updates the virtual gamepad state.
/// - buttons_bitmask: bitmask matching DartPad GamepadButton enum
/// - lx, ly, rx, ry: signed 16-bit axis values (-32767 .. 32767)
/// - lt, rt: unsigned 8-bit trigger values (0 .. 255)
/// Returns 0 on success, negative error code on failure.
DARTPAD_API int32_t dartpad_vgamepad_update(
    uint32_t buttons_bitmask,
    int16_t lx,
    int16_t ly,
    int16_t rx,
    int16_t ry,
    uint8_t lt,
    uint8_t rt);

/// Resets all buttons and axes to neutral (0) immediately (used by Watchdog).
DARTPAD_API int32_t dartpad_vgamepad_reset(void);

/// Polls the latest Force Feedback / Rumble motor values requested by the PC game.
/// Writes `0..255` into `out_large_motor` and `out_small_motor`.
/// Returns `1` if a new rumble event arrived since the last poll, `0` if unchanged.
DARTPAD_API int32_t dartpad_vgamepad_poll_rumble(
    uint8_t* out_large_motor,
    uint8_t* out_small_motor);

/// Unplugs the virtual controller and releases driver resources.
DARTPAD_API void dartpad_vgamepad_destroy(void);

#ifdef __cplusplus
}
#endif

#endif // DARTPAD_VGAMEPAD_H
