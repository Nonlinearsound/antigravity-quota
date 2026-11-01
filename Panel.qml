import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "kniffo.antigravity-quota"
  ipcTarget: "kniffo.antigravity-quota"
  manageIpc: false

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.48)
  readonly property color surface: Commons.Color.popups.background
  readonly property color cardFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color cardBorder: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.09)
  readonly property color trackColor: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool settingsMode: false
  property var draftSettings: ({})
  property string settingsStatusText: ""
  property bool refreshFlash: false
  property double nowMs: Date.now()

  readonly property string barDisplayMode: {
    var mode = String(setting("barDisplay", "icon")).toLowerCase()
    if (mode === "remaining" || mode === "used" || mode === "both") return mode
    return "icon"
  }
  readonly property string meterMode: {
    var mode = String(setting("meterMode", "used")).toLowerCase()
    return mode === "remaining" ? "remaining" : "used"
  }
  readonly property int warningThresholdPct: clamp(Math.round(Number(setting("warningThresholdPct", 80))), 50, 99)

  readonly property var headline: quota.headline
  readonly property real headlineUsedPct: headline ? Number(headline.usedPct || 0) : 0
  readonly property real headlineRemainingPct: headline ? Number(headline.remainingPct || 100) : 100
  readonly property bool isCritical: quota.ready && headlineUsedPct >= 90
  readonly property bool isWarning: quota.ready && headlineUsedPct >= warningThresholdPct

  readonly property color barIconColor: {
    if (!quota.ready && quota.statusText !== "") return urgent
    if (isCritical) return urgent
    if (isWarning) return accent
    return root.barForeground
  }

  readonly property bool showBarChipText: !root.vertical && root.barDisplayMode !== "icon" && root.barChipText !== ""
  readonly property string barChipText: {
    if (!quota.ready || !headline) return ""
    if (barDisplayMode === "remaining") return String(headline.remainingText || "100%")
    if (barDisplayMode === "used") return String(headline.usedText || "0%")
    if (barDisplayMode === "both") return String(headline.usedText || "0%") + " · " + String(headline.remainingText || "100%")
    return ""
  }

  readonly property string barTooltip: {
    if (quota.refreshing && !quota.ready) return "Google AI Quota · Refreshing…"
    if (!quota.ready) {
      return quota.statusText !== ""
        ? "Google AI Quota · " + quota.statusText
        : "Google AI Quota"
    }
    if (!headline) return quota.planName
    return quota.planName + " · " + headline.usedText + " used · " + headline.remainingText + " left (" + headline.groupName + " " + headline.windowBadge + ")"
  }

  implicitWidth: buttonHost.implicitWidth
  implicitHeight: buttonHost.implicitHeight

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function cloneObject(value, fallback) {
    if (value === undefined || value === null) return fallback
    try { return JSON.parse(JSON.stringify(value)) }
    catch (e) { return fallback }
  }

  function normalizedSettings(source) {
    var next = cloneObject(source, {}) || {}
    var bMode = String(next.barDisplay || "icon").toLowerCase()
    next.barDisplay = (bMode === "remaining" || bMode === "used" || bMode === "both") ? bMode : "icon"

    var mMode = String(next.meterMode || "used").toLowerCase()
    next.meterMode = mMode === "remaining" ? "remaining" : "used"

    var warn = Number(next.warningThresholdPct === undefined ? 80 : next.warningThresholdPct)
    next.warningThresholdPct = Math.round(clamp(isFinite(warn) ? warn : 80, 50, 99))

    var refresh = Number(next.refreshIntervalSec === undefined ? 300 : next.refreshIntervalSec)
    next.refreshIntervalSec = Math.round(clamp(isFinite(refresh) ? refresh : 300, 30, 3600))

    next.cliPath = String(next.cliPath || "").trim()
    return next
  }

  function draftValue(name, fallback) {
    var value = draftSettings ? draftSettings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function setDraftValue(name, value) {
    var next = normalizedSettings(draftSettings)
    next[name] = value
    draftSettings = next
    settingsStatusText = ""
  }

  function canPersistSettings() {
    return !!(bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
  }

  function openSettingsView() {
    draftSettings = normalizedSettings(settings)
    settingsStatusText = ""
    settingsMode = true
    if (!opened) open()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function closeSettingsView() {
    settingsMode = false
    settingsStatusText = ""
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveSettings() {
    var next = normalizedSettings(draftSettings)
    draftSettings = next
    root.settings = next
    if (canPersistSettings()) {
      bar.shell.updateEntryInline(root.moduleName, next)
      settingsStatusText = "Saved to shell.json"
    } else {
      settingsStatusText = "Applied for this session"
    }
    quota.refresh(true)
  }

  function triggerRefresh(force) {
    refreshFlash = true
    refreshFlashTimer.restart()
    quota.refresh(force !== false)
  }

  function openCreditsPortal() {
    var uri = quota.credits && quota.credits.upgradeUri
      ? String(quota.credits.upgradeUri)
      : "https://one.google.com/ai/credits"
    if (uri.indexOf("https://") !== 0) uri = "https://one.google.com/ai/credits"
    if (bar) bar.run("xdg-open '" + uri.replace(/'/g, "'\\''") + "'")
    root.close()
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.RightButton) {
      if (opened && settingsMode) root.close()
      else openSettingsView()
      return
    }
    if (buttonCode === Qt.MiddleButton) {
      triggerRefresh(true)
      return
    }
    if (opened) {
      root.close()
    } else {
      settingsMode = false
      root.open()
    }
  }

  function resetRemainingMs(isoStr) {
    if (!isoStr) return -1
    var ms = new Date(String(isoStr)).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function resetSubtitle(isoStr) {
    var remMs = resetRemainingMs(isoStr)
    if (!(remMs > 0)) return ""
    var rel = "Resets in " + quota.formatDuration(remMs)
    var clk = quota.formatResetClock(isoStr, root.nowMs)
    return clk !== "" ? rel + " · " + clk : rel
  }

  function heroMetaText() {
    if (quota.refreshing || root.refreshFlash) return "Refreshing quota…"
    if (quota.stale && quota.statusText !== "") return quota.statusText + " · cached"
    var updated = quota.formatUpdatedAgo(quota.fetchedAtMs, root.nowMs)
    if (updated !== "") return updated
    if (quota.statusText !== "") return quota.statusText
    return "Google AI Subscription"
  }

  function todayDateString() {
    var d = new Date(root.nowMs)
    return d.getFullYear()
      + "-" + String(d.getMonth() + 1).padStart(2, "0")
      + "-" + String(d.getDate()).padStart(2, "0")
  }

  function shortDayLabel(dateStr) {
    if (String(dateStr) === todayDateString()) return "Today"
    var dt = new Date(String(dateStr) + "T00:00:00")
    if (isNaN(dt.getTime())) return String(dateStr)
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][dt.getDay()]
  }

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      if (panelFlick) panelFlick.contentY = 0
      quota.refresh(false)
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    } else {
      settingsMode = false
    }
  }

  Main {
    id: quota
    settings: root.settings
  }

  Timer {
    id: refreshFlashTimer
    interval: 800
    repeat: false
    onTriggered: root.refreshFlash = false
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): string { root.settingsMode = false; root.open(); return "ok" }
    function close(): string { root.close(); return "ok" }
    function show(): string { root.settingsMode = false; root.open(); return "ok" }
    function hide(): string { root.close(); return "ok" }
    function toggle(): string {
      if (root.opened) root.close()
      else { root.settingsMode = false; root.open() }
      return "ok"
    }
    function refresh(): string { root.triggerRefresh(true); return "ok" }
    function settings(): string { root.openSettingsView(); return "ok" }
  }

  // ------------------------------------------------------------------ bar slot
  Item {
    id: buttonHost
    anchors.fill: parent
    implicitWidth: root.showBarChipText ? chipButton.implicitWidth : iconButton.implicitWidth
    implicitHeight: root.showBarChipText ? chipButton.implicitHeight : iconButton.implicitHeight

    BarIconButton {
      id: iconButton
      visible: !root.showBarChipText
      interactive: !root.showBarChipText
      anchors.fill: parent
      bar: root.bar
      tooltipText: root.barTooltip
      active: root.isCritical
      iconComponent: Component {
        Item {
          GoogleAiIcon {
            anchors.centerIn: parent
            iconSize: Style.space(14)
            color: root.barIconColor
            badgeColor: root.urgent
            warning: root.isWarning
          }
        }
      }
      onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
    }

    Item {
      id: chipButton
      visible: root.showBarChipText
      anchors.fill: parent
      implicitWidth: chipRow.implicitWidth + Style.space(14)
      implicitHeight: root.barSize

      readonly property bool tooltipHovered: visible && chipMouse.containsMouse
      property var registeredBar: null

      function triggerPress(buttonCode) {
        if (root.bar) root.bar.hideTooltip(chipButton)
        root.handleBarPress(buttonCode)
      }

      function syncClickRegistration() {
        if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chipButton)
        registeredBar = root.visible && chipButton.visible ? root.bar : null
        if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(chipButton)
      }

      onVisibleChanged: {
        if (!visible && root.bar) root.bar.hideTooltip(chipButton)
        syncClickRegistration()
      }
      Component.onCompleted: syncClickRegistration()
      Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(chipButton)

      Connections {
        target: root
        function onBarChanged() { chipButton.syncClickRegistration() }
        function onBarTooltipChanged() {
          if (chipButton.tooltipHovered && root.bar) root.bar.showTooltip(chipButton, root.barTooltip)
        }
      }

      Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: Style.space(5)

        GoogleAiIcon {
          anchors.verticalCenter: parent.verticalCenter
          iconSize: Style.space(13)
          color: root.barIconColor
          badgeColor: root.urgent
          warning: root.isWarning
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.barChipText
          color: root.isCritical ? root.urgent : root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      MouseArea {
        id: chipMouse
        anchors.fill: parent
        enabled: chipButton.visible
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (root.bar) root.bar.showTooltip(chipButton, root.barTooltip)
        onExited: if (root.bar) root.bar.hideTooltip(chipButton)
        onClicked: function(mouse) { chipButton.triggerPress(mouse.button) }
      }
    }
  }

  // ------------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: buttonHost
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(396))
    contentHeight: panel.fittedContentHeight(
      (root.settingsMode ? settingsColumn.implicitHeight : dashboardColumn.implicitHeight) + topHeader.implicitHeight + Style.space(14),
      Style.space(650)
    )

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingsMode && settingsView.inputCaptured

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          panelFlick.contentY = root.clamp(
            panelFlick.contentY + dy * Style.space(56),
            0,
            Math.max(0, panelFlick.contentHeight - panelFlick.height)
          )
        }
      }
      onCloseRequested: {
        if (root.settingsMode) root.closeSettingsView()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (!root.settingsMode) root.switchPanel(direction)
      }
      onActivateRequested: {
        if (!root.settingsMode) root.triggerRefresh(true)
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.triggerRefresh(true)
        else if (t === "s" || t === "S") {
          if (root.settingsMode) root.saveSettings()
          else root.openSettingsView()
        } else if (!root.settingsMode && (t === "c" || t === "C")) {
          root.openCreditsPortal()
        }
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        // ---------- Fixed Header ----------
        Item {
          id: topHeader
          width: parent.width
          implicitHeight: root.settingsMode ? settingsHeaderRow.implicitHeight : heroHeader.implicitHeight

          PanelHero {
            id: heroHeader
            visible: !root.settingsMode
            width: parent.width
            title: quota.planName
            detail: quota.planBadge
            meta: root.heroMetaText()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              GoogleAiIcon {
                iconSize: Style.font.display
                color: root.isCritical ? root.urgent : root.foreground
                badgeColor: root.urgent
                warning: root.isWarning
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(6)

                Button {
                  iconText: "󰑐"
                  iconSpinning: quota.refreshing || root.refreshFlash
                  tooltipText: "Refresh quota (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(5)
                  bordered: true
                  onClicked: {
                    root.triggerRefresh(true)
                    keyCatcher.forceActiveFocus()
                  }
                }

                Button {
                  iconText: "󰒓"
                  tooltipText: "Settings (s)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(5)
                  bordered: true
                  onClicked: root.openSettingsView()
                }
              }
            }
          }

          RowLayout {
            id: settingsHeaderRow
            visible: root.settingsMode
            width: parent.width
            spacing: Style.space(8)

            Column {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Google AI Quota"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: "SETTINGS"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }
            }

            Button {
              text: "Back"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              bordered: true
              onClicked: root.closeSettingsView()
            }

            Button {
              text: "Save"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              active: true
              bordered: true
              onClicked: root.saveSettings()
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        // ---------- Scrollable Body ----------
        Flickable {
          id: panelFlick
          width: parent.width
          height: Math.max(0, parent.height - topHeader.implicitHeight - Style.space(22))
          contentWidth: width
          contentHeight: root.settingsMode ? settingsColumn.implicitHeight : dashboardColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          // ==================== DASHBOARD VIEW ====================
          Column {
            id: dashboardColumn
            visible: !root.settingsMode
            width: panelFlick.width
            spacing: Style.space(12)

            // Status / Error Banner
            BorderSurface {
              visible: (!quota.ready && !quota.refreshing) || (quota.helpText !== "" && quota.statusText !== "")
              width: parent.width
              padding: Style.space(12)
              implicitHeight: statusBody.implicitHeight + contentTopInset + contentBottomInset
              color: root.alpha(root.urgent, 0.10)
              borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
              radius: Style.cornerRadius

              Column {
                id: statusBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: parent.contentLeftInset
                anchors.rightMargin: parent.contentRightInset
                anchors.topMargin: parent.contentTopInset
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: quota.statusText !== "" ? quota.statusText : "Quota unavailable"
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  textFormat: Text.PlainText
                  visible: text !== ""
                  width: parent.width
                  text: quota.helpText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

            // Initial Loading Placeholder
            Text {
              textFormat: Text.PlainText
              visible: !quota.ready && quota.refreshing
              width: parent.width
              topPadding: Style.space(20)
              bottomPadding: Style.space(20)
              text: "Fetching your Google AI plan quota…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            // ---------- Primary Summary Card: USED vs LEFT ----------
            BorderSurface {
              id: summaryCard
              visible: quota.ready && !!root.headline
              width: parent.width
              padding: Style.space(12)
              implicitHeight: summaryBody.implicitHeight + contentTopInset + contentBottomInset
              color: root.cardFill
              borderSpec: Border.flat(
                root.isCritical ? root.alpha(root.urgent, 0.45) : root.cardBorder,
                1
              )
              radius: Style.cornerRadius

              Column {
                id: summaryBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: summaryCard.contentLeftInset
                anchors.rightMargin: summaryCard.contentRightInset
                anchors.topMargin: summaryCard.contentTopInset
                spacing: Style.space(10)

                RowLayout {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.headline
                      ? (root.headline.groupName + " · " + root.headline.windowBadge).toUpperCase()
                      : "CURRENT QUOTA"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 0.8
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "TIGHTEST WINDOW"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Dual Big Numbers: USED on left, LEFT on right
                RowLayout {
                  width: parent.width
                  spacing: Style.space(12)

                  Column {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      text: root.headline ? String(root.headline.usedText || "0%") : "0%"
                      color: root.isCritical ? root.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.display
                      font.bold: true
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "USED"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.0
                    }
                  }

                  Rectangle {
                    width: 1
                    Layout.preferredHeight: Style.space(34)
                    color: root.alpha(root.foreground, 0.12)
                  }

                  Column {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: root.headline ? String(root.headline.remainingText || "100%") : "100%"
                      color: root.isCritical ? root.urgent : (root.isWarning ? root.accent : root.foreground)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.display
                      font.bold: true
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: "LEFT"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.0
                    }
                  }
                }

                QuotaMeter {
                  width: parent.width
                  usedFraction: root.headline ? Number(root.headline.usedFraction || 0) : 0
                  remainingFraction: root.headline ? Number(root.headline.remainingFraction || 1) : 1
                  thickness: Style.space(7)
                }

                Text {
                  textFormat: Text.PlainText
                  visible: text !== ""
                  width: parent.width
                  text: root.headline ? root.resetSubtitle(root.headline.resetTime) : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // ---------- All Quota Model Groups ----------
            Column {
              visible: quota.ready && quota.groups.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                width: parent.width
                text: "QUOTA BY MODEL GROUP"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: quota.groups

                GroupCard {
                  required property var modelData
                  width: parent.width
                  group: modelData
                }
              }
            }

            // ---------- Google AI Credits ----------
            PanelSeparator {
              visible: creditsSection.visible
              width: parent.width
              foreground: root.foreground
            }

            Column {
              id: creditsSection
              visible: quota.ready || (quota.credits && quota.credits.available)
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                width: parent.width
                text: "GOOGLE AI CREDITS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              BorderSurface {
                id: creditsCard
                width: parent.width
                padding: Style.space(12)
                implicitHeight: creditsBody.implicitHeight + contentTopInset + contentBottomInset
                color: root.cardFill
                borderSpec: Border.flat(root.cardBorder, 1)
                radius: Style.cornerRadius

                Column {
                  id: creditsBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: creditsCard.contentLeftInset
                  anchors.rightMargin: creditsCard.contentRightInset
                  anchors.topMargin: creditsCard.contentTopInset
                  spacing: Style.space(8)

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(8)

                    Column {
                      Layout.fillWidth: true
                      spacing: Style.space(2)

                      Text {
                        textFormat: Text.PlainText
                        text: "Available G1 Credits"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: quota.credits && quota.credits.useG1Credits
                          ? "Overage fallback: Enabled (useG1Credits)"
                          : "Overage fallback: Off (useG1Credits)"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: String(quota.credits ? Number(quota.credits.remainingCredits || 0) : 0)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                    }

                    Button {
                      text: "Manage ↗"
                      tooltipText: "Open Google AI credits portal (c)"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(8)
                      verticalPadding: Style.space(4)
                      bordered: true
                      onClicked: root.openCreditsPortal()
                    }
                  }
                }
              }
            }

            // ---------- Local Antigravity Token Activity ----------
            PanelSeparator {
              visible: localSection.visible
              width: parent.width
              foreground: root.foreground
            }

            Column {
              id: localSection
              visible: quota.localActivity && quota.localActivity.hasActivity === true
              width: parent.width
              spacing: Style.space(8)

              readonly property var recentDays: quota.localActivity ? (quota.localActivity.recentDays || []) : []
              readonly property real peakTokens: {
                var peak = 1
                for (var i = 0; i < recentDays.length; i++)
                  peak = Math.max(peak, Number(recentDays[i].tokens || 0))
                return peak
              }

              PanelSectionHeader {
                width: parent.width
                text: "LOCAL CLI TOKEN ACTIVITY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              BorderSurface {
                id: localCard
                width: parent.width
                padding: Style.space(12)
                implicitHeight: localBody.implicitHeight + contentTopInset + contentBottomInset
                color: root.cardFill
                borderSpec: Border.flat(root.cardBorder, 1)
                radius: Style.cornerRadius

                Column {
                  id: localBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: localCard.contentLeftInset
                  anchors.rightMargin: localCard.contentRightInset
                  anchors.topMargin: localCard.contentTopInset
                  spacing: Style.space(10)

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(16)

                    MiniStat {
                      value: quota.formatTokenCount(quota.localActivity.todayTokens)
                      label: "today tokens"
                    }
                    MiniStat {
                      value: String(quota.localActivity.todayPrompts || 0)
                      label: "today prompts"
                    }
                    MiniStat {
                      value: quota.formatTokenCount(quota.localActivity.weekTokens)
                      label: "7-day tokens"
                    }
                    Item { Layout.fillWidth: true }
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(5)

                    Repeater {
                      model: localSection.recentDays

                      Item {
                        id: dayRow
                        required property var modelData
                        width: parent.width
                        implicitHeight: Style.space(16)

                        readonly property bool isToday: String(modelData.date) === root.todayDateString()
                        readonly property real dayTokens: Number(modelData.tokens || 0)

                        RowLayout {
                          anchors.fill: parent
                          spacing: Style.space(8)

                          Text {
                            textFormat: Text.PlainText
                            Layout.preferredWidth: Style.space(42)
                            text: root.shortDayLabel(dayRow.modelData.date)
                            color: dayRow.isToday ? root.foreground : root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: dayRow.isToday
                          }

                          Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Style.space(6)
                            radius: height / 2
                            color: root.trackColor

                            Rectangle {
                              anchors.left: parent.left
                              anchors.top: parent.top
                              anchors.bottom: parent.bottom
                              radius: parent.radius
                              width: parent.width * root.clamp(dayRow.dayTokens / localSection.peakTokens, 0, 1)
                              color: dayRow.isToday ? root.foreground : root.alpha(root.foreground, 0.65)
                              Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            }
                          }

                          Text {
                            textFormat: Text.PlainText
                            Layout.preferredWidth: Style.space(48)
                            horizontalAlignment: Text.AlignRight
                            text: quota.formatTokenCount(dayRow.dayTokens)
                            color: dayRow.isToday ? root.foreground : root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: dayRow.isToday
                          }
                        }

                        MouseArea {
                          id: dayHover
                          anchors.fill: parent
                          hoverEnabled: true
                          acceptedButtons: Qt.NoButton
                        }

                        PanelToolTip {
                          visible: dayHover.containsMouse
                          text: String(dayRow.modelData.date) + " · "
                            + quota.formatTokenCount(dayRow.dayTokens) + " tokens · "
                            + Number(dayRow.modelData.prompts || 0) + " prompts"
                        }
                      }
                    }
                  }
                }
              }
            }

            // Footer Hint
            Text {
              textFormat: Text.PlainText
              width: parent.width
              topPadding: Style.space(2)
              bottomPadding: Style.space(4)
              text: "j/k scroll · r refresh · c credits · s settings · esc close"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // ==================== SETTINGS VIEW ====================
          Column {
            id: settingsColumn
            visible: root.settingsMode
            width: panelFlick.width
            spacing: Style.space(12)

            Item {
              id: settingsView
              width: parent.width
              implicitHeight: settingsFields.implicitHeight

              readonly property bool inputCaptured: barDisplayDropdown.popupOpen
                || meterModeDropdown.popupOpen
                || warningThresholdField.field.activeFocus
                || refreshIntervalField.field.activeFocus

              Column {
                id: settingsFields
                width: parent.width
                spacing: Style.space(12)

                BorderSurface {
                  id: displaySettingsCard
                  width: parent.width
                  padding: Style.space(12)
                  implicitHeight: displaySettingsCol.implicitHeight + contentTopInset + contentBottomInset
                  color: root.cardFill
                  borderSpec: Border.flat(root.cardBorder, 1)
                  radius: Style.cornerRadius

                  Column {
                    id: displaySettingsCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: displaySettingsCard.contentLeftInset
                    anchors.rightMargin: displaySettingsCard.contentRightInset
                    anchors.topMargin: displaySettingsCard.contentTopInset
                    spacing: Style.space(12)

                    PanelSectionHeader {
                      width: parent.width
                      text: "DISPLAY"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                    }

                    Dropdown {
                      id: barDisplayDropdown
                      width: parent.width
                      label: "Bar display"
                      value: String(root.draftValue("barDisplay", "icon"))
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      options: [
                        { value: "icon", label: "Sparkle icon only" },
                        { value: "remaining", label: "Icon + % Left" },
                        { value: "used", label: "Icon + % Used" },
                        { value: "both", label: "Icon + Used · Left" }
                      ]
                      onChanged: function(val) { root.setDraftValue("barDisplay", val) }
                    }

                    Dropdown {
                      id: meterModeDropdown
                      width: parent.width
                      label: "Meter bar style"
                      value: String(root.draftValue("meterMode", "used"))
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      options: [
                        { value: "used", label: "Fill upward with % Used" },
                        { value: "remaining", label: "Drain downward with % Left" }
                      ]
                      onChanged: function(val) { root.setDraftValue("meterMode", val) }
                    }
                  }
                }

                BorderSurface {
                  id: thresholdsCard
                  width: parent.width
                  padding: Style.space(12)
                  implicitHeight: thresholdsCol.implicitHeight + contentTopInset + contentBottomInset
                  color: root.cardFill
                  borderSpec: Border.flat(root.cardBorder, 1)
                  radius: Style.cornerRadius

                  Column {
                    id: thresholdsCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: thresholdsCard.contentLeftInset
                    anchors.rightMargin: thresholdsCard.contentRightInset
                    anchors.topMargin: thresholdsCard.contentTopInset
                    spacing: Style.space(12)

                    PanelSectionHeader {
                      width: parent.width
                      text: "ALERTS & POLLING"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                    }

                    NumberField {
                      id: warningThresholdField
                      width: parent.width
                      fieldWidth: parent.width
                      label: "Warning highlight threshold (% used)"
                      value: Number(root.draftValue("warningThresholdPct", 80))
                      from: 50
                      to: 99
                      stepSize: 5
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onModified: function(val) { root.setDraftValue("warningThresholdPct", val) }
                    }

                    NumberField {
                      id: refreshIntervalField
                      width: parent.width
                      fieldWidth: parent.width
                      label: "Background refresh interval (seconds)"
                      value: Number(root.draftValue("refreshIntervalSec", 300))
                      from: 30
                      to: 3600
                      stepSize: 30
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onModified: function(val) { root.setDraftValue("refreshIntervalSec", val) }
                    }
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.settingsStatusText !== ""
              width: parent.width
              text: root.settingsStatusText
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "s save · esc back"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------- reusable pieces

  component GroupCard: BorderSurface {
    id: groupCard
    property var group: null

    padding: Style.space(12)
    implicitHeight: groupCol.implicitHeight + contentTopInset + contentBottomInset
    color: root.cardFill
    borderSpec: Border.flat(root.cardBorder, 1)
    radius: Style.cornerRadius

    Column {
      id: groupCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: groupCard.contentLeftInset
      anchors.rightMargin: groupCard.contentRightInset
      anchors.topMargin: groupCard.contentTopInset
      spacing: Style.space(10)

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: groupCard.group ? String(groupCard.group.name || "") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          width: parent.width
          text: {
            if (!groupCard.group) return ""
            var desc = String(groupCard.group.description || "")
            return desc.replace(/^Models within this group:\s*/i, "")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Repeater {
        model: groupCard.group && groupCard.group.buckets ? groupCard.group.buckets : []

        Column {
          id: bucketItem
          required property var modelData
          required property int index

          width: groupCol.width
          spacing: Style.space(6)

          readonly property real usedPct: Number(modelData.usedPct || 0)
          readonly property bool bucketCritical: usedPct >= 90
          readonly property bool bucketWarning: usedPct >= root.warningThresholdPct

          PanelSeparator {
            visible: bucketItem.index > 0
            width: parent.width
            foreground: root.foreground
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            // Window pill badge (5-Hour / Weekly)
            BorderSurface {
              implicitWidth: badgeLabel.implicitWidth + Style.space(8)
              implicitHeight: badgeLabel.implicitHeight + Style.space(3)
              color: root.alpha(root.foreground, 0.06)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.14), 1)
              radius: Math.max(2, Math.round(Style.cornerRadius * 0.6))

              Text {
                id: badgeLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: String(bucketItem.modelData.windowBadge || "Limit").toUpperCase()
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Item { Layout.fillWidth: true }

            // Explicit Dual Readout: Used + Left
            Text {
              textFormat: Text.PlainText
              text: String(bucketItem.modelData.usedText || "0%") + " used"
              color: bucketItem.bucketCritical ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: bucketItem.usedPct > 0
            }

            Text {
              textFormat: Text.PlainText
              text: "·"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              text: String(bucketItem.modelData.remainingText || "100%") + " left"
              color: bucketItem.bucketCritical
                ? root.urgent
                : (bucketItem.bucketWarning ? root.accent : root.foreground)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          QuotaMeter {
            width: parent.width
            usedFraction: Number(bucketItem.modelData.usedFraction || 0)
            remainingFraction: Number(bucketItem.modelData.remainingFraction || 1)
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.resetSubtitle(bucketItem.modelData.resetTime)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component QuotaMeter: Item {
    id: meter
    property real usedFraction: 0
    property real remainingFraction: 1
    property real thickness: Math.max(Style.space(5), Math.round(Style.spacing.controlHeight * 0.18))

    readonly property bool critical: usedFraction >= 0.90
    readonly property bool warning: usedFraction * 100 >= root.warningThresholdPct
    readonly property real fillRatio: root.meterMode === "remaining"
      ? root.clamp(remainingFraction, 0, 1)
      : root.clamp(usedFraction, 0, 1)

    implicitHeight: thickness

    Rectangle {
      id: track
      anchors.fill: parent
      radius: height / 2
      color: root.trackColor
    }

    Rectangle {
      anchors.left: track.left
      anchors.verticalCenter: track.verticalCenter
      height: track.height
      radius: track.radius
      width: track.width * meter.fillRatio
      color: meter.critical
        ? root.urgent
        : (meter.warning ? root.accent : root.foreground)

      Behavior on width {
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
      }
    }
  }

  component MiniStat: Column {
    property string value: "0"
    property string label: ""
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
