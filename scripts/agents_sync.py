#!/usr/bin/env python3
"""Validate the agent files and mirror the skills and agents for other tools.

.claude/skills/<name>/SKILL.md and .claude/agents/<name>.md are the source. This script
checks them against the Agent Skills spec and Claude Code's subagent fields (a misspelled
field is otherwise ignored silently), copies every skill file byte for byte to
.agents/skills/ and writes .agents/skills/.manifest.json with a sha256 per file, so that
other harnesses find the same skills and a copy that drifted is caught by `build check`.
It also writes each agent as .codex/agents/<name>.toml, Codex's custom agent file: the
name, the description, `effort` as model_reasoning_effort and the body as the developer
instructions, in the layout Codex's own import of .claude/agents writes. Codex has no
counterpart to `tools`, `model` or `skills`, which the body's own words carry instead.

    python scripts/agents_sync.py            # validate, then write the mirror and the manifest
    python scripts/agents_sync.py --check    # validate and report drift; writes nothing
    python scripts/test_agents_sync.py       # this script's own tests

Exit codes: 0 ok; 1 problems in the source files, or drift with --check; 2 usage. The
first line of output is the verdict. Hashes and comparisons treat CRLF as LF, because
git's autocrlf may rewrite either side on Windows; copies keep their bytes.
"""

import argparse
import difflib
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

SKILLS_DIR = Path(".claude") / "skills"
AGENTS_DIR = Path(".claude") / "agents"
MIRROR_DIR = Path(".agents") / "skills"
CODEX_DIR = Path(".codex") / "agents"
MANIFEST = ".manifest.json"
PREFIX = "sm"  # every skill and agent name starts with it; mentions of other such names are checked

# The Agent Skills spec's frontmatter; Claude Code accepts more, but a mirrored skill
# must stay portable, and the rest of the house rules live in the body.
SKILL_KEYS = {"name", "description", "license", "compatibility", "allowed-tools"}
# Claude Code's subagent frontmatter (code.claude.com/docs/en/sub-agents). Unknown keys
# are ignored silently there, so here they are errors.
AGENT_KEYS = {
	"name", "description", "tools", "disallowedTools", "model", "permissionMode", "skills", "hooks", "memory",
	"effort", "maxTurns", "mcpServers", "isolation", "background", "omitClaudeMd", "color",
}
MODELS = {"opus", "sonnet", "haiku", "inherit"}
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
TOOLS = {
	"Read", "Grep", "Glob", "Bash", "PowerShell", "Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch",
	"WebSearch", "Skill", "Agent", "TodoWrite",
}
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
MENTION_RE = re.compile(r"\b" + PREFIX + r"-[a-z0-9-]+\b")
TAG_RE = re.compile(r"<[^>\n]+>")
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
SKILL_DIR_RE = re.compile(r"\$\{CLAUDE_SKILL_DIR\}/([^\s`'\")]+)")
BUNDLED_RE = re.compile(r"`((?:references|scripts|assets)/[^`\s]+)`")
SKIP = {"__pycache__", ".DS_Store", "Thumbs.db"}
NAME_MAX, DESC_MAX, BODY_WARN, BODY_MAX = 64, 1024, 300, 500
DENY_RULE = "Edit(.agents/**)"


class FormatError(Exception):
	pass


def read_text(path):
	return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def strip_quotes(value):
	if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
		return value[1:-1]
	return value


def parse_frontmatter(text):
	"""The subset of YAML both file kinds use: `key: value` lines and `key:` with `  - item` lines."""
	lines = text.split("\n")
	if not lines or lines[0].strip() != "---":
		raise FormatError("no frontmatter: the file must start with ---")
	meta, key, i = {}, None, 1
	while i < len(lines) and lines[i].strip() != "---":
		line = lines[i]
		m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
		if m:
			key, value = m.group(1), m.group(2).strip()
			if value.startswith((">", "|")):
				raise FormatError(f"line {i + 1}: block scalars are not supported; put {key} on one line")
			if value.startswith("[") and value.endswith("]"):
				meta[key] = [strip_quotes(v.strip()) for v in value[1:-1].split(",") if v.strip()]
			else:
				meta[key] = strip_quotes(value) if value else []
		elif re.match(r"^\s+-\s+\S", line) and key is not None and isinstance(meta[key], list):
			meta[key].append(strip_quotes(line.strip()[1:].strip()))
		elif line.strip():
			raise FormatError(f"line {i + 1}: unsupported YAML; use `key: value` lines and `  - item` lists")
		i += 1
	if i >= len(lines):
		raise FormatError("frontmatter is not closed by ---")
	return meta, "\n".join(lines[i + 1 :])


