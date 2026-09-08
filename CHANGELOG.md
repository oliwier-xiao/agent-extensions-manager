# Changelog

## 0.1.0

First release. Every skill, plugin and MCP server Claude Code, OpenCode and Codex load, in one
searchable list on the bar, with what each one costs in tokens on every turn and the command that
invokes it in the spelling that particular agent expects.

No agent's configuration file is written at any point — nothing here turns a skill on or off, and
every row says so where you would expect a switch. Two files of its own:
`~/.config/agent-skills/categories.json`, written only when you file a skill under a category, and a
cache under `~/.cache/agent-skills` holding one answer pacman already gave. The one thing it can
change in an agent's tree is a skill directory you have confirmed by name, and it changes it by
moving it to the desktop trash rather than deleting it.

### What it does

- **One list across three agents**, deduplicated by where the file really is rather than by name or
  by path, so a skill symlinked into three roots is one row carrying three agent marks instead of
  three rows repeating themselves — and two copies that have stopped sharing their contents are told
  apart by content hash.
- **The always-on token figure**, computed the way Claude Code's own extensions browser computes it,
  per row and per agent. Three agents read one disk and are charged three different bills for it, so
  the bar prints the bill of the agent that is actually running, read out of `/proc` without starting
  anything.
- **The invocation on your clipboard**, addressed through its plugin where a skill arrives inside
  one, and opened as a grid of choices where the skill documents arguments. Nothing is claimed until
  it happens: the panel writes, reads back, and says **Copied** only when the read agrees.
- **Categories you own.** Fourteen are guessed from the description and a skill the rules cannot
  place lands in Unsorted rather than in whichever category was the residual. Every guess is one
  keystroke from being corrected, and the correction goes to the widget's own file, never to a
  skill's.
- **Flags that mean something** — a skill answering to two names across agents, an expired MCP
  token, a copy that has drifted from its original. A category the classifier was unsure of is not a
  problem and is not reported as one.
- **Removing a skill**, with `^Del`, which asks first and names the paths rather than the row. A
  skill is not one thing on disk, so the question is not one question: a directory that is yours goes
  to the trash whole; a skill a package owns is offered only as the links in your own directories; a
  skill a plugin brought points at the plugin; and the six Codex rewrites from an embedded copy every
  launch are refused outright, because a panel that offered the button anyway would be lying about
  what it can do. Nothing is deleted, every path is re-examined at the moment it is acted on, and a
  link that cannot be moved holds back the directory it points at.

### Requirements

Omarchy 4 with its Quickshell bar, `python3` at `/usr/bin/python3`, and — for removal only —
`/usr/bin/gio` from `glib2`, which a stock install already has because most of the desktop depends on
it. Without it the panel still reads everything and only the removal is refused. No Python package
beyond the standard library: the frontmatter reader is hand-written rather than reaching for PyYAML, which is
not in the Omarchy base set and which rejects real skill files all three agents read without
complaint.
