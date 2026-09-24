/*
 * vphoned_hid — HID event injection via IOKit private API.
 *
 * Matches TrollVNC's STHIDEventGenerator approach: create an
 * IOHIDEventSystemClient, fabricate keyboard events, and dispatch.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Load IOKit symbols and create HID event client. Returns NO on failure.
BOOL vp_hid_load(void);

/// Send a full key press (down + 100ms delay + up).
void vp_hid_press(uint32_t page, uint32_t usage);

/// Send a single key down or key up event.
void vp_hid_key(uint32_t page, uint32_t usage, BOOL down);

/// One finger of a digitizer event. x/y are normalized 0..1 with the origin at
/// the top-left. phase: 0 = down, 1 = move, 3 = up, 4 = cancel.
typedef struct {
    int phase;
    double x;
    double y;
} vp_hid_finger_t;

/// Inject a single-finger digitizer touch event. Used for iOS 18 bases where
/// the VZ USB touchscreen dext produces no digitizer events on the 26.x kernel.
void vp_hid_touch(int phase, double x, double y);

/// Inject a digitizer event carrying several fingers at once, for pinch and
/// rotate. Fingers take identities 1..count in the order given, so a gesture
/// must keep its order stable or the guest reads every event as new touches.
/// HID has no cancel, so phase 4 lifts the finger like phase 3.
void vp_hid_touches(const vp_hid_finger_t *fingers, int count);
