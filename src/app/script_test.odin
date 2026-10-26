package main

import "core:fmt"
import "core:strings"
import "core:testing"

import "../camera"
import "../geom"
import "../sculpt"

// Every kind of statement, with comments, quotes, `;` and blank lines between them, reads
// as what it says, on the line it is on.
@(test)
script_reads_every_kind :: proc(t: ^testing.T) {
	text := `# Set up a scene.
brush clay; wireframe on

set orbit_style turntable   # a comment after a statement
set rebuild-even 500000
set material "red wax"
set symmetry xz; set paint_color 0.2 0.4 0.9
view_axis Front
wait 3; select 2
Remesh_To 500000
undo`
	s := script_parse(text, "test")
	defer script_destroy(&s)
	testing.expect_value(t, len(s.errors), 0)
	testing.expect_value(t, script_report(&s), "")
	if !testing.expect_value(t, len(s.statements), 12) do return
	st := s.statements
	testing.expect_value(t, st[0].kind, Script_Kind.Command)
	testing.expect_value(t, st[0].command, Command_Id.Brush)
	testing.expect_value(t, sculpt.Brush_Kind(st[0].arg), sculpt.Brush_Kind.Clay)
	testing.expect_value(t, st[0].line, 2)
	testing.expect_value(t, st[1].command, Command_Id.Wireframe)
	testing.expect_value(t, st[1].toggle, Script_Toggle.On)
	testing.expect_value(t, st[1].line, 2)
	testing.expect_value(t, st[2].kind, Script_Kind.Set)
	testing.expect_value(t, st[2].setting.key, "orbit_style")
	testing.expect_value(t, camera.Orbit_Style(int(st[2].value)), camera.Orbit_Style.Turntable)
	testing.expect_value(t, st[2].line, 4)
	testing.expect_value(t, st[3].setting.key, "rebuild_even")
	testing.expect_value(t, st[3].value, 500000)
	testing.expect_value(t, st[4].kind, Script_Kind.Line)
	testing.expect_value(t, st[4].set.key, "material")
	testing.expect_value(t, st[5].line_value.(sculpt.Symmetry), sculpt.Symmetry{.X, .Z})
	testing.expect_value(t, st[6].line_value.([3]f32), [3]f32{0.2, 0.4, 0.9})
	testing.expect_value(t, st[6].line, 7)
	testing.expect_value(t, camera.Axis_View(st[7].arg), camera.Axis_View.Front)
	testing.expect_value(t, st[8].kind, Script_Kind.Wait)
	testing.expect_value(t, st[8].count, 3)
	testing.expect_value(t, st[9].kind, Script_Kind.Select)
	testing.expect_value(t, st[9].count, 2)
	testing.expect_value(t, st[10].command, Command_Id.Remesh_To)
	testing.expect_value(t, SPHERE_PRESETS[st[10].arg].vertices, 500000)
	testing.expect_value(t, st[11].command, Command_Id.Undo)
	testing.expect_value(t, st[11].toggle, Script_Toggle.Flip)
	testing.expect_value(t, st[11].line, 11)
}

// Each kind of mistake is an error naming its line, and a script with any error has
// them all listed; `;` and `#` inside quotes are part of the quoted word.
@(test)
script_errors_name_their_lines :: proc(t: ^testing.T) {
	text := `sculpt_everything
brush 2
brush mud
undo now
wireframe maybe
set
set no_such_thing 1
set orbit_speed 9
set smooth_steps 2.5
set wireframe sometimes
set material "a;b#c"
wait 0
select x
set material "red wax
set symmetry xq`
	s := script_parse(text, "bad.cmd")
	defer script_destroy(&s)
	if !testing.expect_value(t, len(s.errors), 15) do return
	for e, i in s.errors do testing.expect_value(t, e.line, i + 1)
	testing.expect(t, strings.contains(s.errors[0].message, `"sculpt_everything"`))
	// Choices are by name only: a number would mean two things for Pie and the sets.
	testing.expect(t, strings.contains(s.errors[1].message, "clay"))
	testing.expect(t, strings.contains(s.errors[3].message, "takes nothing"))
	testing.expect(t, strings.contains(s.errors[4].message, "on or off"))
	testing.expect(t, strings.contains(s.errors[7].message, "from 0.25 to 4"))
	testing.expect(t, strings.contains(s.errors[8].message, "whole number"))
	testing.expect(t, strings.contains(s.errors[10].message, `"a;b#c"`))
	testing.expect(t, strings.contains(s.errors[13].message, "quote"))
	testing.expect(t, strings.has_prefix(script_report(&s), "script: bad.cmd:1: no command is named"))
	testing.expect_value(t, len(s.statements), 0)
}

