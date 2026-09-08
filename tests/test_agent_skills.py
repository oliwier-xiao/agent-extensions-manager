"""Unit tests for the parts of agent-skills that do not touch this machine's config.

Run: python3 -m unittest discover -s tests -v
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load():
    spec = importlib.util.spec_from_loader("agent_skills", None)
    mod = importlib.util.module_from_spec(spec)
    mod.__dict__["__name__"] = "agent_skills"
    with open(os.path.join(ROOT, "bin", "agent-skills"), encoding="utf-8") as fh:
        exec(compile(fh.read(), "agent-skills", "exec"), mod.__dict__)  # noqa: S102
    return mod


ax = load()


def scan_with_home(build):
    """Run a whole scan against a throwaway HOME the caller has just filled.

    The walk is the one part of this program that meets a stranger's
    filesystem, so the cases below are worth running end to end rather than
    against a helper: what used to break was scan() itself, and what it cost
    was every row on the panel rather than the one row at fault.
    """
    d = tempfile.mkdtemp()
    try:
        build(d)
        saved_home, saved_store = ax.HOME, ax.STORE_PATH
        try:
            ax.HOME = d
            ax.STORE_PATH = os.path.join(d, "categories.json")
            return ax.scan()
        finally:
            ax.HOME, ax.STORE_PATH = saved_home, saved_store
    finally:
        # A directory a test made unreadable has to be handed back before the
        # tree can be removed.
        for base, dirs, _ in os.walk(d):
            for name in dirs:
                os.chmod(os.path.join(base, name), 0o700)
        shutil.rmtree(d, ignore_errors=True)


def write_skill(root, name, description="One skill, for the walk to find."):
    os.makedirs(os.path.join(root, name), exist_ok=True)
    with open(os.path.join(root, name, "SKILL.md"), "w", encoding="utf-8") as fh:
        fh.write(f"---\nname: {name}\ndescription: {description}\n---\nbody\n")


class ClaudeOverrideKey(unittest.TestCase):
    """Claude Code reads `overrides[name] ?? overrides[unqualifiedName]`, so a
    skill answers to two keys. Reading only one of them reports a state the agent
    does not have -- on the very field the panel invites you to go and check."""

    def _state(self, home, dir_name):
        def build(d):
            root = os.path.join(d, ".claude", "skills")
            os.makedirs(os.path.join(root, dir_name), exist_ok=True)
            with open(os.path.join(root, dir_name, "SKILL.md"), "w", encoding="utf-8") as fh:
                fh.write("---\nname: design-taste-frontend\ndescription: A skill.\n---\nbody\n")
            os.makedirs(os.path.join(d, ".claude"), exist_ok=True)
            with open(os.path.join(d, ".claude", "settings.json"), "w", encoding="utf-8") as fh:
                json.dump({"skillOverrides": home}, fh)
        result = scan_with_home(build)
        item = next(i for i in result["items"] if i["dirName"] == dir_name)
        return item["state"]["claude"]["value"]

    def test_an_override_under_the_directory_name_is_read(self):
        self.assertEqual(self._state({"taste-skill": "off"}, "taste-skill"), "off")

    def test_an_override_under_the_declared_name_is_read(self):
        # The case that used to be invisible: the directory is `taste-skill` and
        # the SKILL.md declares `design-taste-frontend`.
        self.assertEqual(self._state({"design-taste-frontend": "off"}, "taste-skill"), "off")

    def test_the_declared_name_wins_the_way_it_does_in_the_agent(self):
        self.assertEqual(
            self._state({"design-taste-frontend": "name-only", "taste-skill": "off"}, "taste-skill"),
            "name-only")

    def test_no_override_is_still_on(self):
        self.assertEqual(self._state({}, "taste-skill"), "on")


class MountsAreAddressable(unittest.TestCase):
    """Every mount carries the absolute path it was found at. `path` is a display
    string with a `~` in it, and re-expanding one on the far side to build an
    argument for a destructive command is how something gets removed that nobody
    pointed at."""

    def test_a_skill_reached_from_a_second_root_keeps_abs_on_both(self):
        def build(d):
            claude = os.path.join(d, ".claude", "skills")
            agents = os.path.join(d, ".agents", "skills")
            write_skill(claude, "shared")
            os.makedirs(agents, exist_ok=True)
            os.symlink(os.path.join(claude, "shared"), os.path.join(agents, "shared"))
        result = scan_with_home(build)
        item = next(i for i in result["items"] if i["dirName"] == "shared")
        self.assertGreater(len(item["mounts"]), 1, item["mounts"])
        for m in item["mounts"]:
            self.assertIn("abs", m, m)
            self.assertTrue(m["abs"].startswith("/"), m)


class FetchedSkillsAreCounted(unittest.TestCase):
    """OpenCode's `skills.urls` fetches skills over HTTP and caches them under
    ~/.cache/opencode/skills. They are loaded and charged for like any other, so
    leaving the cache out understates the one figure this widget prints."""

    def test_a_cached_skill_counts_against_opencode(self):
        def build(d):
            write_skill(os.path.join(d, ".cache", "opencode", "skills"), "security-review")
        result = scan_with_home(build)
        item = next(i for i in result["items"] if i["dirName"] == "security-review")
        self.assertEqual(item["tools"], ["opencode"])
        self.assertEqual(item["scope"], "fetched")
        self.assertGreater(result["counts"]["alwaysOnTokens"].get("opencode", 0), 0)

    def test_it_is_not_hidden_as_a_builtin(self):
        # `showBundled` is off by default. A fetched skill that read as bundled
        # would vanish from the default view and take its cost with it.
        def build(d):
            write_skill(os.path.join(d, ".cache", "opencode", "skills"), "security-review")
        result = scan_with_home(build)
        item = next(i for i in result["items"] if i["dirName"] == "security-review")
        self.assertFalse(item["flags"]["builtin"], item["flags"])


class Frontmatter(unittest.TestCase):
    def test_plain_scalar(self):
        fm = ax.parse_frontmatter_block("name: api-design\ndescription: REST patterns.")
        self.assertEqual(fm["name"], "api-design")
        self.assertEqual(fm["description"], "REST patterns.")

    def test_block_scalar_is_not_lost(self):
        """A line-oriented regex reports these skills as costing 2 tokens."""
        fm = ax.parse_frontmatter_block("name: omarchy\ndescription: >\n  First line.\n  Second line.")
        self.assertEqual(fm["description"], "First line. Second line.")

    def test_literal_block_keeps_newlines(self):
        fm = ax.parse_frontmatter_block("description: |\n  one\n  two")
        self.assertEqual(fm["description"], "one\ntwo")

    def test_every_block_header_yaml_allows_is_a_header(self):
        """The chomping indicator and the indentation indicator, in either order.
        Knowing only the first read `description: >2` as the literal text
        ">2 First line. Second line." -- the indicator inside the description
        every agent loads."""
        for header in (">", "|", ">-", "|-", ">+", "|+",
                       ">2", "|2", ">-2", "|-2", ">+2", "|+2", ">2-", "|2+"):
            block = f"description: {header}\n  First line.\n  Second line."
            self.assertEqual(ax.parse_frontmatter_block(block)["description"].replace("\n", " "),
                             "First line. Second line.", header)

    def test_an_indentation_indicator_says_which_columns_are_layout(self):
        # With one, exactly that many columns come off and what is left is the
        # author's text, so a line they indented further keeps the difference.
        fm = ax.parse_frontmatter_block("description: |2\n  one\n    two")
        self.assertEqual(fm["description"], "one\n  two")

    def test_continuation_lines_are_joined(self):
        fm = ax.parse_frontmatter_block("description: starts here\n  and continues\nname: x")
        self.assertEqual(fm["description"], "starts here and continues")
        self.assertEqual(fm["name"], "x")

    def test_nested_mapping(self):
        fm = ax.parse_frontmatter_block("metadata:\n  origin: ECC\n  other: 1")
        self.assertEqual(fm["metadata"], {"origin": "ECC", "other": "1"})

    def test_quotes_are_stripped(self):
        self.assertEqual(ax.parse_frontmatter_block('name: "quoted"')["name"], "quoted")

    def test_no_frontmatter(self):
        self.assertEqual(ax.parse_frontmatter("# just markdown"), {})


class Tokens(unittest.TestCase):
    def test_matches_javascript_half_up_rounding(self):
        """latex-engineer lands on exactly 66.5; Claude Code shows 67, not 66."""
        name, desc = "x" * 10, "y" * 255
        self.assertEqual(len(f"{name} {desc}"), 266)
        self.assertEqual(ax.token_estimate(name, desc, "", 4), 67)

    def test_divisor_three(self):
        self.assertEqual(ax.token_estimate("a" * 30, "", "", 3), 10)

    def test_empty_parts_are_skipped(self):
        self.assertEqual(ax.token_estimate("abcd", "", "", 4), 1)


class Classifier(unittest.TestCase):
    def test_negative_rule_keeps_api_design_out_of_design(self):
        got = ax.classify("api-design", "REST API design patterns including resource naming.",
                          "/s/api-design", None)
        self.assertNotEqual(got["category"], "design")

    def test_marketplace_category_wins(self):
        got = ax.classify("whatever", "", "/s/whatever", "database")
        self.assertEqual(got["category"], "data")
        self.assertEqual(got["confidence"], "high")

    def test_n8n_path_heuristic(self):
        got = ax.classify("n8n-agents", "", "/s/n8n-agents", None)
        self.assertEqual(got["category"], "automation")

    def test_unmatched_waits_on_the_unsorted_shelf(self):
        # It used to fall to `agents`, which was the residual bucket and a lie:
        # a skill that matched nothing is not an agents skill, it is an unfiled
        # one, and putting it there both hid it and made that shelf untrustworthy.
        got = ax.classify("zzz", "qqq", "/s/zzz", None)
        self.assertEqual(got["category"], "unsorted")
        self.assertEqual(got["confidence"], "unclassified")

    def test_agents_is_a_real_shelf_and_still_loses_ties(self):
        # `agents` keeps its own rule and still sits last in RULES so it loses a
        # tie, which is what stopped an n8n skill classifying as agents.
        self.assertIn("agents", ax.CATEGORIES)
        order = [cat for cat, _, _ in ax.RULES]
        self.assertEqual(order[-1], "agents")
        self.assertNotIn("unsorted", order)

    def test_a_thin_guess_is_kept_rather_than_dumped(self):
        # Low confidence means the evidence was thin, not that it was wrong: on
        # the machine this was written for, four of the five low-confidence
        # placements were correct. Routing them all to `unsorted` would break
        # four to fix one, so they keep their shelf and the panel offers a
        # one-click correction instead.
        got = ax.classify("test-driven-development",
                          "Use when implementing any feature or bugfix", "/s/tdd", None)
        self.assertNotEqual(got["category"], "unsorted")

    def test_every_category_has_a_glyph(self):
        for cat in ax.CATEGORIES:
            self.assertIn(cat, ax.GLYPH)

    def test_official_map_targets_are_real_categories(self):
        for target in ax.OFFICIAL_MAP.values():
            self.assertIn(target, ax.CATEGORIES)


class RunningAgents(unittest.TestCase):
    """The bar prints the figure for the agent that is up, so being wrong about
    which one is up is being wrong about the number."""

    def _fake_proc(self, comms):
        root = tempfile.mkdtemp()
        for pid, comm in comms.items():
            os.mkdir(os.path.join(root, str(pid)))
            with open(os.path.join(root, str(pid), "comm"), "w", encoding="utf-8") as fh:
                fh.write(comm + "\n")
        # Not a pid, and must be skipped rather than opened.
        os.mkdir(os.path.join(root, "self"))
        return root

    def _run(self, root):
        real = os.listdir
        os.listdir = lambda p: real(root) if p == "/proc" else real(p)
        realopen = open
        def patched(path, *a, **k):
            if isinstance(path, str) and path.startswith("/proc/"):
                return realopen(os.path.join(root, path[len("/proc/"):]), *a, **k)
            return realopen(path, *a, **k)
        ax.__dict__["open"] = patched
        try:
            return ax.running_agents()
        finally:
            os.listdir = real
            ax.__dict__.pop("open", None)

    def test_reports_only_the_agents_that_are_up(self):
        live = self._run(self._fake_proc({11: "opencode", 12: "bash", 13: "Xwayland"}))
        self.assertEqual(live, {"claude": False, "opencode": True, "codex": False})

    def test_reports_several_at_once(self):
        live = self._run(self._fake_proc({7: "claude", 8: "codex", 9: "node"}))
        self.assertTrue(live["claude"] and live["codex"])
        self.assertFalse(live["opencode"])

    def test_a_name_that_merely_contains_an_agent_is_not_one(self):
        live = self._run(self._fake_proc({21: "claude-helper", 22: "myopencode"}))
        self.assertEqual(live, {"claude": False, "opencode": False, "codex": False})

    def test_no_proc_at_all_is_none_rather_than_an_exception(self):
        real = os.listdir
        os.listdir = lambda p: (_ for _ in ()).throw(OSError(2, "no /proc")) if p == "/proc" else real(p)
        try:
            self.assertEqual(ax.running_agents(),
                             {"claude": False, "opencode": False, "codex": False})
        finally:
            os.listdir = real

    def test_a_pid_that_vanishes_mid_read_is_skipped(self):
        root = self._fake_proc({31: "claude"})
        os.remove(os.path.join(root, "31", "comm"))
        self.assertEqual(self._run(root),
                         {"claude": False, "opencode": False, "codex": False})


class SafeRead(unittest.TestCase):
    def test_refuses_a_symlink_at_the_final_component(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "real")
            with open(real, "w", encoding="utf-8") as fh:
                fh.write("secret")
            link = os.path.join(d, "link")
            os.symlink(real, link)
            self.assertEqual(ax.safe_read(real), b"secret")
            self.assertIsNone(ax.safe_read(link))

    def test_refuses_an_oversized_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "big")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write("x" * 100)
            self.assertIsNone(ax.safe_read(p, max_bytes=10))

    def test_missing_file_is_none_not_an_exception(self):
        self.assertIsNone(ax.safe_read("/nonexistent/nope"))

    def test_directory_is_refused(self):
        self.assertIsNone(ax.safe_read("/tmp"))


class Drift(unittest.TestCase):
    def _item(self, name, digest):
        return {"dirName": name, "contentHash": digest, "realPath": "/" + name + digest,
                "attention": []}

    def test_same_name_different_bytes_is_flagged(self):
        items = [self._item("omarchy", "a"), self._item("omarchy", "b")]
        ax._mark_drift(items)
        self.assertTrue(all("drift" in i["attention"] for i in items))
        self.assertEqual(len(items[0]["driftPeers"]), 1)

    def test_same_name_same_bytes_is_not_flagged(self):
        items = [self._item("omarchy", "a"), self._item("omarchy", "a")]
        ax._mark_drift(items)
        self.assertFalse(any("drift" in i["attention"] for i in items))

    def test_unique_name_is_not_flagged(self):
        items = [self._item("solo", "a")]
        ax._mark_drift(items)
        self.assertEqual(items[0]["attention"], [])


class Roots(unittest.TestCase):
    def test_opencode_sees_claude_and_agents_by_default(self):
        os.environ.pop("OPENCODE_DISABLE_EXTERNAL_SKILLS", None)
        roots = {r["path"].split("/")[-2] + "/" + r["path"].split("/")[-1]: r for r in ax.skill_roots()}
        claude = next(r for r in ax.skill_roots() if r["path"].endswith(".claude/skills"))
        self.assertIn("opencode", claude["tools"])

    def test_the_env_var_takes_opencode_out(self):
        os.environ["OPENCODE_DISABLE_EXTERNAL_SKILLS"] = "1"
        try:
            claude = next(r for r in ax.skill_roots() if r["path"].endswith(".claude/skills"))
            self.assertNotIn("opencode", claude["tools"])
        finally:
            os.environ.pop("OPENCODE_DISABLE_EXTERNAL_SKILLS", None)

    def test_claude_never_reads_the_shared_agents_dir(self):
        shared = next(r for r in ax.skill_roots() if r["path"].endswith(".agents/skills"))
        self.assertNotIn("claude", shared["tools"])


class InvalidYaml(unittest.TestCase):
    def test_bare_colon_in_a_plain_scalar_is_flagged(self):
        self.assertTrue(ax.has_unquoted_colon("description: Triggers on: n8n, workflows"))

    def test_quoted_scalar_may_contain_a_colon(self):
        self.assertFalse(ax.has_unquoted_colon('description: "Triggers on: n8n"'))

    def test_block_scalar_may_contain_a_colon(self):
        self.assertFalse(ax.has_unquoted_colon("description: >\n  Triggers on: n8n"))

    def test_ordinary_frontmatter_is_clean(self):
        self.assertFalse(ax.has_unquoted_colon("name: x\ndescription: A normal one."))

    def test_we_still_read_the_invalid_file(self):
        fm = ax.parse_frontmatter_block("description: Triggers on: n8n, workflows")
        self.assertEqual(fm["description"], "Triggers on: n8n, workflows")


class TieBreak(unittest.TestCase):
    def test_agents_loses_a_tie_to_a_real_domain(self):
        """A router skill for n8n names skills and MCP often enough to tie."""
        desc = ("Use when building, editing or debugging an n8n workflow through the n8n-mcp "
                "MCP server. The entry-point skill for the pack; routes you to the right "
                "specialist skill on any n8n, workflow, node or automation task.")
        got = ax.classify("using-n8n-mcp-skills", desc, "/s/using-n8n-mcp-skills", None)
        self.assertEqual(got["category"], "automation")

    def test_agents_still_wins_when_it_is_alone(self):
        got = ax.classify("prompt-lab", "Prompt and eval tooling for subagent tool use.",
                          "/s/prompt-lab", None)
        self.assertEqual(got["category"], "agents")


class AdversarialReads(unittest.TestCase):
    """The cases the marketplace reviewer names explicitly. Each one used to take
    the helper down with a traceback and an empty stdout."""

    def test_a_fifo_does_not_block_the_shell(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "fifo")
            os.mkfifo(p)
            self.assertIsNone(ax.safe_read(p))

    def test_a_hard_linked_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "real")
            with open(real, "w", encoding="utf-8") as fh:
                fh.write("x")
            os.link(real, os.path.join(d, "second-name"))
            self.assertIsNone(ax.safe_read(real))

    def test_a_world_writable_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "loose")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write("x")
            os.chmod(p, 0o666)
            self.assertIsNone(ax.safe_read(p))

    def test_deeply_nested_json_is_a_finding_not_a_crash(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "deep.json")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write("[" * 200000 + "]" * 200000)
            value, err = ax.read_json(p)
            self.assertIsNone(value)
            self.assertIsInstance(err, str)

    def test_a_config_value_of_the_wrong_type_does_not_raise(self):
        self.assertEqual(ax.as_dict("a string"), {})
        self.assertEqual(ax.as_dict(None), {})
        self.assertEqual(ax.as_list({"not": "a list"}), [])

    def test_control_characters_are_stripped_before_they_reach_qml(self):
        self.assertEqual(ax.clip("a\x00b\x1bc"), "abc")

    def test_long_strings_are_capped(self):
        self.assertEqual(len(ax.clip("x" * 5000, 100)), 100)


class Redaction(unittest.TestCase):
    def test_an_api_key_flag_is_masked(self):
        self.assertNotIn("sk-live-DEADBEEF", ax.redact("npx pkg --api-key sk-live-DEADBEEF"))

    def test_a_url_query_string_is_dropped(self):
        self.assertEqual(ax.redact("https://h/mcp?token=abc"), "https://h/mcp?…")

    def test_an_env_assignment_is_masked(self):
        self.assertNotIn("sk-proj-XYZ", ax.redact("docker run -e OPENAI_API_KEY=sk-proj-XYZ img"))

    def test_a_benign_command_is_left_alone(self):
        cmd = "npx -y @modelcontextprotocol/server-filesystem /home/me"
        self.assertEqual(ax.redact(cmd), cmd)

    def test_a_secret_with_a_space_in_it_does_not_survive(self):
        # Every case above uses a secret with no whitespace in it, which is how
        # a rule that stopped at the next space passed for years. A header is
        # one argument and is routinely written with spaces in it.
        got = ax.redact_argv(["npx", "srv", "--header", "X-Api-Key: one two three"])
        self.assertNotIn("one", got)
        self.assertNotIn("three", got)

    def test_a_flag_and_its_value_are_two_arguments(self):
        got = ax.redact_argv(["npx", "srv", "--api-key", "sk live DEADBEEF"])
        self.assertNotIn("DEADBEEF", got)
        self.assertIn("--api-key", got)

    def test_url_userinfo_is_a_credential_too(self):
        got = ax.redact("https://someone:hunter2@host/mcp")
        self.assertNotIn("hunter2", got)
        self.assertNotIn("someone", got)
        self.assertIn("host", got)

    def test_a_token_in_the_path_is_removed(self):
        # Several hosted endpoints carry their key as a path segment rather than
        # in the query string, where dropping everything after `?` never saw it.
        got = ax.redact("https://host/mcp/eyJhbGciOiJIUzI1NiJ9abcdefghijkl")
        self.assertNotIn("eyJhbGciOiJIUzI1NiJ9abcdefghijkl", got)
        self.assertIn("/mcp/", got)

    def test_a_uuid_in_the_path_is_removed(self):
        got = ax.redact("https://host/v1/3f2b8c1e-4a5b-6c7d-8e9f-0a1b2c3d4e5f/sse")
        self.assertNotIn("3f2b8c1e", got)
        self.assertTrue(got.endswith("/sse"), got)

    def test_a_long_route_is_not_mistaken_for_a_token(self):
        url = "https://mcp.example.com/streamable-http/messages"
        self.assertEqual(ax.redact(url), url)

    def test_a_url_inside_a_command_is_cleaned_where_it_sits(self):
        got = ax.redact_argv(["npx", "mcp-remote", "https://me:pw@host/sse?k=1"])
        self.assertNotIn("pw", got)
        self.assertNotIn("k=1", got)
        self.assertIn("npx mcp-remote", got)

    def test_an_unparseable_target_is_not_an_exception(self):
        self.assertEqual(ax.redact("http://[oops/mcp"), "\u2026")

    def test_argv_that_is_not_strings_is_not_an_exception(self):
        self.assertIsInstance(ax.redact_argv([None, 12, {"a": 1}]), str)


class ArgumentHint(unittest.TestCase):
    IMPECCABLE = ("[craft|shape · audit|critique · animate|bolder|colorize|delight|"
                  "layout|overdrive|quieter|typeset · adapt|clarify|distill · "
                  "harden|onboard|optimize|polish · init|document|extract|live] [target]")

    def test_impeccable_yields_every_action_it_documents(self):
        args = ax.parse_argument_hint(self.IMPECCABLE)
        self.assertEqual(args[0]["kind"], "choice")
        # The plugin's own manifest says 23 commands; the hint has to agree.
        self.assertEqual(len(args[0]["options"]), 23)
        self.assertIn("typeset", args[0]["options"])
        self.assertIn("polish", args[0]["options"])

    def test_the_dot_separates_alternatives_as_much_as_the_bar(self):
        args = ax.parse_argument_hint("[a|b · c]")
        self.assertEqual(args[0]["options"], ["a", "b", "c"])

    def test_trailing_placeholder_is_a_value_not_a_choice(self):
        args = ax.parse_argument_hint(self.IMPECCABLE)
        self.assertEqual(args[1], {"kind": "value", "label": "target"})

    def test_a_hint_with_no_alternatives_offers_no_menu(self):
        # "[filename] [format]" is two things to type, not a list to pick from.
        self.assertEqual(ax.parse_argument_hint("[filename] [format]"), [])
        self.assertEqual(ax.parse_argument_hint("[issue-number]"), [])

    def test_unbracketed_alternatives_still_count(self):
        self.assertEqual(ax.parse_argument_hint("add|remove|list")[0]["options"],
                         ["add", "remove", "list"])

    def test_prose_is_not_mistaken_for_options(self):
        self.assertEqual(ax.parse_argument_hint("Describe what you want"), [])

    def test_angle_brackets_read_the_same_as_square_ones(self):
        self.assertEqual(ax.parse_argument_hint("<on|off|status>")[0]["options"],
                         ["on", "off", "status"])

    def test_wrong_types_and_empty_values_are_not_errors(self):
        for bad in (None, 123, [], {}, "", "   ", True):
            self.assertEqual(ax.parse_argument_hint(bad), [])

    def test_duplicates_collapse_and_the_first_position_wins(self):
        self.assertEqual(ax.parse_argument_hint("[a|a|b]")[0]["options"], ["a", "b"])

    def test_a_hostile_hint_cannot_grow_without_bound(self):
        huge = "[" + "|".join("opt%d" % i for i in range(500)) + "]"
        args = ax.parse_argument_hint(huge)
        self.assertLessEqual(len(args[0]["options"]), ax.MAX_ARG_OPTIONS)

    def test_nothing_shaped_like_a_command_survives(self):
        # Whatever is offered gets appended to an invocation and pasted into a
        # prompt, so the guarantee is on the shape of every token: word
        # characters, dots, dashes and underscores, nothing else. `rm -rf /`
        # carries a space and a slash, `$(id)` and `a;b` carry metacharacters,
        # and none of them survive. A backtick-quoted word does, stripped of its
        # markdown, because that is what its author wrote it to mean.
        args = ax.parse_argument_hint("[safe|rm -rf /|$(id)|a;b|`polish`|ok]")
        self.assertEqual(args[0]["options"], ["safe", "polish", "ok"])
        for token in args[0]["options"]:
            self.assertRegex(token, r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

    def test_groups_are_capped(self):
        many = " ".join("[a%d|b%d]" % (i, i) for i in range(40))
        self.assertLessEqual(len(ax.parse_argument_hint(many)), ax.MAX_ARG_GROUPS)


class CategoryStore(unittest.TestCase):
    """The one thing this program writes, so the shape of what it will accept
    matters more here than anywhere else in the file."""

    def test_a_name_is_lower_case_words_and_dashes(self):
        for good in ("ui", "video", "next-js", "seo2", "a" * 24):
            self.assertRegex(good, ax.CATEGORY_NAME)
        for bad in ("UI", "1st", "", "a" * 25, "with space", "semi;colon", "../etc"):
            self.assertNotRegex(bad, ax.CATEGORY_NAME)

    def test_a_colour_is_a_hex_triple_and_nothing_else(self):
        self.assertRegex("#7AA2F7", ax.HEX_COLOR)
        for bad in ("red", "#fff", "#7AA2F7X", "rgb(1,2,3)", "url(x)", ""):
            self.assertNotRegex(bad, ax.HEX_COLOR)

    def test_a_label_is_one_line(self):
        self.assertRegex("UI", ax.CATEGORY_LABEL)
        self.assertNotRegex("two\nlines", ax.CATEGORY_LABEL)
        self.assertNotRegex("", ax.CATEGORY_LABEL)

    def test_a_store_of_the_wrong_shape_reads_as_an_empty_one(self):
        # read_store is handed whatever is on disk. Anything it cannot vouch for
        # is dropped field by field rather than failing the whole scan.
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "categories.json")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write('{"custom": ["ok", "BAD", 7], "assign": {"s": "ok", "t": "NO"},'
                         ' "labels": {"ok": "Fine", "BAD": "x"},'
                         ' "colors": {"ok": "#ABCDEF", "ok2": "red"}}')
            saved = ax.STORE_PATH
            try:
                ax.STORE_PATH = path
                store = ax.read_store()
            finally:
                ax.STORE_PATH = saved
        self.assertEqual(store["custom"], ["ok"])
        self.assertEqual(store["assign"], {"s": "ok"})
        self.assertEqual(store["labels"], {"ok": "Fine"})
        self.assertEqual(store["colors"], {"ok": "#ABCDEF"})

    def test_a_missing_store_is_not_an_error(self):
        saved = ax.STORE_PATH
        try:
            ax.STORE_PATH = "/nonexistent/agent-skills/categories.json"
            store = ax.read_store()
        finally:
            ax.STORE_PATH = saved
        self.assertEqual(store, {"custom": [], "assign": {}, "labels": {}, "colors": {}})

    def test_custom_categories_are_appended_after_the_built_in_ones(self):
        known = ax.known_categories({"custom": ["ui"]})
        self.assertEqual(known[:len(ax.CATEGORIES)], list(ax.CATEGORIES))
        self.assertEqual(known[-1], "ui")

    def test_a_custom_category_gets_its_own_glyph(self):
        # GLYPH covers the built-ins only, and a KeyError here would abort a scan.
        self.assertEqual(ax.GLYPH.get("ui", ax.CUSTOM_GLYPH), ax.CUSTOM_GLYPH)
        for cat in ax.CATEGORIES:
            self.assertIn(cat, ax.GLYPH)

    def test_a_write_replaces_the_file_whole(self):
        with tempfile.TemporaryDirectory() as d:
            saved_dir, saved_path = ax.STORE_DIR, ax.STORE_PATH
            try:
                ax.STORE_DIR = os.path.join(d, "agent-skills")
                ax.STORE_PATH = os.path.join(ax.STORE_DIR, "categories.json")
                ax.write_store({"custom": ["ui"], "assign": {"a": "ui"},
                                "labels": {}, "colors": {}})
                ax.write_store({"custom": [], "assign": {},
                                "labels": {}, "colors": {}})
                with open(ax.STORE_PATH, encoding="utf-8") as fh:
                    written = json.load(fh)
                leftovers = [n for n in os.listdir(ax.STORE_DIR) if ".tmp." in n]
            finally:
                ax.STORE_DIR, ax.STORE_PATH = saved_dir, saved_path
        self.assertEqual(written["custom"], [])
        self.assertEqual(written["assign"], {})
        self.assertEqual(written["version"], 1)
        self.assertEqual(leftovers, [])


class PluginSkillRoots(unittest.TestCase):
    """A plugin's own skills. They were invisible: the panel listed the plugin as
    one row and never opened it, so on a machine where a skill is installed as a
    plugin rather than copied into ~/.claude/skills, its documented actions did
    not exist as far as this program was concerned."""

    def roots(self, doc):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, ".claude", "plugins"))
            p = os.path.join(d, ".claude", "plugins", "installed_plugins.json")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(doc)
            saved = ax.HOME
            try:
                ax.HOME = d
                return ax.plugin_skill_roots()
            finally:
                ax.HOME = saved

    def test_the_recorded_install_path_is_used_verbatim(self):
        # Not the highest version directory in the cache: several can sit there
        # and only the recorded one is the version Claude Code actually loaded.
        roots = self.roots('{"version":2,"plugins":{"impeccable@impeccable":['
                           '{"scope":"user","installPath":"/x/cache/impeccable/impeccable/4.1.1"}]}}')
        self.assertEqual(len(roots), 1)
        self.assertEqual(roots[0]["path"], "/x/cache/impeccable/impeccable/4.1.1/skills")
        self.assertEqual(roots[0]["plugin"], "impeccable")
        self.assertEqual(roots[0]["scope"], "user")

    def test_only_claude_sees_them(self):
        # OpenCode reads ~/.claude/skills natively; it does not read another
        # agent's plugin cache.
        roots = self.roots('{"plugins":{"a@m":[{"installPath":"/x/a"}]}}')
        self.assertEqual(roots[0]["tools"], ["claude"])

    def test_the_namespace_is_the_plugin_not_the_marketplace(self):
        # The id is `plugin@marketplace` and Claude Code addresses the skill as
        # `/plugin:skill`, so the half before the @ is the one that matters.
        roots = self.roots('{"plugins":{"superpowers@claude-plugins-official":'
                           '[{"installPath":"/x/sp"}]}}')
        self.assertEqual(roots[0]["plugin"], "superpowers")

    def test_a_relative_or_missing_install_path_is_refused(self):
        for doc in ('{"plugins":{"a@m":[{"installPath":"relative/path"}]}}',
                    '{"plugins":{"a@m":[{"installPath":123}]}}',
                    '{"plugins":{"a@m":[{}]}}',
                    '{"plugins":{"a@m":"not a list"}}'):
            self.assertEqual(self.roots(doc), [], doc)

    def test_a_plugin_name_that_is_not_a_bare_word_is_refused(self):
        # The name is interpolated into an invocation that lands in a prompt.
        for bad in ("../etc@m", "a b@m", "$(id)@m", "@m"):
            doc = '{"plugins":{"%s":[{"installPath":"/x/a"}]}}' % bad
            self.assertEqual(self.roots(doc), [], bad)

    def test_no_plugins_file_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as d:
            saved = ax.HOME
            try:
                ax.HOME = d
                self.assertEqual(ax.plugin_skill_roots(), [])
            finally:
                ax.HOME = saved

    def test_a_malformed_plugins_file_is_not_an_error(self):
        self.assertEqual(self.roots("{not json"), [])
        self.assertEqual(self.roots("[]"), [])


class DriftVersusVariant(unittest.TestCase):
    """Two copies of one name are not automatically a fault. Impeccable ships one
    release compiled per harness on purpose, so the declared version decides."""

    def rec(self, name, digest, version=None, attention=None):
        return {"dirName": name, "contentHash": digest, "realPath": "/p/" + digest,
                "declaredVersion": version, "attention": list(attention or [])}

    def test_same_version_different_build_is_not_drift(self):
        items = [self.rec("impeccable", "a", "4.1.1"), self.rec("impeccable", "b", "4.1.1")]
        ax._mark_drift(items)
        for it in items:
            self.assertNotIn("drift", it["attention"])
            self.assertIn("variantPeers", it)
            self.assertNotIn("driftPeers", it)

    def test_a_different_version_is_drift(self):
        items = [self.rec("impeccable", "a", "4.1.1"), self.rec("impeccable", "b", "4.0.4")]
        ax._mark_drift(items)
        for it in items:
            self.assertIn("drift", it["attention"])
            self.assertIn("driftPeers", it)

    def test_no_declared_version_falls_back_to_content(self):
        # Most hand-written skills declare no version, and for those a content
        # difference is the only signal there is. omarchy is the live case.
        items = [self.rec("omarchy", "a"), self.rec("omarchy", "b")]
        ax._mark_drift(items)
        for it in items:
            self.assertIn("drift", it["attention"])

    def test_one_side_missing_a_version_is_still_drift(self):
        items = [self.rec("x", "a", "1.0"), self.rec("x", "b", None)]
        ax._mark_drift(items)
        for it in items:
            self.assertIn("drift", it["attention"])

    def test_identical_content_is_neither(self):
        items = [self.rec("x", "same", "1.0"), self.rec("x", "same", "1.0")]
        ax._mark_drift(items)
        for it in items:
            self.assertEqual(it["attention"], [])
            self.assertNotIn("variantPeers", it)
            self.assertNotIn("driftPeers", it)

    def test_a_version_under_metadata_counts_as_declared(self):
        # Impeccable 4.1.1 puts `version:` at the top of every build; by 4.2.2 the
        # build for ~/.agents had moved it under `metadata` while the others kept
        # it at the top. Reading only the top level would see one copy with a
        # version and one without, which is exactly the shape that means drift.
        fm = ax.parse_frontmatter(
            "---\nname: impeccable\nmetadata:\n  version: 4.2.2\n---\nbody\n")
        meta = fm.get("metadata") if isinstance(fm.get("metadata"), dict) else {}
        self.assertEqual(str(fm.get("version") or meta.get("version") or ""), "4.2.2")

    def test_a_lone_copy_is_left_alone(self):
        items = [self.rec("x", "a", "1.0")]
        ax._mark_drift(items)
        self.assertEqual(items[0]["attention"], [])


class ScanWalk(unittest.TestCase):
    """A skills root holds whatever someone put there, and not all of it is a
    directory. Each case below used to end the scan with a traceback, which is
    not one bad row on the panel but no panel at all."""

    def test_a_symlink_cycle_is_a_finding_and_the_rest_still_lists(self):
        def build(d):
            root = os.path.join(d, ".claude", "skills")
            os.makedirs(root)
            os.symlink("loop", os.path.join(root, "loop"))
            write_skill(root, "ok")
        result = scan_with_home(build)
        self.assertEqual([i["dirName"] for i in result["items"]], ["ok"])
        self.assertTrue(any(f["what"].endswith("/loop") for f in result["findings"]),
                        result["findings"])

    def test_a_dangling_system_link_does_not_end_the_scan(self):
        # ~/.codex/skills/.system is the one that happens: it exists wherever
        # Codex is installed and Codex rewrites it on every launch, so it can be
        # caught mid-change by any scan the panel runs.
        def build(d):
            root = os.path.join(d, ".codex", "skills")
            os.makedirs(root)
            os.symlink(os.path.join(d, "nowhere"), os.path.join(root, ".system"))
            write_skill(root, "ok")
        result = scan_with_home(build)
        self.assertEqual([i["dirName"] for i in result["items"]], ["ok"])
        self.assertTrue(any(f["what"].endswith("/.system") for f in result["findings"]),
                        result["findings"])

    def test_a_system_link_to_a_file_does_not_end_the_scan(self):
        def build(d):
            root = os.path.join(d, ".codex", "skills")
            os.makedirs(root)
            with open(os.path.join(d, "notadir"), "w", encoding="utf-8") as fh:
                fh.write("x")
            os.symlink(os.path.join(d, "notadir"), os.path.join(root, ".system"))
            write_skill(root, "ok")
        result = scan_with_home(build)
        self.assertEqual([i["dirName"] for i in result["items"]], ["ok"])
        self.assertTrue(any(f["what"].endswith("/.system") for f in result["findings"]),
                        result["findings"])

    def test_an_unreadable_system_directory_does_not_end_the_scan(self):
        def build(d):
            root = os.path.join(d, ".codex", "skills")
            write_skill(root, "ok")
            os.mkdir(os.path.join(root, ".system"))
            os.chmod(os.path.join(root, ".system"), 0o000)
        result = scan_with_home(build)
        self.assertEqual([i["dirName"] for i in result["items"]], ["ok"])
        self.assertTrue(any(f["what"].endswith("/.system") for f in result["findings"]),
                        result["findings"])

    def test_a_healthy_system_directory_still_yields_its_skills(self):
        # The guard above must not have cost the thing it guards: a packaged
        # skill set is still read, and still reads as bundled.
        def build(d):
            root = os.path.join(d, ".codex", "skills")
            write_skill(os.path.join(root, ".system"), "packaged")
            write_skill(root, "ok")
        result = scan_with_home(build)
        items = {i["dirName"]: i for i in result["items"]}
        self.assertEqual(sorted(items), ["ok", "packaged"])
        self.assertEqual(items["packaged"]["scope"], "bundled")
        self.assertTrue(items["packaged"]["flags"]["builtin"])
        self.assertEqual(result["findings"], [])

    def test_one_bad_child_does_not_take_its_siblings_with_it(self):
        # The guard around the `.system` listing used to cover the per-child
        # test as well, so a single self-referential link raised out of the
        # whole comprehension and every healthy skill beside it disappeared --
        # blamed on a directory that had read perfectly well. Codex rewrites
        # this directory on every launch, which is exactly when a half-made
        # entry is there to be caught.
        def build(d):
            root = os.path.join(d, ".codex", "skills")
            system = os.path.join(root, ".system")
            write_skill(system, "packaged-a")
            write_skill(system, "packaged-b")
            os.symlink("loop", os.path.join(system, "loop"))
            write_skill(root, "ok")
        result = scan_with_home(build)
        self.assertEqual(sorted(i["dirName"] for i in result["items"]),
                         ["ok", "packaged-a", "packaged-b"])
        self.assertEqual([f["what"] for f in result["findings"]],
                         ["~/.codex/skills/.system/loop"], result["findings"])

    def test_a_packaged_skill_counts_against_the_same_ceiling(self):
        # MAX_ITEMS, MAX_DIR_ENTRIES and the deadline were all checked in the
        # outer loop only, which left `.system` -- the one directory a stranger's
        # package writes into -- as the only unbounded part of the walk.
        def build(d):
            root = os.path.join(d, ".codex", "skills")
            for i in range(4):
                write_skill(os.path.join(root, ".system"), "packaged%d" % i)
        saved = ax.MAX_ITEMS
        try:
            ax.MAX_ITEMS = 2
            result = scan_with_home(build)
        finally:
            ax.MAX_ITEMS = saved
        self.assertEqual(len(result["items"]), 2)
        self.assertTrue(any(f["what"] == "inventory" for f in result["findings"]),
                        result["findings"])


class RefusedReads(unittest.TestCase):
    """A file we would not read and a file that is not there are two different
    facts, and safe_read reported both as None. That is how a world-writable
    settings.json came out as `every skill is on and everything is fine`."""

    def test_a_world_writable_config_says_so(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "settings.json")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write("{}")
            os.chmod(p, 0o666)
            value, err = ax.read_json(p)
        self.assertIsNone(value)
        self.assertIn("world-writable", err)

    def test_a_config_over_the_read_cap_says_so(self):
        # An oversized ~/.claude.json took the MCP list and the usage figures
        # with it and left the panel claiming there were none.
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "claude.json")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write('{"x":"' + "y" * ax.MAX_READ + '"}')
            value, err = ax.read_json(p)
        self.assertIsNone(value)
        self.assertIn("larger than 1 MiB", err)

    def test_a_refused_store_is_reported_rather_than_forgotten(self):
        # The one file this plugin owns is the one whose loss is least visible:
        # an empty store puts every skill back under the classifier's guess,
        # which looks exactly like a machine nobody has filed anything on.
        with tempfile.TemporaryDirectory() as d:
            saved_dir, saved_path = ax.STORE_DIR, ax.STORE_PATH
            try:
                ax.STORE_DIR = d
                ax.STORE_PATH = os.path.join(d, "categories.json")
                with open(ax.STORE_PATH, "w", encoding="utf-8") as fh:
                    fh.write('{"assign": {"nextjs": "design"}}')
                os.chmod(ax.STORE_PATH, 0o666)
                findings = []
                store = ax.read_store(findings)
            finally:
                ax.STORE_DIR, ax.STORE_PATH = saved_dir, saved_path
        self.assertEqual(store["assign"], {})
        self.assertEqual([f["what"] for f in findings], ["categories.json"])
        self.assertIn("world-writable", findings[0]["detail"])

    def test_a_symlinked_config_says_so(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "real.json")
            with open(real, "w", encoding="utf-8") as fh:
                fh.write("{}")
            link = os.path.join(d, "link.json")
            os.symlink(real, link)
            value, err = ax.read_json(link)
        self.assertIsNone(value)
        self.assertIn("symlink", err)

    def test_a_toml_config_reports_the_same_way(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "config.toml")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write("[mcp_servers]\n")
            os.chmod(p, 0o666)
            value, err = ax.read_toml(p)
        self.assertIsNone(value)
        self.assertIn("world-writable", err)

    def test_an_absent_config_is_not_a_finding(self):
        # The regression guard for the whole change. Most machines have no
        # ~/.codex/config.toml and no ~/.config/opencode/opencode.json, so a
        # finding here would fire for nearly every user, every scan.
        missing = "/nonexistent/agent-skills/none"
        self.assertEqual(ax.read_json(missing + ".json"), (None, None))
        self.assertEqual(ax.read_toml(missing + ".toml"), (None, None))
        self.assertIsNone(ax.read_text(missing + ".md"))

    def test_an_empty_home_produces_no_findings_at_all(self):
        result = scan_with_home(lambda d: None)
        self.assertEqual(result["findings"], [])
        self.assertEqual(result["items"], [])

    def test_the_reason_reaches_the_panel(self):
        def build(d):
            os.makedirs(os.path.join(d, ".claude"))
            p = os.path.join(d, ".claude", "settings.json")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write('{"skillOverrides": {"x": "off"}}')
            os.chmod(p, 0o666)
        result = scan_with_home(build)
        self.assertEqual([f["what"] for f in result["findings"]], ["claude settings.json"])
        self.assertIn("world-writable", result["findings"][0]["detail"])


class CategoryAssign(unittest.TestCase):
    """A skill directory can be called `-h`, and argparse reads that as a
    request for help: it printed usage, exited 0, wrote nothing, and the panel
    reported a move that never happened."""

    def run_cli(self, *argvs):
        buf = io.StringIO()
        with tempfile.TemporaryDirectory() as d:
            saved_dir, saved_path = ax.STORE_DIR, ax.STORE_PATH
            try:
                ax.STORE_DIR = os.path.join(d, "agent-skills")
                ax.STORE_PATH = os.path.join(ax.STORE_DIR, "categories.json")
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                    for argv in argvs:
                        code = ax.main(list(argv))
                return code, ax.read_store()
            finally:
                ax.STORE_DIR, ax.STORE_PATH = saved_dir, saved_path

    def test_a_double_dash_gets_an_option_shaped_name_through(self):
        code, store = self.run_cli(["category", "assign", "--", "-h", "design"])
        self.assertEqual(code, 0)
        self.assertEqual(store["assign"], {"-h": "design"})

    def test_without_it_the_parser_takes_the_name_for_itself(self):
        # Left as a test rather than a comment: this is the behaviour the `--`
        # exists to get past, and it exits 0 having written nothing.
        with self.assertRaises(SystemExit):
            self.run_cli(["category", "assign", "-h", "design"])

    def test_the_same_name_can_be_taken_back_off_the_shelf(self):
        code, store = self.run_cli(["category", "assign", "--", "-h", "design"],
                                   ["category", "unassign", "--", "-h"])
        self.assertEqual(code, 0)
        self.assertEqual(store["assign"], {})

    def test_a_name_no_directory_could_have_is_refused(self):
        for bad in ("a/b", "..", ".", "new\nline", "a" * 129):
            code, store = self.run_cli(["category", "assign", "--", bad, "design"])
            self.assertEqual(code, 2, bad)
            self.assertEqual(store["assign"], {}, bad)

    def test_a_name_only_a_shell_would_object_to_is_kept(self):
        # Nothing here is ever handed to a shell -- the panel spawns the helper
        # with an argv list -- so a name a shell would choke on is just a name,
        # and refusing it would strand a skill nobody could file.
        for good in ("with space", "mój-skill", "weird;name", "$(id)"):
            code, store = self.run_cli(["category", "assign", "--", good, "design"])
            self.assertEqual((code, store["assign"]), (0, {good: "design"}), good)

    def test_an_ordinary_name_still_lands(self):
        code, store = self.run_cli(["category", "assign", "nextjs", "web"])
        self.assertEqual((code, store["assign"]), (0, {"nextjs": "web"}))

    def test_a_name_shaped_like_a_directory_is_kept(self):
        for good in ("-h", "--help", "n8n-mcp", "a_b.c", "3d", "a b", "mój-skill"):
            self.assertRegex(good, ax.SKILL_NAME)
        for bad in ("", ".", "..", "a/b", "a\tb", "a" * 129):
            self.assertNotRegex(bad, ax.SKILL_NAME)


class RemovalPlan(unittest.TestCase):
    """What removing a skill would take, decided from a real stat of the real
    directory and the finished mount list. Every field here is read by a panel
    that is about to offer the user a button, so a plan that names the wrong path
    or the wrong agent is worse than no plan at all."""

    def plan(self, build, dir_name):
        result = scan_with_home(build)
        return next(i for i in result["items"] if i["dirName"] == dir_name)["removal"]

    def test_an_ordinary_skill_goes_to_the_trash(self):
        plan = self.plan(lambda d: write_skill(os.path.join(d, ".claude", "skills"), "plain"),
                         "plain")
        self.assertEqual(plan["mode"], "trash")
        self.assertEqual([t["link"] for t in plan["targets"]], ["real"])
        self.assertTrue(plan["targets"][0]["abs"].endswith("/.claude/skills/plain"))
        self.assertEqual(plan["loses"], ["claude", "opencode"])
        self.assertEqual(plan["keeps"], [])
        self.assertTrue(plan["restorable"])
        self.assertIsNone(plan["command"])
        self.assertTrue(plan["why"])

    def test_a_packaged_codex_skill_is_refused(self):
        # ~/.codex/skills/.system is rewritten from an embedded copy on every
        # launch, so a skill removed from it is back before the user has finished
        # reading the confirmation.
        plan = self.plan(
            lambda d: write_skill(os.path.join(d, ".codex", "skills", ".system"), "packaged"),
            "packaged")
        self.assertEqual(plan["mode"], "refuse")
        self.assertEqual(plan["targets"], [])
        self.assertIn(".system", plan["why"])
        self.assertEqual(plan["loses"], [])
        self.assertEqual(plan["keeps"], ["codex"])
        self.assertFalse(plan["restorable"])

    def test_a_plugin_skill_is_handed_back_to_its_plugin(self):
        def build(d):
            install = os.path.join(d, ".claude", "plugins", "cache", "imp", "imp", "4.2.2")
            write_skill(os.path.join(install, "skills"), "impeccable")
            os.makedirs(os.path.join(d, ".claude", "plugins"), exist_ok=True)
            with open(os.path.join(d, ".claude", "plugins", "installed_plugins.json"),
                      "w", encoding="utf-8") as fh:
                json.dump({"plugins": {"impeccable@imp": [{"installPath": install}]}}, fh)
        plan = self.plan(build, "impeccable")
        self.assertEqual(plan["mode"], "delegate")
        self.assertEqual(plan["targets"], [])
        self.assertEqual(plan["command"], ["claude", "plugin", "uninstall", "impeccable"])
        self.assertIn("impeccable", plan["why"])
        self.assertEqual(plan["keeps"], ["claude"])

    def test_a_plugin_skill_the_user_also_linked_is_still_the_plugins(self):
        # The delegate rule used to read `flags.pluginProvided`, which _ingest
        # sets from whichever root reached the realpath first -- and skill_roots()
        # returns the five user roots before the plugin caches. A plugin skill the
        # user had also symlinked into ~/.claude/skills therefore recorded False,
        # planned as `trash`, and listed the plugin's own checkout among the paths
        # to move, which is the panel offering to delete an installed plugin.
        def build(d):
            install = os.path.join(d, ".claude", "plugins", "cache", "kit", "kit", "4.2.2")
            write_skill(os.path.join(install, "skills"), "impeccable")
            os.makedirs(os.path.join(d, ".claude", "plugins"), exist_ok=True)
            with open(os.path.join(d, ".claude", "plugins", "installed_plugins.json"),
                      "w", encoding="utf-8") as fh:
                json.dump({"plugins": {"superkit@kit": [{"installPath": install}]}}, fh)
            os.makedirs(os.path.join(d, ".claude", "skills"), exist_ok=True)
            os.symlink(os.path.join(install, "skills", "impeccable"),
                       os.path.join(d, ".claude", "skills", "impeccable"))
        result = scan_with_home(build)
        item = next(i for i in result["items"] if i["dirName"] == "impeccable")
        self.assertFalse(item["flags"]["pluginProvided"], "the field that cannot be trusted")
        plan = item["removal"]
        self.assertEqual(plan["mode"], "delegate")
        self.assertEqual(plan["targets"], [])
        # The plugin is named by the root the directory actually sits under. The
        # invocation reads `/impeccable` on this record, so the half before its
        # colon is the skill's own name and names no plugin at all.
        self.assertEqual(item["invocation"]["claude"], "/impeccable")
        self.assertEqual(plan["command"], ["claude", "plugin", "uninstall", "superkit"])
        self.assertIn("superkit", plan["why"])

    def test_a_directory_whose_name_merely_starts_the_same_is_not_swept_in(self):
        # Matched on the path boundary rather than a bare startswith. `skills-extra`
        # beside the plugin's `skills` starts with every character of it, and a bare
        # prefix hands the user an uninstall command for a plugin that does not own
        # the directory -- which is worse than handing them none.
        with tempfile.TemporaryDirectory() as d:
            cache = os.path.join(d, "cache", "kit")
            real = os.path.join(cache, "skills-extra", "impeccable")
            os.makedirs(real)
            record = {"realPath": real, "tools": ["claude"], "invocation": {},
                      "flags": {"pluginProvided": False, "builtin": False, "readOnly": False},
                      "mounts": [{"tool": "claude", "path": real, "abs": real, "link": "real"}]}
            roots = [{"path": os.path.join(cache, "skills"), "plugin": "superkit"},
                     {"path": os.path.join(cache, "skills-extra")}]
            plan = ax._removal_plan(record, roots, os.getuid(), None, {})
        self.assertNotEqual(plan["mode"], "delegate")
        self.assertEqual(plan["mode"], "trash")

    def test_a_skill_that_really_lives_elsewhere_loses_only_its_links(self):
        # The directory itself is outside every root the agents scan, so it is
        # not ours to file away on their behalf: only the links to it can go.
        def build(d):
            real = os.path.join(d, "projects", "wanderer")
            write_skill(os.path.join(d, "projects"), "wanderer")
            for root in (".claude/skills", ".codex/skills"):
                os.makedirs(os.path.join(d, root), exist_ok=True)
                os.symlink(real, os.path.join(d, root, "wanderer"))
        plan = self.plan(build, "wanderer")
        self.assertEqual(plan["mode"], "unlink")
        self.assertEqual([t["link"] for t in plan["targets"]], ["symlink", "symlink"])
        self.assertFalse(any("/projects/" in t["abs"] for t in plan["targets"]), plan["targets"])
        self.assertEqual(sorted(plan["loses"]), ["claude", "codex", "opencode"])

    def test_a_directory_a_package_owns_is_unlinked_and_names_the_package(self):
        """The live case: /usr/share/omarchy/default/agents/skills/{omarchy,
        diagnose-crash} are root-owned and reached from three user roots by
        symlink. `flags.readOnly` reads False for both -- it tracks bundling and
        nothing else -- so the mode is taken from a stat of the real directory,
        and the uid is passed in here for the one branch a test cannot become."""
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "share", "omarchy")
            root = os.path.join(d, "skills")
            os.makedirs(real)
            os.makedirs(root)
            link = os.path.join(root, "omarchy")
            os.symlink(real, link)
            record = {"realPath": real, "tools": ["claude", "codex"],
                      "flags": {"pluginProvided": False, "builtin": False, "readOnly": False},
                      "mounts": [{"tool": "claude", "path": link, "abs": link, "link": "symlink"},
                                 {"tool": "codex", "path": link, "abs": link, "link": "symlink"}]}
            plan = ax._removal_plan(record, [{"path": root}], os.getuid() + 1, None,
                                    {real: "omarchy-settings-dev"})
        self.assertEqual(plan["mode"], "unlink")
        self.assertIn("omarchy-settings-dev", plan["why"])
        self.assertEqual([t["abs"] for t in plan["targets"]], [link])
        self.assertIn("re-creates", plan["restoreNote"])
        self.assertEqual(plan["loses"], ["claude", "codex"])

    def test_the_restore_note_names_the_provisioner_not_the_owner_of_the_directory(self):
        """What re-creates the link is /usr/share/omarchy/bin/omarchy-provision-user,
        which loops the packaged skills and runs `ln -sfn` for each one; it belongs
        to omarchy-dev and runs from a migration. The note was built as
        f"{package} re-creates this link", where `package` is whoever owns the skill
        DIRECTORY -- omarchy-settings-dev -- so it attributed the action to something
        that does not perform it and sent anyone chasing it to the wrong package."""
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "share", "omarchy")
            root = os.path.join(d, "skills")
            os.makedirs(real)
            os.makedirs(root)
            link = os.path.join(root, "omarchy")
            os.symlink(real, link)
            record = {"realPath": real, "tools": ["claude"],
                      "flags": {"pluginProvided": False, "builtin": False, "readOnly": False},
                      "mounts": [{"tool": "claude", "path": link, "abs": link, "link": "symlink"}]}
            plan = ax._removal_plan(record, [{"path": root}], os.getuid() + 1, None,
                                    {real: "omarchy-settings-dev"})
        self.assertIn("omarchy-settings-dev", plan["why"])
        self.assertNotIn("omarchy-settings-dev", plan["restoreNote"])
        self.assertIn("provisions", plan["restoreNote"])

    def test_an_unowned_directory_with_no_package_still_says_who_has_it(self):
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "elsewhere")
            root = os.path.join(d, "skills")
            os.makedirs(real)
            os.makedirs(root)
            link = os.path.join(root, "x")
            os.symlink(real, link)
            record = {"realPath": real, "tools": ["claude"],
                      "flags": {"pluginProvided": False, "builtin": False, "readOnly": False},
                      "mounts": [{"tool": "claude", "path": link, "abs": link, "link": "symlink"}]}
            plan = ax._removal_plan(record, [{"path": root}], os.getuid() + 1, None, {})
        self.assertEqual(plan["mode"], "unlink")
        self.assertIn("uid %d" % os.getuid(), plan["why"])
        self.assertIsNone(plan["restoreNote"])

    def test_a_dotfiles_managed_root_is_resolved_the_way_the_act_side_resolves_it(self):
        # ~/.claude as a symlink into a checkout is what chezmoi and stow both
        # produce. The act side has always tested against os.path.realpath of each
        # root; the plan side tested against the literal paths, so every skill the
        # user owns had a realpath outside every root and an ordinary one was
        # refused with nothing the panel could offer to do about it.
        def build(d):
            checkout = os.path.join(d, "dotfiles", "claude")
            write_skill(os.path.join(checkout, "skills"), "plain")
            os.symlink(checkout, os.path.join(d, ".claude"))
        plan = self.plan(build, "plain")
        self.assertEqual(plan["mode"], "trash")
        self.assertEqual([t["link"] for t in plan["targets"]], ["real"])
        self.assertTrue(plan["restorable"])

    def test_a_directory_outside_every_root_gets_a_sentence_of_its_own(self):
        # Substituting a place into the ownership clause produced "belongs to
        # somewhere the agents do not scan", which is not a thing a directory can
        # belong to and told the reader nothing about which of the two it was.
        with tempfile.TemporaryDirectory() as d:
            real = os.path.join(d, "elsewhere")
            os.makedirs(real)
            record = {"realPath": real, "tools": ["claude"],
                      "flags": {"pluginProvided": False, "builtin": False, "readOnly": False},
                      "mounts": [{"tool": "claude", "path": real, "abs": real, "link": "real"}]}
            plan = ax._removal_plan(record, [{"path": os.path.join(d, "skills")}],
                                    os.getuid(), None, {})
        self.assertEqual(plan["mode"], "refuse")
        self.assertNotIn("belongs to", plan["why"])
        self.assertIn("outside every directory the agents scan", plan["why"])

    def test_links_are_ordered_before_the_directory_they_point_at(self):
        # Removing the real directory first takes the row off the next scan
        # entirely: what is left is a dangling link, one finding, and nothing to
        # click on to finish the job.
        def build(d):
            claude = os.path.join(d, ".claude", "skills")
            agents = os.path.join(d, ".agents", "skills")
            write_skill(claude, "shared")
            os.makedirs(agents, exist_ok=True)
            os.symlink(os.path.join(claude, "shared"), os.path.join(agents, "shared"))
        plan = self.plan(build, "shared")
        self.assertEqual([t["link"] for t in plan["targets"]], ["symlink", "real"])
        self.assertTrue(plan["targets"][0]["abs"].endswith("/.agents/skills/shared"))
        self.assertTrue(plan["targets"][-1]["abs"].endswith("/.claude/skills/shared"))

    def test_three_agents_reached_through_two_paths_all_lose_it(self):
        def build(d):
            claude = os.path.join(d, ".claude", "skills")
            agents = os.path.join(d, ".agents", "skills")
            write_skill(claude, "shared")
            os.makedirs(agents, exist_ok=True)
            os.symlink(os.path.join(claude, "shared"), os.path.join(agents, "shared"))
        plan = self.plan(build, "shared")
        self.assertEqual(len(plan["targets"]), 2)
        self.assertEqual(sorted(plan["loses"]), ["claude", "codex", "opencode"])
        self.assertEqual(plan["keeps"], [])

    def test_two_tools_sharing_one_path_make_one_target(self):
        # Mounts are keyed on (tool, path), so the single directory Claude Code
        # and OpenCode both read appears twice in the list. Acting on it as it
        # stands would trash it once and then be handed a path that is gone.
        def build(d):
            write_skill(os.path.join(d, ".claude", "skills"), "twice")
        result = scan_with_home(build)
        item = next(i for i in result["items"] if i["dirName"] == "twice")
        self.assertEqual([m["tool"] for m in item["mounts"]], ["claude", "opencode"])
        self.assertEqual(len(item["removal"]["targets"]), 1)
        self.assertEqual(item["removal"]["targets"][0]["tools"], ["claude", "opencode"])

    def test_every_skill_carries_a_plan_the_panel_can_read(self):
        def build(d):
            write_skill(os.path.join(d, ".claude", "skills"), "plain")
            write_skill(os.path.join(d, ".codex", "skills", ".system"), "packaged")
        for item in scan_with_home(build)["items"]:
            plan = item["removal"]
            self.assertIn(plan["mode"], ("trash", "unlink", "delegate", "refuse"))
            self.assertTrue(plan["why"].endswith("."), plan["why"])
            for field in ("targets", "loses", "keeps", "restorable", "restoreNote", "command"):
                self.assertIn(field, plan)

    def test_the_package_query_is_parsed_out_of_the_sentence_pacman_writes(self):
        # `-Qo` rather than `-Qoq` because a path no package owns goes to stderr
        # and drops out of the quiet output, which would shift every remaining
        # answer onto the wrong path. A directory comes back with a trailing
        # slash it was not given.
        m = ax.PACMAN_OWNED.match(
            "/usr/share/omarchy/default/agents/skills/omarchy/ is owned by "
            "omarchy-settings-dev 4.0.0.r2071.ga703092-1")
        self.assertEqual(m.group("path"), "/usr/share/omarchy/default/agents/skills/omarchy")
        self.assertEqual(m.group("name"), "omarchy-settings-dev")
        self.assertIsNone(ax.PACMAN_OWNED.match("error: No package owns /home/me/skills/x"))


class RemoveCommand(unittest.TestCase):
    """`agent-skills remove`. The row it is acting on was drawn by a scan that may
    be minutes old, so none of it is believed: every fact is taken again from the
    path itself, and a path that fails one of them is refused by name while the
    rest carry on.

    The real gio is never spawned. `_gio_trash` is the only thing in the helper
    that leaves the process, and it is replaced below by a recorder that moves
    the fixture path itself, so the suite can never reach this machine's Trash.
    """

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home, True)
        saved = ax.HOME
        ax.HOME = self.home
        self.addCleanup(setattr, ax, "HOME", saved)
        self.trashed = []
        self.refuse = {}
        saved_trash = ax._gio_trash
        ax._gio_trash = self.fake_trash
        self.addCleanup(setattr, ax, "_gio_trash", saved_trash)

    def fake_trash(self, path):
        # The guard is the point of the stub as much as the recording is: nothing
        # in this suite may act on a path outside the fixture it just built.
        assert path.startswith(self.home + "/"), path
        if path in self.refuse:
            return False, self.refuse[path]
        self.trashed.append(path)
        if os.path.islink(path):
            os.unlink(path)
        else:
            shutil.rmtree(path)
        return True, ""

    def skill(self, root, name):
        write_skill(os.path.join(self.home, root), name)
        return os.path.join(self.home, root, name)

    def remove(self, *paths, dry_run=False):
        out, err = io.StringIO(), io.StringIO()
        argv = ["remove"] + (["--dry-run"] if dry_run else []) + ["--"] + list(paths)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = ax.main(argv)
        return code, json.loads(out.getvalue())

    def test_an_ordinary_skill_goes_and_says_so(self):
        path = self.skill(".claude/skills", "plain")
        code, report = self.remove(path)
        self.assertEqual(code, 0)
        self.assertEqual(report["removed"], [{"path": path, "trashed": True}])
        self.assertEqual(report["refused"], [])
        self.assertEqual(self.trashed, [path])
        self.assertFalse(os.path.exists(path))

    def test_a_plugin_checkout_is_refused_by_the_side_that_acts(self):
        # A plugin's own checkout is a skill root, so every other test here passes
        # on a path inside one -- it is a directory, it is ours, its parent is a
        # root, and it holds a SKILL.md. The plan answers `delegate` for these, but
        # the plan is advisory by design; a guard that lives only there is one the
        # command line walks straight past, and what it would trash is a skill out
        # of an installed plugin.
        cache = os.path.join(self.home, ".claude", "plugins", "cache",
                             "kit", "superkit", "1.0.0", "skills")
        write_skill(cache, "bundled")
        path = os.path.join(cache, "bundled")
        os.makedirs(os.path.join(self.home, ".claude", "plugins"), exist_ok=True)
        with open(os.path.join(self.home, ".claude", "plugins",
                               "installed_plugins.json"), "w", encoding="utf-8") as fh:
            json.dump({"version": 2, "plugins": {"superkit@kit": [
                {"scope": "user", "installPath": os.path.dirname(cache),
                 "version": "1.0.0"}]}}, fh)
        code, report = self.remove(path)
        self.assertEqual(code, 2)
        self.assertEqual(report["removed"], [])
        self.assertIn("installed plugin", report["refused"][0]["reason"])
        self.assertEqual(self.trashed, [])
        self.assertTrue(os.path.exists(path))

    def test_a_relative_path_is_refused_before_anything_is_touched(self):
        path = self.skill(".claude/skills", "plain")
        code, report = self.remove("skills/plain", path)
        self.assertEqual(code, 2)
        self.assertEqual(report["removed"], [])
        self.assertEqual(len(report["refused"]), 2)
        self.assertIn("absolute", report["refused"][0]["reason"])
        self.assertEqual(self.trashed, [])
        self.assertTrue(os.path.exists(path))

    def test_a_path_that_is_not_a_skill_is_refused(self):
        os.makedirs(os.path.join(self.home, ".claude", "skills", "empty"))
        code, report = self.remove(os.path.join(self.home, ".claude", "skills", "empty"))
        self.assertEqual(code, 2)
        self.assertIn("SKILL.md", report["refused"][0]["reason"])
        self.assertEqual(self.trashed, [])

    def test_a_skill_md_that_vanished_since_the_scan_is_refused(self):
        # The row is advisory. Between the scan that drew it and the click that
        # acts on it, the directory can have been emptied by anything at all.
        path = self.skill(".claude/skills", "plain")
        os.remove(os.path.join(path, "SKILL.md"))
        code, report = self.remove(path)
        self.assertEqual(code, 2)
        self.assertIn("SKILL.md", report["refused"][0]["reason"])
        self.assertTrue(os.path.isdir(path))

    def test_a_path_under_system_is_refused(self):
        path = self.skill(".codex/skills/.system", "packaged")
        code, report = self.remove(path)
        self.assertEqual(code, 2)
        self.assertIn(".system", report["refused"][0]["reason"])
        self.assertTrue(os.path.exists(path))

    def test_a_path_outside_every_root_is_refused(self):
        write_skill(os.path.join(self.home, "projects"), "wanderer")
        path = os.path.join(self.home, "projects", "wanderer")
        code, report = self.remove(path)
        self.assertEqual(code, 2)
        self.assertIn("scans for skills", report["refused"][0]["reason"])
        self.assertTrue(os.path.exists(path))

    def test_a_file_is_not_a_skill_directory(self):
        os.makedirs(os.path.join(self.home, ".claude", "skills"))
        path = os.path.join(self.home, ".claude", "skills", "notadir")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("x")
        code, report = self.remove(path)
        self.assertEqual(code, 2)
        self.assertIn("not a directory", report["refused"][0]["reason"])

    def test_a_dry_run_checks_everything_and_touches_nothing(self):
        good = self.skill(".claude/skills", "plain")
        bad = self.skill(".codex/skills/.system", "packaged")
        code, report = self.remove(good, bad, dry_run=True)
        self.assertEqual(code, 0)
        self.assertEqual(report["removed"], [{"path": good, "trashed": False}])
        self.assertIn(".system", report["refused"][0]["reason"])
        self.assertEqual(self.trashed, [])
        self.assertTrue(os.path.exists(good) and os.path.exists(bad))

    def test_one_refusal_does_not_abandon_the_paths_beside_it(self):
        first = self.skill(".claude/skills", "aaa")
        second = self.skill(".claude/skills", "bbb")
        third = self.skill(".claude/skills", "ccc")
        os.remove(os.path.join(second, "SKILL.md"))
        code, report = self.remove(first, second, third)
        self.assertEqual(code, 0)
        self.assertEqual([r["path"] for r in report["removed"]], [first, third])
        self.assertEqual([r["path"] for r in report["refused"]], [second])
        self.assertFalse(os.path.exists(first))
        self.assertFalse(os.path.exists(third))

    def test_links_are_trashed_before_the_directory_whatever_order_they_arrive_in(self):
        # Removing the real directory first leaves a dangling link and takes the
        # row off the next scan, so there is nothing left to finish the job with.
        real = self.skill(".claude/skills", "shared")
        os.makedirs(os.path.join(self.home, ".agents", "skills"))
        link = os.path.join(self.home, ".agents", "skills", "shared")
        os.symlink(real, link)
        code, report = self.remove(real, link)
        self.assertEqual(code, 0)
        self.assertEqual(self.trashed, [link, real])
        self.assertEqual([r["path"] for r in report["removed"]], [link, real])

    def test_what_gio_refused_reaches_the_caller_word_for_word(self):
        # "Trashing on system internal mounts is not supported" is what a user
        # who keeps their skills on another filesystem gets, and it is the only
        # sentence that tells them why nothing happened.
        path = self.skill(".claude/skills", "plain")
        self.refuse[path] = "Trashing on system internal mounts is not supported"
        code, report = self.remove(path)
        self.assertEqual(code, 2)
        self.assertEqual(report["removed"], [])
        self.assertIn("system internal mounts", report["refused"][0]["reason"])
        self.assertTrue(os.path.exists(path))

    def test_a_refusal_from_gio_does_not_stop_the_next_path(self):
        first = self.skill(".claude/skills", "aaa")
        second = self.skill(".claude/skills", "bbb")
        self.refuse[first] = "Trashing on system internal mounts is not supported"
        code, report = self.remove(first, second)
        self.assertEqual(code, 0)
        self.assertEqual(self.trashed, [second])
        self.assertEqual([r["path"] for r in report["refused"]], [first])

    def test_a_refused_link_holds_back_the_directory_it_points_at(self):
        # The network-mount case the README names: ~/.agents/skills on another
        # filesystem, where the trash refuses the link outright. The directory
        # went anyway, which left the skill in the trash, a live dangling link in
        # a root Codex and OpenCode still walk, and no row on the panel to fix it
        # with -- a skill whose realpath is gone stops being an item.
        real = self.skill(".claude/skills", "shared")
        os.makedirs(os.path.join(self.home, ".agents", "skills"))
        link = os.path.join(self.home, ".agents", "skills", "shared")
        os.symlink(real, link)
        self.refuse[link] = "Trashing on system internal mounts is not supported"
        code, report = self.remove(real, link)
        self.assertEqual(code, 2)
        self.assertEqual(report["removed"], [])
        self.assertEqual(self.trashed, [])
        self.assertTrue(os.path.isdir(real))
        held = next(r for r in report["refused"] if r["path"] == real)
        self.assertIn("/.agents/skills/shared", held["reason"])
        self.assertIn("dangling", held["reason"])

    def test_a_link_our_own_checks_refuse_holds_the_directory_back_too(self):
        # Whichever of the two refused it, the link is still on disk and the
        # directory under it has to stay: gio is not the only way a link can fail.
        real = self.skill(".claude/skills", "shared")
        os.makedirs(os.path.join(self.home, ".codex", "skills", ".system"))
        link = os.path.join(self.home, ".codex", "skills", ".system", "shared")
        os.symlink(real, link)
        code, report = self.remove(real, link)
        self.assertEqual(code, 2)
        self.assertEqual(self.trashed, [])
        self.assertTrue(os.path.isdir(real))
        self.assertIn("dangling", next(r for r in report["refused"]
                                       if r["path"] == real)["reason"])

    def test_only_the_directory_that_link_named_is_held_back(self):
        # One refusal must not abandon the others, and that is about separate
        # skills rather than about the links and the target of one: a second link
        # to the same directory still goes, and so does an unrelated skill.
        real = self.skill(".claude/skills", "shared")
        alone = self.skill(".claude/skills", "alone")
        os.makedirs(os.path.join(self.home, ".agents", "skills"))
        os.makedirs(os.path.join(self.home, ".codex", "skills"))
        stuck = os.path.join(self.home, ".agents", "skills", "shared")
        spare = os.path.join(self.home, ".codex", "skills", "shared")
        os.symlink(real, stuck)
        os.symlink(real, spare)
        self.refuse[stuck] = "Trashing on system internal mounts is not supported"
        code, report = self.remove(real, stuck, spare, alone)
        self.assertEqual(code, 0)
        self.assertEqual(self.trashed, [spare, alone])
        self.assertTrue(os.path.isdir(real))
        self.assertFalse(os.path.exists(alone))
        self.assertEqual(sorted(r["path"] for r in report["refused"]), sorted([real, stuck]))


class PackageLookupIsCached(unittest.TestCase):
    """`owning_packages` spawned pacman on every scan: 125 ms against the 21 ms
    the rest of the scan costs, on the path the panel takes each time it opens
    because scanOnOpen defaults to true. The premise that a foreign-owned skill is
    rare is backwards for this audience -- omarchy-provision-user links two
    package-owned skills into every stock user root, so every scan on every stock
    install paid it. Ownership of a path cannot change without a pacman
    transaction, and every transaction rewrites the local database, so the answer
    is kept and re-asked only once that database has moved.
    """

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home, True)
        for name, value in (("HOME", self.home), ("PACMAN", sys.executable),
                            ("PACMAN_DB", os.path.join(self.home, "localdb"))):
            self.addCleanup(setattr, ax, name, getattr(ax, name))
            setattr(ax, name, value)
        os.makedirs(ax.PACMAN_DB)
        # The one thing that leaves the process. Stubbed rather than mocked out
        # wholesale, so the cache is exercised through the same door a scan uses.
        self.asked: list = []
        self.addCleanup(setattr, ax, "_ask_pacman", ax._ask_pacman)
        ax._ask_pacman = self.fake_ask

    def fake_ask(self, paths):
        self.asked.append(list(paths))
        return {p: "omarchy-settings-dev" for p in paths if p.endswith("/omarchy")}

    OMARCHY = "/usr/share/omarchy/default/agents/skills/omarchy"
    CRASH = "/usr/share/omarchy/default/agents/skills/diagnose-crash"

    def test_the_second_scan_spawns_nothing(self):
        answer = {self.OMARCHY: "omarchy-settings-dev"}
        self.assertEqual(ax.owning_packages([self.OMARCHY]), answer)
        self.assertEqual(ax.owning_packages([self.OMARCHY]), answer)
        self.assertEqual(len(self.asked), 1, self.asked)

    def test_a_pacman_transaction_makes_it_ask_again(self):
        ax.owning_packages([self.OMARCHY])
        os.utime(ax.PACMAN_DB, (0, 0))
        ax.owning_packages([self.OMARCHY])
        self.assertEqual(len(self.asked), 2, self.asked)

    def test_a_path_no_package_owns_is_not_asked_about_twice(self):
        # Recorded as the empty string rather than left out of the cache. Left
        # out, a negative answer would send pacman off again on every scan, which
        # is the whole cost this exists to remove.
        self.assertEqual(ax.owning_packages([self.CRASH]), {})
        self.assertEqual(ax.owning_packages([self.CRASH]), {})
        self.assertEqual(len(self.asked), 1, self.asked)

    def test_a_path_the_cache_never_saw_makes_it_ask(self):
        # A partial hit would name the package for one skill and bare uid for the
        # next, which reads as though the second belonged to nobody.
        ax.owning_packages([self.OMARCHY])
        ax.owning_packages([self.CRASH, self.OMARCHY])
        self.assertEqual(len(self.asked), 2, self.asked)

    def test_a_cache_that_cannot_be_parsed_is_a_miss_and_not_a_crash(self):
        path = ax._package_cache_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("{ half a fil")
        self.assertEqual(ax.owning_packages([self.OMARCHY]),
                         {self.OMARCHY: "omarchy-settings-dev"})
        self.assertEqual(len(self.asked), 1, self.asked)

    def test_a_database_that_cannot_be_stat_ed_never_trusts_a_cached_answer(self):
        # No key, so no hit: a machine whose pacman database we cannot see is one
        # where a stale answer could outlive the transaction that invalidated it.
        ax.PACMAN_DB = os.path.join(self.home, "gone")
        ax.owning_packages([self.OMARCHY])
        ax.owning_packages([self.OMARCHY])
        self.assertEqual(len(self.asked), 2, self.asked)
        self.assertFalse(os.path.exists(ax._package_cache_path()))


class DescribeCase(unittest.TestCase):
    """A throwaway HOME with skills in it, and the helper pointed at both.

    Everything below writes a SKILL.md, which is the one thing this suite may
    never do to a real one: HOME, both stores and every root that follows from
    them are moved into a temporary directory before a single verb runs.
    """

    AUTHOR = ("The author's own description, at the length descriptions are "
              "actually written at, which is what the agent reads on every turn.")
    BODY = "\n# A title\n\nA body no verb here is allowed to touch.\n"

    def setUp(self):
        self.home = tempfile.mkdtemp()
        for name in ("HOME", "STORE_DIR", "STORE_PATH", "DESCRIBE_PATH"):
            self.addCleanup(setattr, ax, name, getattr(ax, name))
        ax.HOME = self.home
        ax.STORE_DIR = os.path.join(self.home, ".config", "agent-skills")
        ax.STORE_PATH = os.path.join(ax.STORE_DIR, "categories.json")
        ax.DESCRIBE_PATH = os.path.join(ax.STORE_DIR, "descriptions.json")
        self.root = os.path.join(self.home, ".claude", "skills")
        os.makedirs(self.root)
        self.addCleanup(self.hand_the_tree_back)

    def hand_the_tree_back(self):
        for base, dirs, files in os.walk(self.home):
            for name in dirs + files:
                with contextlib.suppress(OSError):
                    os.chmod(os.path.join(base, name), 0o700)
        shutil.rmtree(self.home, ignore_errors=True)

    def write(self, name, frontmatter, root=None, body=BODY):
        directory = os.path.join(root or self.root, name)
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "SKILL.md")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("---\n" + frontmatter + "---" + body)
        return path

    def skill_md(self, name, root=None):
        """The file `write` and `reset` are named by, the way the panel names it:
        the row's own SKILL.md, absolute, never a display string re-expanded."""
        return os.path.join(root or self.root, name, "SKILL.md")

    def plain(self, name="plain", description=AUTHOR):
        return self.write(name, f"name: {name}\ndescription: {description}\n")

    def cli(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = ax.main(list(argv))
        return code, json.loads(out.getvalue().strip() or "{}")

    def note(self, name, *text):
        """The top field. Given no text at all it clears the note, which is the
        only way one goes: no other verb touches it."""
        return self.cli("describe", "note", "--", name, *text)

    def describe(self, name, text, path=None):
        """The bottom field: this text becomes the description in that SKILL.md."""
        return self.cli("describe", "write", "--", name, path or self.skill_md(name), text)

    def row(self, name):
        return next(i for i in ax.scan()["items"] if i["dirName"] == name)

    def raw(self, path):
        with open(path, "rb") as fh:
            return fh.read()

    def described(self, path):
        """The description as the panel and the three agents will read it."""
        with open(path, encoding="utf-8") as fh:
            fm = ax.parse_frontmatter(fh.read())
        return str(fm.get("description") or "").replace("\n", " ").strip()


class DescriptionNotes(DescribeCase):
    """The top field: somebody's own words about a skill, in their own language,
    kept in this plugin's file and drawn above the description on the card.

    The honesty rule outranks everything else in this feature, and the new model
    makes it sharper rather than softer: no agent ever opens the file a note
    lives in, so a note cannot cost or save a single token, and nothing anywhere
    may suggest otherwise. What the panel prints as the always-on cost comes from
    the description in SKILL.md and from nothing else.
    """

    NOTE = "Moje notatki: tylko konfiguracja pulpitu, nic więcej."

    def test_a_note_is_stored_and_reaches_the_card(self):
        path = self.plain()
        before = self.raw(path)
        code, said = self.note("plain", self.NOTE)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(ax.read_describe_store()["notes"]["plain"], self.NOTE)
        described = self.row("plain")["describe"]
        self.assertEqual(described["noteText"], self.NOTE)
        # The description is the author's still, because a note is not one.
        self.assertEqual(described["fileText"], self.AUTHOR)
        self.assertFalse(described["edited"])
        self.assertEqual(self.raw(path), before)

    def test_a_note_leaves_the_bill_exactly_where_it_was(self):
        self.plain()
        cost = self.row("plain")["tokens"]["alwaysOn"]
        self.note("plain", "A note ten times shorter than the description it sits above.")
        self.assertEqual(self.row("plain")["tokens"]["alwaysOn"], cost)
        # And a note far longer than the description does not move it either: the
        # figure follows the file, and the file has not changed.
        self.note("plain", "x " * 300)
        self.assertEqual(self.row("plain")["tokens"]["alwaysOn"], cost)

    def test_a_note_moves_no_figure_the_scan_prints_anywhere(self):
        # Not only the row's own count. `counts.alwaysOnTokens` is what the bar
        # draws, and a note that crept into it would be a saving nobody made.
        self.plain()
        before = ax.scan()["counts"]["alwaysOnTokens"]
        self.note("plain", "Shorter.")
        self.assertEqual(ax.scan()["counts"]["alwaysOnTokens"], before)

    def test_the_note_lives_in_our_file_and_nowhere_near_the_skill(self):
        path = self.plain()
        self.note("plain", self.NOTE)
        with open(ax.DESCRIBE_PATH, encoding="utf-8") as fh:
            self.assertIn("notes", json.load(fh))
        with open(path, encoding="utf-8") as fh:
            self.assertNotIn(self.NOTE, fh.read())

    def test_a_note_never_opens_a_skill_md(self):
        self.plain()
        self.addCleanup(setattr, ax, "_write_description", ax._write_description)
        self.addCleanup(setattr, ax, "_describe_candidates", ax._describe_candidates)
        ax._write_description = lambda *a, **k: self.fail("the note verb wrote a file")
        ax._describe_candidates = lambda *a, **k: self.fail("the note verb went looking")
        code, said = self.note("plain", self.NOTE)
        self.assertEqual((code, said["ok"]), (0, True))

    def test_an_empty_note_clears_the_one_that_is_there(self):
        self.plain()
        self.note("plain", self.NOTE)
        for emptied in ((), ("",), ("   ",)):
            self.note("plain", self.NOTE)
            code, said = self.note("plain", *emptied)
            self.assertEqual((code, said["ok"]), (0, True), emptied)
            self.assertEqual(ax.read_describe_store()["notes"], {}, emptied)
            self.assertIsNone(self.row("plain")["describe"]["noteText"], emptied)

    def test_clearing_a_note_nobody_wrote_is_not_an_error(self):
        self.plain()
        code, said = self.note("plain")
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertIn("no note", said["detail"])

    def test_clearing_a_note_leaves_the_description_alone(self):
        # The two fields are independent in both directions. This is the half
        # that says emptying the top one is not a way of resetting the bottom.
        path = self.plain()
        self.note("plain", self.NOTE)
        self.describe("plain", "One line, and the agent reads this one.")
        edited = self.raw(path)
        self.note("plain")
        self.assertEqual(self.raw(path), edited)
        self.assertTrue(self.row("plain")["describe"]["edited"])

    def test_a_note_is_one_line_however_it_was_typed(self):
        # A card draws it on one line, so the break comes out here rather than at
        # display time -- a note that changed shape on the way to the screen would
        # not be the text somebody typed.
        self.plain()
        self.note("plain", "  First line.\n\n\tSecond line.  ")
        self.assertEqual(ax.read_describe_store()["notes"]["plain"],
                         "First line. Second line.")

    def test_a_note_longer_than_any_description_here_is_clipped(self):
        self.plain("long")
        self.note("long", "x" * (ax.MAX_DESCRIPTION + 200))
        self.assertEqual(len(ax.read_describe_store()["notes"]["long"]), ax.MAX_DESCRIPTION)

    def test_a_name_no_directory_could_have_is_refused(self):
        for bad in ("a/b", "..", ".", "a" * 129):
            code, said = self.note(bad, "Something.")
            self.assertEqual((code, said["ok"]), (2, False), bad)
            self.assertEqual(ax.read_describe_store()["notes"], {}, bad)

    def test_every_skill_carries_the_describe_the_panel_was_promised(self):
        # The contract both halves are written against, asserted as a whole: the
        # panel reads these nine keys and no others, and the two that belonged to
        # the old staging model are gone rather than left behind as nulls.
        self.plain()
        self.plain("second")
        for row in ax.scan()["items"]:
            described = row["describe"]
            self.assertEqual(sorted(described), ["authorText", "canWrite", "edited", "fileText",
                                                 "handEdited", "noteText", "otherCopy",
                                                 "whyNot", "writeNote"])
            self.assertEqual(described["fileText"], row["description"])
            self.assertEqual(described["authorText"], row["description"])
            self.assertIsNone(described["noteText"])
            self.assertFalse(described["edited"])
            self.assertFalse(described["handEdited"])
            self.assertTrue(described["canWrite"])
            self.assertIsNone(described["whyNot"])


class DescriptionWrite(DescribeCase):
    """The bottom field: the text somebody typed becomes the description in that
    skill's SKILL.md.

    This is the one verb in the program that changes a file somebody else wrote,
    and the only one that moves what the agents pay -- and it moves it for real,
    at the moment it saves, because the file now says something different.
    """

    SHORT = "Short enough to be worth the trouble."

    def test_writing_moves_the_bill_and_keeps_the_author(self):
        self.plain()
        before = self.row("plain")["tokens"]["alwaysOn"]
        code, said = self.describe("plain", self.SHORT)
        self.assertEqual((code, said["ok"]), (0, True))
        row = self.row("plain")
        self.assertEqual(row["describe"]["fileText"], self.SHORT)
        self.assertEqual(row["describe"]["authorText"], self.AUTHOR)
        self.assertTrue(row["describe"]["edited"])
        self.assertFalse(row["describe"]["handEdited"])
        # The figure moves in the same scan that reads the new text, because both
        # come from the one file.
        self.assertLess(row["tokens"]["alwaysOn"], before)
        self.assertEqual(row["tokens"]["alwaysOn"],
                         ax.token_estimate("plain", self.SHORT, "", 4))

    def test_the_note_is_not_what_gets_written(self):
        # The two fields are independent, so the text on the command line is the
        # text that lands, whatever the note beside it says. Under the model this
        # replaced there was no way to write anything else.
        path = self.plain()
        self.note("plain", "A note in my own language, for me.")
        self.describe("plain", self.SHORT)
        self.assertEqual(self.described(path), self.SHORT)
        described = self.row("plain")["describe"]
        self.assertEqual(described["noteText"], "A note in my own language, for me.")
        self.assertEqual(described["fileText"], self.SHORT)

    def test_a_description_of_nothing_is_refused(self):
        path = self.plain()
        before = self.raw(path)
        for empty in ("", "   \n  "):
            code, said = self.describe("plain", empty)
            self.assertEqual((code, said["ok"]), (2, False), repr(empty))
            self.assertIn("reset", said["detail"])
            self.assertEqual(self.raw(path), before)
            self.assertEqual(ax.read_describe_store()["edited"], {})

    def test_the_body_and_every_other_key_come_through_byte_for_byte(self):
        path = self.write("keys", "name: keys\ndescription: Something long enough.\n"
                                  "argument-hint: \"[shape|audit] [target]\"\n"
                                  "allowed-tools: Read, Grep\n"
                                  "metadata:\n  version: 2.1.0\n")
        before = self.raw(path)
        self.describe("keys", self.SHORT)
        after = self.raw(path)
        self.assertNotEqual(after, before)
        head, _, body = after.partition(b"\n---")
        self.assertEqual(body, before.partition(b"\n---")[2])
        for line in (b"argument-hint: \"[shape|audit] [target]\"", b"allowed-tools: Read, Grep",
                     b"metadata:", b"  version: 2.1.0", b"name: keys"):
            self.assertIn(line, head)
        row = self.row("keys")
        self.assertEqual(row["declaredVersion"], "2.1.0")
        self.assertEqual(row["argumentHint"], "[shape|audit] [target]")

    def test_the_mode_the_author_gave_the_file_is_the_mode_it_keeps(self):
        path = self.plain()
        os.chmod(path, 0o640)
        self.describe("plain", self.SHORT)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o640)

    def test_a_skill_md_you_cannot_write_is_refused_and_says_which(self):
        path = self.plain()
        os.chmod(path, 0o444)
        before = self.raw(path)
        described = self.row("plain")["describe"]
        self.assertFalse(described["canWrite"])
        self.assertIn("not writable", described["whyNot"])
        self.assertIn("plain/SKILL.md", described["whyNot"])
        code, said = self.describe("plain", self.SHORT)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("not writable", said["detail"])
        self.assertEqual(self.raw(path), before)
        self.assertEqual(ax.read_describe_store()["edited"], {})

    def test_a_write_that_does_not_read_back_puts_the_original_back(self):
        """The safety net under all of this: the file is read again through the
        parser the agents use, and unless the description now says exactly what
        was asked for, the bytes that were there before go back before anything
        is recorded. Forced here by making the renderer write something else,
        which is the shape every bug in it would take."""
        path = self.plain()
        before = self.raw(path)
        self.addCleanup(setattr, ax, "_render_description", ax._render_description)
        ax._render_description = lambda value: ["description: not what was asked for"]
        code, said = self.describe("plain", self.SHORT)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("did not read back", said["detail"])
        self.assertEqual(self.raw(path), before)
        self.assertEqual(ax.read_describe_store()["edited"], {})

    def test_a_link_into_somebody_else_s_directory_names_the_real_file(self):
        # The shape a stock Omarchy install is in: the skill lives under
        # /usr/share and every agent root holds a link to it. Saying that the
        # link in your own directory is not writable explains nothing about why.
        elsewhere = os.path.join(self.home, "packaged")
        os.makedirs(elsewhere)
        self.write("linked", "name: linked\ndescription: Owned by somebody else.\n",
                   root=elsewhere)
        os.chmod(os.path.join(elsewhere, "linked", "SKILL.md"), 0o444)
        os.symlink(os.path.join(elsewhere, "linked"), os.path.join(self.root, "linked"))
        why = self.row("linked")["describe"]["whyNot"]
        self.assertIn("packaged/linked/SKILL.md", why)
        self.assertNotIn(".claude", why)

    def test_a_packaged_skill_under_system_is_refused(self):
        # Codex rewrites ~/.codex/skills/.system from an embedded copy on every
        # launch, so a description written there is gone before it is read.
        path = self.write("packaged", "name: packaged\ndescription: Packaged one.\n",
                          root=os.path.join(self.home, ".codex", "skills", ".system"))
        before = self.raw(path)
        described = self.row("packaged")["describe"]
        self.assertFalse(described["canWrite"])
        self.assertIn(".system", described["whyNot"])
        code, said = self.describe("packaged", self.SHORT, path=path)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn(".system", said["detail"])
        self.assertEqual(self.raw(path), before)

    def test_a_description_that_changed_since_the_scan_is_refused(self):
        path = self.plain()
        drawn = self.row("plain")["describe"]["fileText"]
        self.write("plain", "name: plain\ndescription: Somebody else got here first.\n")
        code, said = self.cli("describe", "write", "--expect", drawn, "--", "plain",
                              self.skill_md("plain"), self.SHORT)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("since the scan", said["detail"])
        self.assertEqual(self.described(path), "Somebody else got here first.")

    def test_the_row_it_was_drawn_from_still_writes(self):
        path = self.plain()
        drawn = self.row("plain")["describe"]["fileText"]
        code, said = self.cli("describe", "write", "--expect", drawn, "--", "plain",
                              self.skill_md("plain"), self.SHORT)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(path), self.SHORT)

    def test_a_hand_edit_is_overwritten_and_the_author_is_still_kept(self):
        """The model change, stated as plainly as it can be. The bottom field is
        pre-filled with what the file says and saved over it, so a file somebody
        edited by hand in between is written like any other -- it is the text in
        front of them that they are replacing. What survives is `original`: it is
        recorded once, on the first write, so what reset puts back is still the
        author's own words and never our earlier wording nor the hand edit.
        """
        path = self.plain()
        self.describe("plain", self.SHORT)
        self.write("plain", "name: plain\ndescription: Typed here by hand.\n")
        self.assertTrue(self.row("plain")["describe"]["handEdited"])
        code, said = self.describe("plain", "A third wording of it.")
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(path), "A third wording of it.")
        self.assertEqual(ax.read_describe_store()["edited"]["plain"]["original"], self.AUTHOR)
        self.assertFalse(self.row("plain")["describe"]["handEdited"])
        self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual(self.described(path), self.AUTHOR)

    def test_a_skill_that_is_not_there_any_more_is_refused(self):
        self.plain()
        shutil.rmtree(os.path.join(self.root, "plain"))
        code, said = self.describe("plain", self.SHORT)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("no directory named plain", said["detail"])

    def test_a_plugin_skill_says_the_edit_goes_when_the_plugin_does(self):
        install = os.path.join(self.home, "cache", "impeccable", "4.2.2")
        self.write("impeccable", "name: impeccable\ndescription: A plugin's own skill.\n",
                   root=os.path.join(install, "skills"))
        os.makedirs(os.path.join(self.home, ".claude", "plugins"))
        with open(os.path.join(self.home, ".claude", "plugins",
                               "installed_plugins.json"), "w", encoding="utf-8") as fh:
            json.dump({"plugins": {"impeccable@impeccable":
                                   [{"scope": "user", "installPath": install}]}}, fh)
        described = self.row("impeccable")["describe"]
        self.assertTrue(described["canWrite"])
        self.assertIn("plugin update", described["writeNote"])
        code, said = self.describe("impeccable", self.SHORT,
                                   path=self.skill_md("impeccable",
                                                      os.path.join(install, "skills")))
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertIn("plugin update", said["detail"])

    def test_a_fetched_skill_says_the_edit_lasts_until_the_next_fetch(self):
        self.write("security-review", "name: security-review\ndescription: Fetched over HTTP.\n",
                   root=os.path.join(self.home, ".cache", "opencode", "skills"))
        described = self.row("security-review")["describe"]
        self.assertTrue(described["canWrite"])
        self.assertIn("skills.urls", described["writeNote"])

    def test_one_name_reaching_two_files_writes_one_and_says_so(self):
        """A name can reach two different skills -- impeccable ships one build
        for OpenCode and another inside a Claude Code plugin -- and the store is
        keyed by the name, because that is what a person means by a skill. So one
        file is written, the one named on the command line, and the other is left
        alone and counted in the answer. The pair genuinely differs afterwards,
        and the drift flag that says so is right to.
        """
        self.write("twin", "name: twin\ndescription: The copy Claude Code reads.\n")
        self.write("twin", "name: twin\ndescription: The copy OpenCode reads instead.\n",
                   root=os.path.join(self.home, ".config", "opencode", "skills"))
        code, said = self.describe("twin", self.SHORT)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertIn("1 other copy of this name was left alone", said["detail"])
        rows = [i for i in ax.scan()["items"] if i["dirName"] == "twin"]
        self.assertEqual(len(rows), 2)
        self.assertEqual(sorted(r["describe"]["fileText"] for r in rows),
                         [self.SHORT, "The copy OpenCode reads instead."])
        for row in rows:
            self.assertIn("drift", row["attention"])


