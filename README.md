# Agent Extensions

An Omarchy bar widget for the skills, plugins and MCP servers behind your coding agents.

Three agents, three sets of config files, three ideas of where a skill lives. Claude Code keeps skills in
`~/.claude/skills`, plugins in a marketplace cache, and its connectors nowhere on disk at all. OpenCode
keeps skills in `~/.config/opencode/skills`, plugins as npm specifiers in `opencode.json`, and lets a
plugin inject MCP servers at runtime that never appear in any list. Codex keeps its own again. Some of it
is the same skill, symlinked into two places, and no view anywhere shows you that.

This widget is that view. One searchable list of everything all three agents can load, grouped by what the
thing is for, with what each one costs you in tokens on every single turn, which agent can see it, and the
command that invokes it — on your clipboard, in the spelling that particular agent expects.

## What it shows you

Three of these are true on the machine this was written on, and no other tool reports any of them.

**The same skill loaded twice, differing.** `omarchy` exists as a real directory under `~/.claude/skills`
and as a symlink to `/usr/share/omarchy` under `~/.codex/skills`. The two files are not the same. Claude
Code and OpenCode read one, Codex reads the other, and nothing says so. Deduplicating on path alone calls
them unrelated; on name alone, identical. Both are wrong, so the list deduplicates on the resolved path and
then compares content hashes, and marks the pair as drifted.

**One skill, three agents, five mount points.** `diagnose-crash` is a single `SKILL.md` reachable from
`~/.claude/skills`, `~/.codex/skills` and `~/.agents/skills`. It is one row carrying three agent marks, not
five rows repeating themselves.

**Frontmatter that is not valid YAML.** One skill here writes `Triggers on:` inside an unquoted scalar. A
strict parser drops the entire frontmatter rather than the one field and reports a 162-token skill as
costing 4. The reader is deliberately lenient, and the row is flagged so you know the file is one strict
parser away from vanishing.

## Copying the command, with its arguments

A skill that takes arguments says so in its frontmatter, in `argument-hint`. `impeccable` documents
twenty-two of them in the version installed here. Copying that row and getting `/impeccable` on its own is not what anybody wanted, so
the row says **23 actions** and `^C` opens them as a grid instead of copying. The assembled command is
drawn above the options at reading size and updates as you move, so what lands on your clipboard is on
screen before you press Enter rather than something you assemble in your head.

Rows without documented arguments copy straight through, unchanged.

A skill that arrives inside a Claude Code plugin is addressed through it, so that row copies
`/impeccable:impeccable typeset` rather than `/impeccable typeset`. Those skills used to be missing
entirely: the four directories a user drops a skill into were scanned, the plugin was listed as a single
row, and nothing ever opened it. Which version is read is not guessed either — the cache can hold several
and `installed_plugins.json` records the one Claude Code actually loaded.

Nothing is claimed until it happens. The panel attempts the clipboard write, reads the clipboard back, and
says **Copied** only when the read back agrees. When the write went to a helper whose exit code has not
arrived yet it says *sent to the clipboard*, and when neither path was reachable it says so in red and
prints the command so you can select it by hand.

## Shelves

Which shelf you keep a skill on is the one thing about it that is yours, and there is nowhere in Claude
Code, OpenCode or Codex to say so. Fourteen categories are guessed from the description; `^M` moves a row
to a different one, and the coloured dot on any group header opens that shelf for renaming or recolouring.

A skill the rules cannot place lands on **Unsorted** rather than being pushed
into whichever shelf was the residual, and expanding any row shows the shelf it
is on as a control: click it to move it. A classifier that reads descriptions
will get some of them wrong, because it has no idea what you use a skill for, so
the correction is one click from the thing being corrected.

A thin guess is still a guess kept. Low confidence means the evidence was thin,
not that the answer was wrong -- on the machine this was written for, four of the
five low-confidence placements were correct -- so they keep their shelf instead
of being swept into Unsorted, and the control above is how the fifth gets fixed.
Neither case is reported as a problem any more: the list flags drift, a name
mismatch and unreadable frontmatter, and nothing else.

**Edit**, opposite the title, opens all of them at once — every shelf with its colour and its size, a
standing **+ new shelf** at the end, and the same editor on any one you pick. Trying colours on is not
choosing one: the swatches preview, **Save** commits, and backing out with something unsaved asks before
it drops it.

This is the only thing the widget writes, and it writes it to one file of its own:

```
~/.config/agent-ext/categories.json
```

It names directories and categories, nothing else. Deleting it restores every guess the classifier made
and loses nothing but your shelving. No file belonging to Claude Code, OpenCode or Codex is written to
make a category, and none is written to move a skill between them.

