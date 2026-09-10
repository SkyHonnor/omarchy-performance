import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Performance bar widget + panel for Omarchy.
// Shows CPU% in the bar (colour-coded by temperature); click to open a panel
// with CPU, temperature, fan, and memory details — mirroring the battery panel.
//
// Author: orviwan  |  id: orviwan.performance
Panel {
  id: root
  moduleName: "orviwan.performance"
  manageIpc: false

  // ── Sizing fix: PluginBarApi.barSize starts at 0, so fall back to the same
  //    constant the bar itself uses until the binding propagates.
  readonly property int effectiveBarSize: (bar && bar.barSize > 0) ? bar.barSize : Style.bar.sizeHorizontal

  // ── Data ──────────────────────────────────────────────────────────────────
  property int    cpuPct:   0
  property int    tempC:    0
  property int    fanRpm:   0
  property string memLabel: ""
  property real   memUsed:  0   // GB
  property real   memTotal: 0   // GB

  readonly property real   memFraction:  memTotal > 0 ? Math.min(1, memUsed / memTotal) : 0
  readonly property real   tempFraction: Math.min(1, Math.max(0, root.tempC / 100))
  readonly property real   fanFraction:  Math.min(1, Math.max(0, (root.fanRpm - 1299) / (6199 - 1299)))

  // Status text uses the same thresholds as accentColor so text and colour
  // always change together — temperature takes priority over CPU load.
  readonly property string cpuStatusText: {
    if (root.tempC >= 90) return "Running hot"
    if (root.tempC >= 70) return "Running warm"
    if (root.cpuPct >= 90) return "Heavy load"
    if (root.cpuPct >= 60) return "Moderate load"
    if (root.cpuPct >= 30) return "Light load"
    return "Idle"
  }

  // ── Colour: driven by temperature ────────────────────────────────────────
  readonly property color accentColor: {
    if (!root.bar) return "#ffffff"
    if (root.tempC >= 90) return "#ff6b6b"
    if (root.tempC >= 70) return "#ffcc44"
    return root.bar.barForeground
  }

  // ── Polling: stats (CPU + memory) ─────────────────────────────────────────
  Process {
    id: statsProc
    command: ["bash", "-c", "omarchy-system-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.trim().split("\n")
        for (var i = 0; i < lines.length; i++) {
          var cols = lines[i].split("\t")
          if (cols[0] === "cpu" && cols.length >= 2)
            root.cpuPct = parseInt(String(cols[1])) || 0
          if (cols[0] === "memory" && cols.length >= 2) {
            root.memLabel = String(cols[1] || "")
            var m = root.memLabel.match(/^([0-9.]+)[^0-9]+([0-9.]+)/)
            if (m) {
              root.memUsed  = parseFloat(m[1]) || 0
              root.memTotal = parseFloat(m[2]) || 0
            }
          }
        }
      }
    }
  }

  // ── Polling: sensors (temperature + fan) ──────────────────────────────────
  Process {
    id: sensorsProc
    // "Right Side  : 6201 RPM" — $3=colon, $4=RPM
    command: ["bash", "-c",
      "sensors | awk '/Package id 0:/{gsub(/[^0-9.]/,\"\",$4); print \"temp\\t\"$4} /Right Side/{print \"fan\\t\"$4}'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.trim().split("\n")
        for (var i = 0; i < lines.length; i++) {
          var cols = lines[i].split("\t")
          if (cols[0] === "temp") root.tempC  = Math.round(parseFloat(cols[1])) || 0
          if (cols[0] === "fan")  root.fanRpm = parseInt(cols[1]) || 0
        }
      }
    }
  }

  // Launched when the user clicks "Open in btop"
  Process {
    id: btopProc
    command: ["bash", "-c", "omarchy-launch-floating-terminal-with-presentation btop"]
  }

  function refresh() {
    if (!statsProc.running)   statsProc.running   = true
    if (!sensorsProc.running) sensorsProc.running = true
  }

  // Poll every 4 s; ramp to 2 s while the panel is open for live updates.
  Timer {
    interval: root.opened ? 2000 : 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ── Bar button ────────────────────────────────────────────────────────────
  implicitWidth:  button.implicitWidth
  implicitHeight: root.effectiveBarSize

  BarIconButton {
    id: button
    anchors.fill: parent
    bar:        root.bar
    // "68% 󰍛" pattern matching the battery button's "68% 🔋"
    text:       root.cpuPct + "% \u{F035B}"   // 󰍛 nf-md-chip
    foreground: root.accentColor
    // Double-slot width to fit text + icon (same as battery with percentage)
    slotSize:   Style.bar.iconSlot * 2
    // No tooltipText — the panel shows all detail on click
    onPressed:  root.toggle()
  }

  // ── Panel popup ───────────────────────────────────────────────────────────
  PopupCard {
    id: popup
    anchorItem:    button
    bar:           root.bar
    owner:         root
    open:          root.opened
    contentWidth:  Style.space(280)
    contentHeight: popup.fittedContentHeight(panelContent.implicitHeight)

    Column {
      id: panelContent
      anchors { left: parent.left; right: parent.right; top: parent.top }
      spacing: Style.space(14)

      // ── Hero: chip icon · "Performance" · CPU% pill ──────────────────────
      PanelHero {
        iconComponent: Component {
          Text {
            textFormat: Text.PlainText
            text: "\u{F035B}"          // 󰍛 nf-md-chip
            color: root.bar ? root.bar.foreground : "white"
            font.family: root.bar ? root.bar.fontFamily : ""
            font.pixelSize: Style.font.display
          }
        }
        title:      "Performance"
        meta:       root.cpuStatusText
        detail:     root.cpuPct + "%"
        foreground: root.bar ? root.bar.foreground : "white"
        fontFamily: root.bar ? root.bar.fontFamily : ""
      }

      // ── CPU progress bar ──────────────────────────────────────────────────
      ProgressBar {
        fraction:  root.cpuPct / 100
        fillColor: root.accentColor
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : "white" }

      // ── Temperature & Fan ─────────────────────────────────────────────────
      PanelSectionHeader {
        text:       "THERMALS"
        foreground: root.bar ? root.bar.foreground : "white"
        fontFamily: root.bar ? root.bar.fontFamily : ""
      }

      Column {
        width: parent.width
        spacing: Style.space(8)

        StatRow {
          label:     "Temperature"
          value:     root.tempC + "°C"
          valueColor: root.accentColor
          fraction:  root.tempFraction
          fillColor: root.accentColor
        }

        StatRow {
          label:    "Fan"
          value:    root.fanRpm > 0 ? root.fanRpm + " RPM" : "—"
          fraction: root.fanFraction
        }
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : "white" }

      // ── Memory ───────────────────────────────────────────────────────────
      PanelSectionHeader {
        text:       "MEMORY"
        foreground: root.bar ? root.bar.foreground : "white"
        fontFamily: root.bar ? root.bar.fontFamily : ""
      }

      StatRow {
        label:    "Used"
        value:    root.memLabel
        fraction: root.memFraction
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : "white" }

      // ── "Open in btop" button ─────────────────────────────────────────────
      Button {
        width: parent.width
        iconText:          "\u{F035B}"   // 󰍛
        iconSize:          Style.font.body
        text:              "Open in btop"
        fontSize:          Style.font.bodySmall
        foreground:        root.bar ? root.bar.foreground : "white"
        fontFamily:        root.bar ? root.bar.fontFamily : ""
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding:   Style.spacing.controlPaddingY
        bordered:          true
        onClicked: {
          root.close()
          if (!btopProc.running) btopProc.running = true
        }
      }
    }
  }

  // ── Local components ──────────────────────────────────────────────────────

  // Thin progress bar matching the battery panel style.
  component ProgressBar: Item {
    property real  fraction:  0
    property color fillColor: root.bar ? root.bar.foreground : "white"

    width: parent ? parent.width : 0
    implicitHeight: Style.space(8)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: root.bar
        ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
        : "#22ffffff"
    }

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: height / 2
      color: fillColor
      width: Math.max(height, parent.width * Math.min(1, Math.max(0, fraction)))
      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 220 } }
    }
  }

  // Label + value line, with a slim progress bar below.
  component StatRow: Item {
    property string label:      ""
    property string value:      ""
    property color  valueColor: root.bar ? root.bar.foreground : "white"
    property real   fraction:   0
    property color  fillColor:  root.bar ? root.bar.foreground : "white"

    width: parent ? parent.width : 0
    implicitHeight: labelText.implicitHeight + Style.space(5) + bar.implicitHeight

    Text {
      id: labelText
      textFormat: Text.PlainText
      text: parent.label
      color: root.bar
        ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.6)
        : "#99ffffff"
      font.family: root.bar ? root.bar.fontFamily : ""
      font.pixelSize: Style.font.bodySmall
      anchors { left: parent.left; top: parent.top }
    }

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: parent.valueColor
      font.family: root.bar ? root.bar.fontFamily : ""
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors { right: parent.right; top: parent.top }
    }

    ProgressBar {
      id: bar
      fraction:  parent.fraction
      fillColor: parent.fillColor
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    }
  }
}
