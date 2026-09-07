// Pure parsing helpers for `bin/mousekit probe` output. No QML types in here,
// so the whole ratbagctl-shaped surface stays unit-testable with plain JS.
//
// ratbagctl's own man page warns its output format may change; every parser
// below is line-oriented and tolerant, and a line it does not recognise is
// skipped rather than treated as an error.

var SPECIAL_ACTIONS = [
  { value: "resolution-cycle-up", label: "Cycle DPI" },
  { value: "resolution-up", label: "DPI up" },
  { value: "resolution-down", label: "DPI down" },
  { value: "resolution-alternate", label: "Toggle DPI" },
  { value: "resolution-default", label: "Default DPI" },
  { value: "wheel-left", label: "Tilt wheel left" },
  { value: "wheel-right", label: "Tilt wheel right" },
  { value: "doubleclick", label: "Double click" },
  { value: "second-mode", label: "Shift mode" },
  { value: "battery-level", label: "Battery level" }
]

// libratbag numbers button targets in evdev BTN_* order, not X11 order. A
// stock mouse proves it: its physical right button ships mapped to
// 'button 2', and its two side buttons to 'button 4' and 'button 5' — which
// is BTN_RIGHT / BTN_SIDE / BTN_EXTRA, not X11's middle/scroll-up/scroll-down.
// Anything past the named range keeps its number rather than being guessed at.
var BUTTON_NAMES = {
  1: "Left click",
  2: "Right click",
  3: "Middle click",
  4: "Side back",
  5: "Side forward",
  6: "Forward",
  7: "Back",
  8: "Task"
}

// The targets worth offering in the remap menu, in the order a person thinks
// of them. Wider than a 5-button mouse needs, and harmless there.
var REMAPPABLE_BUTTONS = [1, 2, 3, 4, 5]

var MACRO_PRESETS = [
  { label: "Copy", keys: ["+KEY_LEFTCTRL", "KEY_C", "-KEY_LEFTCTRL"] },
  { label: "Paste", keys: ["+KEY_LEFTCTRL", "KEY_V", "-KEY_LEFTCTRL"] },
  { label: "Undo", keys: ["+KEY_LEFTCTRL", "KEY_Z", "-KEY_LEFTCTRL"] },
  { label: "Close window", keys: ["+KEY_LEFTMETA", "KEY_W", "-KEY_LEFTMETA"] },
  { label: "Omarchy menu", keys: ["+KEY_LEFTMETA", "KEY_SPACE", "-KEY_LEFTMETA"] },
  { label: "Next workspace", keys: ["+KEY_LEFTMETA", "KEY_TAB", "-KEY_LEFTMETA"] }
]

function mouseButtonLabel(n) {
  var index = parseInt(String(n), 10)
  if (!isFinite(index)) return "Mouse button"
  return BUTTON_NAMES[index] || ("Mouse button " + index)
}

function specialLabel(name) {
  var value = String(name || "")
  for (var i = 0; i < SPECIAL_ACTIONS.length; i++) {
    if (SPECIAL_ACTIONS[i].value === value) return SPECIAL_ACTIONS[i].label
  }
  // An action this build of libratbag knows but this widget does not: show
  // ratbagctl's own name rather than pretending the button is unmapped.
  return value.replace(/-/g, " ").replace(/^./, function(c) { return c.toUpperCase() })
}

