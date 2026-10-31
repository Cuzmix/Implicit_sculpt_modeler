package main

import "core:testing"

import "../geom"
import "../sculpt"

// A command goes to a thread of its own only where nothing compares the scene within the
// frame, and while one runs only the commands that change no scene may run.
@(test)
long_jobs_go_async_only_where_allowed :: proc(t: ^testing.T) {
	app: App
	obj := new(Object)
	defer free(obj)
	obj.id = 1
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	defer sculpt.levels_destroy(&obj.levels)
	cmd := Scene_Command{kind = .Remesh, vertices = 1000}
	testing.expect(t, !long_job_async(&app, obj, cmd), "a scripted run went async")
	app.long_job.allowed = true
	testing.expect(t, !long_job_async(&app, obj, cmd), "a small object went async")
	big := cmd
	big.vertices = LONG_JOB_MIN_VERTICES
	testing.expect(t, long_job_async(&app, obj, big), "a small object remeshed to a large one stayed on the frame")
	app.long_job.forced = true
	testing.expect(t, long_job_async(&app, obj, cmd), "--async-jobs did not go async")
	adjusted := cmd
	adjusted.adjust = true
	testing.expect(t, !long_job_async(&app, obj, adjusted), "Adjust last went async")
	app.macro.recording = true
	testing.expect(t, !long_job_async(&app, obj, cmd), "a recorded command went async")
	app.macro.recording = false

	testing.expect(t, !long_job_holds(&app, .Remesh) && !long_job_busy(&app), "held with no job")
	app.long_job.on = true
	testing.expect(t, !long_job_async(&app, obj, cmd), "a second job started")
	testing.expect(t, long_job_holds(&app, .Remesh) && long_job_holds(&app, .Undo) && long_job_holds(&app, .Save_Scene), "an edit ran beside the job")
	testing.expect(t, !long_job_holds(&app, .Frame_All) && !long_job_holds(&app, .View_Axis) && !long_job_holds(&app, .Settings), "a view command waited")
	testing.expect(t, history_busy(&app) && !script_can_start(&app), "undo or a script could run beside the job")
	testing.expect(t, !command_enabled(&app, .Remesh), "Remesh was enabled beside the job")
}
