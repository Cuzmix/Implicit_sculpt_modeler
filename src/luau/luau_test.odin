package luau

// Used only where the library is linked (AVAILABLE).
@(require) import "core:c"
@(require) import "core:c/libc"
@(require) import "core:testing"

// The binding against the library it names: the type tags in the order this tag of
// Luau has them, and a chunk compiled, run and failing as the app uses them.
// On builds without plugins the library is not linked, so neither are the tests.
when AVAILABLE {
	@(test)
	luau_type_names_match :: proc(t: ^testing.T) {
		L := luaL_newstate_for_test()
		defer lua_close(L)
		want := [?]struct {
			tp:   Type,
			name: cstring,
		}{{.Nil, "nil"}, {.Boolean, "boolean"}, {.Number, "number"}, {.Vector, "vector"}, {.String, "string"}, {.Table, "table"}, {.Function, "function"}, {.Userdata, "userdata"}, {.Thread, "thread"}, {.Buffer, "buffer"}}
		for w in want do testing.expectf(t, lua_typename(L, w.tp) == w.name, "type %v is %q in this Luau", w.tp, lua_typename(L, w.tp))
		testing.expect(t, GLOBALSINDEX == -10002)
	}

	@(test)
	luau_compiles_runs_and_raises :: proc(t: ^testing.T) {
		L := luaL_newstate_for_test()
		defer lua_close(L)
		luaL_openlibs(L)
		// An Odin function raising an error with the caller's place, as plugins' calls do.
		pushcfunction(L, proc "c" (L: ^State) -> c.int {raise(L, "refused")}, "refuse")
		setglobal(L, "refuse")
		luaL_sandbox(L)
		run :: proc(L: ^State, source: string) -> (status: c.int) {
			n: c.size_t
			code := luau_compile(raw_data(source), c.size_t(len(source)), nil, &n)
			defer libc.free(code)
			if luau_load(L, "=test", code, n, 0) != OK do return -1
			return lua_pcall(L, 0, 1, 0)
		}
		testing.expect(t, run(L, "local s = 0 for i = 1, 1000 do s += i end return s") == OK)
		testing.expect(t, lua_tonumberx(L, -1, nil) == 500500)
		drop(L, 1)

		testing.expect(t, run(L, "return (nil).x") == ERRRUN)
		message, _ := tostring(L, -1)
		testing.expectf(t, message == "test:1: attempt to index nil with 'x'", "the error is %q", message)
		drop(L, 1)

		testing.expect(t, run(L, "return 1 +") == -1)
		message, _ = tostring(L, -1)
		testing.expectf(t, message == "test:1: Expected identifier when parsing expression, got <eof>", "the error is %q", message)
		drop(L, 1)

		testing.expect(t, run(L, "\nrefuse()") == ERRRUN)
		message, _ = tostring(L, -1)
		testing.expectf(t, message == "test:2: refused", "the error is %q", message)
		testing.expect(t, lua_gettop(L) == 1)
	}

	// A state on libc's heap, as the app's plugins have, with no budget.
	@(private = "file")
	luaL_newstate_for_test :: proc() -> ^State {
		return lua_newstate(proc "c" (_: rawptr, ptr: rawptr, _, nsize: c.size_t) -> rawptr {
			if nsize == 0 {
				libc.free(ptr)
				return nil
			}
			return libc.realloc(ptr, nsize)
		}, nil)
	}
}
