import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  property var anchorItem: null
  property var host: null
  property var bar: null
  property bool opened: false

  property var projects: []
  property var gitDirty: ({})
  property string busyName: ""
  property string pendingAction: ""
  property int pendingTimeout: 0
  property bool loaded: false

  // Listing problems (DDEV/Docker unreachable, oversized output) and action
  // failures are tracked separately: every successful listing resets
  // listError, so an action failure stored there would vanish within a
  // second of being shown. actionError lives until the next action or a
  // manual refresh.
  property string listError: ""
  property string actionError: ""
  // True when the last listing attempt failed after an earlier success —
  // the cards then show the last known state, which may no longer be true.
  property bool listStale: false
  property bool listGotData: false

  // The git dirty check spawns a git process per running project, so it
  // runs on open, manual refresh, and after actions, plus at most every
  // 30s otherwise — not on every 10s listing poll.
  property bool gitCheckDue: true
  property real lastGitCheck: 0
  readonly property int gitCheckInterval: 30000

  // Sentinel busyName for actions that aren't tied to one project card.
  readonly property string allProjects: "*"

  property string searchText: ""

  // Producer-side ceilings: without these, ddev output flows straight
  // into a QML SplitParser, which buffers unbounded until it sees a split
  // marker. A huge project listing or a verbose/hijacked command could
  // otherwise grow the parser's buffer without limit.
  readonly property int maxListBytes: 5 * 1024 * 1024
  readonly property int maxListProjects: 500
  readonly property int maxFieldLength: 200
  // approot is used functionally as a cwd (cd, git -C), not just displayed,
  // so it gets Linux's own PATH_MAX instead of the display-field cap.
  readonly property int maxPathLength: 4096

  readonly property int runningCount: {
    var n = 0
    for (var i = 0; i < projects.length; i++) if (projects[i].status === "running") n++
    return n
  }
  readonly property int totalCount: projects.length

  // Client-side filter/grouping over the already-capped, already-truncated
  // project list — purely presentational, never touches the producer-side
  // caps in applyListing/listProc.
  readonly property var filteredProjects: {
    var q = root.searchText.trim().toLowerCase()
    if (q === "") return root.projects
    return root.projects.filter(function(p) {
      return p.name.toLowerCase().indexOf(q) !== -1 || p.type.toLowerCase().indexOf(q) !== -1
    })
  }
  readonly property var runningProjects: root.filteredProjects.filter(function(p) { return p.status === "running" })
  readonly property var stoppedProjects: root.filteredProjects.filter(function(p) { return p.status !== "running" })

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    root.opened = true
    root.gitCheckDue = true
    reloadProjects()
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function reloadProjects() {
    if (listProc.running) return
    root.listGotData = false
    listProc.running = true
  }

  function manualRefresh() {
    root.actionError = ""
    root.gitCheckDue = true
    root.reloadProjects()
  }

  function truncateField(s) {
    s = String(s)
    return s.length > root.maxFieldLength ? s.slice(0, root.maxFieldLength) : s
  }

  function truncatePath(s) {
    s = String(s)
    return s.length > root.maxPathLength ? s.slice(0, root.maxPathLength) : s
  }

  function applyListing(raw) {
    var list = []
    var overflow = raw.length > root.maxListProjects
    var limit = Math.min(raw.length, root.maxListProjects)
    for (var i = 0; i < limit; i++) {
      var p = raw[i]
      if (!p || !p.name) continue
      list.push({
        name: root.truncateField(p.name),
        type: root.truncateField(p.type || ""),
        status: root.truncateField(p.status || "unknown"),
        path: root.truncateField(p.shortroot || p.approot || ""),
        approot: root.truncatePath(p.approot || ""),
        url: root.truncateField(p.primary_url || p.httpsurl || p.httpurl || ""),
        mailpitUrl: root.truncateField(p.mailpit_https_url || p.mailpit_url || "")
      })
    }
    list.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
    root.projects = list
    root.loaded = true
    root.listGotData = true
    root.listStale = false
    root.listError = overflow
      ? ("Showing first " + root.maxListProjects + " of " + raw.length + " projects")
      : ""
    if (root.gitCheckDue || Date.now() - root.lastGitCheck >= root.gitCheckInterval)
      root.checkGitStatus()
  }

  function shQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function checkGitStatus() {
    root.gitCheckDue = false
    root.lastGitCheck = Date.now()
    var running = root.projects.filter(function(p) { return p.status === "running" && p.approot !== "" })
    if (running.length === 0) { root.gitDirty = {}; return }
    // Drop entries for projects that are no longer running so a stopped
    // project never carries a stale dirty flag.
    var pruned = {}
    running.forEach(function(p) {
      if (root.gitDirty[p.name] !== undefined) pruned[p.name] = root.gitDirty[p.name]
    })
    root.gitDirty = pruned
    var script = running.map(function(p) {
      return "printf '%s\\t' " + root.shQuote(p.name) +
        "; git -C " + root.shQuote(p.approot) + " status --porcelain 2>/dev/null | head -c1 | wc -c"
    }).join("; ")
    gitCheckProc.command = ["/usr/bin/timeout", "10", "/usr/bin/bash", "-c", script]
    gitCheckProc.running = false
    gitCheckProc.running = true
  }

  function notify(title, body) {
    Quickshell.execDetached(["/usr/bin/notify-send", "-a", "DDEV Manager", title, body || ""])
  }

  // Human-readable subject for messages: a project name, or "all projects"
  // for the poweroff sentinel.
  function subjectOf(name) {
    return name === root.allProjects ? "all projects" : name
  }

  // Every action runs under `timeout`; the watchdog Timer below uses the
  // same per-action value (+10s) so a deliberately long timeout (DB Admin's
  // first-run install) is never cut short by the watchdog.
  function runAction(name, action, args, cwd, timeoutSecs) {
    if (root.busyName !== "") return
    root.actionError = ""
    root.pendingTimeout = timeoutSecs
    root.pendingAction = action
    root.busyName = name
    actionProc.command = ["/usr/bin/timeout", String(timeoutSecs)].concat(args)
    actionProc.workingDirectory = cwd || ""
    actionProc.running = false
    actionProc.running = true
  }

  function finishAction(exitCode) {
    var action = root.pendingAction
    var subject = root.subjectOf(root.busyName)
    if (exitCode !== 0) {
      root.actionError = exitCode === 124
        ? ("ddev " + action + " timed out for " + subject + " after " + root.pendingTimeout + "s")
        : ("ddev " + action + " failed for " + subject + " (exit " + exitCode + ")")
      root.notify("DDEV: " + action + " failed", root.actionError)
    } else if (action === "start") {
      root.notify("DDEV: " + subject + " is running", "")
    } else if (action === "stop") {
      root.notify("DDEV: " + subject + " stopped", "")
    } else if (action === "poweroff") {
      root.notify("DDEV: all projects stopped", "")
    }
    root.busyName = ""
    root.pendingAction = ""
    root.gitCheckDue = true
    root.reloadProjects()
  }

  function startProject(name) {
    // Generous: a first start may pull images.
    root.runAction(name, "start", ["/usr/bin/ddev", "start", name], "", 180)
  }

  function stopProject(name) {
    root.runAction(name, "stop", ["/usr/bin/ddev", "stop", name], "", 90)
  }

  function powerOffAll() {
    root.runAction(root.allProjects, "poweroff", ["/usr/bin/ddev", "poweroff"], "", 120)
  }

  function openDbAdmin(p) {
    // First use installs the add-on and restarts the project, which can
    // take a while on a slow image pull.
    root.runAction(p.name, "dbadmin",
      ["/usr/bin/bash", "-c", "test -f .ddev/commands/host/adminer || ddev add-on get ddev/ddev-adminer --version v1.4.1; ddev adminer"],
      p.approot, 240)
  }

  function launchProject(p) {
    if (p.url) Qt.openUrlExternally(p.url)
  }

  function launchWpAdmin(p) {
    if (p.url) Qt.openUrlExternally(p.url.replace(/\/+$/, "") + "/wp-admin/")
  }

  function copyUrl(p) {
    if (!p.url) return
    Quickshell.execDetached(["/usr/bin/wl-copy", p.url])
    root.notify("Copied URL", p.url)
  }

  function launchMailpit(p) {
    if (p.mailpitUrl) Qt.openUrlExternally(p.mailpitUrl)
  }

  function launchFolder(p) {
    if (p.approot) Qt.openUrlExternally(Util.fileUrl(p.approot))
  }

  // Login shells so the user's PATH (where omarchy-launch-editor and the
  // terminal live) is available, same as Util.execDetached.
  function launchEditor(p) {
    if (p.approot) Quickshell.execDetached(["/usr/bin/bash", "-lc", "omarchy-launch-editor " + root.shQuote(p.approot)])
  }

  function launchTerminal(p) {
    if (p.approot) Quickshell.execDetached(["/usr/bin/bash", "-lc", "xdg-terminal-exec --dir=" + root.shQuote(p.approot)])
  }

  Process {
    id: listProc
    // head -c rejects listing output past a hard byte ceiling before it
    // ever reaches QML's SplitParser, instead of letting an unbounded
    // local project listing grow the parser's buffer without limit.
    command: ["/usr/bin/timeout", "30", "/usr/bin/bash", "-c",
      "/usr/bin/ddev list --json-output | /usr/bin/head -c " + root.maxListBytes]
    stdout: SplitParser {
      onRead: data => {
        if (data.length >= root.maxListBytes) {
          root.listError = "Project listing too large to display safely"
          return
        }
        try {
          const obj = JSON.parse(data)
          if (obj && obj.raw) root.applyListing(obj.raw)
        } catch (e) {}
      }
    }
    onExited: function(exitCode) {
      // A failed or empty-handed listing means DDEV/Docker couldn't be
      // reached — including after earlier successes, when the cards would
      // otherwise keep showing a state that's no longer true.
      if (exitCode !== 0 || !root.listGotData) {
        if (root.listError === "Project listing too large to display safely") return
        root.listStale = root.loaded
        root.listError = root.loaded
          ? "Couldn't reach DDEV — is Docker running? Showing last known state."
          : "Couldn't reach DDEV — is Docker running?"
      }
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) { root.finishAction(exitCode) }
  }

  // One combined "name<TAB>0-or-1" line per running project — cheaper than
  // spawning a separate git process per row, and skips stopped projects
  // since there's nothing actionable to warn about there.
  Process {
    id: gitCheckProc
    stdout: SplitParser {
      onRead: data => {
        var parts = data.split("\t")
        if (parts.length !== 2) return
        var dirty = JSON.parse(JSON.stringify(root.gitDirty))
        dirty[parts[0]] = parseInt(parts[1], 10) > 0
        root.gitDirty = dirty
      }
    }
  }

  // ddev list queries Docker for every project, so poll gently; actions
  // trigger an immediate reload on completion anyway.
  Timer {
    interval: 10000
    repeat: true
    running: root.opened
    onTriggered: root.reloadProjects()
  }

  // Belt-and-suspenders: if a spawned action's exit somehow never reaches
  // actionProc.onExited (a hang the "timeout" wrapper missed, or a
  // Process/quickshell hiccup), this guarantees busyName always clears
  // instead of permanently disabling every button in the panel.
  Timer {
    interval: (root.pendingTimeout + 10) * 1000
    repeat: false
    running: root.busyName !== ""
    onTriggered: {
      root.actionError = "ddev " + root.pendingAction + " timed out for " + root.subjectOf(root.busyName)
      root.notify("DDEV: " + root.pendingAction + " timed out", root.actionError)
      root.busyName = ""
      root.pendingAction = ""
      root.reloadProjects()
    }
  }

  KeyboardPanel {
    id: popupPanel
    anchorItem: root.anchorItem
    owner: root.host || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popupPanel.fittedContentWidth(Style.space(420))
    contentHeight: popupPanel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: parent.width
          spacing: Style.space(10)

          PanelHero {
            title: "DDEV Manager"
            meta: root.totalCount === 0 ? "" : (root.runningCount + " of " + root.totalCount + " running")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)

                PanelActionButton {
                  id: powerOffButton
                  readonly property bool busy: root.busyName === root.allProjects
                  iconText: busy ? "\uf110" : "\uf011"
                  tooltipText: "Stop all projects (ddev poweroff)"
                  foreground: root.foreground
                  hoverColor: Color.urgent
                  enabled: root.runningCount > 0 && root.busyName === ""
                  onClicked: root.powerOffAll()

                  // Same spin treatment as the per-project start/stop button.
                  transformOrigin: Item.Center
                  RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: Style.duration(900)
                    loops: Animation.Infinite
                    running: powerOffButton.busy && !Style.reduceMotion
                    onRunningChanged: if (!running) powerOffButton.rotation = 0
                  }
                }

                PanelActionButton {
                  iconText: "\uf021"
                  tooltipText: "Refresh"
                  foreground: root.foreground
                  onClicked: root.manualRefresh()
                }
              }
            }
          }

          TextField {
            id: searchField
            visible: root.totalCount > 6
            width: parent.width
            text: root.searchText
            placeholderText: "Filter projects…"
            onTextChanged: root.searchText = text
          }

          Text {
            visible: root.listError !== ""
            width: parent.width
            text: root.listError
            color: Color.urgent
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.actionError !== ""
            width: parent.width
            text: root.actionError
            color: Color.urgent
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.loaded && root.totalCount === 0 && root.listError === ""
            width: parent.width
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "No DDEV projects found.\nRun ddev start inside a project to see it here."
            color: Util.alpha(root.foreground, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            visible: root.totalCount > 0 && root.filteredProjects.length === 0
            width: parent.width
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "No projects match “" + root.searchText + "”."
            color: Util.alpha(root.foreground, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          PanelSectionHeader {
            visible: root.runningProjects.length > 0 && root.stoppedProjects.length > 0
            width: parent.width
            text: "Running — " + root.runningProjects.length
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.runningProjects
            delegate: projectCardDelegate
          }

          PanelSectionHeader {
            visible: root.stoppedProjects.length > 0 && root.runningProjects.length > 0
            width: parent.width
            text: "Stopped — " + root.stoppedProjects.length
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.stoppedProjects
            delegate: projectCardDelegate
          }
        }
      }
    }
  }

  // Shared by both the Running and Stopped Repeaters above — kept outside
  // the scrolling Column so it isn't laid out itself, just instantiated by
  // each Repeater. `column.width` below still resolves: ids are scoped to
  // the whole file, not just their parent.
  Component {
    id: projectCardDelegate

    Rectangle {
      id: card
      required property var modelData
      width: column.width
      implicitHeight: row.implicitHeight + Style.space(16)
      height: implicitHeight
      radius: Style.cornerRadius
      color: Util.alpha(root.foreground, cardHover.hovered ? 0.06 : 0.03)
      border.color: Util.alpha(root.foreground, 0.12)
      border.width: 1
      // Dim the last known state while DDEV is unreachable — the dots and
      // statuses may no longer be true.
      opacity: root.listStale ? 0.5 : 1

      readonly property bool isRunning: modelData.status === "running"
      readonly property bool isBusy: root.busyName === modelData.name

      HoverHandler { id: cardHover }

      RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: Style.space(8)
        spacing: Style.space(10)

        Rectangle {
          width: Style.space(8)
          height: Style.space(8)
          radius: width / 2
          Layout.alignment: Qt.AlignVCenter
          color: card.isRunning ? Color.accent : Color.muted
        }

        Column {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              id: nameText
              text: card.modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.bold: true
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideRight
              // Long names elide first so the type and dirty badge stay visible.
              width: Math.min(implicitWidth, parent.width
                - (typeText.visible ? typeText.width + Style.space(6) : 0)
                - (dirtyBadge.visible ? dirtyBadge.width + Style.space(6) : 0))
            }

            Text {
              id: typeText
              visible: card.modelData.type !== ""
              text: card.modelData.type
              color: Util.alpha(root.foreground, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.baseline: nameText.baseline
            }

            Text {
              id: dirtyBadge
              visible: card.isRunning && root.gitDirty[card.modelData.name] === true
              text: ""
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter

              PanelToolTip {
                visible: dirtyMouse.containsMouse
                text: "Uncommitted changes in this project"
                fontFamily: root.fontFamily
              }
              MouseArea {
                id: dirtyMouse
                anchors.fill: parent
                hoverEnabled: true
              }
            }
          }
          Text {
            // The status dot already shows running vs stopped, so only
            // spell out a status when it's something else (e.g. paused).
            // The project type lives on the name row above.
            text: [
              card.isBusy
                ? (root.pendingAction === "start" ? "Starting…"
                  : root.pendingAction === "stop" ? "Stopping…"
                  : "Opening DB Admin (may install & restart)…")
                : ((card.modelData.status === "running" || card.modelData.status === "stopped")
                  ? "" : card.modelData.status),
              card.modelData.path
            ].filter(function(s) { return s !== "" }).join(" · ")
            color: Util.alpha(root.foreground, 0.65)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }

        // Buttons sit in their own tightly spaced Row: each already has a
        // 22px hit/hover box, so the RowLayout's wider spacing between them
        // would just waste room the project name needs.
        Row {
          spacing: Style.space(2)
          Layout.alignment: Qt.AlignVCenter

          PanelActionButton {
            iconText: ""
            tooltipText: "Open in browser (right-click to copy URL)"
            foreground: root.foreground
            enabled: card.isRunning && card.modelData.url !== "" && root.busyName === ""
            onClicked: root.launchProject(card.modelData)

            // Right-click copies the URL; left clicks fall through to the
            // button's own MouseArea since this one doesn't accept them.
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.RightButton
              onClicked: root.copyUrl(card.modelData)
            }
          }

          // Only WordPress projects get a wp-admin shortcut. Other rows keep
          // the slot (invisible, inert) so button columns line up across cards.
          PanelActionButton {
            readonly property bool isWordPress: card.modelData.type === "wordpress"
            iconText: ""
            tooltipText: isWordPress ? "Open WordPress admin" : ""
            foreground: root.foreground
            opacity: isWordPress ? 1 : 0
            enabled: isWordPress && card.isRunning && card.modelData.url !== "" && root.busyName === ""
            onClicked: root.launchWpAdmin(card.modelData)
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Open in editor"
            foreground: root.foreground
            enabled: card.modelData.approot !== ""
            onClicked: root.launchEditor(card.modelData)
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Open terminal here"
            foreground: root.foreground
            enabled: card.modelData.approot !== ""
            onClicked: root.launchTerminal(card.modelData)
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Open folder"
            foreground: root.foreground
            enabled: card.modelData.approot !== ""
            onClicked: root.launchFolder(card.modelData)
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Open Mailpit (sent emails)"
            foreground: root.foreground
            enabled: card.isRunning && card.modelData.mailpitUrl !== "" && root.busyName === ""
            onClicked: root.launchMailpit(card.modelData)
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "Open DB Admin (Adminer) — installs and restarts the project on first use"
            foreground: root.foreground
            enabled: card.isRunning && root.busyName === ""
            onClicked: root.openDbAdmin(card.modelData)
          }

          PanelActionButton {
            id: powerButton
            iconText: card.isBusy ? "" : (card.isRunning ? "" : "")
            tooltipText: card.isRunning ? "Stop" : "Start"
            foreground: root.foreground
            hoverColor: card.isRunning ? Color.urgent : root.foreground
            enabled: !card.isBusy && root.busyName === ""
            onClicked: card.isRunning ? root.stopProject(card.modelData.name) : root.startProject(card.modelData.name)

            // Spin the busy spinner glyph, matching Ui/Button's iconSpinning.
            // Rotating the whole button is safe: it's disabled while busy, so
            // it has no hover fill or border to visibly turn with it.
            transformOrigin: Item.Center
            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: Style.duration(900)
              loops: Animation.Infinite
              running: card.isBusy && !Style.reduceMotion
              // Snap back upright so the play/stop glyph that replaces the
              // spinner isn't left tilted at whatever angle it stopped on.
              onRunningChanged: if (!running) powerButton.rotation = 0
            }
          }
        }
      }
    }
  }
}
