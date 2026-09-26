issues

open work and known limits | v-deuce app layer only | firmware pipeline tracked upstream

hover chrome
iPhone Mirroring's top strip | close, minimize, zoom disabled at left | Home Screen and App Switcher at right | fades in on pointer over the 38 pt strip, out otherwise
`installHoverChrome` in `VPhoneWindowController` | free-standing traffic lights, backing and buttons at alpha 0, driven by `VPhoneHoverStrip`'s tracking area
no NSToolbar | a visible one raises `maxSize` by its own height, 890 becomes 898, and the size lock no longer holds
14 pt ringed lights need the binary stamped SDK 26+ | SwiftPM stamps the 15.0 deployment target | `make build` restamps with `vtool` | without it AppKit draws legacy 12 pt lights
corners fitted to the Mirroring window per row at 2x | panel 48 pt | chrome 19.75 pt top, 51.5 pt bottom | all `.continuous`
fit check | `screencapture -x -o -l <id>` both windows | compare per-row alpha edge down each corner | backing #353535, glyphs #adadad, rim #656565 over #4f4f4f as captured
Home Screen icon is a drawn 11 pt 3x3 grid | iPhone Mirroring's own `app.grid.3x3` is not a public symbol | App Switcher `iphone.app.switcher` is
both buttons go through `VPhoneKeyHelper` and need vphoned connected
window must not `orderOut`: last window ordered out counts as last window closed, `applicationShouldTerminateAfterLastWindowClosed` returns `!cli.noGraphics` and the guest dies with the app

status bar insets
guest status bar metrics still differ from a real 17e | cosmetic

render cost
`vm config --screen-divisor N` divides the guest panel from 1290x2796 | scale and PPI divide with it so UIKit keeps its point size and the guest still reads 6.1-inch
titlebar poll gone | `refreshTitle` runs from `control.onConnect` and `onDisconnect`, the only two points where `isConnected` and `guestIP` change
camera stream timer cancels on disconnect instead of ticking 30 Hz into a dead socket
Touch ID monitor seeds `isEnabled` from `touchIDForwardingDisabled` | a session with forwarding off no longer opens the biometrickitd XPC link to tear it down
`multiTouchDevice` resolved once | the VM's device set is fixed by its configuration, so a drag no longer bridges an `NSArray` through `Dynamic` per touch event
measured, closed: corner mask and transparent margins cost nothing | `WindowServer` holds 44-46% whether the guest renders or sits idle, so compositing the panel is not on the bill
measured: guest at rest is 0.0-0.2% of `v-deuce`, GPU unchanged | the whole display path shows up only under synthetic input flooding
`Dynamic` costs 10.3 us per call, 6.8 us with an `NSMethodSignature` cache in `vendor/Dynamic` | not applied: that submodule's only remote is upstream `mhdhejazi/Dynamic`, so the commit would leave the parent pointing at an unreachable SHA
no Dynamic call site runs hot enough for that to matter — keys, screenshots and touches are all per-gesture | revisit only if `vendor/Dynamic` stops being a submodule

host gestures
scroll wheel drives one finger | trackpad momentum dropped, the guest decelerates from the drag it saw | a notched wheel reports no end so a 150 ms idle lifts the finger
pinch and rotate share one pair of fingers | `VPhoneTwoFingerGesture` holds centre, span and angle so interleaved `magnify:` and `rotate:` stay one gesture | geometry covered by `TwoFingerGestureTests`
multi-finger on the guest path needs the `touches` cap | `vphoned` takes a `fingers` array, up to 8, identities are array order | a daemon without it drops pinch rather than degrading to a drag
touch cancel | window resign key and control disconnect lift whatever the guest still holds, so a drag ending outside the window no longer sticks a finger down
`mouseMoved` deliberately absent | a touchscreen has no hover, and a range-only digitizer event would put phantom touches under an idle pointer
right-click is touch-and-hold for context menus, as in iPhone Mirroring | finger held at least 0.6 s, past `UILongPressGestureRecognizer`'s 0.5 s | right-drag moves the held finger
home | ⌘1 and ⌘H | app switcher ⌘2 | spotlight ⌘3 | the VM view offers every Cmd chord to the main menu before the guest keyboard
mouse back and forward buttons swipe from the left and right edge
unverified on a booted guest | pinch, rotate, scroll and right-click hold all need a live panel to confirm the guest reads them

ipa install on a stock VM
guest signing needs an iOS `ldid` and none ships | procursus bootstrap has none under `/var/jb/usr/bin`
host signs first | `VPhoneIPASigner` runs the host `ldid` from `VPhoneResources.ldid`, uploads with `presigned`, `vphoned` skips `vp_sign_app`
entitlement rules mirror `vp_sign_app` in `vphoned_install.m` | keep the two in step
host without ldid falls back to guest signing, which fails with a message naming the missing ldid
host only presigns when the guest advertises the `presigned` cap | an older `vphoned` ignores the flag and would install an unsigned payload
signer covered by `IPASignerTests` | verified on the guest | YouTube, Spotify, SoundCloud launch from a vphone install

tweaked ipas die under the code signing monitor
`PokmonGO` (SpooferPro) is SIGKILLed ~1.5 s in | `CODESIGNING / Invalid Page`, `KERN_PROTECTION_FAILURE` in `UnityFramework.framework` `__TEXT`
not a signing fault | bundle and nested images carry a valid CMS signature, `ldid -h` on the guest matches the host cdhash, plain apps from the same installer run
the payload links ellekit and `libSpooferPro.dylib` inline-hooks Unity | `codeSigningMonitor 2` rejects the page the moment a hook rewrites it, same wall LiveContainer hits
no host-side fix | needs a kernel patch that drops monitor enforcement for a managed app, or a hooking method that never writes `__TEXT`
`jb.pmap_cs_custom_trust` on nested images does not help and makes AMFI log `has entitlements but is not a main binary` for every dylib | keep entitlements on bundle mains only

window tiling
second guest tiles beside the first instead of landing on top of it | each `vm launch` is its own process so placement is one-sided: the arriving window moves, windows already up never do
`VPhoneWindowTiling.origin` takes right of the occupied band, then left, then centre | `CGWindowListCopyWindowInfo` locates the other processes' windows, no Accessibility permission
inert under a tiling WM that owns placement | aerospace pins this window from `mirror-pin.sh` and its `on-window-detected` rule runs after the app has placed itself
unverified with two guests booted | geometry covered by `WindowTilingTests`

livecontainer
installed | `com.kdt.livecontainer` | `com.kdt.LiveContainer2` | `com.kdt.LiveContainer3` | no apps inside
JIT-less cert loaded in all three | runs normal apps | TXM kills code that rewrites its own `__TEXT`
open: wire `installIPA` in `VPhoneCLI.swift` into the vphone pill
Apps > Install IPA into LiveContainer | vphoned `lc_install` unpacks into `com.kdt.livecontainer` Documents/Applications, relaunches LC | LC signs on first run | unverified on the guest

done and verified
raw key forwarding | keyDown/keyUp/flagsChanged straight to the guest keyboard, shift and Cmd chords intact
guest-internal copy and paste | Cmd+A, Cmd+C, Cmd+V
clipboard follows focus | host to guest on activate, guest to host on resign, newer host clipboard wins
drag and drop | IPAs install, any other file lands in Files under On My iPhone
window geometry | 406x890 around a 390x844 body, matching iPhone Mirroring
