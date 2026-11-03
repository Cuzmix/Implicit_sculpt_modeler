package main

import "base:runtime"
import "core:thread"
import "core:time"

import "../send"

// The web version has no Send (SEND_AVAILABLE), so nothing is found or answered there;
// these keep the shared code building.

Send_Answer :: struct {}

send_answer_begin :: proc(sh: ^Send_Shared, gen: int, ctx: runtime.Context) -> Send_Answer {return {}}

send_answer_stop :: proc(a: ^Send_Answer) -> ^thread.Thread {return nil}

send_find_run :: proc(sh: ^Send_Shared, name: string, wait: time.Duration, stop: ^bool, all: ^[dynamic]send.Found = nil) -> (found: send.Found, ok: bool) {return}
