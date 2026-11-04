#+build !js
package gpu

import "core:sync"
import vk "vendor:vulkan"

// Device memory for buffers and images, taken from large blocks rather than one
// vkAllocateMemory per backing. A driver caps the allocations a device may hold (4,096 on
// Windows), and each allocation can stall it, so every resource but a large one shares a
// block: 256 MB on a desktop, 64 MB on Android, where memory is shared with the system, a
// quarter of that for host-visible memory, and at most an eighth of the heap either way. A
// request over half a block, or for lazily allocated memory (a transient attachment, which
// takes no memory where the tile memory holds it), gets memory of its own.
//
// Blocks are kept apart by memory type, by whether buffer device addresses may point into
// them, and by buffers against images, so bufferImageGranularity never applies between two
// neighbours. A host-visible block is mapped once, when it is made, and each allocation's
// mapping points into it. Each block keeps its free spans in order of offset, takes the first
// that fits (with the allocation's alignment) and merges a freed span with its neighbours. An
// emptied block is freed unless it is the last of its kind, so a resource made and released
// again and again does not allocate each time.

Vk_Memory :: struct {
	memory: vk.DeviceMemory,
	offset: vk.DeviceSize,
	size:   vk.DeviceSize,
	// Where the allocation starts in the block's mapping; nil unless the memory is host-visible.
	mapped: [^]u8,
	// nil for memory of its own.
	block:  ^Vk_Block,
}

Vk_Block_Key :: struct {
	type:    u32,
	address: bool,
	image:   bool,
}

Vk_Block :: struct {
	key:    Vk_Block_Key,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
	mapped: [^]u8,
	// Free spans in order of offset, none touching another.
	free:   [dynamic]Vk_Span,
	live:   int,
}

Vk_Span :: struct {
	offset, size: vk.DeviceSize,
}

@(private = "file")
vk_blocks: struct {
	mutex: sync.Mutex,
	list:  [dynamic]^Vk_Block,
}

// The size of a block of memory type `type`. A host-visible block is a quarter of a device's:
// it is the system's memory on most GPUs, and what the CPU writes into it (uniforms, staging,
// readbacks) is far smaller than the meshes and pictures the GPU keeps.
@(private = "file")
vk_block_size :: proc(type: u32) -> vk.DeviceSize {
	size := vk.DeviceSize(64 if ODIN_PLATFORM_SUBTARGET == .Android else 256) << 20
	if vk_host_visible(type) do size /= 4
	heap := vk_state.memory.memoryHeaps[vk_state.memory.memoryTypes[type].heapIndex].size
	return min(size, max(heap / 8, 1 << 20))
}

// Memory of type `type` for `reqs`: from a block, or of its own when it is large or
// `dedicated`.
vk_memory_take :: proc(reqs: vk.MemoryRequirements, type: u32, address, image: bool, dedicated := false) -> (Vk_Memory, bool) {
	block_size := vk_block_size(type)
	if dedicated || reqs.size > block_size / 2 {
		memory, ok := vk_memory_allocate(reqs.size, type, address)
		if !ok do return {}, false
		m := Vk_Memory{memory = memory, size = reqs.size}
		if vk_host_visible(type) {
			data: rawptr
			if vk.MapMemory(vk_state.device, memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &data) != .SUCCESS {
				vk.FreeMemory(vk_state.device, memory, nil)
				return {}, false
			}
			m.mapped = ([^]u8)(data)
		}
		return m, true
	}
	key := Vk_Block_Key{type, address, image}
	align := max(reqs.alignment, 1)
	sync.mutex_guard(&vk_blocks.mutex)
	for block in vk_blocks.list {
		if block.key != key do continue
		if m, ok := vk_block_take(block, reqs.size, align); ok do return m, true
	}
	memory, ok := vk_memory_allocate(block_size, type, address)
	if !ok do return {}, false
	block := new(Vk_Block)
	block.key, block.memory, block.size = key, memory, block_size
	if vk_host_visible(type) {
		data: rawptr
		if vk.MapMemory(vk_state.device, memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &data) != .SUCCESS {
			vk.FreeMemory(vk_state.device, memory, nil)
			free(block)
			return {}, false
		}
		block.mapped = ([^]u8)(data)
	}
	append(&block.free, Vk_Span{0, block_size})
	append(&vk_blocks.list, block)
	return vk_block_take(block, reqs.size, align)
}