class DescriptionWritesTheFileItWasGiven(DescribeCase):
    """The file that gets written is the file the row promised.

    One name reaches more than one SKILL.md -- impeccable ships one build for
    OpenCode and another inside a Claude Code plugin -- and the panel draws a row
    per file, whose card names that file, its caveat and its token figure.
    Choosing the first writable copy on this side instead wrote whichever root
    the walk reached first, so writing from the plugin row, whose card carries
    the plugin-update caveat, rewrote the OpenCode copy and made all three of
    those promises false at once.
    """

    TEXT = "One line about it, for the agent to read."

    def two_copies(self):
        claude = self.write("impeccable", "name: impeccable\n"
                                          "description: The copy Claude Code reads.\n")
        opencode = self.write("impeccable", "name: impeccable\n"
                                            "description: The copy OpenCode reads instead.\n",
                              root=os.path.join(self.home, ".config", "opencode", "skills"))
        return claude, opencode

    def test_the_file_named_on_the_command_line_is_the_one_that_changes(self):
        claude, opencode = self.two_copies()
        untouched = self.raw(claude)
        code, said = self.describe("impeccable", self.TEXT, path=opencode)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(opencode), self.TEXT)
        self.assertEqual(self.raw(claude), untouched)
        # And the sentence names the file it wrote, not the one it chose.
        self.assertIn("opencode/skills/impeccable/SKILL.md", said["detail"])
        self.assertIn("1 other copy of this name was left alone", said["detail"])

    def test_the_other_copy_changes_when_that_is_the_one_named(self):
        # The same command with the other path. Nothing about the outcome depends
        # on which root the walk reached first, which is the whole of the fix.
        claude, opencode = self.two_copies()
        untouched = self.raw(opencode)
        code, said = self.describe("impeccable", self.TEXT, path=claude)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(claude), self.TEXT)
        self.assertEqual(self.raw(opencode), untouched)

    def test_reset_puts_back_the_copy_it_was_given(self):
        _, opencode = self.two_copies()
        before = self.raw(opencode)
        self.describe("impeccable", self.TEXT, path=opencode)
        self.assertNotEqual(self.raw(opencode), before)
        code, said = self.cli("describe", "reset", "--", "impeccable", opencode)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.raw(opencode), before)

    def test_a_file_this_name_does_not_reach_is_refused_by_name(self):
        # An absolute path is still only a path. The files this verb may open are
        # the ones the name already resolves to, and every other one is named in
        # the refusal rather than quietly written.
        self.two_copies()
        stranger = self.plain("elsewhere")
        untouched = self.raw(stranger)
        code, said = self.describe("impeccable", self.TEXT, path=stranger)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("is not one of the 2 files this name reaches", said["detail"])
        self.assertEqual(self.raw(stranger), untouched)
        self.assertEqual(ax.read_describe_store()["edited"], {})

    def test_a_path_that_is_not_absolute_is_refused_before_anything_is_read(self):
        # The panel sends the helper's own realPath. A relative one could only
        # have been rebuilt from a display string, and there is no working
        # directory this program ever chose for it to be relative to. Refused
        # before the name is even resolved, on both verbs that take a path.
        self.plain()
        self.addCleanup(setattr, ax, "_describe_candidates", ax._describe_candidates)
        ax._describe_candidates = lambda *a, **k: self.fail("a relative path was acted on")
        for argv in (("write", "--", "plain", "plain/SKILL.md", "Some text."),
                     ("reset", "--", "plain", "plain/SKILL.md")):
            code, said = self.cli("describe", *argv)
            self.assertEqual((code, said["ok"]), (2, False), argv)
            self.assertIn("absolute", said["detail"], argv)
        self.assertEqual(ax.read_describe_store()["edited"], {})

    def test_a_link_and_the_file_it_points_at_are_the_same_target(self):
        # The shape a dotfiles manager leaves: the skill lives in a checkout and
        # the root holds a link to it. The panel has the real path and the walk
        # has the name it was found under, so the two are matched through
        # realpath rather than compared as strings.
        elsewhere = os.path.join(self.home, "checkout")
        os.makedirs(elsewhere)
        real = self.write("dotfiles", "name: dotfiles\ndescription: Kept in a checkout.\n",
                          root=elsewhere)
        os.symlink(os.path.join(elsewhere, "dotfiles"), os.path.join(self.root, "dotfiles"))
        code, said = self.describe("dotfiles", self.TEXT, path=real)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(real), self.TEXT)


