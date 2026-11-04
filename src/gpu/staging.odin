package gpu

import "base:intrinsics"
import "core:mem"
import "core:sync"

// Uploads and downloads through transfer memory the package owns, so render makes no
// transfer buffers, maps nothing and opens no copy pass to move bytes between the CPU and
// the GPU.
//
// An upload hands the bytes (upload, upload_texture) or writes them where stage_buffer and
// stage_texture point. A download (reserve_readback, then download or download_texture)
// names where in a readback's memory a buffer's or a texture's bytes go. The copies are
// recorded together, in the order they were asked for, in one copy pass just before the
// command buffer's next pass begins or it is submitted: so an upload lands before the next
// pass reads it, and a download sees what the passes before it wrote. They are asked for
// between passes, never while a pass of the recording is open: they would land after the
// open pass, not before.
//
// The memory is blocks of transfer buffers. An upload block is owned by one open recording
// at a time: taken afresh it is mapped with `cycle`, so the backend hands it a backing no
// submitted work still reads (making one when every backing is busy), and once the
// recording is submitted or cancelled it is free for the next. A download block takes the
// readbacks one recording reserves; once that recording is submitted, each readback is
// read (readback) when its ticket is done and released by its owner (release_readback),
// and the block is free again once every readback in it is released and its copies have
// run. Larger blocks are made for large transfers (a power of two in size, so a stroke's
// growing ones reuse them) and kept while the free blocks of a kind hold no more than
// STAGING_KEEP; past that the largest go.

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
	mapped:   [^]u8, // uploads: while the recording writes; downloads: once a readback is read
	fresh:    bool, // an upload block not yet mapped by the recording that owns it, so mapped with cycle
	// A download block's readbacks not yet released, whether its recording still reserves
	// in it, and how that recording ended: the ticket its copies are done at, or refused.
	refs:     int,
	open:     bool,
	ticket:   Ticket,
	refused:  bool,
}

@(private = "file")
Staged_Kind :: enum u8 {
	Upload_Buffer,
	Upload_Texture,
	Download_Buffer,
	Download_Texture,
}

@(private = "file")
Staged_Copy :: struct {
	block:   ^Staging_Block,
	offset:  u32,
	kind:    Staged_Kind,
	buffer:  Buffer_Region,
	region:  Texture_Region,
	pixels_per_row, rows_per_layer: u32,
}

@(private = "file")
Staging_Cmd :: struct {
	cmd:         Cmd,
	blocks:      [dynamic]^Staging_Block, // upload blocks
	down_blocks: [dynamic]^Staging_Block,
	copies:      [dynamic]Staged_Copy,
}

@(private = "file")
Readback_Record :: struct {
	block:        ^Staging_Block,
	offset, size: u32,
}

@(private = "file")
staging: struct {
	mutex:     sync.Mutex,
	free:      [dynamic]^Staging_Block, // upload blocks
	down_free: [dynamic]^Staging_Block,
	// Download blocks whose readbacks are all released while their copies may still run.
	retiring:  [dynamic]^Staging_Block,
	open:      [dynamic]^Staging_Cmd,
	spares:    [dynamic]^Staging_Cmd,
	records:   [dynamic]^Readback_Record,
}

// ---- Uploads ------------------------------------------------------------------------

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
	append(&sc.copies, Staged_Copy{block = b, offset = at, kind = .Upload_Buffer, buffer = {buffer = dst, offset = offset, size = size}})
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
	append(&sc.copies, Staged_Copy{block = b, offset = at, kind = .Upload_Texture, region = region, pixels_per_row = pixels_per_row, rows_per_layer = rows_per_layer})
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

// Records the copies staged on `cmd` so far, now rather than as its next pass begins: for
// a caller timing its uploads under a debug group of their own. No pass may be open.
flush_uploads :: proc(cmd: Cmd) {
	staging_flush(cmd)
}

// ---- Downloads ----------------------------------------------------------------------

// `size` bytes of readback memory for downloads `cmd` records (download, download_texture);
// 0 (with last_error) when none could be made. Its bytes are there once `cmd` is submitted
// and its ticket is done (readback); its owner releases it (release_readback), at any time.
@(require_results)
reserve_readback :: proc(cmd: Cmd, size: u32) -> Readback {
	if size == 0 do return 0
	sync.mutex_guard(&staging.mutex)
	sc := staging_cmd(cmd)
	b, at, ok := staging_take_down(sc, size)
	if !ok do return 0
	rec := pop(&staging.records) if len(staging.records) > 0 else new(Readback_Record)
	rec^ = {block = b, offset = at, size = size}
	handle := Readback(pool_add(&pools.readbacks, rec))
	if handle == 0 {
		append(&staging.records, rec)
		return 0
	}
	b.refs += 1
	return handle
}

// Copies `size` bytes of `src` from `offset` into `rb` from `at`, after what `cmd` recorded
// before. `rb` is one `cmd` reserved; a copy past its end is refused.
download :: proc(cmd: Cmd, rb: Readback, at: u32, src: Buffer, offset, size: u32) {
	if size == 0 do return
	sync.mutex_guard(&staging.mutex)
	rec, ok := readback_record(cmd, rb, at, size)
	if !ok do return
	append(&staging_cmd(cmd).copies, Staged_Copy{block = rec.block, offset = rec.offset + at, kind = .Download_Buffer, buffer = {buffer = src, offset = offset, size = size}})
}