// Split the probe blob into its named sections. Returns raw strings; the
// section parsers below turn each into structured data.
function splitProbe(raw) {
  var result = { status: "", error: "", device: "", devices: [], info: "", live: "", dpis: "", rates: "" }
  var lines = String(raw || "").split("\n")
  var section = ""
  var buffers = { INFO: [], LIVE: [], DPIS: [], RATES: [] }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var marker = line.match(/^--([A-Z]+)--$/)
    if (marker) {
      section = marker[1] === "END" ? "" : marker[1]
      continue
    }
    if (section !== "") {
      if (buffers[section]) buffers[section].push(line)
      continue
    }
    if (line.indexOf("STATUS=") === 0) result.status = line.substring(7).trim()
    else if (line.indexOf("ERR=") === 0) result.error = line.substring(4).trim()
    else if (line.indexOf("DEVICE=") === 0) result.device = line.substring(7).trim()
    else if (line.indexOf("DEVICES=") === 0) {
      var parts = line.substring(8).split("\t")
      var id = String(parts[0] || "").trim()
      if (id !== "") result.devices.push({ id: id, name: String(parts[1] || id).trim() })
    }
  }

  result.info = buffers.INFO.join("\n")
  result.live = buffers.LIVE.join("\n")
  result.dpis = buffers.DPIS.join("\n")
  result.rates = buffers.RATES.join("\n")
  return result
}

// The --LIVE-- section, present only when `info` described the wrong profile
// (see info_shows_active in bin/mousekit). It carries the active profile read
// one item at a time, and takes precedence over anything parseInfo found.
function parseLive(raw) {
  var result = {
    present: false,
    profileIndex: -1,
    reportRate: 0,
    buttonCount: 0,
    resolutions: [],
    buttons: []
  }

  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+/, "").replace(/\s+$/, "")
    if (line === "") continue
    result.present = true

    if (line.indexOf("PROFILE=") === 0) {
      result.profileIndex = parseInt(line.substring(8), 10)
      if (!isFinite(result.profileIndex)) result.profileIndex = -1
      continue
    }
    if (line.indexOf("RATE=") === 0) {
      result.reportRate = parseInt(line.substring(5), 10) || 0
      continue
    }
    if (line.indexOf("BUTTONCOUNT=") === 0) {
      result.buttonCount = parseInt(line.substring(12), 10) || 0
      continue
    }

    var resolution = parseResolutionLine(line)
    if (resolution) { result.resolutions.push(resolution); continue }

    var button = parseButtonLine(line)
    if (button) result.buttons.push(button)
  }

  // A section that arrived but yielded no slots tells us nothing usable;
  // fall back to info rather than blanking the panel.
  if (result.resolutions.length === 0 && result.buttons.length === 0) result.present = false
  return result
}

// Merge what parseInfo saw with the authoritative --LIVE-- read, so callers
// get one device record regardless of which path the probe took.
function mergeDevice(info, live) {
  var device = {
    name: info.name,
    model: info.model,
    firmware: info.firmware,
    buttonCount: info.buttonCount,
    profileIndex: info.profileIndex,
    reportRate: info.reportRate,
    resolutions: info.resolutions,
    buttons: info.buttons
  }
  if (!live || !live.present) return device

  device.resolutions = live.resolutions
  device.buttons = live.buttons
  if (live.profileIndex >= 0) device.profileIndex = live.profileIndex
  if (live.reportRate > 0) device.reportRate = live.reportRate
  if (live.buttonCount > 0) device.buttonCount = live.buttonCount
  else if (live.buttons.length > 0) device.buttonCount = live.buttons.length
  return device
}

function parseNumberList(raw) {
  var values = []
  var tokens = String(raw || "").split(/\s+/)
  for (var i = 0; i < tokens.length; i++) {
    var n = parseInt(tokens[i], 10)
    if (isFinite(n) && n > 0 && values.indexOf(n) === -1) values.push(n)
  }
  values.sort(function(a, b) { return a - b })
  return values
}