class DescriptionEditIsPerFile(DescribeCase):
    """An edit is a fact about one SKILL.md, never about the name over it.

    Two copies of a name are the ordinary case here -- impeccable ships one
    build for OpenCode and another inside a Claude Code plugin, and this machine
    carries both -- and the store records the file each entry was written to.
    Keyed by the name alone, the copy nobody had touched read as edited, said it
    had been hand edited, and offered the OTHER file's description as the
    author's text reset would put back: three claims about one file, every one of
    them drawn from what had happened to a different one.
    """

    TEXT = "One line about it, for the agent to read."
    NOTE = "And a note of my own, which belongs to the name."
    CLAUDE = "The copy Claude Code reads."
    OPENCODE = "The copy OpenCode reads instead."

    def two_copies(self):
        claude = self.write("impeccable",
                            f"name: impeccable\ndescription: {self.CLAUDE}\n")
        opencode = self.write("impeccable",
                              f"name: impeccable\ndescription: {self.OPENCODE}\n",
                              root=os.path.join(self.home, ".config", "opencode", "skills"))
        return claude, opencode

    def row_for(self, skill_md):
        """The row this file was drawn from. Both rows carry the same dirName,
        so the file is what tells them apart -- which is the whole point."""
        directory = os.path.dirname(os.path.realpath(skill_md))
        return next(i for i in ax.scan()["items"] if i["realPath"] == directory)

    def test_the_copy_that_does_not_hold_it_says_where_it_is(self):
        # Only one copy at a time can be put back, so the other one cannot be
        # written either. Saying so on the card is the difference between a
        # control that explains itself and one the helper refuses after the
        # window has already closed.
        claude, opencode = self.two_copies()
        self.describe("impeccable", self.TEXT, path=claude)

        held = self.row_for(claude)["describe"]
        self.assertTrue(held["edited"])
        self.assertIsNone(held["otherCopy"])
        self.assertTrue(held["canWrite"])

        other = self.row_for(opencode)["describe"]
        self.assertFalse(other["edited"])
        self.assertFalse(other["handEdited"])
        self.assertEqual(other["authorText"], self.OPENCODE)
        self.assertFalse(other["canWrite"])
        self.assertIn("impeccable", other["otherCopy"])
        self.assertIn("another copy of this name", other["whyNot"])

    def test_nothing_names_another_copy_when_no_edit_has_happened(self):
        claude, opencode = self.two_copies()
        self.note("impeccable", self.NOTE)
        for path in (claude, opencode):
            d = self.row_for(path)["describe"]
            self.assertIsNone(d["otherCopy"], path)
            self.assertTrue(d["canWrite"], path)

    def test_only_the_copy_that_was_written_reads_edited(self):
        claude, opencode = self.two_copies()
        code, said = self.describe("impeccable", self.TEXT, path=opencode)
        self.assertEqual((code, said["ok"]), (0, True))
        written = self.row_for(opencode)["describe"]
        self.assertTrue(written["edited"])
        self.assertEqual(written["fileText"], self.TEXT)
        self.assertEqual(written["authorText"], self.OPENCODE)
        self.assertFalse(written["handEdited"])
        # This file was never written, so it is not edited and not hand edited
        # either, and the text reset would put back here is its own.
        untouched = self.row_for(claude)["describe"]
        self.assertFalse(untouched["edited"])
        self.assertEqual(untouched["fileText"], self.CLAUDE)
        self.assertEqual(untouched["authorText"], self.CLAUDE)
        self.assertFalse(untouched["handEdited"])

    def test_a_note_belongs_to_the_name_and_shows_on_both_copies(self):
        # The other half of the same rule, and the reason the two halves of the
        # store are keyed differently: an edit is one file's, a note is the
        # name's, and every copy of the name draws it above its own description.
        claude, opencode = self.two_copies()
        self.note("impeccable", self.NOTE)
        self.describe("impeccable", self.TEXT, path=opencode)
        for path in (claude, opencode):
            self.assertEqual(self.row_for(path)["describe"]["noteText"], self.NOTE, path)

    def test_reset_on_the_copy_nobody_wrote_to_touches_neither_file(self):
        claude, opencode = self.two_copies()
        self.describe("impeccable", self.TEXT, path=opencode)
        written, other = self.raw(opencode), self.raw(claude)
        code, said = self.cli("describe", "reset", "--", "impeccable", claude)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("opencode/skills/impeccable/SKILL.md", said["detail"])
        self.assertEqual(self.raw(opencode), written)
        self.assertEqual(self.raw(claude), other)
        # The entry is the only way back to the author's words in the file that
        # does carry ours, so a refusal keeps it rather than forgetting it.
        self.assertEqual(ax.read_describe_store()["edited"]["impeccable"]["original"],
                         self.OPENCODE)
        self.assertTrue(self.row_for(opencode)["describe"]["edited"])

    def test_the_second_copy_is_not_written_while_the_first_carries_it(self):
        # One entry per name holds one author's text. Writing the second copy
        # would drop the first file's, leaving that file carrying our words with
        # nothing left to put back, so it is refused and the copy that has them
        # is named.
        claude, opencode = self.two_copies()
        self.describe("impeccable", self.TEXT, path=opencode)
        before = self.raw(claude)
        code, said = self.describe("impeccable", "Another go at it.", path=claude)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("opencode/skills/impeccable/SKILL.md", said["detail"])
        self.assertEqual(self.raw(claude), before)
        self.assertEqual(ax.read_describe_store()["edited"]["impeccable"]["original"],
                         self.OPENCODE)

    def test_an_entry_that_names_no_file_claims_nothing(self):
        """An entry from a store written before the file was recorded. It could
        have been any copy of the name, so it is treated as none of them: the
        row reads as its author's rather than claiming an edit that may have
        happened somewhere else, and nothing offers to put back a description
        this file's author never wrote."""
        self.plain()
        os.makedirs(ax.STORE_DIR, mode=0o700, exist_ok=True)
        with open(ax.DESCRIBE_PATH, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "notes": {},
                       "edited": {"plain": {"original": "An older wording of it.",
                                            "wrote": "Not what this file says.",
                                            "at": 0}}}, fh)
        self.assertEqual(ax.read_describe_store()["edited"]["plain"]["file"], "")
        described = self.row("plain")["describe"]
        self.assertFalse(described["edited"])
        self.assertEqual(described["authorText"], self.AUTHOR)
        self.assertFalse(described["handEdited"])


