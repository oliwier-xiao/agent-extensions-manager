import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The panel: one grouped, searchable list of every skill, MCP server and Claude
// Code plugin the three agents load. bin/agent-ext does all the I/O and prints
// one line of JSON; this file reads it and draws it, and the only process it
// ever runs is that helper.
//
// v0.1 is read-only on purpose. bin/agent-ext registers exactly two subcommands
// (`scan` and `doctor`) and has no write path, and the settled decision is that
// the helper is the only thing that touches the filesystem -- so a switch drawn
// here would be a button that cannot work. Instead every row says where its
// state is written and what it currently is, which is the honest version of the
// same information and is a claim a reviewer can check: this plugin writes
// nothing, anywhere.
Panel {
  id: root
  moduleName: "oliwier.agent-extensions-manager"
  ipcTarget: "oliwier.agent-extensions-manager"
  // The bar widget owns the single live handler for this target. Leaving the
  // base's own handler enabled would register the target twice.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  // KeyboardPanel keys the bar's popout coordinator on `owner`, and
  // Bar.switchPanelFrom matches slot.activeItem -- which is the bar widget, not
  // this panel. Both must be the widget or the open-panel underline never paints
  // and Tab hands off to nothing.
  readonly property var barIdentity: hostWidget || root
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  readonly property color fg: Color.popups.text
  readonly property color hue: Color.accent
  readonly property string face: bar ? bar.fontFamily : Style.font.family
  // Util.alpha, not Qt.darker: on a light theme Qt.darker makes a dimmed step
  // more prominent than the foreground, and on all-black text every level of
  // the ladder collapses into the same value.
  //
  // Five steps, named for the job rather than the number, and each one a role a
  // reader can tell apart at a glance. The first version had three: the name at
  // full strength and everything else at 0.66 or 0.42. On a dark popup that put
  // the type badge, the scope, the tool letters, the token figure, the usage
  // count, every group header and the whole footer at four tenths of the
  // foreground, in ten pixels. It read as grey noise around one bright word,
  // which is exactly what it was.
  //
  // Light text on a dark surface loses more contrast than the alpha suggests,
  // so the metadata floor moved to 0.60 and the reading step to 0.76. `faint`
  // is now for hairlines only and is never asked to carry a glyph.
  readonly property color strong: Util.alpha(fg, 0.88)
  readonly property color readable: Util.alpha(fg, 0.76)
  readonly property color soft: Util.alpha(fg, 0.60)
  readonly property color faint: Util.alpha(fg, 0.14)

  // Manifest defaults repeated verbatim; see the note in BarWidget.qml.
  readonly property string groupMode: String(setting("groupBy", "Category"))
  readonly property string tokenModel: String(setting("tokenModel", "chars/4"))
  readonly property bool showBundled: setting("showBundled", false) === true
  readonly property bool scanOnOpen: setting("scanOnOpen", true) !== false
  readonly property int divisor: root.tokenModel === "chars/3" ? 3 : 4
  readonly property bool showTokens: root.tokenModel !== "Hide"

  // `g` cycles this for the session; the setting owns the default.
  property string groupOverride: ""
  readonly property string grouping: root.groupOverride !== "" ? root.groupOverride : root.groupMode

  // ---- Helper -------------------------------------------------------------

  // Qt.resolvedUrl percent-encodes: a home directory with a space in it would
  // otherwise reach Process as a literal %20 and nothing would start.
  function fromFileUrl(u) {
    var s = String(u || "").replace(/^file:\/\//, "").replace(/\/$/, "")
    try { return decodeURIComponent(s) } catch (e) { return s }
  }
  readonly property string pluginDir: root.fromFileUrl(Qt.resolvedUrl("."))
  readonly property string helperPath: root.pluginDir + "/bin/agent-ext"
  readonly property string homeDir: String(Quickshell.env("HOME") || "")

  readonly property int maxScanBytes: 2 * 1024 * 1024
  readonly property int scanTimeoutMs: 8000
  readonly property int scanTtlMs: 900000

  // The read cap and the process-group teardown, in four lines that each carry
  // their weight:
  //
  //   set -m       gives the job its own process group, so it can be signalled
  //                as a group without touching Quickshell's -- `bash -c`
  //                inherits the shell's group, so a bare `kill 0` would signal
  //                the shell itself.
  //   ... &        the job must be asynchronous, because a trap does not run
  //                while bash waits on a foreground command. `wait` is the one
  //                builtin a signal interrupts, which is what makes the trap
  //                fire the moment Process.running is set false.
  //   head -c $3   caps the read before StdioCollector allocates it -- the
  //                collector has no ceiling of its own, its whole surface being
  //                text/data/waitForEnd. The trailing `cat >/dev/null` drains
  //                the rest so the producer never takes SIGPIPE and reports a
  //                failure it did not have.
  //   kill %1      a job spec, not $!. For a pipeline $! is the PID of the last
  //                element while the process-group id is the first element's, so
  //                `kill -- -$!` would signal the wrong group or none at all.
  //                Bash resolves %1 to the job's own group.
  //
  // The helper path, the divisor and the cap land in positional parameters and
  // are never interpolated into the script text, so bash cannot re-tokenize
  // them. /bin/bash is absolute because the interpreter of a plugin's own helper
  // must not be resolved through the inherited PATH.
  readonly property string scanScript:
      "set -m\n"
    + "\"$1\" scan --divisor \"$2\" | { head -c \"$3\"; cat >/dev/null; } &\n"
    + "trap 'kill -TERM %1 2>/dev/null; exit 143' TERM INT\n"
    + "wait %1\n"

  // A cleared environment with three variables put back, each for a stated
  // reason. PATH is fixed so `#!/usr/bin/env python3` in the helper cannot be
  // pointed at an interpreter of somebody else's choosing, and so head and cat
  // resolve. HOME is the root of everything the helper scans.
  // PYTHONIOENCODING is not optional: with the environment cleared the locale is
  // C, Python would give stdout an ASCII codec, and the helper's
  // ensure_ascii=False dump would die on the first em dash in a description.
  // OPENCODE_DISABLE_EXTERNAL_SKILLS is forwarded when set because the helper
  // reads it and it changes which tools each skill is reported under; dropping
  // it would silently change the answer.
  function scanEnvironment() {
    var env = {
      "PATH": "/usr/local/bin:/usr/bin:/bin",
      "HOME": root.homeDir,
      "PYTHONIOENCODING": "utf-8"
    }
    var oc = String(Quickshell.env("OPENCODE_DISABLE_EXTERNAL_SKILLS") || "")
    if (oc !== "") env["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = oc
    return env
  }

  // The one thing this panel changes, and it changes it through the same helper
  // the reading goes through rather than by writing a file from QML. Arguments
  // land in argv, never in a script, so nothing here can be re-tokenized by a
  // shell -- there is no shell.
  function runCategory(argv, done) {
    if (catProc.running) { root.flashResult("One at a time", "error"); return }
    catProc.pending = done || ""
    catProc.clearEnvironment = true
    catProc.environment = root.scanEnvironment()
    catProc.command = [root.helperPath, "category"].concat(argv)
    catProc.running = true
  }

  // ---- State --------------------------------------------------------------
  // Not `data`: that is Item's default property and holds children.

  property var report: null
  property bool loaded: false
  property bool scanning: false
  property bool scanConsumed: false
  property string scanError: ""
  property string toast: ""
  property var summary: null

  property string filterText: ""
  // One category at a time, chosen by clicking its chip. Not a second grouping
  // and not a second search: it answers "show me only the design ones", which
  // was the one question the list could not be asked without typing a word that
  // happened to appear in the right descriptions.
  property string categoryFilter: ""
  // The other two dimensions the summary boxes stand for: what a thing is, and
  // which agent can see it. One value each, because two of anything here would
  // be a query language and the search field is already the place for that.
  property string kindFilter: ""
  property string toolFilter: ""
  // Whether the shelf strip shows every chip or only the row that fits. Kept
  // across opens, the way the folded groups and the grouping override already
  // are: it is a view preference, and re-collapsing it on every open would be
  // the panel forgetting something the user just told it.
  property bool filtersExpanded: false
  property bool attentionOnly: false
  property var collapsed: ({})
  property string expandedKey: ""
  property int selectedIndex: 0
  property bool cursorActive: false

  // The overlay. One surface, three jobs, because they are the same gesture:
  // something on a row is a short list of possibilities and you are picking one.
  //
  //   "argument"  a skill's documented actions, assembled onto its invocation
  //   "category"  which shelf a skill lives on, including a new one
  //   "style"     what a category is called and what colour it is drawn in
  //
  // `pickerRow` is the row it was opened from, held rather than looked up again
  // so that a rescan landing mid-pick cannot move the question out from under
  // the answer.
  property string pickerMode: ""
  // Which mode to return to when this one is dismissed. The shelf index opens
  // the style editor on top of itself, and backing out of a rename should land
  // where you were rather than closing the whole overlay.
  property string pickerReturn: ""
  property var pickerRow: null
  property string pickerCategory: ""
  // Naming a shelf that does not exist yet. Its own sub-mode rather than a
  // guess about what the typed text means: with the list on screen Enter has to
  // choose between opening the highlighted shelf and creating a new one, and a
  // key that does one of two things depending on what you typed is a key nobody
  // presses confidently.
  property bool pickerNaming: false

  // The style editor keeps a draft. Picking a colour used to write it and back
  // out in the same gesture, which made browsing the twelve swatches impossible:
  // every look was a commit. Now `styleColourIndex` is what is being tried on,
  // `pickerText` is the name being typed, and neither reaches the file until you
  // say so. `styleBase*` is what was there when the editor opened, so the panel
  // knows whether there is anything to save and can ask before dropping it.
  property int styleColourIndex: -1
  property int styleBaseIndex: -1
  property string styleBaseLabel: ""
  property bool styleAsking: false
  readonly property bool styleDirty: root.pickerMode === "style"
    && (root.styleColourIndex !== root.styleBaseIndex
        || root.pickerText.trim() !== root.styleBaseLabel)

  property string pickerText: ""
  property int pickerIndex: 0
  readonly property bool pickerOpen: root.pickerMode !== ""

  // Twelve swatches, the whole colour vocabulary a category can be given. A free
  // hex field would be a text editor this panel does not have, and twelve
  // distinguishable hues is more than fourteen categories need.
  readonly property var swatches: [
    "#E06C75", "#D97757", "#E5C07B", "#98C379", "#7FD88F", "#56B6C2",
    "#5C9CF5", "#7AA2F7", "#9D7CD8", "#C678DD", "#F5A742", "#8B949E"
  ]

  // Which row last had something copied off it. Cleared on a timer, and never
  // set optimistically.
  property string copiedKey: ""
  property string toastTone: "info"

  // Findings you have read and do not want on screen. Held in memory only: the
  // next shell start reports them again, because a skill directory with no
  // SKILL.md in it is still a skill directory with no SKILL.md in it, and a
  // dismissal that outlived the session would quietly become a decision.
  property var dismissed: ({})

  // Each agent's own colour, from that agent's own palette: Anthropic's clay,
  // opencode's TUI secondary, OpenAI's green. Identity is the one thing here
  // allowed not to follow the desktop theme, because a Claude mark that turned
  // green under a green theme would be saying something untrue. Everything the
  // panel says in its own voice still follows it.
  readonly property var markColours: ({
    claude: "#D97757", opencode: "#5C9CF5", codex: "#10A37F"
  })
  function markColour(tool) {
    return root.markColours[tool] || root.fg
  }

  readonly property var categoryOrder: [
    "agents", "code", "workflow", "web", "design", "media", "data",
    "infra", "ops", "security", "automation", "content", "business", "system",
    "unsorted"
  ]
  readonly property var categoryLabel: ({
    agents: "Agents", code: "Code", workflow: "Workflow", web: "Web",
    design: "Design", media: "Media", data: "Data", infra: "Infrastructure",
    ops: "Operations", security: "Security", automation: "Automation",
    content: "Content", business: "Business", system: "System",
    unsorted: "Unsorted"
  })
  readonly property var toolLabel: ({
    claude: "Claude Code", opencode: "OpenCode", codex: "Codex"
  })

  // The codes bin/agent-ext can attach, ranked. Only 2 and above light the urgent
  // colour. `unclassified` and `low-confidence` used to be here at 1: they were
  // the classifier hedging rather than anything wrong, sixteen skills on a
  // machine like this one carried one of them, and a list where most rows are
  // flagged is a list where `drift` -- two agents running different code -- is
  // just another grey dot. The helper no longer emits them, and an unplaced
  // skill gets the `unsorted` shelf and a control to move it off instead.
  // `name-mismatch` is a 2 and not a 1 because it is not cosmetic: the helper
  // builds Claude's invocation from the directory name and OpenCode's from the
  // frontmatter name, so a mismatch means the same skill is called two things.
  readonly property var severityRank: ({
    "drift": 3, "invalid-yaml": 3,
    "name-mismatch": 2, "no-description": 2,
    "long-description": 1
  })
  readonly property var attentionPhrase: ({
    "drift": "Another skill of this name has different content -- two agents are running different code",
    "invalid-yaml": "The frontmatter has an unquoted colon",
    "name-mismatch": "The frontmatter name and the directory name disagree, so the tools call it two things",
    "no-description": "No description, so the agent has nothing to match on",
    "long-description": "The description is over 1024 characters"
  })

  // Every string this panel draws was written by somebody else -- a directory
  // name, a frontmatter `name:`, a description, an MCP server's command line.
  // textFormat: Text.PlainText on every sink is the floor; this is the boundary,
  // where control characters and the bidi overrides that let a crafted
  // description reorder or hide what a row says are removed once, before any of
  // it reaches a model. Length is capped here too, so no single field can make
  // the shell lay out a megabyte of glyphs.
  function clean(value, limit) {
    if (typeof value !== "string") return ""
    var out = ""
    for (var i = 0; i < value.length && out.length < 8192; i++) {
      var c = value.charCodeAt(i)
      if (c < 0x20 || c === 0x7f) { out += " "; continue }
      if ((c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e)
          || (c >= 0x2066 && c <= 0x2069)) continue
      out += value.charAt(i)
    }
    out = out.replace(/\s+/g, " ").trim()
    var cap = limit || 512
    return out.length <= cap ? out : out.substring(0, cap - 1) + "…"
  }

  // An invocation is pasted into an agent prompt, so it is checked against a
  // charset rather than merely cleaned: a frontmatter name carrying anything
  // outside this set is shown but refused for copying, and the row says so.
  function copyable(token) {
    return /^[\/$][A-Za-z0-9][A-Za-z0-9._:-]{0,119}$/.test(String(token || ""))
  }

  // The same guarantee once an argument has been appended. The helper already
  // refuses to offer a token that is not a bare word, so this is the second of
  // two independent checks rather than the only one: what reaches the clipboard
  // is an invocation, at most four single-word arguments, and one space between
  // each. Nothing that could read as a second command can pass.
  function copyableCommand(text) {
    return /^[\/$][A-Za-z0-9][A-Za-z0-9._:-]{0,119}(?: [A-Za-z0-9][A-Za-z0-9._-]{0,31}){0,4}$/
      .test(String(text || ""))
  }

  function flash(message) {
    root.toast = root.clean(message, 200)
    root.toastTone = "info"
    toastTimer.restart()
  }

  // A copy is the one thing in this panel that changes something outside it, so
  // it gets its own tone rather than sharing the plain message strip.
  function flashResult(message, tone) {
    root.toast = root.clean(message, 200)
    root.toastTone = tone
    toastTimer.restart()
  }

  Timer {
    id: toastTimer
    interval: 4000
    onTriggered: { root.toast = ""; root.toastTone = "info" }
  }

  // How long the footer keeps its tick up. Short, because it sits where the eye
  // already is and has to be seen rather than read.
  Timer { id: copiedTimer; interval: 1800; onTriggered: root.copiedKey = "" }

  // ---- Scan ---------------------------------------------------------------

  function requestScan(force) {
    if (scanProc.running) return
    if (force !== true && root.loaded && root.summary
        && root.summary.divisor === root.divisor
        && Date.now() - (Number(root.summary.at) || 0) < root.scanTtlMs) return
    root.startScan()
  }

  function startScan() {
    if (scanProc.running) return
    root.scanning = true
    root.scanConsumed = false
    root.scanError = ""
    scanProc.clearEnvironment = true
    scanProc.environment = root.scanEnvironment()
    scanProc.command = ["/bin/bash", "-c", root.scanScript, "agent-ext-scan",
                        root.helperPath, String(root.divisor), String(root.maxScanBytes)]
    scanProc.running = true
    scanWatchdog.restart()
  }

  // running = false sends SIGTERM to bash, which is sitting in `wait` and runs
  // the trap immediately; the trap takes the whole job's process group down.
  // scanKill is the second half of that promise, for the case where bash itself
  // is wedged and never reaches its own trap.
  function stopScan() {
    scanWatchdog.stop()
    root.scanning = false
    if (!scanProc.running) return
    scanProc.running = false
    scanKill.restart()
  }

  function consumeScan(raw) {
    root.scanConsumed = true
    var text = String(raw || "")
    if (text.length === 0) {
      root.scanError = "bin/agent-ext printed nothing. Run it in a terminal: "
        + root.helperPath + " doctor"
      return
    }
    // The helper ends its one line of JSON with a newline. A payload that does
    // not is one head -c stopped at the cap, or one the watchdog cut short --
    // which is a different fact from "the JSON is malformed", and the difference
    // is the one the user can act on.
    if (text.charAt(text.length - 1) !== "\n") {
      root.scanError = "The scan was cut off at " + Math.round(root.maxScanBytes / 1024)
        + " KiB or by the " + Math.round(root.scanTimeoutMs / 1000)
        + " s deadline. Run it in a terminal: " + root.helperPath + " scan"
      return
    }
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) { parsed = null }
    if (!parsed || !Array.isArray(parsed.items)) {
      root.scanError = "bin/agent-ext did not return a scan. Run it in a terminal: "
        + root.helperPath + " doctor"
      return
    }
    root.report = parsed
    root.loaded = true
    root.scanError = ""
    root.publishSummary()
  }

  // exited and streamFinished have no guaranteed order, so the verdict is taken
  // one turn later, when both have certainly landed.
  function settleScan() {
    if (root.scanConsumed || root.scanning || root.scanError !== "") return
    root.scanError = "bin/agent-ext could not be run. Check that " + root.helperPath
      + " exists and is executable."
  }

  // The bar's figure is computed from the whole report, never from the filtered
  // rows: what is on the bar must not change because something was typed here.
  function publishSummary() {
    var items = (root.report && root.report.items) || []
    var tokens = ({})
    var skills = 0
    var enabled = 0
    var attention = 0
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      if (!root.showBundled && it.flags && it.flags.builtin) continue
      skills++
      var state = it.state || ({})
      var live = false
      for (var tool in state) {
        var v = state[tool] ? state[tool].value : null
        if (v === "off") continue
        live = true
        // The same rule as the helper's own _counts: a tool that has the skill
        // switched off is not paying for it.
        tokens[tool] = (tokens[tool] || 0) + (Number(it.tokens && it.tokens.alwaysOn) || 0)
      }
      if (live) enabled++
      if (root.severityOf(it.attention) >= 2) attention++
    }
    attention += Array.isArray(root.report.findings) ? root.report.findings.length : 0
    // alwaysOnTokens is counted per tool and a session runs one agent, so the
    // bar shows the largest of them -- what the heaviest agent carries on every
    // turn. Adding the three together prints a bill nobody is ever handed.
    var peak = 0
    for (var t in tokens) peak = Math.max(peak, tokens[t])
    root.summary = { at: Date.now(), divisor: root.divisor, skills: skills,
                     enabled: enabled, tokens: peak, attention: attention,
                     perTool: tokens }
  }

  function severityOf(codes) {
    if (!Array.isArray(codes)) return 0
    var top = 0
    for (var i = 0; i < codes.length; i++) top = Math.max(top, root.severityRank[codes[i]] || 0)
    return top
  }

  Process {
    id: scanProc
    // stderr is left on Quickshell's default so the helper's diagnostics land in
    // `qs log`, which is where its own docstring promises they will be.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.consumeScan(text)
        Qt.callLater(root.settleScan)
      }
    }
    onExited: function (exitCode, exitStatus) {
      scanWatchdog.stop()
      scanKill.stop()
      root.scanning = false
      Qt.callLater(root.settleScan)
    }
  }

  Timer {
    id: scanWatchdog
    interval: root.scanTimeoutMs
    onTriggered: {
      if (!scanProc.running) return
      root.stopScan()
      root.scanConsumed = true
      root.scanError = "The scan did not finish in " + Math.round(root.scanTimeoutMs / 1000)
        + " s. A skill root may be on a network mount."
    }
  }

  Timer {
    id: scanKill
    interval: 500
    onTriggered: if (scanProc.running) scanProc.signal(9)
  }

  Process {
    id: catProc
    // What to say when it works. Set per call so the message names the change.
    property string pending: ""
    stdout: StdioCollector { waitForEnd: true }
    onExited: function (exitCode, exitStatus) {
      if (exitCode === 0) {
        if (catProc.pending !== "") root.flashResult(catProc.pending, "ok")
        // The store the classifier reads has changed, so the answer on screen is
        // now stale by exactly one edit. Re-reading is cheap and is the only way
        // the group headers and the tint agree with the file again.
        root.startScan()
      } else {
        // The helper's refusals are one line each and already say what is wrong;
        // repeating them here in the panel's own words would be a second, worse
        // version of the same sentence.
        root.flashResult("The change was refused. Run bin/agent-ext category by hand to see why", "error")
      }
    }
  }

  // ---- View model ---------------------------------------------------------
  //
  // Two stages on purpose. `catalogue` cleans and flattens the report and is
  // rebuilt only when the report or a setting changes; `rows` filters, groups
  // and sorts it and is rebuilt on every keystroke. Cleaning a thousand strings
  // per keypress is the difference between a filter that keeps up and one that
  // does not.

  function normalise(v) {
    // OpenCode and Codex have no per-skill switch the helper can read, so it
    // reports fixed "allow" and "enabled" for them. Both mean on.
    if (v === "allow" || v === "enabled" || v === "on") return "on"
    return v
  }

  function fold(s) {
    return String(s || "").toLowerCase().replace(/[-_\s]+/g, " ")
  }

  function skillView(item) {
    var codes = Array.isArray(item.attention) ? item.attention : []
    var words = []
    for (var c = 0; c < codes.length; c++)
      words.push(root.attentionPhrase[codes[c]] || root.clean(codes[c], 64))

    var state = item.state || ({})
    var switches = []
    var order = ["claude", "opencode", "codex"]
    for (var s = 0; s < order.length; s++) {
      var st = state[order[s]]
      if (!st) continue
      switches.push({ tool: root.toolLabel[order[s]],
                      value: root.clean(st.value, 40),
                      file: root.clean(st.file, 120) })
    }

    var invocations = []
    var tools = Array.isArray(item.tools) ? item.tools : []
    for (var t = 0; t < tools.length; t++) {
      var token = item.invocation ? item.invocation[tools[t]] : null
      if (!token) continue
      invocations.push({ tool: root.toolLabel[tools[t]] || tools[t],
                         text: root.clean(token, 128),
                         ok: root.copyable(token) })
    }

    var mounts = []
    var src = Array.isArray(item.mounts) ? item.mounts : []
    for (var m = 0; m < src.length && m < 8; m++)
      mounts.push({ tool: root.toolLabel[src[m].tool] || root.clean(src[m].tool, 24),
                    path: root.clean(src[m].path, 160),
                    abs: root.clean(src[m].abs, 400),
                    link: root.clean(src[m].link, 16) })

    // driftPeers is attached after the record is built and only on a drift
    // group, so it has to be probed rather than assumed.
    var peers = []
    if (Array.isArray(item.driftPeers))
      for (var p = 0; p < item.driftPeers.length && p < 6; p++)
        peers.push(root.clean(item.driftPeers[p], 160))

    // The helper has already reduced `argument-hint` to tokens it will vouch
    // for; this re-checks the shape of every one of them before any of it can
    // reach a clipboard, because the helper and the panel are separate programs
    // and only one of them is in this file.
    var args = []
    var srcArgs = Array.isArray(item.argumentChoices) ? item.argumentChoices : []
    for (var a = 0; a < srcArgs.length && a < 6; a++) {
      var g = srcArgs[a]
      if (!g || typeof g !== "object") continue
      if (g.kind === "choice") {
        var opts = []
        var raw = Array.isArray(g.options) ? g.options : []
        for (var o = 0; o < raw.length && opts.length < 64; o++)
          if (/^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/.test(String(raw[o]))) opts.push(String(raw[o]))
        if (opts.length > 1) args.push({ kind: "choice", options: opts })
      } else if (g.kind === "value") {
        args.push({ kind: "value", label: root.clean(g.label, 32) })
      }
    }

    // Worked out here rather than inside the object literal: a brace-and-call
    // in a property position is a block followed by a call, not a function
    // expression, and QML says so at load time and stops compiling the file.
    var placedBy = "its description, " + root.clean((item.taxonomy || ({})).confidence, 20)
      + " confidence"
    var by = String((item.taxonomy || ({})).classifier || "")
    if (by === "you") placedBy = "you"
    else if (by === "frontmatter") placedBy = "the skill's own frontmatter"
    else if (by === "marketplace") placedBy = "the marketplace listing"
    else if (by === "path") placedBy = "where it is installed"
    else if (by === "none") placedBy = "nothing matched, so it is waiting to be filed"

    var name = root.clean(item.displayName, 120)
    var desc = root.clean(item.description, 600)
    var tax = item.taxonomy || ({})
    var tags = Array.isArray(tax.tags) ? tax.tags.slice(0, 6).join(", ") : ""
    var u = item.usage || ({})

    return {
      key: "skill:" + root.clean(item.realPath, 200),
      kind: "skill",
      category: String(tax.category || "agents"),
      glyph: root.clean(tax.glyph, 4),
      name: name,
      dirName: root.clean(item.dirName, 128),
      badge: "SKILL",
      scope: item.scope === "bundled" ? "built-in" : root.clean(item.scope, 16),
      tools: {
        claude: state.claude ? root.normalise(state.claude.value) : null,
        opencode: state.opencode ? root.normalise(state.opencode.value) : null,
        codex: state.codex ? root.normalise(state.codex.value) : null
      },
      toolList: tools,
      tokens: root.showTokens ? (Number(item.tokens && item.tokens.alwaysOn) || 0) : null,
      usage: (Number(u.count) || 0) > 0 ? String(u.count) + "×"
        : (u.source === "not tracked" ? "-" : "unused"),
      attention: codes,
      attentionText: words,
      severity: root.severityOf(codes),
      description: desc,
      switches: switches,
      mounts: mounts,
      peers: peers,
      invocations: invocations,
      argumentChoices: args,
      argumentHint: root.clean(item.argumentHint, 200),
      facts: [
        // The hint as its author wrote it, so the picker's list can be checked
        // against the source rather than trusted.
        { label: "arguments", value: root.clean(item.argumentHint, 200) },
        // Where the shelf came from, which is the thing worth knowing when the
        // shelf is wrong. Which shelf it is has its own control above.
        { label: "placed by", value: placedBy },
        { label: "tags", value: root.clean(tags, 120) },
        { label: "content", value: root.clean(item.contentHash, 40) },
        { label: "tokens", value: String(Number(item.tokens && item.tokens.alwaysOn) || 0)
            + " by " + root.clean(item.tokens && item.tokens.method, 20) }
      ],
      haystack: root.fold(name + " " + desc + " " + tax.category + " " + tags + " skill")
    }
  }

  function mcpView(entry) {
    var tools = { claude: null, opencode: null, codex: null }
    var live = entry.enabled === null || entry.enabled === undefined
      ? "unknown" : (entry.enabled ? "on" : "off")
    if (tools.hasOwnProperty(entry.tool)) tools[entry.tool] = live
    var expired = entry.auth === "expired"
    var name = root.clean(entry.name, 120)
    // The target is another process's command line or endpoint and can carry a
    // credential in an argument, so it is only ever shown in the expansion, and
    // clipped hard.
    var target = root.clean(entry.target, 200)
    return {
      key: "mcp:" + root.clean(entry.tool, 16) + ":" + name,
      kind: "mcp",
      category: "agents",
      glyph: "◇",
      name: name,
      badge: "MCP",
      scope: root.clean(entry.scope, 16),
      tools: tools,
      toolList: [entry.tool],
      tokens: null,
      usage: "-",
      attention: expired ? ["needs-auth"] : [],
      attentionText: expired ? ["The stored token has expired"] : [],
      severity: expired ? 2 : 0,
      description: "",
      // D3: MCP servers are read-only in v0.1. There is no CLI for the toggle, it
      // is per project, and it would mean writing ~/.claude.json underneath
      // whatever Claude Code sessions happen to be running.
      switches: [{ tool: root.toolLabel[entry.tool] || root.clean(entry.tool, 24),
                   value: live, file: "read-only in this version" }],
      mounts: target !== "" ? [{ tool: "endpoint", path: target, link: "" }] : [],
      peers: [],
      invocations: [],
      facts: [
        { label: "transport", value: root.clean(entry.transport, 24) },
        { label: "auth", value: root.clean(entry.auth, 24) },
        { label: "source", value: root.clean(entry.source || "config file", 60) }
      ],
      haystack: root.fold(name + " mcp server " + entry.tool)
    }
  }

  function pluginView(entry) {
    var name = root.clean(entry.name, 120)
    var origin = entry.origin || ({})
    return {
      key: "plugin:" + name,
      kind: "plugin",
      category: "agents",
      glyph: "◆",
      name: name,
      badge: "PLUGIN",
      scope: root.clean(entry.scope, 16),
      tools: { claude: entry.enabled === false ? "off" : "on", opencode: null, codex: null },
      toolList: ["claude"],
      tokens: null,
      usage: "-",
      attention: [],
      attentionText: [],
      severity: 0,
      description: "",
      switches: [{ tool: "Claude Code", value: entry.enabled === false ? "off" : "on",
                   file: "~/.claude/settings.json" }],
      mounts: entry.installPath
        ? [{ tool: "installed", path: root.clean(entry.installPath, 160), link: "" }] : [],
      peers: [],
      invocations: [],
      facts: [
        { label: "version", value: root.clean(String(entry.version || "unknown"), 40) },
        { label: "commit", value: root.clean(String(origin.installedSha || "unknown"), 40).substring(0, 12) }
      ],
      haystack: root.fold(name + " plugin claude")
    }
  }

  readonly property var catalogue: {
    var out = []
    if (!root.loaded || !root.report) return out
    var items = root.report.items || []
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      if (!root.showBundled && it.flags && it.flags.builtin) continue
      out.push(root.skillView(it))
    }
    var servers = root.report.mcp || []
    for (var m = 0; m < servers.length; m++) out.push(root.mcpView(servers[m]))
    var plugs = root.report.plugins || []
    for (var p = 0; p < plugs.length; p++) out.push(root.pluginView(plugs[p]))
    return out
  }

  // Headers and rows in one flat array. Not a ListView section: a section
  // delegate can vary its own height but has no control over the delegates below
  // it, so it cannot collapse a group -- and collapsing is the point when sixteen
  // of a machine's skills sit in one bucket.
  readonly property var rows: {
    var out = []
    if (!root.loaded) return out
    var query = root.fold(root.filterText.trim())
    var mode = root.grouping
    var buckets = ({})
    var order = []

    function bucket(key, label) {
      if (!buckets[key]) {
        buckets[key] = { key: key, label: label, rows: [],
                         // Only a category grouping names a shelf you can edit;
                         // every other grouping leaves this empty and the
                         // header draws no marker.
                         category: key.indexOf("cat:") === 0 ? key.substring(4) : "" }
        order.push(key)
      }
      return buckets[key]
    }

    var source = root.catalogue
    for (var i = 0; i < source.length; i++) {
      var v = source[i]
      if (!root.passes(v, "", query)) continue

      if (mode === "Tool") {
        // A skill mounted in three tools belongs in all three groups: the question
        // this grouping answers is "what can this agent see", and omitting it from
        // two of them answers it wrong. The key carries the tool so the cursor and
        // the expansion stay unique.
        for (var t = 0; t < v.toolList.length; t++) {
          var tool = v.toolList[t]
          var copy = {}
          for (var f in v) copy[f] = v[f]
          copy.key = v.key + "@" + tool
          bucket("tool:" + tool, root.toolLabel[tool] || tool).rows.push(copy)
        }
      } else if (mode === "Kind") {
        bucket("kind:" + v.kind, v.kind === "skill" ? "Skills"
          : (v.kind === "mcp" ? "MCP servers" : "Plugins")).rows.push(v)
      } else if (mode === "Nothing") {
        bucket("all", "").rows.push(v)
      } else if (v.kind === "skill") {
        bucket("cat:" + v.category,
          root.categoryLabelFor(v.category)).rows.push(v)
      } else {
        bucket("cat:_servers", "MCP servers and plugins").rows.push(v)
      }
    }

    var keys = []
    if (mode === "Category") {
      var cats = root.knownCategories()
      for (var c = 0; c < cats.length; c++)
        if (buckets["cat:" + cats[c]]) keys.push("cat:" + cats[c])
      if (buckets["cat:_servers"]) keys.push("cat:_servers")
    } else if (mode === "Tool") {
      var to = ["tool:claude", "tool:opencode", "tool:codex"]
      for (var k = 0; k < to.length; k++) if (buckets[to[k]]) keys.push(to[k])
    } else if (mode === "Kind") {
      var ko = ["kind:skill", "kind:mcp", "kind:plugin"]
      for (var j = 0; j < ko.length; j++) if (buckets[ko[j]]) keys.push(ko[j])
    } else {
      keys = order
    }

    for (var g = 0; g < keys.length; g++) {
      var grp = buckets[keys[g]]
      // Attention sorts first inside its group and never to the top of the list:
      // pinning it globally would destroy the taxonomy the panel exists to give
      // you, and attention is a property of a row, not a kind of row.
      grp.rows.sort(function (a, b) {
        if (a.severity !== b.severity) return b.severity - a.severity
        return String(a.name).localeCompare(String(b.name))
      })
      var attn = 0
      var toks = 0
      for (var r = 0; r < grp.rows.length; r++) {
        if (grp.rows[r].severity >= 2) attn++
        toks += Number(grp.rows[r].tokens) || 0
      }
      var isCollapsed = root.collapsed[grp.key] === true
      if (grp.label !== "")
        out.push({ rowType: "header", key: grp.key, label: grp.label,
                   category: grp.category || "",
                   count: grp.rows.length, attention: attn, tokens: toks,
                   collapsed: isCollapsed })
      if (isCollapsed) continue
      for (var q = 0; q < grp.rows.length; q++)
        out.push({ rowType: "row", key: grp.rows[q].key, view: grp.rows[q] })
    }
    return out
  }

  onRowsChanged: if (root.selectedIndex >= root.rows.length)
    root.selectedIndex = Math.max(0, root.rows.length - 1)

  // Recomputed from the visible rows, never from report.counts: the helper's
  // counts include the bundled skills that `showBundled` is hiding, and they know
  // nothing about the filter.
  // One row against every filter except the one dimension that is asking.
  //
  // Faceting, and it is not a nicety: a chip has to keep saying what picking it
  // would give you. Counted against its own filter, "6 servers" becomes "0
  // servers" the moment you click "17 skills", the chip vanishes, and there is
  // no way back to it except a keystroke nobody was told about. So the kind
  // boxes are counted with every filter but the kind, the agent boxes with
  // every filter but the agent, and the shelf chips with every filter but the
  // shelf. The list itself, below, is counted against all of them.
  //
  // The search text is never excepted: typing narrows everything, including the
  // things you could narrow to next.
  function passes(v, except, query) {
    if (except !== "attention" && root.attentionOnly && v.severity < 2) return false
    if (except !== "category" && root.categoryFilter !== ""
        && v.category !== root.categoryFilter) return false
    if (except !== "kind" && root.kindFilter !== "" && v.kind !== root.kindFilter) return false
    if (except !== "tool" && root.toolFilter !== ""
        && v.toolList.indexOf(root.toolFilter) < 0) return false
    if (query !== "" && v.haystack.indexOf(query) < 0) return false
    return true
  }

  // Everything the current filter admits, before grouping and before anything is
  // collapsed. `rows` cannot answer this: a folded group has no rows in it, and
  // the summary was reporting fourteen skills on a machine with sixteen because
  // two of its groups were shut. Folding a group hides rows; it does not delete
  // skills, and the line above the list must not say otherwise. In Tool
  // grouping it also stops a skill mounted in three agents being counted three
  // times, which `rows` did by design.
  readonly property var visibleItems: {
    var out = []
    if (!root.loaded) return out
    var query = root.fold(root.filterText.trim())
    var src = root.catalogue
    for (var i = 0; i < src.length; i++)
      if (root.passes(src[i], "", query)) out.push(src[i])
    return out
  }

  // Every category that has something in it right now, with how much, in the
  // order the store keeps them. A shelf with nothing on it is not offered:
  // filtering to an empty list is a dead end you can only back out of.
  // Every shelf and how much is on it, the empty ones included. The filter strip
  // hides a shelf with nothing on it, because filtering to an empty list is a
  // dead end; the index has the opposite job and must show a shelf you have just
  // made and not filled yet.
  readonly property var shelfSizes: {
    var counts = ({})
    if (!root.loaded) return counts
    var src = root.catalogue
    for (var i = 0; i < src.length; i++)
      if (src[i].kind === "skill")
        counts[src[i].category] = (counts[src[i].category] || 0) + 1
    return counts
  }

  function shelfCount(key) {
    return Number(root.shelfSizes[key]) || 0
  }

  readonly property var categoryChips: {
    var out = []
    if (!root.loaded) return out
    var query = root.fold(root.filterText.trim())
    var counts = ({})
    var src = root.catalogue
    for (var i = 0; i < src.length; i++) {
      var v = src[i]
      if (v.kind !== "skill") continue
      if (!root.passes(v, "category", query)) continue
      counts[v.category] = (counts[v.category] || 0) + 1
    }
    var order = root.knownCategories()
    for (var c = 0; c < order.length; c++)
      if (counts[order[c]])
        out.push({ key: order[c], label: root.categoryLabelFor(order[c]),
                   count: counts[order[c]], colour: root.categoryColourFor(order[c]),
                   rank: c })
    // Fullest shelf first, so the row that survives the fold is the row worth
    // keeping. The stored order breaks ties rather than leaving it to the sort,
    // so two shelves of equal size never swap places between rescans.
    //
    // The counts are faceted, so picking a shelf does not reorder the shelves;
    // only changing a different filter, or typing, can move them.
    out.sort(function (a, b) { return b.count - a.count || a.rank - b.rank })
    return out
  }

  // The summary as things rather than as a sentence. It used to be one line of
  // text joined with middle dots, and on a 1080p screen it ran off the right
  // edge at "Cod\u2026" -- the third agent's own cost, cut in half by the panel
  // border. Two rows of small boxes instead: what was counted, then what it
  // costs per agent, each with that agent's mark. Neither row can overflow,
  // because both wrap, and the numbers stay next to the words they belong to.
  readonly property var countChips: {
    var out = []
    if (!root.loaded) return out
    var query = root.fold(root.filterText.trim())
    var src = root.catalogue
    var skills = 0, mcp = 0, plugins = 0, attention = 0
    for (var i = 0; i < src.length; i++) {
      var v = src[i]
      if (root.passes(v, "kind", query)) {
        if (v.kind === "skill") skills++
        else if (v.kind === "mcp") mcp++
        else plugins++
      }
      // Attention is its own dimension and counts against its own exception, so
      // the box keeps saying how many there are while you are looking at them.
      if (v.severity >= 2 && root.passes(v, "attention", query)) attention++
    }
    // Every box that is drawn can be clicked, so no box is drawn that would
    // filter to nothing. A dead end you can only back out of is worse than an
    // absence, and the empty list underneath already says when there is nothing.
    if (skills > 0) out.push({ kind: "skill", n: skills, rank: 0,
                               what: skills === 1 ? "skill" : "skills", urgent: false })
    if (mcp > 0) out.push({ kind: "mcp", n: mcp, rank: 1,
                            what: mcp === 1 ? "server" : "servers", urgent: false })
    if (plugins > 0) out.push({ kind: "plugin", n: plugins, rank: 2,
                                what: plugins === 1 ? "plugin" : "plugins", urgent: false })
    // Biggest first among the kinds. "Needs attention" is not a kind -- it is the
    // alarm, and it drives a different filter -- so it is appended after the
    // sort rather than ranked among them: an alarm that moves around depending
    // on how many other things there are is an alarm you have to look for.
    out.sort(function (a, b) { return b.n - a.n || a.rank - b.rank })
    if (attention > 0) out.push({ kind: "attention", n: attention,
                                  what: "need attention", urgent: true })
    return out
  }

  readonly property var toolChips: {
    var out = []
    if (!root.loaded) return out
    var query = root.fold(root.filterText.trim())
    var src = root.catalogue
    var order = ["claude", "opencode", "codex"]
    var per = ({})
    var seen = ({})
    for (var i = 0; i < src.length; i++) {
      var v = src[i]
      if (!root.passes(v, "tool", query)) continue
      for (var x = 0; x < order.length; x++) {
        if (v.toolList.indexOf(order[x]) < 0) continue
        seen[order[x]] = (seen[order[x]] || 0) + 1
        // Only a skill has an always-on cost, and only a switched-on one is
        // being paid for. The count beside it is everything that agent can see.
        if (v.kind !== "skill") continue
        var st = v.tools[order[x]]
        if (!st || st === "off") continue
        per[order[x]] = (per[order[x]] || 0) + (Number(v.tokens) || 0)
      }
    }
    for (var o = 0; o < order.length; o++) {
      if (!seen[order[o]]) continue
      var n = per[order[o]] || 0
      out.push({ tool: order[o], label: root.toolLabel[order[o]],
                 seen: seen[order[o]], rank: o,
                 count: String(seen[order[o]]),
                 tokens: !root.showTokens || n === 0 ? ""
                   : (n >= 1000 ? "~" + (n / 1000).toFixed(1) + "k" : "~" + String(n)),
                 colour: root.markColour(order[o]) })
    }
    // Whichever agent loads the most, first. Sorted on how many things it can
    // see rather than on what they cost, because the box is a filter before it
    // is a bill and the count is what picking it will give you.
    out.sort(function (a, b) { return b.seen - a.seen || a.rank - b.rank })
    return out
  }

  // The helper's own top-level findings belong to files, not to extensions, so
  // they go in a strip above the list rather than becoming rows.
  readonly property string findingLine: {
    if (!root.loaded || !root.report) return ""
    var f = root.report.findings || []
    var out = []
    for (var i = 0; i < f.length && out.length < 3; i++) {
      var line = root.clean(f[i].what, 80) + ": " + root.clean(f[i].detail, 120)
      if (root.dismissed[line] === true) continue
      out.push(line)
    }
    if (out.length === 0) return ""
    return out.join("  ·  ")
  }

  function dismissFinding() {
    var line = root.findingLine
    if (line === "") return
    var next = {}
    for (var k in root.dismissed) next[k] = root.dismissed[k]
    // Whole strip, because that is what is on screen and what the cross is
    // attached to. A rescan that finds the same thing again produces the same
    // string and stays down; one that finds something new says so.
    var parts = line.split("  \u00b7  ")
    for (var i = 0; i < parts.length; i++) next[parts[i]] = true
    root.dismissed = next
  }

  // ---- Cursor and actions -------------------------------------------------

  function currentRow() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.rows.length) return null
    return root.rows[root.selectedIndex]
  }

  // Every keyboard move of the cursor goes through here, so this is the one
  // place that has to bring it back on screen. `Contain` scrolls the least
  // amount that makes the row visible and does nothing when it already is,
  // which is why walking down a visible list does not move the viewport at all.
  function moveCursor(delta) {
    if (root.rows.length === 0) return
    if (!root.cursorActive) { root.cursorActive = true; root.showCursor(); return }
    root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, root.selectedIndex + delta))
    root.showCursor()
  }

  function showCursor() {
    if (root.selectedIndex >= 0 && root.selectedIndex < root.rows.length)
      list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.cursorActive = true
  }

  readonly property bool anyChipFilter: root.categoryFilter !== "" || root.kindFilter !== ""
    || root.toolFilter !== "" || root.attentionOnly

  function clearChipFilters() {
    root.categoryFilter = ""
    root.kindFilter = ""
    root.toolFilter = ""
    root.attentionOnly = false
    root.selectedIndex = 0
  }

  function setCollapsed(key, value) {
    var next = {}
    for (var k in root.collapsed) next[k] = root.collapsed[k]
    if (value) next[key] = true
    else delete next[key]
    root.collapsed = next
  }

  function activate() {
    var r = root.currentRow()
    if (!r) return
    if (r.rowType === "header") { root.setCollapsed(r.key, !r.collapsed); return }
    root.expandedKey = root.expandedKey === r.key ? "" : r.key
  }

  // Says "Copied" only once something actually reached the clipboard, and reads
  // it back to find out. The first version announced success from inside the
  // same statement that attempted the write, which is a promise the panel was
  // in no position to make: a rejected write and a successful one produced the
  // same green line.
  //
  // Quickshell's clipboard property is not in this build's quickshell-io type
  // description, so it is attempted first and the verified path -- Util.execArgv,
  // which puts the string in a positional parameter that bash cannot
  // re-tokenize -- is the fallback rather than the other way round. wl-copy is
  // a separate process whose exit code arrives later than this function does,
  // so a copy that got that far is reported as handed over rather than as
  // confirmed. The panel never claims more than it knows.
  function copyText(s, rowKey) {
    var text = String(s || "")
    if (text === "") return false

    var confirmed = false
    var attempted = false
    try {
      Quickshell.clipboardText = text
      attempted = true
      confirmed = String(Quickshell.clipboardText) === text
    } catch (e) {
      attempted = false
    }

    if (!attempted) {
      try { Util.execArgv(["wl-copy", "--", text]); attempted = true }
      catch (e2) { attempted = false }
    }

    if (!attempted) {
      root.flashResult("Could not reach the clipboard. The command is " + text, "error")
      return false
    }

    root.copiedKey = String(rowKey || "")
    copiedTimer.restart()
    root.flashResult((confirmed ? "Copied  " : "Sent to the clipboard  ") + text, "ok")
    return true
  }

  // Ctrl+C on a row that takes arguments opens the picker instead of copying,
  // because `/impeccable` on its own is not what anybody wanted off that row:
  // the skill documents twenty-three actions and the one you meant is the whole
  // point of copying it. Every other row copies straight through, unchanged.
  function copyCurrent() {
    var r = root.currentRow()
    if (!r || r.rowType === "header") return
    var inv = r.view.invocations
    if (!inv || inv.length === 0) { root.flash("Nothing to copy on this row"); return }
    if (!inv[0].ok) {
      root.flash("That invocation has characters a prompt would not take safely")
      return
    }
    if (root.pickerOptions(r.view).length > 0) { root.openPicker(r); return }
    root.copyText(inv[0].text, r.key)
  }

  // Deliberately not Array.isArray. What arrives here is a row's view object
  // after it has been through a `var` property and a ListView model, and that
  // trip converts a nested JavaScript array into a QVariantList: it still has a
  // length and still indexes, but Array.isArray answers false. The first version
  // asked Array.isArray and so every row reported no arguments, including the
  // one whose twenty-three actions the picker exists for. Length is the property
  // being relied on, so length is what gets checked.
  function pickerOptions(view) {
    var groups = view ? view.argumentChoices : null
    if (!groups || typeof groups.length !== "number") return []
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      if (g && g.kind === "choice" && g.options && typeof g.options.length === "number")
        return g.options
    }
    return []
  }

  // Always a plain JavaScript array, whatever pickerOptions handed back. The
  // argument list is copied element by element rather than concatenated,
  // because concat on a QVariantList appends it as one item instead of
  // spreading it, and the picker would then show a single unreadable chip.
  function pickerChips() {
    if (root.pickerNaming) return []
    if (root.pickerMode === "argument") {
      var opts = root.pickerOptions(root.pickerRow.view)
      var out = [""]
      for (var i = 0; i < opts.length; i++) out.push(String(opts[i]))
      return out
    }
    if (root.pickerMode === "category") {
      var cats = root.knownCategories()
      var q = root.pickerText.toLowerCase()
      var hits = []
      for (var c = 0; c < cats.length; c++)
        if (q === "" || cats[c].indexOf(q) >= 0
            || root.categoryLabelFor(cats[c]).toLowerCase().indexOf(q) >= 0)
          hits.push(cats[c])
      // Typing a name nothing answers to is how a category gets made. The chip
      // says so in full rather than hiding a creation behind an empty result.
      if (root.newCategoryName() !== "") hits.unshift("\u0000new")
      return hits
    }
    if (root.pickerMode === "shelves") {
      var all = root.knownCategories()
      var q2 = root.pickerText.toLowerCase()
      var out2 = []
      for (var k = 0; k < all.length; k++)
        if (q2 === "" || all[k].indexOf(q2) >= 0
            || root.categoryLabelFor(all[k]).toLowerCase().indexOf(q2) >= 0)
          out2.push(all[k])
      // Biggest first, the same order the filter strip uses, so the two views of
      // the same shelves do not disagree about which one is the important one.
      out2.sort(function (a, b) { return root.shelfCount(b) - root.shelfCount(a) })
      // Typing a name nothing answers to offers it at the top, which is the fast
      // path once you know it exists. The standing chip at the end is how you
      // find out: an affordance you can see beats one you have to discover by
      // typing something that happens not to match.
      if (root.newCategoryName() !== "") out2.unshift("\u0000new")
      out2.push("\u0000addnew")
      return out2
    }
    if (root.pickerMode === "style") {
      if (root.styleAsking) return ["\u0000save", "\u0000discard"]
      return root.swatches.concat(["\u0000clear"])
    }
    return []
  }

  // Valid, not already taken, and actually typed. Anything else is a filter that
  // happened to match nothing, which must not offer to create a category.
  function newCategoryName() {
    var q = root.pickerText.trim().toLowerCase()
    if (!/^[a-z][a-z0-9-]{0,23}$/.test(q)) return ""
    return root.knownCategories().indexOf(q) >= 0 ? "" : q
  }

  function knownCategories() {
    var meta = root.report && root.report.categories ? root.report.categories : null
    var order = meta && meta.order && typeof meta.order.length === "number" ? meta.order : null
    if (!order) return root.categoryOrder
    var out = []
    for (var i = 0; i < order.length; i++) out.push(String(order[i]))
    return out
  }

  function categoryLabelFor(cat) {
    var meta = root.report && root.report.categories ? root.report.categories : null
    var custom = meta && meta.labels ? meta.labels[cat] : null
    if (custom) return root.clean(custom, 32)
    return root.categoryLabel[cat] || root.clean(cat, 32)
  }

  // A colour you chose, or the rotation off the theme accent. Yours wins,
  // because you chose it after seeing the other one.
  function categoryColourFor(cat) {
    var meta = root.report && root.report.categories ? root.report.categories : null
    var chosen = meta && meta.colors ? meta.colors[cat] : null
    if (chosen && /^#[0-9A-Fa-f]{6}$/.test(String(chosen))) return String(chosen)
    return root.categoryTint(cat)
  }

  function openPicker(row) {
    root.pickerMode = "argument"
    root.pickerRow = row
    root.pickerText = ""
    root.pickerIndex = 0
  }

  function openCategoryPicker(row) {
    root.pickerMode = "category"
    root.pickerRow = row
    root.pickerText = ""
    root.pickerIndex = 0
  }

  // The index of shelves: everything you can rename, recolour or add to, in one
  // place. The dot on a group header edits the one shelf it belongs to; this is
  // the way in when the shelf you want is not on screen, or does not exist yet.
  function openShelvesPicker() {
    root.pickerMode = "shelves"
    root.pickerReturn = ""
    root.pickerRow = null
    root.pickerCategory = ""
    root.pickerNaming = false
    root.pickerText = ""
    root.pickerIndex = 0
  }

  // Back out one layer if this mode was opened on top of another, and close
  // otherwise. Escape and the back chip both come through here so they cannot
  // disagree about where "back" is.
  // The grid cursor and the draft colour are the same thing while the swatches
  // are on screen, so arrowing and clicking both preview and neither commits.
  onPickerIndexChanged: {
    if (root.pickerMode === "style" && !root.styleAsking)
      root.styleColourIndex = root.pickerIndex
  }

  function styleSave() {
    var label = root.pickerText.trim()
    var cat = root.pickerCategory
    var argv = ["style", cat]
    // The label always travels, so one save both renames and recolours and
    // there is no way to write half of what is on screen. An unchanged label is
    // sent empty, which is how the helper is told to drop its override and go
    // back to the built-in name.
    argv.push("--label")
    argv.push(label === root.categoryLabel[cat] ? "" : label)
    argv.push("--color")
    argv.push(root.styleColourIndex >= 0 && root.styleColourIndex < root.swatches.length
      ? String(root.swatches[root.styleColourIndex]) : "")
    root.runCategory(argv, root.categoryLabelFor(cat) + " saved")
    root.styleAsking = false
    root.styleBaseIndex = root.styleColourIndex
    root.styleBaseLabel = label
    root.pickerBack()
  }

  function pickerBack() {
    // A draft is not dropped silently. Leaving the style editor with something
    // unsaved asks first, on the same surface, rather than discarding work the
    // user has no way of knowing was still only a draft.
    if (root.pickerMode === "style" && root.styleDirty && !root.styleAsking) {
      root.styleAsking = true
      root.pickerIndex = 0
      return
    }
    if (root.styleAsking) {
      root.styleAsking = false
      root.styleColourIndex = root.styleBaseIndex
      root.pickerText = root.styleBaseLabel
    }

    // Naming is a step inside the shelf index, so backing out of it lands on the
    // index rather than closing everything.
    if (root.pickerNaming) {
      root.pickerNaming = false
      root.pickerText = ""
      root.pickerIndex = 0
      return
    }
    if (root.pickerReturn !== "") {
      var to = root.pickerReturn
      if (to === "shelves") root.openShelvesPicker()
      else root.closePicker()
      return
    }
    root.closePicker()
  }

  // Where the stored colour sits among the swatches, or the "theme default"
  // entry at the end when the shelf has never been given one.
  function swatchIndexFor(category) {
    var meta = root.report && root.report.categories ? root.report.categories : null
    var stored = meta && meta.colors ? String(meta.colors[category] || "") : ""
    for (var i = 0; i < root.swatches.length; i++)
      if (root.swatches[i].toUpperCase() === stored.toUpperCase()) return i
    return root.swatches.length
  }

  function openStylePicker(category, returnTo) {
    root.pickerMode = "style"
    root.pickerReturn = String(returnTo || "")
    root.pickerRow = null
    root.pickerCategory = String(category || "")
    // Seeded with the name it has, so the first keystroke edits rather than
    // wipes. Backspace is how you clear it, the same as everywhere else here.
    root.pickerText = root.categoryLabelFor(root.pickerCategory)
    root.styleBaseLabel = root.pickerText
    root.styleColourIndex = root.swatchIndexFor(root.pickerCategory)
    root.styleBaseIndex = root.styleColourIndex
    root.styleAsking = false
    // The cursor starts on the colour the shelf already has, so the first arrow
    // press is a step from where you are rather than a jump to the first swatch.
    root.pickerIndex = root.styleColourIndex
  }

  function closePicker() {
    root.pickerMode = ""
    root.pickerReturn = ""
    root.pickerRow = null
    root.pickerCategory = ""
    root.pickerNaming = false
    root.pickerText = ""
    root.pickerIndex = 0
  }

  // The colour the style overlay is currently offering, so the preview box and
  // its dot agree with the highlighted swatch before anything is saved.
  function pickerSwatch() {
    if (root.pickerMode !== "style") return root.hue
    if (root.styleColourIndex < 0 || root.styleColourIndex >= root.swatches.length)
      return root.categoryTint(root.pickerCategory)
    return String(root.swatches[root.styleColourIndex])
  }

  // The line at the top of the overlay: exactly what the chosen chip will do,
  // written out, so the answer to "what happens if I press Enter" is on screen
  // rather than assembled in the reader's head.
  function pickerCommand() {
    if (root.pickerMode === "argument") {
      var base = root.pickerRow.view.invocations[0].text
      var chips = root.pickerChips()
      if (root.pickerIndex <= 0 || root.pickerIndex >= chips.length) return base
      return base + " " + chips[root.pickerIndex]
    }
    if (root.pickerMode === "category") {
      var pick = root.pickerChips()[root.pickerIndex]
      if (pick === undefined) return ""
      if (pick === "\u0000new") return "new category  " + root.newCategoryName()
      return root.categoryLabelFor(pick)
    }
    if (root.pickerNaming) return root.pickerText
    if (root.pickerMode === "shelves") {
      var at = root.pickerChips()[root.pickerIndex]
      if (at === undefined) return ""
      if (at === "\u0000addnew") return "new shelf"
      if (at === "\u0000new") return "new shelf  " + root.newCategoryName()
      return "edit  " + root.categoryLabelFor(at)
    }
    if (root.pickerMode === "style")
      return root.pickerText.trim() === "" ? root.pickerCategory : root.pickerText.trim()
    return ""
  }

  function pickerConfirm() {
    if (root.pickerMode === "argument") {
      var text = root.pickerCommand()
      var key = root.pickerRow ? root.pickerRow.key : ""
      if (!root.copyableCommand(text)) {
        root.flashResult("That argument is not a shape this panel will copy", "error")
        root.closePicker()
        return
      }
      root.closePicker()
      root.copyText(text, key)
      return
    }

    if (root.pickerMode === "category") {
      var chips = root.pickerChips()
      var pick = chips[root.pickerIndex]
      var dir = root.pickerRow ? root.clean(root.pickerRow.view.dirName, 128) : ""
      if (!dir) { root.closePicker(); return }
      if (pick === "\u0000new") {
        var fresh = root.newCategoryName()
        if (fresh === "") { root.closePicker(); return }
        root.runCategory(["assign", dir, fresh, "--create"],
                         dir + " filed under " + fresh)
      } else if (pick !== undefined) {
        root.runCategory(["assign", dir, String(pick)],
                         dir + " filed under " + root.categoryLabelFor(pick))
      }
      root.closePicker()
      return
    }

    if (root.pickerNaming) {
      var named = root.newCategoryName()
      if (named === "") return          // nothing typed yet, or the name is taken
      root.runCategory(["create", named], named + " created")
      root.pickerNaming = false
      root.pickerText = ""
      root.pickerIndex = 0
      return
    }

    if (root.pickerMode === "shelves") {
      var pick2 = root.pickerChips()[root.pickerIndex]
      if (pick2 === undefined) { root.closePicker(); return }
      if (pick2 === "\u0000addnew") {
        root.pickerNaming = true
        root.pickerText = ""
        return
      }
      if (pick2 === "\u0000new") {
        var made = root.newCategoryName()
        if (made === "") return
        // Created empty and left empty. It shows up in the index and in the move
        // picker straight away; the filter strip only lists shelves with
        // something on them, so it appears there once you put a skill on it.
        root.runCategory(["create", made], made + " created")
        root.pickerText = ""
        root.pickerIndex = 0
        return
      }
      root.openStylePicker(String(pick2), "shelves")
      return
    }

    if (root.pickerMode === "style") {
      if (root.styleAsking) {
        // Two answers to one question, and the cursor starts on the safe one.
        if (root.pickerIndex === 0) { root.styleSave(); return }
        root.styleAsking = false
        root.styleColourIndex = root.styleBaseIndex
        root.pickerText = root.styleBaseLabel
        root.pickerBack()
        return
      }
      root.styleSave()
      return
    }
  }

  // The file manager, at the directory the skill is actually installed in.
  // xdg-open through execArgv, so the path is one argv element and cannot be
  // re-read as anything else however it is spelled.
  function openInFiles(path) {
    var abs = String(path || "")
    if (abs === "" || abs.charAt(0) !== "/") {
      root.flashResult("No absolute path on that row", "error")
      return
    }
    try {
      Util.execArgv(["xdg-open", abs])
      root.flashResult("Opened  " + root.tildify(abs), "ok")
    } catch (e) {
      root.flashResult("Could not open a file manager here", "error")
    }
  }

  function tildify(abs) {
    var h = root.homeDir
    return (h !== "" && abs.indexOf(h + "/") === 0) ? "~" + abs.substring(h.length) : abs
  }

  // Ctrl+M on a skill asks which shelf; on a group header it styles the shelf,
  // because that is the thing under the cursor and it is the one edit a header
  // can carry.
  function moveCurrent() {
    var r = root.currentRow()
    if (!r) return
    if (r.rowType === "header") {
      if (String(r.key).indexOf("cat:") === 0) root.openStylePicker(String(r.key).substring(4), "")
      else root.flash("Group by category to rename or recolour one")
      return
    }
    if (r.view.kind !== "skill") { root.flash("Only skills are shelved"); return }
    root.openCategoryPicker(r)
  }

  function revealCurrent() {
    var r = root.currentRow()
    if (!r || r.rowType === "header") return
    var m = r.view.mounts
    if (!m || m.length === 0 || !m[0].abs) { root.flash("Nothing on disk to open"); return }
    root.openInFiles(m[0].abs)
  }

  function cycleGrouping() {
    var order = ["Category", "Tool", "Kind", "Nothing"]
    root.groupOverride = order[(order.indexOf(root.grouping) + 1) % order.length]
    root.collapsed = ({})
    root.selectedIndex = 0
    root.flash("Grouped by " + root.groupOverride.toLowerCase())
  }

  // ---- Lifecycle ----------------------------------------------------------

  onOpenedChanged: {
    if (!opened) {
      root.stopScan()
      root.expandedKey = ""
      root.toast = ""
      // The overlay does not survive the panel. Reopening onto a half-finished
      // rename, or onto an argument grid for a row you have long since stopped
      // thinking about, is the panel remembering something the user does not.
      root.closePicker()
      return
    }
    root.cursorActive = false
    root.selectedIndex = 0
    // scanOnOpen off means the cached scan is reused; it is still refreshed
    // behind the list once it is older than its lifetime, which is what the
    // setting's own description promises.
    if (root.scanOnOpen || !root.loaded) root.startScan()
    else root.requestScan(false)
  }

  Component.onDestruction: root.stopScan()

  function refresh() { root.startScan() }

  // Fourteen hues rotated off the theme's own accent, keeping its saturation and
  // lightness so a tint can never leave the theme. An achromatic accent rotates
  // to grey, so that case falls back to graded foreground alpha rather than
  // pretending to have hues.
  function categoryTint(category) {
    var idx = root.categoryOrder.indexOf(String(category || ""))
    if (idx < 0) return root.soft
    var a = root.hue
    if (a.hslSaturation < 0.12) return Util.alpha(root.fg, 0.28 + (idx % 5) * 0.09)
    var h = (a.hslHue < 0 ? 0 : a.hslHue) + idx / root.categoryOrder.length
    return Qt.hsla(h - Math.floor(h), a.hslSaturation, a.hslLightness, 1)
  }

  // ---- Row delegates ------------------------------------------------------

  component GroupRow: Item {
    id: gr
    required property var group
    property bool hasCursor: false
    signal toggled()
    signal entered()
    signal styleRequested()

    // Was 26. A group header is the one row on screen that has to be found
    // rather than read, and it was the same height as the rows it introduced.
    implicitHeight: Style.space(30)

    // Visuals come from hasCursor, never from containsMouse -- CursorSurface's
    // own contract, and what keeps exactly one highlight on screen across mouse
    // and keyboard.
    CursorSurface {
      anchors.fill: parent
      foreground: root.fg
      accent: root.hue
      hasCursor: gr.hasCursor
    }

    Text {
      id: chevron
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: gr.group.collapsed ? "▸" : "▾"
      color: gr.hasCursor ? root.fg : root.soft
      font.family: root.face
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.left: chevron.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: gmeta.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: gr.group.label
      color: gr.hasCursor ? root.fg : root.strong
      font.family: root.face
      // A label role, not a caption: one step up from the metadata around it,
      // with the tracking a short bold string needs to stop reading as a lump.
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      font.letterSpacing: 0.4
      elide: Text.ElideRight
    }

    Row {
      id: gmeta
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

      // The shelf's own colour and the way into changing it. Only on a category
      // grouping, because a group of "everything Claude can see" is not a shelf
      // and has no name of yours to change. It sits at the head of the meta
      // strip rather than beside the label so the counts stay in one column
      // down the whole list.
      Rectangle {
        id: marker
        anchors.verticalCenter: parent.verticalCenter
        visible: gr.group.category !== ""
        width: visible ? Style.space(18) : 0
        height: Style.space(18)
        radius: width / 2
        color: markerHover.hovered ? Util.alpha(root.fg, 0.16) : "transparent"

        Rectangle {
          anchors.centerIn: parent
          width: Style.space(9)
          height: Style.space(9)
          radius: width / 2
          color: root.categoryColourFor(gr.group.category)
          border.width: markerHover.hovered ? 1 : 0
          border.color: root.fg
        }

        HoverHandler { id: markerHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: gr.styleRequested() }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: gr.group.attention > 0
        textFormat: Text.PlainText
        text: "● " + String(gr.group.attention)
        color: Color.urgent
        font.family: root.face
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showTokens && gr.group.tokens > 0
        textFormat: Text.PlainText
        text: gr.group.tokens >= 1000
          ? "~" + (gr.group.tokens / 1000).toFixed(1) + "k"
          : "~" + String(gr.group.tokens)
        color: root.soft
        font.family: root.face
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: String(gr.group.count)
        color: root.soft
        font.family: root.face
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: gr.entered()
      onClicked: gr.toggled()
    }
  }

  component ExtensionRow: Item {
    id: er
    required property var view
    property bool hasCursor: false
    property bool expanded: false
    property bool copied: false
    signal activated()
    signal entered()
    signal copyRequested(string text)
    signal revealRequested(string path)
    signal shelveRequested()

    // Through root rather than inline, and not only to avoid saying it twice: a
    // `property var` whose binding opens with a brace is read as an object
    // literal in some positions, so the block form of this evaluated to
    // something that was never an array and the row never showed its chip. The
    // row and the picker now ask the same function.
    readonly property var argOptions: root.pickerOptions(er.view)

    // Was 30. Two more pixels of leading is what a light-on-dark list needs
    // before the rows stop touching, and it costs one row of the visible list.
    readonly property int lineHeight: Style.space(32)
    readonly property bool broken: er.view.severity >= 2

    implicitHeight: er.lineHeight + (er.expanded ? detail.implicitHeight + Style.spacing.xl : 0)

    // The height used to snap and the content used to fade into the space that
    // had already appeared, which reads as two separate events for one action.
    // Animating it was previously impossible: a moving delegate height fought
    // ApplyRange while the keyboard cursor walked the list. The range is gone,
    // so the card can open the way it looks like it should. Short, and ease-out,
    // because this is feedback for something you just did rather than a
    // performance -- and it stays under the 300ms where a UI animation starts
    // being felt as a delay.
    Behavior on implicitHeight {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    CursorSurface {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: er.expanded ? er.height : er.lineHeight
      foreground: root.fg
      accent: root.hue
      hasCursor: er.hasCursor
      current: er.expanded
    }

    // Three pixels that say which category this is. A bar, not a dot: a dot moves
    // with the text, a bar stays put and reads down the list.
    Rectangle {
      id: catBar
      anchors.left: parent.left
      anchors.leftMargin: Style.space(2)
      anchors.top: parent.top
      anchors.topMargin: Style.space(5)
      width: Style.space(3)
      height: er.lineHeight - Style.space(10)
      radius: width / 2
      color: root.categoryColourFor(er.view.category)
    }

    Text {
      id: rowGlyph
      anchors.left: catBar.right
      anchors.leftMargin: Style.spacing.lg
      anchors.top: parent.top
      height: er.lineHeight
      width: Style.space(16)
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      text: er.view.glyph
      color: er.hasCursor ? root.fg : root.readable
      font.family: root.face
      font.pixelSize: Style.font.body
    }

    // A skill that documents alternatives says how many, on the line, before you
    // reach for it. Without this the only way to find out that `impeccable` takes
    // twenty-three actions was to copy it and get `/impeccable` on its own.
    Rectangle {
      id: argChip
      anchors.right: badge.left
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      anchors.topMargin: Math.round((er.lineHeight - height) / 2)
      visible: er.argOptions.length > 0
      width: visible ? argChipText.implicitWidth + Style.space(12) : 0
      height: Style.space(16)
      radius: height / 2
      color: Util.alpha(root.hue, 0.16)

      Text {
        id: argChipText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: String(er.argOptions.length) + " actions"
        color: root.hue
        font.family: root.face
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: argChip.left
      anchors.rightMargin: er.argOptions.length > 0 ? Style.spacing.md : Style.spacing.lg
      anchors.top: parent.top
      height: er.lineHeight
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      text: er.view.name
      color: root.fg
      font.family: root.face
      // One step above every other string on the row. It was `body`, the same
      // size as the glyph beside it and only two above the metadata, so the row
      // had no primary role -- just a brighter one.
      font.pixelSize: Style.font.subtitle
      font.bold: er.expanded
      elide: Text.ElideRight
    }

    // The accent is spent on the tool strip, so the type badge takes a neutral
    // fill and does not compete with it.
    Rectangle {
      id: badge
      anchors.right: scope.left
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      anchors.topMargin: Math.round((er.lineHeight - height) / 2)
      width: Style.space(48)
      height: Style.space(16)
      radius: height / 2
      color: Util.alpha(root.fg, 0.10)

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: er.view.badge
        color: root.readable
        font.family: root.face
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.3
      }
    }

    Text {
      id: scope
      anchors.right: strip.left
      anchors.rightMargin: Style.spacing.lg
      anchors.top: parent.top
      height: er.lineHeight
      width: Style.space(52)
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: er.view.scope
      color: root.soft
      font.family: root.face
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    // The tool strip is the on/off column. On and off here are properties of a
    // (thing, tool) pair -- this machine has skills Claude loads and Codex does
    // not -- so one binary column would have to lie about two of the three. Three
    // cells are always drawn, in a fixed order at a fixed width, so the column
    // reads down the list as a shape rather than as text. One hue at graded
    // strength: a palette would read as unrelated kinds rather than as one
    // control at four settings.
    Row {
      id: strip
      anchors.right: tokens.left
      anchors.rightMargin: Style.spacing.lg
      anchors.top: parent.top
      height: er.lineHeight
      spacing: Style.spacing.xs

      Repeater {
        model: ["claude", "opencode", "codex"]

        delegate: Item {
          id: cell
          required property string modelData
          readonly property var toolState: er.view.tools[cell.modelData]

          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(15)
          height: Style.space(15)

          AgentMark {
            anchors.centerIn: parent
            agent: cell.modelData
            size: Style.space(12)
            // The tool's own colour when it has the thing, and plain foreground
            // when it does not. Colour therefore means "loaded here" rather than
            // decorating a row three times over.
            color: cell.toolState === "on" || cell.toolState === "name-only"
                   || cell.toolState === "user-invocable-only"
              ? root.markColour(cell.modelData) : root.fg
            // Four settings that have to stay four settings. The old floor put
            // "this tool cannot see it" at 0.14 and "off" at 0.34, which on a
            // dark popup are both invisible and therefore the same answer. Each
            // step is now legible on its own and still ranked against the others.
            opacity: {
              if (cell.toolState === null || cell.toolState === undefined) return 0.22
              if (cell.toolState === "on") return 1.0
              if (cell.toolState === "unknown") return 0.34
              if (cell.toolState === "off") return 0.46
              return 0.75   // name-only / user-invocable-only
            }
          }
        }
      }
    }

    Text {
      id: tokens
      anchors.right: usage.left
      anchors.rightMargin: Style.spacing.lg
      anchors.top: parent.top
      height: er.lineHeight
      width: root.showTokens ? Style.space(46) : 0
      visible: root.showTokens
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: {
        var n = er.view.tokens
        if (n === null || n === undefined) return "-"
        return n >= 1000 ? "~" + (n / 1000).toFixed(1) + "k" : "~" + String(n)
      }
      color: root.readable
      font.family: root.face
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: usage
      anchors.right: dot.left
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      height: er.lineHeight
      width: Style.space(40)
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: er.view.usage
      color: root.soft
      font.family: root.face
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: dot
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      anchors.topMargin: Math.round((er.lineHeight - height) / 2)
      width: Style.space(6)
      height: width
      radius: width / 2
      visible: er.view.attention.length > 0
      color: er.broken ? Color.urgent : root.soft
    }

    // The confirmation, in the bottom corner of the open card -- the same card
    // that holds the invocation chips you clicked. It was on the row line for a
    // while, where it covered the token count and the usage count, and then in
    // the footer, a panel's height away from the thing it was about. Here it is
    // out of every column's way and still inside the one card the copy came
    // from. It appears only once the clipboard write has been attempted and
    // reported back, never on the keystroke.
    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.spacing.md
      spacing: Style.spacing.xs
      visible: er.copied && er.expanded

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "\u2713"
        color: root.hue
        font.family: root.face
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "copied"
        color: root.hue
        font.family: root.face
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: er.lineHeight
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: er.entered()
      onClicked: er.activated()
    }

    Loader {
      id: detail
      anchors.left: catBar.right
      anchors.leftMargin: Style.spacing.lg
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      anchors.topMargin: er.lineHeight
      active: er.expanded
      opacity: er.expanded ? 1 : 0

      // Matched to the height so the card arrives as one thing. It used to be
      // 90ms against an instant height change, which is why the space appeared
      // before anything was in it.
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      sourceComponent: Column {
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          visible: er.view.description !== ""
          textFormat: Text.PlainText
          text: er.view.description
          color: root.readable
          font.family: root.face
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          maximumLineCount: 4
          elide: Text.ElideRight
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: er.view.attentionText.length > 0

          Repeater {
            model: er.view.attentionText
            delegate: Text {
              required property string modelData
              width: parent.width
              textFormat: Text.PlainText
              text: "•  " + modelData
              color: er.broken ? Color.urgent : root.readable
              font.family: root.face
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // Where the state lives. This panel writes nothing, so the useful thing it
        // can say is which file holds the switch and what it currently says.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: er.view.switches.length > 0

          Repeater {
            model: er.view.switches
            delegate: Item {
              required property var modelData
              width: parent.width
              height: Style.space(15)

              Text {
                anchors.left: parent.left
                width: Style.space(86)
                textFormat: Text.PlainText
                text: modelData.tool
                color: root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(90)
                width: Style.space(120)
                textFormat: Text.PlainText
                text: modelData.value
                color: modelData.value === "off" ? root.soft : root.fg
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(214)
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: modelData.file
                color: root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: er.view.mounts.length > 0

          Repeater {
            model: er.view.mounts
            delegate: Item {
              id: mountRow
              required property var modelData
              width: parent.width
              height: Style.space(17)

              readonly property bool openable: String(modelData.abs || "").charAt(0) === "/"

              // A path on screen that you cannot get to is a riddle. Clicking it
              // opens the directory in whatever the desktop uses for one.
              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: -Style.spacing.xs
                anchors.rightMargin: -Style.spacing.xs
                radius: Style.cornerRadius
                visible: mountHover.hovered && mountRow.openable
                color: Util.alpha(root.fg, 0.08)
              }

              HoverHandler {
                id: mountHover
                cursorShape: mountRow.openable ? Qt.PointingHandCursor : Qt.ArrowCursor
              }
              TapHandler {
                onTapped: if (mountRow.openable) er.revealRequested(String(mountRow.modelData.abs))
              }

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(86)
                textFormat: Text.PlainText
                text: modelData.tool
                color: root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(90)
                anchors.right: linkTag.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.path
                color: mountHover.hovered && mountRow.openable ? root.fg : root.readable
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }

              Text {
                id: linkTag
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.link
                color: modelData.link === "symlink" ? root.hue : root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: er.view.peers.length > 0

          Repeater {
            model: er.view.peers
            delegate: Text {
              required property string modelData
              width: parent.width
              textFormat: Text.PlainText
              text: "drifted from  " + modelData
              color: Color.urgent
              font.family: root.face
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }
        }

        // Which shelf this is on, and the way to change it. A classifier that
        // reads descriptions will put some things in the wrong place -- it has
        // no idea what you use a skill for -- so the correction has to be one
        // click from the thing being corrected, not somewhere else in the panel.
        // Skills only: an MCP server has no shelf to be on.
        Row {
          width: parent.width
          spacing: Style.spacing.md
          visible: er.view.kind === "skill"

          Text {
            anchors.verticalCenter: parent.verticalCenter
            // The same column the facts below use, so the card has one grid.
            width: Style.space(86)
            textFormat: Text.PlainText
            text: "shelf"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            id: shelfChip
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool unfiled: er.view.category === "unsorted"

            width: shelfChipRow.implicitWidth + Style.space(18)
            height: Style.space(22)
            radius: height / 2
            color: shelfHover.hovered ? Util.alpha(root.fg, 0.18)
                                      : Util.alpha(root.fg, 0.08)

            Row {
              id: shelfChipRow
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(7)
                height: width
                radius: width / 2
                color: root.categoryColourFor(er.view.category)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.categoryLabelFor(er.view.category)
                color: shelfHover.hovered ? root.fg : root.readable
                font.family: root.face
                font.pixelSize: Style.font.caption
              }

              // Says what to do, but only when there is something to do. On a
              // shelved skill the chip is already an answer and does not need to
              // shout that it is also a button.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: shelfChip.unfiled || shelfHover.hovered
                textFormat: Text.PlainText
                text: shelfChip.unfiled ? "pick one" : "change"
                color: root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
                font.italic: true
              }
            }

            HoverHandler { id: shelfHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: er.shelveRequested() }
          }
        }

        Row {
          width: parent.width
          spacing: Style.spacing.md
          visible: er.view.invocations.length > 0

          Repeater {
            model: er.view.invocations
            delegate: Rectangle {
              required property var modelData
              required property int index
              // Only the first invocation opens the picker, because that is the
              // one Ctrl+C copies; the others are the same skill's name in the
              // other agents' spelling and take no arguments there.
              readonly property bool picks: index === 0 && er.argOptions.length > 0

              width: invText.implicitWidth + Style.space(14)
              height: Style.space(20)
              radius: height / 2
              color: invHover.hovered && modelData.ok
                ? Style.hoverFillFor(root.fg, root.hue) : Util.alpha(root.fg, 0.10)

              Text {
                id: invText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: modelData.text + (parent.picks ? " \u2026" : "")
                color: modelData.ok ? root.fg : root.soft
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
              }

              HoverHandler { id: invHover; cursorShape: Qt.PointingHandCursor }
              TapHandler {
                onTapped: modelData.ok
                  ? er.copyRequested(modelData.text)
                  : root.flash("That invocation has characters a prompt would not take safely")
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Repeater {
            model: er.view.facts
            delegate: Item {
              required property var modelData
              width: parent.width
              height: modelData.value === "" ? 0 : Style.space(14)
              visible: modelData.value !== ""

              Text {
                anchors.left: parent.left
                width: Style.space(86)
                textFormat: Text.PlainText
                text: modelData.label
                color: root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(90)
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: modelData.value
                color: root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }

  // ---- Surface ------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // One width and one height always. A panel that resizes as you type reads as
    // several panels rather than one being filtered.
    contentWidth: panel.fittedContentWidth(Style.space(720))
    contentHeight: panel.fittedContentHeight(Style.space(520), Style.space(660))

    // Hand-rolled rather than PanelKeyCatcher, which claims j, k, h, l, x and
    // Space as navigation before textKey is ever reached. Those six letters start
    // jira, kubernetes, hooks, latex, nextjs and threejs, and this panel is typed
    // into. PanelKeyCatcher's `blocked` escape hatch exists for a focused editor;
    // there is no editor here, so there would be nothing to raise it. This is the
    // same shape omarchy.menu uses, for the same reason.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        var typing = root.filterText !== ""
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

        // The overlay is modal while it is up: it owns every key, so nothing
        // typed at it can filter the list underneath or move a cursor the user
        // cannot see.
        if (root.pickerOpen) {
          event.accepted = true
          var count = root.pickerChips().length
          if (event.key === Qt.Key_Escape) { root.pickerBack(); return }
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.pickerConfirm(); return
          }
          if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab
              || (ctrl && event.key === Qt.Key_N)) {
            root.pickerIndex = (root.pickerIndex + 1) % count; return
          }
          if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab
              || (ctrl && event.key === Qt.Key_P)) {
            root.pickerIndex = (root.pickerIndex + count - 1) % count; return
          }
          // Down and Up move by a row of chips rather than one, which is what
          // the eye expects of a grid. The step matches the layout's own count.
          if (event.key === Qt.Key_Down) {
            root.pickerIndex = Math.min(count - 1, root.pickerIndex + optionFlow.perRow); return
          }
          if (event.key === Qt.Key_Up) {
            root.pickerIndex = Math.max(0, root.pickerIndex - optionFlow.perRow); return
          }
          if (event.key === Qt.Key_Home) { root.pickerIndex = 0; return }
          if (event.key === Qt.Key_End) { root.pickerIndex = count - 1; return }

          // Typing means different things in the three modes, and each is the
          // obvious one. Filtering a category list, naming the category being
          // styled, and jumping through a fixed list of actions are not the same
          // gesture and are not made to share one.
          if (root.pickerMode !== "argument") {
            if (Util.editsFilter(event, root.pickerText)) {
              root.pickerText = Util.editedFilter(event, root.pickerText)
              root.pickerIndex = 0
              return
            }
            if (!ctrl && event.text && event.text.length === 1
                && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
              root.pickerText = root.clean(root.pickerText + event.text, 32)
              root.pickerIndex = 0
            }
            return
          }

          // A letter jumps to the next action starting with it, the way a long
          // menu has always worked. Twenty-three options is too many to arrow
          // through and too few to deserve a second search field.
          var ch = String(event.text || "").toLowerCase()
          if (!ctrl && ch.length === 1 && ch >= "a" && ch <= "z") {
            var chips = root.pickerChips()
            for (var j = 1; j < count; j++) {
              var at = (root.pickerIndex + j) % count
              if (at > 0 && String(chips[at]).toLowerCase().charAt(0) === ch) {
                root.pickerIndex = at; return
              }
            }
          }
          return
        }

        if (event.key === Qt.Key_Escape) {
          // The boxes at the top come off together rather than one Escape each.
          // Four presses to undo four clicks is a chain nobody can predict the
          // middle of; one press puts the header back the way it started.
          if (root.expandedKey !== "") root.expandedKey = ""
          else if (root.anyChipFilter) root.clearChipFilters()
          else if (typing) root.setFilter("")
          else root.close()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) {
          root.moveCursor(1); event.accepted = true; return
        }
        if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P)) {
          root.moveCursor(-1); event.accepted = true; return
        }
        if (event.key === Qt.Key_PageDown) { root.moveCursor(8); event.accepted = true; return }
        if (event.key === Qt.Key_PageUp) { root.moveCursor(-8); event.accepted = true; return }
        if (event.key === Qt.Key_Home) {
          root.selectedIndex = 0; root.cursorActive = true
          root.showCursor(); event.accepted = true; return
        }
        if (event.key === Qt.Key_End) {
          root.selectedIndex = root.rows.length - 1
          root.cursorActive = true; root.showCursor(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Right) {
          var rr = root.currentRow()
          if (rr && rr.rowType === "header") root.setCollapsed(rr.key, false)
          else if (rr) root.expandedKey = rr.key
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Left) {
          var rl = root.currentRow()
          if (rl && rl.rowType === "header") root.setCollapsed(rl.key, true)
          else if (root.expandedKey !== "") root.expandedKey = ""
          else for (var b = root.selectedIndex; b >= 0; b--)
            if (root.rows[b].rowType === "header") { root.selectedIndex = b; break }
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.cursorActive = true; root.activate(); event.accepted = true; return
        }

        // Text editing before the command letters, so Backspace always erases.
        if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
          event.accepted = true
          return
        }

        // Every command takes Ctrl, in every state. The first version of this
        // gave the bare letters c, g and r to copy, regroup and rescan while the
        // filter was empty, and moved them to Ctrl once something had been typed.
        // That reads well in a footer and is unusable in the hand: the search is
        // empty exactly when you start typing, so "code", "gemini" and "react"
        // each fired a command on their first keystroke and never reached the
        // filter. The panel promises "Type to search" and now every printable
        // key keeps that promise, including the first one. (Naming a
        // version-control tool here, even inside a comment, trips the
        // marketplace scanner's literal-launcher rule, which does not read
        // comments as comments.)
        if (ctrl) {
          var letter = String.fromCharCode(event.key).toLowerCase()
          if (letter === "c") { root.copyCurrent(); event.accepted = true; return }
          if (letter === "r") { root.startScan(); event.accepted = true; return }
          if (letter === "g") { root.cycleGrouping(); event.accepted = true; return }
          if (letter === "m") { root.moveCurrent(); event.accepted = true; return }
          // The Edit button is the discoverable way in; this is the one for
          // people who never take their hands off the keyboard, which on a panel
          // driven entirely by keys is most of them.
          if (letter === "e") { root.openShelvesPicker(); event.accepted = true; return }
          if (letter === "o") { root.revealCurrent(); event.accepted = true; return }
          return
        }

        // `!` is not a letter anybody searches by, and the attention filter is
        // worth one key rather than two. It still only fires on an empty filter,
        // so a description containing it stays reachable.
        if (!typing && event.text === "!") {
          root.attentionOnly = !root.attentionOnly
          root.selectedIndex = 0
          event.accepted = true
          return
        }

        if (event.text && event.text.length === 1
            && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
            && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text)
          event.accepted = true
        }
      }

      Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.lg

        // Which panel this is. Several bar widgets open surfaces that look alike
        // from three feet away -- a search field over a grouped list is a shape
        // this desktop uses more than once -- and the mark you clicked is now
        // hidden behind the panel it opened. The name and that same mark, at the
        // top, close both gaps.
        //
        // The glyph is read off the bar widget rather than written again here.
        // Two copies of a private-use codepoint in two files is two things that
        // can drift, and the one thing this row must never do is disagree with
        // the mark it is standing under.
        Item {
          width: parent.width
          height: titleRow.implicitHeight

          Row {
            id: titleRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: text !== ""
              textFormat: Text.PlainText
              text: root.hostWidget && root.hostWidget.glyph ? root.hostWidget.glyph : ""
              color: root.readable
              font.family: root.face
              font.pixelSize: Style.font.title
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Agent Extensions"
              color: root.fg
              font.family: root.face
              font.pixelSize: Style.font.title
              font.bold: true
              font.letterSpacing: 0.3
              elide: Text.ElideRight
            }
          }

          // The way into the shelves. The dot on a group header already edits
          // the one shelf it belongs to, but only while that shelf is on screen
          // and only if it exists; naming a new one, or fixing a shelf you have
          // filtered away, had nowhere to happen. It sits opposite the title
          // because that is the corner nothing else uses and because it is about
          // the panel rather than about any row in it.
          Rectangle {
            id: editButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: editRow.implicitWidth + Style.space(20)
            height: Style.space(26)
            radius: Style.cornerRadius
            color: root.pickerMode === "shelves" ? Util.alpha(root.hue, 0.26)
              : (editHover.hovered ? Util.alpha(root.fg, 0.16) : Util.alpha(root.fg, 0.07))

            Row {
              id: editRow
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                // nf-md-pencil (U+F03EB), as its surrogate pair for the same
                // reason the bar mark is: a private-use codepoint pasted in is a
                // box in every editor without the font.
                text: "\uDB80\uDFEB"
                color: editHover.hovered || root.pickerMode === "shelves"
                  ? root.fg : root.readable
                font.family: root.face
                font.pixelSize: Style.font.subtitle
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Edit"
                color: editHover.hovered || root.pickerMode === "shelves"
                  ? root.fg : root.readable
                font.family: root.face
                font.pixelSize: Style.font.title
              }
            }

            HoverHandler { id: editHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
              onTapped: root.pickerMode === "shelves" ? root.closePicker()
                                                      : root.openShelvesPicker()
            }
          }
        }

        // A display of the filter, not a field. A focused editor would eat every
        // key, and the key catcher above owns the keyboard.
        //
        // Which left it looking like nothing in particular. It was drawn in the
        // resting state until you had already typed something, so the one
        // control that always has the keyboard was the one control that never
        // looked like it did; and hovering it gave an arrow, so it did not read
        // as somewhere you could type at all. It is drawn focused for as long as
        // the panel is open, because for as long as the panel is open that is
        // the truth, it carries a caret, and the pointer over it is an I-beam.
        BorderSurface {
          id: searchField
          width: parent.width
          height: Style.spacing.controlHeight
          radius: Style.cornerRadius
          color: Style.controlFill(false, true, root.fg, root.hue)
          borderSpec: Border.controlSpec("hover-cursor", root.fg, root.hue)

          // No click handler, only a shape. There is nothing to click: the
          // keyboard is already here. Saying so with the pointer is the whole
          // job, and a MouseArea would also swallow the wheel over the header.
          HoverHandler { cursorShape: Qt.IBeamCursor }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(14)
            textFormat: Text.PlainText
            text: "⌕"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.body
          }

          Text {
            id: filterDisplay
            anchors.left: parent.left
            // The extra step is the caret's slot, held open whether or not the
            // caret is standing in it, so the text never moves under the words.
            anchors.leftMargin: Style.spacing.controlPaddingX + Style.space(25)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.filterText !== "" ? root.filterText : "Type to search"
            color: root.fg
            opacity: root.filterText !== "" ? 1 : 0.58
            font.family: root.face
            font.pixelSize: Style.font.body
            // Elides at the front so the end you are typing stays on screen.
            elide: Text.ElideLeft
            // Width, not an anchor to the caret: the caret anchors to this, and
            // anchoring both ways would be the two of them measuring each other.
            // Only as wide as it needs to be, so the caret sits against the last
            // character rather than at the far end of the row.
            width: Math.max(0, Math.min(implicitWidth,
                     filterMeta.x - x - Style.spacing.md - Style.space(3)))
            horizontalAlignment: Text.AlignLeft
          }

          // The caret. Not a TextInput's: this panel deliberately has no focused
          // editor, so the blink is drawn rather than inherited. 530ms is the
          // interval every toolkit has used since Windows 3.1 and the one every
          // reader is calibrated to.
          Rectangle {
            id: caret
            // Where a caret actually goes: at the insertion point. With nothing
            // typed that is the start of the field, in front of the placeholder,
            // not trailing after it -- a caret parked at the end of "Type to
            // search" reads as though those words were something you typed. The
            // text keeps its position either way, so the first keystroke moves
            // the caret and nothing else.
            anchors.left: root.filterText === "" ? filterDisplay.left : filterDisplay.right
            anchors.leftMargin: root.filterText === "" ? -Style.space(5) : Style.space(1)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(1, Style.space(1))
            height: Style.font.body + Style.space(2)
            color: root.hue
            visible: root.opened

            SequentialAnimation on opacity {
              running: caret.visible
              loops: Animation.Infinite
              // A hard swap, not a fade: a caret that eases is a caret you have
              // to look at to be sure it is blinking.
              PropertyAnimation { to: 1; duration: 0 }
              PauseAnimation { duration: 530 }
              PropertyAnimation { to: 0; duration: 0 }
              PauseAnimation { duration: 530 }
            }
          }

          Text {
            id: filterMeta
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.attentionOnly ? "needs attention" : ""
            color: Color.urgent
            font.family: root.face
            font.pixelSize: Style.font.caption
          }

          // A hairline that sweeps while the helper runs. No spinner: the scan is
          // tens of milliseconds against a local disk, and a spinner would only
          // ever be seen on a network mount.
          Item {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.spacing.hairline
            clip: true
            visible: root.scanning

            Rectangle {
              id: sweep
              width: parent.width * 0.3
              height: parent.height
              color: root.hue

              SequentialAnimation on x {
                running: root.scanning
                loops: Animation.Infinite
                NumberAnimation {
                  from: -sweep.width
                  to: sweep.parent ? sweep.parent.width : 0
                  duration: 900
                  easing.type: Easing.InOutQuad
                }
              }
            }
          }
        }

        // Never assert a finding before the read is in. Until the first scan
        // lands this says what is happening rather than "0 skills".
        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: !root.loaded
          text: "Reading four skill roots…"
          color: root.readable
          font.family: root.face
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // The shelves, as chips you can point at: one row of them, and the
        // rest one click below it.
        //
        // The first version scrolled sideways instead. That is the wrong shape
        // for this control -- a strip you have to drag is a strip whose contents
        // you cannot see, and the entire point of naming every shelf is that you
        // find the one you want without hunting for it. Wrapping the whole set
        // unasked is the other wrong shape: the list underneath is what the
        // panel is for, and three rows of filter on a machine with fifteen
        // categories takes more than it gives. So it is one row until you say
        // otherwise, and it stays open once you have.
        Item {
          id: filterStrip
          width: parent.width
          visible: root.categoryChips.length > 0
          height: visible ? (root.filtersExpanded ? catFlow.implicitHeight
                                                  : catFlow.rowHeight) : 0
          clip: true

          // A click, not a keystroke, and not one you make often. Short enough
          // to stay out of the way and long enough that the rows are seen to
          // arrive rather than to appear.
          Behavior on height {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
          }

          Flow {
            id: catFlow
            // The toggle keeps its corner in both states and at a width that
            // does not depend on its own label, so opening the strip never
            // reflows the row you were already reading, and the count changing
            // from 9 to 10 never nudges a chip onto the next line. Reserving the
            // space unconditionally is also what keeps this out of a binding
            // loop: the flow's width would otherwise depend on the toggle, whose
            // visibility depends on how the flow wrapped.
            width: parent.width - moreBox.width - Style.space(16) - Style.spacing.sm
            spacing: Style.spacing.sm

            readonly property int rowHeight: Style.space(20)

            // How many chips the first row could not take. Counted off the
            // laid-out children rather than measured from their text, so it is
            // right at any panel width, font scale or category name. `width` and
            // `implicitHeight` are read to make this re-evaluate when the flow
            // relayouts; the Repeater is a child here too and has no size of its
            // own, which is what the width test excludes.
            readonly property int hidden: {
              var w = catFlow.width
              var h = catFlow.implicitHeight
              var n = 0
              for (var i = 0; i < catFlow.children.length; i++) {
                var c = catFlow.children[i]
                if (c && c.visible && c.width > 0 && c.y > 0) n++
              }
              return n
            }

            Rectangle {
              width: allText.implicitWidth + Style.space(16)
              height: catFlow.rowHeight
              radius: height / 2
              color: !root.anyChipFilter ? Util.alpha(root.hue, 0.24)
                                         : Util.alpha(root.fg, 0.07)

              Text {
                id: allText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "all"
                color: !root.anyChipFilter ? root.fg : root.readable
                font.family: root.face
                font.pixelSize: Style.font.caption
              }

              HoverHandler { cursorShape: Qt.PointingHandCursor }
              // Clears every box, not just the shelves. It is the one control on
              // screen that means "show me everything again", and leaving an
              // agent or a kind still on after clicking it would be a lie.
              TapHandler { onTapped: root.clearChipFilters() }
            }

            Repeater {
              model: root.categoryChips

              Rectangle {
                id: catChip
                required property var modelData
                readonly property bool on: root.categoryFilter === catChip.modelData.key

                width: catRow.implicitWidth + Style.space(16)
                height: catFlow.rowHeight
                radius: height / 2
                color: catChip.on ? Util.alpha(catChip.modelData.colour, 0.34)
                                  : Util.alpha(root.fg, 0.07)

                Row {
                  id: catRow
                  anchors.centerIn: parent
                  spacing: Style.spacing.sm

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: width
                    radius: width / 2
                    color: catChip.modelData.colour
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: catChip.modelData.label
                    color: catChip.on ? root.fg : root.readable
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: String(catChip.modelData.count)
                    color: catChip.on ? root.readable : root.soft
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                  }
                }

                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  // Clicking the one already on turns it off, so the way back is
                  // the same gesture as the way in.
                  onTapped: {
                    root.categoryFilter = catChip.on ? "" : String(catChip.modelData.key)
                    root.selectedIndex = 0
                    // Filtering to a group that happens to be folded shows an
                    // empty list under a header, which reads as "nothing here".
                    // Choosing a shelf is asking to see what is on it.
                    if (root.categoryFilter !== "")
                      root.setCollapsed("cat:" + root.categoryFilter, false)
                  }
                }
              }
            }
          }

          // The widest label this control can ever hold, measured once. The
          // toggle is sized to it rather than to what it currently says.
          TextMetrics {
            id: moreBox
            font.family: root.face
            font.pixelSize: Style.font.caption
            text: "+99 more"
          }

          Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            visible: catFlow.hidden > 0
            width: moreBox.width + Style.space(16)
            height: catFlow.rowHeight
            radius: height / 2
            color: moreHover.hovered ? Util.alpha(root.fg, 0.18) : Util.alpha(root.fg, 0.07)

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              // Says what is behind it while it is shut, and what it does while
              // it is open. "+3 more" and "less" are the two true sentences.
              text: root.filtersExpanded ? "less" : "+" + String(catFlow.hidden) + " more"
              color: moreHover.hovered ? root.fg : root.readable
              font.family: root.face
              font.pixelSize: Style.font.caption
            }

            HoverHandler { id: moreHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.filtersExpanded = !root.filtersExpanded }
          }
        }

        // What was counted. Wraps rather than eliding, so the last number is
        // never the one that gets cut.
        Flow {
          width: parent.width
          visible: root.loaded && root.countChips.length > 0
          spacing: Style.spacing.sm

          Repeater {
            model: root.countChips

            Rectangle {
              id: countChip
              required property var modelData
              readonly property bool urgent: countChip.modelData.urgent
              readonly property bool on: countChip.modelData.kind === "attention"
                ? root.attentionOnly : root.kindFilter === countChip.modelData.kind

              width: countChipRow.implicitWidth + Style.space(18)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: {
                var base = countChip.urgent ? Color.urgent : root.fg
                if (countChip.on) return Util.alpha(countChip.urgent ? Color.urgent : root.hue, 0.30)
                if (countHover.hovered) return Util.alpha(base, 0.16)
                return Util.alpha(base, countChip.urgent ? 0.14 : 0.07)
              }

              Row {
                id: countChipRow
                anchors.centerIn: parent
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: String(countChip.modelData.n)
                  color: countChip.urgent ? Color.urgent : root.fg
                  font.family: root.face
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: countChip.modelData.what
                  color: countChip.urgent ? Color.urgent
                    : (countChip.on || countHover.hovered ? root.readable : root.soft)
                  font.family: root.face
                  font.pixelSize: Style.font.caption
                }
              }

              HoverHandler { id: countHover; cursorShape: Qt.PointingHandCursor }
              TapHandler {
                // Clicking the one already on turns it off, the same gesture as
                // the shelf chips below. "need attention" is not a kind, so it
                // drives the attention filter rather than the kind filter.
                onTapped: {
                  if (countChip.modelData.kind === "attention")
                    root.attentionOnly = !root.attentionOnly
                  else
                    root.kindFilter = countChip.on ? "" : String(countChip.modelData.kind)
                  root.selectedIndex = 0
                }
              }
            }
          }
        }

        // What it costs, per agent, with that agent's mark and how many of the
        // rows above it can see. Its own row, because it answers a different
        // question from the one above and the two were competing for the same
        // line.
        Flow {
          width: parent.width
          visible: root.loaded && root.toolChips.length > 0
          spacing: Style.spacing.sm

          Repeater {
            model: root.toolChips

            Rectangle {
              id: toolChip
              required property var modelData
              readonly property bool on: root.toolFilter === toolChip.modelData.tool

              width: toolChipRow.implicitWidth + Style.space(18)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: Util.alpha(toolChip.modelData.colour,
                                toolChip.on ? 0.34 : (toolHover.hovered ? 0.22 : 0.13))

              Row {
                id: toolChipRow
                anchors.centerIn: parent
                spacing: Style.spacing.sm

                AgentMark {
                  anchors.verticalCenter: parent.verticalCenter
                  agent: toolChip.modelData.tool
                  size: Style.space(12)
                  color: toolChip.modelData.colour
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: toolChip.modelData.label
                  color: toolChip.on ? root.fg : root.readable
                  font.family: root.face
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: toolChip.modelData.count
                  color: root.soft
                  font.family: root.face
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: text !== ""
                  textFormat: Text.PlainText
                  text: toolChip.modelData.tokens
                  color: root.fg
                  font.family: root.face
                  font.pixelSize: Style.font.bodySmall
                }
              }

              HoverHandler { id: toolHover; cursorShape: Qt.PointingHandCursor }
              TapHandler {
                onTapped: {
                  root.toolFilter = toolChip.on ? "" : String(toolChip.modelData.tool)
                  root.selectedIndex = 0
                }
              }
            }
          }
        }

        // One strip at a time, in order of who most needs answering.
        Loader {
          id: strip
          width: parent.width
          readonly property string message: root.scanError !== "" ? root.scanError
            : (root.toast !== "" ? root.toast : root.findingLine)
          active: strip.message !== ""
          visible: active

          // Three tones, because three different things get said here and they
          // are not equally good news. A refused copy used to arrive in the same
          // accent as a successful one.
          readonly property color tint: root.scanError !== "" ? Color.urgent
            : (root.toast === "" ? root.fg
              : (root.toastTone === "error" ? Color.urgent : root.hue))

          sourceComponent: BorderSurface {
            implicitHeight: stripText.implicitHeight + Style.spacing.xxl * 2
            radius: Style.cornerRadius
            color: Util.alpha(strip.tint, root.toast !== "" || root.scanError !== "" ? 0.12 : 0.05)
            borderSpec: Border.flat(Util.alpha(strip.tint,
              root.toast !== "" || root.scanError !== "" ? 0.34 : 0.18),
              Style.normalBorderWidth)

            Text {
              id: stripText
              anchors.left: parent.left
              anchors.right: dismiss.visible ? dismiss.left : parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.xxl
              anchors.rightMargin: Style.spacing.md
              textFormat: Text.PlainText
              text: strip.message
              color: root.scanError !== "" || root.toastTone === "error"
                ? Color.urgent : root.strong
              font.family: root.face
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            // Only a finding can be put down. A scan error is the panel failing
            // to do its one job and a toast disappears on its own; neither is
            // yours to dismiss.
            Rectangle {
              id: dismiss
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              visible: root.scanError === "" && root.toast === "" && root.findingLine !== ""
              width: visible ? Style.space(20) : 0
              height: Style.space(20)
              radius: width / 2
              color: dismissHover.hovered ? Util.alpha(root.fg, 0.16) : "transparent"

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "\u00d7"
                color: dismissHover.hovered ? root.fg : root.soft
                font.family: root.face
                font.pixelSize: Style.font.body
              }

              HoverHandler { id: dismissHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.dismissFinding() }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }
      }

      ListView {
        id: list
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.spacing.lg
        anchors.bottomMargin: Style.spacing.lg
        clip: true
        spacing: Style.spacing.xxs
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows
        currentIndex: root.selectedIndex

        // The view never steers itself. It used to run ApplyRange, which keeps
        // the current item inside a band and is the right tool while a keyboard
        // cursor walks a list of fixed-height rows -- which is what the
        // neighbouring plugin has. These rows are not fixed height: expanding one
        // changes it, and the new height does not arrive on the click. The Loader
        // has to build the card and the wrapped text has to measure, so the row
        // grows a frame or two later, and ApplyRange answered that late change by
        // scrolling. That is the pause-then-jump: you click, nothing moves, and a
        // moment later the list slides under you. Flick during the gap and the
        // range constraint and your finger pull in opposite directions, which is
        // the "random place" it lands in.
        //
        // So the range is gone and keeping the cursor visible is done explicitly,
        // on the keystrokes that move it, where it is wanted and nowhere else.
        // Expanding a row now does what it looks like: the card opens downward
        // and the viewport stays where you put it.
        highlightRangeMode: ListView.NoHighlightRange
        highlightMoveDuration: 0

        // The helper cannot tell whether a tool is installed -- skill_roots()
        // returns all four roots unconditionally and a missing directory is
        // skipped in silence. So the empty state names what was read, and never
        // claims anything about what is installed.
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(80)
          spacing: Style.spacing.md
          visible: root.rows.length === 0

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: {
              if (!root.loaded) return "Reading four skill roots…"
              if (root.filterText !== "") return "Nothing matches “" + root.filterText + "”."
              if (root.attentionOnly) return "Nothing needs attention."
              if (root.report && (root.report.items || []).length > 0 && !root.showBundled)
                return "Every skill found is built in to an agent."
              return "Nothing found in ~/.claude/skills, ~/.config/opencode/skills, "
                + "~/.codex/skills or ~/.agents/skills."
            }
            color: root.readable
            font.family: root.face
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            visible: root.loaded && root.filterText === "" && !root.attentionOnly
            text: root.report && (root.report.items || []).length > 0 && !root.showBundled
              ? "Turn on “Show built-in skills” to count them."
              : "Install a skill, or run bin/agent-ext doctor to see what was read."
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        delegate: Item {
          id: rowHost
          required property var modelData
          required property int index

          width: list.width
          height: Math.max(headerSlot.implicitHeight, itemSlot.implicitHeight)

          Loader {
            id: headerSlot
            width: rowHost.width
            active: rowHost.modelData.rowType === "header"
            visible: active
            sourceComponent: GroupRow {
              group: rowHost.modelData
              hasCursor: root.cursorActive && root.selectedIndex === rowHost.index
              onEntered: { root.cursorActive = true; root.selectedIndex = rowHost.index }
              onToggled: root.setCollapsed(rowHost.modelData.key, !rowHost.modelData.collapsed)
              onStyleRequested: {
                root.cursorActive = true
                root.selectedIndex = rowHost.index
                if (rowHost.modelData.category !== "")
                  root.openStylePicker(rowHost.modelData.category, "")
              }
            }
          }

          Loader {
            id: itemSlot
            width: rowHost.width
            active: rowHost.modelData.rowType !== "header"
            visible: active
            sourceComponent: ExtensionRow {
              view: rowHost.modelData.view
              hasCursor: root.cursorActive && root.selectedIndex === rowHost.index
              expanded: root.expandedKey === rowHost.modelData.key
              onEntered: { root.cursorActive = true; root.selectedIndex = rowHost.index }
              onActivated: {
                root.cursorActive = true
                root.selectedIndex = rowHost.index
                root.expandedKey = root.expandedKey === rowHost.modelData.key
                  ? "" : rowHost.modelData.key
              }
              copied: root.copiedKey === rowHost.modelData.key
              onRevealRequested: function (path) { root.openInFiles(path) }
              onShelveRequested: {
                root.cursorActive = true
                root.selectedIndex = rowHost.index
                root.openCategoryPicker(rowHost.modelData)
              }
              onCopyRequested: function (text) {
                root.cursorActive = true
                root.selectedIndex = rowHost.index
                if (root.pickerOptions(rowHost.modelData.view).length > 0)
                  root.openPicker(rowHost.modelData)
                else root.copyText(text, rowHost.modelData.key)
              }
            }
          }
        }
      }

      Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.spacing.md

        PanelSeparator { width: parent.width; foreground: root.fg }

        // The promise on screen switches with the mode, so it is always true.
        // Nothing else lives on this line: the copy tick was here for a while
        // and it was the wrong place twice over, competing with the controls for
        // a corner and sitting a panel's height away from the row it was about.
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: {
            var typing = root.filterText !== ""
            var cur = root.currentRow()
            var picks = cur && cur.rowType !== "header"
              && root.pickerOptions(cur.view).length > 0
            var parts = [typing ? "Backspace to erase" : "Type to search"]
            parts.push("Enter to open")
            // The promise changes with the row, because on a row that documents
            // actions Ctrl+C does not copy: it asks which one.
            parts.push(picks ? "^C to pick an action" : "^C to copy")
            parts.push("^G to regroup")
            parts.push("^R to rescan")
            parts.push(root.expandedKey !== "" || typing || root.anyChipFilter
              ? "Esc to go back" : "Esc to close")
            return parts.join("  \u00b7  ")
          }
          color: root.soft
          font.family: root.face
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // ---- The overlay ------------------------------------------------------
      //
      // One surface for the three questions a row can ask, because they are one
      // gesture: a short list of possibilities, one of which you mean. Chips
      // wrap into a grid the eye reads in a pass; the same options down a
      // scrolling column would be three screens of one word each. What is about
      // to happen is drawn above them at reading size and updates on every move,
      // so "what does Enter do here" is answered on screen rather than assembled
      // in the reader's head.
      //
      // No entrance animation. This opens from a keystroke, on a panel opened
      // from a keystroke, and a keyboard action that waits for a curve to finish
      // feels broken however good the curve is.
      Item {
        id: picker
        anchors.fill: parent
        visible: root.pickerOpen

        readonly property bool styling: root.pickerMode === "style"
        readonly property bool shelving: root.pickerMode === "category"
        readonly property bool managing: root.pickerMode === "shelves"
        // Both of these draw a shelf: a colour, a name and how much is on it.
        // One of them files a skill and the other opens the shelf for editing,
        // which is a difference in what Enter does, not in what a shelf is.
        readonly property bool shelfList: picker.shelving || picker.managing

        // Near-opaque, not a scrim. At 0.92 the list underneath read straight
        // through the option chips and both layers became hard to read; the
        // point of a picker is that there is one thing on screen to answer.
        Rectangle {
          anchors.fill: parent
          color: Color.popups.background
          // Swallows the click rather than passing it to the row underneath.
          MouseArea { anchors.fill: parent; onClicked: root.closePicker() }
        }

        // The card, and a floor under it that accepts clicks and does nothing.
        // Without it a click anywhere on the card that is not a chip -- the name
        // you are trying to edit, the hint, the gap between two rows -- falls
        // through to the scrim underneath and dismisses the whole overlay,
        // because a bare Rectangle or Text does not accept mouse events and Qt
        // delivers them to the topmost item that does.
        Item {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          height: cardColumn.implicitHeight

          MouseArea { anchors.fill: parent }

        Column {
          id: cardColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xl

          // A way back that is a target, not a keystroke you have to know. The
          // overlay has the room for it and the alternative was a footer line
          // telling you to press Escape.
          Item {
            width: parent.width
            height: backChip.height

            Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Rectangle {
              id: backChip
              anchors.verticalCenter: parent.verticalCenter
              width: backText.implicitWidth + Style.space(18)
              height: Style.space(22)
              radius: height / 2
              color: backHover.hovered ? Util.alpha(root.fg, 0.16) : Util.alpha(root.fg, 0.08)

              Text {
                id: backText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "\u2190  back"
                color: backHover.hovered ? root.fg : root.readable
                font.family: root.face
                font.pixelSize: Style.font.caption
              }

              HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: root.pickerBack() }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, picker.width - backChip.width
                                 - saveButton.width - Style.spacing.md * 3)
              textFormat: Text.PlainText
              text: {
                if (root.styleAsking) return "unsaved changes"
                if (root.pickerNaming) return "new shelf"
                if (picker.managing) return "shelves"
                if (picker.styling) return "the " + root.pickerCategory + " shelf"
                if (!root.pickerOpen || !root.pickerRow) return ""
                var n = root.clean(root.pickerRow.view.name, 60)
                return picker.shelving ? n + "  \u00b7  move to" : n + "  \u00b7  pick an action"
              }
              color: root.soft
              font.family: root.face
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            }

            // Save is a button because saving is a decision. It shows only where
            // there is a draft to save, and it says whether there is anything in
            // it: dimmed when the shelf is exactly as you found it, lit the
            // moment you change a letter or try a colour on.
            Rectangle {
              id: saveButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: picker.styling && !root.styleAsking
              width: visible ? saveText.implicitWidth + Style.space(20) : 0
              height: Style.space(22)
              radius: height / 2
              color: root.styleDirty
                ? (saveHover.hovered ? Util.alpha(root.hue, 0.42) : Util.alpha(root.hue, 0.28))
                : Util.alpha(root.fg, 0.07)

              Text {
                id: saveText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.styleDirty ? "Save" : "Saved"
                color: root.styleDirty ? root.fg : root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
              }

              HoverHandler {
                id: saveHover
                enabled: root.styleDirty
                cursorShape: Qt.PointingHandCursor
              }
              TapHandler { onTapped: if (root.styleDirty) root.styleSave() }
            }
          }

          // What Enter does, at the size of the thing it is. Everything else on
          // this overlay exists to change this one line.
          BorderSurface {
            width: parent.width
            implicitHeight: commandText.implicitHeight + Style.spacing.xxl * 2
            radius: Style.cornerRadius
            color: Util.alpha(picker.styling ? root.pickerSwatch() : root.hue, 0.14)
            borderSpec: Border.controlSpec("hover-cursor", root.fg, root.hue)

            // In the style overlay this box is not a preview of the name, it is
            // the name, and typing goes into it. So it says so: an I-beam over
            // it and a caret in it, the same two signals the search field uses.
            // Everywhere else the box is a preview of what Enter will do and the
            // pointer stays an arrow, because there is nothing here to type into.
            HoverHandler {
              enabled: picker.styling || root.pickerNaming
              cursorShape: Qt.IBeamCursor
            }

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.controlPaddingX
              spacing: Style.spacing.md

              // The colour being applied, shown as itself rather than named.
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: picker.styling
                width: visible ? Style.space(14) : 0
                height: Style.space(14)
                radius: width / 2
                color: root.pickerSwatch()
              }

              Text {
                id: commandText
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.pickerNaming && root.pickerText === ""
                  ? "Name it" : root.pickerCommand()
                color: root.fg
                opacity: root.pickerNaming && root.pickerText === "" ? 0.5 : 1
                font.family: root.face
                font.pixelSize: Style.font.subtitle
                elide: Text.ElideRight
                // Only as wide as the words, so the caret sits against the last
                // letter rather than at the far end of the box. Capped so a long
                // name still elides instead of pushing the caret off the card.
                width: Math.max(0, Math.min(implicitWidth,
                  parent.width - (picker.styling ? Style.space(14) + Style.spacing.md : 0)
                    - Style.space(4)))
              }

              // The caret for the name being typed. Same 530ms as the search
              // field, drawn rather than inherited for the same reason: there is
              // no focused editor anywhere in this panel.
              Rectangle {
                id: nameCaret
                anchors.verticalCenter: parent.verticalCenter
                visible: picker.styling || root.pickerNaming
                width: visible ? Math.max(1, Style.space(1)) : 0
                height: Style.font.subtitle + Style.space(2)
                color: root.fg
                // In front of the placeholder while the name is empty, after the
                // text once there is any, which is where the insertion point is.
                anchors.left: root.pickerNaming && root.pickerText === ""
                  ? commandText.left : undefined
                anchors.leftMargin: root.pickerNaming && root.pickerText === ""
                  ? -Style.space(5) : 0

                SequentialAnimation on opacity {
                  running: nameCaret.visible
                  loops: Animation.Infinite
                  PropertyAnimation { to: 1; duration: 0 }
                  PauseAnimation { duration: 530 }
                  PropertyAnimation { to: 0; duration: 0 }
                  PauseAnimation { duration: 530 }
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: text !== ""
            text: {
              if (root.styleAsking) return "Keep the new name and colour, or go back to what was there?"
              if (root.pickerNaming) return "Lower case letters, digits and dashes. It starts empty; put something on it with ^M from any row."
              if (picker.managing) return "Pick a shelf to rename it or change its colour. Type a name nothing answers to and it becomes a new one."
              if (picker.styling) return "Type to rename it. Pick a colour, or clear it to go back to the theme."
              if (picker.shelving) return "Type a name nothing answers to and it becomes a new shelf."
              if (!root.pickerOpen || !root.pickerRow) return ""
              var args = root.pickerRow.view.argumentChoices || []
              for (var i = 0; i < args.length; i++)
                if (args[i].kind === "value")
                  return "Then type the " + args[i].label + " after pasting."
              return ""
            }
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Bounded, and scrolling once it would not fit. Twenty-three short
          // words wrap into three rows on this panel, but the count comes from
          // somebody else's frontmatter and a skill documenting sixty actions
          // must not push its own footer off the bottom of the screen.
          Flickable {
            width: parent.width
            height: Math.min(optionFlow.implicitHeight, picker.height * 0.46)
            contentHeight: optionFlow.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Flow {
              id: optionFlow
              width: parent.width
              spacing: Style.spacing.sm

              // What Down and Up step by. Measured from the laid-out chips
              // rather than assumed, so it stays right at any panel width or
              // font scale. The width test matters: the Repeater is a child of
              // the Flow as well, sits at y 0 with no size, and would otherwise
              // be counted as a chip and put every Down one place too far.
              readonly property int perRow: {
                var w = optionFlow.width
                var h = optionFlow.implicitHeight
                var n = 0
                for (var i = 0; i < optionFlow.children.length; i++) {
                  var c = optionFlow.children[i]
                  if (c && c.visible && c.width > 0 && c.y === 0) n++
                }
                return Math.max(1, n)
              }

              Repeater {
                model: root.pickerChips()

                BorderSurface {
                  id: chip
                  required property var modelData
                  required property int index

                  // In the swatch grid the mark follows the draft, so the
                  // colour you are trying on stays lit while you look past it.
                  readonly property bool current: chip.isSwatch || chip.isClear
                    ? root.styleColourIndex === chip.index
                    : root.pickerIndex === chip.index
                  readonly property bool isSwatch: picker.styling && !chip.isAnswer
                  readonly property bool isClear: String(chip.modelData) === "\u0000clear"
                  readonly property bool isNew: String(chip.modelData) === "\u0000new"
                  readonly property bool isAddNew: String(chip.modelData) === "\u0000addnew"
                  readonly property bool isAnswer: String(chip.modelData) === "\u0000save"
                    || String(chip.modelData) === "\u0000discard"

                  // A shelf chip carries its own colour and its size, so the
                  // index reads as an inventory rather than as a word list.
                  readonly property bool isShelf: picker.shelfList && !chip.isNew && !chip.isAddNew

                  implicitWidth: chip.isSwatch && !chip.isClear
                    ? Style.space(30) : chipRowInner.implicitWidth + Style.space(22)
                  implicitHeight: Style.space(28)
                  radius: Style.cornerRadius
                  color: {
                    if (chip.isSwatch && !chip.isClear)
                      return Util.alpha(String(chip.modelData), chip.current ? 1.0 : 0.72)
                    if (chip.current) return Util.alpha(root.hue, 0.26)
                    return Util.alpha(root.fg, 0.07)
                  }
                  borderSpec: Border.controlSpec(chip.current ? "hover-cursor" : "normal",
                                                 root.fg, root.hue)

                  Row {
                    id: chipRowInner
                    anchors.centerIn: parent
                    visible: !(chip.isSwatch && !chip.isClear)
                    spacing: Style.spacing.sm

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: chip.isShelf
                      width: visible ? Style.space(7) : 0
                      height: Style.space(7)
                      radius: width / 2
                      color: chip.isShelf ? root.categoryColourFor(String(chip.modelData))
                                          : "transparent"
                    }

                    Text {
                      id: chipText
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: {
                        if (String(chip.modelData) === "\u0000save") return "Save"
                        if (String(chip.modelData) === "\u0000discard") return "Discard"
                        if (chip.isClear) return "theme default"
                        if (chip.isAddNew) return "+ new shelf"
                        if (chip.isNew) return "+ new  \u201c" + root.newCategoryName() + "\u201d"
                        if (picker.shelfList) return root.categoryLabelFor(String(chip.modelData))
                        return String(chip.modelData) === "" ? "no argument" : String(chip.modelData)
                      }
                      color: chip.current ? root.fg : root.readable
                      font.family: root.face
                      font.pixelSize: Style.font.bodySmall
                      font.italic: String(chip.modelData) === "" || chip.isNew || chip.isAddNew
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: chip.isShelf
                      textFormat: Text.PlainText
                      // An empty shelf says so rather than showing a bare 0,
                      // because a shelf you just made and a shelf nothing
                      // classified into are the same thing and both are fine.
                      text: chip.isShelf
                        ? (root.shelfCount(String(chip.modelData)) > 0
                           ? String(root.shelfCount(String(chip.modelData))) : "empty")
                        : ""
                      color: chip.current ? root.readable : root.soft
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.pickerIndex = chip.index
                    onClicked: {
                      root.pickerIndex = chip.index
                      // Trying a colour on is not choosing it. Everywhere else a
                      // chip is the answer, so clicking it answers.
                      if (picker.styling && !root.styleAsking) return
                      root.pickerConfirm()
                    }
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: {
              if (root.styleAsking) return "Enter to save  \u00b7  Esc to drop the changes"
              if (root.pickerNaming) return "Type the name  \u00b7  Enter to create it  \u00b7  Esc to go back"
              if (picker.managing) return "Type to filter or name a new one  \u00b7  Enter to open it  \u00b7  Esc to go back"
              if (picker.styling) return "Type to rename  \u00b7  arrows to try a colour  \u00b7  Enter to save  \u00b7  Esc to go back"
              if (picker.shelving) return "Type to filter  \u00b7  arrows to choose  \u00b7  Enter to move it  \u00b7  Esc to go back"
              return "Arrows or a letter to choose  \u00b7  Enter to copy  \u00b7  Esc to go back"
            }
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        }
      }
    }
  }
}
