import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Toggles a NetworkManager WireGuard connection; right-click shows whether the
// peer is actually answering. Installed by omarchy-scripts bin/setup-wireguard;
// edit the copy in that repository.
BarWidget {
  id: root
  moduleName: "omarchy-scripts.wireguard"

  // Empty means "the first WireGuard profile NetworkManager knows about".
  readonly property string preferred: String(setting("connection", ""))
  property string connectionName: ""
  property bool connected: false
  property string device: ""
  property string nmState: ""

  // Everything below is only gathered while the popup is open; closing it
  // stops the timer and forgets what was seen.
  property bool popupOpen: false
  property string endpoint: ""
  property string address: ""
  property string dns: ""
  property real rxBytes: -1
  property real txBytes: -1
  property real lastRxAt: 0
  property real watchStart: 0
  property real now: 0
  // A Test nudge: the rx count when it was sent, and when.
  property real testRxStart: -1
  property real testAt: 0
  property string testResult: ""

  // NetworkManager calls a WireGuard connection activated as soon as the
  // interface exists. The interface only counts packets that authenticated, so
  // received bytes are the proof that a handshake with the peer completed.
  readonly property string health: {
    if (!connected) return nmState === "activating" ? "activating" : "off"
    if (nmState === "activating") return "activating"
    if (rxBytes > 0) return "ok"
    if (rxBytes === 0 && watchStart > 0 && now - watchStart > 15000) return "noReply"
    return "waiting"
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function toggle() {
    if (connectionName === "" || toggleProc.running) return
    toggleProc.command = ["nmcli", "connection", connected ? "down" : "up", "id", connectionName]
    toggleProc.running = true
  }

  function close() { popupOpen = false }

  function forgetDetails() {
    rxBytes = -1
    txBytes = -1
    lastRxAt = 0
    watchStart = 0
    testRxStart = -1
    testAt = 0
    testResult = ""
  }

  function sample() {
    now = Date.now()
    refresh()
    if (connected && device !== "" && !trafficProc.running) {
      trafficProc.command = ["cat", "/sys/class/net/" + device + "/statistics/rx_bytes",
                             "/sys/class/net/" + device + "/statistics/tx_bytes"]
      trafficProc.running = true
    }
    if (testRxStart >= 0 && testResult === "testing" && now - testAt > 6000) testResult = "noReply"
  }

  // One DNS query over the tunnel: WireGuard has to handshake to send it, so
  // rx growing afterwards means the peer answered. No ICMP; it is often blocked.
  function test() {
    if (!connected || device === "" || dns === "" || dnsProc.running) return
    var host = endpoint.replace(/:\d+$/, "").replace(/^\[|\]$/g, "") || "."
    testRxStart = Math.max(0, rxBytes)
    testAt = Date.now()
    testResult = "testing"
    dnsProc.command = ["resolvectl", "query", "--cache=no", "--legend=no", "-i", device, host]
    dnsProc.running = true
  }

  function humanBytes(n) {
    if (n < 0) return "–"
    var units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var i = 0
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (i === 0 ? n : n.toFixed(1)) + " " + units[i]
  }

  function ago(ms) {
    var s = Math.max(0, Math.round(ms / 1000))
    if (s < 60) return s + "s"
    if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s"
    return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
  }

  readonly property string healthText: {
    switch (health) {
    case "ok": return "Connected: the peer has answered"
    case "activating": return "Connecting…"
    case "waiting": return "Up, waiting for a handshake" + (watchStart > 0 ? " (" + ago(now - watchStart) + ")" : "")
    case "noReply": return "No reply from peer: check endpoint, keys, firewall"
    default: return "Off"
    }
  }

  readonly property string trafficText: {
    if (!connected || rxBytes < 0) return "–"
    var text = "↓ " + humanBytes(rxBytes) + "   ↑ " + humanBytes(txBytes)
    if (lastRxAt > 0) text += "   (last packet in " + ago(now - lastRxAt) + " ago)"
    return text
  }

  readonly property string testText: {
    switch (testResult) {
    case "testing": return "Sent a DNS query through the tunnel…"
    case "ok": return "Peer answered"
    case "noReply": return "No reply in 6s"
    default: return ""
    }
  }

  onPopupOpenChanged: {
    forgetDetails()
    if (popupOpen && connectionName !== "") {
      detailsProc.command = ["nmcli", "-g", "wireguard.peers,ipv4.addresses,ipv4.dns", "connection", "show", "id", connectionName]
      detailsProc.running = true
    }
  }

  onConnectedChanged: {
    if (!connected) forgetDetails()
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
    command: ["nmcli", "-t", "-f", "NAME,TYPE,ACTIVE,DEVICE,STATE", "connection", "show"]
    stdout: StdioCollector {
      onStreamFinished: {
        var name = ""
        var active = false
        var dev = ""
        var state = ""
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var fields = root.splitTerse(lines[i])
          if (fields.length < 5 || fields[1] !== "wireguard") continue
          var candidate = fields[0]
          if (root.preferred !== "" && candidate !== root.preferred) continue
          if (name === "" || fields[2] === "yes") {
            name = candidate
            active = fields[2] === "yes"
            dev = fields[3]
            state = fields[4]
          }
          if (active) break
        }
        root.connectionName = name
        root.connected = active
        root.device = dev
        root.nmState = state
      }
    }
  }

  Process {
    id: trafficProc
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = text.trim().split("\n")
        if (lines.length < 2 || !root.connected) return
        var rx = Number(lines[0])
        var tx = Number(lines[1])
        if (!isFinite(rx) || !isFinite(tx)) return
        if (root.watchStart === 0) root.watchStart = root.now
        if (root.rxBytes >= 0 && rx > root.rxBytes) root.lastRxAt = root.now
        root.rxBytes = rx
        root.txBytes = tx
        if (root.testResult === "testing" && rx > root.testRxStart) root.testResult = "ok"
      }
    }
  }

  Process {
    id: detailsProc
    stdout: StdioCollector {
      onStreamFinished: {
        // -g prints one field per line and escapes ':' as '\:'.
        var lines = text.split("\n")
        var unescape = function(s) { return (s || "").replace(/\\(.)/g, "$1") }
        var peers = unescape(lines[0])
        var endpoints = []
        var re = /endpoint=(\S+)/g
        var m
        while ((m = re.exec(peers)) !== null) endpoints.push(m[1])
        root.endpoint = endpoints.join(", ")
        root.address = unescape(lines[1]).replace(/,/g, ", ")
        root.dns = unescape(lines[2]).replace(/,/g, ", ")
      }
    }
  }

  Process {
    id: dnsProc
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
    running: !root.popupOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 2000
    running: root.popupOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.connected ? "󰌾" : "󰿆"
    dimmed: !root.connected
    useActiveColor: false
    tooltipText: root.popupOpen ? "" : "WireGuard " + root.connectionName + ": " + (root.connected ? "on" : "off") + " · right-click for details"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.popupOpen = !root.popupOpen
      else if (b === Qt.LeftButton) root.toggle()
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "WireGuard " + root.connectionName
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        text: root.healthText
        color: root.health === "noReply" ? root.bar.urgent : (root.health === "ok" ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.3))
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
        width: parent.width
      }

      PanelSeparator {
        foreground: root.bar.foreground
      }

      Repeater {
        model: [
          { label: "Endpoint", value: root.endpoint },
          { label: "Address", value: root.address },
          { label: "DNS", value: root.dns },
          { label: "Traffic", value: root.trafficText },
          { label: "Test", value: root.testText }
        ]

        Row {
          id: infoRow
          required property var modelData
          visible: modelData.value !== ""
          width: column.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: infoRow.modelData.label
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            width: Style.space(64)
          }

          Text {
            textFormat: Text.PlainText
            text: infoRow.modelData.value
            color: infoRow.modelData.label === "Test" && root.testResult === "noReply" ? root.bar.urgent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WrapAnywhere
            width: parent.width - Style.space(72)
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Button {
          text: root.connected ? "Turn off" : "Turn on"
          foreground: root.bar.foreground
          bordered: true
          enabled: !toggleProc.running
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.toggle()
        }

        Button {
          text: "Test"
          tooltipText: "Send one DNS query through the tunnel and watch for a reply"
          foreground: root.bar.foreground
          bordered: true
          enabled: root.connected && root.dns !== "" && root.testResult !== "testing"
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.test()
        }
      }
    }
  }
}
