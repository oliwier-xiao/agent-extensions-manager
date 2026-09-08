import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The panel: one grouped, searchable list of every skill, MCP server and Claude
// Code plugin the three agents load. bin/agent-skills does all the I/O and prints
// one line of JSON; this file reads it and draws it, and the only process it
// runs to read or change any of that is the helper, wrapped in a /bin/bash
// one-liner that caps the read and takes the whole job group down with it.
// wl-copy and xdg-open are the other two, and neither is handed anything but a
// string the user has just asked to have put somewhere.
//
// The helper registers five subcommands. `scan` and `doctor` only read.
// `category` and `describe note` write the two files this plugin owns,
// ~/.config/agent-skills/categories.json and descriptions.json, which record
// nothing but which shelf a skill was filed on, what that shelf is called, and
// the note somebody wrote about a skill for themselves. `remove`, `describe
// write` and `describe reset` are the three that touch something this plugin did
// not write, and each of them re-stats every path at the moment it acts rather
// than trusting the row that asked. Nothing here ever opens a file for writing
// -- each of those is a helper run with the change in argv -- so what a reviewer
// has to read to believe it is the helper's argument handling rather than the
// whole of this file.
//
// The claim that matters, stated at the width it is actually true: no agent's
// configuration file is written at any point. Two things in an agent's tree can
// change, and each is confirmed by name on its own card before it does: a skill
// directory, which is moved to the desktop trash rather than deleted, and the
// value of one `description:` key, whose author's text is kept so it can be put
// back and every other byte of the file comes through untouched. Every row still
// says where its own state is written and what it currently is, because that
// state is theirs and this panel never writes it -- removing a skill and
// switching one off are different acts, and only the first is here.
Panel {
  id: root
  moduleName: "oliwier.agent-skills-manager"
  ipcTarget: "oliwier.agent-skills-manager"
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

  // ---- The column grid ----------------------------------------------------
  //
  // One set of widths, read by the three things that have to agree on them: the
  // row, the group header that sums the row, and the legend that names them. The
  // row's columns were right-anchored with their widths written where they were
  // used, so they lined up down the list by construction and nothing said what
  // any of them held -- and the group header, which sums two of the same
  // quantities, laid its own numbers out in a right-aligned Row of variable
  // widths, so the sums sat in no column at all. A legend over that would have
  // named columns the totals were not in.
  //
  // Named here, every width is one number in one place, and moving a column
  // moves the heading and the total with it.
  readonly property int colFlag: Style.space(18)
  readonly property int colUsed: Style.space(40)
  readonly property int colTokens: root.showTokens ? Style.space(46) : 0
  readonly property int colAgents: Style.space(15) * 3 + Style.spacing.xs * 2
  readonly property int colScope: Style.space(52)
  readonly property int colKind: Style.space(48)

  // `g` cycles this for the session; the setting owns the default.
  property string groupOverride: ""
  readonly property string groupingWanted:
    root.groupOverride !== "" ? root.groupOverride : root.groupMode

  // A grouping you have already filtered by is not a grouping. Pick one agent and
  // grouping by agent is a heading over a list that is entirely that agent; pick
  // skills and grouping by kind is a heading that says "Skills" over nothing but
  // skills. The agent case was worse than redundant -- an item three agents carry
  // opens a group under each of them, so filtering to OpenCode and grouping by
  // agent put a Claude Code heading at the top of the list you had asked to be
  // OpenCode's, with OpenCode's own group below the fold.
  //
  // So the grouping steps aside for as long as the filter is on. Not a change to
  // what you chose, only to what applies: clearing the filter brings it back.
  readonly property string grouping: {
    var want = root.groupingWanted
    for (var i = 0; i < root.groupModes.length; i++)
      if (root.groupModes[i].key === want) return want
    // Shelf is what the panel opens on and what it falls back to, whenever it is
    // still one of the answers. When it is the thing you filtered by, a flat
    // list is the honest one, because there is nothing left to group.
    for (var j = 0; j < root.groupModes.length; j++)
      if (root.groupModes[j].key === "Category") return "Category"
    return "Nothing"
  }

  // ---- Helper -------------------------------------------------------------

  // Qt.resolvedUrl percent-encodes: a home directory with a space in it would
  // otherwise reach Process as a literal %20 and nothing would start.
  function fromFileUrl(u) {
    var s = String(u || "").replace(/^file:\/\//, "").replace(/\/$/, "")
    try { return decodeURIComponent(s) } catch (e) { return s }
  }
  readonly property string pluginDir: root.fromFileUrl(Qt.resolvedUrl("."))
  readonly property string helperPath: root.pluginDir + "/bin/agent-skills"
  // The helper's shebang is `#!/usr/bin/env python3`, and that is a PATH lookup
  // done by env at a moment nothing here has a say in. Naming the interpreter and
  // handing it the helper as a script means the shebang is never reached, so
  // which Python runs stops being a search result and becomes a decision written
  // down in one place.
  readonly property string pythonPath: "/usr/bin/python3"
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
  //   head -c $4   caps the read before StdioCollector allocates it -- the
  //                collector has no ceiling of its own, its whole surface being
  //                text/data/waitForEnd. The trailing `cat >/dev/null` drains
  //                the rest so the producer never takes SIGPIPE and reports a
  //                failure it did not have.
  //   kill %1      a job spec, not $!. For a pipeline $! is the PID of the last
  //                element while the process-group id is the first element's, so
  //                `kill -- -$!` would signal the wrong group or none at all.
  //                Bash resolves %1 to the job's own group.
  //
  // The interpreter, the helper path, the divisor and the cap land in positional
  // parameters and are never interpolated into the script text, so bash cannot
  // re-tokenize them. Both interpreters are named absolutely -- /bin/bash for
  // this wrapper and /usr/bin/python3 for what it runs -- because neither of
  // them is a thing to go looking for in an inherited PATH.
  readonly property string scanScript:
      "set -m\n"
    + "\"$1\" \"$2\" scan --divisor \"$3\" | { head -c \"$4\"; cat >/dev/null; } &\n"
    + "trap 'kill -TERM %1 2>/dev/null; exit 143' TERM INT\n"
    + "wait %1\n"

  // A cleared environment with three variables put back, each for a stated
  // reason. PATH is fixed so head and cat in the scan wrapper resolve to the
  // system copies; it is no longer what decides which Python runs, because both
  // spawn sites name /usr/bin/python3 themselves and the helper's shebang is
  // never reached. HOME is the root of everything the helper scans.
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

  // The two things this panel changes, and it changes both through the same
  // helper the reading goes through rather than by writing anything from QML.
  // Arguments land in argv, never in a script, so nothing here can be
  // re-tokenized by a shell -- there is no shell.
  //
  // Every caller puts its options first and ends them with a `--`, so the
  // arguments after it are positional whatever they look like. A skill directory
  // is named by whoever wrote the skill and can be called `-h`; the helper's
  // parser would read that as a request for help, print it and exit 0, and an
  // exit 0 is what this panel reports back as a change that has been saved.
  //
  // The spawn itself lives here rather than in each caller, because all of it
  // has to be true of every run: an argv list rather than a script, the
  // interpreter named absolutely, and the cleared environment with the three
  // variables the helper needs put back. What differs between the two writers is
  // what they do with the answer, which is why the guard and the reporting stay
  // with them.
  function startHelper(proc, argv) {
    proc.clearEnvironment = true
    proc.environment = root.scanEnvironment()
    proc.command = [root.pythonPath, root.helperPath].concat(argv)
    proc.running = true
  }

  function runCategory(argv, done) {
    if (catProc.running) { root.flashResult("One at a time", "error"); return }
    catProc.pending = done || ""
    root.startHelper(catProc, ["category"].concat(argv))
  }

  // The one preference this panel keeps, switched from the line it is about and
  // switched back from the screen that owns the shelves. Both ends say where the
  // other one is, because a control that removes itself has to leave its own
  // way back behind, and a line in a toast is read once while a chip on the
  // categories screen is there whenever somebody goes looking.
  function dismissPlacedBy() {
    root.runCategory(["placed-by", "hide"],
                     "placed by is off. The categories screen turns it back on")
  }

  function restorePlacedBy() {
    root.runCategory(["placed-by", "show"], "placed by is back on every card")
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

  // Whether the card still says how a skill came to be on its shelf. It is a
  // question with a shelf life: on a machine nobody has filed anything on yet,
  // "the marketplace listing" and "its description, low confidence" are the
  // difference between a shelf you can trust and one worth checking, and once
  // the shelving is right they are thirty-nine lines saying something already
  // settled. So it is turned off from the line itself, and the store the
  // classifier already reads is what remembers.
  readonly property bool hidePlacedBy: root.report && root.report.categories
    ? root.report.categories.hidePlacedBy === true : false

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

  // The description editor keeps two drafts, because it has two fields and they
  // go to different places. The note is this plugin's own file and costs
  // nothing; the description is somebody else's SKILL.md and is what every
  // agent loads on every turn. Neither leaves the editor until you say so, and
  // the `*Base` value beside each is what the field held when it opened, which
  // is how the panel knows whether there is anything to save and whether backing
  // out is dropping work.
  //
  // Their own text rather than `pickerText`, because that one is a name or a
  // filter and is capped at thirty-two characters on the way in. Both of these
  // run to a paragraph, and the cap here is the one the store and the scanner
  // already agree on.
  readonly property int describeLimit: 1024
  property string describeNote: ""
  property string describeNoteBase: ""
  property string describeText: ""
  property string describeBase: ""
  property bool describeAsking: false

  // Which of the two fields the keystrokes are going into. The panel has no
  // focused QML editor -- the key catcher owns every key and the caret is drawn
  // -- so with two fields on screen there has to be a value that says which one
  // is being typed at, and it has to be visible in the field itself rather than
  // inferred. "note" or "description", and nothing else answers to it.
  property string describeFocus: "note"

  // Dirty per field, because Save writes each of them separately and a prompt
  // that named the wrong one would be asking about a change nobody made.
  //
  // The note is dirty when it differs, empty included: clearing a note is a
  // save. The description is not, because an empty description is not a rewrite
  // -- the helper refuses one and so does this, and `return to default` is the
  // control that means "give the row back to its author".
  readonly property bool describeNoteDirty: root.pickerMode === "describe"
    && root.describeNote.trim() !== root.describeNoteBase
  readonly property bool describeTextDirty: root.pickerMode === "describe"
    && root.describeText.trim() !== ""
    && root.describeText.trim() !== root.describeBase
  readonly property bool describeDirty: root.describeNoteDirty || root.describeTextDirty

  // Whether the editor on screen has anything to write. Two editors share the
  // Save button in the title row now -- a category's name and colour, and a
  // skill's note and description -- and it is lit for whichever of them is dirty.
  readonly property bool saveArmed:
    (root.pickerMode === "style" && root.styleDirty)
    || (root.pickerMode === "describe" && root.describeDirty)

  function saveCurrentEditor() {
    if (root.pickerMode === "style") root.styleSave()
    else if (root.pickerMode === "describe") root.describeSave()
  }

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

  // The codes bin/agent-skills can attach, ranked. Only 2 and above light the urgent
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
    // Still the same fault and still worth the top rank, but a user can now be
    // the cause of it: rewriting the description in one copy of a skill that is
    // installed twice genuinely does make the two differ. The flag is not
    // suppressed for that -- two agents reading different text is the fact it
    // reports either way -- so the sentence names the other way it happens.
    "drift": "Another copy of this skill has different content -- two agents are running different code, and rewriting the description in one copy is one way that happens",
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

  // The same boundary clean() draws -- control characters gone and the bidi
  // overrides that let a crafted description reorder a row removed -- with the
  // two things clean() also does left out, because they are right for a string
  // being displayed and wrong for one being typed. Collapsing runs of
  // whitespace and trimming the ends would eat the space you just pressed, and
  // a field you cannot put a space in is a field you cannot write a sentence
  // in. Nothing is appended when the cap is reached either: this text is a
  // draft that may be written into somebody else's file, and an ellipsis the
  // panel added would go in with it.
  function typable(value, limit) {
    var src = String(value || "")
    var cap = limit || 1024
    var out = ""
    for (var i = 0; i < src.length && out.length < cap; i++) {
      var c = src.charCodeAt(i)
      if (c < 0x20 || c === 0x7f) { out += " "; continue }
      if ((c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e)
          || (c >= 0x2066 && c <= 0x2069)) continue
      out += src.charAt(i)
    }
    return out
  }

  // How this panel spells a token figure, in one place. The row, the group
  // header and the tool chips each wrote it out where it was used, which was
  // fine while the number appeared in three fixed positions; the description
  // card prints two of them side by side and a conditional one beside those,
  // and three figures that round differently in one sentence would be three
  // different claims.
  function tokenText(n) {
    var v = Number(n) || 0
    return v >= 1000 ? "~" + (v / 1000).toFixed(1) + "k" : "~" + String(v)
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
    scanProc.command = ["/bin/bash", "-c", root.scanScript, "agent-skills-scan",
                        root.pythonPath, root.helperPath,
                        String(root.divisor), String(root.maxScanBytes)]
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
      root.scanError = "bin/agent-skills printed nothing. Run it in a terminal: "
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
      root.scanError = "bin/agent-skills did not return a scan. Run it in a terminal: "
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
    root.scanError = "bin/agent-skills could not be run. Check that " + root.helperPath
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
    // figure that stands for all three is the largest of them -- what the
    // heaviest agent carries on every turn. Adding the three together prints a
    // bill nobody is ever handed. It is the fallback, though, not the answer:
    // the helper says which agents have a live process, and the bar spends that
    // to print the figure for the one you are actually paying for.
    var peak = 0
    for (var t in tokens) peak = Math.max(peak, tokens[t])
    root.summary = { at: Date.now(), divisor: root.divisor, skills: skills,
                     enabled: enabled, tokens: peak, attention: attention,
                     perTool: tokens,
                     running: root.report.running || ({}) }
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
        root.flashResult("The change was refused. Run bin/agent-skills category by hand to see why", "error")
      }
    }
  }

  // ---- Removal ------------------------------------------------------------
  //
  // The other thing the panel changes, and the only one that touches anything
  // outside this plugin's own config file. It goes through the same spawn as a
  // shelf change and through the helper's own `remove`, which moves a path to
  // the desktop trash rather than deleting it and re-checks every path at the
  // moment it acts. That re-check is the important half: the row this was
  // started from was drawn by a scan that has already finished, so what it says
  // is advisory, and what the helper stats is what is there now.
  //
  // One at a time and refused rather than queued, the same rule a shelf change
  // follows. It matters more here: two removals started from two keystrokes are
  // two changes to a filesystem that nothing in this panel could put back in
  // order if the second one went wrong half way.
  function runRemove(paths, label) {
    if (removeProc.running) { root.flashResult("One at a time", "error"); return }
    removeProc.label = String(label || "")
    removeProc.reported = false
    removeProc.inflight = true
    root.startHelper(removeProc, ["remove", "--"].concat(paths))
  }

  // Report what the helper said it did, and nothing else. A count worked out
  // here from what was asked for would be a claim about a filesystem this panel
  // never looked at, and the one case that matters is exactly the case where the
  // two disagree: a skill root on a network mount, where the trash is refused
  // and the path is still there afterwards.
  //
  // `removed` is what gio confirmed. The helper lists a path there without
  // moving it only under --dry-run, which nothing in this panel asks for.
  function consumeRemoval(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
    if (!parsed || typeof parsed !== "object") return
    removeProc.reported = true

    var gone = parsed.removed && typeof parsed.removed.length === "number" ? parsed.removed : []
    var kept = parsed.refused && typeof parsed.refused.length === "number" ? parsed.refused : []
    var named = removeProc.label !== "" ? "  " + removeProc.label : ""
    var paths = String(gone.length) + (gone.length === 1 ? " path" : " paths")

    if (kept.length === 0 && gone.length > 0) {
      root.flashResult("Moved to the trash" + named + "  ·  " + paths, "ok")
      return
    }
    // A refusal is repeated in the helper's own words. It names the path and the
    // reason, and the panel has nothing truer to say about either -- least of
    // all about "Trashing on system internal mounts is not supported", which is
    // the sentence a user whose skills live on another filesystem has to read.
    var first = kept.length > 0 ? root.clean(kept[0].reason, 150) : "no reason given"
    if (gone.length === 0) {
      root.flashResult("Nothing was removed  ·  " + first, "error")
      return
    }
    root.flashResult(paths + " removed, " + String(kept.length) + " refused  ·  " + first,
                     "error")
  }

  // exited and streamFinished have no guaranteed order, so the verdict is taken
  // one turn later, when both have certainly landed. Silence is never read as a
  // success: a run whose report could not be parsed is reported as a run nobody
  // can vouch for, and the exit code is not consulted, because the helper exits
  // 0 for a run that removed one path and refused three.
  function settleRemoval() {
    if (removeProc.reported || removeProc.inflight) return
    removeProc.reported = true
    root.flashResult("bin/agent-skills did not say what it removed. Run it in a terminal: "
      + root.helperPath + " remove --dry-run", "error")
  }

  Process {
    id: removeProc
    // What was under the cursor when this was sent, so the answer can still name
    // it after the rescan has taken the row away.
    property string label: ""
    // Whether the helper's own report has been read, and whether the run is
    // still going. Both are the panel's own, rather than the process's, for the
    // reason the scan keeps `scanning`: they have to be true at the moment the
    // verdict is taken rather than at the moment the process object noticed.
    property bool reported: false
    property bool inflight: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.consumeRemoval(text)
        Qt.callLater(root.settleRemoval)
      }
    }

    onExited: function (exitCode, exitStatus) {
      removeProc.inflight = false
      // Re-read whatever happened, a run that removed nothing included. More
      // rows than this one can be stale by the end: a skill reached through a
      // symlink from another agent's root leaves the scan the moment its target
      // does, and one that was only unlinked is still on disk under the agent
      // that owns it.
      root.startScan()
      Qt.callLater(root.settleRemoval)
    }
  }

  // ---- Descriptions -------------------------------------------------------
  //
  // Why this is here at all: every skill an agent can see puts its name and its
  // description into the system prompt on every turn, used or not, and that is
  // the figure this panel exists to print. A description is therefore the one
  // thing a user can rewrite that moves the number -- but only once the agent
  // is reading the new text, which means it has to be in SKILL.md.
  //
  // The editor writes two independent things and they go to two different
  // places. `note` stores your own words about a skill in this plugin's own
  // file: no agent opens that file, so a note costs nothing and is never in any
  // figure this panel prints. `write` replaces the `description:` value in
  // somebody else's SKILL.md, keeping the author's own text so `reset` can put
  // it back -- and that one moves the figure, at the moment it is saved,
  // because the file now says something different.
  //
  // The whole of the file work is the helper's. It replaces one value in the
  // frontmatter and passes every other byte through, reads the file back
  // through the parser the panel and the agents will read it with, and puts the
  // original back if the read-back disagrees. None of that is repeated here.
  //
  // A list of runs rather than one, because a single Save can be both of them
  // and the helper is run one at a time. The second waits for the first to exit
  // rather than racing it, and a refusal drops what is queued behind it: the
  // helper refusing is the helper saying the row that asked was already stale,
  // and the run behind it was built from that same row.
  property var describeQueue: []

  function runDescribe(jobs) {
    if (describeProc.running) { root.flashResult("One at a time", "error"); return }
    if (!jobs || jobs.length === 0) return
    root.describeQueue = jobs.slice(1)
    root.startDescribeJob(jobs[0])
  }

  function startDescribeJob(job) {
    describeProc.pending = String(job.done || "")
    describeProc.detail = ""
    describeProc.code = -1
    describeProc.reported = false
    describeProc.inflight = true
    root.startHelper(describeProc, ["describe"].concat(job.argv))
  }

  // The helper prints one line of JSON and its refusals are one sentence each,
  // already naming the file and the reason. They are repeated in those words
  // rather than translated: the helper is the half that opened the file, and a
  // second version of "SKILL.md has changed since this was written" composed
  // here would be a worse sentence about something this panel did not see.
  function settleDescribe() {
    if (describeProc.reported || describeProc.inflight) return
    describeProc.reported = true
    // Mid-chain: the next run starts here rather than in onExited, so it starts
    // from a process that has already been read as well as exited, and no scan
    // is taken between two halves of one Save.
    if (describeProc.code === 0 && root.describeQueue.length > 0) {
      var next = root.describeQueue[0]
      root.describeQueue = root.describeQueue.slice(1)
      root.startDescribeJob(next)
      return
    }
    root.describeQueue = []
    // Whatever happened, including a refusal. A refusal is usually the helper
    // saying the row that asked was already stale -- the skill moved, or
    // SKILL.md changed underneath -- which is exactly when the list is worth
    // reading again.
    root.startScan()
    if (describeProc.code === 0) {
      root.flashResult(describeProc.pending !== "" ? describeProc.pending
        : (describeProc.detail !== "" ? describeProc.detail : "Saved"), "ok")
      return
    }
    root.flashResult(describeProc.detail !== "" ? describeProc.detail
      : "bin/agent-skills did not say what it did. Run it in a terminal: "
        + root.helperPath + " describe", "error")
  }

  Process {
    id: describeProc
    // What to say when it works, in the panel's own voice, set per call so the
    // line names the change. The helper's own sentence is what a refusal gets.
    property string pending: ""
    property string detail: ""
    // The exit code and whether the run is still going, held here rather than
    // read off the process for the reason the removal keeps its own: the
    // verdict has to be true at the moment it is taken.
    property int code: -1
    property bool reported: false
    property bool inflight: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // The last line, not the whole buffer. One Save can be two runs through
        // this same collector, and a collector that carried the first run's line
        // into the second would hand JSON.parse two objects and get nothing back
        // -- so the refusal that mattered would arrive as no sentence at all.
        // The helper prints one line either way, which makes this free.
        var lines = String(text || "").replace(/\s+$/, "").split("\n")
        var parsed = null
        try { parsed = JSON.parse(lines[lines.length - 1]) } catch (e) { parsed = null }
        if (parsed && typeof parsed === "object")
          // Long enough for a refusal that has to name two absolute paths and
          // then say which of them to act on. At 240 the plugin cache path and
          // the OpenCode path together spent the whole budget and the only
          // actionable clause was the part that got cut.
          describeProc.detail = root.clean(parsed.detail, 480)
        Qt.callLater(root.settleDescribe)
      }
    }

    onExited: function (exitCode, exitStatus) {
      describeProc.code = exitCode
      describeProc.inflight = false
      Qt.callLater(root.settleDescribe)
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

  // Agent ids as the names this panel calls them by, in one string. The helper
  // writes claude, opencode and codex; every other row here has already been
  // through the same translation, and a list of agents is read rather than
  // matched on, so it is joined once at the boundary.
  function toolNames(list) {
    if (!list || typeof list.length !== "number") return ""
    var out = []
    for (var i = 0; i < list.length && i < 8; i++)
      out.push(root.toolLabel[list[i]] || root.clean(list[i], 24))
    return out.join(", ")
  }

  // A command line the panel shows and does not run. Joined for reading only:
  // what would run it is the tool that owns the skill, in a terminal, and this
  // panel spawns one program and it is not another agent's CLI.
  function argvText(argv) {
    if (!argv || typeof argv.length !== "number") return ""
    var out = []
    for (var i = 0; i < argv.length && i < 12; i++) out.push(String(argv[i]))
    return out.join(" ")
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

    // Both of these are attached after the record is built and only on a group
    // that has more than one copy, so they have to be probed rather than assumed.
    // `driftPeers` is the fault -- one copy is behind. `variantPeers` is the same
    // release built once per harness, which is deliberate and gets said quietly.
    var peers = []
    if (Array.isArray(item.driftPeers))
      for (var p = 0; p < item.driftPeers.length && p < 6; p++)
        peers.push(root.clean(item.driftPeers[p], 160))

    var variants = []
    if (Array.isArray(item.variantPeers))
      for (var vp = 0; vp < item.variantPeers.length && vp < 6; vp++)
        variants.push(root.clean(item.variantPeers[vp], 160))

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

    // What removing this skill would mean, decided by the helper because the
    // helper is the half that can stat a path and this one cannot. Nothing here
    // is re-derived: not the mode, not the paths, not which agents lose it. A
    // second opinion computed in QML is how the two halves come to disagree
    // about which directory is about to move, and `linkage` reads "real" for a
    // skill that other roots reach by symlink, so the mounts are the only honest
    // source for a target and the helper has already reduced them to one.
    //
    // Every string that will be drawn goes through clean() like the rest of the
    // record. `abs` deliberately does not: it is never drawn, it is what names
    // the directory to `agent-skills remove`, and clean() collapses runs of
    // whitespace and truncates -- on a path neither of those is cosmetic, and
    // either one names something else or nothing. Absolute is the only thing
    // checked here, because the helper re-stats every path before it acts.
    var removal = null
    var rem = item.removal
    if (rem && typeof rem === "object") {
      var targets = []
      var srcRem = Array.isArray(rem.targets) ? rem.targets : []
      for (var ri = 0; ri < srcRem.length && ri < 12; ri++) {
        var tgt = srcRem[ri]
        if (!tgt) continue
        var abs = String(tgt.abs || "")
        if (abs.charAt(0) !== "/" || abs.length > 4096) continue
        targets.push({ abs: abs,
                       path: root.clean(tgt.path, 200),
                       link: root.clean(tgt.link, 16),
                       tools: root.toolNames(tgt.tools) })
      }
      removal = {
        mode: root.clean(rem.mode, 16),
        why: root.clean(rem.why, 300),
        targets: targets,
        loses: root.toolNames(rem.loses),
        keeps: root.toolNames(rem.keeps),
        restorable: rem.restorable === true,
        restoreNote: root.clean(rem.restoreNote, 200),
        command: root.clean(root.argvText(rem.command), 200)
      }
    }

    // Your own note about this skill, what SKILL.md says now, what its author
    // wrote, and whether this file can be written at all. Read from the helper
    // and never worked out here, for the reason the removal plan is: the helper
    // is the half that can stat a path and open a file, and a second opinion
    // computed in QML is how the two halves come to disagree about which text
    // an agent is loading.
    //
    // The three texts go through typable() rather than clean(). They are drawn,
    // but two of them also seed the editor, and a seed that has had its spacing
    // collapsed and an ellipsis appended is not the author's description any
    // more -- it is a rewrite nobody asked for, one Save away from being written
    // back over the original.
    //
    // An older helper prints no `describe` at all, and then this stays null and
    // the card draws none of the controls. Saying nothing is the honest answer
    // to a build that has not been asked the question.
    var describe = null
    var dsc = item.describe
    if (dsc && typeof dsc === "object") {
      describe = {
        noteText: root.typable(dsc.noteText, 1024),
        fileText: root.typable(dsc.fileText, 1024),
        authorText: root.typable(dsc.authorText, 1024),
        edited: dsc.edited === true,
        canWrite: dsc.canWrite === true,
        whyNot: root.clean(dsc.whyNot, 240),
        writeNote: root.clean(dsc.writeNote, 240),
        handEdited: dsc.handEdited === true,
        // A path, and drawn only. What travels to the helper is `describeAbs`
        // below, which is never rebuilt from a string that has been through
        // clean().
        otherCopy: root.clean(dsc.otherCopy, 240)
      }
    }

    // The file the two writing verbs are told to change, built from the path the
    // helper reported rather than from the string the card draws: tildify() is
    // one-way, and a path re-expanded from `~` is a guess about where home was
    // when the scan ran. Absolute is the only thing checked here, the same as a
    // removal target, because the helper recomputes its own candidates for this
    // name and refuses anything that is not one of them.
    var realDir = String(item.realPath || "")
    var descAbs = realDir.charAt(0) === "/" && realDir.length <= 4096
      ? realDir + "/SKILL.md" : ""

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
      // The length the estimate was taken from, so the editor can move the
      // figure from the same basis the helper used rather than from its own
      // rounded answer.
      tokenChars: Number(item.tokens && item.tokens.chars),
      usage: (Number(u.count) || 0) > 0 ? String(u.count) + "×"
        : (u.source === "not tracked" ? "-" : "unused"),
      attention: codes,
      attentionText: words,
      severity: root.severityOf(codes),
      description: desc,
      switches: switches,
      mounts: mounts,
      removal: removal,
      peers: peers,
      variants: variants,
      declaredVersion: root.clean(item.declaredVersion, 32),
      invocations: invocations,
      argumentChoices: args,
      argumentHint: root.clean(item.argumentHint, 200),
      describe: describe,
      // Where the helper will write, in the two strings a removal target already
      // keeps: this one is drawn and the one below is the one that travels. The
      // drawn string is never the string anything is done to, because clean()
      // collapses runs of whitespace and truncates, and on a path neither of
      // those is cosmetic -- either one names something else or nothing.
      describeFile: root.clean(root.tildify(String(item.realPath || "")) + "/SKILL.md", 200),
      // The file `describe write` and `describe reset` are handed, so that the
      // file that changes is the file this row promised rather than whichever
      // copy of the name the helper would have reached for first. On a skill
      // installed twice under one name those are different files, and the card
      // names this one.
      describeAbs: descAbs,
      facts: [
        // The hint as its author wrote it, so the picker's list can be checked
        // against the source rather than trusted.
        { label: "arguments", value: root.clean(item.argumentHint, 200) },
        // Where the shelf came from, which is the thing worth knowing when the
        // shelf is wrong. Which shelf it is has its own control above.
        //
        // The only fact here that can be dismissed, and the empty value is how:
        // the row already draws nothing for one, so hiding this line needs no
        // second rule and cannot get out of step with the one that is there.
        // Kept in the list rather than spliced out of it so the last fact stays
        // the last fact -- that index is what the controls come to rest on.
        { label: "placed by", value: root.hidePlacedBy ? "" : placedBy,
          dismissable: true },
        { label: "tags", value: root.clean(tags, 120) },
        { label: "content", value: root.clean(item.contentHash, 40) },
        { label: "tokens", value: String(Number(item.tokens && item.tokens.alwaysOn) || 0)
            + " by " + root.clean(item.tokens && item.tokens.method, 20) }
      ],
      // A note you have written is searched alongside the description, because
      // it is your own words about this skill and they are the words you will
      // reach for when you go looking for it. It would be a poor kind of
      // storage that took them and then could not find them.
      haystack: root.fold(name + " " + desc + " "
        + (describe ? describe.noteText : "") + " " + tax.category + " " + tags + " skill")
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
      // MCP servers are read-only in this version. There is no CLI for the toggle, it
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
    // A category is a place to file a skill. mcpView and pluginView write
    // "agents" into this field for every server and every plugin, which was
    // never a claim about where they belong -- the grouping puts them in a
    // bucket of their own whatever they claim, and the chip strip counts only
    // skills. So the filter counted one thing and admitted another: the Agents
    // chip read 5 and gave you thirteen rows. It admits skills only, which is
    // what its own count has always meant.
    if (except !== "category" && root.categoryFilter !== ""
        && (v.kind !== "skill" || v.category !== root.categoryFilter)) return false
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
  // the skill documents twenty-two actions and the one you meant is the whole
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
  // one whose twenty-two actions the picker exists for. Length is the property
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
      var opts = root.pickerRow ? root.pickerOptions(root.pickerRow.view) : []
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
      // The way back to a line somebody switched off from a card. It belongs
      // here rather than in a settings screen this panel does not have: "placed
      // by" answers how the classifier filed a skill, and this is already the
      // one place that is about the shelves themselves rather than about any
      // row on them. It appears only while the line is off, so a reader who
      // never turned it off never meets it.
      if (root.hidePlacedBy) out2.push("\u0000placedby")
      return out2
    }
    if (root.pickerMode === "style") {
      if (root.styleAsking) return ["\u0000save", "\u0000discard"]
      return root.swatches.concat(["\u0000clear"])
    }
    // The description editor is two fields and not a grid, so it offers nothing
    // to step through until it asks the unsaved-changes question, at which point
    // it borrows the same two answers the style editor asks it with.
    if (root.pickerMode === "describe")
      return root.describeAsking ? ["\u0000save", "\u0000discard"] : []
    // Two answers to one question, in the shape the unsaved-category prompt
    // already uses, and the first of them is the one that changes nothing. A
    // mode with nothing to answer draws no chips at all -- an unwritable
    // SKILL.md, a file changed since this panel wrote it, and an edit that
    // belongs to another copy of the name are all answers the helper has already
    // given, and the line above the chips says so instead.
    if (root.pickerMode === "reset")
      return root.describeResettable() ? ["\u0000keepmine", "\u0000restore"] : []
    if (root.pickerMode === "remove")
      return root.removeAnswerable() ? ["\u0000keep", "\u0000remove"] : []
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

  // The row before the mode, which is the order closePicker and the other
  // openers already use in reverse. `pickerMode` is what the overlay's model and
  // its command line are bound to, so setting it first re-evaluated both against
  // a row that was still the last pick's null and each threw on the dereference.
  // Nothing was drawn wrong -- the second assignment put it right in the same
  // frame -- but a warning about nothing is how a journal stops being read. Both
  // readers guard the row as well, so reordering this cannot bring it back.
  function openPicker(row) {
    root.pickerRow = row
    root.pickerMode = "argument"
    root.pickerText = ""
    root.pickerIndex = 0
  }

  function openCategoryPicker(row) {
    root.pickerRow = row
    root.pickerMode = "category"
    root.pickerText = ""
    root.pickerIndex = 0
  }

  // One row at a time, and deliberately no multi-select. Three reasons, decided
  // rather than missed: the set you can point at and the set that can actually
  // be removed are not the same set -- a plugin's skill is its plugin's to
  // remove and one under a .system directory is written back on the next launch
  // -- so a checkbox column would offer a choice the panel would then have to
  // take back one row at a time; the rows are independent, so removing four is
  // four small decisions rather than one big one; and a confirmation covering a
  // list is the confirmation least likely to be read, which is the worst place
  // to put the one action here that cannot be undone from inside the panel.
  //
  // Row before mode, for the reason openPicker states: the overlay's model and
  // its command line are bound to the mode and would otherwise re-evaluate
  // against the previous pick's null row.
  function openRemovePicker(row) {
    root.pickerRow = row
    root.pickerMode = "remove"
    root.pickerReturn = ""
    root.pickerCategory = ""
    root.pickerNaming = false
    root.pickerText = ""
    // On the answer that changes nothing. A confirmation for something
    // irreversible that opens with the irreversible answer under the cursor is
    // a confirmation in name only.
    root.pickerIndex = 0
  }

  // The removal the scan attached to a row, or null. Everything the
  // confirmation says is read from here, which is what keeps the panel from
  // deciding for itself what removing a skill would mean.
  function removalOf(row) {
    if (!row || row.rowType === "header" || !row.view) return null
    var rem = row.view.removal
    if (!rem || typeof rem !== "object" || !rem.mode) return null
    return rem
  }

  function removeMode() {
    var rem = root.removalOf(root.pickerRow)
    return rem ? String(rem.mode) : ""
  }

  // Whether there is anything to answer. `refuse` and `delegate` are the
  // helper's way of saying that this skill is not the panel's to move -- a
  // directory another user owns, one Codex rewrites on every launch, one a
  // plugin brought in -- and neither draws an answer chip, because a control
  // the panel could not honour is a control that lies about what it does.
  function removeAnswerable() {
    var mode = root.removeMode()
    if (mode !== "trash" && mode !== "unlink") return false
    return root.removeTargets().length > 0
  }

  // The paths, in the order the helper put them: every symlink first and the
  // real directory last, so a run that is refused half way cannot leave a link
  // pointing at a directory that has already gone. Each path travels once --
  // a second invocation on a path already trashed could only fail, and would be
  // reported as a failure that never happened.
  function removeTargets() {
    var rem = root.removalOf(root.pickerRow)
    var src = rem && rem.targets && typeof rem.targets.length === "number" ? rem.targets : []
    var out = []
    for (var i = 0; i < src.length; i++) {
      var abs = String(src[i].abs || "")
      if (abs.charAt(0) !== "/") continue
      if (out.indexOf(abs) < 0) out.push(abs)
    }
    return out
  }

  // The same targets as the confirmation draws them. The display path and the
  // absolute path are two different strings on purpose: the one on screen is
  // the one the rest of the panel shows, and the one that travels is never
  // rebuilt from it, because a path re-expanded from `~` is a guess about where
  // home was when the scan ran.
  function removeTargetRows() {
    var rem = root.removalOf(root.pickerRow)
    var src = rem && rem.targets && typeof rem.targets.length === "number" ? rem.targets : []
    var out = []
    var seen = []
    for (var i = 0; i < src.length; i++) {
      // Dropped on the same rule and in the same order as the list that
      // travels, so the card cannot draw a chip for a path nothing will be done
      // to, or leave one out.
      var abs = String(src[i].abs || "")
      if (abs.charAt(0) !== "/" || seen.indexOf(abs) >= 0) continue
      seen.push(abs)
      out.push({ path: String(src[i].path || ""),
                 link: String(src[i].link || ""),
                 tools: String(src[i].tools || "") })
    }
    return out
  }

  // What the second chip does, in the words of the mode the helper chose.
  // `unlink` trashes the links and leaves what they point at, because what they
  // point at is not this user's to move.
  function removeVerb() {
    if (root.removeMode() === "unlink")
      return root.removeTargets().length === 1 ? "Trash the link" : "Trash the links"
    return "Move to the trash"
  }

  function removeSentence() {
    var named = root.pickerRow && root.pickerRow.view
      ? root.clean(root.pickerRow.view.name, 60) : ""
    if (root.removeMode() === "unlink")
      return root.removeTargets().length === 1
        ? "Trash the link to " + named + ", and leave what it points at"
        : "Trash the links to " + named + ", and leave what they point at"
    return "Move " + named + " to the trash"
  }

  // The rest of the removal object, as the label-and-value grid the expanded row
  // already uses for its facts. Only what the helper filled in: an empty value
  // draws no row, so a removal that leaves no agent behind prints no "kept by"
  // line rather than an empty one.
  function removeFacts() {
    var rem = root.removalOf(root.pickerRow)
    if (!rem) return []
    var out = []
    out.push({ label: "loses it", value: String(rem.loses || "") })
    out.push({ label: "kept by", value: String(rem.keeps || "") })
    // What `restorable` false means is that the helper will not vouch for the
    // way back, not that the skill is about to be destroyed -- it says so of a
    // path on another filesystem, where the likeliest outcome is that the trash
    // refuses it and nothing moves at all. So the line promises or declines to
    // promise, and the note underneath is where the reason is.
    if (root.removeAnswerable())
      out.push({ label: "afterwards", value: rem.restorable === true
        ? "you can put it back from the trash"
        : "no promise you can put this one back" })
    out.push({ label: "note", value: String(rem.restoreNote || "") })
    out.push({ label: "removed by", value: String(rem.command || "") })
    return out
  }

  // The describe record the scan attached to a row, or null. Everything the two
  // description screens say is read from here, and a build of the helper that
  // does not print one leaves the controls undrawn rather than guessed at.
  //
  // Tested on the one key the model always fills with a real boolean rather than
  // on the object merely being there, so a record that arrived as something
  // empty reads as no answer instead of as an answer of undefined. Taking a
  // record rather than a row, because the card asks about a view and the picker
  // asks about a row, and the two must not disagree about what counts.
  function describeRecord(d) {
    return d && typeof d === "object" && typeof d.canWrite === "boolean" ? d : null
  }

  function describeOf(row) {
    if (!row || row.rowType === "header" || !row.view) return null
    return root.describeRecord(row.view.describe)
  }

  // The SKILL.md this row is drawn from, absolute, exactly as the scan reported
  // it. It travels with `write` and `reset` so the file that changes is the one
  // the card named: a name can be installed twice, and without this the helper
  // picks a copy of its own. Empty is a refusal rather than a fallback, because
  // a name-only command is the defect.
  function describeTarget(row) {
    var abs = row && row.view ? String(row.view.describeAbs || "") : ""
    return abs.charAt(0) === "/" ? abs : ""
  }

  // Whether the description field can reach the file it was seeded from. The
  // note never asks this -- it goes to this plugin's own store, which is this
  // plugin's to write -- so an unwritable SKILL.md costs the editor one of its
  // two fields and nothing else.
  function describeWritable(row) {
    var d = root.describeOf(row)
    if (!d || d.canWrite !== true || root.describeTarget(row) === "") return false
    // A description longer than the scan carries arrives here already cut, with
    // an ellipsis where the rest of it was. Saving that would write the cut into
    // the file and lose the author's last paragraphs to a field that never had
    // them. One description on this machine is over a thousand characters, so
    // this is a row somebody will really open.
    return String(d.fileText || "").length < root.describeLimit
  }

  // Why the description field is not writable, in the reader's terms. The helper
  // answers for the file; this answers for the one case the helper cannot see,
  // which is the editor's own reach.
  function describeWhyNot(row) {
    var d = root.describeOf(row)
    if (!d) return ""
    if (String(d.fileText || "").length >= root.describeLimit)
      return "This description is longer than the editor holds, so it can only be changed in the file itself."
    return String(d.whyNot || "")
  }

  // What the row will cost once the description in the editor is the description
  // in the file: the row's own measurement, moved by the characters this field
  // has gained or lost, at the divisor the scan was taken with. Not a second
  // tokeniser -- a figure computed one way here and another way in the helper
  // would be two claims about the single number this panel exists to print, and
  // they would drift apart by more than rounding.
  //
  // The length it is measured against is what the field opened with, which is
  // what SKILL.md says. The note has no length in this and never will.
  function describeProjected(now, chars) {
    var moved = root.describeText.trim().length - root.describeBase.length
    // From the character count the scan measured, not from the figure it already
    // rounded. Rounding a rounded number puts this one token away from what the
    // next scan prints, which is the same number in the same panel disagreeing
    // with itself. Half up, because that is what the helper does.
    if (chars !== undefined && chars !== null)
      return Math.max(0, Math.floor((Number(chars) + moved) / root.divisor + 0.5))
    return Math.max(0, Math.round(Number(now) + moved / root.divisor))
  }

  // Whether `return to default` has anything to put back and can put it. The
  // rule the removal card already follows: a control the panel could not honour
  // is a control that lies about what it does, so an unwritable SKILL.md, a file
  // that no longer says what this panel wrote into it, and an edit belonging to
  // another copy of the name each draw their reason instead of a chip.
  //
  // `handEdited` refuses here where it used to be left to the helper, because it
  // now answers for this file rather than for the name: the copy that holds the
  // name's edit is `otherCopy`, so a record saying both `edited` and
  // `handEdited` is saying this very SKILL.md changed underneath, which is
  // precisely what the helper will decline to overwrite.
  function describeResettableFor(d) {
    return !!d && d.edited === true && d.canWrite === true
      && d.handEdited !== true && String(d.otherCopy || "") === ""
  }

  function describeResettable() {
    return root.describeResettableFor(root.describeOf(root.pickerRow))
  }

  // Row before mode, for the reason openPicker states. Both fields are seeded
  // before either, because the editor's own bindings read them the moment the
  // mode changes.
  function openDescribePicker(row) {
    root.pickerRow = row
    var d = root.describeOf(row)
    // The note as it was left, and the description as SKILL.md says it right
    // now. The first keystroke edits rather than wipes, the same as the category
    // editor, and backspace is how either one is cleared.
    root.describeNote = d ? root.typable(d.noteText, root.describeLimit) : ""
    root.describeNoteBase = root.describeNote.trim()
    root.describeText = d ? root.typable(d.fileText, root.describeLimit) : ""
    root.describeBase = root.describeText.trim()
    // On the note, which is the field that changes nothing outside this plugin.
    // A caret opening in the field that overwrites somebody else's file is one
    // keystroke from a rewrite nobody asked for, and every other question here
    // opens on the answer that leaves things alone.
    root.describeFocus = "note"
    root.describeAsking = false
    root.pickerMode = "describe"
    root.pickerReturn = ""
    root.pickerCategory = ""
    root.pickerNaming = false
    root.pickerText = ""
    root.pickerIndex = 0
  }

  // Tab is the whole of the switch, and it moves nowhere the keys cannot go: an
  // unwritable SKILL.md leaves the description on screen to be read with the
  // caret still in the note, because a caret in a field nothing can save is a
  // promise the panel cannot keep. The line on that field says why instead.
  function describeToggleFocus() {
    if (root.describeFocus === "description") { root.describeFocus = "note"; return }
    if (!root.describeWritable(root.pickerRow)) return
    root.describeFocus = "description"
  }

  function openResetPicker(row) {
    root.pickerRow = row
    root.pickerMode = "reset"
    root.pickerReturn = ""
    root.pickerCategory = ""
    root.pickerNaming = false
    root.pickerText = ""
    // On the answer that changes nothing, the same as the removal card. This one
    // is undoable and that one is not, but a confirmation that opens with the
    // cursor on the write is a confirmation in name only either way.
    root.pickerIndex = 0
  }

  // Returning to default puts the author's description back into a file this
  // panel did not create, so it asks first, in a card that says what it will put
  // there. The editor's control comes through here as well, and no draft is lost
  // on the way: the control is not offered while there is one.
  function describeReset() {
    if (!root.describeResettable()) return
    root.openResetPicker(root.pickerRow)
  }

  // One Save, up to two writes, each named by what it changed. Neither is sent
  // unless it differs from what the editor opened with: a run that rewrote a
  // file with the bytes already in it would be a write nobody asked for and a
  // modification time nobody can account for.
  function describeSave() {
    var row = root.pickerRow
    var dir = row && row.view ? root.clean(row.view.dirName, 128) : ""
    if (dir === "") { root.describeAsking = false; root.closePicker(); return }
    var note = root.describeNote.trim()
    var text = root.describeText.trim()
    var jobs = []
    // An emptied note is a save: clearing one is how you take it off the card.
    if (note !== root.describeNoteBase)
      jobs.push({ argv: ["note", "--", dir, note],
                  done: note === "" ? "Note cleared on " + dir : "Note saved on " + dir })
    // An emptied description is not. The store refuses one and so does this,
    // rather than quietly writing it: the control that means "give the row back
    // to its author" is the other one. Nothing is said here because nothing can
    // be -- the message strip is behind this overlay -- so the line under the
    // fields says it while the field is empty.
    var file = root.describeTarget(row)
    // `--expect` is what the field was seeded from, which is what SKILL.md said
    // when the scan drew this row. The panel stays open while somebody types,
    // and a read-modify-write over another author's file with the window left
    // open is how an edit made elsewhere in the meantime disappears. The helper
    // already refuses on a mismatch and says what happened; this is the panel
    // handing it the thing it needs to notice.
    if (text !== "" && text !== root.describeBase && root.describeWritable(row))
      jobs.push({ argv: ["write", "--expect", root.describeBase, "--", dir, file, text],
                  done: root.clean(row.view.name, 60) + " now reads your description" })
    root.describeAsking = false
    root.describeNoteBase = note
    root.describeBase = text
    if (jobs.length > 0) root.runDescribe(jobs)
    root.pickerBack()
  }

  // What the two description cards say under their question, in the same
  // label-and-value grid the removal card and the expanded row already use. An
  // empty value draws no row, so a caveat that does not apply prints nothing
  // rather than an empty line.
  function describeFacts() {
    var row = root.pickerRow
    var d = root.describeOf(row)
    if (!d) return []
    var file = row && row.view ? String(row.view.describeFile || "") : ""
    var out = []
    // The editor states only what its two fields cannot: which copy of the name
    // this is, the caveat on writing it, and where the edit went when it went to
    // another copy. What each field does is written on that field, beside the
    // text it does it to.
    if (root.pickerMode === "describe") {
      out.push({ label: "file", value: file })
      out.push({ label: "caveat",
                 value: d.canWrite === true ? String(d.writeNote || "") : "" })
      out.push({ label: "edit is in", value: String(d.otherCopy || "") })
      return out
    }
    out.push({ label: "writes", value: file })
    out.push({ label: "puts back", value: String(d.authorText || "") })
    out.push({ label: "afterwards", value: "the row reads what its author wrote" })
    return out
  }

  // Why this card is shaped the way it is, in one sentence, in the place the
  // removal card puts the helper's own `why`. It is also where the sentence
  // stands in for a control this panel has declined to draw.
  function detailWhy() {
    if (root.pickerMode === "remove") {
      var rem = root.removalOf(root.pickerRow)
      return rem ? String(rem.why || "") : ""
    }
    var d = root.describeOf(root.pickerRow)
    if (!d) return ""
    if (root.pickerMode === "describe")
      return root.describeWritable(root.pickerRow) ? "" : root.describeWhyNot(root.pickerRow)
    if (root.pickerMode === "reset") {
      if (root.describeResettable())
        return "The description in the file is yours. This puts the author's own back where it is."
      if (d.canWrite !== true) return String(d.whyNot || "")
      if (String(d.otherCopy || "") !== "")
        return "The edit under this name is in " + String(d.otherCopy)
             + ", so there is nothing here to put back."
      if (d.handEdited === true)
        return "SKILL.md no longer says what this panel wrote into it, and the helper refuses rather than overwrite what it did not write."
      return "This row already reads the description its author wrote."
    }
    return ""
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
    var argv = ["style"]
    // The label always travels, so one save both renames and recolours and
    // there is no way to write half of what is on screen. An unchanged label is
    // sent empty, which is how the helper is told to drop its override and go
    // back to the built-in name.
    argv.push("--label")
    argv.push(label === root.categoryLabel[cat] ? "" : label)
    argv.push("--color")
    argv.push(root.styleColourIndex >= 0 && root.styleColourIndex < root.swatches.length
      ? String(root.swatches[root.styleColourIndex]) : "")
    argv.push("--")
    argv.push(cat)
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

    // The same promise for the description editor, which needs it more: what is
    // in those two fields is several sentences somebody may have just written,
    // and there is no other copy of them anywhere.
    if (root.pickerMode === "describe" && root.describeDirty && !root.describeAsking) {
      root.describeAsking = true
      root.pickerIndex = 0
      return
    }
    if (root.describeAsking) {
      root.describeAsking = false
      root.describeNote = root.describeNoteBase
      root.describeText = root.describeBase
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
    root.describeAsking = false
    root.describeNote = ""
    root.describeNoteBase = ""
    root.describeText = ""
    root.describeBase = ""
    root.describeFocus = "note"
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
      if (!root.pickerRow) return ""
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
      if (at === "\u0000addnew") return "new category"
      if (at === "\u0000placedby") return "show placed by on every card again"
      if (at === "\u0000new") return "new category  " + root.newCategoryName()
      return root.categoryLabelFor(at)
    }
    if (root.pickerMode === "style")
      return root.pickerText.trim() === "" ? root.pickerCategory : root.pickerText.trim()
    // The description editor draws two fields of its own instead of this box,
    // so there is no single line here that Enter would act on: Save writes
    // whichever of them has changed, and each field says so where it is.
    if (root.pickerMode === "describe") return ""
    if (root.pickerMode === "reset") {
      if (!root.describeResettable()) return "Close"
      return root.pickerIndex === 1 ? "Put the author's description back" : "Keep what is there"
    }
    if (root.pickerMode === "remove") {
      // The same rule as everywhere else on this line: what Enter does from
      // where the cursor is. With nothing to answer, Enter can only close, and
      // saying so is better than a line that promises a removal the helper has
      // already refused.
      if (!root.removeAnswerable()) return "Close"
      return root.pickerIndex === 1 ? root.removeSentence() : "Keep it"
    }
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
        root.runCategory(["assign", "--create", "--", dir, fresh],
                         dir + " filed under " + fresh)
      } else if (pick !== undefined) {
        root.runCategory(["assign", "--", dir, String(pick)],
                         dir + " filed under " + root.categoryLabelFor(pick))
      }
      root.closePicker()
      return
    }

    if (root.pickerNaming) {
      var named = root.newCategoryName()
      if (named === "") return          // nothing typed yet, or the name is taken
      root.runCategory(["create", "--", named], named + " created")
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
      if (pick2 === "\u0000placedby") {
        // Stay on this screen. The chip goes as soon as the rescan lands, which
        // is answer enough, and closing the index would take away the shelves
        // somebody opened it to look at.
        root.restorePlacedBy()
        root.pickerIndex = 0
        return
      }
      if (pick2 === "\u0000new") {
        var made = root.newCategoryName()
        if (made === "") return
        // Created empty and left empty. It shows up in the index and in the move
        // picker straight away; the filter strip only lists shelves with
        // something on them, so it appears there once you put a skill on it.
        root.runCategory(["create", "--", made], made + " created")
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

    if (root.pickerMode === "describe") {
      if (root.describeAsking) {
        // Two answers to one question, and the cursor starts on the safe one.
        if (root.pickerIndex === 0) { root.describeSave(); return }
        root.describeAsking = false
        root.describeNote = root.describeNoteBase
        root.describeText = root.describeBase
        root.pickerBack()
        return
      }
      root.describeSave()
      return
    }

    // The row is read before the overlay closes, because closePicker drops the
    // row the question was about, and the run is sent afterwards, so the
    // question is off the screen by the time the answer is on its way. The same
    // rule and the same order as the removal below.
    if (root.pickerMode === "reset") {
      if (!root.describeResettable() || root.pickerIndex !== 1) { root.closePicker(); return }
      var dirReset = root.clean(root.pickerRow.view.dirName, 128)
      var fileReset = root.describeTarget(root.pickerRow)
      var namedReset = root.clean(root.pickerRow.view.name, 60)
      root.closePicker()
      if (dirReset === "" || fileReset === "") return
      root.runDescribe([{ argv: ["reset", "--", dirReset, fileReset],
                          done: namedReset + " back to the author's description" }])
      return
    }

    if (root.pickerMode === "remove") {
      // Anything that is not the second chip is the first one. A mode with
      // nothing to answer draws no chips, so Enter there can only close, which
      // is what the line above the chips says it will do.
      if (!root.removeAnswerable() || root.pickerIndex !== 1) { root.closePicker(); return }
      var paths = root.removeTargets()
      var what = root.pickerRow && root.pickerRow.view
        ? root.clean(root.pickerRow.view.name, 60) : ""
      if (paths.length === 0) {
        root.flashResult("The helper named no path to remove on that row", "error")
        root.closePicker()
        return
      }
      // Both read before the overlay closes, because closePicker drops the row
      // the question was about; sent after, so the question is off the screen
      // by the time the answer is on its way.
      root.closePicker()
      root.runRemove(paths, what)
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

  // Ctrl+Delete asks whether to remove the row under the cursor. A command has
  // to take Ctrl here, because the panel promises "Type to search" and every
  // printable key keeps that promise; of what is left, Delete is the one key
  // that already means this everywhere else, and it is the length of a keyboard
  // away from ^C, ^R, ^G, ^M and ^E, which are five letters one slip from each
  // other. This is the only command in the panel that touches a file, so being
  // hard to reach by accident is the point rather than a cost.
  //
  // It opens a question and never removes anything by itself.
  function removeCurrent() {
    var r = root.currentRow()
    if (!r) return
    if (r.rowType === "header") { root.flash("A group header is not a skill"); return }
    if (r.view.kind === "mcp") { root.flash("MCP servers are read-only in this version"); return }
    if (r.view.kind !== "skill") {
      // Where the delegate trail ends. A skill a plugin brought in is sent to
      // its plugin's row, and that row has to say something true when it gets
      // there rather than repeat the refusal it was sent to escape.
      root.flash("A plugin is removed by the tool that installed it, not from here")
      return
    }
    if (!root.removalOf(r)) {
      // Said rather than guessed. An older helper prints a scan with no removal
      // in it, and working one out here from the mounts is exactly the second
      // opinion this panel refuses to have.
      root.flash("This build of bin/agent-skills does not say how to remove a skill")
      return
    }
    root.openRemovePicker(r)
  }

  // The two description commands. Neither changes anything by itself -- ^D opens
  // the editor and ^Z opens the question that puts the author's text back. They
  // take Ctrl for the reason every command here does: the panel promises "Type
  // to search" and every printable key keeps that promise. Neither letter was in
  // use.
  function describeCurrent() {
    var r = root.currentRow()
    if (!r) return
    if (r.rowType === "header") { root.flash("A group header has no description"); return }
    if (r.view.kind !== "skill") {
      root.flash("Only a skill has a description an agent reads on every turn")
      return
    }
    if (!root.describeOf(r)) {
      // Said rather than guessed, the same as the removal. An older helper
      // prints no describe record, and a description rewritten from what the
      // scan happened to show is exactly the second opinion this panel refuses
      // to have about somebody else's file.
      root.flash("This build of bin/agent-skills does not say how to rewrite a description")
      return
    }
    root.openDescribePicker(r)
  }

  // Each refusal in the words the row's own record gives, because the message
  // strip is on screen here and the reason is the whole of the answer: there is
  // nothing to put back, the edit is in another copy, the file has changed since,
  // or it is not this user's to write.
  function resetCurrent() {
    var r = root.currentRow()
    if (!r || r.rowType === "header") return
    var d = root.describeOf(r)
    if (!d) return
    if (d.edited !== true) {
      root.flash("This row already reads the description its author wrote")
      return
    }
    if (String(d.otherCopy || "") !== "") {
      root.flash("The edit under this name is in " + String(d.otherCopy))
      return
    }
    if (d.handEdited === true) {
      root.flash("SKILL.md has changed since this panel wrote it, so it will not be overwritten")
      return
    }
    if (d.canWrite !== true) {
      root.flash(String(d.whyNot || "This one is not this panel's to write"))
      return
    }
    root.openResetPicker(r)
  }

  function revealCurrent() {
    var r = root.currentRow()
    if (!r || r.rowType === "header") return
    var m = r.view.mounts
    if (!m || m.length === 0 || !m[0].abs) { root.flash("Nothing on disk to open"); return }
    root.openInFiles(m[0].abs)
  }

  readonly property var groupModesAll: [
    { key: "Category", label: "category" },
    { key: "Tool", label: "tool" },
    { key: "Kind", label: "kind" },
    { key: "Nothing", label: "none" }
  ]

  // What can be picked right now. The box for a grouping that cannot apply is not
  // drawn at all, for the same reason a kind box that would filter to nothing is
  // not: a control that is on screen and does nothing is worse than one that is
  // absent, because absence is information and a dead button is not.
  readonly property var groupModes: {
    var out = []
    for (var i = 0; i < root.groupModesAll.length; i++) {
      var k = root.groupModesAll[i].key
      if (k === "Tool" && root.toolFilter !== "") continue
      if (k === "Kind" && root.kindFilter !== "") continue
      if (k === "Category" && root.categoryFilter !== "") continue
      out.push(root.groupModesAll[i])
    }
    return out
  }

  // One way in, two ways to reach it: the key cycles, the boxes above the list
  // pick. Both land here so neither can forget to drop the folds, which belong
  // to the grouping that made them and mean nothing under the next one.
  function setGrouping(mode) {
    root.groupOverride = String(mode)
    root.collapsed = ({})
    root.selectedIndex = 0
    root.flash("Grouped by " + root.groupOverride.toLowerCase())
  }

  function cycleGrouping() {
    var at = -1
    for (var i = 0; i < root.groupModes.length; i++)
      if (root.groupModes[i].key === root.grouping) { at = i; break }
    root.setGrouping(root.groupModes[(at + 1) % root.groupModes.length].key)
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
  // Fifteen shelves off one accent. Walking the wheel in order gave neighbouring
  // shelves neighbouring hues -- web and design are one step apart in the list
  // above and were one step apart on the wheel, which is twenty-four degrees,
  // and twenty-four degrees is not a difference a reader can use. So the walk
  // takes a stride co-prime with the number of shelves, which visits every point
  // exactly once and puts consecutive shelves most of the wheel apart; and hue
  // is not asked to carry it alone, because two shelves far apart in hue can
  // still be close in weight. Lightness and saturation step on cycles of three
  // and two, so any two shelves differ on at least two axes.
  function categoryTint(category) {
    var idx = root.categoryOrder.indexOf(String(category || ""))
    if (idx < 0) return root.soft
    var a = root.hue
    if (a.hslSaturation < 0.12) return Util.alpha(root.fg, 0.28 + (idx % 5) * 0.09)
    var n = root.categoryOrder.length
    var h = (a.hslHue < 0 ? 0 : a.hslHue) + ((idx * 7) % n) / n
    var l = a.hslLightness + ((idx % 3) - 1) * 0.11
    var sat = a.hslSaturation * (idx % 2 === 0 ? 1 : 0.74)
    return Qt.hsla(h - Math.floor(h),
                   Math.max(0.16, Math.min(1, sat)),
                   Math.max(0.34, Math.min(0.82, l)), 1)
  }

  // ---- Row delegates ------------------------------------------------------

  // A control inside an expanded card: a word you can click, sized to itself,
  // lit on hover. The card already had one of these written inline -- the shelf
  // chip -- and a description brings three more of the same shape, which is
  // where it becomes worth naming rather than repeating.
  //
  // Every one of them is a click as well as a key, for the reason this file
  // argues about the shelf chip and the paths below it: a key hint in a footer
  // is worth nothing to somebody who arrived with a pointer.
  component CardChip: Rectangle {
    id: cc
    property string label: ""
    property color tone: root.readable
    signal picked()

    width: ccText.implicitWidth + Style.space(22)
    height: Style.space(26)
    radius: height / 2
    color: ccHover.hovered ? Util.alpha(root.fg, 0.18) : Util.alpha(root.fg, 0.08)

    Text {
      id: ccText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: cc.label
      color: ccHover.hovered ? root.fg : cc.tone
      font.family: root.face
      font.pixelSize: Style.font.bodySmall
    }

    HoverHandler { id: ccHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: cc.picked() }
  }

  // One editable field, drawn twice: the note and the description. They are one
  // component because they have to read as a pair -- same width, same radius,
  // same rhythm -- and because what separates them has to be their state rather
  // than their drawing. A label and a tag on one line, the sentence that says
  // where this text goes under it, and a box holding the text.
  //
  // `active` is the whole of the focus signal, and it is deliberately more than
  // one signal at once: the label brightens and thickens, the ground takes the
  // accent, the border lights, the pointer becomes an I-beam and the caret
  // appears. This panel has no focused QML editor to inherit any of that from,
  // so every part of it is drawn -- and one cue on its own was exactly what left
  // a reader unsure which field the keys were going into.
  component DescribeField: Column {
    id: df
    property string label: ""
    property string tag: ""
    property string caption: ""
    property string placeholder: ""
    property string body: ""
    property bool active: false
    property bool editable: true
    property real bodyMax: Style.space(90)
    signal focusRequested()

    spacing: Style.spacing.xs

    Item {
      width: parent.width
      height: dfLabel.implicitHeight

      Text {
        id: dfLabel
        anchors.left: parent.left
        anchors.top: parent.top
        textFormat: Text.PlainText
        text: df.label
        color: df.active ? root.fg : root.soft
        font.family: root.face
        font.pixelSize: Style.font.bodySmall
        font.bold: df.active
      }

      // What this field costs, on the right where a figure belongs. Empty on the
      // field that costs nothing to print, rather than a zero: nothing reads a
      // note, so there is no figure to give.
      Text {
        anchors.left: dfLabel.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: parent.right
        anchors.baseline: dfLabel.baseline
        visible: df.tag !== ""
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: df.tag
        color: root.soft
        font.family: root.face
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      width: parent.width
      visible: df.caption !== ""
      textFormat: Text.PlainText
      text: df.caption
      color: root.soft
      font.family: root.face
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Visibly a field in both states: a ground and a border either way, and the
    // accent only on the one being typed into. The quiet one is not a preview of
    // anything -- it is the same box, waiting its turn.
    BorderSurface {
      width: parent.width
      implicitHeight: dfBody.height + Style.spacing.inputPaddingY * 2
      radius: Style.cornerRadius
      color: df.active ? Util.alpha(root.hue, 0.16) : Util.alpha(root.fg, 0.05)
      // The quiet state takes the theme's own control border, the way every
      // other resting surface here does. The lit one is written out in the
      // accent instead, and deliberately not asked for as a control state:
      // `focus` and `hover-cursor` both default to the foreground at a lower
      // alpha than `normal`, so a field asking for them would come back with a
      // fainter border than the field beside it -- the opposite of the one thing
      // this pair has to say.
      borderSpec: df.active
        ? Border.flat(Util.alpha(root.hue, 0.9), Math.max(1, Style.space(1)))
        : Border.controlSpec("normal", root.fg, root.hue)
      // Dimmed where the helper has said this file cannot be written. The text
      // stays on screen to be read, because reading it is still worth doing; the
      // caption in that state is the helper's own sentence about why.
      opacity: df.editable ? 1 : 0.6

      // The other way into a field, for the hand already on the mouse. It has to
      // take the press as well as the hover, or the click falls through to the
      // floor under the card.
      //
      // Above the text, not under it. A TextEdit takes mouse events even when it
      // is read-only, so declared first this area was covered by the paragraph
      // and only the padding around it answered a click -- one live strip and a
      // dead middle, on the field whose whole job is to be typed into. `z` and
      // not declaration order, so the caret and the placeholder keep theirs.
      MouseArea {
        anchors.fill: parent
        z: 1
        enabled: df.editable
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: df.active ? Qt.IBeamCursor : Qt.PointingHandCursor
        onClicked: df.focusRequested()
      }

      // Wrapped, because both of these run to a paragraph, and bounded, because
      // how long they run is somebody else's answer and a box that grew with it
      // would push the panel's own footer off the bottom of the screen. Past the
      // bound the text slides up rather than scrolling under a bar nobody asked
      // for, so the end being typed is the end that can be seen -- and only in
      // the field holding the keys, because on the other one the beginning is
      // what a reader wants.
      Item {
        id: dfBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Style.spacing.inputPaddingY
        anchors.leftMargin: Style.spacing.controlPaddingX
        anchors.rightMargin: Style.spacing.controlPaddingX
        clip: true
        height: Math.max(Style.space(18),
          Math.min(dfEdit.contentHeight, Math.max(Style.space(36), df.bodyMax)))

        // The same placeholder idiom the name field uses: what to type, where it
        // will be typed, behind the caret rather than after it.
        Text {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          visible: df.body === ""
          textFormat: Text.PlainText
          text: df.placeholder
          color: root.fg
          opacity: 0.5
          font.family: root.face
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
        }

        // A TextEdit, and read-only, and never focused: this panel has no focused
        // editor and the key catcher above owns every keystroke. What it is here
        // for is the two things a wrapped Text cannot do -- lay a paragraph out
        // and say where the insertion point is -- and the caret is drawn on the
        // same 530ms the search field uses, because the panel promises the
        // keyboard is here.
        TextEdit {
          id: dfEdit
          width: parent.width
          y: df.active ? Math.min(0, dfBody.height - dfEdit.contentHeight) : 0
          readOnly: true
          activeFocusOnPress: false
          selectByMouse: false
          cursorVisible: df.active
          cursorPosition: dfEdit.text.length
          textFormat: TextEdit.PlainText
          text: df.body
          color: root.fg
          font.family: root.face
          font.pixelSize: Style.font.bodySmall
          wrapMode: TextEdit.Wrap

          cursorDelegate: Rectangle {
            width: Math.max(1, Style.space(1))
            color: root.fg

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              PropertyAnimation { to: 1; duration: 0 }
              PauseAnimation { duration: 530 }
              PropertyAnimation { to: 0; duration: 0 }
              PauseAnimation { duration: 530 }
            }
          }
        }
      }
    }
  }

  component GroupRow: Item {
    id: gr
    required property var group
    property bool hasCursor: false
    readonly property color tint: root.categoryColourFor(gr.group.category)
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

    // The shelf, drawn as the same chip the filter strip draws it as: one shape,
    // one dot, one count, in two places that mean the same thing.
    //
    // It used to be a bare label with a nine-pixel dot beside it. Fourteen
    // shelves are handed fourteen points around one hue wheel, so two of them
    // are always about twenty degrees apart, and twenty degrees of hue on nine
    // pixels is not a difference anybody can use -- Web and Design read as the
    // same pink. An outlined box carries the same hue on a hundred times the
    // area, and the box is also what stops one shelf's rows from running into
    // the next shelf's heading.
    Rectangle {
      id: shelfChip
      anchors.left: chevron.right
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      width: shelfRow.implicitWidth + Style.space(16)
      height: Style.space(20)
      radius: height / 2
      color: Util.alpha(gr.tint, 0.13)
      border.width: 1
      border.color: Util.alpha(gr.tint, gr.hasCursor ? 0.9 : 0.55)

      Row {
        id: shelfRow
        anchors.left: parent.left
        anchors.leftMargin: Style.space(7)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        // Still the way into renaming and recolouring, and still only on a
        // category grouping: a group of "everything Claude can see" is not a
        // shelf and has no name of yours to change.
        Rectangle {
          id: marker
          anchors.verticalCenter: parent.verticalCenter
          visible: gr.group.category !== ""
          width: visible ? Style.space(14) : 0
          height: Style.space(14)
          radius: width / 2
          color: markerHover.hovered ? Util.alpha(root.fg, 0.20) : "transparent"

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            color: gr.tint
            border.width: markerHover.hovered ? 1 : 0
            border.color: root.fg
          }

          HoverHandler { id: markerHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: gr.styleRequested() }
        }

        Text {
          id: glabel
          anchors.verticalCenter: parent.verticalCenter
          // Capped against the header's own width, never against the row or
          // the chip around it: the chip is sized from this row's content, so
          // measuring this against either of them is the two of them waiting
          // on each other, and what that resolves to is a label of nothing.
          width: Math.min(implicitWidth, Math.round(gr.width * 0.40))
          textFormat: Text.PlainText
          text: gr.group.label
          color: gr.hasCursor ? root.fg : root.strong
          font.family: root.face
          // A label role, not a caption: one step up from the metadata around
          // it, with the tracking a short bold string needs to stop reading as
          // a lump.
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          font.letterSpacing: 0.4
          elide: Text.ElideRight
        }

        // How many things are on this shelf, inside the chip and beside the
        // name, exactly as the filter strip writes it. It used to sit at the
        // right end of the header, in line with the column that counts how many
        // times you have used the skill on that row -- a different quantity
        // wearing the same position.
        Text {
          id: gcount
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: String(gr.group.count)
          color: root.soft
          font.family: root.face
          font.pixelSize: Style.font.caption
        }
      }
    }

    // The two quantities a group sums are two the rows underneath it carry, so
    // they are drawn in those rows' columns: the same width, the same right edge,
    // one heading above both.
    Text {
      id: gflag
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      width: root.colFlag
      horizontalAlignment: Text.AlignRight
      visible: gr.group.attention > 0
      textFormat: Text.PlainText
      text: String(gr.group.attention)
      color: Color.urgent
      font.family: root.face
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: gflag.left
      // Straight over the tokens column: the used column sits between the two and
      // a group has nothing to say in it.
      anchors.rightMargin: Style.spacing.md + root.colUsed + Style.spacing.lg
      anchors.verticalCenter: parent.verticalCenter
      width: root.colTokens
      horizontalAlignment: Text.AlignRight
      visible: root.showTokens && gr.group.tokens > 0
      textFormat: Text.PlainText
      text: gr.group.tokens >= 1000
        ? "~" + (gr.group.tokens / 1000).toFixed(1) + "k"
        : "~" + String(gr.group.tokens)
      color: root.soft
      font.family: root.face
      font.pixelSize: Style.font.caption
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
    signal describeRequested()
    signal removeRequested()

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

    // How far down this row the list is still showing it, in the row's own
    // coordinates. A row cannot work this out for itself: it is `list.contentY`
    // and the view's height measured against this delegate's place in the
    // content, and the delegate is the only thing that can see all three. The
    // card reads it to keep two controls in view on a card taller than the
    // panel. Read only -- writing anything back at the view from in here is how
    // a scroll starts fighting itself.
    property real visibleBottom: 0

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
    // twenty-two actions was to copy it and get `/impeccable` on its own.
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
      width: root.colKind
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
      width: root.colScope
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
      width: root.colTokens
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
      anchors.right: flagCell.left
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      height: er.lineHeight
      width: root.colUsed
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: er.view.usage
      color: root.soft
      font.family: root.face
      font.pixelSize: Style.font.caption
    }

    // A cell, not a dot. The dot is what a row has to say here -- flagged or
    // not -- but a group header has a number, and the two only read as one
    // column if they are laid out in one. The dot keeps the right edge it always
    // had, so nothing moves on a row.
    Item {
      id: flagCell
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.md
      anchors.top: parent.top
      height: er.lineHeight
      width: root.colFlag

      Rectangle {
        id: dot
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Math.round((er.lineHeight - height) / 2)
        width: Style.space(6)
        height: width
        radius: width / 2
        visible: er.view.attention.length > 0
        color: er.broken ? Color.urgent : root.soft
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

      sourceComponent: Item {
        id: card

        // The card measures itself and the row is exactly as tall as the
        // measurement. An Item does not size itself to what is in it and the
        // Loader above only hands down a width, so without this the whole card
        // measures zero and every line of it goes off screen. Stated twice
        // because the two are separate: the implicit height is what the row
        // adds up, the real one is what the card is.
        implicitHeight: cardBody.implicitHeight
        height: cardBody.implicitHeight

        // Where the two controls come to rest, in this item's coordinates. The
        // fact row they park on is a Repeater delegate that nothing out here
        // can name, so that row reports the place rather than being asked for
        // it, and nothing else writes this.
        property real restY: 0

        // The line the controls may not rise above. Everything over it -- the
        // description, the per-agent state rows, the mount paths -- is a column
        // of text, and a control floating across one of those lines reads as
        // belonging to it. Where a row has no category at all, an MCP server
        // has no shelf to be on, the first block below it that is drawn takes
        // the job; asking an undrawn Row for its y gets whatever the Column
        // left there.
        readonly property real ceiling: categoryRow.visible ? categoryRow.y
          : (invocationRow.visible ? invocationRow.y : factsColumn.y)

        // How far down this card the list is still showing it. The row measures
        // that edge against its own top and the card starts one row line below
        // that, so the same edge sits a line height higher in here.
        readonly property real fold: er.visibleBottom - er.lineHeight

        Column {
          id: cardBody
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.spacing.lg

          // The note above the description, and what is true about the description
          // right now. Every skill an agent can see puts its description into the
          // system prompt on every turn, used or not, so a shorter one is the
          // largest lever there is. Changing it is a window of its own, reached
          // from the corner below; this block only reports.
          //
          // Which is why this block has one job above every other: keep two texts
          // apart. What is in SKILL.md is what the agent loads and what the token
          // figure beside the row was computed from. The note above it lives in
          // this plugin's own file, no agent opens that file, and it costs nothing
          // -- so it is drawn in a voice the description is not, and no figure ever
          // goes near it. Drawing the two as one string would make the panel lie
          // about the single number it exists to print.
          Column {
            id: descBlock
            width: parent.width
            spacing: Style.spacing.sm

            // Through root, so this and describeOf() cannot disagree about what
            // counts as an answer: the card asks about a view and the picker asks
            // about a row, and both end up at the same predicate.
            readonly property var desc: root.describeRecord(er.view.describe)
            readonly property bool known: descBlock.desc !== null
              && descBlock.desc !== undefined
            // Whether anything of the reader's own is stored against this name.
            readonly property bool hasNote: descBlock.known
              && String(descBlock.desc.noteText || "") !== ""
            // Whether this copy of the file carries a description this widget
            // wrote. `handEdited` is how the helper says the file has changed
            // since, which makes the text in it nobody's the panel can speak for.
            readonly property bool carriesOurs: descBlock.known
              && descBlock.desc.edited === true && descBlock.desc.handEdited !== true

            visible: er.view.description !== "" || descBlock.known

            // The reader's own words, above the text they were written about,
            // which is the whole of what a note is for. Marked as a quotation
            // rather than as part of the skill: a rule down its left side, the
            // slant a quotation takes everywhere else, and a two-word label so
            // there is no doubt whose sentence this is. No figure anywhere near
            // it -- nothing reads this but the person who wrote it.
            Column {
              width: parent.width
              spacing: Style.spacing.xs
              visible: descBlock.hasNote

              Text {
                textFormat: Text.PlainText
                text: "Note:"
                color: root.soft
                font.family: root.face
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Item {
                width: parent.width
                height: noteBody.implicitHeight

                Rectangle {
                  id: noteRule
                  anchors.left: parent.left
                  anchors.top: parent.top
                  width: Math.max(1, Style.space(2))
                  height: noteBody.implicitHeight
                  radius: width / 2
                  color: Util.alpha(root.hue, 0.55)
                }

                Text {
                  id: noteBody
                  anchors.left: noteRule.right
                  anchors.leftMargin: Style.spacing.md
                  anchors.right: parent.right
                  anchors.top: parent.top
                  textFormat: Text.PlainText
                  text: descBlock.hasNote ? String(descBlock.desc.noteText) : ""
                  color: root.readable
                  font.family: root.face
                  font.pixelSize: Style.font.bodySmall
                  font.italic: true
                  wrapMode: Text.WordWrap
                  maximumLineCount: 6
                  elide: Text.ElideRight
                }
              }
            }

            // Whose text this is, above the passage rather than under it, so the
            // description and the note each sit beneath their own heading and
            // neither line has to be worked out from what it follows. The figure
            // beside it is the row's own, unchanged: this is the cost being paid
            // now, and this line is the only place on the card a figure appears.
            Text {
              width: parent.width
              visible: descBlock.known
              textFormat: Text.PlainText
              text: {
                var counted = root.showTokens && er.view.tokens !== null
                  && er.view.tokens !== undefined
                var now = counted
                  ? "  ·  " + root.tokenText(er.view.tokens) + " on every turn" : ""
                if (er.view.description === "")
                  return "nothing in SKILL.md, so the agent has nothing to match on"
                return (descBlock.carriesOurs ? "your description, in SKILL.md"
                                              : "the author's description, in SKILL.md") + now
              }
              color: root.soft
              font.family: root.face
              font.pixelSize: Style.font.caption
              font.bold: true
              wrapMode: Text.WordWrap
            }
            // What SKILL.md says, which is what the agent reads. It stays here in
            // every state and it is never replaced by the note above it.
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


            // The reassurance that makes a rewrite a reversible act, said on the
            // row rather than only in the card that asked.
            Text {
              width: parent.width
              visible: descBlock.carriesOurs
              textFormat: Text.PlainText
              text: "The author's own description is kept, so return to default puts it back."
              color: root.soft
              font.family: root.face
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Where this file no longer says what the panel wrote into it. Said
            // without naming a culprit, because the panel did not see it happen
            // and the consequence is the same either way: the author's text cannot
            // be put back over something this panel cannot account for.
            Text {
              width: parent.width
              visible: descBlock.known && descBlock.desc.handEdited === true
              textFormat: Text.PlainText
              text: "SKILL.md has changed since this panel wrote its description, so the author's own cannot be put back from here."
              color: Color.urgent
              font.family: root.face
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Which copy holds the edit, when it is not this one. A name can be
            // installed twice and only one of the two carries what was written.
            Text {
              width: parent.width
              visible: descBlock.known && String(descBlock.desc.otherCopy || "") !== ""
              textFormat: Text.PlainText
              text: descBlock.known
                ? "The edit under this name is in " + String(descBlock.desc.otherCopy) : ""
              color: root.soft
              font.family: root.face
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

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

          // Where the state lives. This panel does not write these switches, so the
          // useful thing it can say is which file holds one and what it says now.
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

          // Said, not warned about. Two copies of one release, each compiled for
          // the agent that reads it, is the careful thing to do rather than a
          // mistake -- but it is still worth knowing that the file the other agent
          // loads is not this one.
          Column {
            width: parent.width
            spacing: Style.spacing.xs
            visible: er.view.variants.length > 0

            Repeater {
              model: er.view.variants
              delegate: Text {
                required property string modelData
                width: parent.width
                textFormat: Text.PlainText
                text: (er.view.declaredVersion !== ""
                  ? "also built for another agent, same " + er.view.declaredVersion + "  "
                  : "also built for another agent  ") + modelData
                color: root.soft
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
            id: categoryRow
            width: parent.width
            spacing: Style.spacing.md
            visible: er.view.kind === "skill"

            Text {
              anchors.verticalCenter: parent.verticalCenter
              // The same column the facts below use, so the card has one grid.
              width: Style.space(86)
              textFormat: Text.PlainText
              text: "category"
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
            id: invocationRow
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
            id: factsColumn
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: er.view.facts
              delegate: Item {
                id: factRow
                required property var modelData
                required property int index
                // The controls ride on the last fact rather than opening a row of
                // their own beneath it. That row cost a card's height of empty
                // above the only two things here anybody presses, and pinned them
                // to a margin neither chip is wide enough to have earned.
                //
                // They are no longer drawn in here -- a delegate a Column places
                // and gives one line to cannot follow a scroll -- so what is left
                // of that arrangement is this row holding the line open at the
                // height they need and saying where it is. The height is theirs
                // whether or not they are standing on it: a card that changed
                // height as it was scrolled would be moving the list underneath
                // the scroll.
                readonly property bool carriesControls:
                  index === er.view.facts.length - 1 && cardActions.anythingToDo
                // A fact that can be turned off, and is currently on. Both
                // halves matter: the row that has been dismissed draws nothing
                // at all, so it must not keep drawing the control that dismissed
                // it, and no other fact here is anybody's to switch off.
                readonly property bool dismissable:
                  modelData.dismissable === true && modelData.value !== ""
                width: parent.width
                height: modelData.value === "" && !factRow.carriesControls ? 0
                  : (factRow.carriesControls ? Style.space(26) : Style.space(14))
                visible: modelData.value !== "" || factRow.carriesControls

                // Where the controls come to rest, in the card's coordinates.
                // This row is the only thing that knows: it is a Repeater
                // delegate, and nothing outside the Repeater can name one to ask.
                Binding {
                  when: factRow.carriesControls
                  target: card
                  property: "restY"
                  value: factsColumn.y + factRow.y
                    + Math.round((factRow.height - controls.height) / 2)
                }

                Text {
                  anchors.left: parent.left
                  width: Style.space(86)
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.soft
                  font.family: root.face
                  font.pixelSize: Style.font.caption
                }

                Row {
                  id: valueRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(90)
                  anchors.right: parent.right
                  // The room is kept while the controls are standing in it, and
                  // on a row carrying a control of its own it is kept whether
                  // they are standing there or not. The first is so a long
                  // `tags` elides rather than running under them; the second is
                  // because the chips float over whichever row they happen to
                  // cover, and a control they can cover is a control that
                  // cannot be pressed. Text they hide is only text -- this is
                  // not, so it stays out of the lane they travel in.
                  anchors.rightMargin: (factRow.carriesControls && controls.parked)
                      || (factRow.dismissable && cardActions.anythingToDo)
                    ? controls.width + Style.spacing.md : 0
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.sm

                  Text {
                    id: factValue
                    anchors.verticalCenter: parent.verticalCenter
                    // Sized to the sentence rather than to the row, so the
                    // control below sits against the end of the words instead of
                    // out in a column of its own. Capped at what is left after
                    // that control, which is what keeps the elide honest.
                    width: Math.min(implicitWidth,
                                    valueRow.width - (dismiss.visible
                                      ? dismiss.width + valueRow.spacing : 0))
                    textFormat: Text.PlainText
                    text: modelData.value
                    color: root.soft
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  // The way off, at the end of the sentence it takes away. Drawn
                  // always rather than on hover, at the weight of the line it
                  // belongs to: a control that exists only while the pointer is
                  // over it is one nobody finds, and this one has to be found
                  // once and then never again.
                  //
                  // No confirmation. It changes one boolean in this plugin's own
                  // file, takes nothing away, and says where the way back is at
                  // the moment it happens. The question this panel does ask is
                  // reserved for the one answer that cannot be taken back.
                  Rectangle {
                    id: dismiss
                    anchors.verticalCenter: parent.verticalCenter
                    visible: factRow.dismissable
                    width: Style.space(18)
                    height: Style.space(18)
                    radius: width / 2
                    color: dismissHover.hovered ? Util.alpha(root.fg, 0.18) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "\u00d7"
                      color: dismissHover.hovered ? root.fg : root.soft
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                    }

                    HoverHandler { id: dismissHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.dismissPlacedBy() }
                  }
                }
              }
            }


          // Everything this card can do to the skill it is about, in its bottom
          // corner. None of it goes on the row line: that line carries six
          // columns the row, the group header and the legend all have to agree
          // on, and a control there would be a seventh that only some rows could
          // fill.
          //
          // `edit` opens the window that owns the description -- the note you
          // have written instead of it, what each of them costs, and the two acts
          // that change a file. `delete` opens the question ^Del asks, so a
          // pointer reaches what the keyboard already could. Where the helper
          // says this row is not the panel's to remove, its own answer stands in
          // the control's place, because this file does not draw a control it
          // cannot honour.
          //
          // The alarm colour is not spent here. It belongs to the answer that
          // cannot be taken back, one card further on; a chip that opens a
          // question is not that answer.
          Column {
            id: cardActions
            width: parent.width
            spacing: Style.spacing.xs

            readonly property var removal: er.view.removal
            readonly property string mode: cardActions.removal && cardActions.removal.mode
              ? String(cardActions.removal.mode) : ""
            // Deliberately not Array.isArray, for the reason pickerOptions gives:
            // a nested array that has been through a `var` property and a
            // ListView model is a QVariantList, which still has a length and
            // still answers false to Array.isArray.
            readonly property bool removable:
              (cardActions.mode === "trash" || cardActions.mode === "unlink")
              && !!cardActions.removal.targets
              && typeof cardActions.removal.targets.length === "number"
              && cardActions.removal.targets.length > 0
            readonly property bool refused:
              cardActions.mode === "refuse" || cardActions.mode === "delegate"
            // Whether the last fact row has anything to carry. Asked there rather
            // than answered twice.
            readonly property bool anythingToDo:
              descBlock.known || cardActions.removable

            // Nothing to say on a row with no description of its own, no removal
            // plan and nothing to copy -- an MCP server is all three -- so the
            // block is absent rather than an empty band. Tested on what the row
            // is rather than on what has just happened to it, so the card cannot
            // change height because something was copied.
            visible: descBlock.known || cardActions.mode !== ""
              || er.view.invocations.length > 0

            // The copy tick, still in this corner and still only once the
            // clipboard write has been attempted and reported back, never on the
            // keystroke. It was on the row line for a while, where it covered the
            // token count and the usage count, and then in the footer, a panel's
            // height away from the thing it was about; this corner is where it
            // stopped being in anything's way. It keeps the corner to itself:
            // the two controls come to rest on the fact row above it, because a
            // confirmation that something is already in the clipboard must not
            // take the place a reader is going to look for the button that
            // removes a directory.
            //
            // Faded rather than hidden, so its slot is held open whether or not
            // it is standing in it and nothing on this card moves because
            // something was copied.
            Row {
              anchors.right: parent.right
              spacing: Style.spacing.xs
              opacity: er.copied ? 1 : 0

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "✓"
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

            // The helper's verdict where the chip would be. `refuse` is a
            // directory this user does not own or one an agent rewrites on every
            // launch; `delegate` is a skill a plugin brought in, and the tool that
            // installed it is the one that can take it away. The chips themselves
            // rest on the last fact's line and travel up the card from there, so
            // this sentence has the corner to itself either way.
            Text {
              anchors.right: parent.right
              visible: cardActions.refused
              textFormat: Text.PlainText
              text: cardActions.mode === "delegate"
                ? "removed by the tool that installed it"
                : "not this panel's to remove"
              color: root.soft
              font.family: root.face
              font.pixelSize: Style.font.caption
            }
          }
          }
        }

        // The two things this card can do to the thing it is about. Their place
        // is the last fact row and that is still where they come to rest -- but
        // a card can be taller than the list is, and a control you have to
        // scroll to the end of a long card to reach is one you have to go
        // looking for. So they ride the bottom edge of the viewport between two
        // bounds: never above the category row, never below the line they rest
        // on. When the whole card is on screen both clamps hold them at rest and
        // this is the card it has always been.
        //
        // Out of the fact row and into the card because a Repeater delegate
        // cannot float over anything: the Column above it decides where it goes
        // and it is one line tall. This is one item positioned in the card
        // instead, and the row it parks on reserves its width for exactly as
        // long as it is standing there.
        //
        // Nothing here may move the list. It reads how far the viewport reaches
        // and writes only its own y; the fact row keeps its height whether or
        // not the controls are on it, so a card cannot change height as it is
        // scrolled and pull the list out from under the scroll.
        Item {
          id: controls
          anchors.right: parent.right
          width: controlRow.implicitWidth
          height: controlRow.implicitHeight
          visible: cardActions.anythingToDo

          // Just inside the bottom edge of the viewport, far enough in that they
          // are not sitting on the line the list clips at.
          readonly property real reach:
            card.fold - controls.height - Style.spacing.md
          // Standing on the fact row rather than floating over the card. Asked
          // once here, because two things follow from it and they have to agree:
          // the row keeps the space clear, and the ground below goes away.
          readonly property bool parked: controls.reach >= card.restY

          y: Math.max(card.ceiling, Math.min(card.restY, controls.reach))

          // A ground, for as long as they are over the card's own text. Both
          // chips are a translucent fill over whatever is behind them, which on
          // a mount path is a line of text read straight through two buttons.
          // The fill the picker puts under a question is the one surface in this
          // file that already means "what is underneath does not read through",
          // so it is the one used here rather than a shadow this palette has
          // never drawn. Parked, the row has already made the room and there is
          // nothing to cover.
          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -Style.spacing.lg
            anchors.topMargin: -Style.spacing.xs
            anchors.bottomMargin: -Style.spacing.xs
            radius: height / 2
            visible: !controls.parked
            color: Color.popups.background

            // The card is not the panel: it is the panel's background with the
            // row's own fill laid over it, so a ground painted in the panel
            // colour alone comes out lighter than the card it is sitting on and
            // reads as a plate from somewhere else. The same two layers in the
            // same order composite to the same colour, and the fill is chosen
            // the way CursorSurface chooses it so the ground follows the row
            // under the cursor rather than drifting off it.
            Rectangle {
              anchors.fill: parent
              radius: parent.radius
              color: er.hasCursor ? Style.hoverFillFor(root.fg, root.hue)
                                  : Style.selectedFillFor(root.fg, root.hue)
            }
          }

          Row {
            id: controlRow
            spacing: Style.spacing.sm

            CardChip {
              visible: descBlock.known
              label: "edit"
              onPicked: er.describeRequested()
            }

            CardChip {
              visible: cardActions.removable
              label: "delete"
              onPicked: er.removeRequested()
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
          // The description editor is two fields rather than a grid, and until it
          // asks whether to save it draws no chips at all. Everything below
          // steps through a list that is not there, and every printable key
          // belongs to one of the two texts, so this branch takes the keyboard
          // before any of it. Its own cap and its own sanitiser: `pickerText` is
          // a name held to thirty-two characters, and both of these run to a
          // paragraph that must keep the space just pressed.
          if (root.pickerMode === "describe" && !root.describeAsking) {
            // The one key that moves the caret between the two fields, taken
            // first because everything after it edits whichever field has it.
            // Tab is what a form has always used and it is otherwise unclaimed
            // in this mode: the chip stepping it drives elsewhere runs below
            // this branch, and the panel switch it drives outside the overlay
            // runs after the overlay has returned.
            if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              root.describeToggleFocus(); return
            }
            // Returning to default, on the letter the list gives it, taken
            // before anything can read it as text. Guarded rather than answered:
            // a refusal here would be flashed to the message strip, which this
            // overlay is drawn over, so the key does nothing wherever the control
            // beside it is not drawn and the sentence in its place is what says
            // why.
            if (ctrl && event.key === Qt.Key_Z) { root.describeReset(); return }
            if (root.describeFocus === "description") {
              if (Util.editsFilter(event, root.describeText)) {
                root.describeText = Util.editedFilter(event, root.describeText)
                return
              }
              if (!ctrl && event.text && event.text.length === 1
                  && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127)
                root.describeText = root.typable(root.describeText + event.text,
                                                 root.describeLimit)
              return
            }
            if (Util.editsFilter(event, root.describeNote)) {
              root.describeNote = Util.editedFilter(event, root.describeNote)
              return
            }
            if (!ctrl && event.text && event.text.length === 1
                && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127)
              root.describeNote = root.typable(root.describeNote + event.text,
                                               root.describeLimit)
            return
          }
          // Nothing to step through when the mode draws no chips -- a removal
          // the helper has already refused, or a category filter that matches
          // nothing and is not a name anything could be called. Without this
          // the modulo below is a division by zero, the cursor becomes NaN, and
          // the overlay stops answering keys until it is closed.
          if (count === 0) return
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

          // A removal is answered, not typed at: the two chips are the whole
          // vocabulary, and a letter that quietly filled a field nothing draws
          // would be a keystroke with no effect anybody can see. The same is
          // true of the return-to-default question, and of the editor once it
          // has stopped being two fields and started asking one.
          if (root.pickerMode === "remove" || root.pickerMode === "reset"
              || root.describeAsking) return

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
          // Not a letter, and the only command here that is not: every printable
          // key belongs to the search field, the five letters below are one slip
          // from each other, and this is the one command in the panel that
          // touches a file. Delete is what this means on every other keyboard,
          // and it is a hand's width from all of them.
          if (event.key === Qt.Key_Delete) {
            root.removeCurrent(); event.accepted = true; return
          }
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
          // Two letters nothing here was using: d for the note and description,
          // z for going back to what the author wrote. Each opens a screen
          // rather than doing anything, which is what lets ^Z sit among the
          // letters at all -- it is the one that ends in a write to a file this
          // panel did not create, and the question it opens has the cursor on
          // the answer that leaves the file alone.
          if (letter === "d") { root.describeCurrent(); event.accepted = true; return }
          if (letter === "z") { root.resetCurrent(); event.accepted = true; return }
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
          id: titleBar
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
              text: "Agent Skills Manager"
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
          //
          // It is also the way back out of every overlay. The overlay used to
          // carry a small chip of its own, three lines down and half the size,
          // while this corner sat empty behind a scrim -- two backs in two
          // places, and the bigger, steadier one was the one that did nothing.
          // Now there is one, and it keeps this corner in every state, because a
          // control that changes both what it says and where it is is two
          // changes to follow rather than one.
          //
          // Save stands beside it rather than under it. The two of them used to
          // be a title-sized button with a caption-sized pill tucked below its
          // left edge -- same corner, different height, different radius, no
          // alignment between them -- and the smaller, quieter one was the only
          // one that committed anything. They are one group now: one row, one
          // height, one radius, and the accent belongs to the button that saves.
          Row {
            id: titleActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // Tight enough to read as one control group rather than two things
            // that happen to share a corner.
            spacing: Style.spacing.sm

            // Saving is a decision, so it is a button and not a keystroke you
            // have to know about. It says "Save" in both states rather than
            // flipping to "Saved" when there is nothing to do: both editors back
            // out the moment they write, so "Saved" was a word you could only
            // ever read before you had saved anything. Dimmed is the honest way
            // to say the draft matches what is stored.
            //
            // Two editors share it now, and the description one is the reason it
            // matters that this corner does not move: whichever question is up,
            // the thing that commits it is in the same place.
            Rectangle {
              id: saveButton
              visible: (root.pickerMode === "style" && !root.styleAsking)
                || (root.pickerMode === "describe" && !root.describeAsking)
              width: visible ? saveText.implicitWidth + Style.space(20) : 0
              height: Style.space(26)
              radius: Style.cornerRadius
              color: root.saveArmed
                ? (saveHover.hovered ? Util.alpha(root.hue, 0.46) : Util.alpha(root.hue, 0.30))
                : Util.alpha(root.fg, 0.07)

              Text {
                id: saveText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "Save"
                color: root.saveArmed ? root.fg : root.soft
                font.family: root.face
                font.pixelSize: Style.font.title
              }

              HoverHandler {
                id: saveHover
                enabled: root.saveArmed
                cursorShape: Qt.PointingHandCursor
              }
              TapHandler { onTapped: if (root.saveArmed) root.saveCurrentEditor() }
            }

            Rectangle {
              id: editButton
              width: editRow.implicitWidth + Style.space(20)
              height: Style.space(26)
              radius: Style.cornerRadius
              color: editHover.hovered ? Util.alpha(root.fg, 0.16) : Util.alpha(root.fg, 0.07)

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
                  text: root.pickerOpen ? "\u2190" : "\uDB80\uDFEB"
                  color: editHover.hovered || root.pickerOpen ? root.fg : root.readable
                  font.family: root.face
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.pickerOpen ? "Back" : "Edit"
                  color: editHover.hovered || root.pickerOpen ? root.fg : root.readable
                  font.family: root.face
                  font.pixelSize: Style.font.title
                }
              }

              HoverHandler { id: editHover; cursorShape: Qt.PointingHandCursor }
              TapHandler {
                onTapped: root.pickerOpen ? root.pickerBack() : root.openShelvesPicker()
              }
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
        //
        // Opposite them, how the list is grouped. ^G cycles it and the footer
        // says so, which is worth nothing to someone who came here with a mouse:
        // the only way to find out the list could be grouped by agent was to
        // read a key hint and try it. Four boxes name the choices and take one
        // click to any of them, and they sit on this line rather than a line of
        // their own because this line was half empty and a panel is not obliged
        // to spend a row on a control that fits beside one.
        Item {
          width: parent.width
          visible: root.loaded
          implicitHeight: Math.max(toolFlow.implicitHeight, groupSwitch.height)

        Flow {
          id: toolFlow
          anchors.left: parent.left
          anchors.right: groupSwitch.left
          anchors.rightMargin: Style.spacing.lg
          anchors.verticalCenter: parent.verticalCenter
          visible: root.toolChips.length > 0
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

          Row {
            id: groupSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs
            height: Style.space(24)
            // Filter by all three dimensions at once and the only grouping left
            // is the flat list you are already looking at. One box that cannot
            // be pressed is not a switch.
            visible: root.groupModes.length > 1

            Repeater {
              model: root.groupModes

              Rectangle {
                id: modeChip
                required property var modelData
                readonly property bool on: root.grouping === modeChip.modelData.key

                anchors.verticalCenter: parent.verticalCenter
                width: modeText.implicitWidth + Style.space(16)
                height: Style.space(22)
                radius: Style.cornerRadius
                color: modeChip.on ? Util.alpha(root.hue, 0.30)
                  : (modeHover.hovered ? Util.alpha(root.fg, 0.16) : Util.alpha(root.fg, 0.07))

                Text {
                  id: modeText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: modeChip.modelData.label
                  color: modeChip.on ? root.fg : (modeHover.hovered ? root.readable : root.soft)
                  font.family: root.face
                  font.pixelSize: Style.font.caption
                }

                HoverHandler { id: modeHover; cursorShape: Qt.PointingHandCursor }
                // No toggle-off. Every one of these is a grouping, "none"
                // included, so there is no state for clicking the current one to
                // return to.
                TapHandler {
                  onTapped: if (!modeChip.on) root.setGrouping(String(modeChip.modelData.key))
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

        // ---- The legend --------------------------------------------------
        //
        // Six columns of numbers and glyphs, and until now not one of them said
        // what it was. The token figure was guessable from the tilde; the count
        // beside it -- how many times Claude Code records you having used that
        // skill -- was guessable by nobody, and neither was the difference
        // between the scope word and the three marks next to it.
        //
        // One heading row, above the whole list rather than repeated inside each
        // group, because the group headers sum two of these columns and are laid
        // out in them: a legend per group would be the same six words over and
        // over and would still be missing the totals it explains. It sits above
        // the rule for the same reason a table's head does.
        //
        // Every width here is root's column grid, the same one the row and the
        // group header read, so a heading cannot come to stand over a column it
        // does not name.
        Item {
          width: parent.width
          visible: root.rows.length > 0
          height: visible ? Style.space(15) : 0

          Text {
            anchors.left: parent.left
            // Where a row's name starts: past the shelf bar, the gap, the kind
            // glyph and its gap.
            anchors.leftMargin: Style.space(2) + Style.space(3) + Style.spacing.lg
                                + Style.space(16) + Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "name"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.4
          }

          Text {
            id: legendKind
            anchors.right: legendScope.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            width: root.colKind
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "kind"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.4
          }

          Text {
            id: legendScope
            anchors.right: legendAgents.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            width: root.colScope
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: "scope"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.4
          }

          Text {
            id: legendAgents
            anchors.right: legendTokens.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            width: root.colAgents
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "agents"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.4
          }

          Text {
            id: legendTokens
            anchors.right: legendUsed.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            width: root.colTokens
            visible: root.showTokens
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: "tokens"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.4
          }

          Text {
            id: legendUsed
            anchors.right: legendFlag.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            width: root.colUsed
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: "used"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.4
          }

          // The same key that filters the list down to this column.
          Text {
            id: legendFlag
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            width: root.colFlag
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: "!"
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            font.bold: true
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
              : "Install a skill, or run bin/agent-skills doctor to see what was read."
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
              // How far down this row the viewport still reaches. Handed down
              // rather than worked out inside the row, because the scroll offset
              // and the view's height belong to the list and the row's place in
              // the content belongs to this delegate, and only here are all
              // three in one scope. It is read and never written back: the view
              // steers itself, as the note above says, and a card that answered
              // a scroll by scrolling is the pause-then-jump all over again.
              visibleBottom: list.contentY + list.height - rowHost.y
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
              // The cursor follows the click first, the same as every other
              // control in the card: the question that opens names a row, and
              // the row it names had better be the one that was pointed at.
              onDescribeRequested: {
                root.cursorActive = true
                root.selectedIndex = rowHost.index
                root.openDescribePicker(rowHost.modelData)
              }
              // The card only draws this where the helper said a removal is
              // this panel's to make, so it opens the question directly rather
              // than through removeCurrent, whose guards exist to answer a
              // keystroke that can land on any row at all.
              onRemoveRequested: {
                root.cursorActive = true
                root.selectedIndex = rowHost.index
                root.openRemovePicker(rowHost.modelData)
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
            // Each of the two only where it has something to do, the same rule
            // the removal key follows. Returning to default is offered only
            // where this file carries a description the panel wrote and the
            // helper would let it be put back.
            var dsc = cur && cur.rowType !== "header" ? root.describeOf(cur) : null
            // Named for the control it opens rather than for what you do in
            // there. The card's chip says edit, this key opens the same window,
            // and one act with two names is one the reader has to map.
            if (dsc) parts.push("^D to edit")
            if (root.describeResettableFor(dsc)) parts.push("^Z to default")
            // Only on a row that has an answer to the question. A destructive
            // key nobody has been told about is either never used or used by
            // accident, and this one is only ever offered where the helper has
            // already said what pressing it would mean.
            if (root.removalOf(cur)) parts.push("^Del to remove")
            parts.push("^G to regroup")
            parts.push("^R to rescan")
            parts.push(root.expandedKey !== "" || typing || root.anyChipFilter
              ? "Esc to go back" : "Esc to close")
            return parts.join("  \u00b7  ")
          }
          color: root.soft
          font.family: root.face
          font.pixelSize: Style.font.caption
          // Wraps to a second line before it elides. On a row whose description
          // this panel wrote, this line carries two more promises than it does
          // elsewhere, and a hint cut off at the right edge is the panel keeping
          // a key to itself.
          wrapMode: Text.WordWrap
          maximumLineCount: 2
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
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Under the title, not over it. Covering the whole surface left the top
        // of the panel empty for as long as an overlay was up: the one line that
        // says which panel this is went away exactly when the panel had stopped
        // looking like itself. The title row is the one thing here that is true
        // in every state, so it is the one thing the scrim does not take.
        //
        // titleBar sits inside the header Column, which is not this item's
        // sibling, so its height is read as a number rather than anchored to.
        // The header is pinned to the top, and the title is its first row, so
        // the two are the same edge.
        anchors.top: header.top
        anchors.topMargin: titleBar.height
        visible: root.pickerOpen

        readonly property bool styling: root.pickerMode === "style"
        readonly property bool shelving: root.pickerMode === "category"
        readonly property bool managing: root.pickerMode === "shelves"
        readonly property bool removing: root.pickerMode === "remove"
        // The two description screens. `describing` is the pair of fields typed
        // into; `restoring` is a question with two answers, laid out exactly as
        // the removal question is, because it is the same shape.
        readonly property bool describing: root.pickerMode === "describe"
        readonly property bool restoring: root.pickerMode === "reset"
        // Everything that draws the label-and-value grid under its question.
        // The editor is one of them: which copy of a name it is about, and the
        // caveats on writing it, are facts rather than fields, and the grid the
        // other cards state theirs in is the one place in this panel a reader
        // has already learned to read them.
        readonly property bool detailed: picker.removing || picker.restoring
          || picker.describing
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
          // Swallows the click rather than passing it to the row underneath,
          // and leaves the same way Escape and the back button do rather than
          // by its own route: with an editor open, a stray click on the scrim
          // used to drop a draft that nothing had asked about. Backing out is
          // one function so the three ways of doing it cannot disagree.
          MouseArea { anchors.fill: parent; onClicked: root.pickerBack() }
        }

        // The card, and a floor under it that accepts clicks and does nothing.
        // Without it a click anywhere on the card that is not a chip -- the name
        // you are trying to edit, the hint, the gap between two rows -- falls
        // through to the scrim underneath and dismisses the whole overlay,
        // because a bare Rectangle or Text does not accept mouse events and Qt
        // delivers them to the topmost item that does.
        // Down from the top, on the same line the search field starts on, so
        // the top edge of the panel is the same shape whichever of these is up.
        // Centred, the first thing to read sat a third of the way down behind a
        // band of nothing, and the panel looked emptier the moment it had asked
        // you a question.
        Item {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Style.spacing.lg
          height: cardColumn.implicitHeight

          MouseArea { anchors.fill: parent }

        Column {
          id: cardColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.spacing.xl

          // Which question this is. The way back out of it is the button in the
          // panel's title row, which is on screen for exactly as long as this
          // overlay is; a second one here would be the same word twice, and the
          // smaller of the two.
          Item {
            width: parent.width
            height: Style.space(22)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: picker.width
              textFormat: Text.PlainText
              text: {
                // One grammar for all six states: the thing you are working
                // on, then what this screen does to it. The line sits in the
                // same place at the same size every time, so it cannot be a
                // status here, a bare noun there and a dangling preposition in
                // the third -- the reader learns to read it once.
                var cat = root.categoryLabelFor(root.pickerCategory)
                if (root.styleAsking) return cat + "  \u00b7  unsaved changes"
                if (root.pickerNaming) return "categories  \u00b7  name a new one"
                if (picker.managing) return "categories  \u00b7  pick one to edit"
                if (picker.styling) return cat + "  \u00b7  rename or recolour"
                if (!root.pickerOpen || !root.pickerRow) return ""
                var n = root.clean(root.pickerRow.view.name, 60)
                if (root.describeAsking) return n + "  ·  unsaved changes"
                // The two fields, named, because the window is the only place
                // both of them exist and the heading is where the reader learns
                // there are two.
                if (picker.describing) return n + "  ·  note and description"
                // The same two-way shape the removal heading has, and for the
                // same reason: some of the answers the helper can give are not a
                // write at all, and this is where that is said first.
                if (picker.restoring) return root.describeResettable()
                  ? n + "  ·  return to default"
                  : n + "  ·  nothing to put back"
                if (picker.removing) {
                  // Three of them, because the helper has three answers and two
                  // of them are not a removal at all. The heading is where that
                  // is said first, so nobody reads the rest of the card as a
                  // question they are about to answer.
                  var mode = root.removeMode()
                  if (mode === "refuse") return n + "  \u00b7  not this panel's to remove"
                  if (mode === "delegate") return n + "  \u00b7  another tool owns it"
                  return n + "  \u00b7  remove"
                }
                return picker.shelving ? n + "  \u00b7  move to a category"
                                       : n + "  \u00b7  pick an action"
              }
              color: root.soft
              font.family: root.face
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

          }

          // The two fields, when this is the editor. They replace the preview box
          // below rather than sitting inside it, because that box is a picture of
          // what Enter will do and these are the thing itself: what is in them is
          // what gets written, and a field that looks like a preview is a field
          // nobody tries to type in.
          //
          // Same width, same radius, same rhythm, so they read as a pair -- and
          // the one holding the keys is unmistakable, because that was the whole
          // complaint: it carries the caret, the I-beam and a lit border, and the
          // other goes quiet.
          Column {
            width: parent.width
            spacing: Style.spacing.xl
            visible: picker.describing

            DescribeField {
              width: parent.width
              label: "Note"
              tag: "costs nothing"
              caption: "Kept in this panel's own file. No agent reads it."
              placeholder: "Your own words, shown above the description in this skill's card"
              body: root.describeNote
              // Nothing is lit while the unsaved question is up: the keys have
              // gone to the two chips, and a caret still blinking in a field
              // would be the panel offering a third place to type.
              active: picker.describing && !root.describeAsking
                && root.describeFocus === "note"
              // The one field on this screen that is always writable: it goes to
              // a file this plugin owns, so nothing about somebody else's tree
              // can take it away.
              editable: true
              bodyMax: picker.height * 0.16
              onFocusRequested: root.describeFocus = "note"
            }

            DescribeField {
              id: descriptionField
              width: parent.width
              label: "Description"
              // The figure the whole feature exists for, on the one field that
              // moves it, and only while it is moving: the row's own measurement
              // now, and what that measurement becomes once this text is in the
              // file. Never on the note, under any circumstance.
              tag: {
                if (!root.showTokens || !root.pickerRow || !root.pickerRow.view) return ""
                var counted = root.pickerRow.view.tokens
                if (counted === null || counted === undefined) return ""
                var now = Number(counted)
                var chars = root.pickerRow.view.tokenChars
                var live = root.describeText.trim()
                if (live === "" || live === root.describeBase)
                  return root.tokenText(now) + " on every turn"
                return root.tokenText(now) + " on every turn, "
                     + root.tokenText(root.describeProjected(now, chars)) + " once saved"
              }
              // Where writing is refused the helper's own sentence takes the
              // caption, because it is the sentence that stands in for the
              // control this field would otherwise be. A build that refuses
              // without saying why still gets a caption, because the pair reads
              // as a pair only while both of them have one.
              caption: descriptionField.editable
                ? "SKILL.md itself, which every agent loads."
                : (root.detailWhy() !== "" ? root.detailWhy()
                   : "SKILL.md itself, and not this panel's to write.")
              placeholder: "The description an agent matches on"
              body: root.describeText
              active: picker.describing && !root.describeAsking
                && root.describeFocus === "description"
              editable: root.describeWritable(root.pickerRow)
              bodyMax: picker.height * 0.16
              onFocusRequested: root.describeFocus = "description"
            }
          }

          // What Enter does, at the size of the thing it is. Everything else on
          // this overlay exists to change this one line -- except in the editor,
          // which has two fields of its own above and hides this.
          BorderSurface {
            width: parent.width
            visible: !picker.describing
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
              // Each line names the same action the control beside it names.
              // The question used to ask you to "keep" or "go back" and then
              // offered buttons that said Save and Discard: four words for two
              // actions, and the reader has to map them.
              // Name only what actually changed. Offering to save "the new name
              // and colour" after you only tried a colour is a prompt about a
              // change you did not make, and the reader has to go and check.
              if (root.styleAsking) {
                var renamed = root.pickerText.trim() !== root.styleBaseLabel
                var recoloured = root.styleColourIndex !== root.styleBaseIndex
                var both = renamed && recoloured
                return "Save the new " + (both ? "name and colour" : renamed ? "name" : "colour")
                     + ", or discard " + (both ? "them" : "it") + " and keep what was there?"
              }
              // Name only what actually changed here too. The two fields go to
              // two different files, and a prompt that offered to save "your
              // changes" over one edited field is a prompt about work nobody did.
              if (root.describeAsking) {
                var noted = root.describeNoteDirty
                var wrote = root.describeTextDirty
                var pair = noted && wrote
                return "Save the " + (pair ? "note and the description"
                                           : noted ? "note" : "description")
                     + ", or discard " + (pair ? "them" : "it")
                     + " and keep what was there?"
              }
              // Two states, and each is only said where it is true: a field left
              // empty is not a rewrite and is not sent, and a field at the cap
              // has stopped taking what is typed at it.
              if (picker.describing && root.describeText.trim() === "")
                return "The description is empty, so saving leaves SKILL.md as it is."
              if (picker.describing)
                return root.describeText.length >= root.describeLimit
                  || root.describeNote.length >= root.describeLimit
                  ? "Full at " + String(root.describeLimit) + " characters." : ""
              if (picker.restoring)
                return root.describeResettable()
                  ? "This writes a file this panel did not create. Only the value of the description changes; every other byte comes through untouched."
                  : ""
              if (picker.removing) {
                // What the run will actually do, and only what it will do. The
                // helper trashes one path per invocation and answers for each
                // separately, so a refusal in the middle is not an abandoned
                // job -- and on a skill root that is a different filesystem,
                // being refused is the likely outcome rather than the rare one.
                if (root.removeMode() === "delegate")
                  return "This panel runs the helper and nothing else, so the command below is for you to run."
                if (!root.removeAnswerable()) return ""
                return "Each path is moved to the desktop trash on its own, and one that is refused does not stop the others."
              }
              if (root.pickerNaming) return "Lower case letters, digits and dashes. The new category starts empty \u2014 put something on it with ^M from any row."
              if (picker.managing) return "Pick one to rename it or change its colour. Type a name no category has yet to make a new one."
              if (picker.styling) return "Type to rename it. Pick a colour, or choose theme default to let the theme decide."
              if (picker.shelving) return "Type a name no category has yet to make a new one."
              if (!root.pickerOpen || !root.pickerRow) return ""
              var args = root.pickerRow.view.argumentChoices || []
              for (var i = 0; i < args.length; i++)
                if (args[i].kind === "value")
                  return "This copies the command only \u2014 type the " + args[i].label + " after you paste it."
              return ""
            }
            color: root.soft
            font.family: root.face
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // What removing this would mean, in the helper's words and the
          // helper's paths: the sentence it gave for the mode it chose, one
          // chip per path that will be sent, and what the agents on this
          // machine are left with. Nothing in here is worked out from the
          // row -- a target computed in QML would be a second opinion about
          // which directory is about to move, and two opinions eventually
          // disagree about one.
          //
          // Bounded and scrolling past its cap, for the same reason the chip
          // grid below it is: how many paths there are is somebody else's
          // answer, and a card that grows with it pushes its own footer off the
          // bottom of the screen.
          Flickable {
            width: parent.width
            visible: picker.detailed
            // A much smaller share in the editor, which is the one mode where
            // this grid is not the tallest thing on the card: two fields above it
            // are already allowed a sixth of the height each, and a third spent
            // here before the controls are reached would push them off the bottom.
            height: visible ? Math.min(removeDetail.implicitHeight,
              picker.height * (picker.describing ? 0.16 : 0.34)) : 0
            contentHeight: removeDetail.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
              id: removeDetail
              width: parent.width
              spacing: Style.spacing.md

              // Why this mode and not another one, which is the whole of what
              // the panel knows about the decision. The two description
              // questions put their own sentence in the same place, because
              // they are the same kind of thing: the reason the card looks the
              // way it does, above the facts that follow from it.
              Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: root.detailWhy()
                color: root.readable
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              // One chip per path, in the order they will be sent: every
              // symlink first and the directory itself last. Each says which of
              // the two it is and which agents reach the skill through it,
              // because "two of these three are links" is the fact that decides
              // whether this is a removal or a tidy-up.
              Column {
                width: parent.width
                spacing: Style.spacing.xs
                visible: picker.removing

                Repeater {
                  model: picker.removing ? root.removeTargetRows() : []

                  delegate: Rectangle {
                    id: targetChip
                    required property var modelData
                    readonly property bool link: String(targetChip.modelData.link) === "symlink"

                    width: parent.width
                    height: Style.space(24)
                    radius: Style.cornerRadius
                    color: Util.alpha(root.fg, 0.07)

                    Text {
                      id: targetKind
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(9)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(56)
                      textFormat: Text.PlainText
                      text: targetChip.link ? "link" : "directory"
                      color: targetChip.link ? root.hue : root.readable
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      id: targetTools
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(9)
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: String(targetChip.modelData.tools)
                      color: root.soft
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                    }

                    // The path as the rest of the panel writes it. What travels
                    // to the helper is the absolute one held beside it, which is
                    // never drawn and never rebuilt from this string.
                    Text {
                      anchors.left: targetKind.right
                      anchors.leftMargin: Style.spacing.sm
                      anchors.right: targetTools.left
                      anchors.rightMargin: Style.spacing.md
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: String(targetChip.modelData.path)
                      color: root.readable
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                    }
                  }
                }
              }

              // Who is left with what, and whether it can be put back. The same
              // label column the expanded row lays its facts out in, so the card
              // and the row have one grid between them -- and the same grid the
              // two description questions state their file, their text and their
              // token figure in, so all three cards read the same way.
              Column {
                width: parent.width
                spacing: Style.spacing.xs

                Repeater {
                  model: !picker.detailed ? []
                    : (picker.removing ? root.removeFacts() : root.describeFacts())

                  delegate: Item {
                    id: removeFact
                    required property var modelData

                    width: parent.width
                    visible: String(removeFact.modelData.value) !== ""
                    height: visible ? Math.max(Style.space(15), factValue.implicitHeight) : 0

                    Text {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      width: Style.space(86)
                      textFormat: Text.PlainText
                      text: String(removeFact.modelData.label)
                      color: root.soft
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      id: factValue
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(90)
                      anchors.right: parent.right
                      anchors.top: parent.top
                      textFormat: Text.PlainText
                      text: String(removeFact.modelData.value)
                      color: root.readable
                      font.family: root.face
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                    }
                  }
                }
              }
            }
          }

          // The one answer this window holds besides saving: giving the row back
          // to whoever wrote it. It is drawn as a control rather than as a chip
          // in the grid below, because this mode is two fields -- every printable
          // key belongs to one of the texts, so the grid the arrows step through
          // is empty here and an answer has to be something that can be pointed
          // at. ^Z reaches it from the keyboard, on the letter the list uses.
          //
          // It is not drawn where the helper has said it cannot be honoured,
          // which is this file's rule everywhere else; the sentence above it is
          // what stands in the missing control's place.
          Column {
            id: describeAnswers
            width: parent.width
            spacing: Style.spacing.sm

            // A draft nobody has saved is not offering this yet: returning to
            // default replaces the description in the file, and the field is
            // showing a different one that would be dropped without being asked
            // about.
            readonly property bool resettable: root.describeResettable()
              && !root.describeDirty
            readonly property string caveat: {
              var d = root.describeOf(root.pickerRow)
              if (!d || d.edited !== true) return ""
              // Which of them it is: a control one press away, or one that was
              // never going to be offered on this row.
              if (root.describeResettable() && root.describeDirty)
                return "Save or discard first, then return to default."
              if (String(d.otherCopy || "") !== "")
                return "The edit under this name is in another copy, so there is nothing here to put back."
              if (d.handEdited === true)
                return "SKILL.md has changed since this panel wrote its description, and the helper refuses rather than overwrite what it did not write."
              return ""
            }

            visible: picker.describing && !root.describeAsking
              && (describeAnswers.caveat !== "" || describeAnswers.resettable)

            Text {
              width: parent.width
              visible: text !== ""
              textFormat: Text.PlainText
              text: describeAnswers.caveat
              color: root.soft
              font.family: root.face
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Flow {
              width: parent.width
              spacing: Style.spacing.sm
              visible: describeAnswers.resettable

              CardChip {
                label: "return to default"
                onPicked: root.describeReset()
              }
            }
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
                  readonly property bool isPlacedBy: String(chip.modelData) === "\u0000placedby"
                  readonly property bool isAnswer: String(chip.modelData) === "\u0000save"
                    || String(chip.modelData) === "\u0000discard"
                  // The one chip in this panel whose answer cannot be taken back
                  // from inside it, and it does not look like the one beside it.
                  // Writing a description into SKILL.md is a write too, but the
                  // author's own text is kept and a control puts it back; a
                  // trashed directory is only recoverable somewhere else. The
                  // alarm colour is the same one a flagged row is drawn in, so
                  // it is a colour this list has already taught the reader.
                  readonly property bool isDanger: String(chip.modelData) === "\u0000remove"

                  // A shelf chip carries its own colour and its size, so the
                  // index reads as an inventory rather than as a word list.
                  readonly property bool isShelf: picker.shelfList && !chip.isNew
                    && !chip.isAddNew && !chip.isPlacedBy

                  implicitWidth: chip.isSwatch && !chip.isClear
                    ? Style.space(30) : chipRowInner.implicitWidth + Style.space(22)
                  implicitHeight: Style.space(28)
                  radius: Style.cornerRadius
                  color: {
                    if (chip.isSwatch && !chip.isClear)
                      return Util.alpha(String(chip.modelData), chip.current ? 1.0 : 0.72)
                    if (chip.isDanger)
                      return Util.alpha(Color.urgent, chip.current ? 0.34 : 0.14)
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
                        if (String(chip.modelData) === "\u0000keep") return "Keep it"
                        // Each of these names the act rather than agreeing with
                        // the question, so the chip and the line above it are
                        // one sentence and neither has to be read twice.
                        if (String(chip.modelData) === "\u0000keepmine") return "Keep what is there"
                        if (String(chip.modelData) === "\u0000restore") return "Put the author's back"
                        // Named by the mode the helper chose, so the chip and
                        // the line above it are one sentence rather than two.
                        if (chip.isDanger) return root.removeVerb()
                        if (chip.isClear) return "theme default"
                        if (chip.isAddNew) return "+ new category"
                        if (chip.isPlacedBy) return "show placed by"
                        if (chip.isNew) return "+ new  \u201c" + root.newCategoryName() + "\u201d"
                        if (picker.shelfList) return root.categoryLabelFor(String(chip.modelData))
                        return String(chip.modelData) === "" ? "no argument" : String(chip.modelData)
                      }
                      color: chip.isDanger ? Color.urgent
                        : (chip.current ? root.fg : root.readable)
                      font.family: root.face
                      font.pixelSize: Style.font.bodySmall
                      // Italic for the chips that do something rather than name
                      // a shelf, which is the distinction this grid already
                      // draws between "+ new category" and every shelf beside it.
                      font.italic: String(chip.modelData) === "" || chip.isNew
                        || chip.isAddNew || chip.isPlacedBy
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
              if (root.styleAsking) return "Enter to save  \u00b7  Esc to discard"
              if (root.describeAsking) return "Enter to save  \u00b7  Esc to discard"
              if (picker.describing) {
                // Swapped by state rather than grown, the same rule the panel's
                // own footer follows: a key is named here only where the control
                // beside it is on screen to be pointed at instead. Tab leads,
                // because with two fields on screen it is the first thing a
                // reader needs and the only gesture this window added.
                var keys = [root.describeWritable(root.pickerRow)
                  ? "Tab between the fields" : "Type the note", "Enter to save"]
                if (root.describeResettable() && !root.describeDirty)
                  keys.push("^Z to default")
                keys.push("Esc to go back")
                return keys.join("  \u00b7  ")
              }
              // Escape says what it leaves behind rather than where it goes,
              // because on these overlays leaving is itself an answer.
              if (picker.restoring) return root.describeResettable()
                ? "Arrows to choose  \u00b7  Enter to answer  \u00b7  Esc to keep what is there"
                : "Nothing to answer here  \u00b7  Esc to go back"
              if (picker.removing) return root.removeAnswerable()
                ? "Arrows to choose  \u00b7  Enter to answer  \u00b7  Esc to keep it"
                : "Nothing to answer here  \u00b7  Esc to go back"
              if (root.pickerNaming) return "Type the name  \u00b7  Enter to create it  \u00b7  Esc to go back"
              if (picker.managing) return "Type to filter or name a new one  \u00b7  Enter to edit it  \u00b7  Esc to go back"
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
