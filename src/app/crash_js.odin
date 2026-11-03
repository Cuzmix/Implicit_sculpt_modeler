#+build js
package main

// A browser tab has no signals to catch and no file the crash log could be written to
// while it fails: a crash there is the browser's console's to report, with its own stack.

crash_raw_write :: proc "contextless" (bytes: []u8) {}

crash_handlers_install :: proc() {}

crash_handlers_remove :: proc() {}
