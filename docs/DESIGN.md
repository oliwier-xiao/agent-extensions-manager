# Agent Skills Manager — design brief

> Status: design settled, implementation not started. This document is the output of a 37-agent research
> pass over the Omarchy plugin API, the two reference plugin managers, this author's own two plugins, the
> marketplace review record, and the complete Claude Code / OpenCode / Codex configuration surfaces.
> Every claim marked *verified* was reproduced against a real file or a live session on the author's
> machine; claims that could not be reproduced say so.

> **Attribution.** Every fact below is drawn from the reconnaissance dump. Where a verifier corrected a researcher, the correction is what is written here. Numbers taken from a live machine (install counts, star counts, commit distances) are marked as measurements, not constants.

---

# 1. What this is

**Agent Skills Manager** is a bar widget and a keyboard-driven panel for the Omarchy shell that puts one list in front of you: every skill, plugin and MCP server that Claude Code, OpenCode and Codex will load, drawn from all six of their skill roots and all of their config files at once. It tells you what is on and what is off per tool, what each item costs in tokens on every single turn before you have typed anything, which category it falls into, where it came from, and whether an update is waiting. From that list you can turn a skill off in any of the three tools, copy the correct invocation string for the tool you are actually using, drop a skill into a project, pull upstream changes for the things that have an upstream, and write a new skill from scratch that all three tools will read without complaint. It exists because the three CLIs deliberately overlap — OpenCode reads Claude's `~/.claude/skills` and the shared `~/.agents/skills`, Codex reads `~/.agents/skills` natively, and the same folder on disk therefore charges you context in two or three system prompts at once — and nothing in any of the three shows you that.

---

# 2. Identity

| Field | Value |
|---|---|
| `id` | `oliwier.agent-skills-manager` |
| `name` / `barWidget.displayName` | Agent Skills Manager |
| `barWidget.category` | `AI` |
| `barWidget.defaultSection` | `right` |
| `barWidget.allowMultiple` | `false` |
| `kinds` | `["bar-widget"]` |
| `entryPoints` | `{ "barWidget": "BarWidget.qml" }` |
| Marketplace category | `Developer Tools` |
| Marketplace tags | `ai`, `quickshell`, `bar` |
| Tagline | Every skill, plugin and MCP server your three agents load, in one list — with what each one costs you before you have typed a word. |

**Why this id.** `oliwier.*` is what the two already-listed plugins use and both are verified, so it carries reputational credit. It is lowercase, which community submissions require and which `omarchy plugin validate`'s looser regex does not catch. It is not in the reserved `omarchy.*` namespace. And `oliwier.agent-skills-manager` is free: the installed set on this machine is `agx.screen-time`, `io.github.juancasanueva.plugin-manager`, `io.github.vuhuy.clipboard-manager`, `jankeesvw.notification-center`, `oliwier.network-usage`, `oliwier.opencode-configs`, `omaplug`, `quickshell.spotify`, `saif.workspaces`, `sid.sessions`, `sofos.workspaces`.

**Why "Agent Skills Manager".** Measured against the marketplace catalog, not guessed: of 2599 listings, "skills" appears in one search haystack and in zero names, "mcp" in two names, while "agent" is in 28 -- including the first-party `omarchy.agents`, displayed as "Agents". Adding "AI" to the name buys nothing, because the site's matcher only matches a two-character token at a word boundary and the `ai` tag already supplies that word. Full reasoning, including how the search actually works, in `DECISIONS.md` D1. Plugin ids are permanent at the marketplace and 22 retired ids are blocked from reuse, so this is decided once.

---

# 3. The skill taxonomy

## 3.1 Why two levels, and not one

The official Anthropic catalog on disk proves its own vocabulary is unusable for navigation. Of 291 plugins, `development` holds 120 (41.2%) and 54.7% of installs, and inside that single bucket sit 13 LSP servers, 8 AWS plugins, 3 SAP plugins, 3 Oracle AIDP plugins, 8 payment processors and `frontend-design` at 1.23M installs — six unrelated jobs wearing one label. At the other end `migration` and `math` hold exactly one item each. 14 of 291 entries have no category at all, including `remember` at 58K installs. Only 3 entries carry `tags` (all just `["community-managed"]`) and exactly one carries `keywords`. There is no upstream tag vocabulary to inherit and no upstream category worth passing through unmodified.

Locally it is worse: across 63 `SKILL.md` files on this machine, `category` appears **zero** times and `tags` appears **once**. The Agent Skills spec permits exactly six frontmatter fields — `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools` — and none of them is a category. So the taxonomy is ours to derive, and the only spec-legal place to record it is `metadata`, a string→string map.

The user's own examples decide the shape. *UI, Video, SEO, Next.js, media, animations* is not one list — it is a category (`media`) and five things that cut across categories. `UI` belongs to `impeccable` (design), `emil-design-eng` (design), `taste-skill` (web) and `omarchy` (system) simultaneously. `Next.js` is a framework, not a domain. skills.sh makes the same mistake in public, mixing "Next.js" and "Design & UI" in one flat chip row. **One category per item, many tags per item.** Categories are for the grouped list; tags are for search and for filter chips.

## 3.2 The fourteen categories

Each is defended by a count, not a hunch. `n` is items in the 291-plugin official catalog under the classifier below; `u` is items among the 36 skills installed on this machine.

| # | Category | Glyph | Covers | Official parent | n | u |
|---|---|---|---|---|---|---|
| 1 | `agents` | ◇ | Skills, plugins, MCP, prompts, context, memory, evals, LLM app dev | learning (part) | 67 | 0 |
| 2 | `code` | ⌘ | Writing, reviewing, testing, debugging, refactoring, perf, LSP | testing | 24 | 2 |
| 3 | `workflow` | ⎇ | Git, PRs, issues, planning, specs, docs, release | — | 11 | 1 |
| 4 | `web` | ◫ | React, Next.js, Vue, mobile, browser, CMS app development | — | 5 | 2 |
| 5 | `design` | ✧ | UI/UX, design systems, brand, Figma, accessibility | design | 8 | 1 |
| 6 | `media` | ▶ | Video, audio, image, 3D, animation | — | 4 | 2 |
| 7 | `data` | ▤ | Databases, vector stores, warehouses, ETL, analytics | database | 47 | 1 |
| 8 | `infra` | ☁ | Deploy, cloud, containers, IaC, CI/CD | deployment, migration | 27 | 2 |
| 9 | `ops` | ◉ | Monitoring, logs, traces, incidents | monitoring | 23 | 0 |
| 10 | `security` | ⛨ | Vulnerabilities, auth, compliance | security | 25 | 1 |
| 11 | `automation` | ⟳ | n8n, Zapier, browser automation, scraping, cron, webhooks | automation | 11 | 16 |
| 12 | `content` | ✎ | Writing, SEO, marketing, comms, knowledge, research, science | learning, math | 8 | 2 |
| 13 | `business` | ₿ | Payments, finance, legal, CRM, ERP, commerce | — | 21 | 0 |
| 14 | `system` | ⚙ | OS/desktop/WM, CLI, hardware, game engines, embedded, maps | location | 10 | 6 |

Nothing is a singleton and nothing lands in a junk drawer. `media` is the weakest at n=4 in the official catalog and is carried anyway, because the community ecosystem is where video lives: skills.sh alone lists roughly thirty media skills (`hyperframes` and its six siblings, `ai-video-generation`, `video-edit`, `video-inpainting`, `motion-graphics`, `talking-head-recut`, `music-to-video`, `remotion-best-practices`, `face-swap`, `ai-music`), several at half a million installs. A taxonomy built only from Anthropic's catalog would tell the user that video does not exist.

`agents` is deliberately last in the rule order and deliberately weight-2, and it still absorbs 23% of the official catalog, because in this ecosystem almost every description mentions skills or prompts or models. It is the residual bucket, not a real domain, and any rule added above it must be tested for what it steals from `agents` rather than only for what it captures.

## 3.3 Tags

Tags are free-form, lowercase, hyphenated, and multi-valued. They are derived by the same keyword pass that produces the category, plus a fixed vocabulary of framework and vendor names. The classifier already reproduces the user's own examples correctly on their own machine: `nextjs` gets `{nextjs, react, seo, video, media, docker}` — every one of those words is genuinely in its description; `impeccable` gets `{ui, animation, llm, a11y}`; `threejs` gets `{animation, media, 3d}`; `omarchy` gets `{ui, animation, linux}`. A tag never appears as a group header. Tags drive the filter chip row and the search index, and they are the layer where `UI`, `SEO`, `Next.js` and `animations` live.

## 3.4 The classifier

A deterministic cascade. Stop at the first hit. Record which tier fired, because the UI shows confidence and confidence is what tells the user which rows are worth correcting.

| Tier | Signal | Confidence |
|---|---|---|
| 0 | User override in `overrides.json` | `pinned` — never recomputed |
| 1 | `metadata["agent-ext.category"]` in a `SKILL.md` we authored (identified by `metadata["agent-ext.origin"]`) | `authored` |
| 2 | `marketplace_entry.category` from `plugin-catalog-cache.json`, mapped through the official→proposed table | `high` (covers 277/291) |
| 3 | Pack membership — `openai/skills` `.curated`, `obra/superpowers`, `mattpocock/skills`, `vercel-labs/agent-skills` — pack category applied to all members | `medium` |
| 4 | Path heuristics — `.../skills/n8n-*` → automation, `~/.codex/skills/.system` → bundled badge, vendor-named parent dir | `medium` |
| 5 | Weighted keyword match over `name + " " + description` | `high` / `medium` / `low` (see below) |
| 6 | Nothing matched | `agents`, badged `unclassified` |

Tier 5 uses an ordered rule table: the specific categories (`system`, `media`, `design`, `security`, `ops`, `automation`, `data`, `infra`, `business`) at weight 4; `content`, `web`, `code`, `workflow` at weight 3; `agents` at weight 2 last. Negative rules are load-bearing — `api design`, `schema design`, `database design` and `system design` must **not** score `design`, or `api-design` classifies wrong (it does today, without them). Confidence is `high` when the top score is ≥ 10 **and** beats the runner-up by ≥ 4; `medium` at ≥ 6; `low` otherwise.

Measured on the real data: 138 high / 87 medium / 52 low / 14 unmatched over the 291 official plugins, and 28 high / 7 medium / 1 low over the user's 36 local skills, with nothing in `other`. The local distribution comes out as automation 16, system 6, infra 2, media 2, content 2, web 2, code 2, workflow 1, data 1, security 1, design 1.

Three of the user's own skills classify wrongly, and they are exactly the ones a manual override exists for: `api-design` → `workflow` (it matched the literal word "design" before the negative rules land), `emil-design-eng` → `media` at low confidence, `taste-skill` → `web` at medium. **Ship the override affordance in v0.1.0, not later.** Without it the first thing the user sees is their own skills in the wrong bins, and the feature reads as broken rather than as a first draft.

Every `low` and `unclassified` row is visually marked and sorts to the top of its group, so correcting the classifier is one keystroke from the place you noticed it was wrong.

## 3.5 Where overrides live

`~/.local/state/omarchy/agent-extensions/overrides.json`, mode 0600, following the shape of the user's own `opencode-configs/profiles.json`:

```json
{
  "version": 1,
  "state": { "lastClassifiedAt": "…", "classifierVersion": 3 },
  "favorites": ["claude:taste-skill", "agents:impeccable"],
  "recents": [],
  "items": {
    "claude:api-design": { "category": "code", "tags": ["api", "rest"], "pinnedAt": "…", "note": "" },
    "opencode:n8n-agents": { "tags": ["n8n", "llm", "rag"] }
  },
  "cache": {
    "claude:nextjs": {
      "category": "web", "tags": ["nextjs", "react", "seo"],
      "confidence": "high", "source": "keywords",
      "hash": "<sha256 of name+description>"
    }
  }
}
```

Keys are `<tool>:<identity>`, where identity is the **directory name** for Claude Code and the **frontmatter name** for Codex and OpenCode — because the three tools genuinely disagree, and a single `skillId` field would silently corrupt state the first time it met `~/.claude/skills/taste-skill/` with `name: design-taste-frontend`. The `cache` block is keyed by a hash of `name + description` so a reclassification only runs when the text actually changed; `items` always wins over `cache`.

**We never write a category into someone else's `SKILL.md`.** Only into skills this plugin authored, and only under `metadata`, and only with namespaced keys. State is state; other people's files are theirs.

---

# 4. Create a skill

## 4.1 Why this is first-class

The panel already knows the naming rules of three tools, the frontmatter each accepts, the directory layout each expects and the collisions each resolves silently. That knowledge is worth more when it is applied before a file exists than after. And the create flow is the only write in the product that is inherently safe — it creates new directories with `O_EXCL` and touches nobody's existing config — so it can ship in v0.1.0 alongside the read-only inventory without inheriting any of the write-safety risk that defers project setup and updates.

## 4.2 The portable file

One `SKILL.md` that satisfies all three tools at once. This is what the panel writes by default:

```markdown
---
name: my-skill
description: What this does and when to use it. Front-load the words the user
  would actually type. No angle brackets. Under 1024 characters.
license: MIT
metadata:
  agent-ext.category: design
  agent-ext.tags: ui,animation,nextjs
  agent-ext.origin: oliwier.agent-skills-manager
  agent-ext.created: "2026-09-05"
---

# My Skill

## When to use
…

## Steps
1. …
```

Every key is inside Codex's `quick_validate.py` allow-list `{name, description, license, allowed-tools, metadata}`, inside the Agent Skills spec's six fields, and tolerated by Claude Code. All `metadata` values are strings, because OpenCode's `metadata` is a string→string map and a YAML list will not round-trip. Directory name equals frontmatter name, so Claude's directory-keyed identity and Codex's and OpenCode's frontmatter-keyed identity agree.

## 4.3 The gate

Validate against the **intersection** of the three, which is Codex's rules, because Codex is strictest and a skill that passes Codex passes everywhere:

- `name` matches `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`, ≤ 64 chars, no leading or trailing hyphen, no `--`
- `description` is a non-empty string, ≤ 1024 chars, contains no `<` or `>`, does not start with `[TODO:`
- no top-level key outside `{name, description, license, allowed-tools, metadata}`
- no bare `[TODO: …]` line in the body outside a code fence
- `SKILL.md` is larger than its own frontmatter

**Do not use `claude plugin validate --strict` as the gate.** It was measured passing an 81-character name, an uppercase-and-underscore name, a directory/frontmatter mismatch, a 1500-character description, unknown keys `category`/`tags`/`foo`, a missing `name`, `model: gpt-9` and `allowed-tools: NotARealTool, Bash(rm:*)` without a single warning. It warns only on a missing description and on a file with no frontmatter at all. Offer it as a secondary lint after the real gate, never instead of it.

## 4.4 Delegate where a scaffolder exists

| Tool | Approach | Why |
|---|---|---|
| Claude Code | Delegate: `claude plugin init <name> --description "…" [--author …]`, then patch the description and `metadata`, then delete the TODO body | It writes `.claude-plugin/plugin.json` with the git-config author identity and registers the `<name>@skills-dir` auto-load contract, both of which are fiddly to reproduce and may change between releases |
| Codex | Delegate: `python3 $CODEX_HOME/skills/.system/skill-creator/scripts/init_skill.py <name> --path <dir>`, then patch the `[TODO:]` description, then **gate** with `quick_validate.py` and show its message verbatim on failure | It also emits `agents/openai.yaml`, and `quick_validate.py` is what the ecosystem lints with |
| OpenCode | Write it ourselves | There is no OpenCode scaffolder, the format is three lines of frontmatter, and the only extra rule (`name` equals the folder name) is trivial |

Reuse Codex's name normaliser verbatim in the panel's name field — `lower()` → `re.sub(r'[^a-z0-9]+','-')` → `strip('-')` → collapse `--` → cap at 64 — so the slug the panel previews is byte-identical to the slug Codex would have produced.

## 4.5 The form

Seven fields and one button. The body belongs in a real editor; the panel's job is the metadata and the wiring.

1. **Name** — live-slugified with the Codex normaliser, slug shown beneath, 64-char counter, live collision check across all three tools and both scopes.
2. **Description** — multiline, 1024-char counter that turns `Color.urgent` past the cap, hard block on `<` and `>` with the reason stated ("Codex rejects angle brackets").
3. **Category** — the 14-item picker, pre-selected by running the classifier live over whatever name and description have been typed so far.
4. **Tags** — comma-separated free text, pre-filled with the classifier's suggestions, each removable.
5. **Target tools** — three checkboxes, all on by default, each showing the exact path it will write.
6. **Scope** — user or project; project resolves through a directory picker seeded from `~/.claude.json`'s `projects` map ranked by `lastStartTime`.
7. **Template** — five entries, no more.

Then one button: **Create & open in editor**, which writes the files, runs the gate, and launches `$EDITOR` (`omarchy-launch-editor --inline` here) on the canonical `SKILL.md` positioned after the frontmatter. Do not build a markdown editor in QML.

## 4.6 Templates

Five, each a real body rather than a stub:

- **blank** — frontmatter, `# Name`, `## When to use`, `## Steps`
- **procedure** — trigger and non-goals, inputs to gather, numbered steps with commands, a pitfalls table (symptom → cause → fix), a verification checklist. This is the shape Codex's own memory system prescribes and the shape most high-install skills take.
- **reference** — a short router `SKILL.md` plus `references/` with one file per mode, matching the spec's progressive-disclosure guidance (metadata ≈ 100 tokens, instructions < 5000, resources on demand)
- **tool-wrapper** — `allowed-tools` set, a `scripts/` directory, `argument-hint` filled in, explicit safety rules for destructive flags
- **project-conventions** — project-scoped, pre-fills from the project's actual layout

Every template ships with the `agent-ext.*` metadata block already present, so a created skill classifies itself at confidence `authored`.

## 4.7 Cross-tool fan-out

Canonical location: `~/.agents/skills/<name>/`. It is already the user's shared directory and **Codex reads it natively** as skill root `r1` — no symlink, no config. Then per tool:

- **Codex** — nothing to do.
- **Claude Code** — symlink `~/.claude/skills/<name>` → `~/.agents/skills/<name>`. Claude sessions follow symlinks (the binary says so explicitly); `claude plugin validate` does not, so warn that validation must run against the real directory.
- **OpenCode** — OpenCode does read `~/.agents/skills` (measured: a bare `GET /api/skill` returned 35 skills including all three `~/.agents` entries and 14 from `~/.claude/skills`), gated only by `OPENCODE_DISABLE_EXTERNAL_SKILLS` / `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`. So also nothing to do — but verify at scan time by reading the resolved skill list rather than assuming, and offer "add `~/.agents/skills` to `skills.paths`" as the one-line repair if it is missing.

The precedent for per-tool divergence is `impeccable`, which fans out by **copy** into fifteen harness directories with per-tool frontmatter projections and a `skills-lock.json` recording the source hash. If the user ever needs different frontmatter per tool, that is the architecture: one canonical body, generated projections, a lock file so drift is detectable. Symlinks first; copies only when the frontmatter has to differ.

---

# 5. Architecture

## 5.1 The split

```
QML  — reads and draws. Owns no I/O beyond spawning the helper.
JS   — lib/*.js, .pragma library, pure functions, node-testable, zero QML imports.
bin/ — one python3 helper. The only thing that writes anything, anywhere.
```

This is the user's own established split (`opencode-config_manager`: QML only reads and draws, `bin/oc-profiles` is the only thing that writes) and it is what makes every action runnable by hand and testable without Qt.

**QML surfaces**

- `BarWidget.qml` — bar slot, IPC handler, the `open()`/`close()`/`opened`/`popoutSwitchClosing`/`closeForPopoutSwitch()` shape contract, and a `Loader` that mounts `Panel.qml` lazily on first open.
- `Panel.qml` — all state, all `Process` instances, all `FileView` watches, all dispatch. Zero business logic.
- One `.qml` per screen (`ListView.qml`, `DetailView.qml`, `CreateSheet.qml`, `ArgumentSheet.qml`, `ProjectSheet.qml`) and one per reusable row/control (`ItemRow.qml`, `GroupHeader.qml`, `ChoiceSheet.qml`).

**Why `kinds: ["bar-widget"]` only.** Declaring `panel` as a second kind silently reroutes `omarchy-shell shell toggle <id>` away from the bar popup to the shell's panel loader, breaking any keybinding the user has already bound. Declaring `service` mounts a singleton at shell startup, which violates the zero-startup-cost rule, and a `keepLoaded: true` service is deliberately **not** recreated by hot reload — every edit to it would need `omarchy-restart-shell`, which destroys the dev loop. `Panel.qml` is loaded by the widget's own `Loader` and hand-injected with `bar`, `settings`, `anchorItem`, `hostWidget`, exactly as `oliwier.network-usage` does. `activation: "on-demand"` goes in the manifest for documentation value even though the shell never reads it.

**The helper.** `bin/agent-ext`, python3, one line of JSON on stdout, diagnostics on stderr, exit codes `0` done / `1` usage / `2` refused with nothing written / `3` partial write that was restored. Subcommands:

```
scan            full inventory, all three tools, all roots
summary         the tiny bar-label projection, from cache if fresh
classify        reclassify one item or all
toggle          enable/disable, --tool --kind --id --state
create          write a new skill, --portable
install-project copy or symlink into a project        (v0.2)
update-check    origin resolution + ahead/behind      (v0.3)
update-apply    fetch, ff-merge, validate, rollback   (v0.3)
origin-set      record a manual upstream link
doctor          TSV health report
```

Companion scripts, all vendored from the user's own reviewed code with attribution: `bin/safe-read` (`O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW`, `fstat` on the descriptor not the name, regular-file + own-uid + size-cap checks), `bin/safe-write` (`O_EXCL|O_NOFOLLOW` 0600 temp in the destination's own directory, write, fsync, chmod to the preserved mode, rename, fsync the directory), `bin/jsonc-edit` (the 370-line span-splice scanner), and `bin/agent-ext-git` (bash, modelled line for line on `omaplug/plugin-state.sh`).

