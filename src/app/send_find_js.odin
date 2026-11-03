package main

import "base:runtime"
import "core:time"

import "../send"

// The web version has no Send (SEND_AVAILABLE), so nothing is found or answered there;
// these keep the shared code building.

Send_Answer :: struct {}

send_answer_begin :: proc(sh: ^Send_Shared, ctx: runtime.Context) -> Send_Answer {return {}}

send_answer_end :: proc(sh: ^Send_Shared, a: ^Send_Answer) {}

send_find_run :: proc(sh: ^Send_Shared, name: string, wait: time.Duration) -> (found: send.Found, ok: bool) {return}
