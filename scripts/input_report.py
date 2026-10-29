#!/usr/bin/env python3
"""Analyse a report from the app's developer-only Input Diagnostics mode (report schema 1).

The mode runs guided input tests on a device, an iPad with an Apple Pencil above all, and exports a ZIP
holding diagnostic-events.jsonl, diagnostic-summary.json and diagnostic-report.md. This script checks the
report against its schema, ties every line to the test run it belongs to, recounts from the raw lines what
each run received and what the probe controls answered, and sorts what it finds into three separate lists:

    confirmed failures           an automatic "fail" that the run's own lines bear out, or a person's "fail"
    suspicious patterns          heuristics: missing or inconsistent events, timing, baseline comparisons
    needs manual interpretation  what the data cannot decide: inconclusive or unavailable verdicts,
                                 manual-only tests left unjudged, automatic and manual verdicts that disagree

It never names a root cause: a log shows what happened together, and the iPad has to confirm it.

Usage:
    python scripts/input_report.py REPORT [--out DIR] [--strict]
    python scripts/input_report.py --url https://host/report.zip [--out DIR] [--strict]
    python scripts/test_input_report.py      # this script's tests, over scripts/input_report_samples/

REPORT is the exported .zip, a folder holding its files, or a diagnostic-events.jsonl (the summary is then
read from beside it when present). --url downloads the report first: https only, at most 50 MB, into a new
temp folder; the bytes are untrusted, so archive entries are read by their base name only and an archive
naming an absolute path or a '..' is refused. The analysis goes to DIR/input-analysis.md and
DIR/input-analysis.json (default build/input-report).

Exit codes: 0 analysed (whether or not failures were found), 1 usage error or the download failed,
2 the report is invalid (schema errors; the outputs are still written and say why), 3 with --strict when
the report holds a confirmed failure.
"""

import argparse
import bisect
import json
import math
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "build" / "input-report"
SCHEMA = 1
EVENTS, SUMMARY, REPORT_MD = "diagnostic-events.jsonl", "diagnostic-summary.json", "diagnostic-report.md"
REPORT_FILES = (EVENTS, SUMMARY, REPORT_MD)
MAX_DOWNLOAD = 50 * 1024 * 1024
# The app caps its own log far below this; the cap only stops a hostile archive from inflating an entry
# into all of memory.
MAX_FILE = 64 * 1024 * 1024
MAX_ENTRIES = 64
MAX_LISTED_LINES = 20

# t has millisecond precision, so rounding alone can step it back by up to a millisecond.
T_NOISE = 0.0015
# Gaps longer than this between the events of one moving contact mean the device sent nothing for a while.
GAP_S = 0.25
# A contact that moved no more than this across a gap was resting, and a resting contact sends no moves.
STILL_PT = 5.0
# A contact shorter than this is quicker than a person taps: a bounce, a phantom touch or a cancel.
SHORT_CONTACT_S = 0.010
# Palm rejection usually keeps a window after the Pencil; a palm inside it may be meant, one after it not.
PALM_WINDOW_S = 0.6
ACTIVE_AFTER_UP_S = 0.3
# A state line this soon after a down (and before its up) is the frame that answered that down.
STATE_REACTION_S = 0.1
# The down that ends a run (the tap on Next) is still held, or lifted this recently, at the closing step line.
CLOSING_TAP_S = 0.3
# A contact still down at its run's end gets this long to come up before it counts as down without up.
DANGLING_GRACE_S = 1.0
# A click, pick or value change this soon after a contact came up still belongs to that contact.
RELEASE_SLACK_S = 0.15
RATIO_TOLERANCE = 0.15
METRIC_TOLERANCE = 0.05
EDGE_PT = 40.0
MAX_STEP_SMALL = 0.1
ROLL_JUMP_DEG = 90.0
ROLL_DRIFT_DEG = 10.0

NO_ROOT_CAUSE_NOTE = (
    "A log shows what happened together, not why: a correlation in this report is not a cause. "
    "Every finding has to be confirmed on the iPad before code is changed for it."
)

# id, category, device, needs: the test table of the report schema.
TESTS = (
    ("finger_tap", "finger", "finger", ("ipad",)),
    ("finger_drag", "finger", "finger", ("ipad",)),
    ("finger_cancel", "finger", "finger", ("ipad",)),
    ("finger_after_pencil", "finger", "finger+pencil", ("ipad", "pencil")),
    ("finger_pencil_switch", "finger", "finger+pencil", ("ipad", "pencil")),
    ("pencil_tap", "pencil", "pencil", ("ipad", "pencil")),
    ("pencil_drag", "pencil", "pencil", ("ipad", "pencil")),
    ("pencil_hover", "pencil", "pencil", ("ipad", "pencil")),
    ("pencil_hover_contact_lift", "pencil", "pencil", ("ipad", "pencil")),
    ("pressure_ramp", "pressure", "pencil", ("ipad", "pencil")),
    ("hover_slider", "hover", "pencil", ("ipad", "pencil")),
    ("hover_button", "hover", "pencil", ("ipad", "pencil")),
    ("hover_menu", "hover", "pencil", ("ipad", "pencil")),
    ("slider_ratio_finger", "hover", "finger", ("ipad",)),
    ("slider_ratio_pencil", "hover", "pencil", ("ipad", "pencil")),
    ("text_focus_finger", "text", "finger", ("ipad",)),
    ("text_focus_pencil", "text", "pencil", ("ipad", "pencil")),
    ("text_typing", "text", "keyboard", ("ipad",)),
    ("text_dismiss_reopen", "text", "keyboard", ("ipad",)),
    ("text_scribble", "text", "pencil", ("ipad", "pencil")),
    ("home_swipe_baseline", "system", "finger", ("ipad",)),
    ("home_swipe_after_pencil", "system", "finger+pencil", ("ipad", "pencil")),
    ("roll_right", "roll", "pencil", ("ipad", "pencil_pro")),
    ("roll_left", "roll", "pencil", ("ipad", "pencil_pro")),
    ("roll_neutral", "roll", "pencil", ("ipad", "pencil_pro")),
    ("roll_wrap", "roll", "pencil", ("ipad", "pencil_pro")),
)
TEST_ORDER = {t[0]: i for i, t in enumerate(TESTS)}
TEST_INFO = {t[0]: {"category": t[1], "device": t[2], "needs": list(t[3])} for t in TESTS}
PAIRS = (
    ("finger_tap", "finger_after_pencil"),
    ("home_swipe_baseline", "home_swipe_after_pencil"),
    ("slider_ratio_finger", "slider_ratio_pencil"),
    ("text_focus_finger", "text_focus_pencil"),
)
MANUAL_ONLY = ("home_swipe_baseline", "home_swipe_after_pencil")
# The probe press each test's contacts are meant to produce; downs elsewhere (the home swipe's edge) are not.
PRESS_SRC = {
    "finger_tap": ("finger",),
    "finger_drag": ("finger",),
    "finger_cancel": ("finger",),
    "finger_after_pencil": ("finger",),
    "finger_pencil_switch": ("finger", "pen"),
    "pencil_tap": ("pen",),
    "pencil_drag": ("pen",),
    "pencil_hover_contact_lift": ("pen",),
    "pressure_ramp": ("pen",),
    "slider_ratio_finger": ("finger",),
    "slider_ratio_pencil": ("pen",),
    "text_focus_finger": ("finger",),
    "text_focus_pencil": ("pen",),
}
# text_typing tells the person to type "sculpt" and press Backspace twice (DIAG_TYPE_TEXT and DIAG_TYPE_LEFT in
# src/app/diag_tests.odin), so the field should end holding "scul".
TYPING_INPUT, TYPING_RESULT = "sculpt", "scul"
# The schema does not fix which way is "right"; this reads roll_right as the probe slider's value going up.
ROLL_SIGN = {"roll_right": 1, "roll_left": -1}
SRC_NAME = {"finger": "finger", "pen": "Pencil", "mouse": "mouse"}

SRC_TYPES = {
    "finger": {"down", "move", "up", "cancel"},
    "pen": {"down", "move", "up", "near", "far", "axis", "button_down", "button_up", "gesture"},
    "mouse": {"down", "move", "up", "wheel"},
    "key": {"key_down"},
    "text": {"text", "editing"},
    "window": {"focus_lost", "focus_gained", "keyboard_shown", "keyboard_hidden"},
    "app": {"will_background", "background", "foreground"},
}
POINTER = ("finger", "pen", "mouse")
CONTACT_TYPES = ("down", "move", "up", "cancel")
AXES = {"pressure", "xtilt", "ytilt", "distance", "rotation", "slider", "tangential"}
GESTURES = {"double_tap", "squeeze_began", "squeeze_ended", "squeeze_cancelled"}
KINDS = {"session", "event", "state", "control", "step", "anomaly", "result", "truncated"}
STEP_ACTIONS = {"start", "repeat", "skip", "next", "end"}
AUTO = {"pass", "fail", "inconclusive", "unavailable", "none"}
MANUAL = {"pass", "fail", "inconclusive", "skip", None}
ANOMALY_CODES = {
    "received_not_responded", "finger_palm", "pen_near_stuck", "hover_changed_value", "roll_jump",
    "roll_wrong_direction", "stuck_pressed", "down_without_up", "up_without_down", "os_cancel",
    "text_without_focus", "keyboard_desync", "background_during_step", "pressure_unavailable", "frame_gap",
    "log_truncated",
}
RECEIVED_KEYS = (
    "finger_down", "finger_up", "finger_cancel", "pen_near", "pen_far", "pen_down", "pen_up", "pen_move",
    "pen_axis", "mouse_down", "mouse_up", "key_down", "text",
)
RESPONDED_KEYS = ("press", "release", "click", "cancel", "value", "focus", "blur", "text", "pick")
# Moves and axes are folded into lines ("n"), so their totals are sums the app may round differently.
FOLDED_KEYS = ("pen_move", "pen_axis")

NUM, INT, STR, BOOL = "a number", "an integer", "a string", "true or false"
LIST, OBJ = "a list", "an object"
NUM_NULL, STR_NULL, BOOL_NULL = "a number or null", "a string or null", "true, false or null"


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


TYPE_OK = {
    NUM: is_num,
    INT: is_int,
    STR: lambda v: isinstance(v, str),
    BOOL: lambda v: isinstance(v, bool),
    LIST: lambda v: isinstance(v, list),
    OBJ: lambda v: isinstance(v, dict),
    NUM_NULL: lambda v: v is None or is_num(v),
    STR_NULL: lambda v: v is None or isinstance(v, str),
    BOOL_NULL: lambda v: v is None or isinstance(v, bool),
}
SESSION_FIELDS = {
    "session": STR, "app": STR, "version": STR, "build": STR, "platform": STR, "os": STR, "device": STR,
    "started": STR, "window": LIST, "scale": NUM, "hints": OBJ, "diagnostics": BOOL,
}
COMMON_FIELDS = {"t": NUM, "seq": INT, "kind": STR, "step": STR_NULL, "run": INT}
KIND_FIELDS = {
    "event": {"src": STR, "type": STR, "id": INT},
    "state": {
        "changed": LIST, "pointer": STR, "down": BOOL, "cancel": BOOL, "owner": STR, "fingers": INT,
        "palm": BOOL, "pen_near": BOOL, "pen_down": BOOL, "pointing": BOOL, "gesture": BOOL, "active": BOOL,
        "hot": STR, "text_focus": BOOL, "text_input": BOOL, "keyboard": BOOL_NULL, "pen_distance": NUM,
        "roll": NUM_NULL,
    },
    "control": {"control": STR, "action": STR, "by": STR, "contact": BOOL},
    "step": {"action": STR, "test": STR, "category": STR, "device": STR},
    "anomaly": {"code": STR, "severity": STR, "detail": STR, "count": INT},
    "result": {"test": STR, "auto": STR, "auto_reason": STR, "manual": STR_NULL, "notes": STR, "metrics": OBJ},
    "truncated": {},
}
ENUMS = {
    "state": {"pointer": {"mouse", "finger", "pen"}, "owner": {"none", "interface", "viewport"}},
    "control": {
        "control": {"pad", "slider", "vslider", "button", "menu", "field"},
        "action": {"hover_in", "hover_out", "press", "drag", "release", "click", "cancel", "value", "focus",
                   "blur", "text", "pick", "open"},
        "by": {"mouse", "finger", "pen"},
    },
    "anomaly": {"severity": {"fail", "suspicious", "info"}, "code": ANOMALY_CODES},
}
SUMMARY_FIELDS = {
    "session": OBJ, "ended": STR, "duration_s": NUM, "lines": INT, "dropped": INT, "bytes": INT,
    "truncated": BOOL, "counts": OBJ, "tests": LIST, "anomalies": LIST,
}


