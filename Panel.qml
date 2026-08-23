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
  property string busyName: ""
  property string pendingAction: ""
  property string errorText: ""
  property bool loaded: false

  readonly property int runningCount: {
    var n = 0
    for (var i = 0; i < projects.length; i++) if (projects[i].status === "running") n++
    return n
  }
  readonly property int totalCount: projects.length

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    root.opened = true
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
    if (!listProc.running) listProc.running = true
  }

  function applyListing(raw) {
    var list = []
    for (var i = 0; i < raw.length; i++) {
      var p = raw[i]
      if (!p || !p.name) continue
      list.push({
        name: p.name,
        type: p.type || "",
        status: p.status || "unknown",
        path: p.shortroot || p.approot || "",
        approot: p.approot || "",
        url: p.primary_url || p.httpsurl || p.httpurl || ""
      })
    }
    list.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
    root.projects = list
    root.loaded = true
    root.errorText = ""
  }

  function runAction(name, action, args, cwd) {
    if (root.busyName !== "") return
    root.busyName = name
    root.pendingAction = action
    actionProc.command = args
    actionProc.workingDirectory = cwd || ""
    actionProc.running = false
    actionProc.running = true
  }

  function startProject(name) {
    root.runAction(name, "start", ["/usr/bin/timeout", "90", "/usr/bin/ddev", "start", name], "")
  }

  function stopProject(name) {
    root.runAction(name, "stop", ["/usr/bin/timeout", "90", "/usr/bin/ddev", "stop", name], "")
  }

  function openDbAdmin(p) {
    root.runAction(p.name, "dbadmin",
      ["/usr/bin/timeout", "90", "/usr/bin/bash", "-c", "test -f .ddev/commands/host/adminer || ddev add-on get ddev/ddev-adminer; ddev adminer"],
      p.approot)
  }

  function launchProject(p) {
    if (p.url) Qt.openUrlExternally(p.url)
  }

  Process {
    id: listProc
    command: ["/usr/bin/ddev", "list", "--json-output"]
    stdout: SplitParser {
      onRead: data => {
        try {
          const obj = JSON.parse(data)
          if (obj && obj.raw) root.applyListing(obj.raw)
        } catch (e) {}
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.loaded) root.errorText = "Couldn't reach DDEV — is Docker running?"
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.errorText = "ddev " + root.pendingAction + " failed for " + root.busyName
      root.busyName = ""
      root.pendingAction = ""
      root.reloadProjects()
    }
  }

  Timer {
    interval: 4000
    repeat: true
    running: root.opened
    onTriggered: root.reloadProjects()
  }

  // Belt-and-suspenders: if a spawned action's exit somehow never reaches
  // actionProc.onExited (a hang the "timeout" wrapper missed, or a
  // Process/quickshell hiccup), this guarantees busyName always clears
  // instead of permanently disabling every button in the panel.
  Timer {
    interval: 100000
    repeat: false
    running: root.busyName !== ""
    onTriggered: {
      root.errorText = "'" + root.pendingAction + "' timed out for " + root.busyName
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
    contentWidth: popupPanel.fittedContentWidth(Style.space(380))
    contentHeight: popupPanel.fittedContentHeight(column.implicitHeight, Style.space(480))

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
            title: "DDEV Projects"
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
              PanelActionButton {
                iconText: "↻"
                tooltipText: "Refresh"
                foreground: root.foreground
                onClicked: root.reloadProjects()
              }
            }
          }

          Text {
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: Color.urgent
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.loaded && root.totalCount === 0 && root.errorText === ""
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

          Repeater {
            model: root.projects

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

                  Text {
                    text: card.modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.bold: true
                    font.pixelSize: Style.font.subtitle
                    elide: Text.ElideRight
                    width: parent.width
                  }
                  Text {
                    text: (card.isBusy
                      ? (root.pendingAction === "start" ? "Starting…"
                        : root.pendingAction === "stop" ? "Stopping…"
                        : "Opening DB Admin (may install & restart)…")
                      : (card.modelData.type + " · " + card.modelData.status))
                      + (card.modelData.path ? "  ·  " + card.modelData.path : "")
                    color: Util.alpha(root.foreground, 0.65)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                PanelActionButton {
                  iconText: "↗"
                  tooltipText: "Open in browser"
                  foreground: root.foreground
                  enabled: card.isRunning && card.modelData.url !== "" && root.busyName === ""
                  onClicked: root.launchProject(card.modelData)
                }

                PanelActionButton {
                  iconText: ""
                  tooltipText: "Open DB Admin (Adminer) — installs and restarts the project on first use"
                  foreground: root.foreground
                  enabled: card.isRunning && root.busyName === ""
                  onClicked: root.openDbAdmin(card.modelData)
                }

                PanelActionButton {
                  iconText: card.isBusy ? "…" : (card.isRunning ? "■" : "▶")
                  tooltipText: card.isRunning ? "Stop" : "Start"
                  foreground: root.foreground
                  hoverColor: card.isRunning ? Color.urgent : root.foreground
                  enabled: !card.isBusy && root.busyName === ""
                  onClicked: card.isRunning ? root.stopProject(card.modelData.name) : root.startProject(card.modelData.name)
                }
              }
            }
          }
        }
      }
    }
  }
}
