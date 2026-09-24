#import "vphoned_hid.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef double IOHIDFloat;

static IOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static IOHIDEventRef (*pKeyboard)(CFAllocatorRef, uint64_t,
                                  uint32_t, uint32_t, int, int);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

// Digitizer (touch) event symbols — resolved lazily; touch is a no-op if absent.
static IOHIDEventRef (*pDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                   uint32_t, uint32_t, uint32_t, IOHIDFloat,
                                   IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   boolean_t, boolean_t, uint32_t);
static IOHIDEventRef (*pFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int);

static IOHIDEventSystemClientRef gClient;
static dispatch_queue_t gHIDQueue;

// Digitizer event-mask bits and transducer types (IOHIDEventTypes.h).
#define VP_DIG_RANGE     0x00000001u
#define VP_DIG_TOUCH     0x00000002u
#define VP_DIG_POSITION  0x00000004u
#define VP_DIG_IDENTITY  0x00000020u
#define VP_TRANSDUCER_HAND   1
#define VP_TRANSDUCER_FINGER 2
// kIOHIDEventFieldDigitizerIsDisplayIntegrated: (kIOHIDEventTypeDigitizer<<16)|offset.
#define VP_FIELD_IS_DISPLAY_INTEGRATED ((((uint32_t)11) << 16) | 25)

BOOL vp_hid_load(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) { NSLog(@"vphoned: dlopen IOKit failed"); return NO; }

    pCreate    = dlsym(h, "IOHIDEventSystemClientCreate");
    pKeyboard  = dlsym(h, "IOHIDEventCreateKeyboardEvent");
    pSetSender = dlsym(h, "IOHIDEventSetSenderID");
    pDispatch  = dlsym(h, "IOHIDEventSystemClientDispatchEvent");

    pDigitizer = dlsym(h, "IOHIDEventCreateDigitizerEvent");
    pFinger    = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    pAppend    = dlsym(h, "IOHIDEventAppendEvent");
    pSetInt    = dlsym(h, "IOHIDEventSetIntegerValue");

    if (!pCreate || !pKeyboard || !pSetSender || !pDispatch) {
        NSLog(@"vphoned: missing IOKit symbols");
        return NO;
    }
    if (!pDigitizer || !pFinger || !pAppend || !pSetInt)
        NSLog(@"vphoned: digitizer symbols missing, touch injection disabled");

    gClient = pCreate(kCFAllocatorDefault);
    if (!gClient) { NSLog(@"vphoned: IOHIDEventSystemClientCreate returned NULL"); return NO; }

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    gHIDQueue = dispatch_queue_create("com.vphone.vphoned.hid", attr);

    NSLog(@"vphoned: IOKit loaded");
    return YES;
}

static void send_hid_event(IOHIDEventRef event) {
    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(event);
    dispatch_async(gHIDQueue, ^{
        pSetSender(strong, 0x8000000817319372);
        pDispatch(gClient, strong);
        CFRelease(strong);
    });
}

void vp_hid_press(uint32_t page, uint32_t usage) {
    IOHIDEventRef down = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                   page, usage, 1, 0);
    if (!down) return;
    send_hid_event(down);
    CFRelease(down);

    usleep(100000);

    IOHIDEventRef up = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                 page, usage, 0, 0);
    if (!up) return;
    send_hid_event(up);
    CFRelease(up);
}

void vp_hid_key(uint32_t page, uint32_t usage, BOOL down) {
    IOHIDEventRef ev = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                 page, usage, down ? 1 : 0, 0);
    if (ev) { send_hid_event(ev); CFRelease(ev); }
}

// Which digitizer fields a finger in this phase reports. A touch down or up
// changes the button state and so must carry TOUCH and IDENTITY; a move only
// reports a new position.
static uint32_t finger_mask(int phase) {
    return phase == 1 ? VP_DIG_POSITION : (VP_DIG_TOUCH | VP_DIG_IDENTITY);
}

static boolean_t finger_is_down(int phase) {
    return (phase == 0 || phase == 1) ? 1 : 0;
}

// Build a display-integrated hand digitizer event carrying `count` fingers and
// dispatch it. Mirrors WebKit's HIDEventGenerator touch path. The parent hand
// event carries the centroid and the union of the fingers' masks; it counts as
// in range and touching while any finger is still down.
static void dispatch_fingers(const vp_hid_finger_t *fingers, int count) {
    if (!pDigitizer || !pFinger || !pAppend || !pSetInt) return;
    if (!fingers || count < 1) return;

    double cx = 0, cy = 0;
    uint32_t mask = 0;
    boolean_t down = 0;
    for (int i = 0; i < count; i++) {
        cx += fingers[i].x;
        cy += fingers[i].y;
        mask |= finger_mask(fingers[i].phase);
        if (finger_is_down(fingers[i].phase)) down = 1;
    }
    cx /= count;
    cy /= count;

    uint64_t ts = mach_absolute_time();
    IOHIDEventRef parent = pDigitizer(kCFAllocatorDefault, ts, VP_TRANSDUCER_HAND,
                                      0, 0, mask, 0, cx, cy, 0, 0, 0, down, down, 0);
    if (!parent) return;
    pSetInt(parent, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);

    for (int i = 0; i < count; i++) {
        boolean_t fdown = finger_is_down(fingers[i].phase);
        IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts, i + 1, VP_TRANSDUCER_FINGER,
                                       finger_mask(fingers[i].phase),
                                       fingers[i].x, fingers[i].y, 0, 0, 0, fdown, fdown, 0);
        if (!finger) continue;
        pSetInt(finger, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);
        pAppend(parent, finger, 0);
        CFRelease(finger);
    }

    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(parent);
    dispatch_async(gHIDQueue, ^{
        pSetSender(strong, 0x8000000817319372);
        pDispatch(gClient, strong);
        CFRelease(strong);
    });
    CFRelease(parent);
}

void vp_hid_touch(int phase, double x, double y) {
    vp_hid_finger_t finger = { phase, x, y };
    dispatch_fingers(&finger, 1);
}

void vp_hid_touches(const vp_hid_finger_t *fingers, int count) {
    dispatch_fingers(fingers, count);
}