// Gives memory back: to its block, which goes when emptied unless it is the last of its
// kind, or to the device.
vk_memory_give :: proc(m: Vk_Memory) {
	if m.memory == 0 do return
	block := m.block
	if block == nil {
		vk.FreeMemory(vk_state.device, m.memory, nil)
		return
	}
	sync.mutex_guard(&vk_blocks.mutex)
	vk_block_give(block, Vk_Span{m.offset, m.size})
	if block.live > 0 do return
	others := 0
	for b in vk_blocks.list do if b != block && b.key == block.key do others += 1
	if others == 0 do return
	for b, i in vk_blocks.list do if b == block {
		ordered_remove(&vk_blocks.list, i)
		break
	}
	vk_block_free(block)
}

// Frees every block, at the device's end, when nothing uses them.
vk_memory_destroy :: proc() {
	for block in vk_blocks.list do vk_block_free(block)
	delete(vk_blocks.list)
	vk_blocks.list = nil
}

@(private = "file")
vk_host_visible :: proc(type: u32) -> bool {
	return .HOST_VISIBLE in vk_state.memory.memoryTypes[type].propertyFlags
}

// One vkAllocateMemory; `address` for memory a buffer device address may point into.
@(private = "file")
vk_memory_allocate :: proc(size: vk.DeviceSize, type: u32, address: bool) -> (vk.DeviceMemory, bool) {
	flags := vk.MemoryAllocateFlagsInfo{sType = .MEMORY_ALLOCATE_FLAGS_INFO, flags = {.DEVICE_ADDRESS}}
	info := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, pNext = &flags if address else nil, allocationSize = size, memoryTypeIndex = type}
	memory: vk.DeviceMemory
	if vk.AllocateMemory(vk_state.device, &info, nil, &memory) != .SUCCESS do return 0, false
	count_allocation(i64(size))
	return memory, true
}

@(private = "file")
vk_block_take :: proc(block: ^Vk_Block, size, align: vk.DeviceSize) -> (Vk_Memory, bool) {
	for span, i in block.free {
		start := (span.offset + align - 1) / align * align
		end := span.offset + span.size
		if start + size > end do continue
		// What is left before and after the allocation stays free, in order.
		ordered_remove(&block.free, i)
		at := i
		if start > span.offset {
			inject_at(&block.free, at, Vk_Span{span.offset, start - span.offset})
			at += 1
		}
		if start + size < end do inject_at(&block.free, at, Vk_Span{start + size, end - start - size})
		block.live += 1
		m := Vk_Memory{memory = block.memory, offset = start, size = size, block = block}
		if block.mapped != nil do m.mapped = block.mapped[start:]
		return m, true
	}
	return {}, false
}

@(private = "file")
vk_block_give :: proc(block: ^Vk_Block, span: Vk_Span) {
	block.live -= 1
	at := len(block.free)
	for s, i in block.free do if s.offset > span.offset {
		at = i
		break
	}
	inject_at(&block.free, at, span)
	// Merge with the span after, then the one before.
	if at + 1 < len(block.free) && block.free[at].offset + block.free[at].size == block.free[at + 1].offset {
		block.free[at].size += block.free[at + 1].size
		ordered_remove(&block.free, at + 1)
	}
	if at > 0 && block.free[at - 1].offset + block.free[at - 1].size == block.free[at].offset {
		block.free[at - 1].size += block.free[at].size
		ordered_remove(&block.free, at)
	}
}

@(private = "file")
vk_block_free :: proc(block: ^Vk_Block) {
	vk.FreeMemory(vk_state.device, block.memory, nil)
	delete(block.free)
	free(block)
}