// `ratbagctl info` prints every profile; only the active one drives the UI.
// Profiles are delimited by their own "Profile N:" header, so collect the
// lines belonging to each and keep the one flagged (active), else profile 0.
function parseInfo(raw) {
  var result = {
    name: "",
    model: "",
    firmware: "",
    buttonCount: 0,
    profileIndex: 0,
    reportRate: 0,
    resolutions: [],
    buttons: []
  }

  var lines = String(raw || "").split("\n")
  var profiles = []
  var current = null

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\s+$/, "")
    var trimmed = line.replace(/^\s+/, "")
    if (trimmed === "") continue

    var profileHeader = trimmed.match(/^Profile\s+(\d+):(.*)$/)
    if (profileHeader) {
      current = {
        index: parseInt(profileHeader[1], 10),
        active: /\(active\)/.test(profileHeader[2]),
        disabled: /\(disabled\)/.test(profileHeader[2]),
        lines: []
      }
      profiles.push(current)
      continue
    }

    if (current === null) {
      // Device-level header lines, printed before the first profile.
      var deviceHeader = trimmed.match(/^(.+?)\s+-\s+(.+)$/)
      if (deviceHeader && result.name === "" && trimmed.indexOf(":") === -1) {
        result.name = deviceHeader[2].trim()
        continue
      }
      var kv = trimmed.match(/^([A-Za-z ]+):\s*(.*)$/)
      if (!kv) continue
      var key = kv[1].trim()
      if (key === "Model") result.model = kv[2].trim()
      else if (key === "Firmware version") result.firmware = kv[2].trim()
      else if (key === "Number of Buttons") result.buttonCount = parseInt(kv[2], 10) || 0
      continue
    }

    current.lines.push(trimmed)
  }

  var chosen = null
  for (var p = 0; p < profiles.length; p++) {
    if (profiles[p].active && !profiles[p].disabled) { chosen = profiles[p]; break }
  }
  if (chosen === null) {
    for (var q = 0; q < profiles.length; q++) {
      if (!profiles[q].disabled) { chosen = profiles[q]; break }
    }
  }
  if (chosen === null) return result

  result.profileIndex = chosen.index
  var body = chosen.lines
  for (var b = 0; b < body.length; b++) {
    var text = body[b]

    var rate = text.match(/^Report Rate:\s*(\d+)\s*Hz$/i)
    if (rate) { result.reportRate = parseInt(rate[1], 10); continue }

    var resolution = parseResolutionLine(text)
    if (resolution) { result.resolutions.push(resolution); continue }

    var button = parseButtonLine(text)
    if (button) { result.buttons.push(button); continue }
  }

  if (result.buttonCount === 0) result.buttonCount = result.buttons.length
  return result
}

// "1: 800dpi (active) (default)", "2: 1600x1600dpi", "3: <disabled>"
function parseResolutionLine(text) {
  var disabled = String(text).match(/^(\d+):\s*<disabled>$/)
  if (disabled) {
    return { index: parseInt(disabled[1], 10), dpi: 0, active: false, isDefault: false, disabled: true }
  }

  var match = String(text).match(/^(\d+):\s*(\d+)(?:x(\d+))?dpi(.*)$/)
  if (!match) return null

  var flags = match[4] || ""
  return {
    index: parseInt(match[1], 10),
    dpi: parseInt(match[2], 10),
    dpiY: match[3] ? parseInt(match[3], 10) : parseInt(match[2], 10),
    active: /\(active\)/.test(flags),
    isDefault: /\(default\)/.test(flags),
    disabled: /\(disabled\)/.test(flags)
  }
}

// "Button: 0 is mapped to 'button 1'" and its key/macro/special/none variants.
function parseButtonLine(text) {
  var match = String(text).match(/^Button:\s*(\d+)\s+is mapped to\s+(.*)$/)
  if (!match) return null

  var index = parseInt(match[1], 10)
  var rest = match[2].trim()
  var button = { index: index, kind: "unknown", value: "", label: rest }

  if (rest === "none" || rest === "'none'") {
    button.kind = "none"
    button.label = "Disabled"
    return button
  }

  var macro = rest.match(/^macro\s+'(.*)'$/)
  if (macro) {
    button.kind = "macro"
    button.value = macro[1]
    button.label = macro[1] === "" ? "Macro" : macro[1]
    return button
  }

  var key = rest.match(/^key\s+'(.*)'$/)
  if (key) {
    button.kind = "key"
    button.value = key[1]
    button.label = key[1]
    return button
  }

  var quoted = rest.match(/^'(.*)'$/)
  if (quoted) {
    var inner = quoted[1]
    var mouseButton = inner.match(/^button\s+(\d+)$/)
    if (mouseButton) {
      button.kind = "button"
      button.value = mouseButton[1]
      button.label = mouseButtonLabel(mouseButton[1])
      return button
    }
    button.kind = "special"
    button.value = inner
    button.label = specialLabel(inner)
    return button
  }

  return button
}