## Filtering

Every box along the top is a filter. **33 skills**, **7 servers** and **1 plugin** narrow the list to that
kind; the three agent boxes narrow it to what that agent actually loads; **needs attention** shows only
what is flagged. The shelf chips below them filter by category, folded to one row with a **+3 more** that
opens the rest. Clicking the box that is already on turns it off, `all` clears every one of them, and one
Escape does the same from the keyboard.

The counts stay honest while you use them. Each dimension is counted with every filter except its own, so
picking `servers` leaves the skills box reading 33 rather than 0, and a box that would filter to nothing
is not drawn at all.

## The token figure

Every skill an agent can see puts its name and description into the system prompt on every turn, whether
or not you ever use it. That is the number in each row, and the per-agent total in the boxes at the top.

It is computed the way Claude Code's own extensions browser computes it — the length of the name,
description and when-to-use joined together, divided by four, rounded half up. On this machine that
reproduces fourteen of the fifteen figures the browser shows, to the token. The setting offers a divisor of
three instead, which is closer to how newer models actually tokenise dense technical prose and therefore
closer to what you are really paying; the default matches the browser so the two agree.

## Keys

Every printable key goes to the search, including the first one, so a skill whose name starts with `c` or
`g` is reachable by typing it. Commands take Ctrl.

| Key | What it does |
|---|---|
| type | search everything: names, descriptions, categories, tags |
| `Enter` | open the row, or fold and unfold a group header |
| `^C` | copy the invocation, or pick an action first if the skill documents any |
| `^M` | move the row to another shelf, or restyle the shelf under a group header |
| `^E` | open the shelves: rename one, recolour it, or add one |
| `^O` | open where the skill is installed, in your file manager |
| `^G` | regroup by category, agent, kind or nothing |
| `^R` | read everything again |
| `!` | show only what needs attention |
| `Esc` | back out one step: the open row, then the filters, then the search, then close |

## Requirements

Omarchy 4 with its Quickshell bar, and `python3`, which a stock Omarchy install already has — ten packages
in the base set depend on it. Nothing else.

Whichever of the three agents you actually use is the one you get rows for. An agent that is not installed
is one quiet line saying so, not an error.

The widget reads your agent configuration and never writes to it. The one file it does write is its own,
`~/.config/agent-ext/categories.json`, and only when you shelve something.

## Install

```
omarchy plugin add https://github.com/oliwier-xiao/agent-extensions-manager.git --enable
```

`--enable` puts it straight on the bar and asks which side you want it on. Leave the flag off and it
installs disabled, so you can read the code first and turn it on later with `omarchy plugin enable
oliwier.agent-extensions-manager`. Either way nothing runs until you open the panel for the first time.

## Removal

```
omarchy plugin remove oliwier.agent-extensions-manager
```

That takes the widget off the bar and deletes the plugin. If you shelved anything, one file of yours
outlives it and is safe to delete by hand:

```
~/.config/agent-ext/categories.json
```

Beyond those two paths the footprint is nothing: no cache, no state under `~/.local`, and no file
belonging to Claude Code, OpenCode or Codex modified at any point.

## The command line behind it

The panel draws; `bin/agent-ext` does every byte of the reading and every byte of the one write. It is
worth running on its own.

```
bin/agent-ext doctor
```

```
agent-ext 0.1.0   scan 20.1 ms
skills            39
  claude          15   ~1179 tok always on
  codex            9   ~1035 tok always on
  opencode        33   ~4296 tok always on
mcp servers       7
claude plugins    1
categories        automation 16, agents 5, code 4, system 3, content 2, design 2, ...
```

`bin/agent-ext scan` prints the same inventory as one line of JSON, which is what the panel reads.
`bin/agent-ext category` is the write side, and every one of its verbs is a single named change to the one
file above:

```
bin/agent-ext category list
bin/agent-ext category create ui --label UI --color '#7AA2F7'
bin/agent-ext category assign nextjs ui
bin/agent-ext category unassign nextjs
bin/agent-ext category style ui --reset
```

## Development

Tests are plain `unittest` and need nothing that is not already here.

```
python3 -m unittest discover -s tests -v
```

`tests/preflight.sh` checks this repository against the Omarchy plugin marketplace's published rules — the
structural validator, the automated security baseline, and the recurring demands of its manual review —
and exits non-zero on any violation. Run it before proposing a change.

The design and the reasoning behind it are in [docs/DESIGN.md](docs/DESIGN.md); the decisions that shaped
it, and what was deliberately left out, are in [docs/DECISIONS.md](docs/DECISIONS.md).

## License

MIT. See [LICENSE](LICENSE).
