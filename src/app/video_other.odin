#+build !linux
#+build !windows
#+build !darwin
package main

// Video where the system has no encoder to hand (video.odin): the web; the frames stay as
// pictures.
VIDEO_AVAILABLE :: false
// The encoder takes sides that are multiples of this.
VIDEO_ALIGN :: 2

Video_Backend :: struct {}

video_backend_open :: proc(v: ^Video) -> string {return "this system has no video encoder"}
video_backend_frame :: proc(v: ^Video, rgba: []u8) -> bool {return false}
video_backend_close :: proc(v: ^Video, keep: bool) -> bool {return false}
