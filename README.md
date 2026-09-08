# Agent Skills Manager

Every skill, plugin and MCP server your coding agents load, in one list on your Omarchy bar.

Claude Code, OpenCode and Codex each keep theirs somewhere else — three sets of skill roots, three config
files, and connectors that live nowhere on disk at all. Some of it is the same skill symlinked into two
places, paid for twice. None of the three will tell you what the other two are loading.

This widget is that view: one searchable list of everything all three can load, with what each item costs
you in tokens on every turn, which agent can see it, and the command that invokes it — on your clipboard,
in the spelling that particular agent expects.

![The mark on the bar, with and without the always-on token figure](docs/bar.png)

The mark is what you click. Beside it the bar can carry one figure, and the one worth carrying is above:
what every skill listing adds to every turn before you have typed a word.

It is the figure for the agent you are actually running — three agents read one disk and are charged three
different bills, so a single number was never honest. The helper finds which of them has a live process
straight out of `/proc`, without starting anything, and prints that agent's bill; two of them up prints the
two added together. The default is the mark alone, because a bar is contested space; leave the label off
and nothing runs at all until you open the panel.

An Omarchy **Quattro** shell plugin (`bar-widget`). It needs `omarchy-shell` and `python3`, which a stock
Omarchy install already has.

---

## Install

```
omarchy plugin add https://github.com/oliwier-xiao/agent-skills-manager.git --enable
```

`--enable` puts it straight on the bar and asks which side you want it on. Leave the flag off to install it
disabled, read the code first, and turn it on later with `omarchy plugin enable
oliwier.agent-skills-manager`.

### Update

```
omarchy plugin update oliwier.agent-skills-manager
omarchy restart shell
```

The restart is not optional. The shell reloads a plugin by re-reading its directory, but a QML component it
has already built keeps the code it was built from — so the widget on your bar goes on running the old
version, with nothing to tell you: the new files are on disk and `omarchy plugin list` shows the new
number. It is the most-reported plugin problem in the Omarchy tracker and is being fixed upstream.

### Remove

```
omarchy plugin remove oliwier.agent-skills-manager
```

One file of yours outlives it, so reinstalling later finds your categories again:

```
rm -f ~/.config/agent-skills/categories.json
```

One more file of its own is worth knowing about but not worth keeping:

```
rm -rf ~/.cache/agent-skills
```

That holds one answer pacman already gave — which packages own the skills you did not install — so a scan
does not have to ask again. Deleting it costs a tenth of a second on the next scan and nothing else.

Beyond those three paths the footprint is nothing, and no agent's configuration file is written at any
point. The one other thing the widget can move is a skill you asked it to remove, and that goes to your
desktop trash under `~/.local/share/Trash`, where it stays until you empty it.

---

## The list

![The panel, grouped by category](docs/panel.png)

Everything the three agents can load, on one surface. The boxes across the top count it three ways — by
kind, by what is flagged, by which agent loads it — and each of them is also a filter.

The three agent boxes rarely agree, and the disagreement is the point. On the machine these screenshots
come from, OpenCode carries **33** items for **~4.2k** tokens a turn, Claude Code **23** for **~1.4k**, and
Codex **2** for **~272** — one set of files, three very different bills. OpenCode reads Claude Code's skill
directory as well as its own, so most of what you installed for one agent is being paid for twice.

Each row says what the thing is, which agents see it, what it costs, and how often you have reached for it.
The coloured bar down the left is its category.

### What a row knows

![A skill opened](docs/card.png)

Open a row and it stops summarising. The description is the one the agents actually read — the text costing
you the tokens in the corner. Under it, the state each agent has this skill in and **the file that state is
written in**, so a claim on this panel is one you can go and check.

Then every path it is reachable from, marked `real` or `symlink`; its category, as a control you can click;
the invocation for each agent; how the category was chosen and how confident that guess was; the content
hash the drift check compares; and the token figure with the divisor that produced it.

### One skill, three agents, five mount points

![diagnose-crash, reachable from five paths](docs/mounts.png)

`diagnose-crash` is a single `SKILL.md`, reachable from `~/.claude/skills`, `~/.codex/skills` and
`~/.agents/skills` — and because OpenCode reads two of those roots too, five paths lead to it across three
agents. It is one row carrying three agent marks, not five rows repeating themselves.

