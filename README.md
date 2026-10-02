v-deuce

virtual iPhone on Apple Silicon | fork of vphone-cli 2.x | iPhone Mirroring window over a PCC research VM

what it is
- vphone-cli 2.x firmware patcher, restore and VM control, kept in step with upstream https://github.com/Lakr233/vphone-cli
- app layer rebuilt to look and act like iPhone Mirroring | window, chrome, input, clipboard, installs
- one bundle, built as `VPhone.bundle`, installed and released as `v-deuce.bundle` | `vphone-cli` drives firmware and VMs | `vphone-vm` runs the guest window | `vphoned` inside the guest

added here
- window | 406x890 around a 390x844 panel, 48 pt continuous corners, size locked
- hover chrome | 38 pt top strip | free-standing 14 pt traffic lights | Home Screen and App Switcher buttons | 0.2 s fade
- keys | raw keyDown/keyUp/flagsChanged to the guest keyboard | ⌘1 ⌘H home | ⌘2 app switcher | ⌘3 spotlight
- view | Larger, Actual Size, Smaller | 390x844, 300x650, 196x425 panel as iPhone Mirroring | ⌘+ or ⌘= | ⌘0 | ⌘-
- app | named v-deuce | `AppIcon.icns` iPhone Mirroring icon with its front phone alone, set as the Dock tile at launch | View menu beside Edit | SF Symbol on every action item
- display | `./display <vm> --e` | 1170x2532 panel, notch, iPhone14,5 D17 identity | VM off, root for the Preboot mount | `--restore` puts the original DT back
- gestures | right-click is touch-and-hold | pinch and rotate on one finger pair | scroll wheel drives one finger | mouse back and forward swipe from the edges
- clipboard | host to guest on activate | guest to host on resign | newer host clipboard wins
- window tiling | a second guest opens beside the first
- file browser | filter field takes an absolute path and jumps to it

build
`xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build`
product `.build/XcodeBundle/Build/Products/Debug/VPhone.bundle` | `Contents/MacOS/` holds `vphone-cli` `vphone-vm` `vphone-escalator`
tests | same command, `-scheme VPhoneCoreKitTests test` | gesture and tiling suites live there
no Python | patchers are Swift under `VPhoneExecutable/VPhoneCommand/FirmwarePatcher`

run
`vphone-cli vm launch <name>` | `vphone-cli vm stop <name>`
`vphone-cli vm list` | `info` | `export` | `import` | `vphone-cli <group> --help` for the rest
data under `~/.vphone/` | VMs need `schemaVersion=2`, 1.x VMs must be recreated
API | `--api-listen 127.0.0.1:8765` | bearer token printed as `[api] token: …` or `VPHONE_API_TOKEN`

automation
`./vd` | shell client of `<VM>/vphone.sock` | coordinates in points, each action writes a 430x932 screen to `/tmp/vd.jpg`
`vd up` `down` `deploy` | `tap` `swipe` `key` `type` `look` | `ui` `front` `open` | `rpc` any vphoned method | `vd` alone prints usage
`vd deploy` Release build, replaces `/Applications/v-deuce.bundle`, links `vphone-cli` into it, reboots a running guest
`vd up --headless` no window | `look` falls back to the guest's own screenshot, drops the agent under heavy apps like Instagram
`vd tune` reduced motion and transparency, no background refresh, 30 daemons in `TUNE_OFF` off, locale `en_US`, host zone | rerun after a restore | `rpc services.enable` undoes one
`vd idle [MIN]` stops the guest after MIN min, default 30, with no `vd` call and no window focus | `~/Library/LaunchAgents/dev.sol.vd-idle.plist` runs it every 5 min

host
Apple Silicon | macOS 15+ | Xcode for source builds
`csrutil enable --without debug` and `csrutil allow-research-guests enable` in Recovery | or SIP off

docs map
- ISSUES.md open work and known limits in the app layer
- Research/ firmware pipeline, boot flow, per-patch breakdown in `0_binary_patch_comparison.md`, guest API in `vphoned_http_api.md`
- Documents/ upstream guides and translations, describe vphone-cli not this fork
- Skills/ kernel analysis procedure for `vphone600`

state
hover chrome matches iPhone Mirroring to about 1 px | light ring #6b against #67, drawn by AppKit
2.x port runs `v-deuce` | `schemaVersion=2` | iOS 26.1 23B85
`v-deuce` VM | 4 cores, 3 GB on an 8 GB M1 | Instagram fits | camera daemon off by `vd tune`
upstream taken to 2.2.5 | upstream history carries AI trailers, never merged as is
`./upstream` applies origin/main since local `refs/upstream/synced` as one commit `upstream <version>` | conflicts or AI-tool names stop it | `upstream --done` after resolving
Siri DeviceTree flags unported to the Swift patcher

gotchas
buttons, gestures and clipboard need vphoned connected
guest touch injection only below iOS 26 | iOS 26 takes VZ multitouch
tweaked IPAs that hook `__TEXT` die under the code signing monitor | not a signing fault
SpringBoard draws the island from the DT model identity, not the display properties | `display --e` retargets to iPhone14,5
MobileGestalt caches the identity | move `systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist` aside and reboot after a retarget
Launch Services draws a `BNDL` with the generic plug-in icon | Finder and `NSRunningApplication.icon` show it | the Dock tile is set in code
Japan or EU region at setup blocks system apps | pick United States
setup leaves locale `en_AI`, 24 h clock, foreign zone | `vd tune` sets `AppleLocale` `en_US`, links `/private/var/db/timezone/localtime` to the host zone, resprings
nested Mac VM cannot host | PV=3 needs bare metal
upstream is remote `origin` | pull, never reset | own remote `sol`, branch `deuce`