class DescriptionWriteIsCrashSafe(DescribeCase):
    """The author's words are recorded before the file is touched, and every path
    out of the verb prints its one line of JSON.

    Recorded after, a store that could not be written left the SKILL.md already
    rewritten with the only copy of the original held nowhere -- and a traceback
    where the JSON should have been, so the panel reported failure for a write
    that had happened. A full disk, a quota and a read-only $HOME all arrive
    here; an unwritable store directory is the same shape and the one a test can
    make.
    """

    SHORT = "Short enough to be worth the trouble."

    def run_main(self, *argv):
        """Driven through main rather than through `cli`, which parses whatever
        it is given: what is being asserted is that exactly one line was printed,
        and an empty stdout has to fail rather than read as an empty answer."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = ax.main(list(argv))
        printed = [line for line in out.getvalue().split("\n") if line.strip()]
        self.assertEqual(len(printed), 1, out.getvalue())
        return code, json.loads(printed[0])

    def unwritable_store(self):
        os.makedirs(ax.STORE_DIR, mode=0o700, exist_ok=True)
        os.chmod(ax.STORE_DIR, 0o500)
        self.addCleanup(os.chmod, ax.STORE_DIR, 0o700)

    def test_a_store_that_cannot_be_written_leaves_the_skill_md_alone(self):
        path = self.plain()
        before = self.raw(path)
        self.unwritable_store()
        code, said = self.run_main("describe", "write", "--", "plain", path, self.SHORT)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertEqual(self.raw(path), before)
        self.assertEqual(ax.read_describe_store()["edited"], {})

    def test_a_note_that_cannot_be_stored_answers_in_one_line_too(self):
        self.plain()
        self.unwritable_store()
        code, said = self.run_main("describe", "note", "--", "plain", "Mine.")
        self.assertEqual((code, said["ok"]), (2, False))

    def test_an_entry_recorded_for_a_write_that_failed_goes_back(self):
        """The other half of the ordering: the entry is recorded first, so a
        write that then fails has to take it away again, or the row would say a
        file carries our text when the author's is still in it."""
        path = self.plain()
        before = self.raw(path)
        self.addCleanup(setattr, ax, "_write_description", ax._write_description)
        ax._write_description = lambda *a, **k: "the disk would not take it"
        code, said = self.describe("plain", self.SHORT)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("the disk would not take it", said["detail"])
        self.assertEqual(self.raw(path), before)
        self.assertEqual(ax.read_describe_store()["edited"], {})
        self.assertFalse(self.row("plain")["describe"]["edited"])

    def test_a_reset_the_store_could_not_record_can_be_finished_later(self):
        """Reset writes the file and forgets the entry, in that order, because
        the other order loses the author's words when the write fails. So the
        store that could not be written leaves a file already back to its
        author's text and an entry still saying otherwise -- and without a way
        through that, every later reset would refuse the file for not saying what
        we wrote, and the row would read as hand-edited for good."""
        path = self.plain()
        before = self.raw(path)
        self.describe("plain", self.SHORT)
        self.unwritable_store()
        code, said = self.run_main("describe", "reset", "--", "plain", path)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertEqual(self.raw(path), before)
        self.assertIn("plain", ax.read_describe_store()["edited"])

        os.chmod(ax.STORE_DIR, 0o700)
        code, said = self.cli("describe", "reset", "--", "plain", path)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(ax.read_describe_store(), {"notes": {}, "edited": {}})
        self.assertFalse(self.row("plain")["describe"]["edited"])

    def test_a_second_write_that_fails_keeps_the_first_author_text(self):
        # The rollback puts the entry back rather than dropping it: the first
        # write is still true, and `original` is still the author's own words.
        path = self.plain()
        self.describe("plain", self.SHORT)
        self.addCleanup(setattr, ax, "_write_description", ax._write_description)
        ax._write_description = lambda *a, **k: "the disk would not take it"
        code, said = self.describe("plain", "A third wording of it.")
        self.assertEqual((code, said["ok"]), (2, False))
        entry = ax.read_describe_store()["edited"]["plain"]
        self.assertEqual(entry["original"], self.AUTHOR)
        self.assertEqual(entry["wrote"], self.SHORT)
        self.assertEqual(self.described(path), self.SHORT)


