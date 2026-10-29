#!/usr/bin/env python3
"""Tests for agents_sync.py over a throwaway repository root: python scripts/test_agents_sync.py"""

import contextlib
import hashlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

import agents_sync

SKILL = """---
name: sm-a
description: Does the a thing. Load for ANY task about a, e.g. "do a".
---
# A

See [the reference](references/r.md). The sm-x agent uses it.
"""

AGENT = """---
name: sm-x
description: Agent x, read-only.
tools: Read, Grep
model: opus
skills:
  - sm-a
---
Read sm-a first, then act.
"""


def write(path, text):
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_text(text, encoding="utf-8", newline="\n")


class AgentsSyncTests(unittest.TestCase):
	def setUp(self):
		self.tmp = Path(tempfile.mkdtemp())
		self.addCleanup(shutil.rmtree, self.tmp, True)
		write(self.tmp / ".claude/skills/sm-a/SKILL.md", SKILL)
		write(self.tmp / ".claude/skills/sm-a/references/r.md", "# r\n")
		write(self.tmp / ".claude/agents/sm-x.md", AGENT)
		write(self.tmp / ".claude/settings.json", json.dumps({"permissions": {"deny": ["Edit(.agents/**)"]}}))

	def run_sync(self, *flags):
		out = io.StringIO()
		with contextlib.redirect_stdout(out):
			code = agents_sync.main(["--root", str(self.tmp), *flags])
		return code, out.getvalue().splitlines()

	def mirror(self, rel):
		return self.tmp / ".agents/skills" / rel

	def test_sync_writes_mirror_and_manifest(self):
		code, lines = self.run_sync()
		self.assertEqual(code, 0, lines)
		self.assertTrue(lines[0].startswith("ok agents: 1 skill(s), 1 agent(s); 4 file(s) updated"), lines)
		self.assertEqual(self.mirror("sm-a/references/r.md").read_bytes(), b"# r\n")
		manifest = json.loads(self.mirror(".manifest.json").read_text())
		self.assertEqual(manifest["source"], ".claude/skills")
		self.assertEqual(sorted(manifest["files"]), ["sm-a/SKILL.md", "sm-a/references/r.md"])
		want = hashlib.sha256((self.tmp / ".claude/skills/sm-a/SKILL.md").read_bytes()).hexdigest()
		self.assertEqual(manifest["files"]["sm-a/SKILL.md"], want)

	def test_check_passes_after_sync(self):
		self.run_sync()
		code, lines = self.run_sync("--check")
		self.assertEqual(code, 0, lines)
		self.assertIn("mirror current", lines[0])

	def test_check_reports_edited_source(self):
		self.run_sync()
		with open(self.tmp / ".claude/skills/sm-a/SKILL.md", "a", encoding="utf-8", newline="\n") as f:
			f.write("\nAnother line.\n")
		code, lines = self.run_sync("--check")
		self.assertEqual(code, 1, lines)
		self.assertEqual(lines[0], "FAIL agents: 2 file(s) out of date")
		self.assertIn("  stale .agents/skills/sm-a/SKILL.md", lines)
		self.assertIn("  stale .agents/skills/.manifest.json", lines)
		self.assertEqual(lines[-1], "run: python scripts/agents_sync.py")
		self.assertEqual(self.run_sync()[0], 0)
		self.assertEqual(self.run_sync("--check")[0], 0)

	def test_sync_deletes_stale_files(self):
		self.run_sync()
		write(self.mirror("gone/SKILL.md"), "old\n")
		code, lines = self.run_sync("--check")
		self.assertEqual(code, 1)
		self.assertIn("  extra .agents/skills/gone/SKILL.md", lines)
		code, lines = self.run_sync()
		self.assertEqual(code, 0)
		self.assertIn("  removed .agents/skills/gone/SKILL.md", lines)
		self.assertFalse(self.mirror("gone").exists())

	def test_crlf_mirror_still_matches(self):
		self.run_sync()
		p = self.mirror("sm-a/SKILL.md")
		p.write_bytes(p.read_bytes().replace(b"\n", b"\r\n"))
		code, lines = self.run_sync("--check")
		self.assertEqual(code, 0, lines)

	def test_invalid_skills_are_reported_and_not_mirrored(self):
		self.run_sync()
		before = sorted(p.as_posix() for p in self.mirror("").rglob("*"))
		bad = {
			"sm-b": SKILL.replace("name: sm-a", "name: sm-bee"),
			"sm-c": SKILL.replace("Does the a thing.", "Does <b>bold</b> things."),
			"sm-d": SKILL.replace("---\n# A", "paths: src/**\n---\n# A"),
			"sm-e": SKILL.replace("references/r.md", "references/missing.md"),
			"sm-f": SKILL.replace("The sm-x agent", "Requires sm-nope; the sm-x agent"),
		}
		for name, text in bad.items():
			write(self.tmp / ".claude/skills" / name / "SKILL.md", text.replace("name: sm-a", f"name: {name}", 1) if name != "sm-b" else text)
			write(self.tmp / ".claude/skills" / name / "references/r.md", "# r\n")
		code, lines = self.run_sync()
		self.assertEqual(code, 1, lines)
		self.assertEqual(lines[0], "FAIL agents: 5 problem(s)", lines)
		text = "\n".join(lines)
		self.assertIn("sm-b/SKILL.md: name 'sm-bee' does not match its directory 'sm-b'", text)
		self.assertIn("sm-c/SKILL.md: description contains an XML tag", text)
		self.assertIn("sm-d/SKILL.md: unknown frontmatter key 'paths'", text)
		self.assertIn("sm-e/SKILL.md: link 'references/missing.md' does not exist", text)
		self.assertIn("sm-f/SKILL.md: mentions 'sm-nope', which is not a skill or agent", text)
		self.assertEqual(sorted(p.as_posix() for p in self.mirror("").rglob("*")), before)

	def test_agent_rules(self):
		write(self.tmp / ".claude/agents/sm-y.md", AGENT.replace("name: sm-x", "name: sm-y").replace("skills:\n  - sm-a", "skill:\n  - sm-missing"))
		write(self.tmp / ".claude/settings.json", json.dumps({"permissions": {"deny": []}}))
		code, lines = self.run_sync()
		self.assertEqual(code, 1, lines)
		text = "\n".join(lines)
		self.assertIn("sm-y.md: unknown frontmatter key 'skill' (did you mean 'skills'?)", text)
		self.assertIn(".claude/settings.json: permissions.deny lacks Edit(.agents/**)", text)
		write(self.tmp / ".claude/agents/sm-y.md", AGENT.replace("name: sm-x", "name: sm-y").replace("- sm-a", "- sm-missing"))
		code, lines = self.run_sync()
		self.assertIn("sm-y.md: skills: 'sm-missing' is not a directory in .claude/skills", "\n".join(lines))

	def test_body_length_rules(self):
		write(self.tmp / ".claude/skills/sm-a/SKILL.md", SKILL + "line\n" * 300) # a 3-line body plus 300
		code, lines = self.run_sync()
		self.assertEqual(code, 0, lines)
		self.assertTrue(any("warning:" in l and "lines (keep under 300" in l for l in lines), lines)
		write(self.tmp / ".claude/skills/sm-a/SKILL.md", SKILL + "line\n" * 500)
		code, lines = self.run_sync()
		self.assertEqual(code, 1, lines)
		self.assertTrue(any("lines (limit 500" in l for l in lines), lines)

	def test_zero_skills_is_valid(self):
		shutil.rmtree(self.tmp / ".claude/skills")
		(self.tmp / ".claude/agents/sm-x.md").unlink()
		code, lines = self.run_sync()
		self.assertEqual(code, 0, lines)
		self.assertTrue(lines[0].startswith("ok agents: 0 skill(s), 0 agent(s)"), lines)
		self.assertTrue(any("warning: no skills" in l for l in lines), lines)

	def codex(self, name):
		return self.tmp / ".codex/agents" / f"{name}.toml"

	def test_sync_writes_codex_agents(self):
		self.run_sync()
		want = 'name = "sm-x"\ndescription = "Agent x, read-only."\ndeveloper_instructions = \'\'\'\nRead sm-a first, then act.\'\'\'\n'
		self.assertEqual(self.codex("sm-x").read_text(encoding="utf-8"), want)

	def test_codex_description_forms_and_effort(self):
		quoted = AGENT.replace("Agent x, read-only.", 'Agent x for "this", read-only.')
		write(self.tmp / ".claude/agents/sm-x.md", quoted.replace("model: opus", "model: opus\neffort: low"))
		both = AGENT.replace("name: sm-x", "name: sm-y").replace("Agent x, read-only.", 'Agent y\'s "own" check.')
		write(self.tmp / ".claude/agents/sm-y.md", both)
		code, lines = self.run_sync()
		self.assertEqual(code, 0, lines)
		x = self.codex("sm-x").read_text(encoding="utf-8")
		self.assertIn("description = 'Agent x for \"this\", read-only.'\nmodel_reasoning_effort = \"low\"\n", x)
		self.assertIn('description = """Agent y\'s "own" check."""\n', self.codex("sm-y").read_text(encoding="utf-8"))

	def test_check_reports_stale_and_extra_codex_agents(self):
		self.run_sync()
		with open(self.tmp / ".claude/agents/sm-x.md", "a", encoding="utf-8", newline="\n") as f:
			f.write("\nThen report.\n")
		write(self.codex("sm-old"), 'name = "sm-old"\n')
		write(self.tmp / ".codex/config.toml", "model = 'x'\n")
		code, lines = self.run_sync("--check")
		self.assertEqual(code, 1, lines)
		self.assertIn("  stale .codex/agents/sm-x.toml", lines)
		self.assertIn("  extra .codex/agents/sm-old.toml", lines)
		code, lines = self.run_sync()
		self.assertEqual(code, 0, lines)
		self.assertIn("  removed .codex/agents/sm-old.toml", lines)
		self.assertTrue(self.codex("sm-x").read_text(encoding="utf-8").endswith("Then report.'''\n"))
		self.assertTrue((self.tmp / ".codex/config.toml").exists())
		self.assertEqual(self.run_sync("--check")[0], 0)

	def test_crlf_codex_agent_still_matches(self):
		self.run_sync()
		p = self.codex("sm-x")
		p.write_bytes(p.read_bytes().replace(b"\n", b"\r\n"))
		self.assertEqual(self.run_sync("--check")[0], 0)

	def test_body_with_three_quotes_is_refused(self):
		write(self.tmp / ".claude/agents/sm-x.md", AGENT + "Say '''this'''.\n")
		code, lines = self.run_sync()
		self.assertEqual(code, 1, lines)
		self.assertIn("sm-x.md: the body contains ''', which would end its Codex copy's instructions early", "\n".join(lines))
		self.assertFalse(self.codex("sm-x").exists())


if __name__ == "__main__":
	unittest.main()
