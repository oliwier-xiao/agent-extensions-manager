"""Unit tests for the parts of agent-skills that do not touch this machine's config.

Run: python3 -m unittest discover -s tests -v
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
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


if __name__ == "__main__":
    unittest.main()