class UsageError(Exception):
    """The command line or the network failed before there was a report to read (exit 1)."""


class ReportError(Exception):
    """The report cannot be read at all: a refused or broken archive, or a missing events file (exit 2)."""


class Problems:
    """Errors or warnings folded by message, so a fault repeated on every line is one entry with its count."""

    def __init__(self):
        self.items = {}

    def add(self, line, message):
        item = self.items.setdefault(message, {"message": message, "count": 0, "lines": []})
        item["count"] += 1
        if line is not None and len(item["lines"]) < MAX_LISTED_LINES:
            item["lines"].append(line)

    def __len__(self):
        return len(self.items)

    def as_list(self):
        return list(self.items.values())


# --- reading the report ------------------------------------------------------------------------------


def unsafe_entry(name):
    """An archive entry that names an absolute path or climbs out with '..' is never read."""
    n = name.replace("\\", "/")
    return n.startswith("/") or re.match(r"[A-Za-z]:", n) is not None or ".." in n.split("/")


def read_zip(path):
    """Returns the report's files from a ZIP by base name, and notes about entries that were ignored."""
    try:
        archive = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as e:
        raise ReportError(f"{path}: not a readable ZIP ({e})") from None
    notes, chosen, files = [], {}, {}
    with archive:
        infos = archive.infolist()
        if len(infos) > MAX_ENTRIES:
            raise ReportError(f"refused the archive: {len(infos)} entries (a report has three)")
        for info in infos:
            if unsafe_entry(info.filename):
                raise ReportError(f"refused the archive: entry {info.filename!r} is an absolute path or uses '..'")
            if info.is_dir():
                continue
            base = info.filename.replace("\\", "/").rsplit("/", 1)[-1]
            if base not in REPORT_FILES:
                notes.append(f"ignored archive entry {info.filename!r}: not a report file")
                continue
            if base in chosen:
                raise ReportError(f"refused the archive: two entries are named {base}")
            if info.flag_bits & 0x1:
                raise ReportError(f"refused the archive: {info.filename!r} is encrypted")
            if info.file_size > MAX_FILE:
                raise ReportError(f"refused the archive: {info.filename!r} declares {info.file_size} bytes")
            chosen[base] = info
        for base, info in chosen.items():
            try:
                with archive.open(info) as f:
                    data = f.read(MAX_FILE + 1)
            except (zipfile.BadZipFile, zlib.error, NotImplementedError, RuntimeError, EOFError, OSError) as e:
                raise ReportError(f"{info.filename}: cannot be read from the archive ({e})") from None
            if len(data) > MAX_FILE:
                raise ReportError(f"refused the archive: {info.filename!r} inflates past {MAX_FILE} bytes")
            files[base] = data
    return files, notes


def read_capped(path):
    if path.stat().st_size > MAX_FILE:
        raise ReportError(f"{path}: larger than {MAX_FILE} bytes")
    return path.read_bytes()


def load_report(path):
    """Returns (files by name, source, notes) for a ZIP, a folder or an events file."""
    p = Path(path)
    if not p.exists():
        raise UsageError(f"{path}: no such file or folder")
    if p.is_dir():
        return {n: read_capped(p / n) for n in REPORT_FILES if (p / n).is_file()}, str(p), []
    if zipfile.is_zipfile(p):
        files, notes = read_zip(p)
        return files, str(p), notes
    if p.suffix.lower() == ".zip":
        raise ReportError(f"{path}: not a readable ZIP")
    if p.suffix.lower() == ".jsonl":
        files = {EVENTS: read_capped(p)}
        for name in (SUMMARY, REPORT_MD):
            if (p.parent / name).is_file():
                files[name] = read_capped(p.parent / name)
        return files, str(p), []
    raise UsageError(f"{path}: REPORT must be a .zip, a folder or a diagnostic-events.jsonl")


