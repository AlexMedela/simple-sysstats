import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One system statistic (CPU, GPU, RAM or disk) drawn as an icon plus values.
//
// Everything is read straight from /proc and /sys inside the shell process, so
// a refresh costs a few file reads instead of a bash + awk pipeline. Only the
// disk stat (df) and NVIDIA GPUs (nvidia-smi) spawn a process, because neither
// figure is exposed as a file.
//
// Left-click cycles the view: all values -> first value only -> icon only.
// The choice is shared by every screen and survives restarts (ViewState).
// Right/middle click run the onRightClick / onMiddleClick commands.
BarWidget {
  id: root
  moduleName: "amedela.simple-sysstats"

  readonly property var defaultIcons: ({
    cpu: String.fromCodePoint(0xf4bc),
    gpu: String.fromCodePoint(0xf08ae),
    ram: String.fromCodePoint(0xe266),
    disk: String.fromCodePoint(0xf02ca)
  })

  readonly property string stat: {
    var s = String(setting("stat", "CPU")).toLowerCase()
    return defaultIcons[s] !== undefined ? s : "cpu"
  }
  readonly property string mount: String(setting("mount", "/")) || "/"
  readonly property string stateKey: stat === "disk" ? "disk:" + mount : stat
  readonly property int interval: positive(setting("interval", 0), stat === "disk" ? 30 : 3)
  readonly property bool showTemperature: setting("showTemperature", true) !== false
  readonly property int usageThreshold: positive(setting("usageThreshold", 0), 90)
  readonly property int temperatureThreshold: positive(setting("temperatureThreshold", 0), 85)
  readonly property real fontSize: positive(setting("fontSize", 0), Style.font.body + 2)
  readonly property real iconSize: positive(setting("iconSize", 0), Math.round(fontSize * (stat === "gpu" ? 1.8 : 1.07)))
  readonly property string icon: String(setting("icon", "")) || defaultIcons[stat]

  // 0 = all values, 1 = first value only, 2 = icon only.
  readonly property int viewMode: ViewState.modes[stateKey] !== undefined
    ? ViewState.modes[stateKey] : Number(setting("viewMode", 0))

  property var values: []
  property string tooltipText: ""
  property bool critical: false

  // Sensor paths found once at startup by the discovery process.
  property bool discovered: false
  property string cpuTempPath: ""
  property string gpuVendor: ""
  property string gpuDevice: ""
  property string gpuTempPath: ""
  property var lastCpu: null

  readonly property color fg: critical && bar ? bar.urgent : (bar ? bar.barForeground : Color.foreground)
  readonly property var shownValues: viewMode === 2 ? [] : (viewMode === 1 || vertical ? values.slice(0, 1) : values)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function positive(value, fallback) {
    var n = Number(value)
    return isFinite(n) && n > 0 ? n : fallback
  }

  function gib(bytes) {
    var v = bytes / 1073741824
    return v >= 100 ? v.toFixed(0) : v.toFixed(1)
  }

  function readInt(view) {
    view.reload()
    var n = parseInt(view.text(), 10)
    return isNaN(n) ? null : n
  }

  function publish(values, tooltip, critical) {
    root.values = values
    root.tooltipText = tooltip
    root.critical = critical
  }

  function cycleView() {
    ViewState.setMode(stateKey, (viewMode + 1) % 3)
  }

  function refresh() {
    if (stat === "cpu") sampleCpu()
    else if (stat === "ram") sampleRam()
    else if (stat === "disk") { if (!dfProc.running) dfProc.running = true }
    else if (stat === "gpu") sampleGpu()
  }

  // /proc/stat: "cpu user nice system idle iowait irq softirq steal ..."
  function sampleCpu() {
    procStat.reload()
    var f = procStat.text().split("\n")[0].trim().split(/\s+/).slice(1, 9).map(Number)
    var idle = f[3] + (f[4] || 0)
    var total = 0
    for (var i = 0; i < f.length; i++) total += f[i] || 0
    var prev = lastCpu
    lastCpu = { total: total, idle: idle }
    if (!prev) { warmup.restart(); return }

    var dt = total - prev.total
    var usage = dt > 0 ? Math.round(100 * (dt - (idle - prev.idle)) / dt) : 0
    var temp = showTemperature && cpuTempPath ? readInt(cpuTemp) : null
    if (temp !== null) temp = Math.round(temp / 1000)

    loadAvg.reload()
    var load = loadAvg.text().trim().split(/\s+/).slice(0, 3).join("  ")

    var vals = [usage + "%"]
    var tip = ["CPU usage: " + usage + "%"]
    if (temp !== null) { vals.push(temp + "°C"); tip.push("CPU temp: " + temp + "°C") }
    tip.push("Load average: " + load)
    publish(vals, tip.join("\n"), usage >= usageThreshold || (temp !== null && temp >= temperatureThreshold))
  }

  function sampleRam() {
    memInfo.reload()
    var m = {}
    var lines = memInfo.text().split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = /^(\w+):\s+(\d+)/.exec(lines[i])
      if (match) m[match[1]] = Number(match[2]) * 1024
    }
    if (!m.MemTotal) return
    var used = m.MemTotal - (m.MemAvailable !== undefined ? m.MemAvailable : m.MemFree)
    var usage = Math.round(100 * used / m.MemTotal)
    var tip = ["RAM usage: " + usage + "%", "Used: " + gib(used) + " / " + gib(m.MemTotal) + " GiB"]
    if (m.SwapTotal > 0) tip.push("Swap: " + gib(m.SwapTotal - m.SwapFree) + " / " + gib(m.SwapTotal) + " GiB")
    publish([usage + "%", gib(used) + "G"], tip.join("\n"), usage >= usageThreshold)
  }

  function parseDf(text) {
    var lines = String(text || "").trim().split("\n")
    var f = lines[lines.length - 1].trim().split(/\s+/).map(Number)
    if (f.length < 3 || isNaN(f[0])) {
      publish(["N/A"], "Disk: cannot read " + mount, false)
      return
    }
    var size = f[0], used = f[1], avail = f[2]
    var usage = used + avail > 0 ? Math.round(100 * used / (used + avail)) : 0
    publish([usage + "%", gib(used) + "G"],
      "Disk (" + mount + ") usage: " + usage + "%\nUsed: " + gib(used) + " / " + gib(size)
        + " GiB\nFree: " + gib(avail) + " GiB",
      usage >= usageThreshold)
  }

  function sampleGpu() {
    if (gpuVendor === "amd") {
      var usage = readInt(gpuBusy)
      if (usage === null) return
      var temp = showTemperature && gpuTempPath ? readInt(gpuTemp) : null
      if (temp !== null) temp = Math.round(temp / 1000)
      var vramUsed = readInt(gpuVramUsed)
      var vramTotal = readInt(gpuVramTotal)
      gpuReport(usage, temp, vramUsed, vramTotal)
    } else if (gpuVendor === "nvidia") {
      if (!nvidiaProc.running) nvidiaProc.running = true
    } else {
      publish(["N/A"], gpuVendor === "intel"
        ? "GPU usage is not exposed by the Intel driver"
        : "No supported GPU found (AMD via sysfs, NVIDIA via nvidia-smi)", false)
    }
  }

  function gpuReport(usage, temp, vramUsed, vramTotal) {
    var vals = [usage + "%"]
    var tip = ["GPU usage: " + usage + "%"]
    if (temp !== null) { vals.push(temp + "°C"); tip.push("GPU temp: " + temp + "°C") }
    if (vramUsed !== null && vramTotal) tip.push("VRAM: " + gib(vramUsed) + " / " + gib(vramTotal) + " GiB")
    publish(vals, tip.join("\n"), usage >= usageThreshold || (temp !== null && temp >= temperatureThreshold))
  }

  // nvidia-smi CSV: utilization, temperature, memory.used, memory.total (MiB)
  function parseNvidia(text) {
    var f = String(text || "").trim().split("\n")[0].split(",").map(function(s) { return parseInt(s, 10) })
    if (f.length < 4 || isNaN(f[0])) { publish(["N/A"], "nvidia-smi returned no data", false); return }
    gpuReport(f[0], showTemperature && !isNaN(f[1]) ? f[1] : null, f[2] * 1048576, f[3] * 1048576)
  }

  // Discovery output, one "kind priority value..." record per line.
  function applyDiscovery(text) {
    var cpu = null, gpu = null
    var pinned = String(setting("gpuCard", ""))
    var vendorRank = { nvidia: 3, amd: 2, intel: 1 }
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].trim().split(/\s+/)
      if (f[0] === "cpu" && f.length >= 3) {
        var prio = Number(f[1])
        if (!cpu || prio < cpu.prio) cpu = { prio: prio, path: f[2] }
      } else if (f[0] === "gpu" && f.length >= 6) {
        var g = { card: f[1], vendor: f[2], vram: Number(f[3]) || 0, device: f[4], temp: f[5] === "-" ? "" : f[5] }
        if (pinned) { if (g.card === pinned) gpu = g; continue }
        if (!gpu || vendorRank[g.vendor] > vendorRank[gpu.vendor]
            || (g.vendor === gpu.vendor && g.vram > gpu.vram)) gpu = g
      }
    }
    cpuTempPath = cpu ? cpu.path : ""
    if (gpu) {
      gpuVendor = gpu.vendor
      gpuDevice = gpu.device
      gpuTempPath = gpu.temp
    }
    discovered = true
  }

  FileView { id: procStat; path: "/proc/stat"; blockLoading: true; printErrors: false }
  FileView { id: loadAvg; path: "/proc/loadavg"; blockLoading: true; printErrors: false }
  FileView { id: memInfo; path: "/proc/meminfo"; blockLoading: true; printErrors: false }
  FileView { id: cpuTemp; path: root.cpuTempPath; blockLoading: true; printErrors: false }
  FileView { id: gpuBusy; path: root.gpuVendor === "amd" ? root.gpuDevice + "/gpu_busy_percent" : ""; blockLoading: true; printErrors: false }
  FileView { id: gpuVramUsed; path: root.gpuVendor === "amd" ? root.gpuDevice + "/mem_info_vram_used" : ""; blockLoading: true; printErrors: false }
  FileView { id: gpuVramTotal; path: root.gpuVendor === "amd" ? root.gpuDevice + "/mem_info_vram_total" : ""; blockLoading: true; printErrors: false }
  FileView { id: gpuTemp; path: root.gpuTempPath; blockLoading: true; printErrors: false }

  // Runs once. Lists CPU temperature sensors (lower priority wins) and GPUs.
  Process {
    id: discoveryProc
    running: root.stat === "cpu" || root.stat === "gpu"
    command: ["sh", "-c", `
      for h in /sys/class/hwmon/hwmon*; do
        name=$(cat "$h/name" 2>/dev/null)
        case "$name" in
          k10temp|zenpower) echo "cpu 1 $h/temp1_input" ;;
          coretemp)
            p="$h/temp1_input"
            for l in "$h"/temp*_label; do
              case "$(cat "$l" 2>/dev/null)" in "Package id 0") p="\${l%_label}_input" ;; esac
            done
            echo "cpu 1 $p" ;;
          cpu_thermal|soc_thermal) echo "cpu 3 $h/temp1_input" ;;
          acpitz) echo "cpu 8 $h/temp1_input" ;;
        esac
      done
      for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] && echo "cpu 2 $z/temp"
      done
      for c in /sys/class/drm/card*; do
        case "\${c##*/}" in *-*) continue ;; esac
        d=$(readlink -f "$c/device")
        t=$(ls -d "$d"/hwmon/hwmon*/temp1_input 2>/dev/null | head -n1)
        case "$(cat "$d/vendor" 2>/dev/null)" in
          0x1002) [ -r "$d/gpu_busy_percent" ] && echo "gpu \${c##*/} amd $(cat "$d/mem_info_vram_total" 2>/dev/null || echo 0) $d \${t:--}" ;;
          0x10de) command -v nvidia-smi >/dev/null && echo "gpu \${c##*/} nvidia 0 $d -" ;;
          0x8086) echo "gpu \${c##*/} intel 0 $d -" ;;
        esac
      done
      true
    `]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDiscovery(text)
    }
  }

  Process {
    id: dfProc
    command: ["df", "-B1", "--output=size,used,avail", root.mount]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseDf(text)
    }
  }

  Process {
    id: nvidiaProc
    command: ["nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total",
      "--format=csv,noheader,nounits", "--id=0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseNvidia(text)
    }
  }

  Timer {
    interval: root.interval * 1000
    running: root.discovered || root.stat === "ram" || root.stat === "disk"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // CPU usage is a delta between two samples; take the second one quickly so
  // the widget does not sit empty for a full interval after startup.
  Timer {
    id: warmup
    interval: 500
    onTriggered: root.sampleCpu()
  }

  // WidgetButton is the bar's hover/click surface: the bar overlays each slot
  // with its own pointer area and only forwards presses and tooltips to it.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : row.implicitWidth + 15
    fixedHeight: root.vertical ? column.implicitHeight + 12 : -1
    tooltipText: root.tooltipText
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) { root.cycleView(); return }
      var right = mouseButton === Qt.RightButton
      var cmd = String(root.setting(right ? "onRightClick" : "onMiddleClick",
        right ? "omarchy-launch-or-focus-tui btop" : ""))
      if (root.bar && cmd) root.bar.run(cmd)
    }

    Row {
      id: row
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: 5

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        color: root.fg
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: root.iconSize
        renderType: Text.NativeRendering
      }

      // Values are drawn as separate pieces with a thin rule between them, so
      // the gap around the separator is not a full monospace space.
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Number(root.setting("separatorGap", 4))

        Repeater {
          model: {
            var out = []
            for (var i = 0; i < root.shownValues.length; i++) {
              if (i > 0) out.push("|")
              out.push(root.shownValues[i])
            }
            return out
          }

          Item {
            readonly property bool isSep: modelData === "|"
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: isSep ? 1 : piece.implicitWidth
            implicitHeight: piece.implicitHeight

            Rectangle {
              visible: parent.isSep
              anchors.centerIn: parent
              width: 1
              height: Math.round(root.fontSize * 0.85)
              color: root.fg
              opacity: 0.5
            }

            Text {
              id: piece
              visible: !parent.isSep
              text: parent.isSep ? " " : modelData
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.fontSize
              renderType: Text.NativeRendering
            }
          }
        }
      }
    }

    Column {
      id: column
      visible: root.vertical
      anchors.centerIn: parent
      spacing: 2

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.icon
        color: root.fg
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: root.iconSize
        renderType: Text.NativeRendering
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.shownValues.length > 0
        text: root.shownValues.length > 0 ? root.shownValues[0] : ""
        color: root.fg
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Math.round(root.fontSize * 0.85)
        renderType: Text.NativeRendering
      }
    }
  }
}
