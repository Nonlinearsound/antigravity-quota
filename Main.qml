import QtQuick
import Quickshell
import Quickshell.Io

// Background data controller for kniffo.antigravity-quota.
// Hydrates instantly from disk cache at shell startup, refreshes periodically
// via scripts/fetch_quota.py, and retries promptly after transient offline states.
Item {
  id: root
  visible: false

  property var settings: ({})

  property bool ready: false
  property bool refreshing: false
  property bool stale: false
  property bool retryAdvised: false
  property string statusText: ""
  property string helpText: ""

  property string planName: "Google AI"
  property string planBadge: ""
  property string planDescription: ""
  property var headline: null
  property var groups: []
  property var credits: ({
    available: false,
    remainingCredits: 0,
    useG1Credits: false,
    upgradeUri: "https://one.google.com/ai/credits"
  })
  property var localActivity: ({
    hasActivity: false,
    todayPrompts: 0,
    todaySessions: 0,
    todayTokens: 0,
    weekTokens: 0,
    totalPrompts: 0,
    totalSessions: 0,
    totalTokens: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheTokens: 0,
    recentDays: []
  })
  property string fetchedAt: ""
  property double fetchedAtMs: 0

  property string lastCacheText: ""
  property bool pendingForce: false
  property bool queuedRefresh: false

  readonly property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)))
  readonly property string cliPath: String(setting("cliPath", "")).trim()

  readonly property string scriptPath: pathFromUrl(Qt.resolvedUrl("scripts/fetch_quota.py"))
  readonly property string cachePath: {
    var base = Quickshell.env("XDG_CACHE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "/tmp") + "/.cache"
    return base + "/omarchy/antigravity-quota/display-state.json"
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) return decodeURIComponent(value.substring(7))
    return value
  }

  FileView {
    id: stateCacheFile
    path: root.cachePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var raw = String(text() || "")
      if (raw !== "") {
        root.lastCacheText = raw
        root.applyPayload(raw, false)
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    id: retryTimer
    interval: 30000
    repeat: false
    onTriggered: root.refresh(true)
  }

  Process {
    id: collectorProcess
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(text, true)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "")
          console.warn("antigravity-quota:", text.trim())
      }
    }

    onExited: {
      root.refreshing = false
      if (root.queuedRefresh) {
        let forceNext = root.pendingForce
        root.queuedRefresh = false
        root.pendingForce = false
        root.refresh(forceNext)
      }
    }
  }

  function refresh(force) {
    var wantForce = force === true
    if (collectorProcess.running) {
      root.queuedRefresh = true
      if (wantForce) root.pendingForce = true
      return
    }

    var cmd = ["/usr/bin/python3", root.scriptPath]
    if (wantForce) cmd.push("--force")
    if (root.cliPath !== "") {
      cmd.push("--cli-path")
      cmd.push(root.cliPath)
    }

    root.refreshing = true
    collectorProcess.command = cmd
    collectorProcess.running = true
  }

  function applyPayload(rawText, persistToDisk) {
    var trimmed = String(rawText || "").trim()
    if (trimmed === "") return

    try {
      let data = JSON.parse(trimmed)
      if (!data || typeof data !== "object") return

      root.ready = data.ready === true
      root.stale = data.stale === true
      root.retryAdvised = data.retryAdvised === true
      root.statusText = String(data.statusText || "")
      root.helpText = String(data.helpText || "")

      root.planName = String(data.planName || "Google AI")
      root.planBadge = String(data.planBadge || "")
      root.planDescription = String(data.planDescription || "")
      root.headline = data.headline || null
      root.groups = Array.isArray(data.groups) ? data.groups : []
      root.credits = data.credits && typeof data.credits === "object" ? data.credits : ({
        available: false,
        remainingCredits: 0,
        useG1Credits: false,
        upgradeUri: "https://one.google.com/ai/credits"
      })
      root.localActivity = data.localActivity && typeof data.localActivity === "object" ? data.localActivity : ({
        hasActivity: false,
        todayPrompts: 0,
        todaySessions: 0,
        todayTokens: 0,
        weekTokens: 0,
        totalPrompts: 0,
        totalSessions: 0,
        totalTokens: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheTokens: 0,
        recentDays: []
      })
      root.fetchedAt = String(data.fetchedAt || "")
      root.fetchedAtMs = Number(data.fetchedAtMs || 0)

      if (root.retryAdvised) retryTimer.restart()
      else retryTimer.stop()

      if (persistToDisk && root.ready && trimmed !== root.lastCacheText) {
        root.lastCacheText = trimmed
        try { stateCacheFile.setText(trimmed + "\n") } catch (e) {}
      }
    } catch (err) {
      root.statusText = "Quota parser error"
      root.helpText = String(err)
      console.warn("antigravity-quota: failed to parse JSON:", err)
    }
  }

  function formatTokenCount(n) {
    var val = Number(n || 0)
    if (!isFinite(val) || val <= 0) return "0"
    if (val >= 1e9) return (val / 1e9).toFixed(1) + "B"
    if (val >= 1e6) return (val / 1e6).toFixed(1) + "M"
    if (val >= 1e3) return (val / 1e3).toFixed(1) + "K"
    return String(Math.round(val))
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var totalMinutes = Math.floor(ms / 60000)
    var days = Math.floor(totalMinutes / (60 * 24))
    var hours = Math.floor((totalMinutes % (60 * 24)) / 60)
    var minutes = totalMinutes % 60
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + minutes + "m"
    return Math.max(1, minutes) + "m"
  }

  function formatResetClock(isoString, nowMs) {
    if (!isoString) return ""
    var dt = new Date(String(isoString))
    if (isNaN(dt.getTime())) return ""
    var now = new Date(nowMs)
    var hh = String(dt.getHours()).padStart(2, "0")
    var mm = String(dt.getMinutes()).padStart(2, "0")
    var diffMs = dt.getTime() - nowMs
    if (diffMs <= 24 * 3600 * 1000 && dt.getDate() === now.getDate()) {
      return "today " + hh + ":" + mm
    }
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    return days[dt.getDay()] + " " + months[dt.getMonth()] + " " + dt.getDate() + ", " + hh + ":" + mm
  }

  function formatUpdatedAgo(fetchedMs, nowMs) {
    if (!(fetchedMs > 0)) return ""
    var elapsedSec = Math.max(0, Math.floor((nowMs - fetchedMs) / 1000))
    if (elapsedSec < 30) return "Updated just now"
    if (elapsedSec < 3600) return "Updated " + Math.floor(elapsedSec / 60) + "m ago"
    return "Updated " + Math.floor(elapsedSec / 3600) + "h ago"
  }
}
