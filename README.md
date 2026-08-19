# Mounted Drives

Omarchy shell bar widget: shows connected external drives (USB, CD-ROM, hotplug, and optionally secondary internal NVMe/SATA disks) and lets you mount, unmount, eject, and open them from the bar.

The icon is hidden unless at least one eligible drive is connected (`alwaysShow: false`). The bar icon reflects what is connected: USB → usb, optical → disc, anything else → harddisk.

## Usage

- Left-click: open/close the popup
- Middle-click: refresh the drive list
- Popup: Mount / Unmount per partition, folder button opens the mountpoint, eject button (⏏) safely removes the whole disk
- LUKS partitions: locked rows show a passphrase field — Unlock opens the container and mounts it (Enter submits); unlocked rows get the normal mount/open actions plus a lock button () to close the container. Ejecting a disk with an open container unmounts and closes it first.
- Popup toggle "Show internal drives": include internal non-system disks (secondary NVMe/SATA). Off by default, persisted in `shell.json`.
- Keys: `r` refresh, `esc` close

## Settings (inline in `~/.config/omarchy/shell.json`)

| Key | Default | Meaning |
|---|---|---|
| `pollIntervalSec` | 8 | fallback `lsblk` poll interval (5–300) |
| `includeInternal` | false | also show internal non-system NVMe/SATA disks (popup toggle) |
| `alwaysShow` | false | keep the icon visible with no drive connected |

## How it works

- `scripts/list_drives.py` runs `lsblk -J` and filters to eligible disks, excluding the root disk, loop/zram/dm-* devices. It emits one JSON object per poll.
- Mounting/unmounting/ejecting runs `udisksctl` (no sudo needed for the active session). Errors are shown in the popup row.
- Hotplug detection is event-driven: `udevadm monitor` watches kernel block events and refreshes within ~0.5s of a drive appearing/disappearing (the same mechanism Nautilus uses). The timer poll is only a fallback, and the widget still fast-polls (2s) while the popup is open.

## LUKS support

LUKS partitions are reported with their container state:

```json
{ "name": "sdb1", "fstype": "crypto_LUKS", "encrypted": true, "unlocked": false }
```

When the container is open, lsblk (util-linux ≥ 2.39) nests the crypt mapper under its backing partition, so `list_drives.py` finds it as the partition's `type == "crypt"` child and reports `unlocked: true`, the mapper path, the unlocked filesystem type, and the live mountpoints.

In the panel:

- **Locked rows** show a passphrase field. Unlock passes the passphrase to `udisksctl unlock -b <dev> --key-file <tmp>` — udisksctl reads keys only from a file, never stdin, so the passphrase is staged as a 0600 file in the RAM-backed runtime dir and removed by a trap immediately after (it travels as an argv element and never touches persistent storage). The filesystem is mounted right after. A wrong passphrase shows udisks' error in the row.
- **Unlocked rows** behave like normal partitions (mount/unmount/open) plus a lock button that unmounts and runs `udisksctl lock -b <dev>`.

udisks gotcha: mount/unmount refuse the LUKS *backing* partition with "is not a mountable filesystem" — both directions. So filesystem operations on an unlocked container target the cleartext mapper instead: after unlock the mapper is parsed from udisksctl's stdout ("Unlocked /dev/sdb1 as /dev/dm-0."), and already-unlocked rows use the mapper path lsblk reports. Only `lock` talks to the backing partition. Eject unmounts the mapper, then locks the container, before powering the disk down.

The passphrase field takes over the panel keyboard while focused (the same `PanelKeyCatcher.blocked` pattern the wifi panel uses), so `r`/`esc` and the cursor keys stay out of the way until the field loses focus.
