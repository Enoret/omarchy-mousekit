import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Everything the panel knows about the mouse, and the only place that writes
// to it. State arrives as one `mousekit probe` blob; changes go out as one
// `mousekit apply` call each. Both run through bash so the plugin never needs
// to be on PATH or marked executable.
Item {
  id: root

  property string helperPath: ""
  property var settings: ({})

  // "" while the first probe is in flight, then ok / nocli / nodaemon /
  // nodevice / error. The panel renders a guidance card for everything but ok.
  property string status: ""
  property string lastError: ""
  property string actionStatus: ""

  property string deviceId: ""
  property string deviceName: ""
  property string deviceModel: ""
  property string firmware: ""
  property var devices: []

  property var resolutions: []
  property var buttons: []
  property var supportedDpis: []
  property var supportedRates: []
  property int reportRate: 0
  property int buttonCount: 0

  property bool refreshing: false

  // Optimistic DPI while a write is in flight, so dragging the slider moves
  // the hero read-out on the drag rather than a poll later. -1 means "trust
  // whatever the last probe reported".
  property int pendingDpi: -1

  readonly property bool available: status === "ok" && deviceId !== ""
  readonly property bool busy: probeProcess.running || applyProcess.running

  readonly property var activeResolutionObject: Model.activeResolution(resolutions)
  readonly property int activeResolutionIndex: Model.activeResolutionIndex(resolutions)
  readonly property int activeDpi: pendingDpi > 0
    ? pendingDpi
    : (activeResolutionObject ? activeResolutionObject.dpi : 0)
  readonly property var dpiBounds: Model.dpiBounds(supportedDpis, resolutions)

  // Devices report their supported DPI values non-linearly — a PRO X lists 89
  // steps from 100 to 25500, dense below 1000 and sparse above 6000. Driving
  // the slider by list index rather than by DPI gives fine control exactly
  // where the values are dense, instead of burying 400–3200 in the first 12%
  // of the track.
  readonly property bool dpiByIndex: supportedDpis.length > 1
  readonly property int dpiIndex: dpiByIndex
    ? Math.max(0, supportedDpis.indexOf(Model.snapDpi(activeDpi, supportedDpis)))
    : -1

  function dpiAtIndex(position) {
    if (!dpiByIndex) return Math.round(position)
    var i = Math.max(0, Math.min(supportedDpis.length - 1, Math.round(position)))
    return supportedDpis[i]
  }

  readonly property string preferredDevice: String(setting("device", ""))
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 60)), 10)
    if (!isFinite(n)) n = 60
    return Math.max(5, Math.min(3600, n))
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // A refresh asked for while one is already running must not be dropped: on a
  // device that needs the slow per-item path a probe takes ~2s, so the
  // post-write settle refresh routinely lands mid-probe. Dropping it left the
  // panel showing pre-write values with nothing scheduled to correct them.
  property bool _refreshQueued: false

  function refresh() {
    if (helperPath === "") return
    if (probeProcess.running) { _refreshQueued = true; return }
    refreshing = true
    probeProcess.command = ["bash", helperPath, "probe", preferredDevice]
    probeProcess.running = true
    if (!probeWatchdog.running) probeWatchdog.start()
  }

  function applyState(raw) {
    var parsed = Model.splitProbe(raw)
    status = parsed.status === "" ? "error" : parsed.status
    lastError = parsed.error

    if (status !== "ok") {
      deviceId = ""
      deviceName = ""
      deviceModel = ""
      firmware = ""
      devices = parsed.devices
      resolutions = []
      buttons = []
      supportedDpis = []
      supportedRates = []
      reportRate = 0
      buttonCount = 0
      pendingDpi = -1
      return
    }

    // parseInfo describes whichever profile `info` rendered; the --LIVE--
    // section, when the probe had to fall back, describes the one the mouse is
    // actually using. mergeDevice prefers the latter.
    var info = Model.mergeDevice(Model.parseInfo(parsed.info), Model.parseLive(parsed.live))
    deviceId = parsed.device
    devices = parsed.devices
    deviceName = info.name !== "" ? info.name : deviceLabelFor(parsed.device)
    deviceModel = info.model
    firmware = info.firmware
    resolutions = info.resolutions
    buttons = info.buttons
    buttonCount = info.buttonCount
    reportRate = info.reportRate
    supportedDpis = Model.parseNumberList(parsed.dpis)
    supportedRates = Model.parseNumberList(parsed.rates)

    // The device agreed with the optimistic value (or moved somewhere else
    // entirely); either way the probe is now the better source of truth.
    pendingDpi = -1
  }

  function deviceLabelFor(id) {
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id === id) return devices[i].name
    }
    return String(id || "")
  }

  // One in-flight write at a time, with a single-slot queue: a slider release
  // landing on top of a chip click should supersede it, not interleave with it.
  property var _queuedCommand: null

  function run(args, label) {
    if (helperPath === "" || !available) return
    var command = ["bash", helperPath, "apply", deviceId].concat(args)
    if (applyProcess.running) {
      _queuedCommand = { command: command, label: label || "" }
      return
    }
    actionStatus = label || ""
    lastError = ""
    applyProcess.command = command
    applyProcess.running = true
  }

  function setDpi(value) {
    var dpi = Model.snapDpi(value, supportedDpis)
    if (dpi <= 0 || dpi === activeDpi) return
    pendingDpi = dpi
    run(["dpi", String(dpi)], dpi + " DPI")
  }

  function setResolutionDpi(index, value) {
    var dpi = Model.snapDpi(value, supportedDpis)
    if (dpi <= 0) return
    if (index === activeResolutionIndex) pendingDpi = dpi
    run(["resolution-dpi", String(index), String(dpi)], dpi + " DPI")
  }

  function setActiveResolution(index) {
    if (index < 0 || index === activeResolutionIndex) return
    // Repaint the slots from the click rather than the next probe.
    var next = []
    for (var i = 0; i < resolutions.length; i++) {
      var resolution = resolutions[i]
      next.push({
        index: resolution.index,
        dpi: resolution.dpi,
        dpiY: resolution.dpiY,
        active: resolution.index === index,
        isDefault: resolution.isDefault,
        disabled: resolution.disabled
      })
    }
    resolutions = next
    pendingDpi = -1
    run(["resolution", String(index)], "Preset " + (index + 1))
  }

  function cycleResolution(delta) {
    setActiveResolution(Model.nextResolutionIndex(resolutions, delta))
  }

  function stepDpi(delta) {
    var current = activeDpi
    if (current <= 0) return

    // Walk the supported list by entries when there is one, so a step is
    // always a value the device actually accepts.
    if (supportedDpis.length > 1) {
      var position = supportedDpis.indexOf(Model.snapDpi(current, supportedDpis))
      if (position === -1) position = 0
      var next = Math.max(0, Math.min(supportedDpis.length - 1, position + delta))
      setDpi(supportedDpis[next])
      return
    }
    setDpi(current + delta * dpiBounds.step)
  }

  function setReportRate(hz) {
    if (hz <= 0 || hz === reportRate) return
    reportRate = hz
    run(["rate", String(hz)], hz + " Hz")
  }

  function setButtonAction(index, kind, value) {
    var args = ["button", String(index), kind]
    if (kind === "macro") args = args.concat(value)
    else args.push(String(value))
    run(args, "Button " + index)
  }

  function selectDevice(id) {
    if (id === "" || id === deviceId) return
    deviceId = id
    refresh()
  }

  function nextDevice() {
    if (devices.length < 2) return
    var position = 0
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].id === deviceId) { position = i; break }
    }
    selectDevice(devices[(position + 1) % devices.length].id)
  }

  Process {
    id: probeProcess
    running: false
    command: []
    stdout: StdioCollector { id: probeStdout; waitForEnd: true }
    stderr: StdioCollector { id: probeStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      probeWatchdog.stop()
      if (exitCode === 0) {
        root.applyState(String(probeStdout.text || ""))
      } else {
        root.status = "error"
        root.lastError = String(probeStderr.text || "").replace(/\s+/g, " ").trim() || "mousekit probe failed"
      }
      // A probe that started before the last write cannot have seen it.
      if (root._refreshQueued) {
        root._refreshQueued = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: applyProcess
    running: false
    command: []
    stdout: StdioCollector { id: applyStdout; waitForEnd: true }
    stderr: StdioCollector { id: applyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(applyStdout.text || "")
      var errorLine = stdout.match(/^ERR=(.*)$/m)

      if (exitCode === 0 && !errorLine) {
        root.lastError = ""
        actionStatusTimer.restart()
      } else {
        root.pendingDpi = -1
        root.actionStatus = ""
        root.lastError = errorLine
          ? errorLine[1].trim()
          : (String(applyStderr.text || "").replace(/\s+/g, " ").trim() || "ratbagctl rejected that change")
      }
      if (root._queuedCommand) {
        var queued = root._queuedCommand
        root._queuedCommand = null
        root.actionStatus = queued.label
        applyProcess.command = queued.command
        applyProcess.running = true
        return
      }
      // Read back what the device actually settled on, which is not always
      // what was asked for: unsupported DPI values get clamped silently.
      settleTimer.restart()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // ratbagd can take a moment to appear after login, and a mouse can be
    // plugged in later. Poll quickly until something answers, then stop.
    id: startupRamp
    property int ticks: 0
    interval: 3000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.available || ticks >= 10) startupRamp.running = false
      else root.refresh()
    }
  }

  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 1600
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // A probe that never exits would otherwise stop every later refresh,
    // because refresh() skips while one is running.
    id: probeWatchdog
    interval: 10000
    onTriggered: if (probeProcess.running) probeProcess.running = false
  }
}
