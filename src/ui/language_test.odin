package ui

import "core:testing"

@(private = "file")
SAMPLE :: `@language Testisch
# A comment, and blank lines between entries.

Colour
= Farbe

Two\nlines
= Zwei\nZeilen

%s is not a voxel brush
= %s ist kein Voxel-Pinsel

theme|Light
= Hell

Light
= Licht
`

// A language file reads into its entries, escapes and all, and tr shows each English line
// in it, leaving one it lacks as it is; trc picks the entry for its place first.
@(test)
language_reads_and_translates :: proc(t: ^testing.T) {
	l, ok, line := language_parse(SAMPLE)
	defer language_destroy(&l)
	testing.expectf(t, ok, "the sample failed at line %d", line)
	testing.expect_value(t, l.name, "Testisch")
	testing.expect_value(t, len(l.entries), 5)
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	testing.expect_value(t, tr(&ctx, "Colour"), "Colour")
	ctx.language = &l
	testing.expect_value(t, tr(&ctx, "Colour"), "Farbe")
	testing.expect_value(t, tr(&ctx, "Two\nlines"), "Zwei\nZeilen")
	testing.expect_value(t, tr(&ctx, "Not here"), "Not here")
	testing.expect_value(t, trc(&ctx, "theme", "Light"), "Hell")
	testing.expect_value(t, trc(&ctx, "lamp", "Light"), "Licht")
	// What is measured is what is shown: the translation, unless the text is the user's.
	frame_begin(&ctx, {window = {800, 600}, pixel_density = 1, dt = 1.0 / 60})
	testing.expect(t, text_width(&ctx, "Colour", 14) == text_width_plain(&ctx, "Farbe", 14))
	testing.expect(t, text_width_plain(&ctx, "Colour", 14) != text_width_plain(&ctx, "Farbe", 14))
	_ = frame_end(&ctx)
	ctx.language = nil
}

// A damaged file is refused at the line at fault, never half read.
@(test)
language_refuses_a_damaged_file :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		line: int,
	} {
		{"Colour\n= Farbe\n", 1}, // no @language line
		{"@language X\n= Farbe\n", 2}, // a translation with no English line
		{"@language X\nColour\n= Farbe\nColour\n= Couleur\n", 5}, // given twice
		{"@language X\nColour\nShape\n= Form\n", 2}, // Colour has no translation
		{"@language X\n%s left\n= %d übrig\n", 3}, // the verbs differ
		{"@language X\nColour\n", 2}, // the file ends before its translation
	}
	for c in cases {
		l, ok, line := language_parse(c.text)
		testing.expectf(t, !ok && line == c.line, "%q: ok %v at line %d", c.text, ok, line)
		testing.expect(t, len(l.entries) == 0)
	}
	testing.expect(t, language_verbs_match("%.1f mm and 100%%", "%.1f mm und 100 %%"))
	testing.expect(t, !language_verbs_match("%s of %d", "%d von %s"))
}

// With record on, a line shown that the language lacks is kept once, and a translation
// drawn again is not taken for one.
@(test)
language_records_what_it_lacks :: proc(t: ^testing.T) {
	l, _, _ := language_parse(SAMPLE)
	defer language_destroy(&l)
	l.record = true
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	ctx.language = &l
	_ = tr(&ctx, "Not here")
	_ = tr(&ctx, "Not here")
	_ = tr(&ctx, tr(&ctx, "Colour"))
	testing.expect_value(t, len(l.missing), 1)
	testing.expect(t, "Not here" in l.missing)
	ctx.language = nil
}
