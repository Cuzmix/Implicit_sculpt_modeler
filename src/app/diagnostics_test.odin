package main

import "core:encoding/json"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

import "../zip"

// An App with the diagnostics screen open and its session started, on the heap: an App is
// too big for a test thread's stack many times over.
@(private = "file")
diag_test_app :: proc() -> ^App {
	app := new(App)
	app.diag.allowed = true
	diag_open(app)
	return app
}

@(private = "file")
diag_test_free :: proc(app: ^App) {
	diag_destroy(app)
	free(app)
}

// A JSON string escapes what JSON must and turns bytes that are not UTF-8 into U+FFFD, so a
// note typed on any keyboard never breaks a line of the log.
@(test)
json_quote_escapes_and_replaces :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	json_quote(&b, "a\"b\\c\nd\x01e\xff")
	testing.expect_value(t, strings.to_string(b), "\"a\\\"b\\\\c\\nd\\u0001e�\"")
	buf: [6]u8
	diag_put_text(buf[:], "abéé")
	testing.expect_value(t, diag_text(buf[:]), "abé")
	free_all(context.temp_allocator)
}

// However long a session runs, the log stays within its cap and its reserve, says once that
// it was cut, and still takes the lines that say what the tests found.
@(test)
diag_log_stays_within_its_cap :: proc(t: ^testing.T) {
	app := diag_test_app()
	defer diag_test_free(app)
	d := &app.diag
	diag_run_start(app, .Text_Typing)
	e: sdl.Event
	for i in 0 ..< 60_000 {
		e.key = {type = .KEY_DOWN, timestamp = u64(i + 1) * 1_000_000, key = sdl.K_TAB}
		diag_event(app, &e)
		if i % 1000 == 0 do free_all(context.temp_allocator)
	}
	testing.expect(t, d.truncated, "the log was never cut")
	testing.expect(t, d.dropped > 0, "nothing was dropped")
	testing.expect(t, len(d.log) <= DIAG_LOG_CAP + DIAG_LOG_RESERVE, "the log passed its cap and reserve")
	testing.expect_value(t, d.counts[.Key_Down], 60_000)
	diag_run_end(app, .End)
	log := string(d.log[:])
	testing.expect(t, strings.contains(log, `"kind":"truncated"`), "no truncated line")
	testing.expect(t, strings.contains(log, `"kind":"result"`), "the run's result did not get in after the cap")
	testing.expect_value(t, strings.count(log, `"code":"log_truncated"`), 1)
	free_all(context.temp_allocator)
}

// Text is logged only from the diagnostic field: what arrives anywhere else is counted by its
// length alone, and noted as text with no field to take it.
@(test)
diag_text_is_logged_only_from_its_field :: proc(t: ^testing.T) {
	app := diag_test_app()
	defer diag_test_free(app)
	d := &app.diag
	e: sdl.Event
	e.text = {type = .TEXT_INPUT, timestamp = 1, text = "secret"}
	diag_event(app, &e)
	d.field_id = 7
	app.kit.ctx.text_focus = 7
	e.text = {type = .TEXT_INPUT, timestamp = 2, text = "scul"}
	diag_event(app, &e)
	log := string(d.log[:])
	testing.expect(t, !strings.contains(log, "secret"), "text from outside the field was logged")
	testing.expect(t, strings.contains(log, `"len":6`), "its length was not")
	testing.expect(t, strings.contains(log, `"text":"scul"`), "the field's own text was not logged")
	testing.expect(t, strings.contains(log, `"code":"text_without_focus"`), "text with no field was not noted")
	free_all(context.temp_allocator)
}

