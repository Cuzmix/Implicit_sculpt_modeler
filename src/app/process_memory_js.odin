package main

// A browser tab gives a page no measure of the memory it holds, so the web version reads
// none and the readout leaves the line out.
process_memory :: proc() -> int {
	return 0
}

// A browser tab does not say how much more it may take either, so the check before a heavy
// step (memory_check.odin) has nothing to go on and lets every step run.
memory_headroom :: proc() -> int {
	return 0
}
