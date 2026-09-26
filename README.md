v-deuce

virtual iPhone on Apple Silicon | fork of vphone-cli | iPhone Mirroring window over a PCC research VM

what it is
- vphone-cli boot chain, firmware patchers and CFW install, kept in step with upstream https://github.com/Lakr233/vphone-cli
- app layer rebuilt to look and act like iPhone Mirroring | window, chrome, input, clipboard, installs
- app `v-deuce.app` | bundle id `com.vphone.cli` | CLI `v-deuce`, same subcommands as `vphone-cli`

added here
- window | 406x890 around a 390x844 panel, 48 pt continuous corners, size locked
- hover chrome | 38 pt top strip | free-standing 14 pt traffic lights | Home Screen and App Switcher buttons | 0.2 s fade
- keys | raw keyDown/keyUp/flagsChanged to the guest keyboard | ⌘1 ⌘H home | ⌘2 app switcher | ⌘3 spotlight
- gestures | right-click is touch-and-hold | pinch and rotate on one finger pair | scroll wheel drives one finger | mouse back and forward swipe from the edges | side button gestures
- clipboard | host to guest on activate | guest to host on resign | newer host clipboard wins
- drag and drop | IPAs install | other files land in Files under On My iPhone
- ipa install | host `ldid` presigns | vphoned skips guest signing | Apps > Install IPA into LiveContainer
- window tiling | a second guest opens beside the first
- patchers | `cfw_patch_siri_dt.py` | `cfw_patch_display_dt.py` | `vm_patch_display.sh`
- render | `vm config --screen-divisor N` divides the 1290x2796 guest panel, point size unchanged

build
`make setup_tools` once | toolchain submodules, Python venv
`make bundle` | builds, restamps SDK 26 with `vtool`, signs with private entitlements, bundles `.build/v-deuce.app`
`cp -R .build/v-deuce.app /Applications/` | `/opt/homebrew/bin/v-deuce` links to the bundle executable
never bare `swift build` | unsigned binary dies at launch
`swift test` | gesture, tiling and IPA signer suites

run
`v-deuce vm create <name> -V jb` | download, patch, DFU restore, CFW install, first boot
`v-deuce vm launch <name>` | `v-deuce vm stop <name>` stops the guest cleanly over SIGINT
`v-deuce vm list` | `info` | `config` | `clone` | `export` | `import` | `rename` | `delete`
ssh `-p 22222` | `mobile@<vm-ip>` on jb, `root@<vm-ip>` on regular and dev | password `alpine`
vnc `vnc://<vm-ip>:5901`
data under `~/.vphone/` | `VMs/` `ipsws/` `tools/` `debs/` `venv/` | `$VPHONE_ROOT` moves the whole tree

variants
| variant | boot chain | CFW | adds |
| --- | --- | --- | --- |
| `less` | 4 | 2 | patchless, iOS mitigations on |
| `regular` | 42 | 10 | AMFI, SSV, Img4, TXM bypass |
| `dev` | 53 | 12 | TXM entitlement and debug bypass |
| `jb` | 113 | 14 | jailbreak, Sileo, TrollStore on first boot |
| `exp` | 141 | 18 | jb plus anti-VM-detection research patches |

host
Apple Silicon | macOS 15+ | Xcode with iOS SDK for vphoned
SIP off, `csrutil allow-research-guests enable`, `amfi_get_out_of_my_way=1` boot-arg | or SIP on without debug plus `vphone-amfidont`
`brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd`

docs map
- ISSUES.md open work and known limits in the app layer
- research/ firmware pipeline, boot flow, per-patch breakdown in `0_binary_patch_comparison.md`
- skills/ kernel analysis procedure for `vphone600`
- docs/ upstream translations, describe vphone-cli not this fork

state
hover chrome matches iPhone Mirroring to about 1 px | light ring #6b against #67, drawn by AppKit
pinch, rotate, scroll and right-click hold unverified on a live panel

gotchas
14 pt traffic lights need the SDK 26+ stamp | without `make bundle` AppKit draws legacy 12 pt lights and the whole app keeps the macOS 15 look
buttons, gestures and clipboard need vphoned connected over vsock 1337
tweaked IPAs that hook `__TEXT` die under the code signing monitor | not a signing fault
`ldid-procursus` up to `2.1.5-procursus7` hangs on an entitlement integer `0` | `brew install --HEAD ldid-procursus`
Japan or EU region at setup blocks system apps | pick United States
`EXC_GUARD` / `GUARD_TYPE_MACH_PORT` at app launch | re-patch with `--force-exc-guard`
nested Mac VM cannot host | PV=3 needs bare metal
upstream is remote `origin` | pull, never reset | own remote `sol`, branch `deuce`