def body_lines(body):
	stripped = body.strip("\n")
	return len(stripped.split("\n")) if stripped else 0


def check_description(meta, where, problems):
	d = meta.get("description")
	if not isinstance(d, str) or not d.strip():
		problems.append(f"{where}: description is empty")
		return
	if len(d) > DESC_MAX:
		problems.append(f"{where}: description is {len(d)} chars (max {DESC_MAX})")
	if TAG_RE.search(d):
		problems.append(f"{where}: description contains an XML tag")


def check_mentions(text, where, known, problems):
	for token in sorted(set(MENTION_RE.findall(text))):
		if token not in known:
			problems.append(f"{where}: mentions '{token}', which is not a skill or agent")


def validate_skill(root, skill_dir, known, problems, warnings):
	name = skill_dir.name
	rel = skill_dir.relative_to(root).as_posix()
	if not NAME_RE.match(name) or len(name) > NAME_MAX:
		problems.append(f"{rel}: directory name '{name}' is not a valid skill name (lowercase, digits, single hyphens, at most {NAME_MAX})")
	f = skill_dir / "SKILL.md"
	where = f"{rel}/SKILL.md"
	if not f.is_file():
		problems.append(f"{rel}: no SKILL.md")
		return
	text = read_text(f)
	try:
		meta, body = parse_frontmatter(text)
	except FormatError as e:
		problems.append(f"{where}: frontmatter: {e}")
		return
	for key in sorted(set(meta) - SKILL_KEYS):
		problems.append(f"{where}: unknown frontmatter key '{key}' (skills use only name and description)")
	if meta.get("name") != name:
		problems.append(f"{where}: name '{meta.get('name')}' does not match its directory '{name}'")
	check_description(meta, where, problems)
	n = body_lines(body)
	if n == 0:
		problems.append(f"{where}: empty body")
	elif n > BODY_MAX:
		problems.append(f"{where}: body is {n} lines (limit {BODY_MAX}; move detail to references/)")
	elif n > BODY_WARN:
		warnings.append(f"{where}: body is {n} lines (keep under {BODY_WARN}; {BODY_MAX} is the limit)")
	targets = [t for t in LINK_RE.findall(text) if "://" not in t and not t.startswith(("#", "mailto:"))]
	targets += SKILL_DIR_RE.findall(text) + BUNDLED_RE.findall(text)
	for target in sorted(set(t.split("#")[0] for t in targets if t.split("#")[0])):
		if target.count("/") > 1:
			problems.append(f"{where}: '{target}' is nested two deep (keep references one level deep)")
		elif not (skill_dir / target).exists() and not (target.startswith("scripts/") and (root / target).exists()):
			problems.append(f"{where}: link '{target}' does not exist")
	# The name line is checked above; a misspelt name would otherwise be reported twice.
	check_mentions(str(meta.get("description", "")) + "\n" + body, where, known, problems)


