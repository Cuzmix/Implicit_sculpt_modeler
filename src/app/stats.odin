package main

import "core:slice"

FRAME_HISTORY :: 240

// Fixed-size ring buffers: recording a frame never allocates.
Frame_Stats :: struct {
	frame_ms: [FRAME_HISTORY]f32,
	cpu_ms:   [FRAME_HISTORY]f32,
	head:     int,
	count:    int,
}

frame_stats_push :: proc(s: ^Frame_Stats, frame_ms, cpu_ms: f64) {
	s.frame_ms[s.head] = f32(frame_ms)
	s.cpu_ms[s.head] = f32(cpu_ms)
	s.head = (s.head + 1) % FRAME_HISTORY
	s.count = min(s.count + 1, FRAME_HISTORY)
}

// Median and 99th percentile of the recorded frame times, sorted on the stack.
frame_stats_percentiles :: proc(s: ^Frame_Stats) -> (p50, p99: f32) {
	if s.count == 0 do return
	sorted: [FRAME_HISTORY]f32
	n := s.count
	// Until the ring wraps, samples occupy the first `count` slots.
	copy(sorted[:n], s.frame_ms[:n])
	slice.sort(sorted[:n])
	return sorted[n / 2], sorted[min(n - 1, n * 99 / 100)]
}
