// Exercises Model.js against ratbagctl output shaped exactly as
// tools/ratbagctl.body.py prints it (print_device / print_profile /
// print_resolution / print_button).
const fs = require("fs")
const path = require("path").join(__dirname, "Model.js")
const M = {}
new Function("exports", fs.readFileSync(path, "utf8") + "\n;Object.assign(exports, {splitProbe,parseInfo,parseLive,mergeDevice,parseNumberList,parseButtonLine,parseResolutionLine,snapDpi,dpiBounds,activeResolutionIndex,nextResolutionIndex,shortDeviceName,vendorOf,statusMessage,mouseButtonLabel,specialLabel,enabledResolutions});")(M)

const info = [
"singing-gundi - Logitech G Pro X Superlight",
"             Model: usb:046d:c094:0",
"       Device Type: Mouse",
"  Firmware version: 1",
" Number of Buttons: 5",
"    Number of Leds: 0",
"Number of Profiles: 1",
"Profile 0: (active)",
"  Name: n/a",
"  Report Rate: 1000Hz",
"  Resolutions:",
"    0: 400dpi",
"    1: 800dpi (active) (default)",
"    2: 1600dpi",
"    3: 3200dpi",
"    4: <disabled>",
"  Angle Snapping: False",
"  Debounce time: 4ms",
"  Button: 0 is mapped to 'button 1'",
"  Button: 1 is mapped to 'button 3'",
"  Button: 2 is mapped to 'button 2'",
"  Button: 3 is mapped to 'resolution-cycle-up'",
"  Button: 4 is mapped to macro 'KEY_LEFTCTRL+KEY_C'",
"  Button: 5 is mapped to key 'KEY_F13'",
"  Button: 6 is mapped to none",
].join("\n")

const probe = [
"STATUS=ok",
"DEVICE=singing-gundi",
"DEVICES=singing-gundi\tLogitech G Pro X Superlight",
"DEVICES=noisy-tapir\tRazer DeathAdder V2",
"--INFO--",
info,
"--DPIS--",
"100 150 200 400 800 1600 3200 6400 25600",
"--RATES--",
"125 250 500 1000",
"--END--",
].join("\n")

let failures = 0
function check(label, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected)
  if (a !== e) { failures++; console.log(`FAIL ${label}\n  got      ${a}\n  expected ${e}`) }
  else console.log(`ok   ${label} = ${a}`)
}

const parsed = M.splitProbe(probe)
check("status", parsed.status, "ok")
check("device", parsed.device, "singing-gundi")
check("devices", parsed.devices.map(d => d.id), ["singing-gundi", "noisy-tapir"])
check("device name", parsed.devices[0].name, "Logitech G Pro X Superlight")

const d = M.parseInfo(parsed.info)
check("name", d.name, "Logitech G Pro X Superlight")
check("model", d.model, "usb:046d:c094:0")
check("firmware", d.firmware, "1")
check("buttonCount", d.buttonCount, 5)
check("reportRate", d.reportRate, 1000)
check("profileIndex", d.profileIndex, 0)
check("resolution dpis", d.resolutions.map(r => r.dpi), [400, 800, 1600, 3200, 0])
check("resolution disabled", d.resolutions.map(r => r.disabled), [false, false, false, false, true])
check("active resolution", M.activeResolutionIndex(d.resolutions), 1)
check("enabled count", M.enabledResolutions(d.resolutions).length, 4)
check("button kinds", d.buttons.map(b => b.kind), ["button", "button", "button", "special", "macro", "key", "none"])
// libratbag numbers targets in evdev BTN_* order, so 'button 2' is BTN_RIGHT
// and 'button 3' is BTN_MIDDLE — the reverse of X11. Confirmed against a
// Logitech PRO X, whose physical right button ships mapped to 'button 2'.
check("button labels", d.buttons.map(b => b.label),
  ["Left click", "Middle click", "Right click", "Cycle DPI", "KEY_LEFTCTRL+KEY_C", "KEY_F13", "Disabled"])
check("evdev button order", [1, 2, 3, 4, 5].map(M.mouseButtonLabel),
  ["Left click", "Right click", "Middle click", "Side back", "Side forward"])

const dpis = M.parseNumberList(parsed.dpis)
check("dpi list", dpis, [100, 150, 200, 400, 800, 1600, 3200, 6400, 25600])
check("rates", M.parseNumberList(parsed.rates), [125, 250, 500, 1000])
check("snap 1500 -> 1600", M.snapDpi(1500, dpis), 1600)
check("snap 810 -> 800", M.snapDpi(810, dpis), 800)
check("dpiBounds", M.dpiBounds(dpis, d.resolutions), { min: 100, max: 25600, step: 50 })

