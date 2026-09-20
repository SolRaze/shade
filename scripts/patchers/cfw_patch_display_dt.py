#!/usr/bin/env python3
"""cfw_patch_display_dt.py — post-restore display identity rewrite.

Rewrites the two device-tree properties that decide which handset the guest
draws its status bar and home indicator for:

    product/artwork-device-subtype   2556  ->  <subtype>
    product/island-notch-location     144  ->  <notch>

`artwork-device-subtype` is the panel height in pixels; SpringBoard keys its
device artwork off it. `island-notch-location` is the Dynamic Island's
horizontal origin; 0 means the panel has no island, which is what a notched
device (iPhone 16e/17e, 2532) reports.

Runs on the host against the restored filesystem, like
cfw_patch_post_restore_dt.py: the img4 is signature-checked by iBoot's
image4_validate_property_callback, which the boot-chain patches already
bypass, so an offline re-pack boots.

Usage:
    cfw_patch_display_dt.py <devicetree.img4> [--subtype N] [--notch N] [--dry-run]

Idempotent: a second run on an already-patched img4 reports no change.
"""

import argparse
import sys

import pyimg4

from cfw_patch_post_restore_dt import (
    _find_property,
    _get_node_name,
    _parse_node,
    _serialize_node,
)


def _patch_dt_blob(dt_blob: bytes, subtype: int, notch: int, drop_notch: bool = False) -> bytes:
    root, end = _parse_node(dt_blob, 0)
    if end != len(dt_blob):
        raise ValueError(f"DT parse length mismatch: ended at {end}, blob is {len(dt_blob)}")
    if _get_node_name(root) != "device-tree":
        raise ValueError(f"expected root node 'device-tree', got {_get_node_name(root)!r}")

    product = next(
        (c for c in root.children if _get_node_name(c) == "product"),
        None,
    )
    if product is None:
        raise ValueError("no 'product' node in device tree")

    changed = []
    if drop_notch:
        # Renaming the property hides it from the guest's by-name lookups, which
        # is the only way to "delete" it: every slot's length is fixed, so the
        # blob has to keep its size.
        for prop in product.properties:
            if prop.name == "island-notch-location":
                prop.name = "island-notch-location-off"
                changed.append("island-notch-location: renamed out of lookup")
        prop = _find_property(product, "artwork-device-subtype")
        new_val = subtype.to_bytes(prop.length, "little")
        if prop.value != new_val:
            changed.append(f"artwork-device-subtype: {int.from_bytes(prop.value, 'little')} -> {subtype}")
            prop.value = new_val
        if not changed:
            return dt_blob
        for c in changed:
            print(f"  [+] {c}")
        return _serialize_node(root)

    for name, value in (("artwork-device-subtype", subtype), ("island-notch-location", notch)):
        prop = _find_property(product, name)
        new_val = value.to_bytes(prop.length, "little")
        if prop.value != new_val:
            before = int.from_bytes(prop.value, "little")
            prop.value = new_val
            changed.append(f"{name}: {before} -> {value}")

    if not changed:
        return dt_blob
    for c in changed:
        print(f"  [+] {c}")
    return _serialize_node(root)


def patch_devicetree_file(
    path: str, subtype: int, notch: int, dry_run: bool = False, drop_notch: bool = False
) -> int:
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
        raise ValueError(f"{path}: expected DT payload (fourcc='dtre'), got {im4p.fourcc!r}")

    compression = im4p.payload.compression
    if compression != pyimg4.Compression.NONE:
        im4p.payload.decompress()
    dt_blob = bytes(im4p.payload.output().data)

    new_dt = _patch_dt_blob(dt_blob, subtype, notch, drop_notch)
    if new_dt == dt_blob:
        print(f"  [.] {path}: DT already in target state — no change")
        return 0
    if len(new_dt) != len(dt_blob):
        raise RuntimeError(f"DT size changed: {len(dt_blob)} -> {len(new_dt)} bytes")

    new_payload = pyimg4.IM4PData(data=new_dt)
    if compression != pyimg4.Compression.NONE:
        new_payload.compress(compression)
    new_im4p = pyimg4.IM4P(
        fourcc=im4p.fourcc, description=im4p.description, payload=new_payload
    )
    out_bytes = (
        pyimg4.IMG4(im4p=new_im4p, im4m=img4.im4m, im4r=img4.im4r).output()
        if is_img4
        else new_im4p.output()
    )

    if dry_run:
        print("  [.] dry-run — not writing back")
        return 1
    with open(path, "wb") as f:
        f.write(out_bytes)
    print(f"  [+] wrote {path} ({len(out_bytes)} bytes)")
    return 1


def dump_product_node(path: str) -> None:
    with open(path, "rb") as f:
        data = f.read()
    try:
        im4p = pyimg4.IMG4(data).im4p
    except Exception:
        im4p = pyimg4.IM4P(data)
    if im4p.payload.compression != pyimg4.Compression.NONE:
        im4p.payload.decompress()
    root, _ = _parse_node(bytes(im4p.payload.output().data), 0)
    product = next(c for c in root.children if _get_node_name(c) == "product")
    for prop in product.properties:
        if len(prop.value) == 4:
            shown = f"{int.from_bytes(prop.value, 'little')} ({prop.value.hex()})"
        else:
            shown = prop.value[:48].hex()
            text = prop.value.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            if text.isprintable() and text:
                shown = f"{text!r} {shown}"
        print(f"  {prop.name:<40} len={prop.length:<4} {shown}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path")
    ap.add_argument("--subtype", type=int, default=2532, help="panel height (default 2532)")
    ap.add_argument("--notch", type=int, default=0, help="island origin, 0 = notch (default 0)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--dump", action="store_true", help="print the product node and exit")
    ap.add_argument(
        "--drop-notch",
        action="store_true",
        help="rename island-notch-location so the guest cannot find it",
    )
    args = ap.parse_args()
    if args.dump:
        dump_product_node(args.path)
        return 0
    patch_devicetree_file(args.path, args.subtype, args.notch, args.dry_run, args.drop_notch)
    return 0


if __name__ == "__main__":
    sys.exit(main())
