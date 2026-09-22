issues

open work and known limits | v-deuce app layer only | firmware pipeline tracked upstream

auto-hide toolbar strip
wanted: iPhone Mirroring's hover chrome in the 36 pt top strip | close, minimize, zoom disabled at left | app-switcher grid and split-view icons at right | appears on pointer over the strip, fades out otherwise
not started | an app-hide-on-deactivate build went in by mistake and is out again, sources and `mirror.sh` back to their earlier shape
window already reserves the strip: content 406x890 around a 390x844 panel, `vmView` at x 8 y 10
standard buttons exist under `.titled` + `.fullSizeContentView` and are `isHidden = true` in `VPhoneWindowController` | alpha on an NSTrackingArea over the strip is the route
window must not `orderOut`: last window ordered out counts as last window closed, `applicationShouldTerminateAfterLastWindowClosed` returns `!cli.noGraphics` and the guest dies with the app

status bar insets
guest status bar metrics still differ from a real 17e | cosmetic

guest probe leftovers
`MARK.txt` in `/var/mobile/Media/Downloads`, `/var/mobile/Downloads`, `/var/mobile/Documents` | root-owned, mode 666 | delete

livecontainer
installed | `com.kdt.livecontainer` | `com.kdt.LiveContainer2` | `com.kdt.LiveContainer3` | no apps inside
JIT-less cert loaded in all three | runs normal apps | TXM kills code that rewrites its own `__TEXT`
open: wire `installIPA` in `VPhoneCLI.swift` into the vphone pill

done and verified
raw key forwarding | keyDown/keyUp/flagsChanged straight to the guest keyboard, shift and Cmd chords intact
guest-internal copy and paste | Cmd+A, Cmd+C, Cmd+V
clipboard follows focus | host to guest on activate, guest to host on resign, newer host clipboard wins
drag and drop | IPAs install, any other file lands in Files under On My iPhone
window geometry | 406x890 around a 390x844 body, matching iPhone Mirroring