**Why python3.** Measured: a python3 helper doing direct file reads scans 36 skill directories across four roots plus four JSON configs in ~4 ms of work and ~30 ms wall including interpreter start. The alternatives are not close — `claude plugin list --json` is 256–681 ms, `codex mcp list` is 14–63 ms, and `opencode mcp list` is **5–8.6 seconds** because it dials every MCP server over the network. python3 is transitively guaranteed on a stock Omarchy install by ten packages in `omarchy-base.packages` (`python-gobject`, `python-poetry-core`, `nautilus-python`, `kdenlive`, `libreoffice-fresh`, `obs-studio`, `system-config-printer`, `tldr`, `udiskie`, `yt-dlp`), it is the only tool present that can do `O_NOFOLLOW`/`O_EXCL`/`O_NONBLOCK` atomic I/O, comment-preserving span-splice editing and TOML reading (`tomllib`) in one process, and `jq` silently succeeds with empty output on a zero-byte file where python raises.

## 5.2 Performance budget

| Moment | Budget | What runs |
|---|---|---|
| Shell start | **0 ms** | The widget draws a glyph. Nothing else. No file read, no process, no timer that fires. |
| Shell start + 3 s | one 5 ms subprocess | `bin/agent-ext summary --json` under `timeout 5`, output capped, to fill the bar label. Deferred so it never lands on the shell's startup critical path. |
| Panel open | ~30 ms | Spawn `bin/agent-ext scan --json`, draw a skeleton, populate on `onExited`. |
| Panel open, expand a row | lazily, with a spinner | `claude plugin details <name>` (~300 ms) for the per-component token breakdown, if the row is a Claude plugin and the catalog cache has no entry. |
| Explicit "Check for updates" only | seconds | `git ls-remote` (~1.2 s each) at concurrency 4–6, each under `timeout 20`, `GIT_TERMINAL_PROMPT=0`, `GIT_SSH_COMMAND='ssh -oBatchMode=yes'`. |
| Never on any interactive path | — | `opencode mcp list`. Read `opencode.json` and the resolved config instead. |

`omarchy-shell` is one process for the entire desktop. A blocking read or a synchronous 6-second CLI call freezes the clock, the tray and every other widget. That is the whole justification for `O_NONBLOCK` reads, out-of-process parsing, and the ban on the OpenCode CLI.

## 5.3 Cache and state

```
~/.cache/omarchy/oliwier.agent-skills-manager/     0700, files 0600
  inventory.json         full scan result, with a `sources` array of {path, mtime_ns, size, inode}
  summary.json           < 1 KB, the bar-label projection
  catalog-projection.json  the 291-plugin catalog reduced to the ~12 fields we use
  origins-index.json     content-hash → candidate upstreams, TTL in hours

~/.local/state/omarchy/agent-extensions/        0700, files 0600
  overrides.json         categories, tags, favourites — user-entered, must survive
  origins.json           manual upstream links — user-entered, must survive
  backups/               timestamped pre-write copies, pruned to keepBackups
```

Cache follows the observed house pattern of the **full plugin id** (`~/.cache/omarchy/oliwier.opencode-configs/`); state follows the observed pattern of the **short name** (`~/.local/state/omarchy/opencode-configs/`). Both honour `XDG_CACHE_HOME` and `XDG_STATE_HOME`.

Invalidation is stat-based: the helper stats only the recorded source paths (sub-millisecond) and rebuilds only when a `(mtime_ns, size, inode)` tuple differs or `schemaVersion` changed. Nothing derived from the network is refreshed implicitly; those fields carry their own `checkedAt` and a TTL.

**Never write our backups into `~/.claude/backups/`.** Claude Code enumerates that directory and unlinks everything past the newest five — ours would be deleted, and worse, ours would evict Claude Code's own safety net.

Cache files contain only derived values — counts, timestamps, names, hashes. Never a verbatim copy of config content. `~/.claude.json` is mode 0600 and holds `oauthAccount`, `userID`, `machineID` and a `projects` map exposing the user's directory layout; MCP definitions carry bearer tokens by design.

## 5.4 Refresh

Three tiers.

1. **Panel open** — full rescan, unconditionally. 30 ms. No incremental diff engine, no staleness bugs.
2. **While the panel is open** — `FileView { watchChanges: true }` on the config files, plus **one** `Process` running `inotifywait -m -q -e create,delete,moved_to,moved_from,close_write` over the skill roots. Both feed a 300 ms debounced re-run of the same 30 ms scan. `~/.claude.json` gets a 750 ms debounce of its own because it is ~86 KB and is rewritten repeatedly *during* a session — measured, with five rotated backups at 113/115/144/514-second intervals, all mid-session.
3. **Background or explicit** — the `$HOME` project walk (162 ms at depth 5), the content-hash origin index (~800 ms), and every `git ls-remote`.

Two watcher hazards, both real. Claude Code writes `~/.claude.json` via `tmp.<pid>.<epoch>` + rename, replacing the inode on every save, so a watch on the path goes dead after the first write — watch the parent directory, or re-arm after every event. And Omarchy's own `Bar.qml` documents that `FileView`'s directory watch can permanently stop delivering events after several changes land in quick succession. Belt and braces: `FileView` + a slow 30 s reconciliation timer + an `IpcHandler { target: "oliwier.agent-skills-manager" }` exposing `refresh()` so a hook or a script can force a rescan.

`inotify` is effectively unlimited here — `max_user_watches` is 524,288 with 64 in use — but `inotify-tools` is **not** a declared dependency of the `omarchy` package. Guard with `command -v inotifywait` and degrade to the polling timer, exactly as `net-usage` degrades when docker is absent. Do not document `omarchy pkg add inotify-tools` in the README: a single package-manager line in a scanned fence costs the `package-manager` capability and forfeits a `passed` security baseline.

## 5.5 Hot reload and the dev loop

Quickshell's own file watcher is **off** — `omarchy-launch-shell` runs `QS_DISABLE_FILE_WATCHER=1 QS_NO_RELOAD_POPUP=1 systemd-cat -t omarchy-shell -- quickshell -n -p "$OMARCHY_PATH/shell"`. All plugin hot reload comes from `PluginRegistry`'s `inotifywait -m -r` on `~/.config/omarchy/plugins`, debounced 150 ms into `Qt.clearComponentCache()` + rescan. Console output goes to the journal under tag `omarchy-shell`.

`dev-sync.sh` is copied from `opencode-config_manager` with two strings changed: `rsync -a --delete` into `~/.config/omarchy/plugins/oliwier.agent-skills-manager/` excluding `.git dev-sync.sh *.md .gitignore test docs`, an explicit `rm -rf` of any stray symlinked tooling directory (rsync protects excluded names on the receiving side, so an already-deployed symlink is never removed and will keep failing validation forever), `chmod +x bin/*`, `omarchy plugin validate "$DEST"`, then `omarchy-restart-shell` — **not** `rescanPlugins`, because a bar widget already mounted in a bar slot keeps its old instance, and the change lands in the registry but not on the screen, which reads exactly like a bug in the edit you just made. Then `journalctl --user` for the last 20 seconds grepped for the plugin id.

---

# 6. The unified data model

One flat array of records. Grouping is a sort, not a nesting. Identity is `realpath` for anything on disk.

```jsonc
{
  "key": "claude:taste-skill",        // <tool>:<identity>, identity per tool's own rule
  "realPath": "/home/oliwierdata/.claude/skills/taste-skill",
  "contentHash": "sha256:…",          // sha256 of SKILL.md; distinguishes drifted copies

  "kind": "skill" | "plugin" | "mcp" | "command" | "agent",
  "displayName": "design-taste-frontend",  // frontmatter name / interface.display_name
  "dirName": "taste-skill",
  "description": "…",                 // sanitised on ingest, plain text only

  "tool": "claude" | "opencode" | "codex",
  "scope": "user" | "project" | "shared" | "system" | "admin" | "plugin" | "bundled" | "synced",
  "projectPath": null,

  "mounts": [                         // every path this same realPath is reachable from
    { "tool": "claude",   "path": "~/.claude/skills/taste-skill", "link": "real" },
    { "tool": "opencode", "path": "~/.claude/skills/taste-skill", "link": "native" }
  ],
  "linkage": "real" | "symlink" | "native" | "copy",

  "state": {                          // per tool, because the mechanisms differ
    "claude":   { "value": "on", "ladder": ["on","name-only","user-invocable-only","off"],
                  "lockedBy": null, "writable": true, "file": "~/.claude/settings.json" },
    "opencode": { "value": "allow", "matchedPattern": "*", "writable": true },
    "codex":    { "value": "enabled", "writable": true, "needsRestart": true }
  },

  "invocation": {                     // per tool, because the sigils differ
    "claude":   "/taste-skill",
    "opencode": "/design-taste-frontend",
    "codex":    "$design-taste-frontend"
  },
  "argumentHint": null,               // parsed into slots when present

  "tokens": { "alwaysOn": 72, "onInvoke": null, "model": "claude-opus-4-7", "method": "chars/4" },
  "usage":  { "count": 14, "lastUsedAt": 1788…, "daysSinceUse": 8, "source": "claude.json" },

  "taxonomy": { "category": "web", "tags": ["nextjs","react","seo"],
                "confidence": "medium", "classifier": "keywords" },

  "origin": { "type": "none" | "git" | "git-subdir" | "npm" | "pypi" | "pacman"
                    | "marketplace" | "remote" | "manual",
              "url": null, "ref": null, "subdir": null,
              "installedSha": null, "tier": 8, "confidence": "unknown" },

  "update": { "state": "unknown" | "current" | "behind" | "ahead"
                     | "diverged" | "local" | "error",
              "behind": 0, "checkedAt": null, "detail": "" },

  "attention": [],                    // ["drift","broken-symlink","name-mismatch","needs-auth",…]
  "flags": { "builtin": false, "readOnly": false, "pluginProvided": false }
}
```

Three deliberate decisions in that shape.

**Identity is `realPath`, and `mounts` carries the rest.** A naive per-tool scan produced 108 rows for 33 real skills; deduplicating by `realpath` gives 36 paths resolving to 33 unique files. `diagnose-crash` is one file reachable from `~/.claude/skills`, `~/.codex/skills` and `~/.agents/skills`.

**`contentHash` is a second key, not a nicety.** Two live drift cases exist on this machine: `~/.claude/skills/omarchy` is a real directory whose `SKILL.md` differs from the `/usr/share/omarchy` copy the other two tools symlink to, and `~/.agents/skills/impeccable/SKILL.md` differs from the plugin-cache copy at the same declared version 4.1.1 (34 differing files including an entire extra `agents/` directory). Deduplicating on `realpath` alone reports them as unrelated; on name alone, as identical. Both are wrong, and "same name, different content, both live" is a genuine finding no other tool surfaces.

**`state` and `invocation` are maps, not scalars.** The three tools disagree on identity, on the toggle mechanism and on the sigil. One `enabled` boolean and one `command` string would be wrong for at least one tool on every row.

---

# 7. Per-tool adapters

## 7.1 Claude Code (v2.1.259)

**Reads**

