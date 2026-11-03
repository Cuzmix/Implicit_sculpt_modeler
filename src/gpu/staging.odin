package gpu

import "base:intrinsics"
import "core:mem"
import "core:sync"

// Uploads through upload memory the package owns, so render makes no transfer buffers,
// maps nothing and opens no copy pass to fill a buffer or a texture: it hands the bytes
// (upload, upload_texture) or writes them where stage_buffer and stage_texture point, and
// the copies are recorded together, in one copy pass, just before the command buffer's
// next pass begins or it is submitted. So an upload lands before the next pass reads it.
//
// The memory is blocks of upload transfer buffers, each owned by one open recording at a
// time. A block taken afresh is mapped with `cycle`, so the backend hands it a backing no
// submitted work still reads (making one when every backing is busy); once the recording
// is submitted or cancelled the block is free for the next. Larger blocks are made for
// large uploads (a power of two in size, so a stroke's growing uploads reuse them) and kept
// while the free blocks hold no more than STAGING_KEEP; past that the largest go.

STAGING_BLOCK :: 4 << 20
STAGING_KEEP :: 64 << 20
// Buffer copies start on 16 bytes; texture copies on 256, which every backend takes.
@(private = "file")
STAGING_ALIGN_BUFFER :: 16
@(private = "file")
STAGING_ALIGN_TEXTURE :: 256

@(private = "file")
Staging_Block :: struct {
	transfer: Transfer_Buffer,
	size:     u32,
	used:     u32,
	mapped:   [^]u8, // while the recording writes into it; nil once its copies are recorded
	fresh:    bool, // not yet mapped by the recording that owns it, so mapped with cycle
}

@(private = "file")
Staged_Copy :: struct {
	block:   ^Staging_Block,
	offset:  u32,
	texture: bool,
	buffer:  Buffer_Region,
	region:  Texture_Region,
	pixels_per_row, rows_per_layer: u32,
}

@(private = "file")
Staging_Cmd :: struct {
	cmd:    Cmd,
	blocks: [dynamic]^Staging_Block,
	copies: [dynamic]Staged_Copy,
}

@(private = "file")
staging: struct {
	mutex:  sync.Mutex,
	free:   [dynamic]^Staging_Block,
	open:   [dynamic]^Staging_Cmd,
	spares: [dynamic]^Staging_Cmd,
}

// Bytes for `size` bytes of `dst` from `offset`, written by the caller before the next
// pass of `cmd` begins or it is submitted; nil (with last_error) when no upload memory
// could be made.
@(require_results)
stage_buffer :: proc(cmd: Cmd, dst: Buffer, offset, size: u32) -> []u8 {
	if size == 0 do return nil
	sync.mutex_guard(&staging.mutex)
	sc := staging_cmd(cmd)
	b, at, ok := staging_take(sc, size, STAGING_ALIGN_BUFFER)
	if !ok do return nil
	append(&sc.copies, Staged_Copy{block = b, offset = at, buffer = {buffer = dst, offset = offset, size = size}})
	return b.mapped[at:][:size]
}

// Bytes for `region` of a texture, rows of `pixels_per_row` texels, written by the caller
// as stage_buffer's are. `size` is the bytes the region takes.
@(require_results)
stage_texture :: proc(cmd: Cmd, region: Texture_Region, size, pixels_per_row, rows_per_layer: u32) -> []u8 {
	if size == 0 do return nil
	sync.mutex_guard(&staging.mutex)
	sc := staging_cmd(cmd)
	b, at, ok := staging_take(sc, size, STAGING_ALIGN_TEXTURE)
	if !ok do return nil
	append(&sc.copies, Staged_Copy{block = b, offset = at, texture = true, region = region, pixels_per_row = pixels_per_row, rows_per_layer = rows_per_layer})
	return b.mapped[at:][:size]
}

// Copies `data` into `dst` from `offset` before the next pass of `cmd`. False (with
// last_error) when no upload memory could be made.
@(require_results)
upload :: proc(cmd: Cmd, dst: Buffer, offset: u32, data: []u8) -> bool {
	if len(data) == 0 do return true
	bytes := stage_buffer(cmd, dst, offset, u32(len(data)))
	if bytes == nil do return false
	copy(bytes, data)
	return true
}

// Copies `data`, tightly packed rows of the region's width, into `region` of a texture
// before the next pass of `cmd`.
@(require_results)
upload_texture :: proc(cmd: Cmd, region: Texture_Region, data: []u8) -> bool {
	if len(data) == 0 do return true
	bytes := stage_texture(cmd, region, u32(len(data)), region.w, region.h)
	if bytes == nil do return false
	copy(bytes, data)
	return true
}

// The staging of an open recording, made on its first upload.
@(private = "file")
staging_cmd :: proc(cmd: Cmd) -> ^Staging_Cmd {
	for sc in staging.open do if sc.cmd == cmd do return sc
	sc := pop(&staging.spares) if len(staging.spares) > 0 else new(Staging_Cmd)
	sc.cmd = cmd
	append(&staging.open, sc)
	return sc
}

