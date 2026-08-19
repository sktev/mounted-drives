// Parse list_drives.py output and expose display helpers.

function parseDrives(raw) {
  var data = { drives: [], error: "" }
  try {
    data = JSON.parse(raw)
  } catch (e) {
    return { drives: [], error: "Failed to parse drive list: " + e }
  }
  return {
    drives: (data && Array.isArray(data.drives)) ? data.drives : [],
    error: (data && data.error) || ""
  }
}

// Number of mounted filesystems across every connected drive.
function mountedCount(drives) {
  var count = 0
  for (var i = 0; i < drives.length; i++) {
    var children = drives[i].children || []
    for (var j = 0; j < children.length; j++) {
      if (children[j].mountpoints && children[j].mountpoints.length > 0) count++
    }
  }
  return count
}

// Human label for a disk: full vendor+model, falling back to label/name.
function diskTitle(disk) {
  var vendor = (disk.vendor || "").trim()
  var model = (disk.model || "").trim()
  if (vendor && model) return vendor + " " + model
  if (model) return model
  if (disk.label) return disk.label
  return disk.name.toUpperCase()
}

// Compact single-partition rows: full model + the partition label.
function compactTitle(disk) {
  var child = (disk.children && disk.children[0]) || {}
  var base = diskTitle(disk)
  if (child.label) return base + " (" + child.label + ")"
  return base
}

function kindIcon(kind) {
  if (kind === "usb") return ""        // fa-usb
  if (kind === "cdrom") return "\u{F05EE}"   // mdi-disc (cd-rom)
  return "\u{F02CA}"                         // mdi-harddisk (generic disk/nvme)
}

function kindLabel(kind) {
  if (kind === "usb") return "USB"
  if (kind === "cdrom") return "CD-ROM"
  return "Disk"
}

// Caption for a partition leaf: the live mountpoint when mounted, the
// unlock state for LUKS, otherwise size · fstype · not mounted.
function leafCaption(leaf) {
  if (leaf.mountpoints && leaf.mountpoints.length > 0) return leaf.mountpoints[0]
  if (leaf.encrypted && leaf.unlocked)
    return leaf.size + " · unlocked (" + (leaf.unlockedFstype || "crypto") + ") · not mounted"
  if (leaf.encrypted) return leaf.size + " · LUKS · locked"
  return leaf.size + " · " + leaf.fstype + " · not mounted"
}
