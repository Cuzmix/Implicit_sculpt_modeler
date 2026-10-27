package main

import "core:testing"

// Save next counts a name's trailing number up, keeping its digits, adds _002 to a name
// without one, and passes over numbers whose file exists.
@(test)
save_next_numbers_the_file :: proc(t: ^testing.T) {
	none :: proc(path: string) -> bool {return false}
	first :: proc(path: string, ok: bool) -> string {return path if ok else "(none)"}
	testing.expect_value(t, first(save_next_path("dir/dragon.sculpt", none)), "dir/dragon_002.sculpt")
	testing.expect_value(t, first(save_next_path("dir/dragon_001.sculpt", none)), "dir/dragon_002.sculpt")
	testing.expect_value(t, first(save_next_path("dragon_7.sculpt", none)), "dragon_008.sculpt")
	testing.expect_value(t, first(save_next_path("dragon_009.sculpt", none)), "dragon_010.sculpt")
	testing.expect_value(t, first(save_next_path("dragon_999.sculpt", none)), "dragon_1000.sculpt")
	testing.expect_value(t, first(save_next_path("dragon_00041.sculpt", none)), "dragon_00042.sculpt")
	// Digits not after an underscore, or too many of them, are part of the name.
	testing.expect_value(t, first(save_next_path("head2.sculpt", none)), "head2_002.sculpt")
	testing.expect_value(t, first(save_next_path("scan_1234567.sculpt", none)), "scan_1234567_002.sculpt")
	testing.expect_value(t, first(save_next_path("rock_.sculpt", none)), "rock__002.sculpt")
	taken :: proc(path: string) -> bool {return path == "a/b_002.sculpt" || path == "a/b_003.sculpt"}
	testing.expect_value(t, first(save_next_path("a/b.sculpt", taken)), "a/b_004.sculpt")
}
