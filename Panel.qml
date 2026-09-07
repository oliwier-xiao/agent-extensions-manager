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
  moduleName: "oliwier.ai-skills-manager"
  ipcTarget: "oliwier.ai-skills-manager"
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
  // Util.alpha, not Qt.darker: on a light theme Qt.darker makes muted more
  // prominent than the foreground, and on all-black text every level collapses.
  readonly property color muted: Util.alpha(fg, 0.66)
  readonly property color veryMuted: Util.alpha(fg, 0.42)
  readonly property color faint: Util.alpha(fg, 0.16)

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
  property bool attentionOnly: false
  property var collapsed: ({})
  property string expandedKey: ""
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var categoryOrder: [
    "agents", "code", "workflow", "web", "design", "media", "data",
    "infra", "ops", "security", "automation", "content", "business", "system"
  ]
  readonly property var categoryLabel: ({
    agents: "Agents", code: "Code", workflow: "Workflow", web: "Web",
    design: "Design", media: "Media", data: "Data", infra: "Infrastructure",
    ops: "Operations", security: "Security", automation: "Automation",
    content: "Content", business: "Business", system: "System"
  })
  readonly property var toolLabel: ({
    claude: "Claude Code", opencode: "OpenCode", codex: "Codex"
  })

  // The seven codes bin/agent-ext can attach, ranked. Only 2 and above light the
  // urgent colour: `unclassified` and `low-confidence` are the classifier
  // hedging, not a fault, and sixteen n8n skills on a machine like this one carry
  // one of them -- ranking those as failures would paint the whole list red and
  // bury `drift`, which means two agents are running different code.
  // `name-mismatch` is a 2 and not a 1 because it is not cosmetic: the helper
  // builds Claude's invocation from the directory name and OpenCode's from the
  // frontmatter name, so a mismatch means the same skill is called two things.
  readonly property var severityRank: ({
    "drift": 3, "invalid-yaml": 3,
    "name-mismatch": 2, "no-description": 2,
    "long-description": 1, "unclassified": 1, "low-confidence": 1
  })
  readonly property var attentionPhrase: ({
    "drift": "Another skill of this name has different content -- two agents are running different code",
    "invalid-yaml": "The frontmatter has an unquoted colon",
    "name-mismatch": "The frontmatter name and the directory name disagree, so the tools call it two things",
    "no-description": "No description, so the agent has nothing to match on",
    "long-description": "The description is over 1024 characters",
    "unclassified": "Nothing in the description matched a category",
    "low-confidence": "The category is a guess"
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

  function flash(message) {
    root.toast = root.clean(message, 200)
    toastTimer.restart()
  }

  Timer { id: toastTimer; interval: 4000; onTriggered: root.toast = "" }

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
                    link: root.clean(src[m].link, 16) })

    // driftPeers is attached after the record is built and only on a drift
    // group, so it has to be probed rather than assumed.
    var peers = []
    if (Array.isArray(item.driftPeers))
      for (var p = 0; p < item.driftPeers.length && p < 6; p++)
        peers.push(root.clean(item.driftPeers[p], 160))

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
        : (u.source === "not tracked" ? "—" : "unused"),
      attention: codes,
      attentionText: words,
      severity: root.severityOf(codes),
      description: desc,
      switches: switches,
      mounts: mounts,
      peers: peers,
      invocations: invocations,
      facts: [
        { label: "category", value: root.clean(tax.category, 40) + " ("
            + root.clean(tax.confidence, 20) + ", " + root.clean(tax.classifier, 20) + ")" },
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
      usage: "—",
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
      usage: "—",
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
      if (!buckets[key]) { buckets[key] = { key: key, label: label, rows: [] }; order.push(key) }
      return buckets[key]
    }

    var source = root.catalogue
    for (var i = 0; i < source.length; i++) {
      var v = source[i]
      if (root.attentionOnly && v.severity < 2) continue
      if (query !== "" && v.haystack.indexOf(query) < 0) continue

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
          root.categoryLabel[v.category] || v.category).rows.push(v)
      } else {
        bucket("cat:_servers", "MCP servers and plugins").rows.push(v)
      }
    }

    var keys = []
    if (mode === "Category") {
      for (var c = 0; c < root.categoryOrder.length; c++)
        if (buckets["cat:" + root.categoryOrder[c]]) keys.push("cat:" + root.categoryOrder[c])
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
  readonly property string countLine: {
    if (!root.loaded) return ""
    var skills = 0, mcp = 0, plugins = 0, attention = 0
    var perTool = ({})
    for (var i = 0; i < root.rows.length; i++) {
      var r = root.rows[i]
      if (r.rowType !== "row") continue
      var v = r.view
      if (v.kind === "skill") skills++
      else if (v.kind === "mcp") mcp++
      else plugins++
      if (v.severity >= 2) attention++
      if (v.kind === "skill" && root.showTokens) {
        var tools = ["claude", "opencode", "codex"]
        for (var x = 0; x < tools.length; x++) {
          var st = v.tools[tools[x]]
          if (st && st !== "off") perTool[tools[x]] = (perTool[tools[x]] || 0) + (Number(v.tokens) || 0)
        }
      }
    }
    var parts = [String(skills) + (skills === 1 ? " skill" : " skills")]
    if (mcp > 0) parts.push(String(mcp) + " servers")
    if (plugins > 0) parts.push(String(plugins) + " plugins")
    if (attention > 0) parts.push(String(attention) + " need attention")
    if (root.showTokens) {
      var order = ["claude", "opencode", "codex"]
      var cost = []
      for (var o = 0; o < order.length; o++) {
        var n = perTool[order[o]]
        if (!n) continue
        cost.push(root.toolLabel[order[o]] + " ~"
          + (n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n)))
      }
      if (cost.length > 0) parts.push(cost.join(" · ") + " on every turn")
    }
    return parts.join("  ·  ")
  }

  // The helper's own top-level findings belong to files, not to extensions, so
  // they go in a strip above the list rather than becoming rows.
  readonly property string findingLine: {
    if (!root.loaded || !root.report) return ""
    var f = root.report.findings || []
    if (f.length === 0) return ""
    var out = []
    for (var i = 0; i < f.length && i < 3; i++)
      out.push(root.clean(f[i].what, 80) + ": " + root.clean(f[i].detail, 120))
    if (f.length > 3) out.push("and " + String(f.length - 3) + " more")
    return out.join("  ·  ")
  }

  // ---- Cursor and actions -------------------------------------------------

  function currentRow() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.rows.length) return null
    return root.rows[root.selectedIndex]
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    if (!root.cursorActive) { root.cursorActive = true; return }
    root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, root.selectedIndex + delta))
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.cursorActive = true
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

  function copyText(s) {
    var text = String(s || "")
    if (text === "") return
    // Quickshell's clipboard property is not in this build's quickshell-io type
    // description, so it is attempted and the verified path -- Util.execArgv,
    // which puts the string in a positional parameter that bash cannot
    // re-tokenize -- is the fallback rather than the other way round.
    try { Quickshell.clipboardText = text }
    catch (e) { Util.execArgv(["wl-copy", text]) }
    root.flash("Copied " + text)
  }

  function copyCurrent() {
    var r = root.currentRow()
    if (!r || r.rowType === "header") return
    var inv = r.view.invocations
    if (!inv || inv.length === 0) { root.flash("Nothing to copy on this row"); return }
    if (!inv[0].ok) {
      root.flash("That invocation has characters a prompt would not take safely")
      return
    }
    root.copyText(inv[0].text)
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
    if (idx < 0) return root.veryMuted
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

    implicitHeight: Style.space(26)

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
      color: gr.hasCursor ? root.fg : root.veryMuted
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
      color: gr.hasCursor ? root.fg : root.muted
      font.family: root.face
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
    }

    Row {
      id: gmeta
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.md

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
        color: root.veryMuted
        font.family: root.face
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: String(gr.group.count)
        color: root.veryMuted
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
    signal activated()
    signal entered()
    signal copyRequested(string text)

    readonly property int lineHeight: Style.space(30)
    readonly property bool broken: er.view.severity >= 2

    implicitHeight: er.lineHeight + (er.expanded ? detail.implicitHeight + Style.spacing.xl : 0)

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
      color: root.categoryTint(er.view.category)
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
      color: er.hasCursor ? root.fg : root.muted
      font.family: root.face
      font.pixelSize: Style.font.body
    }

    Text {
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.spacing.md
      anchors.right: badge.left
      anchors.rightMargin: Style.spacing.lg
      anchors.top: parent.top
      height: er.lineHeight
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      text: er.view.name
      color: root.fg
      font.family: root.face
      font.pixelSize: Style.font.body
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
      color: root.faint

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: er.view.badge
        color: root.veryMuted
        font.family: root.face
        font.pixelSize: Style.font.caption - 1
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
      color: root.veryMuted
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
        model: [
          { tool: "claude", letter: "C" },
          { tool: "opencode", letter: "O" },
          { tool: "codex", letter: "X" }
        ]

        delegate: Text {
          id: cell
          required property var modelData
          readonly property var toolState: er.view.tools[cell.modelData.tool]

          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(11)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: cell.modelData.letter
          font.family: root.face
          font.pixelSize: Style.font.caption
          font.bold: cell.toolState === "on"
          color: cell.toolState === "on" ? root.hue : root.fg
          opacity: {
            if (cell.toolState === null || cell.toolState === undefined) return 0.14
            if (cell.toolState === "on") return 1.0
            if (cell.toolState === "unknown") return 0.22
            if (cell.toolState === "off") return 0.34
            return 0.60   // name-only / user-invocable-only
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
        if (n === null || n === undefined) return "—"
        return n >= 1000 ? "~" + (n / 1000).toFixed(1) + "k" : "~" + String(n)
      }
      color: root.veryMuted
      font.family: root.face
      font.pixelSize: Style.font.caption
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
      color: root.veryMuted
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
      color: er.broken ? Color.urgent : root.veryMuted
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

      // Opacity, not height: an animated delegate height fights ApplyRange while
      // the keyboard cursor is walking the list.
      Behavior on opacity { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

      sourceComponent: Column {
        spacing: Style.spacing.lg

        Text {
          width: parent.width
          visible: er.view.description !== ""
          textFormat: Text.PlainText
          text: er.view.description
          color: root.muted
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
              color: er.broken ? Color.urgent : root.muted
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
                color: root.veryMuted
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
                color: modelData.value === "off" ? root.veryMuted : root.fg
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
                color: root.veryMuted
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
              required property var modelData
              width: parent.width
              height: Style.space(15)

              Text {
                anchors.left: parent.left
                width: Style.space(86)
                textFormat: Text.PlainText
                text: modelData.tool
                color: root.veryMuted
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(90)
                anchors.right: linkTag.left
                anchors.rightMargin: Style.spacing.md
                textFormat: Text.PlainText
                text: modelData.path
                color: root.muted
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }

              Text {
                id: linkTag
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: modelData.link
                color: modelData.link === "symlink" ? root.hue : root.veryMuted
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

        Row {
          width: parent.width
          spacing: Style.spacing.md
          visible: er.view.invocations.length > 0

          Repeater {
            model: er.view.invocations
            delegate: Rectangle {
              required property var modelData
              width: invText.implicitWidth + Style.space(12)
              height: Style.space(18)
              radius: height / 2
              color: invHover.hovered && modelData.ok
                ? Style.hoverFillFor(root.fg, root.hue) : root.faint

              Text {
                id: invText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: modelData.text
                color: modelData.ok ? root.fg : root.veryMuted
                font.family: root.face
                font.pixelSize: Style.font.caption
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
                color: root.veryMuted
                font.family: root.face
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(90)
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: modelData.value
                color: root.veryMuted
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

        if (event.key === Qt.Key_Escape) {
          if (root.expandedKey !== "") root.expandedKey = ""
          else if (root.attentionOnly) root.attentionOnly = false
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
          root.selectedIndex = 0; root.cursorActive = true; event.accepted = true; return
        }
        if (event.key === Qt.Key_End) {
          root.selectedIndex = root.rows.length - 1
          root.cursorActive = true; event.accepted = true; return
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

        // Single letters are commands only while the filter is empty; once
        // anything has been typed they move to Ctrl and the footer says so. There
        // is no way to have both an unconditional letter command and a filter you
        // can type "copy" into.
        var letter = ctrl
          ? String.fromCharCode(event.key).toLowerCase()
          : String(event.text || "").toLowerCase()
        if ((!typing && !ctrl) || (typing && ctrl)) {
          if (letter === "c") { root.copyCurrent(); event.accepted = true; return }
          if (letter === "r") { root.startScan(); event.accepted = true; return }
          if (letter === "g") { root.cycleGrouping(); event.accepted = true; return }
          if (!ctrl && event.text === "!") {
            root.attentionOnly = !root.attentionOnly
            root.selectedIndex = 0
            event.accepted = true
            return
          }
        }
        if (ctrl) return

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

        // A display of the filter, not a field. A focused editor would eat every
        // key, and the key catcher above owns the keyboard.
        BorderSurface {
          width: parent.width
          height: Style.spacing.controlHeight
          radius: Style.cornerRadius
          color: Style.controlFill(false, root.filterText !== "", root.fg, root.hue)
          borderSpec: Border.controlSpec(root.filterText !== "" ? "hover-cursor" : "normal",
                                         root.fg, root.hue)

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(14)
            textFormat: Text.PlainText
            text: "⌕"
            color: root.veryMuted
            font.family: root.face
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX + Style.space(20)
            anchors.right: filterMeta.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.filterText !== "" ? root.filterText : "Type to search"
            color: root.fg
            opacity: root.filterText !== "" ? 1 : 0.58
            font.family: root.face
            font.pixelSize: Style.font.body
            elide: Text.ElideLeft
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
          text: root.loaded ? root.countLine : "Reading four skill roots…"
          color: root.veryMuted
          font.family: root.face
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        // One strip at a time, in order of who most needs answering.
        Loader {
          id: strip
          width: parent.width
          readonly property string message: root.scanError !== "" ? root.scanError
            : (root.toast !== "" ? root.toast : root.findingLine)
          active: strip.message !== ""
          visible: active

          sourceComponent: BorderSurface {
            implicitHeight: stripText.implicitHeight + Style.spacing.xxl * 2
            radius: Style.cornerRadius
            color: root.scanError !== "" ? Util.alpha(Color.urgent, 0.10)
              : (root.toast !== "" ? Util.alpha(root.hue, 0.10) : Util.alpha(root.fg, 0.05))
            borderSpec: Border.flat(
              root.scanError !== "" ? Util.alpha(Color.urgent, 0.35)
                : (root.toast !== "" ? Util.alpha(root.hue, 0.30) : Util.alpha(root.fg, 0.18)),
              Style.normalBorderWidth)

            Text {
              id: stripText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.xxl
              anchors.rightMargin: Style.spacing.xxl
              textFormat: Text.PlainText
              text: strip.message
              color: root.scanError !== "" ? Color.urgent : root.muted
              font.family: root.face
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
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

        // Keeps the keyboard cursor on screen when it walks past the fold. Zero,
        // not a margin: a non-zero begin scrolls the list on load so the first row
        // and its heading sit above the fold before anything is touched.
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: height - Style.space(40)
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
            color: root.muted
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
            color: root.veryMuted
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
              onCopyRequested: function (text) { root.copyText(text) }
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
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: {
            var typing = root.filterText !== ""
            var parts = [typing ? "Backspace to erase" : "Type to search"]
            parts.push("Enter to open")
            parts.push((typing ? "^C" : "c") + " to copy")
            parts.push((typing ? "^G" : "g") + " to regroup")
            parts.push((typing ? "^R" : "r") + " to rescan")
            parts.push(root.expandedKey !== "" || typing || root.attentionOnly
              ? "Esc to go back" : "Esc to close")
            return parts.join("  ·  ")
          }
          color: root.veryMuted
          font.family: root.face
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
