import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Toggles a NetworkManager WireGuard connection. Installed by
// omarchy-scripts bin/setup-wireguard; edit the copy in that repository.
BarWidget {
  id: root
  moduleName: "omarchy-scripts.wireguard"

  // Empty means "the first WireGuard profile NetworkManager knows about".
  readonly property string preferred: String(setting("connection", ""))
  property string connectionName: ""
  property bool connected: false

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function toggle() {
    if (connectionName === "" || toggleProc.running) return
    toggleProc.command = ["nmcli", "connection", connected ? "down" : "up", "id", connectionName]
    toggleProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: connectionName !== ""

  IpcHandler {
    target: "omarchy-scripts.wireguard"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  // nmcli -t escapes ':' and '\' inside fields with a backslash.
  function splitTerse(line) {
    var fields = [""]
    for (var i = 0; i < line.length; i++) {
      var c = line[i]
      if (c === "\\" && i + 1 < line.length) fields[fields.length - 1] += line[++i]
      else if (c === ":") fields.push("")
      else fields[fields.length - 1] += c
    }
    return fields
  }

  Process {
    id: statusProc
    command: ["nmcli", "-t", "-f", "NAME,TYPE,ACTIVE", "connection", "show"]
    stdout: StdioCollector {
      onStreamFinished: {
        var name = ""
        var active = false
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var fields = root.splitTerse(lines[i])
          if (fields.length < 3 || fields[1] !== "wireguard") continue
          var candidate = fields[0]
          if (root.preferred !== "" && candidate !== root.preferred) continue
          if (name === "" || fields[2] === "yes") {
            name = candidate
            active = fields[2] === "yes"
          }
          if (active) break
        }
        root.connectionName = name
        root.connected = active
      }
    }
  }

  Process {
    id: toggleProc
    stderr: StdioCollector { id: toggleErr }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var message = toggleErr.text.trim() || ("nmcli exited " + exitCode)
        Quickshell.execDetached(["notify-send", "-u", "critical", "WireGuard: " + root.connectionName, message])
      }
      root.broadcast("refresh")
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.connected ? "󰌾" : "󰿆"
    dimmed: !root.connected
    useActiveColor: false
    tooltipText: "WireGuard " + root.connectionName + ": " + (root.connected ? "on" : "off")
    onPressed: root.toggle()
  }
}