def validate_agent(root, f, skill_names, known, problems, warnings):
	where = f.relative_to(root).as_posix()
	text = read_text(f)
	try:
		meta, body = parse_frontmatter(text)
	except FormatError as e:
		problems.append(f"{where}: frontmatter: {e}")
		return
	for key in sorted(set(meta) - AGENT_KEYS):
		hint = difflib.get_close_matches(key, AGENT_KEYS, n=1)
		problems.append(f"{where}: unknown frontmatter key '{key}'" + (f" (did you mean '{hint[0]}'?)" if hint else ""))
	if meta.get("name") != f.stem or not NAME_RE.match(f.stem):
		problems.append(f"{where}: name '{meta.get('name')}' does not match file '{f.name}'")
	check_description(meta, where, problems)
	if body_lines(body) == 0:
		problems.append(f"{where}: empty body")
	if "'''" in body:
		problems.append(f"{where}: the body contains ''', which would end its Codex copy's instructions early")
	skills = meta.get("skills", [])
	if isinstance(skills, str):
		skills = [s.strip() for s in skills.split(",") if s.strip()]
	for s in skills:
		if s not in skill_names:
			problems.append(f"{where}: skills: '{s}' is not a directory in .claude/skills")
	model = meta.get("model")
	if isinstance(model, str) and model not in MODELS and not model.startswith("claude-"):
		warnings.append(f"{where}: model '{model}' is not one of {sorted(MODELS)} or a claude-* id")
	effort = meta.get("effort")
	if isinstance(effort, str) and effort not in EFFORTS:
		warnings.append(f"{where}: effort '{effort}' is not one of {sorted(EFFORTS)}")
	tools = meta.get("tools", [])
	if isinstance(tools, str):
		tools = [t.strip() for t in tools.split(",") if t.strip()]
	for t in tools:
		if t.split("(")[0] not in TOOLS:
			warnings.append(f"{where}: tools: unknown '{t}'")
	check_mentions(str(meta.get("description", "")) + "\n" + body, where, known, problems)


def check_settings(root, problems):
	f = root / ".claude" / "settings.json"
	where = ".claude/settings.json"
	if not f.is_file():
		problems.append(f"{where}: missing; its permissions.deny must contain {DENY_RULE} so the mirror is never edited by hand")
		return
	try:
		data = json.loads(read_text(f))
	except ValueError as e:
		problems.append(f"{where}: not valid JSON ({e})")
		return
	if DENY_RULE not in data.get("permissions", {}).get("deny", []):
		problems.append(f"{where}: permissions.deny lacks {DENY_RULE}")


def validate(root):
	problems, warnings = [], []
	skills_dir, agents_dir = root / SKILLS_DIR, root / AGENTS_DIR
	skill_dirs = sorted(p for p in skills_dir.iterdir() if p.is_dir() and p.name not in SKIP) if skills_dir.is_dir() else []
	agent_files = sorted(agents_dir.glob("*.md")) if agents_dir.is_dir() else []
	skill_names = {p.name for p in skill_dirs}
	known = skill_names | {f.stem for f in agent_files}
	for d in skill_dirs:
		validate_skill(root, d, known, problems, warnings)
	for f in agent_files:
		validate_agent(root, f, skill_names, known, problems, warnings)
	check_settings(root, problems)
	if not skill_dirs:
		warnings.append(f"no skills in {SKILLS_DIR.as_posix()}")
	return problems, warnings, len(skill_dirs), len(agent_files)


def normalized(data):
	return data.replace(b"\r\n", b"\n")


def desired_files(root):
	"""Mirror path (posix, relative to .agents/skills) -> source file."""
	src = root / SKILLS_DIR
	if not src.is_dir():
		return {}
	files = {}
	for p in sorted(src.rglob("*")):
		if p.is_file() and not set(p.relative_to(src).parts) & SKIP:
			files[p.relative_to(src).as_posix()] = p
	return files


