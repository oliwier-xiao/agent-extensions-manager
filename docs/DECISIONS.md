# Decisions

Recorded as they are made, with the reasoning that settled them. A decision here overrides anything in
`DESIGN.md` that predates it.

## D1 — Identity: `oliwier.agent-skills-manager`, displayed as "Agent Skills Manager"

2026-09-05, renamed twice, settled 2026-09-07. The id keeps the author's existing `oliwier.*`
convention. It was `ai-skills-manager`, then `agent-extensions-manager`, and is now this.

The middle name was chosen against the wrong list. "Extensions" is Claude Code's own umbrella term for
skills, plugins, MCP servers and hooks, and it collides with nothing in the widget picker -- which holds
eleven entries, two of them called "Plugin Manager". But the picker is not where anyone finds this. The
marketplace is, and its catalog was measured rather than guessed: of **2599 listings, "skills" appears in
one haystack and in zero names**, while "agent" is in 28 names -- including the first-party
`omarchy.agents`, displayed simply as "Agents". "Agent Extensions" sitting under "Agents (Built-in)" reads
as an add-on to that widget. And "extension" is a dead search word on a site where every item is one: two
listings match it.

The marketplace's search was read rather than assumed (`assets/js/search.js`, `app.js`). The haystack is
name + description + author + publisher + id + category + kind + tags -- manifest `aliases` are **not** in
it, so they serve only the widget picker. Tokens longer than three characters match as substrings; shorter
ones ("ai", "mcp") match only at a word boundary; multiple words are ANDed; and there is no relevance
ranking at all, the default sort being "Recently added". Two consequences settled the name. Putting "AI"
in it buys exactly nothing, because the `ai` tag already supplies that word and a two-character token
cannot match inside one. And the name is worth only the words the description does not already contain --
"skills" was the one word nobody on the site had.

"Manager" stays despite the two "Plugin Manager" entries in the picker. Without it the name reads as a
pack of skills to install rather than something that manages them, and the author's other listing is
"OpenCode Config Manager", so the pair sits together under one publisher.

Renamed before the marketplace submission, which is the only cheap moment: ids are permanent there and 22
retired ones are blocked from reuse forever. Nothing outside this repository referred to the old id.

## D2 — Upstream updates only where the answer is exact

2026-09-05. Auto-update covers Claude Code plugins (`installed_plugins.json` carries `gitCommitSha` and the
marketplace carries the repo), marketplaces themselves, and npm-sourced OpenCode plugins. Bare skills get
manual linking, stored in the plugin's own `sources.json`.

The measurement that settled it: **zero of the 33 unique skill directories on the author's machine is a git
repository or lives inside one.** The content-hash fallback recovered 32 of 38 candidates, but 29 of those
were ambiguous — the same n8n skill bytes match two different upstream repositories — so the interface
would have to ask "which of these three?" anyway. Guessing buys nothing and risks pulling the wrong tree
over a skill the user edited.

## D3 — MCP servers are read-only in v0.1

2026-09-05. Every MCP server across the three tools is listed, with `connected` / `needs auth` state,
including the claude.ai connectors. None of them gets a toggle yet.

There is no CLI for it (`claude mcp` offers only add/get/list/login/logout/remove), the toggle is per
project, and it would mean writing `~/.claude.json` — 86 KB, shared with whatever Claude Code sessions are
running — under a lock protocol known only from decompiling a single build. Nothing else in v0.1 needs that
file, so deferring this one feature removes the largest write risk from the entire release.

## D4 — "Set up for a project" symlinks by default

2026-09-05. The default is a symlink into `<project>/.claude/skills/<name>`; a copy is one keystroke away
and is what the user should choose when the skill must travel with the repository.

Symlinks are followed by all three tools — confirmed empirically for Claude Code, where a marker skill
symlinked from outside a scratch project loaded in a real session. The cost of the alternative is already
visible on this machine: `~/.claude/skills/omarchy` is a copy that has drifted one line from the
`/usr/share/omarchy` original the other two tools read, so Claude and OpenCode are running different
versions of the same skill and nothing says so.

## D5 — One file is written, and it is the plugin's own

2026-09-07. D3 deferred every write, and the README said the widget wrote nothing at all. Shelving broke
that: which category a skill sits in is a judgement the user makes, there is nowhere in Claude Code,
OpenCode or Codex to record it, and a classifier guess you cannot correct is worse than no classifier.

So there is exactly one write, to `~/.config/agent-ext/categories.json`, a file this plugin owns. It
contains directory names, category names, labels and colours, and nothing else. Deleting it restores every
guess and loses only the shelving. The reasoning that made D3 the right call still holds and still applies
to it: no file belonging to any of the three agents is written, so nothing this plugin does can corrupt a
config another process is holding open.

The write goes through the helper rather than from QML. `bin/agent-ext category` takes its arguments in
argv, validates the whole document before touching the disk, and replaces the file by rename, so a crash
mid-write cannot leave a half-written store the next scan refuses to parse. Every verb is runnable by
hand, which is the same standard the read side is held to.