class DescriptionReset(DescribeCase):
    """Back to what the author wrote, and only where that can be done exactly.
    A file somebody has edited since is left alone and said so about, because
    there is no version of overwriting it that the person who typed it would
    thank us for."""

    SHORT = "A shorter way of saying it."
    NOTE = "Mine, and no reset takes it away."

    def test_reset_after_a_write_puts_the_file_back_byte_for_byte(self):
        path = self.plain()
        before = self.raw(path)
        self.describe("plain", self.SHORT)
        self.assertNotEqual(self.raw(path), before)
        code, said = self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.raw(path), before)
        # And the entry is forgotten, so the row is its author's again in every
        # way the panel can see.
        self.assertEqual(ax.read_describe_store()["edited"], {})
        described = self.row("plain")["describe"]
        self.assertFalse(described["edited"])
        self.assertEqual(described["fileText"], self.AUTHOR)
        self.assertEqual(described["authorText"], self.AUTHOR)

    def test_the_token_figure_comes_back_with_the_text(self):
        self.plain()
        before = self.row("plain")["tokens"]["alwaysOn"]
        self.describe("plain", self.SHORT)
        self.assertNotEqual(self.row("plain")["tokens"]["alwaysOn"], before)
        self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual(self.row("plain")["tokens"]["alwaysOn"], before)

    def test_resetting_the_description_keeps_the_note(self):
        # The two fields are independent, and this is the direction that used to
        # be impossible to state: under the model this replaced, reset dropped
        # the note as well, because the note was where the description came from.
        path = self.plain()
        before = self.raw(path)
        self.note("plain", self.NOTE)
        self.describe("plain", self.SHORT)
        code, said = self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.raw(path), before)
        self.assertEqual(ax.read_describe_store()["notes"]["plain"], self.NOTE)
        self.assertEqual(self.row("plain")["describe"]["noteText"], self.NOTE)

    def test_reset_with_nothing_to_undo_never_opens_the_file(self):
        path = self.plain()
        before = self.raw(path)
        self.note("plain", self.NOTE)
        self.addCleanup(setattr, ax, "_write_description", ax._write_description)
        self.addCleanup(setattr, ax, "_describe_candidates", ax._describe_candidates)
        ax._write_description = lambda *a, **k: self.fail("reset wrote a file it never wrote to")
        ax._describe_candidates = lambda *a, **k: self.fail("reset went looking for nothing")
        code, said = self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.raw(path), before)
        # It is not a way of clearing the note either.
        self.assertEqual(ax.read_describe_store()["notes"]["plain"], self.NOTE)

    def test_a_hand_edit_is_refused_and_said_so_about(self):
        path = self.plain()
        self.describe("plain", self.SHORT)
        self.write("plain", "name: plain\ndescription: Typed here by hand.\n")
        edited = self.raw(path)
        code, said = self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("changed by hand", said["detail"])
        self.assertEqual(self.raw(path), edited)
        # The store keeps the entry: nothing was undone, so there is nothing to
        # forget, and the row goes on saying what happened to the file.
        self.assertIn("plain", ax.read_describe_store()["edited"])

    def test_that_hand_edit_shows_on_the_row(self):
        self.plain()
        self.describe("plain", self.SHORT)
        self.assertFalse(self.row("plain")["describe"]["handEdited"])
        self.write("plain", "name: plain\ndescription: Typed here by hand.\n")
        described = self.row("plain")["describe"]
        self.assertTrue(described["handEdited"])
        self.assertTrue(described["edited"])
        self.assertEqual(described["fileText"], "Typed here by hand.")
        self.assertEqual(described["authorText"], self.AUTHOR)

    def test_resetting_what_was_never_written_is_not_an_error(self):
        self.plain()
        code, said = self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual((code, said["ok"]), (0, True))

    def test_a_second_write_keeps_the_author_rather_than_our_own_text(self):
        # `original` is recorded once. Overwriting it on the second write would
        # leave reset restoring our first wording as though the author had
        # written it, and the author's words would be gone for good.
        path = self.plain()
        before = self.raw(path)
        self.describe("plain", self.SHORT)
        self.describe("plain", "A third wording of it.")
        self.assertEqual(ax.read_describe_store()["edited"]["plain"]["original"], self.AUTHOR)
        self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual(self.raw(path), before)