// Cycling has to skip the disabled slot 4 and wrap from 3 back to 0.
check("cycle from 1", M.nextResolutionIndex(d.resolutions, 1), 2)
const at3 = d.resolutions.map(r => Object.assign({}, r, { active: r.index === 3 }))
check("cycle wraps 3 -> 0", M.nextResolutionIndex(at3, 1), 0)
check("cycle back 3 -> 2", M.nextResolutionIndex(at3, -1), 2)

check("short name", M.shortDeviceName("Logitech G Pro X Superlight"), "G Pro X Superlight")
check("vendor", M.vendorOf("Logitech G Pro X Superlight"), "Logitech")

// Multi-profile device: the (active) profile wins over profile 0.
const multi = [
"pretty-yak - Razer DeathAdder V2",
" Number of Buttons: 8",
"Number of Profiles: 2",
"Profile 0:",
"  Report Rate: 500Hz",
"  Resolutions:",
"    0: 400dpi (active)",
"Profile 1: (active)",
"  Report Rate: 1000Hz",
"  Resolutions:",
"    0: 800dpi",
"    1: 1800dpi (active)",
"  Button: 0 is mapped to 'button 1'",
].join("\n")
const m = M.parseInfo(multi)
check("multi profileIndex", m.profileIndex, 1)
check("multi rate", m.reportRate, 1000)
check("multi active dpi", M.activeResolutionIndex(m.resolutions), 1)

// Separate X/Y resolution formatting.
check("xy resolution", M.parseResolutionLine("2: 1600x900dpi (active)"),
  { index: 2, dpi: 1600, dpiY: 900, active: true, isDefault: false, disabled: false })

// ---- The Logitech PRO X case ------------------------------------------
//
// Real output: 5 profiles, profile 1 flagged "(disabled) (active)". ratbagctl
// prints no body for a disabled profile, so `info` describes profile 0 while
// every bare write lands on profile 1 — and the two hold different values.
// Rendering info's profile there showed 800 DPI on a mouse running at 1600.
// The probe detects this and appends a --LIVE-- section read item by item
// from the active profile; mergeDevice must prefer it.
const proX = [
"STATUS=ok",
"DEVICE=sobbing-rabbit",
"DEVICES=sobbing-rabbit\tLogitech PRO X",
"--INFO--",
"sobbing-rabbit - Logitech PRO X",
"             Model: usb:046d:4093:0",
"       Device Type: Mouse",
" Number of Buttons: 5",
"    Number of Leds: 0",
"Number of Profiles: 5",
"Profile 0:",
"  Name: n/a",
"  Report Rate: 500Hz",
"  Resolutions:",
"    0: 400dpi",
"    1: 800dpi (active) (default)",
"  Button: 0 is mapped to 'button 1'",
"Profile 1: (disabled) (active)",
"Profile 2: (disabled)",
"--LIVE--",
"PROFILE=1",
"RATE=1000",
"BUTTONCOUNT=5",
"0: 400dpi",
"1: 1600dpi (active) (default)",
"2: 3200dpi",
"Button: 0 is mapped to 'button 1'",
"Button: 3 is mapped to 'button 4'",
"--DPIS--",
"100 400 800 1600 3200",
"--RATES--",
"125 250 500 1000",
"--END--",
].join("\n")

const px = M.splitProbe(proX)
const pxInfo = M.parseInfo(px.info)
const pxLive = M.parseLive(px.live)
const pxDevice = M.mergeDevice(pxInfo, pxLive)

check("proX info sees stale profile 0", M.activeResolutionIndex(pxInfo.resolutions), 1)
check("proX info stale dpi", pxInfo.resolutions[1].dpi, 800)
check("proX live present", pxLive.present, true)
check("proX merged profile", pxDevice.profileIndex, 1)
check("proX merged rate", pxDevice.reportRate, 1000)
check("proX merged buttonCount", pxDevice.buttonCount, 5)
// The whole point: the panel must show the ACTIVE profile's 1600, not 800.
check("proX merged dpis", pxDevice.resolutions.map(r => r.dpi), [400, 1600, 3200])
check("proX merged active dpi", pxDevice.resolutions.find(r => r.active).dpi, 1600)
check("proX merged buttons", pxDevice.buttons.map(b => b.label), ["Left click", "Side back"])
// Device identity still comes from info, which --LIVE-- never carries.
check("proX name survives merge", pxDevice.name, "Logitech PRO X")

// A device whose active profile IS shown must not pay for the fallback.
check("no live section", M.parseLive("").present, false)
check("merge without live", M.mergeDevice(d, M.parseLive("")).resolutions.length, 5)

// Degraded probes.
check("nocli", M.statusMessage("nocli", ""), "libratbag is not installed.")
check("nodaemon", M.splitProbe("STATUS=nodaemon\nERR=cannot connect").error, "cannot connect")
check("empty info", M.parseInfo("").resolutions, [])
check("dpiBounds no list", M.dpiBounds([], []), { min: 100, max: 3200, step: 50 })

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`)
process.exit(failures === 0 ? 0 : 1)