Deduplicating on path alone calls the copies unrelated; on name alone, identical. So every path is
resolved first, grouped by where the file really is, then compared by content hash — which is also what
catches two copies that share a name and have stopped sharing their contents.

### What gets flagged

![The rows that are flagged](docs/attention.png)

`!` shows only what needs looking at, and every count in the header narrows with it. Two things are flagged
here, and no agent reports either:

**A skill answering to two names.** The directory is `taste-skill`; the `SKILL.md` inside declares
`name: design-taste-frontend`. Claude Code invokes a skill by its directory, OpenCode and Codex by the name
it declares — so the same file is `/taste-skill` in one and `/design-taste-frontend` in the other two. Copy
the wrong one and nothing happens, with no error to say why. The row carries both, against the agent each
belongs to.

**A server whose token has expired.** `n8n-mcp` is remote and its stored credentials have run out. OpenCode
will not say so until the moment you need it.

The list stays quiet about everything else. A category the classifier was unsure of is not a problem, and
is not reported as one.

---

## Copying the command

![The command on the clipboard](docs/copied.png)

`^C` puts the invocation on your clipboard in the spelling the agent under the cursor expects. Nothing is
claimed until it happens: the panel writes, reads back, and says **Copied** only when the read agrees. If
neither path was reachable it says so in red and prints the command for you to select by hand.

A skill arriving inside a Claude Code plugin is addressed through it, so that row copies
`/impeccable:impeccable` rather than `/impeccable`. Which version is read is not guessed either — the cache
can hold several, and `installed_plugins.json` records the one Claude Code actually loaded.

### Skills that take arguments

![Picking an action](docs/actions.png)

A skill that takes arguments says so in its frontmatter, in `argument-hint`. `impeccable` documents
twenty-two of them, so copying that row and getting `/impeccable` on its own is not what anybody wanted.
The row says **22 actions** and `^C` opens them as a grid instead.

The assembled command is drawn above the options at reading size and updates as you move, so what will land
on your clipboard is on screen before you press Enter. Arrows move; a letter jumps to the next action
starting with it. **no argument** is the first option, because sometimes the bare command was the point.
Rows without documented arguments copy straight through.

---

## Categories

Which category a skill belongs in is the one thing about it that is yours, and there is nowhere in Claude
Code, OpenCode or Codex to say so. Fourteen are guessed from the description, and a skill the rules cannot
place lands in **Unsorted** rather than being pushed into whichever one was the residual.

![Moving a skill to another category](docs/move.png)

`^M` moves a row, and an expanded row shows its category as a control — so the correction sits next to the
thing being corrected. A classifier reading descriptions has no idea what you actually use a skill for and
will get some of them wrong. Type a name nothing answers to and it becomes a new one.

Low confidence means the evidence was thin, not that the answer was wrong, so a thin guess keeps its
category instead of being swept into Unsorted.

![The category index](docs/categories.png)

**Edit**, opposite the title, opens all of them at once with a standing **+ new category** at the end —
the way in when the one you want is not on screen, or does not exist yet. `^E` does the same from the
keyboard.

![Renaming and recolouring a category](docs/category-editor.png)

Pick one and you can rename it, recolour it, or clear the colour and fall back to the theme's. Trying a
colour on is not choosing one: swatches preview against the category's own name as you arrow through them,
and **Save** commits.

![Backing out of an unsaved category](docs/unsaved.png)

Backing out with something unsaved asks first, on the same surface, rather than dropping work you had no
way of knowing was still a draft.

This is the only configuration the widget writes, and it writes it to one file of its own:

```
~/.config/agent-skills/categories.json
```

It names directories and categories, nothing else. Delete it and every classifier guess comes back; you
lose only your own filing. No file belonging to Claude Code, OpenCode or Codex is written to make a
category or to move a skill between them.

---

## Removing a skill

`^Del` asks whether to get rid of the skill under the cursor. It is the one key here that changes
something outside this widget's own file, so it asks first and the question names what will actually
happen rather than the name of the row.

Which is not one question, because a skill is not one thing on disk. Four answers, and the helper decides
which before the panel draws anything:

**It is yours, so it goes to the trash.** Every path that reaches it, listed by name — links first, then
the directory itself — with which agents stop seeing it and which, if any, still will. Nothing is
deleted: each path is handed to `gio trash`, so it lands in the same desktop trash as everything else and
comes back the same way.