class DescriptionShapes(DescribeCase):
    """The hard half: a description is written in four different ways in the
    files on a real machine, and a replacement that handles a plain one-line
    value and mangles a block scalar is worse than no feature at all. Three of
    this machine's own skills write theirs as a folded block, and one carries a
    bare colon inside a quoted one."""

    FOLDED = ("name: folded\n"
              "description: >\n"
              "  REQUIRED for end-user customization of Linux desktop, window manager,\n"
              "  or system config. Triggers: Hyprland, window rules, keybindings.\n"
              "metadata:\n"
              "  version: 1.4.0\n")
    FOLDED_TEXT = ("REQUIRED for end-user customization of Linux desktop, window manager, "
                   "or system config. Triggers: Hyprland, window rules, keybindings.")
    TEXT = "Hyprland and desktop config: window rules, keybindings, themes."

    def test_a_folded_block_survives_a_write_and_a_reset(self):
        path = self.write("folded", self.FOLDED)
        row = self.row("folded")
        self.assertEqual(row["describe"]["fileText"], self.FOLDED_TEXT)
        # The figure a line-oriented replacement would report here is about two.
        self.assertGreater(row["tokens"]["alwaysOn"], 30)

        self.describe("folded", self.TEXT)
        self.assertEqual(self.described(path), self.TEXT)
        self.assertEqual(self.row("folded")["describe"]["fileText"], self.TEXT)
        # The key that followed the block is still a key, not four lines of prose
        # swallowed by a span that ran on past the end of the value.
        self.assertEqual(self.row("folded")["declaredVersion"], "1.4.0")

        # What comes back is the author's text to the character and the author's
        # cost to the token. The four lines they folded it over are this
        # program's to write now, and it writes one -- which is why the file is
        # not byte for byte what it was and the assertions here are about the
        # text rather than the bytes.
        self.cli("describe", "reset", "--", "folded", self.skill_md("folded"))
        self.assertEqual(self.described(path), self.FOLDED_TEXT)
        self.assertEqual(self.row("folded")["tokens"]["alwaysOn"], row["tokens"]["alwaysOn"])
        with open(path, encoding="utf-8") as fh:
            self.assertIn("metadata:\n  version: 1.4.0\n", fh.read())

    def indicated(self, header):
        """The same block, with an indentation indicator in its header.

        YAML lets the chomping indicator and the indentation indicator be written
        in either order, so `>2`, `>-2` and `|+2` are all one header and none of
        them is text. A parser that knew only the chomping half read the whole
        header as the start of the description.
        """
        return self.write("indicated",
                          "name: indicated\n"
                          f"description: {header}\n"
                          "  REQUIRED for end-user customization of Linux desktop, "
                          "window manager,\n"
                          "  or system config. Triggers: Hyprland, window rules, keybindings.\n"
                          "metadata:\n"
                          "  version: 1.4.0\n")

    def test_an_indentation_indicator_is_never_part_of_the_description(self):
        for header in (">2", "|2", ">-2", "|+2"):
            with self.subTest(header=header):
                path = self.indicated(header)
                row = self.row("indicated")
                self.assertEqual(row["describe"]["fileText"], self.FOLDED_TEXT)
                self.assertNotIn(header, row["describe"]["fileText"])
                # The figure follows the text, so a header read as prose moved it.
                self.assertEqual(row["tokens"]["alwaysOn"],
                                 ax.token_estimate("indicated", self.FOLDED_TEXT, "", 4))
                self.assertEqual(row["declaredVersion"], "1.4.0")

                code, said = self.describe("indicated", self.TEXT, path=path)
                self.assertEqual((code, said["ok"]), (0, True), said)
                self.assertEqual(self.described(path), self.TEXT)
                # The crux: what was recorded for the undo is the author's text
                # and not the header. Recorded with the indicator on the front,
                # reset wrote `description: '>2 REQUIRED for …'` into the file
                # and the author's words were gone for good.
                self.assertEqual(
                    ax.read_describe_store()["edited"]["indicated"]["original"],
                    self.FOLDED_TEXT)

                code, said = self.cli("describe", "reset", "--", "indicated", path)
                self.assertEqual((code, said["ok"]), (0, True), said)
                self.assertEqual(self.described(path), self.FOLDED_TEXT)
                self.assertEqual(self.row("indicated")["declaredVersion"], "1.4.0")

    def test_a_block_header_this_parser_cannot_read_whole_is_refused(self):
        # Better to refuse than to begin a round trip reset cannot finish: an
        # `original` taken from a header we misread is not the author's text, and
        # reset would write our misreading back into their file for good.
        for header in (">-2-", "|22", "> and then some prose", "|-+"):
            with self.subTest(header=header):
                path = self.write("odd", f"name: odd\ndescription: {header}\n"
                                         "  Some description text.\n")
                before = self.raw(path)
                code, said = self.describe("odd", self.TEXT, path=path)
                self.assertEqual((code, said["ok"]), (2, False), said)
                self.assertIn("block scalar", said["detail"])
                self.assertEqual(self.raw(path), before)
                self.assertEqual(ax.read_describe_store()["edited"], {})

    def test_a_literal_block_is_read_and_written_the_same_way(self):
        path = self.write("literal", "name: literal\ndescription: |\n"
                                     "  One line of it.\n  And a second.\n")
        self.assertEqual(self.row("literal")["describe"]["fileText"],
                         "One line of it. And a second.")
        self.describe("literal", self.TEXT)
        self.assertEqual(self.described(path), self.TEXT)

    def test_a_colon_a_quote_and_non_ascii_all_round_trip(self):
        # n8n-sdk-server is the file this is drawn from: a bare `Triggers on:`
        # inside the description, which is what makes a generic YAML writer drop
        # the whole frontmatter rather than the one field.
        path = self.write("quoted", "name: quoted\ndescription: 'Read this one FIRST. "
                                    "Triggers on: n8n, \"workflow\", spójne wywołania.'\n")
        self.assertIn("Triggers on:", self.row("quoted")["describe"]["fileText"])
        text = 'Use FIRST for n8n. Triggers on: n8n, "workflow", spójne wywołania — ćwiczenia.'
        self.describe("quoted", text)
        self.assertEqual(self.described(path), text)
        self.assertEqual(self.row("quoted")["describe"]["fileText"], text)

    def test_a_text_with_both_kinds_of_quote_still_lands_exactly(self):
        # Neither quoting carries this, and nothing is escaped on purpose: the
        # read-back goes through the same parser the agents use, which strips a
        # pair of quotes and does not undo escapes, so an escaped quote would come
        # back with its backslash still on it.
        path = self.plain("both")
        text = """He said "it's fine" — and the description says so: plainly."""
        code, said = self.describe("both", text)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(path), text)
        with open(path, encoding="utf-8") as fh:
            self.assertIn("description: >-\n  " + text, fh.read())

    def test_a_value_a_reader_would_take_for_something_else_is_quoted(self):
        for value in ("true", "No", "null", "12.5", "- a dash to start with",
                      "a colon: in the middle", "trailing hash # here", "ends with a colon:"):
            rendered = ax._render_description(value)
            self.assertEqual(len(rendered), 1, value)
            self.assertNotEqual(rendered[0], f"description: {value}", value)
            self.assertEqual(ax.parse_frontmatter_block("\n".join(rendered))["description"],
                             value, value)

    def test_an_ordinary_sentence_is_written_plainly(self):
        self.assertEqual(ax._render_description("An ordinary description of a skill."),
                         ["description: An ordinary description of a skill."])

    def test_a_frontmatter_we_would_have_to_guess_at_is_refused(self):
        for name, frontmatter in (
                ("twice", "name: twice\ndescription: One.\ndescription: Two.\n"),
                ("mapping", "name: mapping\ndescription:\n  text: One.\n"),
                ("absent", "name: absent\nargument-hint: \"[x]\"\n")):
            self.write(name, frontmatter)
            code, said = self.describe(name, self.TEXT)
            self.assertEqual((code, said["ok"]), (2, False), name)
            self.assertIn("was left alone", said["detail"], name)

    def test_a_description_the_author_left_blank_is_the_one_worth_filling_in(self):
        # `no-description` is already a row the panel flags. An empty value is a
        # value, unlike the mapping above, so this is the one case where a write
        # puts a skill's description on the page for the first time.
        path = self.write("blank", "name: blank\ndescription:\nmetadata:\n  version: 1.0.0\n")
        self.assertIn("no-description", self.row("blank")["attention"])
        code, said = self.describe("blank", self.TEXT)
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(path), self.TEXT)
        self.assertEqual(self.row("blank")["declaredVersion"], "1.0.0")

    def test_carriage_returns_are_left_alone_rather_than_mixed(self):
        directory = os.path.join(self.root, "dos")
        os.makedirs(directory)
        with open(os.path.join(directory, "SKILL.md"), "w", encoding="utf-8", newline="") as fh:
            fh.write("---\r\nname: dos\r\ndescription: Written on another machine.\r\n"
                     "---\r\n\r\n# Body\r\n")
        code, said = self.describe("dos", self.TEXT)
        self.assertEqual((code, said["ok"]), (2, False))
        self.assertIn("carriage returns", said["detail"])

    def test_a_description_longer_than_the_bound_is_clipped(self):
        path = self.plain("long")
        self.describe("long", "x" * (ax.MAX_DESCRIPTION + 200))
        self.assertEqual(len(self.described(path)), ax.MAX_DESCRIPTION)


