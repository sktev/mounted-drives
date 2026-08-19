#!/usr/bin/env python3
"""Enumerate eligible drives for the mounted.drives Omarchy shell plugin.

Emits one JSON object on stdout: {"drives": [...], "error": ""}.

Each drive entry:
{
  "name": "sda", "path": "/dev/sda", "size": "3.8G", "vendor": "Kingston", "model": "DT 101 II",
  "kind": "usb" | "cdrom" | "disk", "removable": true, "transport": "usb",
  "children": [
    { "name", "path", "size", "fstype", "label", "mountpoints": [...],
      "encrypted": false, "unlocked": false }
  ]
}

LUKS: partitions with fstype crypto_LUKS are reported with
encrypted: true / unlocked: false. When the container is open, lsblk
(util-linux >= 2.39) nests the crypt mapper under the backing partition, so
the unlocked mapper is found as the partition's type=="crypt" child;
unlocked: true is set along with mapperPath, the unlocked filesystem type,
and the live mountpoints collected from the mapper subtree.
"""

import argparse
import json
import re
import subprocess


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()


def root_disk_name():
    """Name (sda/nvme0n1) of the disk hosting /, or None."""
    src = run(["findmnt", "-n", "-o", "SOURCE", "/"])
    if not src.startswith("/dev/"):
        return None
    dev = src.split("[", 1)[0]  # strip btrfs subvol suffix like [/@]
    # Walk the inverse dependency chain to the top-level disk. This handles
    # LUKS mappers (PKNAME is empty for /dev/mapper/* devices) as well as
    # plain partitions. The last line of `lsblk -s` is the top disk.
    chain = run(["lsblk", "-s", "-no", "NAME", dev]).splitlines()
    names = [re.sub(r"^[\s└─├│]*", "", line) for line in chain]
    names = [n for n in names if n]
    return names[-1] if names else dev[len("/dev/"):]


def children_of(device):
    """Mountable/interesting leaves of a disk device."""
    children = []
    for c in device.get("children") or []:
        fstype = c.get("fstype") or ""
        # Skip non-filesystem partitions; crypto_LUKS is kept (locked, phase 1).
        if not fstype:
            continue
        children.append(leaf(c))
    # "Superfloppy" / filesystem directly on the disk, or optical media.
    if not children and device.get("fstype"):
        children.append(leaf(device))
    return children


def leaf(node):
    fstype = node.get("fstype") or ""
    base = {
        "name": node.get("name"),
        "path": node.get("path"),
        "size": node.get("size") or "",
        "fstype": fstype,
        "label": node.get("label") or "",
        "encrypted": fstype == "crypto_LUKS",
    }
    if not base["encrypted"]:
        base["mountpoints"] = [m for m in (node.get("mountpoints") or []) if m]
        base["unlocked"] = False
        return base

    # Locked by default. When the container is open, lsblk nests the crypt
    # mapper as a child of the backing partition.
    crypt = next(
        (c for c in (node.get("children") or []) if c.get("type") == "crypt"),
        None,
    )
    if crypt is None:
        base["mountpoints"] = []
        base["unlocked"] = False
        return base

    mountpoints = []

    def collect(n):
        mountpoints.extend(m for m in (n.get("mountpoints") or []) if m)
        for c in n.get("children") or []:
            collect(c)

    collect(crypt)
    base["mountpoints"] = mountpoints
    base["unlocked"] = True
    base["mapperPath"] = crypt.get("path") or ""
    base["unlockedFstype"] = crypt.get("fstype") or ""
    return base


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--include-internal", action="store_true")
    args = parser.parse_args()

    raw = run(["lsblk", "-J", "-o",
               "NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINTS,VENDOR,MODEL,TRAN,RM,HOTPLUG,TYPE"])
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": "lsblk parse failed: %s" % exc, "drives": []}))
        return

    root_disk = root_disk_name()
    drives = []

    for d in data.get("blockdevices", []):
        name = d.get("name") or ""
        if name == root_disk or name.startswith("zram") or d.get("type") == "loop":
            continue
        # Top-level dm-* devices are not shown; unlocked mappers are matched
        # through the nesting described in leaf() instead.
        if name.startswith("dm-"):
            continue

        transport = (d.get("tran") or "").lower()
        removable = d.get("rm") is True
        hotplug = d.get("hotplug") is True
        dtype = (d.get("type") or "").lower()

        eligible = transport == "usb" or removable or hotplug or dtype == "rom"
        if not eligible and args.include_internal:
            eligible = transport in ("sata", "nvme")
        if not eligible:
            continue

        kind = "cdrom" if dtype == "rom" else ("usb" if (transport == "usb" or removable) else "disk")
        drives.append({
            "name": name,
            "path": d.get("path"),
            "size": d.get("size") or "",
            "vendor": d.get("vendor") or "",
            "model": d.get("model") or "",
            "kind": kind,
            "removable": removable,
            "transport": transport,
            "children": children_of(d),
        })

    drives.sort(key=lambda x: (x["kind"] != "usb", x["name"]))
    print(json.dumps({"drives": drives}))


if __name__ == "__main__":
    main()