@(private = "file")
staging_find :: proc(cmd: Cmd) -> (^Staging_Cmd, int) {
	for sc, i in staging.open do if sc.cmd == cmd do return sc, i
	return nil, -1
}

// `size` bytes at `align` in a block the recording owns, mapped.
@(private = "file")
staging_take :: proc(sc: ^Staging_Cmd, size, align: u32) -> (^Staging_Block, u32, bool) {
	if n := len(sc.blocks); n > 0 {
		b := sc.blocks[n - 1]
		at := u32(mem.align_forward_uint(uint(b.used), uint(align)))
		if u64(at) + u64(size) <= u64(b.size) && staging_map(b) {
			b.used = at + size
			return b, at, true
		}
	}
	b := staging_block(size)
	if b == nil || !staging_map(b) do return nil, 0, false
	append(&sc.blocks, b)
	b.used = size
	return b, 0, true
}

// The smallest free block of at least `size` bytes, or a new one.
@(private = "file")
staging_block :: proc(size: u32) -> ^Staging_Block {
	best := -1
	for b, i in staging.free {
		if b.size >= size && (best < 0 || b.size < staging.free[best].size) do best = i
	}
	if best >= 0 {
		b := staging.free[best]
		unordered_remove(&staging.free, best)
		b.used, b.fresh = 0, true
		return b
	}
	block_size := u32(STAGING_BLOCK)
	if size > STAGING_BLOCK do block_size = u32(1) << u32(32 - intrinsics.count_leading_zeros(size - 1)) if size <= 1 << 31 else size
	transfer := create_transfer_buffer({usage = .Upload, size = block_size})
	if transfer == 0 do return nil
	b := new(Staging_Block)
	b^ = {transfer = transfer, size = block_size, fresh = true}
	return b
}

@(private = "file")
staging_map :: proc(b: ^Staging_Block) -> bool {
	if b.mapped != nil do return true
	b.mapped = ([^]u8)(map_transfer_buffer(b.transfer, b.fresh))
	b.fresh = false
	if b.mapped == nil {
		fail(.Refused, "upload memory could not be mapped")
		return false
	}
	return true
}

// Records the copies `cmd` has staged, in a copy pass of their own; called as a pass
// begins and before a submit, while no pass is open.
@(private)
staging_flush :: proc(cmd: Cmd) {
	sync.mutex_guard(&staging.mutex)
	sc, _ := staging_find(cmd)
	if sc == nil || len(sc.copies) == 0 do return
	for b in sc.blocks {
		if b.mapped != nil {
			unmap_transfer_buffer(b.transfer)
			b.mapped = nil
		}
	}
	pass := begin_copy_pass_raw(cmd)
	for c in sc.copies {
		if c.texture {
			upload_to_texture(pass, {transfer_buffer = c.block.transfer, offset = c.offset, pixels_per_row = c.pixels_per_row, rows_per_layer = c.rows_per_layer}, c.region, false)
		} else {
			upload_to_buffer(pass, {transfer_buffer = c.block.transfer, offset = c.offset}, c.buffer, false)
		}
	}
	end_copy_pass(pass)
	clear(&sc.copies)
}

// Hands the blocks of a submitted or cancelled recording back for the next, releasing the
// largest free ones while they hold more than STAGING_KEEP (the backend frees each once
// its copies have run).
@(private)
staging_done :: proc(cmd: Cmd) {
	sync.mutex_guard(&staging.mutex)
	sc, i := staging_find(cmd)
	if sc == nil do return
	for b in sc.blocks {
		if b.mapped != nil {
			unmap_transfer_buffer(b.transfer)
			b.mapped = nil
		}
		append(&staging.free, b)
	}
	kept: u64
	for b in staging.free do kept += u64(b.size)
	for kept > STAGING_KEEP && len(staging.free) > 1 {
		largest := 0
		for b, j in staging.free do if b.size > staging.free[largest].size do largest = j
		b := staging.free[largest]
		kept -= u64(b.size)
		unordered_remove(&staging.free, largest)
		release_transfer_buffer(b.transfer)
		free(b)
	}
	clear(&sc.blocks)
	clear(&sc.copies)
	sc.cmd = nil
	unordered_remove(&staging.open, i)
	append(&staging.spares, sc)
}

// Frees every block and record; the device is going.
@(private)
staging_reset :: proc() {
	for sc in staging.open {
		for b in sc.blocks {
			release_transfer_buffer(b.transfer)
			free(b)
		}
		delete(sc.blocks)
		delete(sc.copies)
		free(sc)
	}
	for sc in staging.spares {
		delete(sc.blocks)
		delete(sc.copies)
		free(sc)
	}
	for b in staging.free {
		release_transfer_buffer(b.transfer)
		free(b)
	}
	delete(staging.open)
	delete(staging.spares)
	delete(staging.free)
	staging = {}
}
