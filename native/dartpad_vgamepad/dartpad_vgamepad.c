#include "dartpad_vgamepad.h"
#include <string.h>

// Note: On Windows, compile with USE_VIGEM=1 and link against ViGEmClient,
// or replace backend implementation with VHF (Virtual HID Framework) without
// changing the exported C ABI functions consumed by Dart FFI.

#if defined(_WIN32) && defined(USE_VIGEM)
#include <windows.h>
#include <ViGEm/Client.h>

static PVIGEM_CLIENT g_client = NULL;
static PVIGEM_TARGET g_target = NULL;
static int32_t g_device_type = DARTPAD_DEVICE_XBOX360;
static volatile uint8_t g_large_motor = 0;
static volatile uint8_t g_small_motor = 0;
static volatile int32_t g_rumble_dirty = 0;

static VOID CALLBACK on_x360_notification(
    PVIGEM_CLIENT Client,
    PVIGEM_TARGET Target,
    UCHAR LargeMotor,
    UCHAR SmallMotor,
    UCHAR LedNumber,
    LPVOID UserData) {
  (void)Client; (void)Target; (void)LedNumber; (void)UserData;
  g_large_motor = LargeMotor;
  g_small_motor = SmallMotor;
  g_rumble_dirty = 1;
}

static VOID CALLBACK on_ds4_notification(
    PVIGEM_CLIENT Client,
    PVIGEM_TARGET Target,
    UCHAR LargeMotor,
    UCHAR SmallMotor,
    DS4_LIGHTBAR_COLOR LightbarColor,
    LPVOID UserData) {
  (void)Client; (void)Target; (void)LightbarColor; (void)UserData;
  g_large_motor = LargeMotor;
  g_small_motor = SmallMotor;
  g_rumble_dirty = 1;
}

static USHORT map_xbox_buttons(uint32_t mask) {
  USHORT wButtons = 0;
  if (mask & (1u << 0))  wButtons |= XUSB_GAMEPAD_A;              // south
  if (mask & (1u << 1))  wButtons |= XUSB_GAMEPAD_B;              // east
  if (mask & (1u << 2))  wButtons |= XUSB_GAMEPAD_X;              // west
  if (mask & (1u << 3))  wButtons |= XUSB_GAMEPAD_Y;              // north
  if (mask & (1u << 4))  wButtons |= XUSB_GAMEPAD_LEFT_SHOULDER;  // leftShoulder
  if (mask & (1u << 5))  wButtons |= XUSB_GAMEPAD_RIGHT_SHOULDER; // rightShoulder
  if (mask & (1u << 8))  wButtons |= XUSB_GAMEPAD_DPAD_UP;        // dpadUp
  if (mask & (1u << 9))  wButtons |= XUSB_GAMEPAD_DPAD_DOWN;      // dpadDown
  if (mask & (1u << 10)) wButtons |= XUSB_GAMEPAD_DPAD_LEFT;      // dpadLeft
  if (mask & (1u << 11)) wButtons |= XUSB_GAMEPAD_DPAD_RIGHT;     // dpadRight
  if (mask & (1u << 12)) wButtons |= XUSB_GAMEPAD_START;          // start
  if (mask & (1u << 13)) wButtons |= XUSB_GAMEPAD_BACK;           // select
  if (mask & (1u << 14)) wButtons |= XUSB_GAMEPAD_GUIDE;          // guide
  if (mask & (1u << 15)) wButtons |= XUSB_GAMEPAD_LEFT_THUMB;     // leftStick
  if (mask & (1u << 16)) wButtons |= XUSB_GAMEPAD_RIGHT_THUMB;    // rightStick
  return wButtons;
}

DARTPAD_API int32_t dartpad_vgamepad_init(int32_t device_type) {
  if (g_client != NULL) {
    dartpad_vgamepad_destroy();
  }
  g_device_type = device_type;
  g_client = vigem_alloc();
  if (g_client == NULL) return -1;

  const VIGEM_ERROR ret = vigem_connect(g_client);
  if (!VIGEM_SUCCESS(ret)) {
    vigem_free(g_client);
    g_client = NULL;
    return -2;
  }

  g_target = (device_type == DARTPAD_DEVICE_DS4)
      ? vigem_target_ds4_alloc()
      : vigem_target_x360_alloc();

  const VIGEM_ERROR add_ret = vigem_target_add(g_client, g_target);
  if (!VIGEM_SUCCESS(add_ret)) {
    vigem_target_free(g_target);
    vigem_disconnect(g_client);
    vigem_free(g_client);
    g_target = NULL;
    g_client = NULL;
    return -3;
  }

  if (device_type == DARTPAD_DEVICE_DS4) {
    vigem_target_ds4_register_notification(g_client, g_target, &on_ds4_notification, NULL);
  } else {
    vigem_target_x360_register_notification(g_client, g_target, &on_x360_notification, NULL);
  }
  return 0;
}