// A script that is not one at all lists twenty errors and counts the rest.
@(test)
script_errors_stop_at_twenty :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 25 do strings.write_string(&b, "nonsense\n")
	s := script_parse(strings.to_string(b), "x")
	defer script_destroy(&s)
	testing.expect_value(t, len(s.errors), SCRIPT_ERRORS_MAX)
	testing.expect_value(t, s.more, 5)
	testing.expect(t, strings.contains(script_report(&s), "script: x: 5 more errors"))
}

// One spelling names one thing: no two commands, and no command and a statement word,
// are the same name once written as scripts write them; each choice is one word and no
// two of a command's are alike; a setting's key is the name a script writes.
@(test)
script_names_are_unique :: proc(t: ^testing.T) {
	seen := make(map[string]Command_Id, allocator = context.temp_allocator)
	for id in Command_Id {
		if id == .None do continue
		name := script_name(fmt.tprint(id))
		testing.expectf(t, name not_in seen, "%v and %v are both %q", id, seen[name], name)
		testing.expectf(t, name != "set" && name != "wait" && name != "select", "%v is a statement word", id)
		seen[name] = id
		testing.expect_value(t, script_command(name), id)
		choices := make(map[string]bool, allocator = context.temp_allocator)
		for a in 0 ..< COMMANDS[id].args {
			choice := script_name(command_arg_name(id, a))
			testing.expectf(t, !strings.contains_any(choice, " \t;#\""), "%v's choice %q is not one word", id, choice)
			testing.expectf(t, choice not_in choices, "%v has two choices %q", id, choice)
			choices[choice] = true
		}
	}
	// A verb is no command and no setting, so neither shadows the other.
	for v in Script_Verb {
		name := SCRIPT_VERBS[v].name
		testing.expect_value(t, script_name(name), name)
		testing.expectf(t, name not_in seen, "%v is also the command %v", v, seen[name])
		_, is_row := script_setting(name)
		testing.expectf(t, !is_row && setting_line(name).parse == nil, "%v is also a setting", v)
	}
	for s in SETTINGS do testing.expect_value(t, script_name(s.key), s.key)
	for s in SCRIPT_VALUES do testing.expect_value(t, script_name(s.key), s.key)
	for line in SETTING_LINES {
		_, is_row := script_setting(line.key)
		testing.expectf(t, !is_row, "%s is a row and a line", line.key)
	}
}

// Each verb reads what it takes, and says what that is when it is given something else.
@(test)
script_reads_the_verbs :: proc(t: ^testing.T) {
	text := `move 0.9 0 -1.5
rotate 0 45 370
boolean subtract
slice z
hide -y
mask_rect 0 0 1 0.335
project 1
draw_curve stitches
insert_middle torus
falloff Firm
alpha "my alphas/rock 2.png"`
	s := script_parse(text, "x")
	defer script_destroy(&s)
	testing.expect_value(t, script_report(&s), "")
	if !testing.expect_value(t, len(s.statements), 11) do return
	st := s.statements
	for v, i in Script_Verb {
		testing.expect_value(t, st[i].kind, Script_Kind.Verb)
		testing.expect_value(t, st[i].verb, v)
	}
	testing.expect_value(t, st[0].numbers.xyz, [3]f32{0.9, 0, -1.5})
	testing.expect_value(t, st[1].numbers.z, 370)
	testing.expect_value(t, Boolean_Mode(st[2].arg), Boolean_Mode.Subtract)
	testing.expect_value(t, st[3].arg, 2)
	testing.expect_value(t, st[4].arg, 1)
	testing.expect(t, st[4].flip)
	testing.expect_value(t, st[5].numbers, [4]f32{0, 0, 1, 0.335})
	testing.expect_value(t, st[6].count, 1)
	testing.expect_value(t, Curve_Kind(st[7].arg), Curve_Kind.Stitches)
	testing.expect_value(t, geom.Primitive(st[8].arg), geom.Primitive.Torus)
	testing.expect_value(t, string(FALLOFF_PRESETS[st[9].arg].label), "Firm")
	testing.expect_value(t, st[10].text, "my alphas/rock 2.png")

	bad := script_parse("move 1 2\nrotate 0 x 0\nboolean maybe\nslice w\nhide -\nmask_rect 0 0 0 1\nmask_rect 0 0 2 1\nproject 0\ndraw_curve\ninsert_middle blob\nfalloff soft\nalpha", "bad")
	defer script_destroy(&bad)
	if !testing.expect_value(t, len(bad.errors), 12) do return
	for e, i in bad.errors do testing.expect_value(t, e.line, i + 1)
	testing.expect(t, strings.contains(bad.errors[0].message, "move takes three numbers"))
	testing.expect(t, strings.contains(bad.errors[10].message, "smooth, linear, sharp, firm or flat"))
}