// The verdicts come from the run's own counts: the direction a roll moved the slider, the
// pressure reported or not, the taps answered, the size slider's ratio, a hover that moved.
@(test)
diag_verdicts_read_the_runs_counts :: proc(t: ^testing.T) {
	judge :: proc(r: Diag_Run) -> Diag_Verdict {
		r := r
		v, _ := diag_judge(&r)
		return v
	}
	roll := Diag_Run{test = .Roll_Right}
	testing.expect_value(t, judge(roll), Diag_Verdict.Unavailable)
	roll.m.rotation_reports, roll.m.roll_value = 5, 10
	testing.expect_value(t, judge(roll), Diag_Verdict.Pass)
	roll.m.roll_value = -10
	testing.expect_value(t, judge(roll), Diag_Verdict.Fail)
	roll.test = .Roll_Left
	testing.expect_value(t, judge(roll), Diag_Verdict.Pass)

	pressure := Diag_Run{test = .Pressure_Ramp}
	pressure.received[.Pen_Down] = 3
	testing.expect_value(t, judge(pressure), Diag_Verdict.Unavailable)
	pressure.m.pressure_samples, pressure.m.pressure_min, pressure.m.pressure_max = 20, 0.1, 0.9
	testing.expect_value(t, judge(pressure), Diag_Verdict.Pass)

	taps := Diag_Run{test = .Finger_Tap, palms = 2}
	taps.on_probe[.Finger_Down] = 3
	taps.by[.Finger] = 1
	testing.expect_value(t, judge(taps), Diag_Verdict.Fail)
	taps.by[.Finger], taps.palms = 3, 0
	testing.expect_value(t, judge(taps), Diag_Verdict.Pass)

	ratio := Diag_Run{test = .Slider_Ratio_Finger}
	ratio.m.drag_by, ratio.m.drag_travel, ratio.m.drag_value = .Finger, 100, 100 * DIAG_RANGE / DIAG_VTRACK
	testing.expect_value(t, judge(ratio), Diag_Verdict.Pass)
	ratio.m.drag_value = 40
	testing.expect_value(t, judge(ratio), Diag_Verdict.Fail)
	ratio.m.drag_by = .Pen
	testing.expect_value(t, judge(ratio), Diag_Verdict.Inconclusive)

	hover := Diag_Run{test = .Hover_Slider}
	hover.m.hover_frames = DIAG_HOVER_FRAMES
	testing.expect_value(t, judge(hover), Diag_Verdict.Pass)
	hover.m.hover_changed = 1.5
	testing.expect_value(t, judge(hover), Diag_Verdict.Fail)

	swipe := Diag_Run{test = .Home_Swipe_Baseline}
	swipe.received[.Background] = 1
	testing.expect_value(t, judge(swipe), Diag_Verdict.Inconclusive)
	free_all(context.temp_allocator)
}

// The report is one ZIP of its three files: every line of the log is JSON starting with the
// session, and the summary lists every test with its runs.
@(test)
diag_report_unpacks_with_three_files :: proc(t: ^testing.T) {
	app := diag_test_app()
	defer diag_test_free(app)
	diag_run_start(app, .Finger_Tap)
	diag_run_end(app, .Skip)
	archive, ok := diag_archive(app)
	testing.expect(t, ok, "the archive was not made")
	list, err := zip.entries(archive, {entries = 8, total = 64 << 20}, context.temp_allocator)
	testing.expect_value(t, err, zip.Error.None)
	names := [3]string{"diagnostic-report.md", "diagnostic-events.jsonl", "diagnostic-summary.json"}
	testing.expect_value(t, len(list), 3)
	for e, i in list do if i < 3 do testing.expect_value(t, e.name, names[i])
	if len(list) < 3 do return
	events, _ := zip.read(archive, list[1], context.temp_allocator)
	for line, i in strings.split_lines(strings.trim_space(string(events)), context.temp_allocator) {
		v, perr := json.parse_string(line, .JSON, allocator = context.temp_allocator)
		testing.expectf(t, perr == nil, "line %d is not JSON: %v", i + 1, perr)
		if i == 0 do testing.expect_value(t, v.(json.Object)["kind"].(json.String), "session")
	}
	summary, _ := zip.read(archive, list[2], context.temp_allocator)
	v, perr := json.parse(summary, .JSON, allocator = context.temp_allocator)
	testing.expect_value(t, perr, json.Error.None)
	tests := v.(json.Object)["tests"].(json.Array)
	testing.expect_value(t, len(tests), len(Diag_Test_Id))
	runs := tests[0].(json.Object)["runs"].(json.Array)
	testing.expect_value(t, len(runs), 1)
	if len(runs) == 1 do testing.expect_value(t, runs[0].(json.Object)["manual"].(json.String), "skip")
	free_all(context.temp_allocator)
}

// Every test has a stable id the report names it by, steps, an expected result and the
// needs that say what only a device has.
@(test)
diag_tests_are_complete :: proc(t: ^testing.T) {
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for test, id in DIAG_TESTS {
		testing.expectf(t, test.key != "" && test.key not_in seen, "%v has no id of its own", id)
		seen[test.key] = true
		back, ok := diag_test_named(test.key)
		testing.expect(t, ok && back == id, "an id does not name its test")
		testing.expectf(t, test.steps != "" && test.expected != "" && test.needs != "" && test.device != "", "%v is missing text", id)
		testing.expectf(t, strings.contains(test.needs, "ipad"), "%v does not say it needs the iPad", id)
	}
	free_all(context.temp_allocator)
}