DARTPAD_API int32_t dartpad_vgamepad_update(
    uint32_t buttons_bitmask,
    int16_t lx,
    int16_t ly,
    int16_t rx,
    int16_t ry,
    uint8_t lt,
    uint8_t rt) {
  if (g_client == NULL || g_target == NULL) return -1;

  if (g_device_type == DARTPAD_DEVICE_DS4) {
    DS4_REPORT ds4;
    DS4_REPORT_INIT(&ds4);
    if (buttons_bitmask & (1u << 0))  ds4.wButtons |= DS4_BUTTON_CROSS;
    if (buttons_bitmask & (1u << 1))  ds4.wButtons |= DS4_BUTTON_CIRCLE;
    if (buttons_bitmask & (1u << 2))  ds4.wButtons |= DS4_BUTTON_SQUARE;
    if (buttons_bitmask & (1u << 3))  ds4.wButtons |= DS4_BUTTON_TRIANGLE;
    if (buttons_bitmask & (1u << 4))  ds4.wButtons |= DS4_BUTTON_SHOULDER_LEFT;
    if (buttons_bitmask & (1u << 5))  ds4.wButtons |= DS4_BUTTON_SHOULDER_RIGHT;
    if (buttons_bitmask & (1u << 12)) ds4.wButtons |= DS4_BUTTON_OPTIONS;
    if (buttons_bitmask & (1u << 13)) ds4.wButtons |= DS4_BUTTON_SHARE;
    if (buttons_bitmask & (1u << 14)) ds4.bSpecial |= DS4_SPECIAL_BUTTON_PS;
    if (buttons_bitmask & (1u << 15)) ds4.wButtons |= DS4_BUTTON_THUMB_LEFT;
    if (buttons_bitmask & (1u << 16)) ds4.wButtons |= DS4_BUTTON_THUMB_RIGHT;

    ds4.bTriggerL = lt;
    ds4.bTriggerR = rt;
    ds4.bThumbLX = (BYTE)((lx + 32768) >> 8);
    ds4.bThumbLY = (BYTE)(255 - ((ly + 32768) >> 8));
    ds4.bThumbRX = (BYTE)((rx + 32768) >> 8);
    ds4.bThumbRY = (BYTE)(255 - ((ry + 32768) >> 8));

    const VIGEM_ERROR ret = vigem_target_ds4_update(g_client, g_target, ds4);
    return VIGEM_SUCCESS(ret) ? 0 : -2;
  }

  XUSB_REPORT report;
  ZeroMemory(&report, sizeof(XUSB_REPORT));
  report.wButtons = map_xbox_buttons(buttons_bitmask);
  report.bLeftTrigger = lt;
  report.bRightTrigger = rt;
  report.sThumbLX = lx;
  report.sThumbLY = ly;
  report.sThumbRX = rx;
  report.sThumbRY = ry;

  const VIGEM_ERROR ret = vigem_target_x360_update(g_client, g_target, report);
  return VIGEM_SUCCESS(ret) ? 0 : -2;
}

DARTPAD_API int32_t dartpad_vgamepad_reset(void) {
  return dartpad_vgamepad_update(0, 0, 0, 0, 0, 0, 0);
}

DARTPAD_API int32_t dartpad_vgamepad_poll_rumble(
    uint8_t* out_large_motor,
    uint8_t* out_small_motor) {
  if (out_large_motor) *out_large_motor = g_large_motor;
  if (out_small_motor) *out_small_motor = g_small_motor;
  if (g_rumble_dirty) {
    g_rumble_dirty = 0;
    return 1;
  }
  return 0;
}

DARTPAD_API void dartpad_vgamepad_destroy(void) {
  if (g_client != NULL && g_target != NULL) {
    vigem_target_remove(g_client, g_target);
    vigem_target_free(g_target);
    g_target = NULL;
  }
  if (g_client != NULL) {
    vigem_disconnect(g_client);
    vigem_free(g_client);
    g_client = NULL;
  }
}

#else
// Stub / Simulation implementation when built without Windows ViGEm SDK
static int32_t g_initialized = 0;

DARTPAD_API int32_t dartpad_vgamepad_init(int32_t device_type) {
  (void)device_type;
  g_initialized = 1;
  return 0;
}

DARTPAD_API int32_t dartpad_vgamepad_update(
    uint32_t buttons_bitmask,
    int16_t lx,
    int16_t ly,
    int16_t rx,
    int16_t ry,
    uint8_t lt,
    uint8_t rt) {
  if (!g_initialized) return -1;
  (void)buttons_bitmask;
  (void)lx; (void)ly; (void)rx; (void)ry;
  (void)lt; (void)rt;
  return 0;
}

DARTPAD_API int32_t dartpad_vgamepad_reset(void) {
  return dartpad_vgamepad_update(0, 0, 0, 0, 0, 0, 0);
}

DARTPAD_API int32_t dartpad_vgamepad_poll_rumble(
    uint8_t* out_large_motor,
    uint8_t* out_small_motor) {
  if (out_large_motor) *out_large_motor = 0;
  if (out_small_motor) *out_small_motor = 0;
  return 0;
}

DARTPAD_API void dartpad_vgamepad_destroy(void) {
  g_initialized = 0;
}
#endif
