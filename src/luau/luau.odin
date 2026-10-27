package luau

import "core:c"

// The part of Luau's C API (deps/luau-src/VM/include/lua.h, lualib.h and
// Compiler/include/luacode.h, at LUAU_TAG in scripts/versions.env) that script plugins
// use, for the library scripts/build_luau.py builds. That build is Luau's LUAU_EXTERN_C
// one: the names are C names, and an error is a longjmp (LUA_USE_LONGJMP=1), so a
// function that raises one must have nothing left to free or `defer` to run when it does.
// Plugins are for the desktop builds only (README "Script plugins"; the store rules in
// sm-store keep code that was not reviewed out of tablet builds), so elsewhere nothing is
// imported and AVAILABLE is false: the app's object file then names no Luau symbol.

AVAILABLE :: (ODIN_OS == .Windows || ODIN_OS == .Linux) && ODIN_PLATFORM_SUBTARGET != .Android

State :: struct {}

Alloc :: #type proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr
CFunction :: #type proc "c" (L: ^State) -> c.int
Continuation :: #type proc "c" (L: ^State, status: c.int) -> c.int

// lua_Callbacks, field for field: only `userdata` and `interrupt` are set here, the rest
// stay nil, but the layout is Luau's.
Callbacks :: struct {
	userdata:            rawptr,
	interrupt:           proc "c" (L: ^State, gc: c.int),
	panic:               proc "c" (L: ^State, errcode: c.int),
	userthread:          proc "c" (LP, L: ^State),
	useratom:            proc "c" (L: ^State, s: cstring, l: c.size_t) -> i16,
	userfinalizer:       proc "c" (L, co: ^State),
	debugbreak:          proc "c" (L: ^State, ar: rawptr),
	debugstep:           proc "c" (L: ^State, ar: rawptr),
	debuginterrupt:      proc "c" (L: ^State, ar: rawptr),
	debugprotectederror: proc "c" (L: ^State),
	onallocate:          proc "c" (L: ^State, block: rawptr, osize, nsize: c.size_t, memcat: u8, tt, tag: c.int),
	preresume:           proc "c" (L: ^State),
	postresume:          proc "c" (L: ^State),
	onfree:              proc "c" (L: ^State, block: rawptr),
}

// lua_Type with Luau's default float vectors (LUA_VECTOR_DOUBLE 0); the tests check the
// names Luau gives them, so a new tag that reorders them fails there, not in a plugin.
Type :: enum c.int {
	None          = -1,
	Nil           = 0,
	Boolean       = 1,
	Light_Userdata,
	Number,
	Integer,
	Vector,
	String,
	Table,
	Function,
	Userdata,
	Thread,
	Buffer,
}

// lua_Status.
OK :: 0
ERRRUN :: 2
ERRMEM :: 4

MAXCSTACK :: 8000
REGISTRYINDEX :: -MAXCSTACK - 2000
GLOBALSINDEX :: -MAXCSTACK - 2002

