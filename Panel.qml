import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.sktev.mounted-drives"
  ipcTarget: "io.github.sktev.mounted-drives"

  property var drives: []
  property string errorText: ""
  property string busyDev: ""
  property string busyOp: ""
  property var actionError: ({ dev: "", msg: "" })
  // True while a passphrase field has focus; the panel key catcher steps
  // aside so the field owns the keys (the same pattern as wifi's prompt).
  property bool inputActive: false
  property int unlockTick: 0

  readonly property int mountedCount: Model.mountedCount(root.drives)
  readonly property bool includeInternal: root.setting("includeInternal", false) === true
  // Bar icon reflects what is connected; usb > cdrom > disk.
  readonly property string barIcon: {
    var hasUsb = false, hasCd = false
    for (var i = 0; i < root.drives.length; i++) {
      var k = root.drives[i].kind
      if (k === "usb") hasUsb = true
      else if (k === "cdrom") hasCd = true
    }
    if (hasUsb) return Model.kindIcon("usb")
    if (hasCd) return Model.kindIcon("cdrom")
    return Model.kindIcon("disk")
  }
  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property color err: "#f87171"
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : "JetBrainsMono Nerd Font"

  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0)
      return decodeURIComponent(value.substring(7))
    return value
  }

  function refresh() {
    if (scannerProc.running) return
    var cmd = ["python3", pathFromUrl(Qt.resolvedUrl("scripts/list_drives.py"))]
    if (root.includeInternal) cmd.push("--include-internal")
    scannerProc.command = cmd
    scannerProc.running = true
  }

  function setIncludeInternal(value) {
    var next = {}
    for (var k in settings) if (settings.hasOwnProperty(k)) next[k] = settings[k]
    next.includeInternal = value === true
    root.settings = next
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") {
      bar.shell.updateEntryInline(root.moduleName, next)
    }
    root.refresh()
  }

  function updateDrives(raw) {
    var parsed = Model.parseDrives(raw)
    drives = parsed.drives
    errorText = parsed.error
  }

  function busyFor(dev) { return root.busyDev === dev }

  // Like runAction, but the caller supplies a ready-made shell script line.
  // Device paths come from lsblk, not user input, so quoting is safe here.
  function runScript(dev, op, script) {
    if (root.busyDev !== "") return
    root.busyDev = dev
    root.busyOp = op
    root.actionError = { dev: "", msg: "" }
    actionProc.command = ["bash", "-c", script]
    actionProc.running = true
  }

  function runAction(dev, op, parts) {
    if (root.busyDev !== "") return
    var str = ""
    for (var i = 0; i < parts.length; i++) str += Util.shellQuote(parts[i]) + " "
    root.busyDev = dev
    root.busyOp = op
    root.actionError = { dev: "", msg: "" }
    actionProc.command = ["bash", "-c", str]
    actionProc.running = true
  }

  // Filesystem ops on an unlocked LUKS leaf must target the cleartext
  // mapper: udisks refuses the backing partition ("is not a mountable
  // filesystem") in both directions. Only lock talks to the backing
  // partition. busyDev/errors keep using leaf.path so rows match up.
  function fsPath(leaf) {
    if (leaf.encrypted && leaf.unlocked && leaf.mapperPath) return leaf.mapperPath
    return leaf.path
  }
  function mountDevice(leaf) { runAction(leaf.path, "mount", ["udisksctl", "mount", "-b", fsPath(leaf)]) }
  function unmountDevice(leaf) { runAction(leaf.path, "unmount", ["udisksctl", "unmount", "-b", fsPath(leaf)]) }

  // Unlock a LUKS partition. udisksctl only reads the key from a real file
  // (no stdin, no tty here), so the passphrase is staged as a 0600 file in
  // the RAM-backed runtime dir and removed immediately via trap — it never
  // touches persistent storage. The passphrase rides stdin (actionProc
  // writes it on start), never argv and never shell interpolation:
  // /proc/<pid>/cmdline is readable by same-user processes. udisksctl
  // reports the mapper on stdout ("Unlocked /dev/sdb1 as /dev/dm-0.") —
  // mount THAT, since mounting the backing partition is refused even
  // after unlock.
  function unlockDevice(leaf, passphrase) {
    if (root.busyDev !== "") return
    root.busyDev = leaf.path
    root.busyOp = "unlock"
    root.actionError = { dev: "", msg: "" }
    var script = 'keyfile="${XDG_RUNTIME_DIR:-/dev/shm}/mounted.drives.$$.key"'
      + '; IFS= read -r pass'
      + '; umask 077; printf %s "$pass" > "$keyfile"'
      + '; trap \'rm -f "$keyfile"\' EXIT'
      + '; out=$(udisksctl unlock -b ' + leaf.path + ' --key-file "$keyfile")'
      + ' && mapper=$(printf %s "$out" | sed -n "s/.* as //; s/[. ]*$//p")'
      + ' && [ -n "$mapper" ] && udisksctl mount -b "$mapper"'
    actionProc.stdinSecret = passphrase
    actionProc.command = ["bash", "-c", script]
    actionProc.running = true
  }

  // Close an open LUKS container, unmounting its filesystem first.
  function lockDevice(leaf) {
    if (leaf.mountpoints && leaf.mountpoints.length > 0)
      runScript(leaf.path, "lock", "udisksctl unmount -b " + fsPath(leaf) + " && udisksctl lock -b " + leaf.path)
    else
      runAction(leaf.path, "lock", ["udisksctl", "lock", "-b", leaf.path])
  }

  // Safely remove: unmount every mounted partition first, then power the
  // disk down (or open the optical tray). The chain stops at the first
  // failure, so the error message names the partition that refused.
  function ejectDisk(disk) {
    var script = ""
    var children = disk.children || []
    for (var i = 0; i < children.length; i++) {
      var c = children[i]
      if (c.encrypted && c.unlocked) {
        // Open containers hold the backing partition: unmount the cleartext
        // mapper, then close the container.
        if (c.mountpoints && c.mountpoints.length > 0)
          script += "udisksctl unmount -b " + fsPath(c) + " && "
        script += "udisksctl lock -b " + c.path + " && "
      } else if (!c.encrypted && c.mountpoints && c.mountpoints.length > 0) {
        script += "udisksctl unmount -b " + c.path + " && "
      }
    }
    if (disk.kind === "cdrom") script += "eject " + disk.path
    else script += "udisksctl power-off -b " + disk.path
    runScript(disk.path, "eject", script)
  }
  function openMountpoint(path) {
    if (!path) return
    openProc.command = ["xdg-open", path]
    openProc.running = true
  }

  function triggerPress(button) {
    if (button === Qt.MiddleButton) { refresh(); return }
    if (opened) close()
    else { open(); refresh() }
  }

  onOpenedChanged: { if (opened) refresh() }

  visible: root.drives.length > 0 || root.setting("alwaysShow", false) === true
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Process {
    id: scannerProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateDrives(text)
    }
  }

  Process {
    id: actionProc
    command: []
    // LUKS passphrases ride stdin, never argv: /proc/<pid>/cmdline is
    // readable by same-user processes. write() fires once the process
    // starts; the unlock script consumes it with `IFS= read -r`.
    property string stdinSecret: ""
    stdinEnabled: true
    onStarted: {
      if (stdinSecret !== "") {
        write(stdinSecret + "\n")
        stdinSecret = ""
      }
    }
    // udisksctl prints success messages ("Unmounted /dev/sda1.") to stdout —
    // that's not an error, so stdout is ignored and only stderr is shown.
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // GLib prints a "no controlling terminal" warning on stderr when
        // stdin is a pipe (the unlock passphrase). Drop that noise and
        // keep only real error lines.
        var msg = (text || "").split("\n").filter(function(line) {
          return line.indexOf("** (udisksctl") !== 0 && line.trim() !== ""
        }).join("\n")
        if (msg !== "") root.actionError = { dev: root.busyDev, msg: msg }
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        // Success: drop any stderr chatter that isn't a failure.
        root.actionError = { dev: "", msg: "" }
        // The focused passphrase field clears itself on this tick.
        if (root.busyOp === "unlock") root.unlockTick++
      } else if (root.actionError.dev !== root.busyDev) {
        root.actionError = { dev: root.busyDev, msg: "Command failed (exit " + exitCode + ")" }
      }
      root.busyDev = ""
      root.busyOp = ""
      root.refresh()
    }
  }

  Process {
    id: openProc
    command: []
  }

  // Hotplug: kernel block events drive the refresh (the way Nautilus does
  // via udev), so a newly inserted drive appears almost instantly. The
  // debounce coalesces the burst of events a single insert produces.
  Process {
    id: udevProc
    command: ["udevadm", "monitor", "--kernel", "--subsystem-match=block", "--property"]
    running: true
    stdout: StdioCollector {
      onDataChanged: udevDebounce.restart()
    }
  }

  Timer {
    id: udevDebounce
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  // Fallback poll in case a udev event is missed.
  Timer {
    interval: Math.max(5, Number(root.setting("pollIntervalSec", 8))) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: fastPoll
    interval: 2000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    tooltipText: {
      var parts = []
      for (var i = 0; i < root.drives.length; i++) parts.push(Model.htmlEscape(Model.diskTitle(root.drives[i])))
      if (parts.length === 0) return ""
      if (root.mountedCount > 0) parts.push(root.mountedCount + " mounted")
      return parts.join(" · ")
    }
    onPressed: function(b) { root.triggerPress(b) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a passphrase field has focus it owns the keys.
      blocked: root.inputActive
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          Text {
            text: root.mountedCount > 0
              ? "Drives (" + root.mountedCount + " mounted)"
              : "Drives"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
          }

          Text {
            text: "Internal drives"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Layout.alignment: Qt.AlignVCenter
          }

          ToggleSwitch {
            checked: root.includeInternal
            foreground: root.fg
            accent: Color.accent
            Layout.alignment: Qt.AlignVCenter
            onToggled: root.setIncludeInternal(!checked)
          }

          Button {
            text: ""
            tooltipText: "Refresh Devices"
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.refresh()
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.fg
        }

        Repeater {
          model: root.drives

          delegate: BorderSurface {
            id: diskCard
            required property var modelData
            Layout.fillWidth: true
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.055)
            borderSpec: Border.flat(Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08), 1)
            radius: Style.cornerRadius
            padding: Style.space(10)

            // Drives with a single partition collapse to one row; only
            // multi-partition (or empty) disks use the grouped card below.
            readonly property bool compact: modelData.children.length === 1
            implicitHeight: (diskCard.compact ? compactRow.implicitHeight : diskColumn.implicitHeight)
              + contentTopInset + contentBottomInset

            RowLayout {
              id: compactRow
              anchors.fill: parent
              visible: diskCard.compact
              spacing: Style.space(8)

              readonly property var child: modelData.children[0]

              Text {
                text: Model.kindIcon(modelData.kind)
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                spacing: 1
                Layout.fillWidth: true

                Text {
                  text: Model.compactTitle(modelData)
                  textFormat: Text.PlainText
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  text: Model.leafCaption(compactRow.child)
                  textFormat: Text.PlainText
                  color: compactRow.child.mountpoints.length > 0 ? root.dim : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: root.actionError.dev === compactRow.child.path
                    || root.actionError.dev === modelData.path
                  text: root.actionError.msg
                  textFormat: Text.PlainText
                  color: root.err
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  Layout.fillWidth: true
                }

                RowLayout {
                  visible: compactRow.child.encrypted && !compactRow.child.unlocked
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  TextField {
                    id: compactPass
                    Layout.fillWidth: true
                    password: true
                    placeholderText: "Passphrase"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    horizontalPadding: Style.spacing.controlGap
                    verticalPadding: Style.spacing.controlPaddingY
                    onActiveFocusChanged: root.inputActive = activeFocus
                    onAccepted: compactUnlock.clicked()
                    Keys.onEscapePressed: root.close()
                  }

                  Button {
                    id: compactUnlock
                    visible: !root.busyFor(compactRow.child.path)
                      && !root.busyFor(modelData.path)
                    text: "Unlock"
                    active: true
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    onClicked: {
                      if (compactPass.text === "") return
                      root.unlockDevice(compactRow.child, compactPass.text)
                    }
                  }
                }
              }

              Text {
                visible: root.busyFor(compactRow.child.path) || root.busyFor(modelData.path)
                text: ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.alignment: Qt.AlignVCenter
              }

              Button {
                visible: (!compactRow.child.encrypted || compactRow.child.unlocked)
                  && compactRow.child.mountpoints.length > 0
                  && !root.busyFor(compactRow.child.path)
                  && !root.busyFor(modelData.path)
                text: ""
                tooltipText: "Open " + Model.htmlEscape(compactRow.child.mountpoints[0])
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.openMountpoint(compactRow.child.mountpoints[0])
              }

              Button {
                visible: (!compactRow.child.encrypted || compactRow.child.unlocked)
                  && !root.busyFor(compactRow.child.path)
                  && !root.busyFor(modelData.path)
                text: compactRow.child.mountpoints.length > 0 ? "Unmount" : "Mount"
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                active: true
                onClicked: compactRow.child.mountpoints.length > 0
                  ? root.unmountDevice(compactRow.child)
                  : root.mountDevice(compactRow.child)
              }

              Button {
                visible: compactRow.child.encrypted && compactRow.child.unlocked
                  && !root.busyFor(compactRow.child.path)
                  && !root.busyFor(modelData.path)
                text: ""
                tooltipText: "Lock " + Model.htmlEscape(compactRow.child.name)
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.lockDevice(compactRow.child)
              }

              Button {
                visible: (modelData.kind === "usb" || modelData.kind === "cdrom")
                  && !root.busyFor(modelData.path)
                text: ""
                tooltipText: "Safely remove " + Model.htmlEscape(modelData.name)
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.ejectDisk(modelData)
              }
            }

            Connections {
              target: root
              function onUnlockTickChanged() {
                if (root.busyDev === compactRow.child.path) compactPass.text = ""
              }
            }

            ColumnLayout {
              id: diskColumn
              anchors.fill: parent
              visible: !diskCard.compact
              spacing: Style.space(8)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  text: Model.kindIcon(modelData.kind)
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                  spacing: 1
                  Layout.fillWidth: true

                  Text {
                    text: Model.diskTitle(modelData)
                    textFormat: Text.PlainText
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    text: modelData.size + " · " + Model.kindLabel(modelData.kind)
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  visible: root.busyFor(modelData.path)
                  text: ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignVCenter
                }

                Button {
                  visible: (modelData.kind === "usb" || modelData.kind === "cdrom")
                    && !root.busyFor(modelData.path)
                  text: ""
                  tooltipText: "Safely remove " + Model.htmlEscape(modelData.name)
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.ejectDisk(modelData)
                }
              }

              Text {
                visible: root.actionError.dev === modelData.path
                text: root.actionError.msg
                textFormat: Text.PlainText
                color: root.err
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }

              Repeater {
                model: modelData.children

                delegate: Item {
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: partitionRow.implicitHeight

                  RowLayout {
                    id: partitionRow
                    anchors.fill: parent
                    spacing: Style.space(8)

                    Text {
                      text: modelData.encrypted ? "" : "•"
                      color: modelData.encrypted ? root.fg : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      Layout.alignment: Qt.AlignVCenter
                    }

                    ColumnLayout {
                      spacing: 1
                      Layout.fillWidth: true

                      Text {
                        text: modelData.label ? modelData.label + " (" + modelData.name + ")" : modelData.name
                        textFormat: Text.PlainText
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        text: Model.leafCaption(modelData)
                        textFormat: Text.PlainText
                        color: modelData.mountpoints.length > 0 ? root.dim : root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        visible: root.actionError.dev === modelData.path
                        text: root.actionError.msg
                        textFormat: Text.PlainText
                        color: root.err
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                      }

                      RowLayout {
                        visible: modelData.encrypted && !modelData.unlocked
                        Layout.fillWidth: true
                        spacing: Style.space(8)

                        TextField {
                          id: partPass
                          Layout.fillWidth: true
                          password: true
                          placeholderText: "Passphrase"
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          horizontalPadding: Style.spacing.controlGap
                          verticalPadding: Style.spacing.controlPaddingY
                          onActiveFocusChanged: root.inputActive = activeFocus
                          onAccepted: partUnlock.clicked()
                          Keys.onEscapePressed: root.close()
                        }

                        Button {
                          id: partUnlock
                          visible: !root.busyFor(modelData.path)
                          text: "Unlock"
                          active: true
                          foreground: root.fg
                          fontFamily: root.fontFamily
                          fontSize: Style.font.caption
                          horizontalPadding: Style.spacing.controlPaddingX
                          verticalPadding: Style.spacing.controlPaddingY
                          onClicked: {
                            if (partPass.text === "") return
                            root.unlockDevice(modelData, partPass.text)
                          }
                        }
                      }
                    }

                    Text {
                      visible: root.busyFor(modelData.path)
                      text: ""
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      Layout.alignment: Qt.AlignVCenter
                    }

                    Button {
                      visible: (!modelData.encrypted || modelData.unlocked) && modelData.mountpoints.length > 0 && !root.busyFor(modelData.path)
                      text: ""
                      tooltipText: "Open " + Model.htmlEscape(modelData.mountpoints[0])
                      foreground: root.fg
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      horizontalPadding: Style.spacing.controlPaddingX
                      verticalPadding: Style.spacing.controlPaddingY
                      onClicked: root.openMountpoint(modelData.mountpoints[0])
                    }

                    Button {
                      visible: (!modelData.encrypted || modelData.unlocked) && !root.busyFor(modelData.path)
                      text: modelData.mountpoints.length > 0 ? "Unmount" : "Mount"
                      foreground: root.fg
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      horizontalPadding: Style.spacing.controlPaddingX
                      verticalPadding: Style.spacing.controlPaddingY
                      active: true
                      onClicked: modelData.mountpoints.length > 0
                        ? root.unmountDevice(modelData)
                        : root.mountDevice(modelData)
                    }

                    Button {
                      visible: modelData.encrypted && modelData.unlocked && !root.busyFor(modelData.path)
                      text: ""
                      tooltipText: "Lock " + Model.htmlEscape(modelData.name)
                      foreground: root.fg
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      horizontalPadding: Style.spacing.controlPaddingX
                      verticalPadding: Style.spacing.controlPaddingY
                      onClicked: root.lockDevice(modelData)
                    }
                  }

                  Connections {
                    target: root
                    function onUnlockTickChanged() {
                      if (root.busyDev === modelData.path) partPass.text = ""
                    }
                  }
                }
              }

              Text {
                visible: modelData.children.length === 0 && !root.busyFor(modelData.path)
                text: modelData.kind === "cdrom" ? "No media" : "No mountable partitions"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Text {
          visible: root.drives.length === 0
          Layout.fillWidth: true
          text: "No drives connected."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          visible: root.errorText !== ""
          Layout.fillWidth: true
          text: root.errorText
          textFormat: Text.PlainText
          color: root.err
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          text: "r refresh · esc closes"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
