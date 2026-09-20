#!/usr/bin/env python3
"""cfw_patch_siri_dt.py — turn on the /product Siri capability flags.

vphone600 ships the Siri-family capability properties under
`device-tree/product` as 12-byte `'syscfg/XXXX'` cstring placeholders.
Those resolve through syscfg on real hardware; the VM has no syscfg, so
`libMobileGestalt` answers NO and iOS reports Siri as unavailable. With
Siri unavailable CarPlay refuses to start a session, so a VM cannot be a
CarPlay source.

d47ap carries each of them as uint32 1 (verified against
`Firmware/all_flash/DeviceTree.d47ap.im4p` of
`iPhone17,3_26.1_23B85_Restore.ipsw`). This writes that value, shrinking
the property from 12 bytes to 4, which also clears the placeholder bit
in the length field.

Only the Siri family is touched. Rewriting `/product` wholesale breaks
screen rendering on the VM — the display pipeline reads capability
properties during init and picks a path the VM cannot service.

Usage:
    cfw_patch_siri_dt.py <devicetree.img4|im4p> [--dry-run] [--restore]

`--restore` puts the placeholders back, so Siri can be taken away again
without reinstalling the firmware.

Dependencies: pyimg4 (in requirements.txt).
"""

import sys

import pyimg4

from cfw_patch_post_restore_dt import (
    _get_node_name,
    _parse_node,
    _serialize_node,
)

# Property name -> syscfg placeholder the stock vphone600 DT ships.
SIRI_PROPERTIES = {
    "assistant": b"syscfg/assi",
    "dictation": b"syscfg/dict",
    "offline-dictation": b"syscfg/odct",
    "siri-gesture": b"syscfg/sige",
    "carplay-2": b"syscfg/car2",
}

ENABLED = (1).to_bytes(4, "little")


def _patch_dt_blob(dt_blob: bytes, restore: bool = False) -> bytes:
    root, end = _parse_node(dt_blob, 0)
    if end != len(dt_blob):
        raise ValueError(f"DT parse length mismatch: ended at {end}, blob is {len(dt_blob)}")

    product = next(
        (c for c in root.children if _get_node_name(c) == "product"), None
    )
    if product is None:
        raise ValueError("no 'product' node under the device-tree root")

    changed = []
    for prop in product.properties:
        placeholder = SIRI_PROPERTIES.get(prop.name)
        if placeholder is None:
            continue
        new_value = placeholder + b"\x00" if restore else ENABLED
        if prop.value == new_value:
            continue
        before = prop.value.hex()
        prop.value = new_value
        prop.length = len(new_value)
        changed.append(f"{prop.name}: {before} -> {new_value.hex()}")

    missing = SIRI_PROPERTIES.keys() - {p.name for p in product.properties}
    if missing:
        raise KeyError(f"/product is missing {sorted(missing)}")

    if not changed:
        return dt_blob
    for c in changed:
        print(f"  [+] {c}")
    return _serialize_node(root)


def patch_devicetree_file(path: str, *, dry_run: bool = False, restore: bool = False) -> int:
    with open(path, "rb") as f:
        data = f.read()

    try:
        img4 = pyimg4.IMG4(data)
        is_img4 = True
        im4p = img4.im4p
    except Exception:
        img4 = None
        is_img4 = False
        im4p = pyimg4.IM4P(data)

    if im4p.fourcc != "dtre":
        raise ValueError(f"{path}: expected fourcc='dtre', got {im4p.fourcc!r}")

    original_compression = im4p.payload.compression
    if original_compression != pyimg4.Compression.NONE:
        im4p.payload.decompress()
    dt_blob = bytes(im4p.payload.output().data)
    print(f"  [.] DT blob: {len(dt_blob)} bytes")

    new_dt = _patch_dt_blob(dt_blob, restore=restore)
    if new_dt == dt_blob:
        print(f"  [.] {path}: already in target state — no change")
        return 0

    new_payload = pyimg4.IM4PData(data=new_dt)
    if original_compression != pyimg4.Compression.NONE:
        new_payload.compress(original_compression)
    new_im4p = pyimg4.IM4P(
        fourcc=im4p.fourcc, description=im4p.description, payload=new_payload
    )
    out_bytes = (
        pyimg4.IMG4(im4p=new_im4p, im4m=img4.im4m, im4r=img4.im4r).output()
        if is_img4
        else new_im4p.output()
    )

    print(f"  [.] output size: {len(out_bytes)} bytes (was {len(data)})")
    if dry_run:
        print("  [.] dry-run — not writing back")
        return 0
    with open(path, "wb") as f:
        f.write(out_bytes)
    print(f"  [+] wrote {path}")
    return 1


def _main(argv):
    if len(argv) < 2:
        print(
            "Usage: cfw_patch_siri_dt.py <devicetree.img4|im4p> [--dry-run] [--restore]",
            file=sys.stderr,
        )
        return 2
    try:
        patch_devicetree_file(
            argv[1], dry_run="--dry-run" in argv[2:], restore="--restore" in argv[2:]
        )
    except Exception as e:
        print(f"[-] {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