// Copies `region` of a texture into `rb` from `at` (a multiple of 256), as tightly packed
// rows of the region's width; `size` is the bytes that takes.
download_texture :: proc(cmd: Cmd, rb: Readback, at: u32, region: Texture_Region, size: u32) {
	if size == 0 do return
	sync.mutex_guard(&staging.mutex)
	rec, ok := readback_record(cmd, rb, at, size)
	if !ok do return
	if (rec.offset + at) % STAGING_ALIGN_TEXTURE != 0 {
		fail(.Invalid, "a texture download starts on 256 bytes")
		return
	}
	append(&staging_cmd(cmd).copies, Staged_Copy{block = rec.block, offset = rec.offset + at, kind = .Download_Texture, region = region, pixels_per_row = region.w, rows_per_layer = region.h})
}

// A readback of `size` bytes of `src` from `offset`: reserve_readback and download in one.
@(require_results)
download_buffer :: proc(cmd: Cmd, src: Buffer, offset, size: u32) -> Readback {
	rb := reserve_readback(cmd, size)
	if rb != 0 do download(cmd, rb, 0, src, offset, size)
	return rb
}

// The readback's bytes once its recording's copies have run, valid until it is released:
// (nil, false) while they have not; (nil, true) when they never will (the recording was
// refused or cancelled, or the memory could not be mapped).
@(require_results)
readback :: proc(rb: Readback) -> (data: []u8, ready: bool) {
	sync.mutex_guard(&staging.mutex)
	rec := (^Readback_Record)(pool_get(&pools.readbacks, u32(rb)))
	if rec == nil do return nil, true
	b := rec.block
	if b.open do return nil, false
	if b.refused do return nil, true
	if !done(b.ticket) do return nil, false
	if b.mapped == nil {
		b.mapped = ([^]u8)(map_transfer_buffer(b.transfer, false))
		if b.mapped == nil {
			fail(.Refused, "readback memory could not be mapped")
			return nil, true
		}
	}
	return b.mapped[rec.offset:][:rec.size], true
}

// Hands a readback's memory back; safe at any time, its copies still to run or not. 0 does
// nothing.
release_readback :: proc(rb: Readback) {
	if rb == 0 do return
	sync.mutex_guard(&staging.mutex)
	rec := (^Readback_Record)(pool_remove(&pools.readbacks, u32(rb)))
	if rec == nil do return
	b := rec.block
	append(&staging.records, rec)
	b.refs -= 1
	if b.refs == 0 && !b.open do staging_retire(b)
}

// The record of `rb`, which `cmd` reserved, holding `size` bytes from `at`.
@(private = "file")
readback_record :: proc(cmd: Cmd, rb: Readback, at, size: u32) -> (^Readback_Record, bool) {
	rec := (^Readback_Record)(pool_get(&pools.readbacks, u32(rb)))
	if rec == nil {
		fail(.Invalid, "a download into a readback released or never reserved")
		return nil, false
	}
	sc, _ := staging_find(cmd)
	owned := false
	if sc != nil do for b in sc.down_blocks do if b == rec.block do owned = true
	if !owned {
		fail(.Invalid, "a download into a readback another recording reserved")
		return nil, false
	}
	if u64(at) + u64(size) > u64(rec.size) {
		fail(.Invalid, "a download past the end of its readback")
		return nil, false
	}
	return rec, true
}

// ---- Blocks -------------------------------------------------------------------------

// The staging of an open recording, made on its first upload or readback.
@(private = "file")
staging_cmd :: proc(cmd: Cmd) -> ^Staging_Cmd {
	for sc in staging.open do if sc.cmd == cmd do return sc
	sc := pop(&staging.spares) if len(staging.spares) > 0 else new(Staging_Cmd)
	sc.cmd = cmd
	append(&staging.open, sc)
	return sc
}

// Whether `cmd` has copies staged that its next pass or its submit will record.
@(private)
staging_pending :: proc(cmd: Cmd) -> bool {
	sync.mutex_guard(&staging.mutex)
	sc, _ := staging_find(cmd)
	return sc != nil && len(sc.copies) > 0
}

@(private = "file")
staging_find :: proc(cmd: Cmd) -> (^Staging_Cmd, int) {
	for sc, i in staging.open do if sc.cmd == cmd do return sc, i
	return nil, -1
}

// `size` bytes at `align` in an upload block the recording owns, mapped.
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
	b := staging_block(&staging.free, size, .Upload)
	if b == nil || !staging_map(b) do return nil, 0, false
	append(&sc.blocks, b)
	b.used = size
	return b, 0, true
}