**A package owns it, so only your links can go.** `omarchy` and `diagnose-crash` live in
`/usr/share/omarchy`, owned by pacman and reached from your directories by symlink. The directory itself
is not yours to remove and is never offered; the links are, and the panel says that Omarchy re-creates
them when it next provisions your user, so removing them may not be final.

**A plugin brought it, so the plugin is where it goes.** A skill that arrives inside a Claude Code plugin
is not a thing you can remove on its own without breaking the plugin around it. The row says so and shows
the command that would do it properly.

**Nothing would happen, so nothing is offered.** Codex rewrites the six skills under its `.system`
directory from an embedded copy every time it launches. Removing one is undone before you next look at it,
and a panel that offered the button anyway would be lying about what it can do.

The row is advisory and the helper knows it. Every path is re-examined at the moment it is acted on — if
the skill moved, changed hands or stopped being a skill between the panel drawing the row and you
answering the question, that path is refused with a reason and the rest carry on. If a link cannot be
moved, the directory it points at is left where it is too, because a trashed skill with a live link still
pointing at it is worse than either.

---

## Finding things

![Typing narrows the list](docs/search.png)

Every printable key goes to the search, including the first, so a skill starting with `c` or `g` is
reachable by typing it; commands take Ctrl. The search reads names, descriptions, categories and tags.
Every box along the top is a filter, and so is every category chip below them — clicking the one already on
turns it off, `all` clears them, and Escape does the same.

The counts stay honest as you narrow. Each dimension is counted with every filter except its own, so
picking `servers` leaves the skills box reading its real total rather than 0, and a box that would filter
to nothing is not drawn at all.

### Grouping

![Grouped by agent](docs/grouped.png)

By category answers the question you open the panel with — where is the thing that does X. By agent is
right when you are about to switch agents and want to know what that one alone can see. By kind separates
skills from plugins from MCP servers. None gives one flat alphabetical list, which is the fastest thing to
type-search through.

Four boxes at the right of the agent row take one click to any of them, and `^G` cycles the same four.
Fewer than four once you have filtered, because a grouping you have already filtered by is not a grouping:
pick one agent, and grouping by agent is a heading over a list that is entirely that agent. Each box steps
aside for as long as its filter is on and comes back when you clear it.

---

## MCP servers and plugins

![An MCP server](docs/mcp.png)

MCP servers are listed beside skills because they load the same way and cost the same kind of money. Local
ones are read from the config files that declare them. Claude Code's account connectors are not on disk at
all; when they cannot be reached, the names Claude Code has recorded are shown with the source that
supplied them, and the row says so rather than inventing a state.

Servers are read-only in this version, and every row says so where you would otherwise expect a switch. The
panel does not draw a control it cannot honour.

## The token figure

Every skill an agent can see puts its name and description into the system prompt on every turn, whether or
not you ever use it. That is the number in each row, and the per-agent total in the boxes at the top.

It is computed the way Claude Code's own extensions browser computes it: the length of the name,
description and when-to-use joined, divided by four, rounded half up. On this machine that reproduces
fourteen of the fifteen figures the browser shows, to the token. The setting offers a divisor of three
instead, closer to how newer models tokenise dense technical prose and therefore closer to what you are
really paying; the default matches the browser so the two agree.

---

## Keys

Every printable key goes to the search. Commands take Ctrl.

| Key | What it does |
|---|---|
| type | search everything: names, descriptions, categories, tags |
| `Enter` | open the row, or fold and unfold a group header |
| `^C` | copy the invocation, or pick an action first if the skill documents any |
| `^M` | move the row to another category, or restyle the category under a group header |
| `^E` | open the categories: rename one, recolour it, or add one |
| `^O` | open where the skill is installed, in your file manager |
| `^Del` | ask whether to move the skill under the cursor to the trash |
| `^G` | regroup by category, agent, kind or nothing |
| `^R` | read everything again |
| `!` | show only what needs attention |
| `Esc` | back out one step: the open row, then the filters, then the search, then close |

## Settings

Five, in the widget's own settings panel. Each says why its default is its default rather than restating
its label.