class HttpsOnlyRedirects(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to another https URL, so a download never falls back to plain http."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise UsageError(f"refused a redirect away from https to {public_url(newurl)}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def public_url(url):
    """The URL without its query and fragment, which may hold a signed token that must not reach the outputs."""
    parts = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


def download(url):
    """Saves the report at url into a new temp folder and returns the saved file's path."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or not parts.netloc:
        raise UsageError("--url takes an https:// URL")
    opener = urllib.request.build_opener(HttpsOnlyRedirects)
    request = urllib.request.Request(url, headers={"User-Agent": "sculpt-input-report"})
    try:
        with opener.open(request, timeout=60) as response:
            length = response.headers.get("Content-Length", "")
            if length.isdigit() and int(length) > MAX_DOWNLOAD:
                raise ReportError(f"refused the download: {length} bytes is over the 50 MB cap")
            chunks, size = [], 0
            while size <= MAX_DOWNLOAD:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise UsageError(f"could not download {public_url(url)}: {e}") from None
    if size > MAX_DOWNLOAD:
        raise ReportError("refused the download: it is over the 50 MB cap")
    data = b"".join(chunks)
    folder = Path(tempfile.mkdtemp(prefix="input-report-"))
    target = folder / ("report.zip" if data[:4] == b"PK\x03\x04" else EVENTS)
    target.write_bytes(data)
    return target


# --- checking lines against the schema ---------------------------------------------------------------


def parse_jsonl(data, errors, warnings):
    """Returns the lines as dicts, each with its 1-based line number under "_ln", and the line count."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        errors.add(None, f"{EVENTS} is not UTF-8 ({e.reason} at byte {e.start})")
        text = data.decode("utf-8", errors="replace")
    if text.startswith("\ufeff"):
        warnings.add(1, f"{EVENTS} starts with a byte order mark")
        text = text[1:]
    lines = text.split("\n")
    complete = text.endswith("\n")
    if complete:
        lines.pop()
    records = []
    for i, line in enumerate(lines, 1):
        if line.endswith("\r"):
            warnings.add(i, 'lines end with "\\r\\n" (the schema says "\\n")')
            line = line[:-1]
        if not line.strip():
            warnings.add(i, "empty line")
            continue
        try:
            rec = json.loads(line)
        except (ValueError, RecursionError):
            if i == len(lines) and not complete:
                warnings.add(i, "the last line is cut off: the app stopped while writing it")
            else:
                errors.add(i, "line is not JSON")
            continue
        if not isinstance(rec, dict):
            errors.add(i, "line is not a JSON object")
            continue
        rec["_ln"] = i
        records.append(rec)
    return records, len(lines)


def check_fields(rec, fields, what, problems):
    """Adds a problem for each missing or mistyped field; True when every field is present and typed."""
    ok = True
    for name, kind in fields.items():
        if name not in rec:
            problems.add(rec.get("_ln"), f"{what} without {name!r}")
            ok = False
        elif not TYPE_OK[kind](rec[name]):
            problems.add(rec.get("_ln"), f"{what} whose {name!r} is not {kind}")
            ok = False
    return ok


def check_enums(rec, kind, warnings):
    """Unknown values are warnings, so a report from a newer app still analyses; False skips the line."""
    ok = True
    for field, known in ENUMS.get(kind, {}).items():
        value = rec.get(field)
        if isinstance(value, str) and value not in known:
            warnings.add(rec["_ln"], f"{kind} line with an unknown {field} {value!r} (skipped; a newer app?)")
            ok = False
    return ok


def check_event(rec, errors, warnings):
    src, typ, ln = rec["src"], rec["type"], rec["_ln"]
    if src not in SRC_TYPES:
        warnings.add(ln, f"event with an unknown src {src!r} (skipped; a newer app?)")
        return False
    if typ not in SRC_TYPES[src]:
        warnings.add(ln, f"{src} event with an unknown type {typ!r} (skipped; a newer app?)")
        return False
    need = {}
    if src in POINTER and typ in CONTACT_TYPES:
        need.update(x=NUM, y=NUM)
    if typ in ("move", "axis"):
        need["n"] = INT
    if typ == "axis":
        need.update(axis=STR, value=NUM)
    if typ == "key_down":
        need["key"] = STR
    if src == "text":
        need["len"] = INT
    if typ == "gesture":
        need["gesture"] = STR
    what = f"{src} {typ} event"
    ok = check_fields(rec, need, what, errors)
    optional = {"pressure": NUM, "wrap": BOOL, "text": STR, "dx": NUM, "dy": NUM}
    ok = check_fields(rec, {k: v for k, v in optional.items() if k in rec}, what, errors) and ok
    if typ == "move" and src in POINTER and ("dx" not in rec or "dy" not in rec):
        warnings.add(ln, f"{what} without 'dx' and 'dy'")
    if ok and "n" in need and rec["n"] < 1:
        errors.add(ln, f"{what} whose 'n' is below 1")
        ok = False
    if ok and src == "text" and rec["len"] < 0:
        errors.add(ln, f"{what} whose 'len' is negative")
        ok = False
    if ok and typ == "axis" and rec["axis"] not in AXES:
        warnings.add(ln, f"pen axis line with an unknown axis {rec['axis']!r} (a newer app?)")
    if ok and typ == "gesture" and rec["gesture"] not in GESTURES:
        warnings.add(ln, f"pen gesture line with an unknown gesture {rec['gesture']!r} (a newer app?)")
    if ok and "pressure" in rec and not 0.0 <= rec["pressure"] <= 1.0:
        warnings.add(ln, f"{what} whose pressure is outside 0..1")
    return ok


def check_line(rec, errors, warnings):
    """Checks one line after the session line, whose common fields are already checked; True when the
    analysis can use it."""
    kind, ln = rec["kind"], rec["_ln"]
    if kind == "session":
        errors.add(ln, "a second session line")
        return False
    if kind not in KINDS:
        warnings.add(ln, f"line of an unknown kind {kind!r} (skipped; a newer app?)")
        return False
    ok = True
    if rec["t"] < 0:
        errors.add(ln, "line whose 't' is negative")
        ok = False
    if (rec["step"] is None) != (rec["run"] == 0):
        errors.add(ln, "line whose 'step' and 'run' disagree (step null goes with run 0, a test id with run >= 1)")
        ok = False
    if rec["run"] < 0:
        errors.add(ln, "line whose 'run' is negative")
        ok = False
    if not check_fields(rec, KIND_FIELDS[kind], f"{kind} line", errors):
        return False
    if kind == "event":
        return check_event(rec, errors, warnings) and ok
    if kind == "control":
        extra = {k: NUM for k in ("before", "after", "travel", "roll") if k in rec}
        extra.update({k: kind for k, kind in (("text", STR), ("len", INT)) if k in rec})
        ok = check_fields(rec, extra, "control line", errors) and ok
    if kind == "state" and not all(isinstance(c, str) for c in rec["changed"]):
        errors.add(ln, "state line whose 'changed' holds something other than names")
        ok = False
    if kind == "anomaly" and rec["count"] < 1:
        errors.add(ln, "anomaly line whose 'count' is below 1")
        ok = False
    if kind == "step":
        if rec["action"] not in STEP_ACTIONS:
            warnings.add(ln, f"step line with an unknown action {rec['action']!r} (skipped; a newer app?)")
            return False
        if rec["step"] is not None and rec["step"] != rec["test"]:
            errors.add(ln, "step line whose 'step' is neither null nor its 'test'")
            ok = False
    if kind == "result":
        ok = check_result(rec, errors, warnings) and ok
    return check_enums(rec, kind, warnings) and ok


def check_result(rec, errors, warnings):
    ln, ok = rec["_ln"], True
    if rec["step"] != rec["test"]:
        errors.add(ln, "result line whose 'test' is not its 'step'")
        ok = False
    if rec["auto"] not in AUTO:
        warnings.add(ln, f"result with an unknown auto verdict {rec['auto']!r} (read as no verdict)")
    if rec["manual"] not in MANUAL:
        warnings.add(ln, f"result with an unknown manual verdict {rec['manual']!r} (read as no verdict)")
    metrics = rec["metrics"]
    for name, keys in (("received", RECEIVED_KEYS), ("responded", RESPONDED_KEYS)):
        group = metrics.get(name)
        if not isinstance(group, dict):
            errors.add(ln, f"result metrics without the {name!r} object")
            ok = False
            continue
        missing = [k for k in keys if not is_int(group.get(k))]
        if missing:
            errors.add(ln, f"result metrics whose {name!r} lacks integer {', '.join(missing)}")
            ok = False
    if not is_int(metrics.get("palms")):
        errors.add(ln, "result metrics without an integer 'palms'")
        ok = False
    return ok


def check_session(records, errors, warnings):
    """Returns the session line, or None when the report cannot be analysed at all."""
    if not records or records[0]["_ln"] != 1 or records[0].get("kind") != "session":
        errors.add(1, 'line 1 is not the session line (kind "session")')
        return None
    s = records[0]
    if not is_int(s.get("schema")) or s["schema"] != SCHEMA:
        errors.add(1, f"the session line's schema is {s.get('schema')!r}; this analyzer reads schema {SCHEMA}")
        return None
    check_fields(s, SESSION_FIELDS, "session line", errors)
    window = s.get("window")
    if isinstance(window, list) and (len(window) != 2 or not all(is_num(v) for v in window)):
        errors.add(1, "session line whose 'window' is not [width, height]")
    for field in ("seq", "t"):
        if field in s:
            warnings.add(1, f"session line carries {field!r} (the schema gives it none)")
    return s


# --- runs ----------------------------------------------------------------------------------------------


class Run:
    """One run of one test: from its start or repeat step line to the end, skip or next that closes it."""

    def __init__(self, test, number, rec):
        self.test, self.run = test, number
        self.start_ln, self.start_t = rec["_ln"], rec["t"]
        self.end_ln = self.end_t = self.end_action = None
        self.lines = []
        self.result = None
        self.truncated = False
        self.downs = []
        self.marks = {}
        self.rotation = []
        self.pressure = []
        self.pressure_on_lines = 0
        self.hover = []
        self.checks = []
        self.verdict_evidence = []
        self.stats = {}

    @property
    def label(self):
        return f"{self.test} run {self.run}"

    @property
    def category(self):
        return TEST_INFO.get(self.test, {}).get("category", "")

    def mark(self, code, ln, text):
        self.marks.setdefault(code, []).append((ln, text))

    def of(self, kind, **match):
        return [r for r in self.lines if r["kind"] == kind and all(r.get(k) == v for k, v in match.items())]

    def metrics(self):
        return self.result["metrics"] if self.result else {}


class Session:
    """Stands in for a run for lines outside any test, so session-wide marks have somewhere to go."""

    test, run, label, category, truncated = None, None, "outside any test", "", False

    def __init__(self):
        self.downs, self.marks = [], {}

    def mark(self, code, ln, text):
        self.marks.setdefault(code, []).append((ln, text))


def finding(code, where, title, evidence, lines=(), correlates=None, backs=False, covers=False, codes=(),
            default="suspicious"):
    """One finding; backs marks evidence that can confirm an automatic fail of its run, covers one that
    explains an inconclusive or unavailable verdict better than the verdict alone."""
    return {
        "kind": code, "test": where.test, "run": where.run, "title": title, "evidence": list(evidence),
        "lines": sorted(set(lines))[:40], "correlates_with": correlates, "_backs": backs, "_covers": covers,
        "_codes": set(codes), "_list": default,
    }


def fmt_s(seconds):
    return f"{seconds:.3f} s" if seconds < 10 else f"{seconds:.1f} s"


def fmt_ms(seconds):
    return f"{seconds * 1000:.0f} ms"


def fmt_num(v):
    if v is None:
        return "none"
    if isinstance(v, float):
        return f"{v:.4g}"
    return str(v)


def lines_text(items):
    lns = [ln for ln, _ in items]
    shown = ", ".join(str(n) for n in lns[:12])
    return shown + (f" and {len(lns) - 12} more" if len(lns) > 12 else "")


def left_out(down):
    """The run's last down, still held or just lifted at its closing step line and answered by no probe,
    is the tap on the mode's own Next button, not a test contact; an answered last down is a test contact."""
    return down["closing"] and not down["answered"]


def raw_key(src, typ):
    """The summary's count key for an event: "finger_down", "pen_axis", but "key_down" and "text"."""
    return typ if typ.startswith(src) else f"{src}_{typ}"


class Analyzer:
    """Validates one report and derives every finding from it; analyse() runs the whole pipeline."""

    def __init__(self, files, source, notes=()):
        self.files, self.source = files, source
        self.errors, self.warnings = Problems(), Problems()
        for note in notes:
            self.warnings.add(None, note)
        self.session = None
        self.summary = None
        self.records = []
        self.line_count = 0
        self.runs = {}
        self.test_runs = {}
        self.skipped = set()
        self.trunc = None
        self.backwards = []
        self.raw_counts = {}
        self.states = []
        self.outside = Session()
        self.findings = []
        self.comparisons = []

    # The pipeline ------------------------------------------------------------------------------------

    def analyse(self):
        if EVENTS not in self.files:
            self.errors.add(None, f"the report has no {EVENTS}")
            return self.output()
        records, self.line_count = parse_jsonl(self.files[EVENTS], self.errors, self.warnings)
        self.session = check_session(records, self.errors, self.warnings)
        if self.session is None:
            return self.output()
        self.order_and_tag(records[1:])
        self.check_summary()
        self.walk()
        # roll_neutral judges its drift against the roll_right and roll_left runs, so it is checked last.
        for run in sorted(self.all_runs(), key=lambda r: r.test == "roll_neutral"):
            self.recount(run)
            self.run_checks(run)
        self.session_checks()
        for run in self.all_runs():
            self.classify(run)
        self.compare()
        self.claim_app_anomalies()
        return self.output()

    def all_runs(self):
        return sorted(self.runs.values(), key=lambda r: r.start_ln)

    def run_of(self, rec):
        if rec.get("step") is None:
            return None
        return self.runs.get((rec["step"], rec["run"]))

    # Order, tags and runs ------------------------------------------------------------------------------

    def order_and_tag(self, records):
        """Checks every line, seq and t, opens and closes runs, and ties each line to its run."""
        prev_seq = prev_t = None
        open_run = None
        for rec in records:
            if rec.get("kind") == "event" and isinstance(rec.get("src"), str) and isinstance(rec.get("type"), str):
                key = raw_key(rec["src"], rec["type"])
                self.raw_counts[key] = self.raw_counts.get(key, 0) + (rec["n"] if is_int(rec.get("n")) else 1)
            if not check_fields(rec, COMMON_FIELDS, "line", self.errors):
                continue
            ln, t, seq = rec["_ln"], rec["t"], rec["seq"]
            if prev_seq is not None:
                if seq <= prev_seq:
                    self.errors.add(ln, "seq is not strictly increasing")
                elif seq > prev_seq + 1:
                    self.warnings.add(ln, "seq skips numbers: lines are missing from the log")
            if prev_t is not None and t < prev_t - T_NOISE:
                self.errors.add(ln, "t goes backwards")
                self.backwards.append((ln, prev_t - t))
            prev_seq, prev_t = seq, max(t, prev_t if prev_t is not None else t)
            if not check_line(rec, self.errors, self.warnings):
                continue
            if self.trunc is not None and rec["kind"] not in ("step", "result", "anomaly"):
                self.errors.add(ln, "a line other than step, result or anomaly after the truncated line")
                continue
            if rec["kind"] == "truncated":
                if self.trunc is not None:
                    self.errors.add(ln, "a second truncated line")
                self.trunc = (ln, t)
            if rec["kind"] == "step":
                open_run = self.step(rec, open_run)
                continue
            self.records.append(rec)
            self.tag(rec, open_run)
        for run in self.runs.values():
            if run.end_ln is None:
                self.warnings.add(run.start_ln, "a run never ended (no end, skip or next step line)")
            elif run.result is None and run.end_action != "skip":
                self.warnings.add(run.end_ln, "a finished run has no result line")
            if self.trunc is not None and (run.end_ln is None or run.end_ln > self.trunc[0]):
                run.truncated = True

    def step(self, rec, open_run):
        """Opens or closes a run for one step line; returns the run open after it."""
        action, test, ln, number = rec["action"], rec["test"], rec["_ln"], rec["run"]
        if test not in TEST_INFO:
            self.warnings.add(ln, f"step line for an unknown test {test!r} (a newer app?)")
        if action in ("start", "repeat"):
            if number < 1:
                self.errors.add(ln, "a start or repeat step line whose 'run' is not >= 1")
                return open_run
            if (test, number) in self.runs:
                self.errors.add(ln, "a run starts twice")
                return open_run
            if open_run is not None:
                self.warnings.add(ln, "a run starts while another is still open (the open one is closed here)")
                self.close(open_run, rec, "implicit")
            previous = self.test_runs.get(test, [])
            if number != len(previous) + 1:
                self.warnings.add(ln, "run numbers of a test do not count up from 1")
            run = Run(test, number, rec)
            self.runs[(test, number)] = run
            self.test_runs.setdefault(test, []).append(run)
            return run
        if open_run is not None and open_run.test == test and number in (0, open_run.run):
            self.close(open_run, rec, action)
            return None
        if action == "skip":
            self.skipped.add(test)
        else:
            self.warnings.add(ln, f"a step {action!r} line for a test with no open run")
        return open_run

    @staticmethod
    def close(run, rec, action):
        run.end_ln, run.end_t, run.end_action = rec["_ln"], rec["t"], action

    def tag(self, rec, open_run):
        ln = rec["_ln"]
        if rec["step"] is None:
            if open_run is not None and rec["kind"] == "event":
                self.warnings.add(ln, "an event line inside an open run carries no step")
            return
        run = self.runs.get((rec["step"], rec["run"]))
        if run is None:
            self.errors.add(ln, "a line names a test run that has not started")
            return
        late = run.end_t is not None and rec["t"] > run.end_t + STATE_REACTION_S
        if late and rec["kind"] not in ("result", "anomaly"):
            self.warnings.add(ln, "a line is tagged with a run that had already ended")
        run.lines.append(rec)
        if rec["kind"] == "result":
            if run.result is not None:
                self.errors.add(ln, "a second result for one run")
            else:
                run.result = rec

    # The summary ---------------------------------------------------------------------------------------

    def check_summary(self):
        data = self.files.get(SUMMARY)
        if data is None:
            self.warnings.add(None, f"the report has no {SUMMARY}: the analysis uses the events alone")
            return
        try:
            summary = json.loads(data.decode("utf-8"))
        except (UnicodeDecodeError, ValueError, RecursionError):
            self.errors.add(None, f"{SUMMARY} is not JSON")
            return
        if not isinstance(summary, dict):
            self.errors.add(None, f"{SUMMARY} is not a JSON object")
            return
        if not is_int(summary.get("schema")) or summary["schema"] != SCHEMA:
            self.errors.add(None, f"{SUMMARY}: schema {summary.get('schema')!r}; this analyzer reads {SCHEMA}")
            return
        summary["_ln"] = None
        if not check_fields(summary, SUMMARY_FIELDS, SUMMARY, self.errors):
            return
        self.summary = summary
        mine = {k: v for k, v in self.session.items() if k not in ("kind", "_ln")}
        for key in sorted(set(mine) | set(summary["session"])):
            if mine.get(key) != summary["session"].get(key):
                self.warnings.add(None, f"summary: session field {key!r} differs from the session line")
        if summary["truncated"] != (self.trunc is not None):
            self.warnings.add(None, "summary: 'truncated' disagrees with the log's truncated line")
        if summary["lines"] != self.line_count:
            self.warnings.add(None, f"summary: 'lines' is {summary['lines']}, the log has {self.line_count}")
        if summary["dropped"] > 0:
            self.warnings.add(None, f"summary: the app dropped {summary['dropped']} line(s)")
        self.check_counts(summary["counts"])
        self.check_summary_tests(summary["tests"])

    def check_counts(self, counts):
        mine, off = self.raw_counts, []
        for key in sorted(set(mine) | set(counts)):
            theirs, ours = counts.get(key, 0), mine.get(key, 0)
            if not is_int(theirs):
                self.errors.add(None, f"summary: counts[{key!r}] is not an integer")
                continue
            fine = ours <= theirs if self.trunc else abs(theirs - ours) <= max(2, 0.02 * theirs)
            if not fine:
                off.append(f"{key} {theirs} vs {ours} in the log")
        if off:
            self.warnings.add(None, "summary: counts disagree with the log's events: " + "; ".join(off))

    def check_summary_tests(self, tests):
        listed = set()
        for entry in tests:
            if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or not isinstance(entry.get("runs"), list):
                self.errors.add(None, "summary: a tests entry without a string 'id' and a 'runs' list")
                continue
            for item in entry["runs"]:
                if not isinstance(item, dict) or not is_int(item.get("run")):
                    self.errors.add(None, "summary: a runs entry without an integer 'run'")
                    continue
                key = (entry["id"], item["run"])
                listed.add(key)
                run = self.runs.get(key)
                if run is None:
                    self.warnings.add(None, f"summary: {entry['id']} run {item['run']} never starts in the log")
                    continue
                result = run.result or {}
                for field in ("auto", "manual"):
                    if run.result is not None and item.get(field) != result.get(field):
                        self.warnings.add(None, f"summary: {run.label} {field} verdict differs from its result line")
        for key, run in self.runs.items():
            if key not in listed:
                self.warnings.add(run.start_ln, f"summary: {run.label} is missing from the summary's tests")

    def summary_test(self, test):
        if self.summary:
            for entry in self.summary["tests"]:
                if isinstance(entry, dict) and entry.get("id") == test:
                    return entry
        return {}

    # The walk over the whole log -----------------------------------------------------------------------

    def walk(self):
        """One pass in log order: contacts, proximity, probe presses, hover changes and stuck presses."""
        self.contacts, self.pending, self.stale = {}, [], {}
        self.pen_near, self.last_up = {}, {}
        self.last_pen = None
        self.state = None
        self.all_up_since, self.stuck_flagged = None, False
        self.sends_near = any(r["kind"] == "event" and r["src"] == "pen" and r["type"] == "near" for r in self.records)
        self.pen_idle = (0.0, None)
        end_at = {run.end_ln: run for run in self.runs.values() if run.end_ln is not None}
        for rec in self.records:
            t = rec["t"]
            for end_ln in sorted(n for n in end_at if n < rec["_ln"]):
                self.run_ended(end_at.pop(end_ln))
            self.expire(t)
            self.check_stuck(t, rec["_ln"])
            if self.state is not None and self.state["pen_near"] and self.last_pen is not None:
                idle = t - self.last_pen[0]
                if idle > self.pen_idle[0]:
                    self.pen_idle = (idle, rec["_ln"])
            kind = rec["kind"]
            if kind == "state":
                self.states.append(rec)
                self.state = rec
            elif kind == "event":
                self.walk_event(rec)
            elif kind == "control":
                self.walk_control(rec)
        for run in end_at.values():
            self.run_ended(run)
        if self.trunc is None and self.records:
            for c in list(self.contacts.values()):
                self.dangling(c, "by the end of the log", self.records[-1]["t"])
        self.state_lns = [s["_ln"] for s in self.states]
        self.attach_states()

    def where(self, rec):
        return self.run_of(rec) or self.outside

    def walk_event(self, rec):
        src, typ, ln, t = rec["src"], rec["type"], rec["_ln"], rec["t"]
        if src == "pen":
            self.last_pen = (t, ln)
            if typ == "near":
                self.pen_near[rec["id"]] = True
            elif typ == "far":
                self.pen_near[rec["id"]] = False
            elif typ == "axis":
                self.walk_axis(rec)
            if typ in ("down", "move") and "pressure" in rec and self.run_of(rec):
                self.run_of(rec).pressure_on_lines += 1
        if src in POINTER and typ in CONTACT_TYPES:
            {"down": self.contact_down, "move": self.contact_move}.get(typ, self.contact_up)(rec)

    def walk_axis(self, rec):
        run = self.run_of(rec)
        if run is None:
            return
        if rec["axis"] == "rotation":
            run.rotation.append((rec["_ln"], rec["t"], rec["value"], rec.get("wrap") is True))
        elif rec["axis"] == "pressure":
            run.pressure.append((rec["_ln"], rec["value"]))

    def contact_down(self, rec):
        src, cid, ln, t = rec["src"], rec["id"], rec["_ln"], rec["t"]
        where = self.where(rec)
        key = (src, cid)
        if key in self.contacts:
            where.mark("double_down", ln, f"{SRC_NAME[src]} id {cid} down at line {ln} while already down since line {self.contacts[key]['ln']}")
        if src == "pen" and self.sends_near and not self.pen_near.get(cid, False):
            where.mark("pen_down_without_near", ln, f"Pencil id {cid} down at line {ln} with no near since its last far")
        since_pen = t - self.last_pen[0] if self.last_pen is not None and src == "finger" else None
        down = {"ln": ln, "t": t, "src": src, "id": cid, "x": rec["x"], "y": rec["y"], "up_t": None, "up_ln": None,
                "answered": False, "press_ln": None, "closing": False, "state": None, "since_pen": since_pen}
        where.downs.append(down)
        self.contacts[key] = {"src": src, "id": cid, "ln": ln, "t": t, "last_t": t, "x": rec["x"], "y": rec["y"],
                              "where": where, "down": down}
        self.all_up_since, self.stuck_flagged = None, False

    def contact_move(self, rec):
        c = self.contacts.get((rec["src"], rec["id"]))
        if c is None:
            if rec["src"] == "finger":
                self.where(rec).mark("move_not_down", rec["_ln"], f"finger id {rec['id']} moves at line {rec['_ln']} without being down")
            return
        self.contact_step(c, rec)

    def contact_step(self, c, rec):
        """A gap inside a contact counts only when the line after it folds a single raw event (a folded line
        proves events kept arriving) and the contact moved across it (a resting finger sends nothing)."""
        gap = rec["t"] - c["last_t"]
        moved = math.hypot(rec["x"] - c["x"], rec["y"] - c["y"])
        if gap > GAP_S and rec.get("n", 1) <= 1 and moved > STILL_PT:
            c["where"].mark("contact_gap", rec["_ln"], f"{SRC_NAME[c['src']]} id {c['id']}: {fmt_ms(gap)} without events before line {rec['_ln']}, while it moved {moved:.0f} pt")
        c["last_t"], c["x"], c["y"] = rec["t"], rec["x"], rec["y"]

    def contact_up(self, rec):
        src, cid, ln, t, typ = rec["src"], rec["id"], rec["_ln"], rec["t"], rec["type"]
        key = (src, cid)
        c = self.contacts.pop(key, None)
        if c is None:
            late = self.stale.pop(key, None)
            if late is not None:
                late["where"].mark("late_up", ln, f"its {typ} came at line {ln}, {fmt_s(t - late['t'])} after the down")
            else:
                self.where(rec).mark("up_without_down", ln, f"{SRC_NAME[src]} id {cid} {typ} at line {ln} with no down")
            return
        self.contact_step(c, rec)
        held = t - c["t"]
        if held < SHORT_CONTACT_S:
            c["where"].mark("short_contact", ln, f"{SRC_NAME[src]} id {cid} down at line {c['ln']}, {typ} at line {ln} after {fmt_ms(held)}")
        c["down"]["up_t"], c["down"]["up_ln"], c["down"]["ended"] = t, ln, typ
        self.last_up[src] = t
        if not self.contacts:
            self.all_up_since, self.stuck_flagged = t, False

    def walk_control(self, rec):
        where, ln, t, by, action = self.where(rec), rec["_ln"], rec["t"], rec["by"], rec["action"]
        if action == "press" and by in POINTER:
            for d in where.downs:
                if d["src"] == by and not d["answered"] and d["t"] <= t + T_NOISE and (d["up_t"] is None or t <= d["up_t"] + STATE_REACTION_S):
                    d["answered"], d["press_ln"] = True, ln
                    break
            else:
                where.mark("press_without_down", ln, f"{rec['control']} press by {by} at line {ln} with no {SRC_NAME[by]} down waiting for it")
        if action in ("value", "click", "pick") and not rec["contact"] and where.category != "roll":
            held = any(c["src"] == by for c in self.contacts.values())
            recent = t - self.last_up.get(by, -1e9) <= RELEASE_SLACK_S
            if not held and not recent and isinstance(where, Run):
                where.hover.append(rec)

    def run_ended(self, run):
        """Gives the run's held contacts a grace period, and marks the down that closed the run."""
        for c in self.contacts.values():
            if c["where"] is run:
                self.pending.append((run.end_t + DANGLING_GRACE_S, c))
        if run.downs:
            last = run.downs[-1]
            if last["up_t"] is None or last["up_t"] >= run.end_t - CLOSING_TAP_S:
                last["closing"] = True

    def expire(self, t):
        keep = []
        for deadline, c in self.pending:
            if self.contacts.get((c["src"], c["id"])) is not c:
                continue
            if t > deadline:
                self.dangling(c, "by its run's end", t)
            else:
                keep.append((deadline, c))
        self.pending = keep

    def dangling(self, c, when, t):
        if c["where"].truncated:
            return
        c["where"].mark("down_without_up", c["ln"], f"{SRC_NAME[c['src']]} id {c['id']} down at line {c['ln']} (t {fmt_s(c['t'])}) with no up or cancel {when}")
        del self.contacts[(c["src"], c["id"])]
        self.stale[(c["src"], c["id"])] = c
        if not self.contacts:
            self.all_up_since, self.stuck_flagged = t, False

    def check_stuck(self, t, ln):
        """A control that still holds the press well after every pointer came up."""
        if self.all_up_since is None or self.stuck_flagged or self.state is None or not self.state["active"]:
            return
        if t - self.all_up_since > ACTIVE_AFTER_UP_S:
            where = self.where(self.state)
            where.mark("active_stuck", self.state["_ln"], f"state said active=true (line {self.state['_ln']}) still {fmt_s(t - self.all_up_since)} after every pointer was up, at line {ln}")
            self.stuck_flagged = True

    def attach_states(self):
        """Each down gets the state of the frame that answered it, or the state that stood before it."""
        for where in list(self.runs.values()) + [self.outside]:
            for d in where.downs:
                i = bisect.bisect_right(self.state_lns, d["ln"])
                chosen = None
                if i < len(self.states):
                    s = self.states[i]
                    if s["t"] - d["t"] <= STATE_REACTION_S and (d["up_ln"] is None or s["_ln"] < d["up_ln"]):
                        chosen = s
                if chosen is None and i > 0:
                    chosen = self.states[i - 1]
                d["state"] = chosen

    # Per-run checks ------------------------------------------------------------------------------------

    def recount(self, run):
        """Counts what the run received and what the probes answered from its own lines."""
        received = dict.fromkeys(RECEIVED_KEYS, 0)
        responded = dict.fromkeys(RESPONDED_KEYS, 0)
        for rec in run.lines:
            if rec["kind"] == "event":
                key = raw_key(rec["src"], rec["type"])
                if key in received:
                    received[key] += rec.get("n", 1)
            elif rec["kind"] == "control" and rec["action"] in responded:
                responded[rec["action"]] += 1
        palms = sum(1 for d in run.downs if d["src"] == "finger" and d["state"] is not None and d["state"]["palm"])
        presses_by = dict.fromkeys(POINTER, 0)
        for rec in run.of("control", action="press"):
            presses_by[rec["by"]] += 1
        run.stats.update(received=received, responded=responded, palms=palms, presses_by=presses_by,
                         left_out=sum(1 for d in run.downs if left_out(d)))
        if run.result is None or run.truncated:
            return
        metrics, off = run.metrics(), []
        for group, mine in (("received", received), ("responded", responded)):
            theirs = metrics.get(group, {})
            for key, ours in mine.items():
                value = theirs.get(key)
                if not is_int(value):
                    continue
                slack = max(2, METRIC_TOLERANCE * value) if key in FOLDED_KEYS else 0
                if abs(value - ours) > slack:
                    off.append(f"{group}.{key} {value} vs {ours} counted")
        if is_int(metrics.get("palms")) and metrics["palms"] != palms:
            off.append(f"palms {metrics['palms']} vs {palms} from the state lines")
        if off:
            self.warnings.add(run.result["_ln"], f"{run.label}: the result's metrics disagree with the run's own lines: " + "; ".join(off))

    def run_checks(self, run):
        self.check_marks(run)
        self.check_palm_window(run)
        self.check_hover(run)
        self.check_frame_gaps(run)
        if run.truncated:
            # After the truncated line only step, result and anomaly lines were kept, so a missing press,
            # axis or text in this run says nothing about the device; only what was logged is checked.
            run.verdict_evidence.append(f"the log was truncated during this run (line {self.trunc[0]}): its later events were not logged")
            return
        self.check_presses(run)
        self.check_pen_to_finger(run)
        test = run.test
        if test.startswith("slider_ratio_"):
            self.check_ratio(run)
        if test == "pressure_ramp":
            self.check_pressure(run)
        if run.category == "text":
            self.check_text(run)
        if run.category == "roll":
            self.check_roll(run)
        if test == "finger_cancel":
            self.check_cancel(run)
        self.check_background(run)

    def check_presses(self, run):
        for src in PRESS_SRC.get(run.test, ()):
            downs = [d for d in run.downs if d["src"] == src and not left_out(d)]
            missed = [d for d in downs if not d["answered"]]
            if not missed:
                continue
            states = [d["state"] for d in missed if d["state"] is not None]
            palm = sum(1 for s in states if s["palm"])
            near = sum(1 for s in states if s["pen_near"])
            evidence = [
                f"{len(downs)} {SRC_NAME[src]} down(s) received, {len(downs) - len(missed)} answered by a probe press",
                f"unanswered downs at lines {', '.join(str(d['ln']) for d in missed[:12])}",
                f"the state of their frames said palm=true for {palm} and pen_near=true for {near} of {len(missed)}",
            ]
            since = [d["since_pen"] for d in missed if d["since_pen"] is not None]
            if since:
                span = fmt_s(min(since)) if min(since) == max(since) else f"{fmt_s(min(since))} to {fmt_s(max(since))}"
                evidence.append(f"time since the last pen event at those downs: {span}")
            correlates = None
            if palm:
                correlates = f"correlates with the app taking the {SRC_NAME[src]} for a palm" + (" while state said pen_near=true" if near else "")
            title = f"{len(missed)} of {len(downs)} {SRC_NAME[src]} downs got no probe press"
            run.checks.append(finding("received_not_responded", run, title, evidence, [d["ln"] for d in missed],
                                      correlates, backs=True, codes=("received_not_responded", "finger_palm")))

    MARK_TITLES = {
        "down_without_up": ("{n} contact(s) went down with no up or cancel by the run's end", ("down_without_up",)),
        "up_without_down": ("{n} up or cancel event(s) for an id that was not down", ("up_without_down",)),
        "double_down": ("{n} second down(s) for an id already down", ()),
        "pen_down_without_near": ("{n} Pencil down(s) without a near first, on a platform that sends near", ()),
        "move_not_down": ("{n} finger move(s) for an id that was not down", ()),
        "short_contact": ("{n} contact(s) lasted under 10 ms from down to up", ()),
        "contact_gap": ("{n} gap(s) over 0.25 s between events while a contact moved", ()),
        "press_without_down": ("{n} probe press(es) with no matching raw down in the run", ()),
        "active_stuck": ("A control stayed active more than 0.3 s after every pointer was up", ("stuck_pressed",)),
    }

    def check_marks(self, where):
        for code, (title, codes) in self.MARK_TITLES.items():
            items = where.marks.get(code)
            if not items:
                continue
            evidence = [text for _, text in items[:8]]
            if len(items) > 8:
                evidence.append(f"and {len(items) - 8} more at lines {lines_text(items[8:])}")
            if code == "down_without_up" and where.marks.get("late_up"):
                evidence += [text for _, text in where.marks["late_up"][:4]]
            correlates = "consistent with events lost or held back while the contact moved" if code == "contact_gap" else None
            target = where if isinstance(where, Run) else self.outside
            item = finding(code, target, title.format(n=len(items)), evidence, [ln for ln, _ in items], correlates, codes=codes)
            (where.checks if isinstance(where, Run) else self.findings).append(item)

    def check_palm_window(self, run):
        soon = [d for d in run.downs if d["src"] == "finger" and d["state"] is not None and d["state"]["palm"]
                and d["since_pen"] is not None and d["since_pen"] <= PALM_WINDOW_S]
        if soon:
            evidence = [f"finger down at line {d['ln']}, {fmt_ms(d['since_pen'])} after the last pen event, taken as a palm" for d in soon[:8]]
            run.checks.append(finding(
                "palm_after_pen", run, f"{len(soon)} finger down(s) within 0.6 s after the last pen event became a palm",
                evidence, [d["ln"] for d in soon],
                "consistent with a palm-rejection window after the Pencil; a finger this soon may be meant as a palm",
                codes=("finger_palm",)))

    def check_hover(self, run):
        if not run.hover:
            return
        groups = {}
        for rec in run.hover:
            groups.setdefault((rec["control"], rec["action"]), []).append(rec)
        hovering = [r for r in run.of("event", src="pen", type="move")]
        for (control, action), recs in groups.items():
            what = {"value": f"The {control}'s value changed", "click": f"The {control} clicked", "pick": f"The {control} picked"}[action]
            evidence = [f"{len(recs)} {action} line(s) by {recs[0]['by']} with contact=false and no contact held"]
            changes = [r for r in recs if "before" in r and "after" in r]
            if changes:
                total = sum(r["after"] - r["before"] for r in changes)
                evidence.append(f"value moved {total:+.4g} in total: " + ", ".join(f"{fmt_num(r['before'])} to {fmt_num(r['after'])} (line {r['_ln']})" for r in changes[:5]))
            correlates = None
            if hovering:
                correlates = f"correlates with {sum(r['n'] for r in hovering)} Pencil hover move(s) (no pen down) in the same run"
            run.checks.append(finding("hover_changed_value", run, f"{what} {len(recs)} time(s) with no contact", evidence,
                                      [r["_ln"] for r in recs], correlates, backs=True, codes=("hover_changed_value",)))

    def check_pen_to_finger(self, run):
        fingers = [d for d in run.downs if d["src"] == "finger" and d["since_pen"] is not None]
        if not fingers or TEST_INFO.get(run.test, {}).get("device") != "finger+pencil" or run.category == "system":
            return
        run.stats["pen_to_finger_ms"] = round(fingers[0]["since_pen"] * 1000)
        answered = [d for d in fingers if d["answered"]]
        run.stats["pen_to_answered_finger_ms"] = round(answered[0]["since_pen"] * 1000) if answered else None
        text = f"from the last pen event to the first finger down: {fmt_ms(fingers[0]['since_pen'])} (line {fingers[0]['ln']}); "
        text += f"to the first answered finger down: {fmt_ms(answered[0]['since_pen'])} (line {answered[0]['ln']})" if answered else "no finger down was answered"
        run.verdict_evidence.append(text)
        metric = run.metrics().get("pen_to_finger_ms")
        if is_num(metric) and abs(metric - fingers[0]["since_pen"] * 1000) > 20:
            self.warnings.add(run.result["_ln"], f"{run.label}: metrics pen_to_finger_ms {metric:.0f} vs {fingers[0]['since_pen'] * 1000:.0f} from the lines")

    def check_ratio(self, run):
        values = [r for r in run.of("control", action="value") if r["control"] in ("slider", "vslider") and "before" in r and "after" in r and r["contact"]]
        travels = [abs(r["travel"]) for r in run.of("control") if "travel" in r]
        metrics = run.metrics()
        ratio, source = None, "the run's control lines"
        if values and travels and max(travels) > 0:
            ratio = abs(values[-1]["after"] - values[0]["before"]) / max(travels)
            if is_num(metrics.get("ratio")) and metrics["ratio"] and abs(ratio - metrics["ratio"]) / metrics["ratio"] > METRIC_TOLERANCE:
                self.warnings.add(run.result["_ln"], f"{run.label}: metrics ratio {metrics['ratio']:.4g} vs {ratio:.4g} from the control lines")
        elif is_num(metrics.get("ratio")):
            ratio, source = metrics["ratio"], "the result's metrics (the lines carry no travel)"
        run.stats["ratio"], run.stats["ratio_source"] = ratio, source
        expected = metrics.get("expected_ratio")
        if ratio is None or not is_num(expected) or expected == 0:
            return
        off = (ratio - expected) / expected
        run.stats["ratio_off"] = off
        if abs(off) > RATIO_TOLERANCE:
            evidence = [f"ratio {ratio:.4g} value units per point from {source}, expected {expected:.4g}",
                        f"{len(values)} value line(s), {max(travels) if travels else metrics.get('travel_pt')} pt of travel"]
            run.checks.append(finding("ratio_off", run, f"Slider ratio is {abs(off) * 100:.0f}% {'below' if off < 0 else 'above'} the expected ratio",
                                      evidence, [r["_ln"] for r in values], backs=True))

    def check_pressure(self, run):
        metrics = run.metrics()
        if not run.pressure:
            pen_downs = len(run.of("event", src="pen", type="down"))
            other = sum(r["n"] for r in run.of("event", src="pen", type="axis"))
            evidence = [f"{pen_downs} Pencil down(s) and {other} other axis report(s), no pressure axis line",
                        f"{run.pressure_on_lines} Pencil down or move line(s) carried a pressure value",
                        f"result metrics: pressure_min {fmt_num(metrics.get('pressure_min'))}, pressure_max {fmt_num(metrics.get('pressure_max'))}, pressure_samples {fmt_num(metrics.get('pressure_samples'))}"]
            run.checks.append(finding("pressure_unavailable", run, "Pressure unavailable: no pressure axis lines in the run (not read as zero)",
                                      evidence, [run.start_ln], "a Pencil or driver that reports no pressure, or a ramp drawn without contact",
                                      covers=True, codes=("pressure_unavailable",), default="needs"))
            return
        values = [v for _, v in run.pressure]
        run.stats.update(pressure_min=min(values), pressure_max=max(values), pressure_samples=len(values))
        if max(values) - min(values) < 0.3:
            run.checks.append(finding("pressure_narrow", run, f"Pressure only spanned {min(values):.2f} to {max(values):.2f} over the ramp",
                                      [f"{len(values)} pressure axis line(s)"], [ln for ln, _ in run.pressure[:20]], backs=True))

    def check_text(self, run):
        states = run.of("state")
        focus = [s for s in states if s["text_focus"]]
        typing = any(s["text_input"] for s in states)
        if focus and not typing:
            run.checks.append(finding("focus_without_text_input", run, "The field took focus but text input never turned on",
                                      [f"{len(focus)} state line(s) with text_focus=true, none with text_input=true"],
                                      [s["_ln"] for s in focus[:20]], backs=True))
        self.check_keyboard(run, states)
        texts = run.of("event", src="text", type="text")
        # With no state line before it, the focus at a text event is unknown, not false.
        loose = [r for r in texts if (self.state_before(r["_ln"]) or {"text_focus": True})["text_focus"] is False]
        if loose:
            run.checks.append(finding("text_without_focus", run, f"{len(loose)} text event(s) arrived while no field had focus",
                                      [f"text at line {r['_ln']} ({r['len']} bytes)" for r in loose[:6]], [r["_ln"] for r in loose],
                                      backs=True, codes=("text_without_focus",)))
        keys = run.of("event", src="key", type="key_down") + texts
        if run.test == "text_typing" and keys and not run.of("control", action="text"):
            run.checks.append(finding("typing_lost", run, "Typed text never reached the field",
                                      [f"{len(keys)} key or text event(s), no probe text line"], [r["_ln"] for r in keys[:20]], backs=True))
        if run.test == "text_typing" and keys:
            self.check_typed_text(run, keys)
        pen_downs = run.of("event", src="pen", type="down")
        if run.test == "text_scribble" and pen_downs and not texts:
            run.checks.append(finding("scribble_no_text", run, "Writing with the Pencil produced no text",
                                      [f"{len(pen_downs)} Pencil down(s) in the run, no text event"], [r["_ln"] for r in pen_downs], backs=True))
        if run.test in ("text_focus_finger", "text_focus_pencil"):
            presses = [r for r in run.of("control", action="press") if r["control"] == "field"]
            if presses and not run.of("control", action="focus"):
                run.checks.append(finding("field_no_focus", run, "The field was pressed but never took focus",
                                          [f"{len(presses)} field press(es), no focus line"], [r["_ln"] for r in presses], backs=True))

    def state_before(self, ln):
        """The state that stood when line ln was logged: state lines are written only when something changes."""
        i = bisect.bisect_left(self.state_lns, ln)
        return self.states[i - 1] if i > 0 else None

    def check_typed_text(self, run, keys):
        """The field's text lines carry its whole (synthetic) text after each change, so the last one shows
        what the typing left, against what the test's instruction leaves."""
        changes = [r for r in run.of("control", action="text") if r["control"] == "field" and isinstance(r.get("text"), str)]
        if not changes or changes[-1]["text"] == TYPING_RESULT:
            return
        last = changes[-1]
        printable = sum(1 for r in keys if r["src"] == "key" and r["key"] == "printable")
        backspaces = sum(1 for r in keys if r["src"] == "key" and r["key"] == "Backspace")
        texts = [r for r in keys if r["src"] == "text"]
        evidence = [
            f'the field\'s last text line (line {last["_ln"]}) holds {last["text"]!r}; typing "{TYPING_INPUT}" and pressing '
            f'Backspace twice leaves {TYPING_RESULT!r}',
            "the field went " + " -> ".join(repr(r["text"]) for r in changes[-8:]),
            f"{printable} printable key(s), {backspaces} Backspace(s) and {len(texts)} text event(s) "
            f"({sum(r['len'] for r in texts)} byte(s)) arrived in the run",
        ]
        run.checks.append(finding("typed_text_wrong", run, f"The field ended holding {last['text']!r}, not {TYPING_RESULT!r}",
                                  evidence, [r["_ln"] for r in changes] + [r["_ln"] for r in keys[:20]], backs=True))

    def check_keyboard(self, run, states):
        """The keyboard's window events against the state's keyboard flag, and a keyboard that does not return."""
        if not states or all(s["keyboard"] is None for s in states):
            return
        problems = []
        events = run.of("event", src="window")
        for ev in events:
            if ev["type"] not in ("keyboard_shown", "keyboard_hidden"):
                continue
            want = ev["type"] == "keyboard_shown"
            later = [s for s in states if ev["_ln"] < s["_ln"] and s["t"] <= ev["t"] + 0.5]
            before = [s for s in states if s["_ln"] < ev["_ln"]]
            settled = later[-1] if later else (before[-1] if before else None)
            if settled is not None and settled["keyboard"] is not None and settled["keyboard"] != want:
                problems.append((ev["_ln"], f"{ev['type']} at line {ev['_ln']}, but the state said keyboard={str(settled['keyboard']).lower()} at line {settled['_ln']}"))
        hidden = [ev for ev in events if ev["type"] == "keyboard_hidden"]
        if hidden:
            for focus in [r for r in run.of("control", action="focus") if r["t"] > hidden[0]["t"]]:
                shown = [ev for ev in events if ev["type"] == "keyboard_shown" and focus["t"] - 0.1 <= ev["t"] <= focus["t"] + 1.0]
                if not shown:
                    after = [s for s in states if s["_ln"] > focus["_ln"]]
                    note = f"; the state then said text_input={str(after[-1]['text_input']).lower()} keyboard={str(after[-1]['keyboard']).lower()}" if after else ""
                    problems.append((focus["_ln"], f"the field took focus again at line {focus['_ln']} after the keyboard was hidden, and no keyboard_shown followed within 1 s{note}"))
        if problems:
            run.checks.append(finding("keyboard_desync", run, "The on-screen keyboard and the app's keyboard state disagree",
                                      [text for _, text in problems[:6]], [ln for ln, _ in problems], backs=True, codes=("keyboard_desync",)))

    def check_roll(self, run):
        metrics = run.metrics()
        if not run.rotation:
            pens = len(run.of("event", src="pen"))
            run.checks.append(finding("no_rotation", run, "No rotation axis lines: the roll cannot be judged",
                                      [f"{pens} Pencil event line(s) in the run, none a rotation axis",
                                       f"result metrics: rotation_reports {fmt_num(metrics.get('rotation_reports'))}"],
                                      [run.start_ln], "a Pencil without barrel roll (the test needs a Pencil Pro) or a driver not reporting rotation",
                                      covers=True, default="needs"))
            return
        net, wraps, prev = 0.0, 0, None
        for _, _, value, wrap in run.rotation:
            if prev is not None:
                step = value - prev
                if step > 180:
                    step -= 360
                    wraps += 1
                elif step < -180:
                    step += 360
                    wraps += 1
                net += step
            prev = value
        flagged = sum(1 for r in run.rotation if r[3])
        values = [r[2] for r in run.rotation]
        value_lines = [r for r in run.of("control", action="value") if "before" in r and "after" in r]
        delta = sum(r["after"] - r["before"] for r in value_lines) if value_lines else metrics.get("value_delta")
        source = "the run's control lines" if value_lines else "the result's metrics"
        run.stats.update(roll_net_deg=round(net, 1), value_delta=delta, wraps=max(wraps, flagged))
        facts = [f"{len(run.rotation)} rotation axis line(s), raw {min(values):.1f} to {max(values):.1f} degrees, net {net:+.1f} degrees unwrapped",
                 f"slider value_delta {fmt_num(delta)} from {source}"]
        run.verdict_evidence += facts
        lines = [r[0] for r in run.rotation[:10]] + [r["_ln"] for r in value_lines[:10]]
        sign = ROLL_SIGN.get(run.test)
        if sign and is_num(delta):
            if delta * sign <= 0:
                moved = "did not move" if delta == 0 else ("went down" if delta < 0 else "went up")
                context = (f"the raw rotation moved {net:+.1f} degrees while the value {moved}; context: SDL's UIKit driver passes the Pencil's "
                           "rollAngle through in degrees, and its source notes the conversion was never tried on a Pencil that rolls")
                run.checks.append(finding("roll_wrong_direction", run, f"Slider value {moved} during {run.test} (expected {'up' if sign > 0 else 'down'})",
                                          facts, lines, context if self.ios() else f"the raw rotation moved {net:+.1f} degrees", backs=True,
                                          codes=("roll_wrong_direction",)))
        if run.test == "roll_neutral":
            reference = [abs(r.stats.get("value_delta") or 0) for r in self.all_runs() if r.test in ROLL_SIGN and is_num(r.stats.get("value_delta"))]
            limit = 0.1 * max(reference) if reference and max(reference) > 0 else 0.02
            if abs(net) > ROLL_DRIFT_DEG or (is_num(delta) and abs(delta) > limit):
                run.checks.append(finding("roll_drift", run, "The value drifted while the Pencil was held without rolling", facts, lines,
                                          backs=True, codes=("roll_jump",)))
        if run.test == "roll_wrap":
            if not wraps and not flagged and metrics.get("wrapped") is not True:
                run.checks.append(finding("roll_no_wrap", run, "No wrap across +-180 degrees: the wrap was not exercised", facts, lines,
                                          covers=True, default="needs"))
            jumps = [r for r in run.of("control") if is_num(r.get("roll")) and abs(r["roll"]) > ROLL_JUMP_DEG]
            max_step = metrics.get("max_step")
            if jumps or (is_num(max_step) and max_step > MAX_STEP_SMALL):
                evidence = facts + [f"largest one-frame change {fmt_num(max_step)} of the slider's range (metrics)"]
                evidence += [f"roll {r['roll']:+.1f} degrees in one frame at line {r['_ln']}" for r in jumps[:4]]
                run.checks.append(finding("roll_jump", run, "The value jumped at the wrap", evidence, lines + [r["_ln"] for r in jumps],
                                          backs=True, codes=("roll_jump",)))

    def check_cancel(self, run):
        cancels = run.of("event", src="finger", type="cancel")
        probe = run.of("control", action="cancel")
        if not cancels:
            run.verdict_evidence.append("no finger cancel arrived, so the cancel path was not exercised")
            return
        if not probe:
            run.checks.append(finding("cancel_not_seen", run, f"The OS cancelled {len(cancels)} touch(es) but no probe saw a cancel",
                                      [f"finger cancel at line {r['_ln']}" for r in cancels[:6]], [r["_ln"] for r in cancels],
                                      backs=True, codes=("os_cancel",)))

    def check_background(self, run):
        window_h = self.window()[1]
        backgrounds = run.of("event", src="app", type="background") or run.of("event", src="app", type="will_background")
        if run.category == "system":
            downs = [d for d in run.downs if d["src"] == "finger"]
            edge = [d for d in downs if window_h and d["y"] >= window_h - EDGE_PT]
            first = backgrounds[0]["t"] if backgrounds else None
            seconds = first - edge[0]["t"] if first is not None and edge and edge[0]["t"] <= first else None
            before = [d for d in edge if first is None or d["t"] <= first]
            run.stats.update(background=len(backgrounds), edge_downs=len(edge), edge_downs_before_background=len(before),
                             seconds_to_background=seconds)
            text = f"{len(edge)} finger down(s) within 40 pt of the bottom edge, {len(backgrounds)} background event(s)"
            if first is not None:
                text += f"; {len(before)} edge down(s) before the first background (line {backgrounds[0]['_ln']})"
            run.verdict_evidence.append(text)
            metrics = run.metrics()
            if is_int(metrics.get("background")) and metrics["background"] != len(backgrounds) and not run.truncated:
                self.warnings.add(run.result["_ln"], f"{run.label}: metrics background {metrics['background']} vs {len(backgrounds)} in the lines")
            return
        if backgrounds:
            run.checks.append(finding("background_during_step", run, "The app went to the background during the test",
                                      [f"background at line {r['_ln']}" for r in backgrounds[:4]], [r["_ln"] for r in backgrounds],
                                      "events around a background are cut short by the OS", codes=("background_during_step",)))

    def check_frame_gaps(self, run):
        gaps = [r for r in run.of("anomaly", code="frame_gap")]
        if gaps:
            count = sum(r["count"] for r in gaps)
            run.checks.append(finding("frame_gap", run, f"The app reported {count} frame gap(s) during the test",
                                      [f"line {r['_ln']}: {r['detail']}" for r in gaps[:6]], [r["_ln"] for r in gaps],
                                      "events arriving in a late frame look delayed to every check above", codes=("frame_gap",)))

    # Session-wide checks -------------------------------------------------------------------------------

    def ios(self):
        return self.session.get("platform") == "iOS"

    def window(self):
        w = self.session.get("window")
        return (w[0], w[1]) if isinstance(w, list) and len(w) == 2 and all(is_num(v) for v in w) else (0, 0)

    def session_checks(self):
        self.check_marks(self.outside)
        self.check_proximity()
        if self.backwards:
            worst = max(self.backwards, key=lambda b: b[1])
            self.findings.append(finding("t_backwards", self.outside, f"t went backwards {len(self.backwards)} time(s)",
                                         [f"largest step back {fmt_ms(worst[1])} at line {worst[0]}"], [b[0] for b in self.backwards],
                                         "every timing check reads t, so timings around these lines are unreliable"))
        if self.trunc is not None:
            cut = [r.label for r in self.all_runs() if r.truncated]
            self.findings.append(finding("log_truncated", self.outside, f"The log was truncated at line {self.trunc[0]} ({fmt_s(self.trunc[1])})",
                                         ["after it the app logged only step, result and anomaly lines",
                                          f"runs affected: {', '.join(cut) if cut else 'none'}"], [self.trunc[0]],
                                         covers=True, codes=("log_truncated",), default="needs"))
        loose = [r for r in self.records if r["kind"] == "anomaly" and r["step"] is None and r["code"] == "frame_gap"]
        if loose:
            self.findings.append(finding("frame_gap", self.outside, f"The app reported {sum(r['count'] for r in loose)} frame gap(s) outside the tests",
                                         [f"line {r['_ln']}: {r['detail']}" for r in loose[:6]], [r["_ln"] for r in loose], codes=("frame_gap",)))

    def check_proximity(self):
        pens = [r for r in self.records if r["kind"] == "event" and r["src"] == "pen"]
        nears = [r for r in pens if r["type"] == "near"]
        fars = [r for r in pens if r["type"] == "far"]
        if not nears or fars:
            return
        palms = [(where, d) for where in self.all_runs() for d in where.downs
                 if d["src"] == "finger" and d["t"] > nears[0]["t"] and d["state"] is not None and d["state"]["palm"] and d["state"]["pen_near"]]
        tests = sorted({w.label for w, _ in palms}, key=lambda s: (TEST_ORDER.get(s.split(" run ")[0], 99), s))
        last_state = self.states[-1] if self.states else None
        evidence = [f"{len(nears)} pen near line(s), the first at line {nears[0]['_ln']} ({fmt_s(nears[0]['t'])}), and no far line"]
        if last_state is not None:
            evidence.append(f"the last state line (line {last_state['_ln']}) says pen_near={str(last_state['pen_near']).lower()}")
        if self.pen_idle[1] is not None:
            evidence.append(f"the state kept pen_near=true for up to {fmt_s(self.pen_idle[0])} with no pen event (the stretch ending at line {self.pen_idle[1]})")
        correlates = None
        if palms:
            correlates = (f"correlates with {len(palms)} finger down(s) after the first near taken as a palm while state said "
                          f"pen_near=true ({', '.join(tests)})")
        if self.ios():
            context = ("context, not a conclusion: SDL's UIKit driver is known not to send pen proximity-out on iOS (it adds the Pencil "
                       "on its first event and removes it only at shutdown), so a missing far is expected from the driver")
            correlates = f"{correlates}; {context}" if correlates else context
        lists = "needs" if self.trunc is not None else "suspicious"
        if self.trunc is not None:
            evidence.append(f"the log was truncated at line {self.trunc[0]}, so a later far may not have been logged")
        self.findings.append(finding("pen_near_never_far", self.outside, "Pen proximity never left: near arrived and far never did",
                                     evidence, [nears[0]["_ln"]] + [d["ln"] for _, d in palms[:12]], correlates,
                                     codes=("pen_near_stuck",), default=lists))

    # Verdicts -------------------------------------------------------------------------------------------

    def classify(self, run):
        """Turns the run's verdicts and its checks into findings, each in exactly one of the three lists."""
        result = run.result
        auto = result["auto"] if result and result["auto"] in AUTO else None
        manual = result["manual"] if result and result["manual"] in MANUAL else None
        backing = [c for c in run.checks if c["_backs"]]
        rest = [c for c in run.checks if not c["_backs"]]
        verdict = ["no result line"]
        if result:
            verdict = [f"auto: {result['auto']} ({result['auto_reason'] or 'no reason given'})",
                       f"manual: {result['manual'] or 'none'}" + (f" ({result['notes']})" if result["notes"] else "")]
        context = self.home_context() if run.category == "system" else None
        if run.end_action == "skip" and auto != "fail" and manual != "fail":
            # The person skipped the run: its heuristics still count, but there is no verdict to weigh.
            backing, rest = [], rest + backing
        elif result is None:
            if run.end_action != "skip":
                rest.append(finding("no_result", run, "The run has no result line", run.verdict_evidence + [f"started at line {run.start_ln}"],
                                    [run.start_ln], default="needs"))
            backing, rest = [], rest + backing
        elif manual == "fail":
            rest.append(self.merged("manual_fail", run, f"Judged failed by the person{': ' + result['notes'] if result['notes'] else ''}",
                                    verdict, backing, "confirmed", context))
            backing = []
        elif auto == "fail" and manual == "pass":
            rest.append(self.merged("verdicts_disagree", run, "The automatic verdict says fail, the person says pass", verdict, backing, "needs", context))
            backing = []
        elif auto == "fail" and backing:
            rest.append(self.merged("auto_fail", run, backing[0]["title"], verdict, backing, "confirmed", context))
            backing = []
        elif auto == "fail":
            why = "the log was truncated during the run" if run.truncated else "no check found the failure in the run's lines"
            rest.append(self.merged("auto_fail_unbacked", run, f"Automatic fail not borne out by the run's own lines ({why})",
                                    verdict, [], "needs", context))
        elif manual in ("pass",):
            pass
        elif auto != "pass" or manual == "inconclusive":
            covering = [c for c in rest if c["_covers"]]
            if covering:
                covering[0]["evidence"] = verdict + covering[0]["evidence"]
            else:
                title = ("Manual-only test without a manual verdict" if run.test in MANUAL_ONLY and manual is None
                         else f"Automatic verdict {result['auto']}, {'the person could not decide' if manual == 'inconclusive' else 'no manual verdict'}")
                rest.append(self.merged("undecided", run, title, verdict, [], "needs", context))
        for item in rest + backing:
            self.findings.append(item)

    def merged(self, code, run, title, verdict, backing, lists, context=None):
        evidence = verdict + run.verdict_evidence
        for check in backing:
            nested = check["title"] != title
            if nested:
                evidence.append(check["title"])
            evidence += [("  " if nested else "") + e for e in check["evidence"] if e not in evidence]
        notes = [c["correlates_with"] for c in backing if c["correlates_with"]]
        if context:
            notes.append(context)
        item = finding(code, run, title, evidence, [ln for c in backing for ln in c["lines"]] + [run.result["_ln"] if run.result else run.start_ln],
                       "; ".join(notes) or None, default=lists)
        item["_codes"] = set().union(*(c["_codes"] for c in backing)) if backing else set()
        return item

    def home_context(self):
        """What SDL's UIKit view controller does with the screen edges under this session's hint: iOS asks
        for a second swipe at an edge the app defers."""
        if not self.ios():
            return None
        hints = self.session.get("hints") if isinstance(self.session.get("hints"), dict) else {}
        hint = hints.get("ios_hide_home_indicator")
        if hint == "2":
            effect = "SDL defers every screen edge, and iOS asks for a second swipe at a deferred edge"
        elif hint in ("0", "1"):
            effect = "SDL defers no screen edge, so a deferred edge does not account for a second swipe"
        else:
            effect = ("SDL defers every screen edge when the window is fullscreen or borderless, and iOS asks for a second swipe "
                      "at a deferred edge")
        return f"context: with this session's ios_hide_home_indicator hint {hint!r}, {effect}"

    def claim_app_anomalies(self):
        """The app's own live detections: noted on the findings that match them, listed alone when none does."""
        claimed = {}
        for item in self.findings:
            for code in item["_codes"]:
                claimed.setdefault((item["test"], item["run"]), {}).setdefault(code, []).append(item)
                if item["test"] is None:
                    claimed.setdefault("session", {}).setdefault(code, []).append(item)
        groups = {}
        for rec in self.records:
            if rec["kind"] == "anomaly" and rec["code"] in ANOMALY_CODES and rec["severity"] != "info" and rec["code"] not in ("frame_gap",):
                groups.setdefault((rec["step"], rec["run"] if rec["step"] else None, rec["code"]), []).append(rec)
        for (test, number, code), recs in groups.items():
            count = sum(r["count"] for r in recs)
            where = f"{test} run {number}" if test else "outside the tests"
            owners = claimed.get((test, number), {}).get(code) or claimed.get("session", {}).get(code)
            if owners:
                for owner in owners:
                    own = (owner["test"], owner["run"]) == (test, number)
                    note = f"the app's live detection reported {code} x{count}" + ("" if own else f" in {where}")
                    owner["correlates_with"] = f"{owner['correlates_with']}; {note}" if owner["correlates_with"] else note
                continue
            target = self.runs.get((test, number)) or self.outside
            self.findings.append(finding("app_anomaly", target, f"The app's live detection reported {code} x{count}, not found in the logged lines by this analysis",
                                         [f"line {r['_ln']} ({r['severity']}): {r['detail']}" for r in recs[:6]], [r["_ln"] for r in recs],
                                         default="suspicious"))

    # Baseline against after-Pencil ----------------------------------------------------------------------

    def test_stats(self, test):
        runs = self.test_runs.get(test, [])
        if not runs:
            return None
        # The same counts as the tests table: the device's received downs and its probe press lines.
        device = "pen" if TEST_INFO.get(test, {}).get("device") == "pencil" else "finger"
        downs = sum(r.stats["received"][f"{device}_down"] for r in runs)
        skipped = sum(1 for r in runs for d in r.downs if d["src"] == device and left_out(d))
        presses = sum(r.stats["presses_by"][device] for r in runs)
        probed = device in PRESS_SRC.get(test, ())
        out = {
            "runs": len(runs),
            "verdicts": ", ".join(f"{r.result['auto']}/{r.result['manual'] or '-'}" if r.result else "no result" for r in runs),
            "device": SRC_NAME[device],
            "downs": downs,
            "presses": presses if probed else None,
            "response_rate": round(presses / (downs - skipped), 3) if downs > skipped and probed else None,
            "palms": sum(r.stats.get("palms", 0) for r in runs),
        }
        if skipped and probed:
            out["downs_left_out_of_the_rate"] = skipped
        for key in ("ratio", "background", "edge_downs", "edge_downs_before_background", "seconds_to_background",
                    "pen_to_finger_ms", "pen_to_answered_finger_ms"):
            values = [r.stats[key] for r in runs if r.stats.get(key) is not None]
            if values:
                out[key] = round(sum(values) / len(values), 6) if key in ("ratio", "seconds_to_background") else values[-1]
        for key in ("text_input_on", "keyboard_shown", "focus_changes"):
            values = [r.metrics().get(key) for r in runs if key in r.metrics()]
            if values:
                out[key] = values[-1]
        return out

    def compare(self):
        confirmed_tests = {f["test"] for f in self.findings if f["_list"] == "confirmed"}
        for base, after in PAIRS:
            a, b = self.test_stats(base), self.test_stats(after)
            rows, flags = [], []
            keys = ["verdicts", "device", "downs", "presses", "response_rate", "palms"]
            keys += [k for k in ("downs_left_out_of_the_rate", "ratio", "background", "edge_downs", "edge_downs_before_background", "seconds_to_background",
                                 "pen_to_finger_ms", "pen_to_answered_finger_ms", "text_input_on", "keyboard_shown", "focus_changes")
                     if (a and k in a) or (b and k in b)]
            for key in keys:
                row = {"measure": key, "baseline": a.get(key) if a else None, "after": b.get(key) if b else None}
                if row["baseline"] is not None or row["after"] is not None:
                    rows.append(row)
            self.comparisons.append({"baseline": base, "after": after, "baseline_runs": a["runs"] if a else 0,
                                     "after_runs": b["runs"] if b else 0, "rows": rows})
            if not a or not b:
                continue
            where = self.test_runs[after][-1]
            if a.get("ratio") and b.get("ratio") is not None:
                diff = (b["ratio"] - a["ratio"]) / a["ratio"]
                if abs(diff) > RATIO_TOLERANCE:
                    flags.append(finding("ratio_differs", where, f"Slider ratio differs by {abs(diff) * 100:.0f}% between finger and Pencil (needs interpretation)",
                                         [f"{base}: {a['ratio']:.4g} value units per point; {after}: {b['ratio']:.4g}",
                                          f"verdicts {base}: {a['verdicts']}; {after}: {b['verdicts']}"],
                                         [r.start_ln for r in self.test_runs[base] + self.test_runs[after]],
                                         "consistent with the slider mapping Pencil travel differently from finger travel, or with a different drag "
                                         "by the person; try both on the iPad"))
            if after not in confirmed_tests:
                if a["response_rate"] is not None and b["response_rate"] is not None and a["response_rate"] - b["response_rate"] >= 0.2:
                    flags.append(finding("rate_drops", where, f"Response rate falls from {a['response_rate']:.0%} ({base}) to {b['response_rate']:.0%} ({after})",
                                         [f"{base}: {a['presses']} of {a['downs']}; {after}: {b['presses']} of {b['downs']}"],
                                         [r.start_ln for r in self.test_runs[after]]))
                if b["palms"] > a["palms"]:
                    flags.append(finding("palms_rise", where, f"Palms rise from {a['palms']} ({base}) to {b['palms']} ({after})",
                                         [f"finger downs taken as a palm, from the state lines"], [r.start_ln for r in self.test_runs[after]]))
                ea, eb = a.get("edge_downs_before_background"), b.get("edge_downs_before_background")
                if ea is not None and eb is not None and eb > ea:
                    flags.append(finding("more_swipes", where, f"The home swipe needed {eb} edge down(s) after the Pencil against {ea} before",
                                         [f"background events {base}: {a.get('background')}; {after}: {b.get('background')}"],
                                         [r.start_ln for r in self.test_runs[after]], self.home_context()))
            self.findings += flags

    # Output --------------------------------------------------------------------------------------------

    def tests_table(self):
        ids = [t[0] for t in TESTS]
        extra = list(self.test_runs) + [e.get("id") for e in (self.summary or {}).get("tests", []) if isinstance(e, dict)]
        ids += [t for t in extra if isinstance(t, str) and t not in ids and t not in TEST_INFO]
        ids = list(dict.fromkeys(ids))
        out = []
        for test in ids:
            entry = self.summary_test(test)
            info = TEST_INFO.get(test, {})
            runs = []
            for run in self.test_runs.get(test, []):
                result = run.result or {}
                anomalies = {}
                for rec in run.of("anomaly"):
                    anomalies[rec["code"]] = anomalies.get(rec["code"], 0) + rec["count"]
                runs.append({
                    "run": run.run, "start": run.start_t, "end": run.end_t, "end_action": run.end_action,
                    "start_line": run.start_ln, "end_line": run.end_ln, "truncated": run.truncated,
                    "auto": result.get("auto"), "auto_reason": result.get("auto_reason"), "manual": result.get("manual"),
                    "notes": result.get("notes"), "counted": run.stats, "metrics": result.get("metrics"), "anomalies": anomalies,
                })
            out.append({
                "id": test, "title": entry.get("title") or test.replace("_", " "),
                "category": info.get("category") or entry.get("category"), "device": info.get("device") or entry.get("device"),
                "needs": entry.get("needs") if isinstance(entry.get("needs"), list) else info.get("needs", []),
                "known": test in TEST_INFO, "skipped": test in self.skipped, "runs": runs,
            })
        return out

    def output(self):
        tests = self.tests_table() if self.session else []
        lists = {"confirmed": [], "suspicious": [], "needs": []}
        order = lambda f: (TEST_ORDER.get(f["test"], -1 if f["test"] is None else 99), f["test"] or "", f["run"] or 0,
                           f["lines"][0] if f["lines"] else 0, f["kind"])
        for item in sorted(self.findings, key=order):
            lists[item["_list"]].append(item)
        for prefix, name in (("C", "confirmed"), ("S", "suspicious"), ("N", "needs")):
            for i, item in enumerate(lists[name], 1):
                item["id"] = f"{prefix}{i}"
        clean = lambda items: [{k: v for k, v in [("id", f["id"])] + list(f.items()) if not k.startswith("_")} for f in items]
        report = {k: v for k, v in (self.session or {}).items() if not k.startswith("_") and k != "kind"}
        report["source"] = self.source
        report["files"] = sorted(self.files)
        if self.summary:
            report["summary"] = {k: self.summary.get(k) for k in ("ended", "duration_s", "lines", "dropped", "bytes", "truncated")}
        report["truncated_at_line"] = self.trunc[0] if self.trunc else None
        not_tested = [{"test": t["id"], "category": t["category"], "needs": t["needs"], "skipped": t["skipped"]}
                      for t in tests if not t["runs"]]
        return {
            "schema": SCHEMA, "report": report, "valid": len(self.errors) == 0,
            "errors": self.errors.as_list(), "warnings": self.warnings.as_list(), "tests": tests,
            "confirmed_failures": clean(lists["confirmed"]), "suspicious_patterns": clean(lists["suspicious"]),
            "needs_manual_interpretation": clean(lists["needs"]), "comparisons": self.comparisons, "not_tested": not_tested,
        }


# --- Markdown -------------------------------------------------------------------------------------------


def cell(v):
    if v is None:
        return "-"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        return f"{v:.4g}"
    return str(v).replace("|", "\\|").replace("\n", " ")


def md_findings(items, empty):
    if not items:
        return [empty, ""]
    out = []
    for f in items:
        where = f"{f['test']} run {f['run']}" if f["test"] else "whole session"
        out.append(f"### {f['id']} · {where}: {f['title']}")
        out += [f"- {e.strip()}" if not e.startswith("  ") else f"  - {e.strip()}" for e in f["evidence"]]
        if f["correlates_with"]:
            notes = [re.sub(r"^correlates with ", "", n.strip()) for n in f["correlates_with"].split("; ")]
            out.append("- Correlates with:")
            out += [f"  - {n}" for n in notes]
        if f["lines"]:
            shown = ", ".join(str(n) for n in f["lines"][:16])
            out.append(f"- Lines: {shown}{' ...' if len(f['lines']) > 16 else ''}")
        out.append("")
    return out


def md_problems(items, empty):
    if not items:
        return [empty]
    out = []
    for p in items[:60]:
        where = f" (line{'s' if p['count'] > 1 else ''} {', '.join(str(n) for n in p['lines'])}{' ...' if p['count'] > len(p['lines']) else ''})" if p["lines"] else ""
        count = f" x{p['count']}" if p["count"] > 1 else ""
        out.append(f"- {p['message']}{count}{where}")
    if len(items) > 60:
        out.append(f"- and {len(items) - 60} more kinds (see input-analysis.json)")
    return out


def render_markdown(a):
    r = a["report"]
    out = ["# Input diagnostics analysis", ""]
    status = "valid" if a["valid"] else "INVALID"
    out.append(f"Report `{r.get('source')}`: {status}, {len(a['errors'])} kind(s) of error, {len(a['warnings'])} kind(s) of warning.")
    if not a["valid"]:
        out.append("The findings below come from the lines that could be read; fix the errors before trusting them.")
    out.append("")
    if "platform" in r:
        summary = r.get("summary") or {}
        hints = r.get("hints") if isinstance(r.get("hints"), dict) else {}
        window = r.get("window") if isinstance(r.get("window"), list) else []
        out += ["## Environment", "", "| Field | Value |", "|---|---|"]
        rows = [("Platform", r.get("platform")), ("OS", r.get("os") or "unknown"), ("Device", r.get("device") or "unknown"),
                ("App", f"{r.get('app')} {r.get('version')} ({r.get('build')} build)"), ("Session", r.get("session")),
                ("Started", r.get("started")), ("Ended", summary.get("ended")),
                ("Duration", f"{summary['duration_s']:.1f} s" if is_num(summary.get("duration_s")) else None),
                ("Lines", summary.get("lines")), ("Truncated", r.get("truncated_at_line") is not None),
                ("Window", " x ".join(cell(v) for v in window) + f" points, scale {cell(r.get('scale'))}" if window else None),
                ("Hints", ", ".join(f"{k}={v}" for k, v in hints.items()) or "none")]
        out += [f"| {k} | {cell(v)} |" for k, v in rows]
        out.append("")
    run_count = sum(len(t["runs"]) for t in a["tests"])
    out += ["## Overview", "",
            f"{sum(1 for t in a['tests'] if t['runs'])} test(s) run in {run_count} run(s), {len(a['not_tested'])} not run: "
            f"**{len(a['confirmed_failures'])} confirmed failure(s)**, {len(a['suspicious_patterns'])} suspicious pattern(s), "
            f"{len(a['needs_manual_interpretation'])} needing manual interpretation.", ""]
    if a["tests"]:
        out += md_tests(a)
    out += [f"## Confirmed failures ({len(a['confirmed_failures'])})", ""]
    out += md_findings(a["confirmed_failures"], "None: no automatic fail was borne out by its run's lines and nobody judged a test failed.")
    out += [f"## Suspicious patterns ({len(a['suspicious_patterns'])})", ""]
    out += md_findings(a["suspicious_patterns"], "None.")
    out += [f"## Needs manual interpretation ({len(a['needs_manual_interpretation'])})", ""]
    out += md_findings(a["needs_manual_interpretation"], "None.")
    if a["comparisons"]:
        out += ["## Baseline and after the Pencil", ""]
        for c in a["comparisons"]:
            out += [f"| Measure | {c['baseline']} | {c['after']} |", "|---|---|---|"]
            for row in c["rows"]:
                value = lambda v: f"{v:.0%}" if row["measure"] == "response_rate" and is_num(v) else cell(v)
                out.append(f"| {row['measure'].replace('_', ' ')} | {value(row['baseline'])} | {value(row['after'])} |")
            out.append("")
    out += ["## Validation", "", f"### Errors ({len(a['errors'])})", ""]
    out += md_problems(a["errors"], "None.")
    out += ["", f"### Warnings ({len(a['warnings'])})", ""]
    out += md_problems(a["warnings"], "None.")
    out += ["", "## Not tested", ""]
    out += md_not_tested(a)
    out += ["", "---", "", f"*{NO_ROOT_CAUSE_NOTE}*", ""]
    return "\n".join(out)


def md_tests(a):
    counts = {}
    for name in ("confirmed_failures", "suspicious_patterns", "needs_manual_interpretation"):
        for f in a[name]:
            if f["test"]:
                counts.setdefault(f["test"], [0, 0, 0])[("confirmed_failures", "suspicious_patterns", "needs_manual_interpretation").index(name)] += 1
    out = ["## Tests", "", "| Test | Runs | Auto | Manual | Downs (finger / Pencil) | Probe presses (finger / Pencil) | Palms | Findings (C / S / N) |",
           "|---|---|---|---|---|---|---|---|"]
    for t in a["tests"]:
        if not t["runs"]:
            out.append(f"| {t['id']} | 0{' (skipped)' if t['skipped'] else ''} | - | - | - | - | - | - |")
            continue
        autos = ", ".join(cell(r["auto"]) for r in t["runs"])
        manuals = ", ".join(cell(r["manual"]) for r in t["runs"])
        downs = " / ".join(str(sum(r["counted"].get("received", {}).get(k, 0) for r in t["runs"])) for k in ("finger_down", "pen_down"))
        presses = " / ".join(str(sum(r["counted"].get("presses_by", {}).get(k, 0) for r in t["runs"])) for k in ("finger", "pen"))
        palms = sum(r["counted"].get("palms", 0) for r in t["runs"])
        c = counts.get(t["id"], [0, 0, 0])
        out.append(f"| {t['id']} | {len(t['runs'])} | {autos} | {manuals} | {downs} | {presses} | {palms} | {c[0]} / {c[1]} / {c[2]} |")
    out.append("")
    return out


def md_not_tested(a):
    if not a["not_tested"]:
        out = ["Every test in the list ran at least once."]
    else:
        out = [f"- {t['test']} ({t['category'] or 'unknown category'}): needs {', '.join(t['needs']) or 'nothing listed'}"
               + (" (skipped)" if t["skipped"] else "") for t in a["not_tested"]]
        for need in ("ipad", "pencil", "pencil_pro"):
            names = [t["test"] for t in a["not_tested"] if need in t["needs"]]
            if names:
                out.append(f"- Not run among the tests needing {need}: {len(names)}")
    platform = a["report"].get("platform")
    if platform and platform != "iOS":
        out.append(f"- This report comes from {platform}, not an iPad: every test needing ipad ran away from the device it describes.")
    return out


# --- command line ---------------------------------------------------------------------------------------


def analyse_path(path):
    """Reads and analyses a report; returns the analysis dict (ReportError becomes an invalid analysis)."""
    try:
        files, source, notes = load_report(path)
    except ReportError as e:
        return refused(str(path), str(e))
    return Analyzer(files, source, notes).analyse()


def refused(source, message):
    analyzer = Analyzer({}, source)
    analyzer.errors.add(None, message)
    return analyzer.output()


def write_outputs(analysis, out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "input-analysis.json").write_text(json.dumps(analysis, indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    (out / "input-analysis.md").write_text(render_markdown(analysis), encoding="utf-8", newline="\n")
    return out


def exit_code(analysis, strict):
    if not analysis["valid"]:
        return 2
    return 3 if strict and analysis["confirmed_failures"] else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    p.add_argument("report", nargs="?", help="the report: a .zip, a folder or a diagnostic-events.jsonl")
    p.add_argument("--url", help="download the report from this https URL first")
    p.add_argument("--out", default=str(DEFAULT_OUT), help="where input-analysis.md and .json go (default build/input-report)")
    p.add_argument("--strict", action="store_true", help="exit 3 when a confirmed failure is found")
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 1
    if bool(args.report) == bool(args.url):
        print("FAIL input-report: give exactly one of REPORT or --url")
        return 1
    try:
        if args.url:
            try:
                path = download(args.url)
            except ReportError as e:
                analysis = refused(public_url(args.url), str(e))
                path = None
            else:
                print(f"downloaded {public_url(args.url)} to {path}")
                analysis = analyse_path(path)
                analysis["report"]["source"] = public_url(args.url)
        else:
            analysis = analyse_path(args.report)
    except UsageError as e:
        print(f"FAIL input-report: {e}")
        return 1
    out = write_outputs(analysis, args.out)
    code = exit_code(analysis, args.strict)
    head = "ok" if analysis["valid"] else "INVALID"
    print(f"{head} input-report: {len(analysis['confirmed_failures'])} confirmed failure(s), "
          f"{len(analysis['suspicious_patterns'])} suspicious pattern(s), {len(analysis['needs_manual_interpretation'])} needing manual "
          f"interpretation; {len(analysis['errors'])} error(s), {len(analysis['warnings'])} warning(s)")
    for e in analysis["errors"][:5]:
        lines = f" (line {e['lines'][0]})" if e["lines"] else ""
        print(f"error: {e['message']}{lines}")
    print(f"wrote {out / 'input-analysis.md'} and {out / 'input-analysis.json'}")
    return code


if __name__ == "__main__":
    sys.exit(main())