// What a script sets is what the settings file would have set, rows and lines alike,
// and the statements outlive the temp allocator, which the operations they run free.
@(test)
script_set_writes_the_fields :: proc(t: ^testing.T) {
	s := script_parse("set orbit_style turntable; set wireframe on; set smooth_steps 12; set hd_window 2000000; set cloth_mode gravity; set symmetry y; set paint_color 1 0 0.5; set material steel", "x")
	defer script_destroy(&s)
	testing.expect_value(t, len(s.errors), 0)
	free_all(context.temp_allocator)
	app: App
	for st in s.statements do script_set(&app, st)
	testing.expect_value(t, app.nav.orbit_style, camera.Orbit_Style.Turntable)
	testing.expect(t, app.wireframe)
	testing.expect_value(t, app.ui.smooth_steps, 12)
	testing.expect_value(t, app.hd_window_vertices, 2_000_000)
	testing.expect_value(t, app.brush.cloth_mode, sculpt.Cloth_Mode.Gravity)
	testing.expect_value(t, app.brush.symmetry, sculpt.Symmetry{.Y})
	testing.expect_value(t, app.brush.color, [3]f32{1, 0, 0.5})
	steel, _ := material_by_name("steel")
	testing.expect_value(t, app.material, steel)
}

// A start-up script is set-up: once it is done nothing it did is in the History, the
// scene counts as unchanged where it was unchanged before it, the stats start afresh,
// and the scripted events count from the frame it ended on.
@(test)
script_finishes_as_set_up :: proc(t: ^testing.T) {
	app: App
	defer {
		for obj in app.scene.objects {
			sculpt.levels_destroy(&obj.levels)
			free(obj)
		}
		delete(app.scene.objects)
		delete(app.scene.also)
		history_destroy(&app.history)
		results_destroy(&app)
		script_unload(&app)
	}
	obj := new(Object)
	obj.id = 1
	obj.transform = {scale = 1}
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	app.autosave.clean = scene_fingerprint(&app)
	app.stats.dabs_total = 7
	testing.expect(t, script_load(&app, "", "set wireframe on; mask invert; wait 2; select 1", scripted = true))
	// Nothing runs until the viewport has its size.
	testing.expect(t, script_frame(&app))
	testing.expect(t, !app.wireframe)
	app.ui.viewport_size = {800, 600}
	frame :: proc(app: ^App) {
		_ = script_frame(app)
		if app.script.running do app.script.frames += 1
	}
	app.script.frames = 1
	frame(&app)
	testing.expect(t, app.wireframe)
	testing.expect_value(t, len(app.history.done), 1)
	testing.expect(t, app.script.running)
	frame(&app)
	frame(&app)
	testing.expect(t, !app.script.running)
	testing.expect(t, !app.script.failed)
	testing.expect_value(t, app.script.next, 4)
	testing.expect_value(t, len(app.history.done), 0)
	testing.expect_value(t, app.autosave.clean, scene_fingerprint(&app))
	testing.expect_value(t, app.stats.dabs_total, 0)
	testing.expect_value(t, app.kit.events_offset, 3)
}

// A statement that does nothing stops the script there, and says which.
@(test)
script_stops_at_what_does_nothing :: proc(t: ^testing.T) {
	app: App
	defer script_unload(&app)
	defer results_destroy(&app)
	testing.expect(t, script_load(&app, "", "set flat on\nselect 2\nset wireframe on", scripted = false))
	app.ui.viewport_size = {800, 600}
	testing.expect(t, script_frame(&app))
	testing.expect(t, app.flat)
	testing.expect(t, app.script.failed)
	testing.expect(t, !app.wireframe)
	testing.expect(t, strings.contains(app.result.text, "line 2"))
	testing.expect(t, .Warning in app.result.flags)
}