| Setting | Default | What it decides |
|---|---|---|
| Next to the bar icon | Nothing | whether the bar carries the always-on token figure for whichever agent is running, the number of skills, the count of what is flagged, or nothing |
| Group the list by | Category | the grouping the panel opens on |
| Show built-in skills | off | whether the skills each agent ships with are counted; you did not install them and cannot turn them off, so by default only your own things are |
| Estimate token cost as | chars/4 | the divisor, or hiding the figure entirely |
| Rescan every time the panel opens | on | turn it off only if you keep skills on a network mount, where a stat of every file is no longer free |

## Requirements

Omarchy 4 with its Quickshell bar, and `python3` at `/usr/bin/python3`. Nothing else, and no Python package
beyond the standard library — the frontmatter reader is hand-written rather than reaching for PyYAML, which
is not in the Omarchy base set and which rejects real skill files all three agents read without complaint.

The interpreter is named rather than looked up — the panel spawns `/usr/bin/python3` outright instead of
letting the helper's shebang search a `PATH`. Stock Omarchy puts it there; if yours is elsewhere, the panel
opens empty while the helper still works in a terminal.

Whichever of the three agents you actually use is the one you get rows for. An agent that is not installed
is one quiet line saying so, not an error.

The widget never writes an agent's configuration file — nothing here turns a skill on or off, and every row
says so where you would expect a switch. What it can change in an agent's tree is one thing: a skill
directory you have confirmed by name, and it changes it by moving it to the trash.

Removal needs `/usr/bin/gio`, from `glib2`, which a stock Omarchy install already has because most of the
desktop depends on it. Without it the panel still reads everything and only the removal is refused.

## The command line behind it

The panel draws; `bin/agent-skills` does every byte of the reading and both of the writes — the category
store, and the removal. It is worth running on its own.

```
bin/agent-skills doctor
```

```
agent-skills 0.1.0   scan 22.6 ms
skills            41
  claude          16   ~1406 tok always on
  codex            8   ~808 tok always on
  opencode        34   ~4460 tok always on
mcp servers       7
claude plugins    1
running now       claude, opencode
categories        automation 16, agents 5, code 4, design 3, security 3, content 2, infra 2, media 2, system 2, data 1, web 1
```

`bin/agent-skills scan` prints the same inventory as one line of JSON, which is what the panel reads.
`bin/agent-skills category` is one of the two write sides, and every verb is a single named change to the
one file above:

```
bin/agent-skills category list
bin/agent-skills category create ui --label UI --color '#7AA2F7'
bin/agent-skills category assign nextjs ui
bin/agent-skills category unassign nextjs
bin/agent-skills category style ui --reset
```

`bin/agent-skills remove` is the other, and it is the only thing here that touches a file this plugin did
not write. Paths must be absolute, and they are meant to come from a scan's `removal.targets` rather than
be typed:

```
bin/agent-skills remove --dry-run -- /home/you/.claude/skills/nextjs
bin/agent-skills remove -- /home/you/.claude/skills/nextjs
```

`--dry-run` runs every check and prints what would go without touching anything, which is the form worth
reaching for first. Neither form deletes: each path is handed to `gio trash` on its own, and the answer
says which ones moved and, for each one that did not, why. Every path is re-examined at the moment it is
acted on rather than trusted from the row that asked — if the skill moved, changed owner or stopped being
a skill since the panel drew it, that path is refused and the others carry on.

Every file read under a scanned root is opened once with `O_NOFOLLOW` and `O_NONBLOCK`, judged on that
descriptor rather than on its name, and read back only to the size that descriptor vouched for.
`omarchy-shell` is one process for the whole desktop, so nothing read on its behalf may block inside
`open(2)` or turn out to be larger than it said it was. A file that is refused — a symlink, a device,
something world-writable, something over the read cap — is reported as refused rather than treated as
absent, because an empty list and a list that could not be read look identical and mean opposite things.

The one read outside that path is `/proc/<pid>/comm`, which is how the bar finds which agent is running. It
is a kernel file, never larger than a line, and cannot be a symlink elsewhere, so it is opened plainly and
every error is swallowed per process.

## Development

Tests are plain `unittest` and need nothing that is not already here.

```
python3 -m unittest discover -s tests -v
```

`tests/preflight.sh` checks this repository against the Omarchy plugin marketplace's published rules — the
structural validator, the automated security baseline, and the recurring demands of its manual review — and
exits non-zero on any violation. CI runs it on every push and pull request, so run it before proposing a
change and meet it locally rather than on the branch.

## License

MIT. See [LICENSE](LICENSE).
