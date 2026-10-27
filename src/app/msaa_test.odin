package main

import "core:testing"

// Each setting names a sample count that names it back, and counts the panel does not
// offer read as the nearest one it does.
@(test)
msaa_settings_name_sample_counts :: proc(t: ^testing.T) {
	for m in Msaa do testing.expect_value(t, msaa_of(msaa_samples(m)), m)
	testing.expect_value(t, msaa_of(._8), Msaa.X4)
	testing.expect_value(t, len(MSAA_NAMES), len(Msaa))
	s := script_parse("set msaa x2", "x")
	defer script_destroy(&s)
	testing.expect_value(t, len(s.errors), 0)
	app: App
	for st in s.statements do script_set(&app, st)
	testing.expect_value(t, app.msaa, Msaa.X2)
}