// The supported-DPI list is the authority on what the device accepts, so a
// slider value is pulled onto the nearest entry before it is written. With no
// list (or a device that reports a bare range) fall back to the raw value.
function snapDpi(value, supported) {
  var target = Math.round(Number(value) || 0)
  if (!supported || supported.length === 0) return target

  var best = supported[0]
  var bestDelta = Math.abs(target - best)
  for (var i = 1; i < supported.length; i++) {
    var delta = Math.abs(target - supported[i])
    if (delta < bestDelta) { best = supported[i]; bestDelta = delta }
  }
  return best
}

function dpiBounds(supported, resolutions) {
  if (supported && supported.length > 1) {
    var step = supported[1] - supported[0]
    return {
      min: supported[0],
      max: supported[supported.length - 1],
      step: step > 0 ? step : 50
    }
  }

  // No usable list: bracket whatever the profile already holds so the slider
  // still has a sane travel instead of collapsing to a point.
  var min = 100
  var max = 3200
  for (var i = 0; i < (resolutions || []).length; i++) {
    var dpi = resolutions[i].dpi
    if (dpi > 0) {
      min = Math.min(min, dpi)
      max = Math.max(max, dpi)
    }
  }
  return { min: min, max: Math.max(max, min + 100), step: 50 }
}

function activeResolution(resolutions) {
  for (var i = 0; i < (resolutions || []).length; i++) {
    if (resolutions[i].active) return resolutions[i]
  }
  return null
}

function activeResolutionIndex(resolutions) {
  var resolution = activeResolution(resolutions)
  return resolution ? resolution.index : -1
}

// Enabled slots only — a disabled slot cannot be made active, so cycling past
// it (bar scroll, right click) has to skip it rather than fail silently.
function enabledResolutions(resolutions) {
  var result = []
  for (var i = 0; i < (resolutions || []).length; i++) {
    if (!resolutions[i].disabled && resolutions[i].dpi > 0) result.push(resolutions[i])
  }
  return result
}

function nextResolutionIndex(resolutions, delta) {
  var enabled = enabledResolutions(resolutions)
  if (enabled.length === 0) return -1

  var position = 0
  for (var i = 0; i < enabled.length; i++) {
    if (enabled[i].active) { position = i; break }
  }
  var next = (position + delta) % enabled.length
  if (next < 0) next += enabled.length
  return enabled[next].index
}

function shortDeviceName(name) {
  // "Logitech G Pro X Superlight" reads better in a 380px hero without the
  // vendor prefix the panel already shows on its own line.
  return String(name || "")
    .replace(/^Logitech\s+(Gaming\s+)?/i, "")
    .replace(/^Razer\s+/i, "")
    .replace(/^SteelSeries\s+/i, "")
    .replace(/\s+Receiver$/i, "")
    .trim()
}

function vendorOf(name) {
  var match = String(name || "").match(/^(Logitech|Razer|SteelSeries|Roccat|Corsair|ASUS|Glorious|Etekcity)\b/i)
  return match ? match[1] : ""
}

function statusMessage(status, error) {
  switch (String(status || "")) {
    case "ok": return ""
    case "nocli": return "libratbag is not installed."
    case "nodaemon": return "The ratbagd service is not running."
    case "nodevice": return "No configurable mouse detected."
    case "error": return error || "ratbagctl returned an error."
    default: return error || "Checking for a configurable mouse…"
  }
}

function statusHint(status) {
  switch (String(status || "")) {
    case "nocli": return "omarchy pkg add libratbag"
    case "nodaemon": return "sudo systemctl enable --now ratbagd"
    case "nodevice": return "Plug in a supported mouse, or check libratbag's device list."
    default: return ""
  }
}
