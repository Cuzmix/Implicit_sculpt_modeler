#+build !linux
#+build !windows
package main

// Video on the systems whose encoder is not wired up yet (video.odin): the Mac and the
// iPad (AVFoundation) and the web, which has none; the frames stay as pictures.
VIDEO_AVAILABLE :: false

Video_Backend :: struct {}

video_backend_open :: proc(v: ^Video) -> string {return "this system has no video encoder"}
video_backend_frame :: proc(v: ^Video, rgba: []u8) -> bool {return false}
video_backend_close :: proc(v: ^Video, keep: bool) -> bool {return false}