// `size` bytes on 256 (so a texture may land there) in a download block the recording
// reserves in.
@(private = "file")
staging_take_down :: proc(sc: ^Staging_Cmd, size: u32) -> (^Staging_Block, u32, bool) {
	if n := len(sc.down_blocks); n > 0 {
		b := sc.down_blocks[n - 1]
		at := u32(mem.align_forward_uint(uint(b.used), STAGING_ALIGN_TEXTURE))
		if u64(at) + u64(size) <= u64(b.size) {
			b.used = at + size
			return b, at, true
		}
	}
	// Blocks whose copies have run since they were retired are free again.
	for i := 0; i < len(staging.retiring); {
		b := staging.retiring[i]
		if b.refused || done(b.ticket) {
			unordered_remove(&staging.retiring, i)
			append(&staging.down_free, b)
			continue
		}
		i += 1
	}
	b := staging_block(&staging.down_free, size, .Download)
	if b == nil do return nil, 0, false
	b.refs, b.open, b.ticket, b.refused = 0, true, {}, false
	append(&sc.down_blocks, b)
	b.used = size
	return b, 0, true
}

// The smallest block of `free` of at least `size` bytes, or a new one.
@(private = "file")
staging_block :: proc(free: ^[dynamic]^Staging_Block, size: u32, usage: Transfer_Usage) -> ^Staging_Block {
	best := -1
	for b, i in free {
		if b.size >= size && (best < 0 || b.size < free[best].size) do best = i
	}
	if best >= 0 {
		b := free[best]
		unordered_remove(free, best)
		b.used, b.fresh = 0, true
		return b
	}
	block_size := u32(STAGING_BLOCK)
	if size > STAGING_BLOCK do block_size = u32(1) << u32(32 - intrinsics.count_leading_zeros(size - 1)) if size <= 1 << 31 else size
	transfer := create_transfer_buffer({usage = usage, size = block_size})
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

// A download block with no readback left: free once its copies have run.
@(private = "file")
staging_retire :: proc(b: ^Staging_Block) {
	if b.mapped != nil {
		unmap_transfer_buffer(b.transfer)
		b.mapped = nil
	}
	if b.refused || done(b.ticket) {
		append(&staging.down_free, b)
		staging_trim(&staging.down_free)
	} else {
		append(&staging.retiring, b)
	}
}

// Releases the largest of the free blocks while they hold more than STAGING_KEEP (the
// backend frees each once no work in flight uses it).
@(private = "file")
staging_trim :: proc(blocks: ^[dynamic]^Staging_Block) {
	kept: u64
	for b in blocks do kept += u64(b.size)
	for kept > STAGING_KEEP && len(blocks) > 1 {
		largest := 0
		for b, j in blocks do if b.size > blocks[largest].size do largest = j
		b := blocks[largest]
		kept -= u64(b.size)
		unordered_remove(blocks, largest)
		release_transfer_buffer(b.transfer)
		free(b)
	}
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
		switch c.kind {
		case .Upload_Buffer:
			upload_to_buffer(pass, {transfer_buffer = c.block.transfer, offset = c.offset}, c.buffer, false)
		case .Upload_Texture:
			upload_to_texture(pass, {transfer_buffer = c.block.transfer, offset = c.offset, pixels_per_row = c.pixels_per_row, rows_per_layer = c.rows_per_layer}, c.region, false)
		case .Download_Buffer:
			download_from_buffer(pass, c.buffer, {transfer_buffer = c.block.transfer, offset = c.offset})
		case .Download_Texture:
			download_from_texture(pass, c.region, {transfer_buffer = c.block.transfer, offset = c.offset, pixels_per_row = c.pixels_per_row, rows_per_layer = c.rows_per_layer})
		}
	}
	end_copy_pass(pass)
	clear(&sc.copies)
}

// Hands the upload blocks of a submitted or cancelled recording back for the next, and
// gives its download blocks the ticket their readbacks are ready at (`ok` false: never).
@(private)
staging_done :: proc(cmd: Cmd, ticket: Ticket, ok: bool) {
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
	staging_trim(&staging.free)
	for b in sc.down_blocks {
		b.open, b.ticket, b.refused = false, ticket, !ok
		if b.refs == 0 do staging_retire(b)
	}
	clear(&sc.blocks)
	clear(&sc.down_blocks)
	clear(&sc.copies)
	sc.cmd = nil
	unordered_remove(&staging.open, i)
	append(&staging.spares, sc)
}

// Frees every block and record; the device is going, and render has released its
// readbacks (one it still holds keeps its block, which the tracking allocator reports).
@(private)
staging_reset :: proc() {
	release_all :: proc(blocks: [dynamic]^Staging_Block) {
		for b in blocks {
			release_transfer_buffer(b.transfer)
			free(b)
		}
		delete(blocks)
	}
	for sc in staging.open {
		release_all(sc.blocks)
		release_all(sc.down_blocks)
		delete(sc.copies)
		free(sc)
	}
	for sc in staging.spares {
		delete(sc.blocks)
		delete(sc.down_blocks)
		delete(sc.copies)
		free(sc)
	}
	release_all(staging.free)
	release_all(staging.down_free)
	release_all(staging.retiring)
	for rec in staging.records do free(rec)
	delete(staging.records)
	delete(staging.open)
	delete(staging.spares)
	staging = {}
}
