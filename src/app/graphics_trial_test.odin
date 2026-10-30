package main

import "core:os"
import "core:strings"
import "core:testing"

// A Metal trial the setting chose leaves its marker; a start that finds the marker is back on
// Automatic and removes it; a clean start removes it too; --gpu=metal and other choices are
// never guarded.
@(test)
graphics_trial_falls_back_after_a_failed_start :: proc(t: ^testing.T) {
	folder := "build/graphics_trial_test/"
	_ = os.remove_all(folder)
	defer os.remove_all(folder)
	testing.expect(t, os.make_directory_all(folder) == nil)
	settings := "build/graphics_trial_test/settings.txt"
	marker := graphics_trial_path(settings)
	testing.expect(t, strings.has_suffix(marker, "settings-metal-trial"), marker)

	start, path, failed := graphics_trial_begin(.Metal, "", settings)
	testing.expect_value(t, start, Graphics.Metal)
	testing.expect(t, !failed && path != "" && os.exists(marker), "a trial start left no marker")

	// The start crashed: the next one finds the marker.
	start, path, failed = graphics_trial_begin(.Metal, "", settings)
	testing.expect_value(t, start, Graphics.Auto)
	testing.expect(t, failed && path == "" && !os.exists(marker), "a failed trial was not undone")

	// A start that shows its frames removes its marker, and the one after tries again.
	start, path, failed = graphics_trial_begin(.Metal, "", settings)
	app: App
	app.graphics_trial = strings.clone(path)
	graphics_trial_end(&app)
	testing.expect(t, app.graphics_trial == "" && !os.exists(marker), "a started trial kept its marker")
	start, path, failed = graphics_trial_begin(.Metal, "", settings)
	testing.expect(t, start == .Metal && !failed, "a trial after a good start was refused")
	_ = os.remove(marker)

	for c in ([?]Graphics{.Auto, .Vulkan, .SDL_GPU}) {
		start, path, failed = graphics_trial_begin(c, "", settings)
		testing.expect(t, start == c && path == "" && !failed, "a choice other than Metal was guarded")
	}
	start, path, failed = graphics_trial_begin(.Metal, "metal", settings)
	testing.expect(t, start == .Metal && path == "" && !failed && !os.exists(marker), "--gpu=metal was guarded")
	start, path, failed = graphics_trial_begin(.Metal, "", "")
	testing.expect(t, start == .Metal && path == "" && !failed, "a run without settings was guarded")
}
