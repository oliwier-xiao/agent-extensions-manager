import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar slot: one glyph, an optional figure, and the way in. Panel.qml draws
// the list and owns the only subprocess in the plugin; bin/agent-ext does every
// byte of the I/O.
//
// Startup cost is nil, deliberately. The panel Loader starts inactive, so
// Panel.qml is not read off disk or compiled until something asks for it, and
// the one Timer here refuses to run while `barLabel` is "Nothing" -- which is
// what it is until somebody changes it.
BarWidget {
  id: root
  moduleName: "oliwier.ai-skills-manager"

  // nf-md-brain (U+F09D1), written as its surrogate pair rather than pasted in.
  // A private-use codepoint is invisible in a diff, in a review, and in any
  // editor without a Nerd Font loaded; an escape and a name are legible
  // everywhere and say which glyph this is meant to be.
  //
  // It was nf-md-robot, which was wrong for one reason no amount of taste would
  // have found: Omarchy's own `omarchy.agents` widget is a robot too
  // (nf-md-robot_outline, U+F16A3), so on a default bar this plugin sat next to
  // a near-identical mark and neither could be picked out. Not the puzzle-piece
  // family either -- the plugin manager already wears that, and two neighbours
  // that both mean "things you installed" have to be told apart at a glance
  // rather than read.
  //
  // A brain survives the size it is actually drawn at, which is the whole test:
  // at the bar's 13px the folds still read, and it is asymmetric, so it cannot
  // be mistaken for one more round blob in a row of them. nf-md-head_cog is the
  // other honest answer and reads as "machine learning" more literally, but its
  // cog collapses to a dot at this size.
  readonly property string glyph: "\uDB82\uDDD1"

  // The shell stores `barWidget.defaults` as registry metadata for the settings
  // UI and never merges it into `settings` (BarModel.entrySettings hands over the
  // shell.json entry minus `id`, and nothing reads `defaults`). Every fallback
  // here repeats the manifest value verbatim, or a widget added by hand to
  // shell.json behaves differently from one added through the settings panel.
  readonly property string labelMode: String(setting("barLabel", "Nothing"))
  readonly property string tokenModel: String(setting("tokenModel", "chars/4"))
  readonly property int divisor: root.tokenModel === "chars/3" ? 3 : 4
  readonly property bool tokensHidden: root.tokenModel === "Hide"

  // Whether a figure is wanted at all, and therefore whether this widget is ever
  // allowed to cause work. "Always-on tokens" with the cost column hidden is a
  // contradiction the user already resolved: they said do not show me the cost,
  // so we do not show it and we do not go and count it either.
  readonly property bool numbersWanted: root.labelMode !== "Nothing"
    && !(root.labelMode === "Always-on tokens" && root.tokensHidden)

  // { at, divisor, skills, enabled, tokens, attention } produced by Panel.qml
  // after each successful scan. Nothing here parses helper output.
  property var summary: null
  property int scanAttempts: 0
  readonly property int summaryTtlMs: 900000

  readonly property var panelSummary: panelLoader.item ? panelLoader.item.summary : null
  readonly property bool scanning: panelLoader.item ? panelLoader.item.scanning === true : false

  // Usable, not merely present: a chars/4 total under a chars/3 heading is a
  // wrong number, so changing the model re-arms the short interval. The old
  // figure stays up for those seconds rather than blanking -- it was right for
  // the model it was measured with, and it is about to be replaced.
  readonly property bool summaryUsable: root.summary !== null
    && root.summary.divisor === root.divisor

  onDivisorChanged: root.scanAttempts = 0
  onPanelSummaryChanged: if (root.panelSummary) root.publish(root.panelSummary)

  // A bar surface is built per monitor, so a widget listed once is live once per
  // screen. One scan feeds all of them.
  function peers() {
    return root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : [root]
  }

  function publish(next) {
    var live = root.peers()
    if (live.length === 0) { root.summary = next; return }
    for (var i = 0; i < live.length; i++) {
      if (live[i] && "summary" in live[i]) {
        live[i].summary = next
        if ("scanAttempts" in live[i]) live[i].scanAttempts = 0
      }
    }
  }

  // The only path by which the bar causes work, and it refuses in four cases: a
  // scan already running here, a sibling monitor already running one, a usable
  // figure still inside its lifetime, or a helper that has failed enough times
  // that retrying would be a fork loop rather than a heartbeat. Mounting the
  // panel is the price of the figure the user asked for; at the default setting
  // this function is never called.
  function requestSummary(force) {
    if (root.scanning) return
    if (force !== true) {
      if (root.summaryUsable && Date.now() - (Number(root.summary.at) || 0) < root.summaryTtlMs) return
      var live = root.peers()
      for (var i = 0; i < live.length; i++)
        if (live[i] && live[i] !== root && live[i].scanning === true) return
    } else {
      root.scanAttempts = 0
    }
    var target = root.ensurePanel()
    if (!target) return
    root.scanAttempts += 1
    target.requestScan(force === true)
  }

  function compact(value) {
    var n = Number(value) || 0
    if (n < 1000) return String(Math.round(n))
    if (n < 10000) return (Math.round(n / 100) / 10).toFixed(1) + "k"
    if (n < 1000000) return String(Math.round(n / 1000)) + "k"
    return (Math.round(n / 100000) / 10).toFixed(1) + "M"
  }

  readonly property int attentionCount:
    root.summaryUsable ? (Number(root.summary.attention) || 0) : 0

  readonly property string labelText: {
    // A vertical bar has no room for a figure beside the mark, so an edge bar is
    // icon-only whatever the setting says. The tooltip still carries the numbers.
    if (root.vertical || !root.numbersWanted || !root.summaryUsable) return ""
    if (root.labelMode === "Always-on tokens") return root.compact(root.summary.tokens)
    if (root.labelMode === "Skills enabled") return String(Number(root.summary.enabled) || 0)
    // Attention is meant to be invisible most of the time: a clean machine gets
    // the bare mark back and its width returned to its neighbours.
    if (root.labelMode === "Needs attention")
      return root.attentionCount > 0 ? String(root.attentionCount) : ""
    return ""
  }

  readonly property bool alarmed:
    root.labelMode === "Needs attention" && root.attentionCount > 0

  // The widest string this mode can produce, so the slot is measured once and the
  // bar never shifts under the cursor when a number ticks over.
  readonly property string labelTemplate: {
    if (root.labelMode === "Always-on tokens") return "88.8k"
    if (root.labelMode === "Skills enabled") return "888"
    return "88"
  }

  // Only digits and words this file composed reach the bar's shared tooltip Text,
  // which belongs to Bar.qml and is not ours to set a textFormat on (it does set
  // PlainText, at Bar.qml:1108, but that is the shell's choice and could change).
  // Nothing read off another author's disk is ever put here; that stays inside
  // the panel, where every sink is explicitly PlainText.
  readonly property string tooltipText: {
    if (!root.summaryUsable) return "Agent Extensions\nClaude Code · OpenCode · Codex"
    var line = String(root.summary.enabled) + " of " + String(root.summary.skills) + " enabled"
    if (!root.tokensHidden)
      line += "  ·  ~" + root.compact(root.summary.tokens) + " tokens on every turn"
    var out = "Agent Extensions\n" + line
    if (root.attentionCount > 0) out += "\n" + String(root.attentionCount) + " need attention"
    return out
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Mount on demand, then never unmount. The Loader is synchronous on purpose:
  // setting `active` creates the item and runs onLoaded before the assignment
  // returns, which is what lets open() call straight through on the same tick.
  // Injection is repeated here rather than left to onLoaded because the panel's
  // `bar` and `anchorItem` must be set before its first open(), and onLoaded's
  // Qt.callLater would land after it.
  function ensurePanel() {
    if (!panelLoader.active) {
      panelLoader.active = true
      root.injectPanel()
    }
    return panelLoader.item
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Bar.findPanelWidget requires open(), close() and an `opened` that is not
  // undefined on the bar-widget root, and Bar.requestPopout compares ownership
  // against slot.activeItem -- this item, never the panel. So all four live here
  // and delegate down. They read correctly before Panel.qml exists, which is why
  // the lazy Loader is safe: the bar can find, tab to, number and summon this
  // widget while its panel is still an unread file on disk.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { var p = root.ensurePanel(); if (p) p.open() }
  function togglePanel() { var p = root.ensurePanel(); if (p) p.toggle() }
  // close and the popout switch never mount anything: a panel that was never
  // opened has nothing to close, and mounting one to say so would put the cost
  // back exactly where this file spent its effort taking it out.
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Underline what this widget paints rather than 55% of whatever slot it lands
  // in, which is what the bar assumes when a widget says nothing.
  readonly property real openPanelIndicatorWidth: row.implicitWidth
  readonly property real openPanelIndicatorHeight: Style.bar.iconCanvas

  Loader {
    id: panelLoader
    active: false
    asynchronous: false
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Anything running as this user can call these, so none of them changes
  // anything: they move this panel around and nothing else. There is
  // deliberately no rescan verb -- a rescan starts a process, and a no-argument
  // way for any process on the session bus to make the shell fork on demand is a
  // surface this plugin does not need. Middle-clicking the mark does that job.
  IpcHandler {
    target: "oliwier.ai-skills-manager"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  Timer {
    id: summaryTimer
    // The first fire is a deliberate stall: the bar has to paint and the session
    // has to finish coming up before this widget mounts a panel and starts a
    // process. After that it is a slow heartbeat, because the only thing that
    // moves these numbers is a skill being installed or switched, and both happen
    // outside this widget. A helper that will not run gets four tries and is then
    // left alone; explaining a broken helper is the panel's job, not the bar's.
    interval: root.summaryUsable ? root.summaryTtlMs : (root.scanAttempts === 0 ? 6000 : 60000)
    repeat: true
    running: root.numbersWanted && root.bar !== null
      && (root.summaryUsable || root.scanAttempts < 4)
    onTriggered: root.requestSummary(false)
  }

  // WidgetButton rather than a bare MouseArea for two reasons that are not
  // cosmetic: it registers with bar.registerClickTarget, which is the only way a
  // click on this mark can switch to it while a neighbouring panel's full-screen
  // overlay is mapped (KeyboardPanel.pressTargetAt walks bar.clickTargets and
  // requires triggerPress), and it supplies `tooltipHovered`, which
  // Bar.targetTooltipHovered requires before showTooltip will show anything.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The mark is drawn by the Row below so it is centred on its ink rather than
    // on its advance box; the button's own label stays out of the way.
    labelVisible: false
    hasVisualContent: true
    fontSize: Style.bar.iconFont
    active: root.alarmed
    tooltipText: root.tooltipText
    // Icon-only and vertical keep the slot every other icon-only module uses.
    // With a figure beside it the 8.5 house edge padding goes outside the pair
    // and never between the mark and the number.
    fixedWidth: root.vertical
      ? -1
      : (root.labelText !== ""
        ? Math.round(row.implicitWidth + Style.spaceReal(8.5) * 2)
        : Style.bar.iconSlot)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    onPressed: function (b) {
      // Middle click re-reads, the gesture the clock and the profile switcher
      // already use. Right click and the wheel are deliberately unbound: a stray
      // gesture over the bar must never do anything.
      if (b === Qt.MiddleButton) root.requestSummary(true)
      else if (b === Qt.LeftButton) root.togglePanel()
    }

    Row {
      id: row
      anchors.centerIn: parent
      // Measured on the neighbouring plugin: at 6px the figure sat closer to the
      // next widget's glyph than to its own and the eye grouped it with the wrong
      // one. 2 gives about a third of that gap.
      spacing: root.labelText !== "" ? Style.space(2) : 0

      Item {
        anchors.verticalCenter: parent.verticalCenter
        // The canvas, not the slot, once there is a figure beside it: reserving
        // the whole slot puts most of the gap inside the widget.
        width: root.labelText !== "" ? Style.bar.iconCanvas : Style.bar.iconSlot
        height: Style.bar.iconCanvas

        OpticalGlyph {
          anchors.fill: parent
          text: root.glyph
          fontFamily: button.fontFamily
          fontSize: button.fontSize
          color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        }
      }

      Text {
        id: figure
        anchors.verticalCenter: parent.verticalCenter
        visible: root.labelText !== ""
        textFormat: Text.PlainText
        text: root.labelText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
        horizontalAlignment: Text.AlignLeft
        // Pinned to the widest figure this mode can produce, so the bar never
        // shifts under the cursor when a number ticks over.
        width: figureBox.width

        TextMetrics {
          id: figureBox
          font: figure.font
          text: root.labelTemplate
        }
      }
    }
  }
}