when AVAILABLE {
	when ODIN_OS == .Windows {
		// Built with /MT, whose objects bring in the static C++ library themselves.
		foreign import lib "../../deps/luau/luau.lib"
	} else {
		foreign import lib {"../../deps/luau/libluau.a", "system:stdc++", "system:m"}
	}

	@(default_calling_convention = "c")
	foreign lib {
		lua_newstate :: proc(allocator: Alloc, ud: rawptr) -> ^State ---
		lua_close :: proc(L: ^State) ---
		lua_newthread :: proc(L: ^State) -> ^State ---
		lua_gettop :: proc(L: ^State) -> c.int ---
		lua_settop :: proc(L: ^State, idx: c.int) ---
		lua_pushvalue :: proc(L: ^State, idx: c.int) ---
		lua_remove :: proc(L: ^State, idx: c.int) ---
		lua_type :: proc(L: ^State, idx: c.int) -> Type ---
		lua_typename :: proc(L: ^State, tp: Type) -> cstring ---
		lua_tonumberx :: proc(L: ^State, idx: c.int, isnum: ^c.int) -> f64 ---
		lua_toboolean :: proc(L: ^State, idx: c.int) -> c.int ---
		lua_tolstring :: proc(L: ^State, idx: c.int, len: ^c.size_t) -> [^]u8 ---
		lua_objlen :: proc(L: ^State, idx: c.int) -> c.int ---
		lua_pushnil :: proc(L: ^State) ---
		lua_pushnumber :: proc(L: ^State, n: f64) ---
		lua_pushinteger :: proc(L: ^State, n: c.int) ---
		lua_pushlstring :: proc(L: ^State, s: [^]u8, l: c.size_t) ---
		lua_pushcclosurek :: proc(L: ^State, fn: CFunction, debugname: cstring, nup: c.int, cont: Continuation) ---
		lua_pushboolean :: proc(L: ^State, b: c.int) ---
		lua_getfield :: proc(L: ^State, idx: c.int, k: cstring) -> Type ---
		lua_rawgeti :: proc(L: ^State, idx: c.int, n: c.int) -> Type ---
		lua_createtable :: proc(L: ^State, narr, nrec: c.int) ---
		lua_setreadonly :: proc(L: ^State, idx: c.int, enabled: c.int) ---
		lua_setfield :: proc(L: ^State, idx: c.int, k: cstring) ---
		lua_rawseti :: proc(L: ^State, idx: c.int, n: c.int) ---
		lua_call :: proc(L: ^State, nargs, nresults: c.int) ---
		lua_pcall :: proc(L: ^State, nargs, nresults, errfunc: c.int) -> c.int ---
		lua_cpcall :: proc(L: ^State, fn: CFunction, ud: rawptr) -> c.int ---
		lua_error :: proc(L: ^State) -> ! ---
		lua_concat :: proc(L: ^State, n: c.int) ---
		lua_ref :: proc(L: ^State, idx: c.int) -> c.int ---
		lua_unref :: proc(L: ^State, ref: c.int) -> c.int ---
		lua_callbacks :: proc(L: ^State) -> ^Callbacks ---

		luaL_where :: proc(L: ^State, lvl: c.int) ---
		luaL_openlibs :: proc(L: ^State) ---
		luaL_sandbox :: proc(L: ^State) ---
		luaL_sandboxthread :: proc(L: ^State) ---

		// The bytecode, or a chunk that raises the compile error when run, in memory from
		// libc's malloc: the caller frees it with libc's free.
		luau_compile :: proc(source: [^]u8, size: c.size_t, options: rawptr, outsize: ^c.size_t) -> [^]u8 ---
		luau_load :: proc(L: ^State, chunkname: cstring, data: [^]u8, size: c.size_t, env: c.int) -> c.int ---
	}

	// The macros of lua.h this package's users need, as procedures.

	drop :: proc "contextless" (L: ^State, n: c.int) {lua_settop(L, -n - 1)}

	pushcfunction :: proc "contextless" (L: ^State, fn: CFunction, debugname: cstring) {lua_pushcclosurek(L, fn, debugname, 0, nil)}

	pushstring :: proc "contextless" (L: ^State, s: string) {lua_pushlstring(L, raw_data(s), c.size_t(len(s)))}

	getglobal :: proc "contextless" (L: ^State, name: cstring) -> Type {return lua_getfield(L, GLOBALSINDEX, name)}

	setglobal :: proc "contextless" (L: ^State, name: cstring) {lua_setfield(L, GLOBALSINDEX, name)}

	// The string at `idx`, which Luau owns: it lives while the value stays on the stack.
	// A number is turned into its text in place, as lua_tolstring does; any other value
	// gives "" and false.
	tostring :: proc "contextless" (L: ^State, idx: c.int) -> (string, bool) {
		n: c.size_t
		p := lua_tolstring(L, idx, &n)
		if p == nil do return "", false
		return string(p[:n]), true
	}

	// Raises `message` as a Luau error, after the plugin's file and line that called the
	// function raising it, as luaL_error does. Nothing after it runs: the caller must have
	// freed what it made, and have no `defer` pending.
	raise :: proc "contextless" (L: ^State, message: string) -> ! {
		luaL_where(L, 1)
		pushstring(L, message)
		lua_concat(L, 2)
		lua_error(L)
	}
}