class DescriptionStore(DescribeCase):
    """The second file this plugin owns. It is read on every scan, so a store
    that cannot be parsed has to read as an empty one and say so -- an entry
    quietly half-read is one that would have reset writing a guess into somebody
    else's file."""

    def test_a_store_of_the_wrong_shape_reads_as_an_empty_one(self):
        os.makedirs(ax.STORE_DIR, mode=0o700)
        for doc in ('{"notes": "not a mapping"}', '{"notes": {"a/b": "text"}}',
                    '{"notes": {"ok": 12}}', '{"notes": {"ok": "   "}}', "[]"):
            with open(ax.DESCRIBE_PATH, "w", encoding="utf-8") as fh:
                fh.write(doc)
            self.assertEqual(ax.read_describe_store()["notes"], {}, doc)

    def test_an_edited_entry_missing_a_half_is_dropped_whole(self):
        os.makedirs(ax.STORE_DIR, mode=0o700)
        for doc in ('{"edited": {"a": {"wrote": "x"}}}',
                    '{"edited": {"a": {"original": "x"}}}',
                    '{"edited": {"a": "not a mapping"}}'):
            with open(ax.DESCRIBE_PATH, "w", encoding="utf-8") as fh:
                fh.write(doc)
            self.assertEqual(ax.read_describe_store()["edited"], {}, doc)

    def test_an_edited_entry_naming_a_relative_file_names_none(self):
        # A path this program never wrote. There is no working directory it
        # could be relative to, so it names no copy of the skill rather than
        # whichever one the panel happened to be launched from.
        os.makedirs(ax.STORE_DIR, mode=0o700)
        with open(ax.DESCRIBE_PATH, "w", encoding="utf-8") as fh:
            fh.write('{"edited": {"a": {"original": "x", "wrote": "y", '
                     '"file": "a/SKILL.md"}}}')
        self.assertEqual(ax.read_describe_store()["edited"]["a"]["file"], "")

    def test_a_store_that_still_says_applied_is_read_as_edited(self):
        """The key was called `applied` while a note was a thing you applied.
        Nothing is applied any more, but a store the shipped code wrote holds
        real author text under the old name, and dropping it would leave those
        files carrying our words with nothing left to put them back."""
        path = self.plain()
        os.makedirs(ax.STORE_DIR, mode=0o700, exist_ok=True)
        with open(ax.DESCRIBE_PATH, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "notes": {"plain": "A note from before."},
                       "applied": {"plain": {"original": self.AUTHOR,
                                             "wrote": "What the widget put there.",
                                             "at": 1757000000, "file": path}}}, fh)
        store = ax.read_describe_store()
        self.assertEqual(store["edited"]["plain"]["original"], self.AUTHOR)
        self.assertEqual(store["edited"]["plain"]["file"], path)
        self.assertEqual(store["notes"]["plain"], "A note from before.")

        # And the row reads it as an edit, so the way back is still offered.
        self.write("plain", "name: plain\ndescription: What the widget put there.\n")
        described = self.row("plain")["describe"]
        self.assertTrue(described["edited"])
        self.assertFalse(described["handEdited"])
        self.assertEqual(described["authorText"], self.AUTHOR)
        code, said = self.cli("describe", "reset", "--", "plain", self.skill_md("plain"))
        self.assertEqual((code, said["ok"]), (0, True))
        self.assertEqual(self.described(path), self.AUTHOR)
        # Rewritten under the name it is kept under now, with nothing left of the
        # old one to be read twice.
        with open(ax.DESCRIBE_PATH, encoding="utf-8") as fh:
            written = json.load(fh)
        self.assertEqual(written["edited"], {})
        self.assertNotIn("applied", written)

    def test_a_refused_store_is_reported_rather_than_forgotten(self):
        os.makedirs(ax.STORE_DIR, mode=0o700)
        with open(ax.DESCRIBE_PATH, "w", encoding="utf-8") as fh:
            fh.write('{"notes": {"plain": "mine"}}')
        os.chmod(ax.DESCRIBE_PATH, 0o666)
        findings: list = []
        self.assertEqual(ax.read_describe_store(findings)["notes"], {})
        self.assertEqual([f["what"] for f in findings], ["descriptions.json"])
        self.assertIn("world-writable", findings[0]["detail"])

    def test_the_store_is_written_for_this_user_alone(self):
        self.plain()
        self.note("plain", "Mine.")
        self.assertEqual(stat.S_IMODE(os.stat(ax.DESCRIBE_PATH).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(ax.STORE_DIR).st_mode), 0o700)

    def test_the_two_stores_stay_out_of_each_other_s_way(self):
        # One file names categories and the other names descriptions, and either
        # can be deleted on its own: a reader who throws away their notes should
        # not find every skill back under the classifier's guess as well.
        self.plain()
        # The category verb answers in a sentence rather than in JSON, so it is
        # driven here rather than through the helper the describe tests use.
        with contextlib.redirect_stdout(io.StringIO()):
            ax.main(["category", "assign", "--", "plain", "code"])
        self.note("plain", "Mine.")
        os.unlink(ax.DESCRIBE_PATH)
        row = self.row("plain")
        self.assertEqual(row["taxonomy"]["category"], "code")
        self.assertIsNone(row["describe"]["noteText"])
        self.assertFalse(row["describe"]["edited"])


if __name__ == "__main__":
    unittest.main()
