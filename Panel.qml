import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget + popup for configurable mice. The widget is the whole plugin:
// the bar mounts this file, and the popup lives inside it, the same shape the
// first-party Tailscale widget uses.
//
// The icon hides itself when no configurable mouse is present, so on a laptop
// with no supported mouse the bar looks exactly as it did before.
Panel {
  id: root
  moduleName: "io.github.enoret.mousekit"
  ipcTarget: "io.github.enoret.mousekit"
  manageIpc: false

  // The helper script is addressed relative to this file so the plugin works
  // from any directory name and never needs to be on PATH.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    while (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)

  readonly property bool alwaysShow: setting("alwaysShow", false) === true
  readonly property string statusMessage: Model.statusMessage(mouse.status, mouse.lastError)
  readonly property string statusHint: Model.statusHint(mouse.status)

  // Slider end labels always read in DPI, whichever way the slider is driven.
  readonly property int dpiFloor: mouse.dpiByIndex ? mouse.supportedDpis[0] : mouse.dpiBounds.min
  readonly property int dpiCeiling: mouse.dpiByIndex
    ? mouse.supportedDpis[mouse.supportedDpis.length - 1]
    : mouse.dpiBounds.max

  // While the slider is being dragged the hero pill previews the value it
  // would land on, so the number moves with the thumb instead of only after
  // release — the drag is otherwise silent, since the write waits for release.
  readonly property int previewDpi: dpiSlider && dpiSlider.dragging
    ? mouse.dpiAtIndex(dpiSlider.liveValue)
    : mouse.activeDpi

  readonly property string tooltip: mouse.available
    ? (mouse.activeDpi + " DPI" + (mouse.reportRate > 0 ? " · " + mouse.reportRate + " Hz" : "")
       + " · " + Model.shortDeviceName(mouse.deviceName))
    : statusMessage

  // ---- keyboard cursor ----------------------------------------------------
  //
  // One flat list of rows drives j/k. h/l then acts *within* the current row,
  // which is what keeps the DPI presets and polling rates readable as
  // horizontal chip strips instead of exploding into one row per chip.
  readonly property var navRows: {
    var rows = []
    if (!mouse.available) return rows
    if (mouse.resolutions.length > 0) rows.push("slots")
    if (mouse.activeDpi > 0) rows.push("dpi")
    if (mouse.supportedRates.length > 1) rows.push("rates")
    for (var i = 0; i < mouse.buttons.length; i++) rows.push("button:" + i)
    return rows
  }

  property int cursorIndex: 0
  property bool cursorActive: false
  property int slotChip: 0
  property int rateChip: 0
  property bool chooserOpen: false

  readonly property string cursorRow: cursorIndex >= 0 && cursorIndex < navRows.length ? navRows[cursorIndex] : ""

  function rowHasCursor(row) {
    return cursorActive && cursorRow === row
  }

  function focusRow(row) {
    var position = navRows.indexOf(row)
    if (position === -1) return
    cursorActive = true
    cursorIndex = position
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (navRows.length === 0) return

    if (dy !== 0) {
      cursorIndex = Math.max(0, Math.min(navRows.length - 1, cursorIndex + dy))
      scrollCursorIntoView()
      return
    }
    if (dx === 0) return

    if (cursorRow === "slots") {
      slotChip = Math.max(0, Math.min(mouse.resolutions.length - 1, slotChip + dx))
    } else if (cursorRow === "rates") {
      rateChip = Math.max(0, Math.min(mouse.supportedRates.length - 1, rateChip + dx))
    } else if (cursorRow === "dpi") {
      mouse.stepDpi(dx)
    }
  }

  function activateCursor() {
    if (cursorRow === "slots") {
      var resolution = mouse.resolutions[slotChip]
      if (resolution && !resolution.disabled) mouse.setActiveResolution(resolution.index)
    } else if (cursorRow === "rates") {
      mouse.setReportRate(mouse.supportedRates[rateChip])
    } else if (cursorRow.indexOf("button:") === 0) {
      openButtonChooser(parseInt(cursorRow.substring(7), 10))
    }
  }

  function openButtonChooser(index) {
    if (!buttonColumn || index < 0 || index >= buttonColumn.children.length) return
    var row = buttonColumn.children[index]
    if (row && row.openChooser) row.openChooser()
  }

  function clampCursor() {
    if (cursorIndex >= navRows.length) cursorIndex = Math.max(0, navRows.length - 1)
    if (slotChip >= mouse.resolutions.length) slotChip = Math.max(0, mouse.resolutions.length - 1)
    if (rateChip >= mouse.supportedRates.length) rateChip = Math.max(0, mouse.supportedRates.length - 1)
  }

  function syncChipsToDevice() {
    // Follow the device when it changes underneath us (an onboard DPI button,
    // another tool), but never while the user is steering with the keyboard.
    if (cursorActive) return
    var active = mouse.activeResolutionIndex
    for (var i = 0; i < mouse.resolutions.length; i++) {
      if (mouse.resolutions[i].index === active) { slotChip = i; break }
    }
    var rate = mouse.supportedRates.indexOf(mouse.reportRate)
    if (rate !== -1) rateChip = rate
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (cursorRow.indexOf("button:") !== 0) return
    var index = parseInt(cursorRow.substring(7), 10)
    if (buttonColumn && index >= 0 && index < buttonColumn.children.length) {
      scrollItemIntoView(buttonColumn.children[index])
    }
  }

  // ---- bar slot -----------------------------------------------------------

  visible: mouse.available || alwaysShow
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    mouse.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onNavRowsChanged: clampCursor()
  onCursorIndexChanged: scrollCursorIntoView()

  Service {
    id: mouse
    helperPath: root.pluginDir + "/bin/mousekit"
    settings: root.settings

    onResolutionsChanged: root.syncChipsToDevice()
    onReportRateChanged: root.syncChipsToDevice()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { mouse.refresh(); return "ok" }
    function status(): string { return root.tooltip }
    function dpi(value: string): string {
      var n = parseInt(value, 10)
      if (!isFinite(n)) return "usage: dpi <value>"
      mouse.setDpi(n)
      return "ok"
    }
    function cycleDpi(): string { mouse.cycleResolution(1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: mouse.available ? "󰍽" : "󰍾"
    tooltipText: root.tooltip
    foreground: mouse.available ? root.barForeground : Qt.darker(root.barForeground, 1.6)

    onPressed: function(buttonCode) {
      // Right click is the DPI button this mouse may not have: it walks the
      // enabled presets without opening anything.
      if (buttonCode === Qt.RightButton) mouse.cycleResolution(1)
      else if (buttonCode === Qt.MiddleButton) mouse.refresh()
      else root.toggle()
    }
    onWheelMoved: function(delta) { mouse.stepDpi(delta > 0 ? 1 : -1) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.chooserOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") mouse.refresh()
        else if (t === "n" || t === "N") mouse.nextDevice()
        else if (t === "c" || t === "C") mouse.cycleResolution(1)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: mouse.available ? Model.shortDeviceName(mouse.deviceName) : "Mouse"
            meta: mouse.available ? root.heroMeta() : "No device"
            detail: root.previewDpi > 0 ? (root.previewDpi + " DPI") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: mouse.available ? 1.0 : 0.5

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: mouse.available ? "󰍽" : "󰍾"
                color: mouse.available ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            // Only earns its place with a second mouse plugged in; one device
            // needs no switcher.
            trailingControl: Component {
              PanelActionButton {
                visible: mouse.devices.length > 1
                iconText: "󰑖"
                tooltipText: "Next device"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: mouse.nextDevice()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: mouse.actionStatus !== "" ? mouse.actionStatus : mouse.lastError
            color: mouse.lastError !== "" && mouse.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---- guidance card, shown instead of the controls ---------------

          CursorSurface {
            visible: !mouse.available
            width: parent.width
            implicitHeight: guidance.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Column {
              id: guidance
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.statusMessage
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Text {
                textFormat: Text.PlainText
                visible: root.statusHint !== ""
                width: parent.width
                text: root.statusHint
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          // ---- sensitivity -------------------------------------------------

          PanelSeparator {
            visible: mouse.available && mouse.resolutions.length > 0
            foreground: root.foreground
          }

          Column {
            visible: mouse.available && mouse.resolutions.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SENSITIVITY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              id: slotFlow
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: mouse.resolutions

                Chip {
                  required property var modelData
                  required property int index
                  label: modelData.disabled ? "off" : String(modelData.dpi)
                  enabled: !modelData.disabled
                  current: modelData.active
                  hasCursor: root.rowHasCursor("slots") && root.slotChip === index
                  onEntered: { root.focusRow("slots"); root.slotChip = index }
                  onChosen: mouse.setActiveResolution(modelData.index)
                }
              }
            }

            // Retunes the preset the mouse is currently on. Writing on release
            // (not on every drag frame) keeps one ratbagctl call per gesture.
            CursorSurface {
              width: parent.width
              visible: mouse.activeDpi > 0
              hasCursor: root.rowHasCursor("dpi")
              foreground: root.foreground
              implicitHeight: dpiRow.implicitHeight + Style.spacing.lg

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onContainsMouseChanged: if (containsMouse) root.focusRow("dpi")
              }

              RowLayout {
                id: dpiRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  text: String(root.dpiFloor)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.alignment: Qt.AlignVCenter
                }

                PanelSlider {
                  id: dpiSlider
                  bar: root.bar
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  integer: true
                  minimum: mouse.dpiByIndex ? 0 : mouse.dpiBounds.min
                  maximum: mouse.dpiByIndex ? mouse.supportedDpis.length - 1 : mouse.dpiBounds.max
                  step: mouse.dpiByIndex ? 1 : mouse.dpiBounds.step
                  value: mouse.dpiByIndex ? mouse.dpiIndex : mouse.activeDpi
                  onMoved: function(next) { root.focusRow("dpi") }
                  onReleased: function(next) { mouse.setDpi(mouse.dpiAtIndex(next)) }
                }

                Text {
                  textFormat: Text.PlainText
                  text: String(root.dpiCeiling)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.alignment: Qt.AlignVCenter
                }
              }
            }
          }

          // ---- polling rate ------------------------------------------------

          PanelSeparator {
            visible: mouse.available && mouse.supportedRates.length > 1
            foreground: root.foreground
          }

          Column {
            visible: mouse.available && mouse.supportedRates.length > 1
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "POLLING RATE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: mouse.supportedRates

                Chip {
                  required property var modelData
                  required property int index
                  label: modelData + " Hz"
                  current: modelData === mouse.reportRate
                  hasCursor: root.rowHasCursor("rates") && root.rateChip === index
                  onEntered: { root.focusRow("rates"); root.rateChip = index }
                  onChosen: mouse.setReportRate(modelData)
                }
              }
            }
          }

          // ---- buttons -----------------------------------------------------

          PanelSeparator {
            visible: mouse.available && mouse.buttons.length > 0
            foreground: root.foreground
          }

          Column {
            visible: mouse.available && mouse.buttons.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "BUTTONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: buttonColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: mouse.buttons

                ButtonRow {
                  required property var modelData
                  required property int index
                  width: buttonColumn.width
                  info: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  function heroMeta() {
    var parts = []
    var vendor = Model.vendorOf(mouse.deviceName)
    if (vendor !== "") parts.push(vendor)
    if (mouse.buttonCount > 0) parts.push(mouse.buttonCount + " buttons")
    if (mouse.reportRate > 0) parts.push(mouse.reportRate + " Hz")
    return parts.join(" · ")
  }

  // ---- components ---------------------------------------------------------

  // Compact selectable pill used for both DPI presets and polling rates.
  component Chip: CursorSurface {
    id: chip

    property string label: ""
    signal chosen()
    signal entered()

    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    bordered: true
    opacity: enabled ? 1.0 : 0.4

    implicitWidth: chipText.implicitWidth + Style.space(20)
    implicitHeight: Math.max(Style.spacing.controlHeight, chipText.implicitHeight + Style.space(10))

    Text {
      id: chipText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: chip.label
      color: chip.current ? root.foreground : Qt.darker(root.foreground, 1.2)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: chip.current
    }

    MouseArea {
      anchors.fill: parent
      enabled: chip.enabled
      hoverEnabled: true
      cursorShape: chip.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: chip.entered()
      onClicked: chip.chosen()
    }
  }

  // One physical mouse button and what it currently does. Clicking anywhere on
  // the row opens the action chooser.
  component ButtonRow: CursorSurface {
    id: buttonRow

    property var info: null
    property int rowIndex: 0

    readonly property string mappingLabel: info ? String(info.label || "Unmapped") : "Unmapped"
    readonly property bool remapped: info && (info.kind === "special" || info.kind === "macro" || info.kind === "key")

    function openChooser() {
      chooserPopup.open()
    }

    hasCursor: root.rowHasCursor("button:" + rowIndex)
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: buttonRowInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow("button:" + buttonRow.rowIndex)
      onClicked: buttonRow.openChooser()
    }

    RowLayout {
      id: buttonRowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "󰍽"
        color: buttonRow.remapped ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        text: "Button " + (buttonRow.info ? buttonRow.info.index : buttonRow.rowIndex)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.alignment: Qt.AlignVCenter
      }

      Item { Layout.fillWidth: true }

      Text {
        textFormat: Text.PlainText
        text: buttonRow.mappingLabel
        color: buttonRow.remapped ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        Layout.maximumWidth: Style.space(170)
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        text: "󰅂"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }

    Popup {
      id: chooserPopup
      x: 0
      y: buttonRow.height + Style.space(4)
      width: Math.max(Style.space(280), buttonRow.width)
      height: Math.min(Style.space(320), chooserList.contentHeight + Style.space(2))
      padding: 0
      modal: false
      focus: true
      closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

      property int choiceIndex: 0

      // Built once per open so the "keep current" entry reflects the mapping
      // the device reports right now.
      readonly property var choices: {
        var options = [{ header: "DPI & WHEEL" }]
        for (var s = 0; s < Model.SPECIAL_ACTIONS.length; s++) {
          options.push({
            label: Model.SPECIAL_ACTIONS[s].label,
            detail: Model.SPECIAL_ACTIONS[s].value,
            kind: "special",
            value: Model.SPECIAL_ACTIONS[s].value
          })
        }
        options.push({ header: "MOUSE BUTTONS" })
        for (var b = 0; b < Model.REMAPPABLE_BUTTONS.length; b++) {
          var target = Model.REMAPPABLE_BUTTONS[b]
          options.push({
            label: Model.mouseButtonLabel(target),
            detail: "button " + target,
            kind: "button",
            value: String(target)
          })
        }
        options.push({ header: "KEYBOARD" })
        for (var m = 0; m < Model.MACRO_PRESETS.length; m++) {
          options.push({
            label: Model.MACRO_PRESETS[m].label,
            detail: Model.MACRO_PRESETS[m].keys.join(" "),
            kind: "macro",
            value: Model.MACRO_PRESETS[m].keys
          })
        }
        return options
      }

      function firstSelectable() {
        for (var i = 0; i < choices.length; i++) if (!choices[i].header) return i
        return 0
      }

      function moveChoice(delta) {
        var next = choiceIndex
        for (var guard = 0; guard < choices.length; guard++) {
          next += delta
          if (next < 0 || next >= choices.length) return
          if (!choices[next].header) { choiceIndex = next; chooserList.positionViewAtIndex(next, ListView.Contain); return }
        }
      }

      function chooseCurrent() {
        var choice = choices[choiceIndex]
        if (!choice || choice.header) return
        mouse.setButtonAction(buttonRow.info ? buttonRow.info.index : buttonRow.rowIndex, choice.kind, choice.value)
        close()
      }

      onOpenedChanged: {
        root.chooserOpen = opened
        if (opened) {
          choiceIndex = firstSelectable()
          Qt.callLater(function() { chooserList.forceActiveFocus() })
        } else if (root.opened) {
          Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
      }

      background: BorderSurface {
        color: Color.popups.background
        borderSpec: Border.flat(root.dim, 1)
        radius: Style.cornerRadius
      }

      contentItem: ListView {
        id: chooserList
        clip: true
        focus: true
        model: chooserPopup.choices
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            chooserPopup.close(); event.accepted = true; return
          }
          if (event.key === Qt.Key_Down || event.text === "j") {
            chooserPopup.moveChoice(1); event.accepted = true; return
          }
          if (event.key === Qt.Key_Up || event.text === "k") {
            chooserPopup.moveChoice(-1); event.accepted = true; return
          }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            chooserPopup.chooseCurrent(); event.accepted = true
          }
        }

        // One delegate covering both row shapes: a ListView delegate must set
        // `height` (implicitHeight is not read), and swapping in a Loader
        // would collide with Loader's default `sourceComponent` property.
        delegate: Item {
          id: choiceItem
          required property var modelData
          required property int index

          readonly property bool isHeader: !!modelData.header

          width: chooserList.width
          height: isHeader ? Style.space(26) : Style.space(38)

          PanelSectionHeader {
            visible: choiceItem.isHeader
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            text: choiceItem.isHeader ? choiceItem.modelData.header : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          CursorSurface {
            visible: !choiceItem.isHeader
            anchors.fill: parent
            radius: 0
            foreground: root.foreground
            fill: root.hoverFill
            hasCursor: chooserPopup.choiceIndex === choiceItem.index

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                text: choiceItem.isHeader ? "" : String(choiceItem.modelData.label)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.alignment: Qt.AlignVCenter
              }

              Item { Layout.fillWidth: true }

              Text {
                textFormat: Text.PlainText
                text: choiceItem.isHeader ? "" : String(choiceItem.modelData.detail)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
                horizontalAlignment: Text.AlignRight
                Layout.maximumWidth: Style.space(150)
                Layout.alignment: Qt.AlignVCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: chooserPopup.choiceIndex = choiceItem.index
              onClicked: {
                chooserPopup.choiceIndex = choiceItem.index
                chooserPopup.chooseCurrent()
              }
            }
          }
        }
      }
    }
  }
}