| Path | For |
|---|---|
| `$CLAUDE_CONFIG_DIR/skills/*/SKILL.md` (default `~/.claude/skills`) | user skills, keyed by **directory name** |
| `<cwd>/.claude/skills/**/SKILL.md`, walking up to the repo root **or** `$HOME`, whichever comes first | project skills; a clashing nested skill becomes `<subdir>:<name>` |
| `<managed dir>/.claude/skills/` (`/etc/codex`-equivalent: `/etc/claude-code/.claude/skills/`) | enterprise scope, read-only, absent here |
| `~/.claude/skills/synced/` | claude.ai-synced, read-only cache, `synced` is a reserved name |
| `~/.claude/commands/*.md`, `<project>/.claude/commands/*.md` | legacy commands, same frontmatter minus `name`/`paths`, invoked by **file name** |
| plugin `skills/<name>/SKILL.md` and plugin-root `SKILL.md` | `/plugin:skill`, frontmatter name + plugin prefix |
| `~/.claude/plugins/installed_plugins.json` | `{scope, installPath, version, installedAt, lastUpdated, gitCommitSha}` per `plugin@marketplace` |
| `~/.claude/plugins/known_marketplaces.json` | `{source:{source,repo}, installLocation, lastUpdated}` |
| `~/.claude/plugins/plugin-catalog-cache.json` (477 KB, 0600) | 291 plugins with `tokens.<model>.{always_on,on_invoke}`, `components.{commands,agents,skills[],hooks,mcpServers,lspServers}`, `marketplace_entry.{category,homepage,author,source{url,path,ref,sha}}`, `unique_installs`, `sha`, `last_updated` |
| `~/.claude/settings.json`, `<project>/.claude/settings.json`, `<project>/.claude/settings.local.json`, managed settings | `skillOverrides`, `enabledPlugins`, `disableBundledSkills`, `enabledMcpjsonServers`, `disabledMcpjsonServers` |
| `~/.claude.json` — **read only, never written** | `skillUsage` (bare name *and* `plugin:skill` keys), `pluginUsage` (`plugin@marketplace`), `agentLastUsed`, `favoritePlugins`, `projects[<path>].{mcpServers,enabledMcpjsonServers,disabledMcpjsonServers,hasTrustDialogAccepted,lastStartTime,lastCost}`, `claudeAiMcpEverConnected` |

Bundled skills (~18: `design`, `dataviz`, `artifact-design`, `code-review`, `claude-api`, `run`, `init`, `security-review`, `workflow-authoring`, …) are compiled into the binary and exist nowhere on disk. They are a hardcoded, version-keyed list with `path: null` and `tokens: null`, still toggleable via `skillOverrides` and still carrying real usage counts. `disableBundledSkills` is their group switch.

**Writes**

| Operation | Target | Method |
|---|---|---|
| Skill on/off | `~/.claude/settings.json` → `skillOverrides[<directory name>]` | `jsonc-edit` span splice |
| Plugin on/off | — | delegate to `claude plugin enable\|disable <p>@<m> [-s scope]` |
| Project MCP | `~/.claude.json` | **not in v0.1.0** — see §11 |

`skillOverrides` is a **four-value ladder**, not a boolean: `"on" | "name-only" | "user-invocable-only" | "off"`, absent meaning on. `name-only` lists the skill without its description, which is a real token saving and the reason this plugin is a context-budget editor rather than an on/off list. Resolution runs `policySettings > flagSettings > author lock (frontmatter `disable-model-invocation`) > plugin-provided (forced on) > projectSettings > userSettings`; `localSettings` participates only as an unqualified-name fallback. A row locked by any of the first four renders read-only with a lock glyph.

`enabledPlugins` values are `array | boolean | object` — the extended form carries version constraints — and precedence is `user < project < local < flag < policy`. A `false` written at a lower precedence than the file that enabled it does nothing and reports no error, so the panel computes the winning source and shows which file it will touch.

Token cost is computable locally with no API call and no subprocess:

```js
Math.round([resolvedName, description, whenToUse].filter(Boolean).join(" ").length / 4)
```

`resolvedName` is the *resolved* name — the directory name for user skills, `plugin:skill` for plugin skills — not the frontmatter name. On `api-design` this gives exactly 68 and on `omarchy` exactly 150, both matching the screenshot. The divisor is 4 in the extensions browser regardless of model; a separate model-aware divisor returns 3 for newer models including Opus 5, offered behind a settings toggle. `skillListingMaxDescChars` (default 1536) and `skillListingBudgetFraction` cap what actually reaches the prompt, so the badge and the real cost diverge on very long descriptions — show the badge, mention the cap in the detail view.

> **Verified on this machine, 2026-09-05.** The formula was run against all fifteen rows of the reference screenshot: **eleven matched exactly** (`database-migrations` 85, `deployment-patterns` 72, `docker-patterns` 88, `emil-design-eng` 43, `latex-engineer` 67, `nextjs` 94, `obsidian-vault-context` 73, `systematic-debugging` 28, `taste-skill` 70, `test-driven-development` 26, `threejs` 70). `api-design` computes 68 against a screenshot reading of 85; its `SKILL.md` has since gained a `metadata.origin` key, so the description was almost certainly edited after the screenshot was taken — treat it as stale, not as a broken formula. The remaining three (`omarchy`, `diagnose-crash`, `security-fortress`) could not be checked with a line-oriented regex because their `description:` is a **multi-line YAML scalar**. That is the implementation note: the frontmatter reader must be a real YAML parser, not a `^description:` match, or three of this machine's own skills silently report a token cost of 2 to 5.


`~/.claude.json` **can** be written safely and we still will not, in v0.1.0. The protocol is real: `mkdir ~/.claude.json.lock` (a directory, via proper-lockfile; `rmdir` releases; stale after 10 s, refreshed every 5 s), then Claude Code **re-reads the file from disk under that lock** and applies its pending mutation to that fresh base, so a disjoint-key edit survives. But: the protocol is reverse-engineered from one build; multiple Claude processes run concurrently on this machine including a daemon with no visible TUI; a file left unparseable for even an instant triggers Claude Code's auto-repair path, which overwrites the whole file from its in-memory cache and destroys everything on disk since the last read; and the official docs say plainly *"Claude Code also keeps a fifth file, `~/.claude.json`, that it writes for itself; you don't need to edit it."* Nothing v0.1.0 needs lives there.

## 7.2 OpenCode (1.18.27)

**Reads**

| Path | For |
|---|---|
| `~/.config/opencode/skills/**/SKILL.md` — 16 real skills, the single largest source here | user skills, keyed by **frontmatter name** |
| `~/.claude/skills/**/SKILL.md` and `~/.agents/skills/**/SKILL.md` | external skills, auto-loaded, killable with `OPENCODE_DISABLE_EXTERNAL_SKILLS` / `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS` |
| `<worktree ancestors>/.claude/skills`, `.agents/skills`, and each config dir's `{skill,skills}/**/SKILL.md` | project skills |
| `skills.paths[]` (`**/SKILL.md`) and `skills.urls[]` (an `index.json` catalog cached under `~/.cache/opencode/skills/<name>/`) | extra roots and remote catalogs |
| `~/.config/opencode/opencode.json` (or `.jsonc`) | `mcp`, `plugin[]`, `permission`, `agent`, `skills` |
| `~/.config/opencode/tui.json` | a **second, independent** `plugin[]` for TUI-target packages |
| `~/.cache/opencode/packages/<spec>/node_modules/<pkg>/package.json` | installed version and `repository.url` for npm plugins |
| `~/.local/state/opencode/plugin-meta.json` | resolved version, `last_time`, `load_count` (partial — enrichment only) |
| **the resolved config**, via `opencode debug config` or `GET /config` | the truth |

The last row is not optional. On this machine `oh-my-openagent` injects five MCP servers, sixteen agents, ~50 commands, a `tools` block and a local skills catalog at runtime through the `config()` hook. A widget that reads `opencode.json` shows one MCP server; the user sees six. **Never build the OpenCode view from the raw file.**

**Writes**

| Operation | Target | Method |
|---|---|---|
| Skill on/off | `~/.config/opencode/opencode.json` → `permission.skill["<frontmatter name>"] = "allow" \| "deny"` | `jsonc-edit` span splice |
| MCP on/off | `mcp.<name>.enabled` (the bare `{"enabled": false}` override form works for inherited servers) | v0.2 |
| Plugin off | remove the array entry from **both** `opencode.json` and `tui.json` | v0.2, with an explanatory row |

Two traps. `permission.skill` is glob-patterned and **last match wins**, so appending `{"my-skill":"deny"}` after an existing `{"*":"allow"}` is correct and prepending it does nothing — the panel appends, then recomputes and displays the *effective* verdict and the pattern that produced it. And `permission.skill` accepts a bare action string (`"skill": "deny"`) as well as a map; a parser expecting an object will crash on it.

The write target is `opencode.json` here, and OpenCode's own `Config.updateGlobal` **full-rewrites** a `.json` file with `JSON.stringify(…, 2)`, destroying comments — only the `.jsonc` branch splices. That is one more reason we splice ourselves rather than delegate. There is also no lock around OpenCode's config writes and a session is live on this machine, so writes there are the riskiest of the three: detect-modified-since-read and surface a loud conflict, never silently retry.

OpenCode never hot-reloads config. Every toggle needs a restart banner on the row.

`opencode.json` on this machine contains `"apiKey": "${GOOGLE_API_KEY:-}"` — a shell-style string that OpenCode does **not** interpolate (only `{env:VAR}` and `{file:path}` are). A `jq` round-trip preserves it; a reformat churns it. Surface it as a lint with a one-click fix to `{env:GOOGLE_API_KEY}`.

## 7.3 Codex (0.153.0)

**Reads**

| Path | For |
|---|---|
| `$HOME/.agents/skills/**` — root `r1`, **native, no symlink** | user skills, keyed by **frontmatter name**, falling back to the directory basename |
| `$CODEX_HOME/skills/**` — root `r0`, annotated in-source as *"deprecated, kept for backward compatibility"* | user skills |
| `$CODEX_HOME/skills/.system/**` — root `r2`, marked by `.codex-system-skills.marker` | six bundled skills (`imagegen`, `openai-docs`, `plugin-creator`, `review-agent`, `skill-creator`, `skill-installer`), read-only, symlinks **not** followed here |
| `<dir>/.agents/skills` for every directory from the project root down to cwd, plus `<project>/.codex/skills` | repo scope |
| `/etc/codex/skills` | admin scope, absent here |
| plugin skill roots, namespaced `<namespace>:<name>` | plugin-provided |
| `<skill>/agents/openai.yaml` | `interface.{display_name, short_description, icon_small, icon_large, brand_color, default_prompt}`, `policy.allow_implicit_invocation`, `dependencies.tools[]` |
| `~/.codex/hooks.json` | hooks, with a trust model |
| `codex mcp list --json` (14–63 ms) | MCP inventory |
| `codex debug prompt-input` | **the ground-truth oracle** for what Codex will actually load |

**Writes** — into `~/.codex/config.toml`, which **does not exist on this machine**.

| Operation | Key |
|---|---|
| Skill on/off | `[[skills.config]]` with `enabled` plus **exactly one** of `path` (an absolute path to the `SKILL.md` **file**, not the folder) or `name` |
| Plugin on/off | `[plugins."<plugin>@<marketplace>"] enabled = true \| false` |
| MCP add/remove | delegate to `codex mcp add\|remove` (fast, official) |

