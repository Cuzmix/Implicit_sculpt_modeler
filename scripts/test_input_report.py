#!/usr/bin/env python3
"""Tests for input_report.py over the samples in scripts/input_report_samples: python scripts/test_input_report.py

Each sample is analysed as its folder and as a ZIP built here with stored entries, the way the app exports it,
so both ways in must reach the same findings.
"""

import contextlib
import io
import json
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path

import input_report

SAMPLES = Path(__file__).resolve().parent / "input_report_samples"
LISTS = ("confirmed_failures", "suspicious_patterns", "needs_manual_interpretation")
# The reported iPad bugs the ipad_bugs sample carries, as the tests whose runs must be confirmed failures.
BUG_CONFIRMED = {
    "finger_after_pencil", "finger_pencil_switch", "hover_slider", "slider_ratio_pencil", "text_dismiss_reopen",
    "home_swipe_after_pencil", "roll_right", "roll_left",
}


def run_cli(*args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = input_report.main([str(a) for a in args])
    return code, out.getvalue()


def zip_folder(folder, target, extra=()):
    """Writes the sample's files at the archive's root, stored, plus any (name, bytes) extras."""
    with zipfile.ZipFile(target, "w", zipfile.ZIP_STORED) as archive:
        for f in sorted(folder.iterdir()):
            archive.write(f, f.name)
        for name, data in extra:
            archive.writestr(name, data)
    return target


def typing_report(folder, typed, auto):
    """A one-test report of text_typing in the app's own shape: each key and its text event, then the field's
    text line carrying the field's whole text after the change; typed holds characters and "\\b" for Backspace."""
    session = {"kind": "session", "schema": 1, "session": "t", "app": "Sculpt", "version": "dev", "build": "debug",
               "platform": "Windows", "os": "", "device": "", "started": "2026-10-29T15:53:42Z", "window": [1600, 900],
               "scale": 1, "hints": {}, "diagnostics": True}
    lines, seq, t = [session], 0, 0.0

    def add(kind, **fields):
        nonlocal seq, t
        seq, t = seq + 1, round(t + 0.017, 3)
        lines.append({"t": t, "seq": seq, "kind": kind, "step": "text_typing", "run": 1, **fields})

    add("step", action="start", test="text_typing", category="text", device="keyboard")
    add("event", src="finger", type="down", id=1, x=1365.0, y=450.0)
    add("control", control="field", action="press", by="finger", contact=True)
    add("event", src="finger", type="up", id=1, x=1365.0, y=450.0)
    add("control", control="field", action="focus", by="finger", contact=False)
    text = ""
    for ch in typed:
        add("event", src="key", type="key_down", id=0, key="Backspace" if ch == "\b" else "printable")
        if ch != "\b":
            add("event", src="text", type="text", id=0, len=1, text=ch)
        text = text[:-1] if ch == "\b" else text + ch
        add("control", control="field", action="text", by="finger", contact=False, len=len(text), text=text)
    add("step", action="end", test="text_typing", category="text", device="keyboard")
    received = dict.fromkeys(input_report.RECEIVED_KEYS, 0)
    received.update(finger_down=1, finger_up=1, key_down=len(typed), text=sum(1 for ch in typed if ch != "\b"))
    responded = dict.fromkeys(input_report.RESPONDED_KEYS, 0)
    responded.update(press=1, focus=1, text=len(typed))
    add("result", test="text_typing", auto=auto, auto_reason=f"the field holds {text!r}", manual=None, notes="",
        metrics={"received": received, "responded": responded, "palms": 0, "field": text})
    folder.mkdir(parents=True)
    events = "".join(json.dumps(line) + "\n" for line in lines)
    (folder / input_report.EVENTS).write_text(events, encoding="utf-8", newline="\n")
    return folder


def findings(analysis, name):
    return analysis[name]


def by_test(items, test):
    return [f for f in items if f["test"] == test]


class InputReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.analyses = {}
        for sample in ("healthy", "ipad_bugs"):
            folder = SAMPLES / sample
            cls.analyses[(sample, "folder")] = input_report.analyse_path(folder)
            cls.analyses[(sample, "zip")] = input_report.analyse_path(zip_folder(folder, cls.tmp / f"{sample}.zip"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, True)

    def each(self, sample):
        for way in ("folder", "zip"):
            with self.subTest(way=way):
                yield self.analyses[(sample, way)]

    def test_healthy_is_valid_and_quiet(self):
        for a in self.each("healthy"):
            self.assertTrue(a["valid"], a["errors"])
            self.assertEqual(a["errors"], [])
            self.assertEqual(a["confirmed_failures"], [])
            self.assertEqual(a["suspicious_patterns"], [], "a healthy log should raise no heuristic")
            self.assertEqual(a["needs_manual_interpretation"], [])
            self.assertEqual(a["not_tested"], [])
            self.assertEqual(len(a["tests"]), 26)

    def test_ipad_bugs_confirmed_failures(self):
        for a in self.each("ipad_bugs"):
            self.assertTrue(a["valid"], a["errors"])
            confirmed = findings(a, "confirmed_failures")
            self.assertEqual({f["test"] for f in confirmed}, BUG_CONFIRMED)
            palm = by_test(confirmed, "finger_after_pencil")[0]
            self.assertEqual(palm["kind"], "auto_fail")
            self.assertIn("palm=true for 3 and pen_near=true for 3 of 3", " ".join(palm["evidence"]))
            hover = by_test(confirmed, "hover_slider")[0]
            self.assertIn("with no contact", hover["title"])
            roll = by_test(confirmed, "roll_right")[0]
            self.assertIn("went down", roll["title"])
            self.assertIn("roll_wrong_direction", roll["correlates_with"])
            swipe = by_test(confirmed, "home_swipe_after_pencil")[0]
            self.assertEqual(swipe["kind"], "manual_fail")
            self.assertIn("two swipes", swipe["title"])

    def test_ipad_bugs_suspicious_patterns(self):
        for a in self.each("ipad_bugs"):
            suspicious = findings(a, "suspicious_patterns")
            kinds = {(f["test"], f["kind"]) for f in suspicious}
            self.assertIn((None, "pen_near_never_far"), kinds)
            self.assertIn(("slider_ratio_pencil", "ratio_differs"), kinds)
            self.assertIn(("finger_drag", "down_without_up"), kinds)
            near = [f for f in suspicious if f["kind"] == "pen_near_never_far"][0]
            self.assertIn("UIKit", near["correlates_with"], "on iOS the driver's known gap is given as context")
            self.assertIn("not a conclusion", near["correlates_with"])
            ratio = [f for f in suspicious if f["kind"] == "ratio_differs"][0]
            self.assertIn("40%", ratio["title"])

    def test_ipad_bugs_pressure_needs_manual_interpretation(self):
        for a in self.each("ipad_bugs"):
            pressure = by_test(findings(a, "needs_manual_interpretation"), "pressure_ramp")
            self.assertEqual(len(pressure), 1)
            self.assertEqual(pressure[0]["kind"], "pressure_unavailable")
            self.assertIn("unavailable", pressure[0]["title"])
            self.assertIn("not read as zero", pressure[0]["title"])
            for name in ("confirmed_failures", "suspicious_patterns"):
                self.assertEqual(by_test(findings(a, name), "pressure_ramp"), [])

    def test_unknown_values_are_warnings(self):
        for a in self.each("ipad_bugs"):
            self.assertEqual(a["errors"], [])
            self.assertTrue(any("hover_roll" in w["message"] for w in a["warnings"]), a["warnings"])

    def test_lists_never_share_a_finding(self):
        for sample in ("healthy", "ipad_bugs"):
            for a in self.each(sample):
                seen = {}
                for name in LISTS:
                    for f in a[name]:
                        key = (f["test"], f["run"], f["kind"], f["title"])
                        self.assertNotIn(f["id"], seen, f"{f['id']} is in {seen.get(f['id'])} and {name}")
                        self.assertNotIn(key, seen.values(), f"{key} is in two lists")
                        seen[f["id"]] = key
                        self.assertTrue(f["id"].startswith(name[0].upper()), f["id"])

    def test_folder_and_zip_agree(self):
        for sample in ("healthy", "ipad_bugs"):
            a, b = self.analyses[(sample, "folder")], self.analyses[(sample, "zip")]
            for name in LISTS + ("comparisons", "not_tested", "tests"):
                self.assertEqual(a[name], b[name], f"{sample}: {name} differs between folder and zip")

    def test_markdown_ends_with_the_no_root_cause_note(self):
        for sample in ("healthy", "ipad_bugs"):
            md = input_report.render_markdown(self.analyses[(sample, "folder")])
            self.assertIn(input_report.NO_ROOT_CAUSE_NOTE, md)
            self.assertTrue(md.rstrip().endswith(input_report.NO_ROOT_CAUSE_NOTE + "*"))
            for heading in ("## Confirmed failures", "## Suspicious patterns", "## Needs manual interpretation",
                            "## Baseline and after the Pencil", "## Validation", "## Not tested", "## Environment"):
                self.assertIn(heading, md)

    def test_cli_writes_outputs_and_exit_codes(self):
        out = self.tmp / "cli"
        code, text = run_cli(SAMPLES / "ipad_bugs", "--out", out)
        self.assertEqual(code, 0, text)
        data = json.loads((out / "input-analysis.json").read_text(encoding="utf-8"))
        self.assertEqual(list(data), ["schema", "report", "valid", "errors", "warnings", "tests", *LISTS,
                                      "comparisons", "not_tested"])
        self.assertTrue((out / "input-analysis.md").is_file())
        self.assertEqual(run_cli(SAMPLES / "ipad_bugs", "--out", out, "--strict")[0], 3)
        self.assertEqual(run_cli(SAMPLES / "healthy", "--out", out, "--strict")[0], 0)
        self.assertEqual(run_cli("--out", out)[0], 1)
        self.assertEqual(run_cli(self.tmp / "missing", "--out", out)[0], 1)
        self.assertEqual(run_cli("--url", "http://example.com/report.zip", "--out", out)[0], 1)

    def test_events_file_reads_the_summary_beside_it(self):
        a = input_report.analyse_path(SAMPLES / "healthy" / input_report.EVENTS)
        self.assertTrue(a["valid"], a["errors"])
        self.assertIn(input_report.SUMMARY, a["report"]["files"])
        self.assertEqual(a["confirmed_failures"], [])

    def test_invalid_schema_exits_2(self):
        out = self.tmp / "invalid"
        code, text = run_cli(SAMPLES / "invalid_schema", "--out", out)
        self.assertEqual(code, 2, text)
        data = json.loads((out / "input-analysis.json").read_text(encoding="utf-8"))
        self.assertFalse(data["valid"])
        self.assertIn("schema", data["errors"][0]["message"])
        self.assertIn(input_report.NO_ROOT_CAUSE_NOTE, (out / "input-analysis.md").read_text(encoding="utf-8"))

    def test_missing_session_line_is_invalid(self):
        folder = self.tmp / "no_session"
        folder.mkdir()
        lines = (SAMPLES / "healthy" / input_report.EVENTS).read_text(encoding="utf-8").splitlines(True)
        (folder / input_report.EVENTS).write_text("".join(lines[1:]), encoding="utf-8", newline="\n")
        a = input_report.analyse_path(folder)
        self.assertFalse(a["valid"])
        self.assertIn("session line", a["errors"][0]["message"])

    def test_broken_order_is_an_error(self):
        folder = self.tmp / "reordered"
        folder.mkdir()
        lines = (SAMPLES / "healthy" / input_report.EVENTS).read_text(encoding="utf-8").splitlines(True)
        lines[10], lines[11] = lines[11], lines[10]
        (folder / input_report.EVENTS).write_text("".join(lines), encoding="utf-8", newline="\n")
        a = input_report.analyse_path(folder)
        self.assertFalse(a["valid"])
        self.assertTrue(any("seq is not strictly increasing" in e["message"] for e in a["errors"]), a["errors"])

    def test_zip_entry_climbing_out_is_refused(self):
        bad = zip_folder(SAMPLES / "healthy", self.tmp / "climb.zip", extra=[("../x", b"planted")])
        a = input_report.analyse_path(bad)
        self.assertFalse(a["valid"])
        self.assertIn("refused", a["errors"][0]["message"])
        self.assertIn("'../x'", a["errors"][0]["message"])
        self.assertFalse((self.tmp.parent / "x").exists())
        absolute = zip_folder(SAMPLES / "healthy", self.tmp / "absolute.zip", extra=[("/etc/x", b"planted")])
        self.assertFalse(input_report.analyse_path(absolute)["valid"])
        code, _ = run_cli(bad, "--out", self.tmp / "climb")
        self.assertEqual(code, 2)

    def test_typed_text_left_wrong_is_a_confirmed_failure(self):
        a = input_report.analyse_path(typing_report(self.tmp / "typing_fail", "sc\b", "fail"))
        self.assertTrue(a["valid"], a["errors"])
        confirmed = by_test(a["confirmed_failures"], "text_typing")
        self.assertEqual(len(confirmed), 1, a["needs_manual_interpretation"])
        self.assertEqual(confirmed[0]["kind"], "auto_fail")
        self.assertIn("'s', not 'scul'", confirmed[0]["title"])
        self.assertIn("2 printable key(s), 1 Backspace(s)", " ".join(confirmed[0]["evidence"]))
        self.assertEqual(by_test(a["needs_manual_interpretation"], "text_typing"), [])

    def test_typed_text_left_right_raises_nothing(self):
        a = input_report.analyse_path(typing_report(self.tmp / "typing_pass", "sculpt\b\b", "pass"))
        self.assertTrue(a["valid"], a["errors"])
        for name in LISTS:
            self.assertEqual(by_test(a[name], "text_typing"), [], name)

    def test_zip_entries_are_read_by_base_name(self):
        nested = self.tmp / "nested.zip"
        with zipfile.ZipFile(nested, "w", zipfile.ZIP_STORED) as archive:
            for f in sorted((SAMPLES / "healthy").iterdir()):
                archive.write(f, f"report/{f.name}")
        a = input_report.analyse_path(nested)
        self.assertTrue(a["valid"], a["errors"])
        self.assertEqual(a["tests"], self.analyses[("healthy", "folder")]["tests"])


if __name__ == "__main__":
    unittest.main()