def mirror(root, check):
	"""Returns (drift, written): drift as (kind, path) with kind 'stale' or 'extra'."""
	dst = root / MIRROR_DIR
	desired = desired_files(root)
	manifest = {
		"source": SKILLS_DIR.as_posix(),
		"files": {rel: hashlib.sha256(normalized(p.read_bytes())).hexdigest() for rel, p in desired.items()},
	}
	prefix = MIRROR_DIR.as_posix() + "/"
	drift = []
	for rel, p in desired.items():
		target = dst / rel
		if not target.is_file() or normalized(target.read_bytes()) != normalized(p.read_bytes()):
			drift.append(("stale", prefix + rel))
	mf = dst / MANIFEST
	current = None
	if mf.is_file():
		try:
			current = json.loads(read_text(mf))
		except ValueError:
			current = None
	if current != manifest:
		drift.append(("stale", prefix + MANIFEST))
	existing = {p.relative_to(dst).as_posix() for p in dst.rglob("*") if p.is_file()} if dst.is_dir() else set()
	for rel in sorted(existing - set(desired) - {MANIFEST}):
		drift.append(("extra", prefix + rel))
	if check or not drift:
		return drift, []
	written = []
	for kind, path in drift:
		rel = path[len(prefix) :]
		target = dst / rel
		if kind == "extra":
			target.unlink()
			written.append(f"removed {path}")
			continue
		target.parent.mkdir(parents=True, exist_ok=True)
		if rel == MANIFEST:
			target.write_bytes((json.dumps(manifest, indent=2) + "\n").encode("utf-8"))
		else:
			shutil.copyfile(desired[rel], target)
		written.append(f"wrote {path}")
	for d in sorted((p for p in dst.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
		if not any(d.iterdir()):
			d.rmdir()
	return drift, written


def codex_toml(meta, body):
	"""An agent as Codex's custom agent file, with the string forms Codex's own import picks:
	the description is a basic string, a literal one when it holds a double quote, and a
	multi-line basic one when it holds an apostrophe too, where quotes need no escape but a
	backslash and three quotes in a row do. The body is a multi-line literal string, so its
	backslashes and quotes stay as written (validate_agent refuses a body with ''')."""
	description = meta["description"]
	if '"' not in description and "\\" not in description:
		description = '"' + description + '"'
	elif "'" not in description:
		description = "'" + description + "'"
	else:
		description = '"""' + description.replace("\\", "\\\\").replace('"""', '""\\"') + '"""'
	lines = [f'name = "{meta["name"]}"', f"description = {description}"]
	if isinstance(meta.get("effort"), str):
		lines.append(f'model_reasoning_effort = "{meta["effort"]}"')
	lines.append("developer_instructions = '''\n" + body.strip("\n") + "'''")
	return "\n".join(lines) + "\n"


def mirror_codex(root, check):
	"""The agents' Codex copies; returns (drift, written) as mirror does. Only *.toml under
	.codex/agents is touched: the rest of .codex is Codex's own settings."""
	dst = root / CODEX_DIR
	agents_dir = root / AGENTS_DIR
	desired = {}
	for f in sorted(agents_dir.glob("*.md")) if agents_dir.is_dir() else []:
		meta, body = parse_frontmatter(read_text(f))
		desired[f.stem + ".toml"] = codex_toml(meta, body).encode("utf-8")
	prefix = CODEX_DIR.as_posix() + "/"
	drift = []
	for rel, data in desired.items():
		target = dst / rel
		if not target.is_file() or normalized(target.read_bytes()) != data:
			drift.append(("stale", prefix + rel))
	existing = {p.name for p in dst.glob("*.toml")} if dst.is_dir() else set()
	for rel in sorted(existing - set(desired)):
		drift.append(("extra", prefix + rel))
	if check or not drift:
		return drift, []
	written = []
	for kind, path in drift:
		target = dst / path[len(prefix) :]
		if kind == "extra":
			target.unlink()
			written.append(f"removed {path}")
			continue
		target.parent.mkdir(parents=True, exist_ok=True)
		target.write_bytes(desired[path[len(prefix) :]])
		written.append(f"wrote {path}")
	return drift, written


def main(argv=None):
	p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
	p.add_argument("--check", action="store_true", help="report drift and problems without writing anything")
	p.add_argument("--root", default=str(Path(__file__).resolve().parent.parent), help="the repository root")
	args = p.parse_args(argv)
	root = Path(args.root).resolve()

	problems, warnings, skills, agents = validate(root)
	if problems:
		print(f"FAIL agents: {len(problems)} problem(s)")
		for line in problems:
			print(f"  {line}")
		for line in warnings:
			print(f"  warning: {line}")
		return 1
	drift, written = mirror(root, args.check)
	codex_drift, codex_written = mirror_codex(root, args.check)
	drift, written = drift + codex_drift, written + codex_written
	if args.check and drift:
		print(f"FAIL agents: {len(drift)} file(s) out of date")
		for kind, path in drift:
			print(f"  {kind} {path}")
		print("run: python scripts/agents_sync.py")
		return 1
	state = f"{len(written)} file(s) updated" if written else "mirror current"
	print(f"ok agents: {skills} skill(s), {agents} agent(s); {state}")
	for line in written:
		print(f"  {line}")
	for line in warnings:
		print(f"  warning: {line}")
	return 0


if __name__ == "__main__":
	sys.exit(main())