`skills.config` is read **only** from the User layer and session flags, so there is no per-project skill disable in Codex at all. The panel says so on the row rather than offering a switch that silently does nothing; project scoping for Codex is achieved by placing or removing the folder under `<project>/.agents/skills`.

There is no comment-preserving TOML writer on this machine — no `taplo`, no `dasel`, no `yq`, no `tomlkit`; `tomllib` is read-only by design. So the write is a **sentinel-delimited block splice**:

```toml
# >>> omarchy agent-extensions (managed) — do not edit inside this block >>>
[[skills.config]]
name = "some-skill"
enabled = false
# <<< omarchy agent-extensions (managed) <<<
```

We own everything between the sentinels and rewrite that region wholesale; we never touch a byte outside it. If the file does not exist we create it with `O_EXCL`. If it exists but our block is missing we append. If our sentinels are unbalanced or nested we **refuse** and say so. After every write we re-parse with `tomllib` and roll back on failure. Any `[[skills.config]]` entry outside our block is shown as "managed elsewhere — read only". The block goes last in the file, and the README says why: TOML scopes subsequent bare keys into the final table, so anything the user adds after our block would land inside it.

Codex skills take **no arguments** — the `$ARGUMENTS`/`$0`/`$1` text in the bundled `skill-creator` prose is inherited Claude-Code boilerplate that `codex-rs/skills/src/parser.rs` does not implement; it deserializes exactly `name`, `description` and `metadata.short-description`. Codex's real placeholder mechanism is custom prompts at `~/.codex/prompts/*.md` with 1-based `$1`–`$9`, `$ARGUMENTS`, named `KEY=value` and `$$` for a literal dollar. The panel does not offer an argument picker for a Codex skill.

`--strict-config` is accepted only by `codex exec` and the TUI — `codex mcp`, `codex plugin` and `codex debug` refuse it — so config validation runs through `codex exec --strict-config`.

## 7.4 Cross-tool rules

**Identity.** Claude keys by directory name. Codex and OpenCode key by frontmatter name, falling back to the directory. `~/.claude/skills/taste-skill/` declaring `name: design-taste-frontend` is the live proof and the reason a rename must move the directory **and** edit the frontmatter.

**Invocation.** Claude: `/<dirName>`, or `/<plugin>:<skill>` for plugin skills (always emit the qualified form as primary — a later plugin can steal the bare name). OpenCode: `/<frontmatterName>`, plus the model-facing `skill({name})` tool; skill-sourced slash commands exist but are excluded from `/` autocomplete in a vanilla install, so also offer `Use the "<name>" skill to …`. Codex: `$<frontmatterName>`, or `$<namespace>:<name>` for plugin skills. One skill, three strings.

**Duplicate names.** OpenCode registers skills with unbounded concurrency and the surviving entry is whichever async parse finishes last — measured flipping between runs for `omarchy`. It logs a `duplicate skill name` warning and nothing else. Claude has `skills_sync_name_collision` telemetry. **Nothing prompts the user.** The panel detects collisions itself, before writing, across all three tools and both scopes, and surfaces them as a Needs-attention row.

**Symlink following.** Claude sessions follow symlinks (`claude plugin validate` does not, and says so). Codex follows for User/Repo/Admin scopes and **ignores** for System. OpenCode follows (`symlink: true` in its scan call). All three verified empirically.

---

# 8. The UI

## 8.1 Grouping

Default: **attention first, then by tool.**

```
Needs attention          (urgent-tinted header)
Favorites
Claude Code
OpenCode
Codex
Shared (~/.agents)
Not used recently
▸ Disabled (N)           (collapsed)
```

Within a tool group, sub-order by kind (Plugins, Skills, MCP servers), then alphabetically. Attention items are **moved** into the top group, not duplicated, and every group header count is a plain count of the rows it shows; the honest totals live in one summary line beneath the search field:

> `47 items · 34 on · ~4.7k tok/turn · 2 need attention · 3 updates`

**Why by tool.** The token budget is per tool, because each CLI builds its own system prompt — the same skill in two tools is genuinely paid for twice, which is the panel's central finding. And tool is the only axis on which a row is never ambiguous. `g` cycles to two alternates, persisted: **by category** (the 14 groups from §3) and **by source** (repo, marketplace, bundle, local). Source earns its keep on this exact machine: it collapses OpenCode's 16 n8n skills into one header reading `n8n · 16 skills · ~2.7k tok/turn`, which is the single most useful line the panel can draw.

Group headers are focusable rows, collapsed and expanded with `h`/`l`, remembering state across opens. Five to eight headers means the whole list folds to one screen.

The section names are lifted verbatim from Claude Code's own extensions browser (`attention`, `favorites`, `disused`, the collapsible disabled header) so the panel reads as a native companion rather than a fan reimplementation.

**Needs attention** qualifies on: an MCP needing auth or failed to connect; a plugin that failed to load; an unreadable `SKILL.md`; a broken symlink; a duplicate name or a drifted copy; a config file that would not parse; a project skill in an untrusted folder (`hasTrustDialogAccepted: false`); a frontmatter name that does not match the directory (invalid for OpenCode); a description past 1024 characters (invalid for Codex and OpenCode); a `low`-confidence or unclassified category. Merely being disabled or unused never qualifies.

## 8.2 Row anatomy

At ~580 logical units of width:

```
│▌ [◇] design-taste-frontend  SKILL  ⟳            ~72 tok  [●─]  ⋮
│▌     user · claude+opencode · 14× 8d
```

1. A 2px full-height **tool rail** in the tool hue.
2. A 28×28 radius-6 **tile** filled with the tool hue at solved contrast, carrying the **category glyph** in white bold — kind is what you scan for, and the tile is where omaplug's colour actually comes from. An 8×8 radius-4 `Color.accent` dot at `(-2,-2)` when an update is pending.
3. Name (bold, `Style.font.body`, elided) + type badge (uppercase caption, `Util.alpha(fg, 0.45)`) + at most one status badge.
4. A single meta line at `Style.font.caption` in `Util.alpha(fg, 0.66)`: `scope · tools · usage`, or `connected` / `needs auth` / `failed` for MCP.
5. A **fixed-width right cluster**: token figure, state control, `⋮`. Fixed width so the toggle never moves vertically between rows — omaplug's two-row action column jitters down the list and is the one thing worth not copying.

Descriptions never go on a row — they run 250 to 950 characters. They live in the detail view, in a 400 ms hover tooltip, and in the search index.

Row height is **fixed** at `Style.space(56)`. omaplug's 56–120px variable rows produce a ragged list, jittering controls and unreliable `positionViewAtIndex`.

Hover and the keyboard cursor are the same highlight, not two: the row's `MouseArea` is anchored `right: actions.left` so hovering a button is not hovering the row, and `onEntered` moves the cursor index.

## 8.3 Colour

Three channels, one question each. This is the discipline in the user's own `lib/Palette.js` and it resolves the only real conflict in the research.

**Hue = tool.** Reuse `Palette.providerTint(id, Color.accent, surface, fallback)` verbatim: hue rotated off `Color.accent` on the existing 38° grid (`PROVIDER_STEP = 38`), saturation clamped, and HSL lightness **solved by bisection** against `PROVIDER_TARGET = 6.0` contrast on the actual surface. Add `TOOL_SLOTS = { claude: 0, codex: 3, opencode: 6 }` — 114° apart, and slot 0 still coincides with the existing `anthropic: 0`, so this plugin and `opencode-config-manager` agree on Claude's hue. The `if (base.s < 12) return fallback` escape stays: a theme whose accent is grey is saying it does not want hue, and on such a theme the tool must still be legible — which it is, via the tool letter in the tile and the rail's presence.

**Glyph + uppercase caption = category and kind.** Monochrome, always `Util.alpha(fg, 0.45)`. Fourteen hues would be unreadable and would fight the tool rail; three tools × five kinds is already fifteen colours nobody can name.

**Accent and urgent = status.** `Color.accent` for update-available (the corner dot) and the favourite pill at `Util.alpha(Color.accent, 0.18)`; `Color.urgent` for needs-auth, failed-to-load and drift; nothing at all for the normal case. Accent budget stays tiny — one control state, one badge, one dot, links. Never accent-tint a whole row.

**Ordinal data never gets a categorical palette.** Token cost is a 3-step meter drawn in `foreground` at graded alpha `0.50 / 0.65 / 0.85` — the user's own `tierAlpha` values — not a red/amber/green traffic light. An unknown cost drops the indicator entirely rather than earning a confident low band, and 0.30 alpha is about 2.1:1 on a dark theme, which is a smudge, not a mark.

Everything else is theme tokens. Zero hardcoded hex for chrome. Declare `contentForeground`, `contentFontFamily`, `panelBackground` at the panel root and thread them down as `required property` into every child, exactly as omaplug does — that inheritance *is* the reason the user perceives omaplug as having good colours. Muted text is `Util.alpha(fg, 0.66)` and `Util.alpha(fg, 0.45)`, never `Qt.darker`: on a light theme `Qt.darker` makes secondary text *more* prominent than the primary, and on all-black text all three levels collapse.

## 8.4 Keymap

| Key | Action |
|---|---|
| `/` | focus search; `Esc` in search blurs to the list, `Esc` in the list closes the panel |
| `j k ↓ ↑` | move, skipping rows inside collapsed groups and skipping headers |
| `h ←` / `l →` | collapse / expand the group (or jump from a row to its header) |
| `Space` | toggle on/off for the row's primary tool |
| `Enter` | open the detail view |
| `f` | favourite |
| `c` / `C` | copy invocation / force the argument picker |
| `n` | new skill |
| `t` | cycle tool filter (All → Claude → OpenCode → Codex) |
| `g` | cycle grouping (tool → category → source) |
| `k`… wait — `y` | set category on the focused row |
| `p` | project setup (v0.2) |
| `u` / `U` | mark for update / check all (v0.3) |
| `a` | apply everything staged |
| `r` | rescan |
| `x` | uninstall — **guarded** |
| `?` | keymap overlay |

Two implementation notes that will bite otherwise.

`PanelKeyCatcher` fires `activateRequested` for **both** Space and Enter, and fires `returnRequested` first for Enter. So "Space toggles, Enter views" is not directly expressible with its signals: set a flag in `onReturnRequested` and branch in `onActivateRequested`, or bypass the catcher for those two keys with an own `Keys.onPressed` at `Keys.priority: Keys.BeforeItem`. And `x` is pre-bound to `deleteRequested`, which here means uninstall — reuse the user's own two-stage guard where the first press of an acting key only lights the cursor, because acting on an invisible selection is how you delete the wrong thing.

Do **not** gate the key catcher with `blocked: searchField.activeFocus` while force-focusing the search field on open. That is exactly the trap that made omaplug entirely mouse-driven despite importing the component. Keep the search field focused so typing works immediately and forward Up/Down/Space/Enter/`f` **out** of the `TextField`.

Footer: one centred caption line in `Util.alpha(fg, 0.45)`, four spaces between items, five verbs relevant to the focused row's kind, the rest behind `?`:

> `↑↓ select    ⏎ view    space toggle    f favorite    / search`

## 8.5 Flow: copy the invocation

