#+build js, wasi, orca
package thread

// The web version runs on one thread (README "Web"), so here, in place of Odin's own js
// stand-ins that stop the program, a thread runs its procedure to the end when it starts,
// on the caller's thread, and is done at once. That suits work handed off whole (a long
// job, a decode); the app keeps a thread that waits for more work from starting at all
// on the web.

import "base:intrinsics"
import "base:runtime"

_IS_SUPPORTED :: false

Thread_Os_Specific :: struct {}

_thread_priority_map := [Thread_Priority]i32{
	.Normal = 0,
	.Low = -2,
	.High = +2,
}

_create :: proc(procedure: Thread_Proc, priority := Thread_Priority.Normal, name: Maybe(string) = nil) -> ^Thread {
	t := new(Thread)
	if t == nil do return nil
	t.procedure = procedure
	t.creation_allocator = context.allocator
	t.name = name
	return t
}

_start :: proc(t: ^Thread) {
	if .Started in t.flags do return
	t.flags += {.Started}
	// Its own temp memory, as a thread has: the caller's may hold what its frame still uses.
	temp: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&temp, 0, context.allocator)
	defer runtime.default_temp_allocator_destroy(&temp)
	{
		context = _select_context_for_thread(t.init_context)
		context.temp_allocator = runtime.default_temp_allocator(&temp)
		t.procedure(t)
	}
	t.flags += {.Done}
	if .Self_Cleanup in t.flags do free(t, t.creation_allocator)
}

_is_done :: proc(t: ^Thread) -> bool {
	return .Done in t.flags
}

_join :: proc(t: ^Thread) {
	t.flags += {.Joined}
}

_join_multiple :: proc(threads: ..^Thread) {
	for t in threads do _join(t)
}

_destroy :: proc(thread: ^Thread) {
	free(thread, thread.creation_allocator)
}

_terminate :: proc(thread : ^Thread, exit_code: int) {
}

_yield :: proc() {
}

_get_name :: proc(thread: ^Thread, allocator : runtime.Allocator, loc : runtime.Source_Code_Location) -> (string, runtime.Allocator_Error) {
	name, _ := thread.name.?
	bytes, err := runtime.make_slice([]u8, len(name), allocator, loc)
	copy(bytes, name)
	return string(bytes), err
}

_set_name :: proc(thread: ^Thread, name:string) {
}
