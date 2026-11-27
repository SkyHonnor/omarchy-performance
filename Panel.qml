import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Personal performance bar widget + panel for Omarchy.
// Displays CPU% + chip icon in the bar (tinted by temperature) and opens a
// live metrics popup with CPU/GPU temperatures, fan RPM, memory, and btop.
Panel {
  id: root
  moduleName: "skyhonnor.performance"
  ipcTarget: "skyhonnor.performance"
  manageIpc: true

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // Fallback until PluginBarApi.barSize propagates on initial load.
  readonly property int effectiveBarSize: (bar && bar.barSize > 0) ? bar.barSize : Style.bar.sizeHorizontal

  // ── Metrics ───────────────────────────────────────────────────────────────
  property int    cpuPct:      0
  property int    cpuTempC:    0
  property bool   hasCpuTemp:  false
  property int    gpuTempC:    0
  property bool   hasGpuTemp:  false
  // Multi-GPU list: [{ vendor, busyPct, vramUsedMiB, vramTotalMiB, tempC, suspended, curFreqMHz, maxFreqMHz }]
  property var    gpus:        []
  property int    fanRpm:      0
  property int    fanMaxRpm:   5400
  property bool   hasFan:      false
  property string memLabel:    ""
  property real   memUsed:     0
  property real   memTotal:    0

  readonly property string gpuScriptPath: decodeURIComponent(Qt.resolvedUrl("gpu-stats.sh").toString().replace(/^file:\/\//, ""))

  readonly property real memFraction:     memTotal > 0 ? Math.min(1, memUsed / memTotal) : 0
  readonly property int  memPct:          Math.round(memFraction * 100)
  readonly property real cpuTempFraction: Math.min(1, Math.max(0, root.cpuTempC / 100))
  readonly property real gpuTempFraction: Math.min(1, Math.max(0, root.gpuTempC / 100))
  readonly property real fanFraction:     root.fanMaxRpm > 0
    ? Math.min(1, Math.max(0, root.fanRpm / root.fanMaxRpm))
    : 0

  readonly property int peakGpuTempC: {
    var peak = root.hasGpuTemp ? root.gpuTempC : 0
    for (var i = 0; i < root.gpus.length; i++) {
      var g = root.gpus[i]
      if (g && !g.suspended && g.tempC !== null && g.tempC > peak) peak = g.tempC
    }
    return peak
  }

  readonly property int peakTempC: Math.max(
    root.hasCpuTemp ? root.cpuTempC : 0,
    root.peakGpuTempC
  )

  readonly property string cpuStatusText: {
    if (root.peakTempC >= 90) return strings.t("status.hot")
    if (root.peakTempC >= 70) return strings.t("status.warm")
    if (root.cpuPct >= 90)    return strings.t("status.heavy")
    if (root.cpuPct >= 60)    return strings.t("status.moderate")
    if (root.cpuPct >= 30)    return strings.t("status.light")
    return strings.t("status.idle")
  }

  function tempColor(tempC) {
    if (!root.bar) return Commons.Color.foreground
    if (tempC >= 90) return "#ff6b6b"
    if (tempC >= 70) return "#ffcc44"
    return root.bar.barForeground
  }

  function loadColor(pct) {
    if (!root.bar) return Commons.Color.foreground
    if (pct >= 92) return "#ff6b6b"
    if (pct >= 80) return "#ffcc44"
    return root.bar.barForeground
  }

  function formatMiB(mib) {
    if (mib >= 1024) return (mib / 1024).toFixed(1) + "G"
    return Math.round(mib) + "M"
  }

  function gpuDisplayLabel(gpu, index) {
    if (root.gpus.length <= 1) return strings.t("label.gpu")
    var vendor = gpu && gpu.vendor ? " · " + gpu.vendor : ""
    return strings.t("label.gpu") + " " + (index + 1) + vendor
  }

  function gpuUsageText(gpu) {
    if (!gpu) return "—"
    if (gpu.suspended) return strings.t("status.sleeping")
    var parts = []
    if (gpu.busyPct >= 0) parts.push(gpu.busyPct + "%")
    if (gpu.vramTotalMiB > 0 && gpu.vramUsedMiB >= 0)
      parts.push(formatMiB(gpu.vramUsedMiB) + " / " + formatMiB(gpu.vramTotalMiB))
    if (parts.length === 0 && gpu.curFreqMHz >= 0) {
      var freqStr = gpu.maxFreqMHz > 0
        ? gpu.curFreqMHz + " / " + gpu.maxFreqMHz + " MHz"
        : gpu.curFreqMHz + " MHz"
      parts.push(strings.t("label.gpuClock") + " " + freqStr)
    }
    return parts.length > 0 ? parts.join(" · ") : "—"
  }

  function gpuUsageFraction(gpu) {
    if (!gpu || gpu.suspended) return 0
    if (gpu.busyPct >= 0) return Math.min(1, Math.max(0, gpu.busyPct / 100))
    if (gpu.vramTotalMiB > 0 && gpu.vramUsedMiB >= 0)
      return Math.min(1, Math.max(0, gpu.vramUsedMiB / gpu.vramTotalMiB))
    if (gpu.curFreqMHz >= 0 && gpu.maxFreqMHz > 0)
      return Math.min(1, Math.max(0, gpu.curFreqMHz / gpu.maxFreqMHz))
    return 0
  }

  function gpuUsageColor(gpu) {
    if (!root.bar) return Commons.Color.foreground
    if (!gpu || gpu.suspended) return root.bar.foreground
    if (gpu.tempC !== null && gpu.tempC >= 70) return tempColor(gpu.tempC)
    if (gpu.busyPct >= 0) return loadColor(gpu.busyPct)
    return root.bar.foreground
  }

  function parseOptionalInt(raw) {
    var s = String(raw || "").trim()
    if (s === "" || s === "NA") return null
    var n = parseInt(s, 10)
    return isFinite(n) ? n : null
  }

  function parseGpuStats(raw) {
    var lines = String(raw || "").trim().split("\n")
    var list = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var cols = line.split("\t")
      if (cols.length < 6) continue
      var busy = parseOptionalInt(cols[1])
      var vUsed = parseOptionalInt(cols[2])
      var vTotal = parseOptionalInt(cols[3])
      var temp = parseOptionalInt(cols[4])
      var susp = cols[5] === "1"
      var curFreq = cols.length >= 7 ? parseOptionalInt(cols[6]) : null
      var maxFreq = cols.length >= 8 ? parseOptionalInt(cols[7]) : null
      list.push({
        vendor: cols[0],
        busyPct: (busy !== null && busy >= 0 && busy <= 100) ? busy : -1,
        vramUsedMiB: (vUsed !== null && vUsed >= 0) ? vUsed : -1,
        vramTotalMiB: (vTotal !== null && vTotal > 0) ? vTotal : -1,
        tempC: (temp !== null && temp >= 0 && temp < 150) ? temp : null,
        suspended: susp,
        curFreqMHz: (curFreq !== null && curFreq >= 0) ? curFreq : -1,
        maxFreqMHz: (maxFreq !== null && maxFreq > 0) ? maxFreq : -1
      })
    }
    root.gpus = list
  }

  readonly property color accentColor: tempColor(root.peakTempC)
  readonly property color memColor:    loadColor(root.memPct)

  function barMetricColor(metricColor) {
    if (!root.bar) return metricColor
    const foreground = root.bar.barForeground
    const lightBar = 0.2126 * foreground.r + 0.7152 * foreground.g + 0.0722 * foreground.b < 0.5
    if (lightBar && Qt.colorEqual(metricColor, "#ffcc44")) return "#805000"
    if (lightBar && Qt.colorEqual(metricColor, "#ff6b6b")) return "#a32323"
    return metricColor
  }

  // ── Helpers to parse `sensors -j` ─────────────────────────────────────────
  function readTempSubfeature(feature) {
    if (!feature || typeof feature !== "object") return null
    for (var k in feature) {
      if (/^temp\d+_input$/.test(k)) {
        var n = Number(feature[k])
        if (isFinite(n)) return n
      }
    }
    return null
  }

  function clearSensorReadings() {
    root.hasCpuTemp = false
    root.cpuTempC = 0
    root.hasGpuTemp = false
    root.gpuTempC = 0
    root.hasFan = false
    root.fanRpm = 0
  }

  function parseSensorsJson(raw) {
    var trimmed = String(raw || "").trim()
    if (!trimmed) {
      clearSensorReadings()
      return
    }
    var data
    try {
      data = JSON.parse(trimmed)
    } catch (e) {
      clearSensorReadings()
      return
    }
    if (!data || typeof data !== "object") {
      clearSensorReadings()
      return
    }

    var cpuTemp = null
    var cpuPriority = 99
    var gpuTemp = null
    var fanInput = null
    var fanMax = null

    for (var chipName in data) {
      var chip = data[chipName]
      if (!chip || typeof chip !== "object") continue
      var lowerChip = chipName.toLowerCase()

      for (var featName in chip) {
        if (featName === "Adapter") continue
        var feat = chip[featName]
        if (!feat || typeof feat !== "object") continue

        // CPU temperature (prefer k10temp Tctl/Tdie, then coretemp Package, then dell_smm CPU, then acpitz)
        var t = readTempSubfeature(feat)
        if (t !== null && t > -50 && t < 150) {
          var prio = 99
          if (lowerChip.indexOf("k10temp") === 0 && (featName === "Tctl" || featName === "Tdie")) prio = 1
          else if (lowerChip.indexOf("coretemp") === 0 && featName.indexOf("Package id 0") === 0) prio = 1
          else if (lowerChip.indexOf("dell_smm") === 0 && featName === "CPU") prio = 2
          else if (lowerChip.indexOf("acpitz") === 0 && featName === "temp1") prio = 3

          if (prio < cpuPriority) {
            cpuPriority = prio
            cpuTemp = t
          }

          // GPU temperature (amdgpu / nouveau / radeon)
          if ((lowerChip.indexOf("amdgpu") === 0 || lowerChip.indexOf("radeon") === 0 || lowerChip.indexOf("nouveau") === 0)
              && (featName === "edge" || featName === "junction" || featName === "temp1")
              && gpuTemp === null) {
            gpuTemp = t
          }
        }

        // Fan speed (first available fan*_input across any hardware sensor)
        if (fanInput === null) {
          for (var subKey in feat) {
            var m = subKey.match(/^(fan\d+)_input$/)
            if (m) {
              var rpm = Number(feat[subKey])
              if (isFinite(rpm) && rpm >= 0) {
                fanInput = rpm
                var maxVal = Number(feat[m[1] + "_max"])
                if (isFinite(maxVal) && maxVal > 0) fanMax = maxVal
                break
              }
            }
          }
        }
      }
    }

    if (cpuTemp !== null) {
      root.cpuTempC = Math.round(cpuTemp)
      root.hasCpuTemp = true
    } else {
      root.cpuTempC = 0
      root.hasCpuTemp = false
    }
    if (gpuTemp !== null) {
      root.gpuTempC = Math.round(gpuTemp)
      root.hasGpuTemp = true
    } else {
      root.gpuTempC = 0
      root.hasGpuTemp = false
    }
    if (fanInput !== null) {
      root.fanRpm = Math.round(fanInput)
      if (fanMax !== null) root.fanMaxRpm = Math.round(fanMax)
      root.hasFan = true
    } else {
      root.fanRpm = 0
      root.hasFan = false
    }
  }

  // ── Polling processes (direct argv, no shell wrapper) ─────────────────────
  Process {
    id: statsProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.trim().split("\n")
        for (var i = 0; i < lines.length; i++) {
          var cols = lines[i].split("\t")
          if (cols[0] === "cpu" && cols.length >= 2)
            root.cpuPct = parseInt(String(cols[1]), 10) || 0
          if (cols[0] === "memory" && cols.length >= 2) {
            root.memLabel = String(cols[1] || "")
            var m = root.memLabel.match(/^([0-9]+(?:[.,][0-9]+)?)[^0-9]+([0-9]+(?:[.,][0-9]+)?)/)
            if (m) {
              root.memUsed  = parseFloat(m[1].replace(",", ".")) || 0
              root.memTotal = parseFloat(m[2].replace(",", ".")) || 0
            }
          }
        }
      }
    }
  }

  Process {
    id: sensorsProc
    property bool gotOutput: false
    command: ["sensors", "-j"]
    onStarted: gotOutput = false
    onExited: if (!gotOutput) root.clearSensorReadings()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        sensorsProc.gotOutput = true
        root.parseSensorsJson(text)
      }
    }
  }

  Process {
    id: gpuProc
    property bool gotOutput: false
    command: ["bash", root.gpuScriptPath]
    onStarted: gotOutput = false
    onExited: if (!gotOutput) root.gpus = []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        gpuProc.gotOutput = true
        root.parseGpuStats(text)
      }
    }
  }

  Process {
    id: btopProc
    command: ["omarchy-launch-floating-terminal-with-presentation", "btop"]
  }

  property bool gpuInitialized: false

  function refresh() {
    if (!statsProc.running)   statsProc.running   = true
    if (!sensorsProc.running) sensorsProc.running = true
    if ((root.opened || !root.gpuInitialized) && !gpuProc.running) {
      root.gpuInitialized = true
      gpuProc.running = true
    }
  }

  onOpenedChanged: {
    if (opened) root.refresh()
  }

  Timer {
    interval: root.opened ? 2000 : 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ── Bar button (CPU + RAM) ────────────────────────────────────────────────
  readonly property real openPanelIndicatorWidth: !button.vertical ? barContent.implicitWidth : 0
  implicitWidth:  button.implicitWidth
  implicitHeight: !button.vertical ? root.effectiveBarSize : button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar:              root.bar
    labelVisible:     false
    hasVisualContent: true
    fontSize:         Style.bar.iconFont
    horizontalMargin: 7
    fixedWidth:       vertical ? -1 : Math.round(barContent.implicitWidth + scaledHorizontalMargin * 2)
    fixedHeight:      vertical ? Style.bar.iconSlot : -1
    tooltipText:      ""
    onPressed:        root.toggle()

    FontMetrics {
      id: barLabelMetrics
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
    }

    readonly property real figureOffsetY:
      (barLabelMetrics.descent - barLabelMetrics.ascent + barLabelMetrics.tightBoundingRect("0").height) / 2

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(8)
      scale: button.pressScale

      // CPU% + chip icon
      Row {
        spacing: Style.space(4)
        height: Style.bar.iconCanvas

        Text {
          visible: !button.vertical
          textFormat: Text.PlainText
          text: root.cpuPct + "%"
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          color: root.barMetricColor(root.accentColor)
          y: (parent.height - height) / 2 + button.figureOffsetY
          renderType: Text.NativeRendering
        }

        OpticalGlyph {
          width: Style.bar.iconCanvas
          height: Style.bar.iconCanvas
          text: "\u{F035B}"   // 󰍛 nf-md-memory (chip)
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          paintedSize: Style.bar.iconSize
          color: root.barMetricColor(root.accentColor)
        }
      }

      // RAM% + memory stick icon
      Row {
        visible: !button.vertical
        spacing: Style.space(4)
        height: Style.bar.iconCanvas

        Text {
          textFormat: Text.PlainText
          text: root.memTotal > 0
            ? root.memPct + "% (" + root.memUsed.toFixed(1) + "G)"
            : root.memPct + "%"
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          color: root.barMetricColor(root.memColor)
          y: (parent.height - height) / 2 + button.figureOffsetY
          renderType: Text.NativeRendering
        }

        OpticalGlyph {
          width: Style.bar.iconCanvas
          height: Style.bar.iconCanvas
          text: "\u{EFC5}"    //  nf-fa-memory (RAM stick)
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          paintedSize: Style.bar.iconSize
          color: root.barMetricColor(root.memColor)
        }
      }
    }
  }

  // ── Panel popup ───────────────────────────────────────────────────────────
  PopupCard {
    id: popup
    anchorItem:    button
    bar:           root.bar
    owner:         root
    open:          root.opened
    contentWidth:  popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(panelContent.implicitHeight)

    Column {
      id: panelContent
      anchors { left: parent.left; right: parent.right; top: parent.top }
      spacing: Style.space(14)

      PanelHero {
        iconComponent: Component {
          Text {
            textFormat: Text.PlainText
            text: "\u{F035B}"   // 󰍛 nf-md-memory (chip)
            color: root.bar ? root.bar.foreground : Commons.Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
          }
        }
        title:      strings.t("title")
        meta:       root.cpuStatusText
        foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : Commons.Color.foreground }

      PanelSectionHeader {
        text:       strings.t("section.resources")
        foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      Column {
        width: parent.width
        spacing: Style.space(10)

        StatRow {
          icon:       "\u{F035B}"   // 󰍛 CPU
          label:      strings.t("label.cpu")
          value:      root.cpuPct + "%"
          valueColor: root.accentColor
          fraction:   root.cpuPct / 100
          fillColor:  root.accentColor
        }

        StatRow {
          icon:       "\u{EFC5}"    //  RAM
          label:      strings.t("label.memory")
          value:      root.memLabel !== ""
            ? root.memLabel + " (" + root.memPct + "%)"
            : "—"
          valueColor: root.memColor
          fraction:   root.memFraction
          fillColor:  root.memColor
        }

        Repeater {
          model: root.gpus

          StatRow {
            required property var modelData
            required property int index
            visible:    modelData.suspended || modelData.busyPct >= 0 || modelData.vramTotalMiB > 0 || modelData.curFreqMHz >= 0
            icon:       "\u{F08AE}"   // 󰢮 GPU card
            label:      root.gpuDisplayLabel(modelData, index)
            value:      root.gpuUsageText(modelData)
            valueColor: root.gpuUsageColor(modelData)
            fraction:   root.gpuUsageFraction(modelData)
            fillColor:  valueColor
          }
        }
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : Commons.Color.foreground }

      PanelSectionHeader {
        text:       strings.t("section.thermals")
        foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      Column {
        width: parent.width
        spacing: Style.space(10)

        StatRow {
          icon:       "\u{F050F}"   // 󰔏 thermometer
          label:      strings.t("label.cpu")
          value:      root.hasCpuTemp ? root.cpuTempC + "°C" : "—"
          valueColor: root.hasCpuTemp ? root.tempColor(root.cpuTempC) : (root.bar ? root.bar.foreground : Commons.Color.foreground)
          fraction:   root.hasCpuTemp ? root.cpuTempFraction : 0
          fillColor:  valueColor
        }

        Repeater {
          model: root.gpus

          StatRow {
            required property var modelData
            required property int index
            visible:    !modelData.suspended && modelData.tempC !== null
            icon:       "\u{F050F}"   // 󰔏 thermometer
            label:      root.gpuDisplayLabel(modelData, index)
            value:      modelData.tempC !== null ? modelData.tempC + "°C" : "—"
            valueColor: modelData.tempC !== null ? root.tempColor(modelData.tempC) : (root.bar ? root.bar.foreground : Commons.Color.foreground)
            fraction:   modelData.tempC !== null ? Math.min(1, Math.max(0, modelData.tempC / 100)) : 0
            fillColor:  valueColor
          }
        }

        // Fallback if `sensors -j` detected a GPU temperature not listed via DRM
        StatRow {
          visible:    root.gpus.length === 0 && root.hasGpuTemp
          icon:       "\u{F050F}"   // 󰔏 thermometer
          label:      strings.t("label.gpu")
          value:      root.gpuTempC + "°C"
          valueColor: root.tempColor(root.gpuTempC)
          fraction:   root.gpuTempFraction
          fillColor:  valueColor
        }
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : Commons.Color.foreground }

      PanelSectionHeader {
        text:       strings.t("section.fan")
        foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      }

      StatRow {
        icon:     "\u{F0210}"       // 󰈐 fan
        label:    strings.t("label.fanSpeed")
        value:    root.hasFan ? root.fanRpm + " RPM" : "—"
        fraction: root.hasFan ? root.fanFraction : 0
      }

      PanelSeparator { foreground: root.bar ? root.bar.foreground : Commons.Color.foreground }

      Button {
        width: parent.width
        iconText:          "\u{F035B}"   // 󰍛
        iconSize:          Style.font.body
        text:              strings.t("action.openBtop")
        fontSize:          Style.font.bodySmall
        foreground:        root.bar ? root.bar.foreground : Commons.Color.foreground
        fontFamily:        root.bar ? root.bar.fontFamily : Style.font.family
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
  component ProgressBar: Item {
    property real  fraction:  0
    property color fillColor: root.bar ? root.bar.foreground : Commons.Color.foreground

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
      Behavior on width { NumberAnimation { duration: Style.duration(260); easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: Style.duration(220) } }
    }
  }

  component StatRow: Item {
    property string icon:       ""
    property string label:      ""
    property string value:      ""
    property color  valueColor: root.bar ? root.bar.foreground : Commons.Color.foreground
    property real   fraction:   0
    property color  fillColor:  root.bar ? root.bar.foreground : Commons.Color.foreground

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labelRow.implicitHeight, valueText.implicitHeight) + Style.space(5) + bar.implicitHeight

    Row {
      id: labelRow
      spacing: Style.space(6)
      anchors { left: parent.left; top: parent.top }

      Text {
        visible: parent.parent.icon !== ""
        textFormat: Text.PlainText
        text: parent.parent.icon
        color: root.bar
          ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.8)
          : "#ccffffff"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: parent.parent.label
        color: root.bar
          ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.6)
          : "#99ffffff"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      id: valueText
      textFormat: Text.PlainText
      text: parent.value
      color: parent.valueColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors { right: parent.right; verticalCenter: labelRow.verticalCenter }
    }

    ProgressBar {
      id: bar
      fraction:  parent.fraction
      fillColor: parent.fillColor
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    }
  }
}