**Zero-argument fast path — one keystroke.** Cursor on row, press `c`, clipboard holds the command, toast reads `Copied /design-taste-frontend`. That covers ~97% of rows: across ~45 skills on this machine exactly **one** declares `argument-hint`, and **zero** declare `arguments`.

The string is derived per tool from §7.4, never guessed. The user's brief suggests `/taste-skill`; for Claude that is right and for OpenCode it is wrong — the same file is `/design-taste-frontend` there. Getting this right for all three is the feature.

**Argument path.** `c` on a row that declares `argument-hint`, or `C` on any row, opens an `ArgumentSheet`. Parse the hint by structure: `[...]` delimits a positional slot, `|` separates alternatives within a slot, ` · ` separates semantic clusters (rendered as separator lines, not as options), a bare word is free text, and a parenthetical is a hint, not an enum. `impeccable`'s single hint therefore parses to slot 1 = 22 options in 6 clusters and slot 2 = a free-text `target`. Each slot renders as a `SearchableDropdown` from `qs.Ui`, stacked, with a live one-line preview in `Color.accent` pinned at the bottom. First field focused on open, so the real cost is `c` → `pol` → `Enter` = `/impeccable:impeccable polish` in five keystrokes.

Two extra sources when they exist, merged and deduplicated because they drift: a `## Commands` markdown table in `SKILL.md` (whose first cell is a backticked `name [arg]`, and whose second column gives the chip grouping), and a `scripts/command-metadata.json` sidecar (23 entries of `{description, argumentHint}` in impeccable's case). They disagree on 5 of 23 hints — the JSON is the richer and authoritative one for hints, the table is authoritative for category and reference path.

**Repeat path.** Remember the last argument set per item in `overrides.json`, so `c` then `Enter` re-copies the previous command in two keystrokes.

**Mechanism.** `Quickshell.execDetached(["wl-copy", "--", text])` — a plain argv with no shell at all, which cannot be re-tokenised and needs no quoting. `wl-copy` is present; `cliphist`, `xclip` and `xsel` are not. Omarchy's own `wl-paste --watch` daemons capture whatever we copy into the shell's clipboard history for free.

Do **not** use `Quickshell.clipboardText`. It is writable in 0.3.1 and upstream's own header says *"Under wayland the clipboard will be empty unless a quickshell window is focused"* — a bar-anchored layer surface has no focus serial, so the write silently no-ops.

A second action per row: **Send to terminal**, via Omarchy's own `omarchy-clipboard-paste-text --shift-insert <text>`, which copies and then Shift+Inserts into the focused window. That is the button that removes the alt-tab, and the binary already ships. Guard it — without `--copy-only` that helper *types* into whatever has focus, so a mis-wired button puts a slash command into a browser.

**Never emit a shell string built from free text.** The invocation is composed from a validated id plus arguments drawn from our own parsed enum; free-text slots are stripped of newlines (a slash command is one line) and the assembled string stays editable before the copy.

## 8.6 Flow: project setup (v0.2)

`p` opens a `ChoiceSheet` with three decisions and one preview.

1. **Target** — the entries of `~/.claude.json`'s `projects` map, filtered to paths that still exist, ranked by `lastStartTime` with `lastCost` as tiebreak, unioned with `githubRepoPaths` values and a cached background filesystem discovery, then a final `Choose a folder…` row. The union matters: 8 of 16 project keys have no agent config, while `~/mcp`, `~/my-skills`, `~/oliwier/portfolio` and `~/my-omarchy_config` have agent config and have never been opened by Claude.
2. **Mode** — Symlink / Copy / Reference-only. Default **symlink when the source is a git working tree the user can update, copy otherwise**, because a copy silently detaches from upstream and makes "check for updates" a lie forever.
3. **Shared vs personal**, Claude only — reuse the CLI's own wording: `.claude/settings.json (shared with your team)` vs `.claude/settings.local.json (just you)`.

Then a preview, always, before the confirm, with the verb on every line:

```
+ <proj>/.claude/skills/design-taste-frontend   (symlink → ~/.claude/skills/taste-skill)
~ <proj>/.claude/settings.local.json            (add skillOverrides entry)
= <proj>/.mcp.json                              (unchanged)
```

Destinations: Claude `<proj>/.claude/skills/<name>/`; OpenCode `<proj>/.opencode/skills/<name>/` (and warn that OpenCode will inject `node_modules`, `package.json` and a `.gitignore` into that directory on next start); Codex `<proj>/.agents/skills/<name>/` — which is also read by OpenCode, so one copy serves two — with `<proj>/.codex/skills` offered only when project MCP is also wanted, and with `[projects."<abs path>"] trust_level = "trusted"` written alongside.

Resolve the git repo root first. `.claude/settings.local.json` is read at the **repository root**, worktree-resolved, not the launch directory — writing to the wrong one means Claude Code reads a stale file.

## 8.7 Flow: updates (v0.3)

Mark, then apply. `u` marks a row (Claude Code's own verbs are "Mark for update" / "Unmark for update"), the row gains the accent corner dot, the footer grows `a apply (3)`. `U` opens a full-page check-all view.

**Origin resolution is a cascade**, and the honest headline is that it fails for almost everything the user actually has: **zero of 33 skill directories is a git repo**, none of the four skill roots is a repo, `/usr/share/omarchy` is not a repo, and the single `origin:` field on the machine reads `custom (synthesis)`.

| Tier | Signal | Confidence |
|---|---|---|
| 0 | `origins.json` manual link | authoritative, immune to re-detection |
| 1 | Plugin/marketplace registry: `installed_plugins.json.gitCommitSha` + `known_marketplaces.json.source.repo` + `.claude-plugin/plugin.json.repository` | exact |
| 2 | Enclosing git worktree: `git rev-parse --show-toplevel --show-prefix` on the **realpath** | exact |
| 3 | `readlink -f` then `pacman -Qo` then `pacman -Qi` for the URL — and parse `.r<N>.g<sha>` out of the version for the exact upstream commit | exact |
| 4 | Package registry: npm `registry.npmjs.org/<pkg>` (dist-tags + repository), PyPI `project_urls.Repository` (which carries the monorepo subfolder), the MCP Registry (`repository.url` **and** `repository.subfolder`) | high |
| 5 | Content-hash match against an index of every `SKILL.md` under `$HOME` | medium — **and usually ambiguous** |
| 6 | Nothing | none — offer "Link upstream…" |

Tier 5 is the one that makes the feature work on this machine and it must be presented honestly: measured, it recovers 32 of 38 unresolved skills, taking coverage from 21% to 88%, but **29 of those 32 are ambiguous** — `n8n-code-tool`'s exact content exists under two different remotes. It yields a menu, not an answer. The remaining six are the Codex `.system` bundled skills, which need a "bundled" label rather than a lookup. The index costs ~800 ms warm; run it off the UI thread, cache it, key it by content hash.

Because most skills have no upstream, **manual linking is the primary path, not the fallback.** The "Link upstream…" affordance takes a GitHub tree URL (`https://github.com/owner/repo/tree/ref/path` — the same form Codex's installer accepts), parses it into `{url, ref, subdir}`, verifies with one `git ls-remote`, takes a content fingerprint, and writes `origins.json`.

**Checking** uses `git ls-remote <url> <ref>` as the default primitive — no auth, no REST rate limit, ~1.2 s. Exit 128 means the repo is gone; exit 0 with **empty output** means the ref is gone, and treating that as "up to date" is a silent bug waiting to happen. An exact behind-count uses one `gh api repos/{o}/{r}/compare/{installedSha}...{ref}` call when `gh auth status` succeeds — but `gh` is in **neither** `omarchy-base.packages` nor `omarchy-other.packages`, so it enriches and never gates, and unauthenticated `api.github.com` at 60/hr is never called in a loop.

Never use `releases/latest` as a version oracle: for `pbakaus/impeccable` it returned `ext-v1.4.0` on one day and `cli-v4.0.1` on another while the skill train sat at `skill-v4.2.0`. Use `git ls-remote --tags --refs <url> 'refs/tags/skill-v*'` with client-side semver sorting.

Never run `rev-list --count HEAD..@{u}` inside `~/.claude/plugins/marketplaces/*`: that clone is shallow with refspec `+refs/heads/main:refs/remotes/origin/main` and a **stale** `origin/main`, so it reports 0 while the real upstream is hundreds of commits ahead.

**Applying** follows `omarchy-plugin-update` exactly: export `GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND='ssh -oBatchMode=yes'`, `timeout 15 git fetch --quiet origin HEAD`, compare `rev-parse HEAD` against `FETCH_HEAD`, show the diff, `git merge --ff-only FETCH_HEAD`, validate, and `git reset --hard ORIG_HEAD` on failure. For a git-subdir upstream, sparse-clone to a temp dir (`git clone --filter=blob:none --depth 1 --sparse` then `sparse-checkout set <path>`) and swap. Prefer delegation wherever a first-party command exists: `claude plugin marketplace update <m>` then `claude plugin update <p>@<m> -y`, `codex plugin marketplace upgrade [name] --json`, `opencode plugin <module> -g -f`.

Before applying, check for local modification: `git status --porcelain` for git installs, a recomputed sha256-tree fingerprint against `origins.json` for the 31 non-git ones (measured at 40 ms for a two-file skill). If dirty, refuse the fast path and offer three explicit choices — back up and overwrite, stash, cancel. Never silently discard. Back up first to `<parent>/.<name>.bak.<YYYYMMDDHHMMSS>`; the dot prefix is load-bearing, because every tool's discovery glob skips dotfiles and a non-dotted backup would register as a second, duplicate skill.

Run the whole job **detached** with a status-file protocol at `$XDG_RUNTIME_DIR/oliwier.agent-skills-manager/update.status` (falling back to `~/.cache/…`), copying omaplug's job-id guard, `pid` line with a `kill -0` liveness probe every 2 s, `FileView { watchChanges: true }` plus a 500 ms poll, a 3 s start timer, a per-operation watchdog and a 300 s staleness window for adopting an orphaned job. Applying an update can reload the plugin that is running it; without this the UI is stuck on "Installing…" forever.

**A git acquisition followed by an execution sink in the same script is the marketplace's blocking `remote-git-execution-unpinned` finding.** So: `git -C <dir> fetch/merge` and nothing else. Show the diff, and let the user run any build step themselves.

---

# 9. The bar widget

The icon is **always** the state channel, regardless of the label setting: `bar.barForeground` normally, `bar.urgent` when something needs auth or failed to load, with a small `Color.accent` pip when updates are staged. One state channel, costing zero width. That is the user's own doctrine and it frees the label slot entirely.

**Default label: the token cost.** `barLabel: "Token cost"`, rendered `4.7k` — the always-on tokens the enabled skills add to every turn across the selected tools. The argument: attention is already on the icon, so the label must not duplicate it; a count is legible but not actionable (28 of 36 says nothing about whether that is expensive); the token figure is the number no other tool on this machine shows, it is the reason to open the panel, and it moves when you act.

Width stability is mandatory. Format as `4.7k` / `12.1k`, always four or five characters, pinned with a `TextMetrics { text: "WWWWW" }` box — a bar that changes width on every change twitches all day and nudges every widget to its left. The update pip is drawn **over** the glyph, never beside it.

Mouse contract: left click toggles the panel, middle click refreshes without opening, scroll is deliberately unbound — a stray scroll over the bar must never rewrite a config. Hover shows `bar.showTooltip(root, tooltipText)` with the per-tool breakdown.

Vertical bars return an empty label and draw the glyph only.

The widget exposes the shape contract the bar's popout coordinator requires — `readonly property bool opened`, `open()`, `close()`, `togglePanel()`, `readonly property bool popoutSwitchClosing`, `closeForPopoutSwitch()` — all forwarded to the `Loader`'s `Panel.qml` item, plus `IpcHandler { target: "oliwier.agent-skills-manager" }` with `open/close/show/hide/toggle/refresh/status`. Every IPC method is read-only or UI-only: none of them writes a config. Exposing `enableSkill` over IPC would be a blocking marketplace finding — the reviewer has flagged first-party plugins for exactly that, since any local process could then modify the user's configuration without a panel interaction.

Set the `Loader`'s `active: false` until first open. omaplug loads 1900 lines of QML at shell start for every user whether or not they open it.

Glyph: a book-with-gear or toolbox from the Nerd Font, distinguishable from omaplug's plug and from `omarchy.agents`.

---

# 10. Settings schema

Written in the house voice: name each option, state what it costs, justify which one is the default, and never promise more than the write actually reaches. Declared in `manifest.json` under `barWidget.schema` for the marketplace and for any future settings UI — **and duplicated as a literal third time in every `setting(key, literal)` call in QML**, because the shell copies a manifest's `defaults` into registry metadata and never reads them back. There is no settings-form renderer in 4.0.0.alpha; `settingsForm` and `schema` are as decorative as `aliases`. The panel draws its own settings pane.

| Key | Type | Default | Description |
|---|---|---|---|
| `barLabel` | enum: Token cost / Enabled count / Updates / Nothing | `Token cost` | What the bar says next to the icon. The icon already turns urgent when something needs your attention, so the label is free for the number nothing else on this machine shows: the tokens your enabled skills add to every single turn. The count is easier to read and tells you less — twenty-eight of thirty-six says nothing about whether that is expensive. Nothing leaves the icon, and the panel answers the question. |
| `tools` | multiselect: Claude Code / OpenCode / Codex | all three | Which agent CLIs this panel manages. A tool that is not installed is skipped whether or not it is ticked; untick one you do have to keep it out of the list entirely, rather than looking at a group you never touch. |
| `grouping` | enum: Tool / Category / Source | `Tool` | How the list is divided below the attention and favourites groups. Tool is the default because the token cost is per tool — each CLI builds its own system prompt, so the same skill in two tools is paid for twice. Category answers what do I have; Source answers where did this come from, and is the one that folds a sixteen-skill bundle into a single line. |
| `tokenDivisor` | enum: 4 (matches Claude Code) / 3 (newer models) | `4` | Both are estimates over the same text. Four is what Claude Code's own browser shows, so the numbers here match the numbers you already see; three is closer for Opus 5 and every newer model, and will read about a third higher. Neither is a tokenizer. |
| `showBuiltins` | boolean | `false` | The skills each CLI ships with — Codex has six under a `.system` folder, Claude has roughly eighteen compiled into its binary. They cost context like any other, but you did not install them and mostly cannot remove them, so they stay hidden until you want to audit the whole bill. |
| `showComponents` | boolean | `false` | A plugin bundles skills, commands, agents and sometimes MCP servers. Off shows the plugin as one row with a count; on lists every piece as its own row, which is what you want the day you are hunting for which of twenty-three commands you actually meant. |
| `disusedDays` | integer 7–180 step 1 | `30` | Days without a single invocation before an item drops into Not used recently. Nothing is disabled for you; the group exists because a skill you have not called in a month is still charging you for its description on every turn, and that is the only way to notice. |
| `confirmToggle` | boolean | `false` | Off is the fast path the bar is for. What keeps that safe is the backup taken on the way past and the undo sitting in the toast, not a dialog. Turn it on when a mis-toggle would cost you a long-running session. |
| `updateCheck` | enum: When the panel opens / Once a day / Never | `Once a day` | Checking means a network call per origin, so opening the panel would otherwise pause on a bad connection. Once a day catches everything worth catching; `U` checks now whatever this says. |
| `projectSetup` | enum: Link where it can, copy where it cannot / Always copy / Always ask | first | A link keeps the project pointed at the one copy you update; a copy is a fork you will forget you made, and update will never be able to tell you it drifted. Copying is still right for a skill you are about to edit for one project only. |
| `agentsDir` | path | `""` | Leave empty for `~/.agents/skills`, which Codex reads natively as a skill root and OpenCode picks up as an external source. Claude Code does not read it at all — the skills you keep there reach Claude only through the symlinks in `~/.claude/skills`, and this panel will tell you when one is missing rather than quietly showing you a skill Claude cannot see. |
| `keepBackups` | integer 1–200 step 1 | `10` | Copies of each file taken immediately before a write overwrites it, oldest deleted past this count. Undo reads the newest pair, which is never pruned, so one is always kept whatever this says. |

Every numeric setting is clamped in QML *and* again in the helper — a hand-edited non-number arrives as `NaN`, and `NaN` reaching a `Timer.interval` is a timer that never fires and restarts itself hundreds of times a second. Clamp with `Math.min(2147483647, …)` too: `Timer.interval` is a signed 32-bit int in milliseconds, so anything past ~596 hours wraps negative.

Hard defaults, deliberately **not** settings: the section order, the colour mapping, the keymap, whether attention items are lifted, and the token-estimate method. Those are the design; exposing them would be admitting we did not decide.

---

# 11. Write-safety rules

Twelve rules. Every one of them exists because something measurably went wrong.

1. **Never write with `FileView`.** Its write is atomic onto the path it *resolved*, so a symlink parked at the target is followed and the symlink's target is overwritten — measured in the user's own plugin, with the store landing in an unrelated file every twenty seconds and the symlink still standing. There is no property that turns it off. Several skill paths here **are** symlinks into `/usr/share/omarchy`.
2. **All writes go through `bin/safe-write`:** `O_EXCL|O_NOFOLLOW` mode 0600 temp in the destination's own directory, write, fsync, chmod to the preserved mode, `rename(2)`, fsync the directory. Temp names are unpredictable — `.new` and `.tmp` beside the real file are neither.
3. **All reads go through `bin/safe-read`:** `O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW`, then `fstat` on **that descriptor**, then regular-file + own-uid + size-cap checks, then read exactly the vouched-for bytes. `O_NONBLOCK` is what turns a planted FIFO into `ENXIO` instead of a stall inside `open(2)` — and a stall inside `open(2)` freezes the entire desktop shell. Check-then-open is not fixable with a timeout; the marketplace reviewer rejected exactly that mitigation on this user's previous submission.
4. **Never reserialise a user's config.** Splice the exact byte span the one key occupies, back to front so an earlier offset is never invalidated by a later one, detecting the file's own indent. `opencode.json` carries `${GOOGLE_API_KEY:-}`; `settings.json` carries a hand-authored `autoMode.environment` array; users diff their dotfiles.
5. **Prefer the vendor CLI where one exists and is fast enough.** `claude plugin enable|disable`, `claude plugin update`, `codex mcp add|remove` (14–63 ms). That outsources locking, merging and format preservation. The exception is `opencode`, at 5–8.6 s, which is banned from every path.
6. **One write path per file.** Where we delegate to a CLI, we never also hand-edit that file. A direct rename while Claude Code holds `~/.claude.json.lock` clobbers the holder.
7. **Detect-modified-since-read, always.** Compare `(mtime_ns, size, inode)` against what was read. On a difference, abort and re-present rather than merge blindly. `~/.claude.json` and `opencode.json` are both rewritten by running sessions.
8. **Parse-check the serialised bytes before the rename, never after.** A `~/.claude.json` left unparseable for an instant triggers Claude Code's auto-repair, which overwrites the whole file from memory and destroys everything on disk since its last read. A `config.toml` left unparseable breaks Codex's entire config load, not just our block.
9. **Back up before every write**, to `~/.local/state/omarchy/agent-extensions/backups/` with second-resolution stamps disambiguated by a `-2`, `-3` suffix (an undo lands well inside one second, and without a unique name the revert's own backup overwrites the copy it is about to restore from), pruned to `keepBackups` but **never** pruning the copy Undo points at.
10. **Write eagerly, on the user action.** A write through a child process does **not** survive `Component.onDestruction` — the bytes sit in Qt's buffer while the event loop that would flush them is already stopping. Never defer a user-visible mutation to shutdown.
11. **No state-changing IPC.** `open/close/toggle/refresh/status` only. Anything running as this user can call these.
12. **Argv arrays, never shell strings.** Skill names and descriptions come from arbitrary third-party frontmatter. Where `bash -c` is genuinely needed for a pipeline, use a **constant script plus positional parameters** and pass every value as `$1`, `$2` — never spliced into the script text. And no runtime value ever goes into interpreter source: `python3 -c "…$var…"` is the shape of an injection even when today's source for it is the kernel.

Two more that are not writes but belong here:

13. **`textFormat: Text.PlainText` on every `Text`** that renders a name, description, author, path or error. Qt defaults to `AutoText`, which sniffs HTML — `<img src="https://evil">` in a skill description becomes a network fetch made by the long-lived shell process, chosen by whoever wrote the listing. Shell components we do not own (`PanelHero`, `Button`, `ConfirmDialog`, `PanelToolTip`) do not set it and are not ours to fix, so flatten strings with a `plain()` helper before handing them over. Also strip zero-width characters — upstream ships an agent name containing one.
14. **Bound every external boundary.** `head -c` caps at the producing end and a matching byte ceiling at the consuming end (4 MiB process output, 12 MiB catalog), `timeout N` on every subprocess, `--max-filesize` and `--proto '=https'` and no `-L` and no `--compressed` on every curl, and `Object.create(null)` for every id-keyed map with `hasOwnProperty.call` lookups, because a skill literally named `__proto__` is possible.

---

# 12. Failure matrix

| # | Failure | How we detect it | What the UI does | Recovery |
|---|---|---|---|---|
| 1 | A tool is not installed | binary absent from `PATH` **and** config dir absent | No group. No empty state. No mention outside the settings multiselect, where it is greyed with "not found on this machine". | none needed |
| 2 | Tool installed, config unparseable | helper returns `{ok:false, code:"E_PARSE", path, line, col}` | One Needs-attention row: `OpenCode config could not be read — opencode.json:12`. Enter opens the file. **Never** an empty list — a panel showing zero OpenCode skills when the user has sixteen is worse than useless. | manual edit; `r` rescans |
| 3 | Helper times out (exit 124/137/143, empty stdout) | non-zero exit with no JSON | `E_KILLED`: "That took too long and was stopped. Nothing was changed." | `r` |
| 4 | Helper crashes mid-write | exit 3 | Rollback already ran in the helper's signal trap; the toast says which file was restored. | automatic |
| 5 | Config changed under us between read and write | `(mtime_ns,size,inode)` mismatch | Conflict dialog naming the file: "Reload and try again" / "Cancel". Never a silent retry. | `r` then repeat |
| 6 | Toggle written at the wrong precedence | winning-source computation | The row shows which file wins and offers to write there instead. | one click |
| 7 | Claude plugin toggled but not reloaded | always true | Persistent row note: "takes effect after `/reload-plugins` or a restart". Without it the toggle is reported as broken. | user action |
| 8 | OpenCode or Codex toggled | always true | Persistent row note: "restart <tool> to apply". OpenCode never hot-reloads config; Codex needs a restart for `skills.config`. | user action |
| 9 | `~/.codex/config.toml` does not exist | `stat` | The confirm sheet says, in words, **"This will create `~/.codex/config.toml`"**. A config file materialising unannounced is how a utility loses trust permanently. | user confirms |
| 10 | Our sentinel block in `config.toml` is unbalanced or nested | scan before write | Refuse. Show the two sentinel lines and their line numbers. Offer "open the file". | manual |
| 11 | Broken symlink in a skill root | `-L` true, `-e` false | Needs-attention row: "target missing: `/usr/share/omarchy/…`". `-e` alone does not see it. | user action |
| 12 | Two copies, same name, different content | name collision + `contentHash` differ | Needs-attention row: `omarchy · 2 copies, contents differ`, expanding to both paths, both hashes and which tools see each. | user chooses |
| 13 | Frontmatter name ≠ directory name | scan | Warning chip: "invalid for OpenCode; Claude will call it `<dir>`, OpenCode will call it `<frontmatter>`". Offer a normalise fix. | one click |
| 14 | Description > 1024 chars, or contains `<`/`>` | scan | Warning chip naming which tools reject it. | detail view |
| 15 | Create: target path already exists | `stat` before write | Refuse. Offer Rename / Open existing / Create as `<name>-2`. Never overwrite. | user chooses |
| 16 | Create: name collides in a **different** tool | cross-tool scan | Show it, and default to "link to the existing one instead of creating a second copy" — that is almost always what was meant. | user chooses |
| 17 | Create: name collides in a different **scope** of the same tool | scan | Allow, but warn that the project one shadows the user one, and show which wins. | informational |
| 18 | `git ls-remote` exits 0 with **empty** output | explicit check | `E_BAD_REF`: "the branch `<ref>` no longer exists upstream". This is *not* "up to date". | edit the link |
| 19 | `git ls-remote` exit 128 | exit code | `E_NO_REPO`: "the repository could not be reached or no longer exists". | edit the link |
| 20 | Git wants credentials | cannot happen — `GIT_TERMINAL_PROMPT=0`, `GIT_SSH_COMMAND='ssh -oBatchMode=yes'`, `timeout 15` | Row shows `ERROR — authentication required`. | manual |
| 21 | Skill has no detectable upstream (the normal case) | cascade exhausted | Not an error. A quiet "Link upstream…" affordance on the row and a Needs-attention entry only if the user asked to check. | one paste |
| 22 | Content-hash origin match is ambiguous | > 1 candidate | Present the menu, never auto-adopt. Record the choice as `manual`. | user chooses |
| 23 | Local modifications before an update | `git status --porcelain` / fingerprint mismatch | Refuse the fast path; three explicit choices, never a silent discard. | user chooses |
| 24 | Detached update job died | `kill -0` fails twice at 2 s intervals | "The update was interrupted. Nothing further was changed." Row returns to its previous state. | `U` |
| 25 | Update applied but validation failed | validator exit | `git reset --hard ORIG_HEAD` or restore the `.bak.<stamp>`; the row shows the validator's message verbatim. | automatic |
| 26 | `inotifywait` absent | `command -v` | Silent degrade to the 30 s reconciliation timer. Mentioned once in `doctor`, never in the list. | none |
| 27 | `FileView` directory watch stops delivering | reconciliation timer notices a mtime change it was not told about | Silent recovery. This is documented in Omarchy's own `Bar.qml`. | automatic |
| 28 | `gh` absent or unauthenticated | `gh auth status` at startup | Exact behind-counts are unavailable; `git ls-remote` still answers behind/current/unknown. No error shown. | none |
| 29 | Search matches nothing | count 0 | One dimmed line: `No items match "<query>"` / `Esc to clear`. Never a blank area — an empty region reads as a failed load. | `Esc` |
| 30 | Nothing installed at all | count 0, no filter | One line and one action: `No skills, plugins or MCP servers found.` / `⏎ create your first skill`. | `n` |
| 31 | First paint before both async reads land | `ready = inventory !== null && overrides !== null` | Rows read "reading what is on disk", not "0 skills" and not "never used". *Nothing matches* is a finding, not a default. | automatic |
| 32 | Claude/Codex/OpenCode row is locked by policy or an author flag | resolution cascade | Read-only with a lock glyph and the reason ("locked by frontmatter `disable-model-invocation`"). | none |

Every error string comes from the backend, not the panel. The panel renders `issue.detail || issue.code` and forwards codes untouched — a backend that learns a new failure should not need a QML change to describe it, and a UI that invents its own wording draws `E_SOMETHING` the day it falls behind.

---

# 13. Scope

## v0.1.0 — ship

- **Read-only inventory across all three tools**, deduplicated by realpath, with `linked` / `copied` / `native` distinguished, and per-tool visibility derived from discovery-path membership rather than from duplicated scanning.
- **The grouped, collapsible list**, keyboard-driven, with `qs.Ui` components and `Color.*` tokens, type-to-search, the footer hint bar, favourites, and a real empty state.
- **The taxonomy** — 14 categories, tags, the classifier cascade, per-row confidence, and the one-keystroke override written to `overrides.json`.
- **Create a skill** — the seven-field form, the five templates, the portable file, the Codex-strict gate, delegation to `claude plugin init` and `init_skill.py`, and the cross-tool fan-out.
- **Token cost** — the `chars/4` always-on figure per item and per tool group, plus a budget warning where a tool's listing would be truncated.
- **Usage stats** — read free from `~/.claude.json`'s `skillUsage` / `pluginUsage`, with `· never used` in warning colour, and an explicit "not tracked" for OpenCode and Codex, which have no equivalent counter.
- **Copy the invocation**, per tool, with the argument picker when `argument-hint` exists.
- **Skill enable/disable in all three tools** — `skillOverrides` (four states) for Claude, `permission.skill` for OpenCode, the sentinel `[[skills.config]]` block for Codex.
- **Claude plugin enable/disable**, delegated to the CLI.
- **Needs attention**, populated by real signals: drift, broken symlinks, name mismatches, over-long descriptions, unparseable configs, low-confidence classifications.
- **The bar widget** with the deferred token-cost label.
- The stat-based cache, `doctor`, `dev-sync.sh`, the four-layer test suite and CI.

## Later

| Version | Adds |
|---|---|
| **v0.2** | MCP toggles for all three tools *together* (`codex mcp` delegation, `mcp.<name>.enabled` splice for OpenCode, `~/.claude.json` under its own lock for Claude project scope, behind an explicit confirm). Project setup, with the copy-vs-symlink choice and the full preview. OpenCode plugin removal with its explanatory row. Codex plugin toggles. |
| **v0.3** | Upstream updates: the origin cascade, the manual-link store, the content-hash index, the detached job with the status-file protocol, mark-then-apply, rollback. |
| **v0.4** | Browse and install from the official catalog (291 plugins, already cached locally with token costs and install counts — zero network calls), plus `skill-installer` delegation for Codex and `skills.urls` catalogs for OpenCode. |
| **v0.5** | The rich argument composer with per-plugin command tables, remembered argument sets, and multi-skill stacking (`/a /b <args>`, which Claude Code supports for up to six). |
| **Never in v0.1** | Any write to `~/.claude.json`. Any deletion of a plugin cache directory — Claude Code refcounts in-use versions with PID files under `<version>/.in_use/`, and uninstall must go through `claude plugin uninstall`. Any write into `~/.codex/skills/.system/`, which Codex `remove_dir_all`s and rewrites from its embedded copy after every upgrade. |

---

# 14. Repo, testing and marketplace posture

```
manifest.json  README.md  LICENSE  preview.png  .gitignore  dev-sync.sh
BarWidget.qml  Panel.qml  ListView.qml  DetailView.qml  CreateSheet.qml
ArgumentSheet.qml  ProjectSheet.qml  ItemRow.qml  GroupHeader.qml  ChoiceSheet.qml
lib/{Model,Taxonomy,Palette,Invocation,Presentation}.js      # .pragma library, pure
bin/{agent-ext,agent-ext-git,safe-read,safe-write,jsonc-edit}
tests/  docs/  .github/workflows/ci.yml
```

`lib/*.js` are pure ES5-style with a `module.exports` guard so QML `import`s them and `node --test` requires them, with **zero** npm dependencies and no `package.json`. Every one carries `.pragma library` — without it each importing document gets its own copy, which for a 75 KB file across virtualised delegates is real memory.

**Four test layers**, all headless: `node --test tests/` over the pure model; `python3 -m unittest` over the helper against a fixture `HOME` in a tmpdir, one test per row of the failure matrix; a hardening suite where each security property is an executable test (a planted symlink store leaves the victim untouched, a FIFO is refused without stalling, a killed two-file write leaves nothing half-applied, canaries minted per run so a checkout under `TMPDIR` is not reported as a leak); and an offscreen smoke test — `QT_QPA_PLATFORM=offscreen quickshell -p tests/Headless.qml` with a fake `HOME` and a stub helper on `PATH`, skipping cleanly when quickshell is absent. Plus `bash -n`, non-fatal `shellcheck -S warning`, filtered non-fatal `qmllint -I "$OMARCHY_PATH/shell"`, and `jq` manifest assertions mirroring `omarchy-plugin-validate` exactly — including `find . -path ./.git -prune -o -type l -print` returning empty.

`test/run.sh` sha256s the user's real `~/.claude/settings.json`, `~/.claude.json`, `~/.config/opencode/opencode.json` and `~/.codex/config.toml` before and after, and fails if any moved. The user already does this for one config; here it guards four, and two of them hold OAuth material.

**Marketplace posture: aim for `passed`.** That means no install command anywhere in the repo — the scanner reads the root README's ```bash fences *and* `.github/workflows/*.yml`, and an `apt-get install shellcheck` in CI already cost this user a capability once. Anything genuinely needed goes under a `## Development` heading, which the scanner skips. No file named `install*`, `setup*` or `uninstall*` — the name alone trips the `installer` capability, and a setup-named binary asset fails closed. No `.service` file, no `systemctl`, no bundled binary, no `__pycache__` (set `sys.dont_write_bytecode = True` in the helpers). Say "No sudo or pkexec is required" explicitly, twice — the policy excludes clearly-negated documentation from the `privilege` capability, and it is free. A `passed` baseline publishes automatically as Verified and unlocks `installation.mode: standard`, which is a real discoverability difference from the `manual-setup` note the user's network-usage listing carries.

The submission body is the six-heading form byte-exact, title `[Plugin]: Agent Skills Manager`, category `Developer Tools`, tags `ai, quickshell, bar`, and Maintainer notes that pre-declare every capability the scanner will find and enumerate what the plugin writes, at what mode, and what it reads. Pre-declaring is what turns a ten-hour review into a smooth one. During review, push exactly one commit and then stop — approval binds to an exact 40-character SHA, and a moving HEAD is the sixth most common machine rejection.
