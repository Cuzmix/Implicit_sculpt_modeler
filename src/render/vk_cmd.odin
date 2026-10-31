package render

import "core:log"
import "core:mem"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Command buffers, passes and fences of the Vulkan backend. A texture rests in its default
// layout (vk_default_layout) between passes: a pass moves what it writes into the layout it
// needs and back when it ends, as SDL_GPU does, so command buffers recorded out of order
// still agree on every layout. Barriers are conservative (all commands, all memory); the
// pass structure keeps them few.

Vk_Stage :: enum u8 {
	Vertex,
	Fragment,
	Compute,
}

Vk_Pass :: enum u8 {
	None,
	Render,
	Compute,
	Copy,
}

Vk_Uniform_Block :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	mapped: [^]u8,
}

Vk_Uniform_Slot :: struct {
	block:  ^Vk_Uniform_Block,
	offset: u32,
}

Vk_Present :: struct {
	window: ^Vk_Window,
	image:  u32,
	frame:  int,
}

// A texture level a pass moved out of its default layout, to move back when it ends.
Vk_Target :: struct {
	img:    ^Vk_Image,
	level:  u32,
	layout: vk.ImageLayout,
}

Vk_Sampled :: struct {
	view:    vk.ImageView,
	sampler: vk.Sampler,
}

// The queue a command buffer goes to, whose timeline its serial counts on.
Vk_Queue :: enum u8 {
	Graphics,
	Compute,
}

Vk_Cmd :: struct {
	cb:              vk.CommandBuffer,
	queue:           Vk_Queue,
	serial:          u64, // the submission's timeline value on its queue, once submitted
	// A graphics command buffer waits for the compute timeline to reach this before it
	// runs (gpu_wait_on); 0 for no wait.
	compute_wait:    u64,
	// What a compute-queue recording writes, marked with its serial when it is submitted.
	written_images:  [dynamic]^Vk_Image,
	written_buffers: [dynamic]^Vk_Buffer_Backing,
	stamp:           u64, // this recording's number, which tracked objects remember
	pools:           [dynamic]vk.DescriptorPool,
	pools_used:      int,
	blocks:          [dynamic]^Vk_Uniform_Block,
	blocks_used:     int,
	block_offset:    u32,
	uniforms:        [Vk_Stage][4]Vk_Uniform_Slot,
	buffers:         [dynamic]^Vk_Buffer_Backing,
	images:          [dynamic]^Vk_Image,
	samplers:        [dynamic]^Vk_Sampler,
	pipelines:       [dynamic]^Vk_Pipeline,
	presents:        [dynamic]Vk_Present,
	pass:            Vk_Pass,
	targets:         [dynamic]Vk_Target,
	pipeline:        ^Vk_Pipeline,
	vertex_storage:  [8]vk.Buffer,
	samplers_bound:  [16]Vk_Sampled, // the fragment stage's in a render pass, the compute stage's in a compute pass
	compute_storage: [8]vk.Buffer,   // read-only storage buffers
	write_textures:  [8]vk.ImageView,
	write_buffers:   [8]vk.Buffer,
	// The compute pass's texture array (gpu_bind_compute_texture_array), written into set 3
	// at the next dispatch; array_count 0 until one is bound.
	array_images:    [VK_TEXTURE_ARRAY_MAX]vk.DescriptorImageInfo,
	array_count:     u32,
	// The compute pass's top-level acceleration structure (gpu_bind_compute_accel), 0 until
	// one is bound.
	accel:           vk.AccelerationStructureKHR,
	accels:          [dynamic]^Vk_Accel,
	// The structures this graphics recording rewrites in place (a refit, a top level in its
	// old memory), each also in `accels`: its submission waits for any compute-queue work
	// still tracing against them (Vk_Accel.compute_read).
	accel_writes:    [dynamic]^Vk_Accel,
	sets:            [4]vk.DescriptorSet,
	set_dirty:       [4]bool,
	bind_dirty:      bool,
	timed_slot:      int, // 1 + the timestamp slot this recording wrote into, 0 for none (vk_timing.odin)
}

Vk_Fence :: struct {
	serial: u64,
	queue:  Vk_Queue,
}

@(private = "file")
vk_stamps: u64

// ---- Tracking -----------------------------------------------------------------------

vk_cmd_track_buffer :: proc(cmd: ^Vk_Cmd, b: ^Vk_Buffer_Backing) {
	if b.stamp == cmd.stamp do return
	b.stamp = cmd.stamp
	b.refs += 1
	append(&cmd.buffers, b)
}

vk_cmd_track_image :: proc(cmd: ^Vk_Cmd, img: ^Vk_Image) {
	if img.stamp == cmd.stamp do return
	img.stamp = cmd.stamp
	img.refs += 1
	append(&cmd.images, img)
}

@(private = "file")
vk_cmd_track_sampler :: proc(cmd: ^Vk_Cmd, s: ^Vk_Sampler) {
	if s.stamp == cmd.stamp do return
	s.stamp = cmd.stamp
	s.refs += 1
	append(&cmd.samplers, s)
}

@(private = "file")
vk_cmd_track_pipeline :: proc(cmd: ^Vk_Cmd, p: ^Vk_Pipeline) {
	if p.stamp == cmd.stamp do return
	p.stamp = cmd.stamp
	p.refs += 1
	append(&cmd.pipelines, p)
}

// ---- Barriers -----------------------------------------------------------------------

vk_image_barrier :: proc(cmd: ^Vk_Cmd, img: ^Vk_Image, old, new: vk.ImageLayout, level: u32 = 0, levels: u32 = vk.REMAINING_MIP_LEVELS) {
	barrier := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.ALL_COMMANDS},
		srcAccessMask       = {.MEMORY_WRITE} if old != .UNDEFINED else {},
		dstStageMask        = {.ALL_COMMANDS},
		dstAccessMask       = {.MEMORY_READ, .MEMORY_WRITE} if new != .PRESENT_SRC_KHR else {},
		oldLayout           = old,
		newLayout           = new,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = img.image,
		subresourceRange    = {aspectMask = img.owner.aspect, baseMipLevel = level, levelCount = levels, layerCount = 1},
	}
	info := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &barrier}
	vk.CmdPipelineBarrier2(cmd.cb, &info)
}

// Orders every earlier write before every later access: for buffers, which have no
// layouts to carry the ordering.
vk_memory_barrier :: proc(cmd: ^Vk_Cmd) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.ALL_COMMANDS},
		srcAccessMask = {.MEMORY_WRITE},
		dstStageMask  = {.ALL_COMMANDS},
		dstAccessMask = {.MEMORY_READ, .MEMORY_WRITE},
	}
	info := vk.DependencyInfo{sType = .DEPENDENCY_INFO, memoryBarrierCount = 1, pMemoryBarriers = &barrier}
	vk.CmdPipelineBarrier2(cmd.cb, &info)
}

// Moves a texture level from its default layout to `layout` for the current pass, cycling
// first when asked and the GPU may still read it; the pass moves it back when it ends.
@(private = "file")
vk_target :: proc(cmd: ^Vk_Cmd, t: ^Vk_Texture, level: u32, cycle: bool, layout: vk.ImageLayout) -> ^Vk_Image {
	if cycle && !t.swapchain && t.active.refs > 0 do vk_texture_cycle(t, cmd)
	img := t.active
	vk_cmd_track_image(cmd, img)
	vk_image_barrier(cmd, img, t.default_layout, layout, level, 1)
	append(&cmd.targets, Vk_Target{img, level, layout})
	return img
}

@(private = "file")
vk_targets_restore :: proc(cmd: ^Vk_Cmd) {
	for target in cmd.targets do vk_image_barrier(cmd, target.img, target.layout, target.img.owner.default_layout, target.level, 1)
	clear(&cmd.targets)
}

// ---- Command buffers ----------------------------------------------------------------

vk_cmd_free :: proc(cmd: ^Vk_Cmd) {
	for pool in cmd.pools do vk.DestroyDescriptorPool(vk_state.device, pool, nil)
	for block in cmd.blocks {
		vk.DestroyBuffer(vk_state.device, block.buffer, nil)
		vk.FreeMemory(vk_state.device, block.memory, nil)
		free(block)
	}
	vk.FreeCommandBuffers(vk_state.device, vk_state.command_pool, 1, &cmd.cb)
	delete(cmd.pools)
	delete(cmd.blocks)
	delete(cmd.buffers)
	delete(cmd.images)
	delete(cmd.samplers)
	delete(cmd.pipelines)
	delete(cmd.accels)
	delete(cmd.accel_writes)
	delete(cmd.presents)
	delete(cmd.targets)
	delete(cmd.written_images)
	delete(cmd.written_buffers)
	free(cmd)
}

// Lets go of everything a finished (or cancelled) command buffer used and makes it free
// for the next recording.
vk_cmd_recycle :: proc(cmd: ^Vk_Cmd) {
	for b in cmd.buffers {
		b.refs -= 1
		vk_buffer_reap(b.owner)
	}
	for img in cmd.images {
		img.refs -= 1
		vk_texture_reap(img.owner)
	}
	for s in cmd.samplers {
		s.refs -= 1
		vk_sampler_reap(s)
	}
	for p in cmd.pipelines {
		p.refs -= 1
		vk_pipeline_reap(p)
	}
	for a in cmd.accels {
		a.refs -= 1
		vk_accel_reap(a)
	}
	clear(&cmd.accels)
	clear(&cmd.accel_writes)
	clear(&cmd.buffers)
	clear(&cmd.images)
	clear(&cmd.samplers)
	clear(&cmd.pipelines)
	clear(&cmd.presents)
	clear(&cmd.targets)
	clear(&cmd.written_images)
	clear(&cmd.written_buffers)
	for pool in cmd.pools[:cmd.pools_used] do vk.ResetDescriptorPool(vk_state.device, pool, {})
	cmd.pools_used, cmd.blocks_used, cmd.block_offset = 0, 0, 0
	vk.ResetCommandBuffer(cmd.cb, {})
	append(&vk_state.free_cmds, cmd)
}

vk_acquire_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	vk_collect()
	cmd: ^Vk_Cmd
	if len(vk_state.free_cmds) > 0 {
		cmd = pop(&vk_state.free_cmds)
	} else {
		cmd = new(Vk_Cmd)
		info := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = vk_state.command_pool, level = .PRIMARY, commandBufferCount = 1}
		if vk.AllocateCommandBuffers(vk_state.device, &info, &cmd.cb) != .SUCCESS {
			free(cmd)
			sdl.SetError("vkAllocateCommandBuffers failed")
			return nil
		}
	}
	vk_stamps += 1
	cmd.stamp = vk_stamps
	cmd.serial = 0
	cmd.queue, cmd.compute_wait = .Graphics, 0
	cmd.timed_slot = 0
	cmd.pass = .None
	cmd.pipeline = nil
	cmd.uniforms = {}
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	if vk.BeginCommandBuffer(cmd.cb, &begin) != .SUCCESS {
		append(&vk_state.free_cmds, cmd)
		sdl.SetError("vkBeginCommandBuffer failed")
		return nil
	}
	return (^sdl.GPUCommandBuffer)(cmd)
}

// A command buffer for the compute queue (gpu_acquire_compute_command_buffer): compute
// passes only (vk_check_compute_writes knows their writes, not a copy's), submitted with
// vk_submit_compute.
vk_acquire_compute_command_buffer :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUCommandBuffer {
	cmd := (^Vk_Cmd)(vk_acquire_command_buffer(device))
	if cmd != nil do cmd.queue = .Compute
	return (^sdl.GPUCommandBuffer)(cmd)
}

// Makes the graphics command buffer wait, before any of its work, for the compute
// submission `fence` names, so it sees what that wrote.
vk_wait_on :: proc(command_buffer: ^sdl.GPUCommandBuffer, fence: ^sdl.GPUFence) {
	cmd, f := (^Vk_Cmd)(command_buffer), (^Vk_Fence)(fence)
	if cmd.queue == .Graphics && f.queue == .Compute do cmd.compute_wait = max(cmd.compute_wait, f.serial)
}

// The command buffer that moves new textures into their default layouts, opened when the
// first one since the last submission is made.
vk_setup_cmd :: proc() -> ^Vk_Cmd {
	if vk_state.setup == nil do vk_state.setup = (^Vk_Cmd)(vk_acquire_command_buffer(vk_device_handle()))
	return vk_state.setup
}

@(private = "file")
vk_submit :: proc(cmd: ^Vk_Cmd) -> (u64, bool) {
	if cmd.pass != .None {
		sdl.SetError("submitted inside a pass")
		return 0, false
	}
	if cmd.queue == .Compute do return vk_submit_compute(cmd)
	// A band of render mode on the compute queue may still be tracing against a bottom
	// level the studio refits here: this waits for it, which stalls nothing once it is done.
	for a in cmd.accel_writes do cmd.compute_wait = max(cmd.compute_wait, a.compute_read)
	if vk_state.validation do vk_check_compute_writes(cmd)
	vk_compute_waited = max(vk_compute_waited, cmd.compute_wait)
	for p in cmd.presents {
		t := p.window.textures[p.image]
		vk_image_barrier(cmd, t.active, .COLOR_ATTACHMENT_OPTIMAL, .PRESENT_SRC_KHR)
	}
	if vk.EndCommandBuffer(cmd.cb) != .SUCCESS {
		sdl.SetError("vkEndCommandBuffer failed")
		return 0, false
	}
	setup := vk_state.setup
	vk_state.setup = nil
	if setup != nil && setup != cmd && vk.EndCommandBuffer(setup.cb) != .SUCCESS {
		sdl.SetError("vkEndCommandBuffer failed")
		return 0, false
	}
	vk_state.submitted += 1
	serial := vk_state.submitted
	buffers: [2]vk.CommandBufferSubmitInfo
	n: u32
	if setup != nil && setup != cmd {
		buffers[n] = {sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = setup.cb}
		n += 1
	}
	buffers[n] = {sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cmd.cb}
	n += 1
	waits := make([dynamic]vk.SemaphoreSubmitInfo, 0, len(cmd.presents) + 1, context.temp_allocator)
	signals := make([]vk.SemaphoreSubmitInfo, len(cmd.presents) + 1, context.temp_allocator)
	signals[0] = {sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vk_state.timeline, value = serial, stageMask = {.ALL_COMMANDS}}
	for p, i in cmd.presents {
		append(&waits, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = p.window.acquired[p.frame], stageMask = {.ALL_COMMANDS}})
		signals[i + 1] = {sType = .SEMAPHORE_SUBMIT_INFO, semaphore = p.window.render_done[p.image], stageMask = {.ALL_COMMANDS}}
	}
	// At every stage: what the compute queue wrote may be read by any shader here.
	if cmd.compute_wait > 0 do append(&waits, vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vk_state.compute_timeline, value = cmd.compute_wait, stageMask = {.ALL_COMMANDS}})
	submit := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = u32(len(waits)),
		pWaitSemaphoreInfos      = raw_data(waits),
		commandBufferInfoCount   = n,
		pCommandBufferInfos      = &buffers[0],
		signalSemaphoreInfoCount = u32(len(signals)),
		pSignalSemaphoreInfos    = raw_data(signals),
	}
	if r := vk.QueueSubmit2(vk_state.queue, 1, &submit, 0); r != .SUCCESS {
		log.errorf("Vulkan: vkQueueSubmit2 failed: %v", r)
		sdl.SetError("vkQueueSubmit2 failed")
		return 0, false
	}
	vk_timing_submitted(cmd, serial)
	for p in cmd.presents {
		p.window.frame_serial[p.frame] = serial
		vk_present(p)
	}
	cmd.serial = serial
	append(&vk_state.in_flight, cmd)
	if setup != nil && setup != cmd {
		setup.serial = serial
		append(&vk_state.in_flight, setup)
	}
	vk_collect()
	return serial, true
}

// The highest compute serial a graphics submission has waited for. Every later graphics
// submission runs after that one, so it sees the same compute work.
@(private = "file")
vk_compute_waited: u64

// Submits a compute-queue command buffer: it waits for every graphics submission so far
// (so for anything they wrote, or read that it now writes) and signals the compute
// timeline. A pending setup buffer goes first on the graphics queue, which it then waits
// for too, since the graphics queue may use those textures before the compute queue runs.
@(private = "file")
vk_submit_compute :: proc(cmd: ^Vk_Cmd) -> (u64, bool) {
	if len(cmd.presents) > 0 || len(cmd.targets) > 0 {
		sdl.SetError("a compute-queue command buffer holds compute passes only")
		return 0, false
	}
	if setup := vk_state.setup; setup != nil {
		if _, ok := vk_submit(setup); !ok do return 0, false
	}
	if vk.EndCommandBuffer(cmd.cb) != .SUCCESS {
		sdl.SetError("vkEndCommandBuffer failed")
		return 0, false
	}
	vk_state.compute_submitted += 1
	serial := vk_state.compute_submitted
	buffer := vk.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cmd.cb}
	wait := vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vk_state.timeline, value = vk_state.submitted, stageMask = {.ALL_COMMANDS}}
	signal := vk.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vk_state.compute_timeline, value = serial, stageMask = {.ALL_COMMANDS}}
	submit := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1 if vk_state.submitted > 0 else 0,
		pWaitSemaphoreInfos      = &wait,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &buffer,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal,
	}
	if r := vk.QueueSubmit2(vk_state.compute_queue, 1, &submit, 0); r != .SUCCESS {
		log.errorf("Vulkan: vkQueueSubmit2 (compute) failed: %v", r)
		sdl.SetError("vkQueueSubmit2 failed")
		return 0, false
	}
	for img in cmd.written_images do img.compute_write = serial
	for b in cmd.written_buffers do b.compute_write = serial
	for a in cmd.accels do a.compute_read = max(a.compute_read, serial)
	cmd.serial = serial
	append(&vk_state.in_flight, cmd)
	vk_collect()
	return serial, true
}

// Under --gpu-debug: a graphics submission that uses an image or buffer the compute queue
// wrote, without waiting for that write (gpu_wait_on, here or in an earlier submission),
// would read it before it is written, or before it is visible. One queue runs the two in
// order anyway, so the validation layer cannot see this there; this check can.
@(private = "file")
vk_check_compute_writes :: proc(cmd: ^Vk_Cmd) {
	waited := max(vk_compute_waited, cmd.compute_wait)
	for img in cmd.images do if img.compute_write > waited {
		vk_validation_error("a graphics submission uses an image (%s) that compute submission %d writes, without waiting for it", img.owner.name if img.owner.name != nil else "unnamed", img.compute_write)
	}
	for b in cmd.buffers do if b.compute_write > waited {
		vk_validation_error("a graphics submission uses a buffer that compute submission %d writes, without waiting for it", b.compute_write)
	}
}

vk_submit_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	_, ok := vk_submit((^Vk_Cmd)(command_buffer))
	return ok
}

vk_submit_command_buffer_and_acquire_fence :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUFence {
	serial, ok := vk_submit((^Vk_Cmd)(command_buffer))
	if !ok do return nil
	fence := new(Vk_Fence)
	fence.serial, fence.queue = serial, (^Vk_Cmd)(command_buffer).queue
	return (^sdl.GPUFence)(fence)
}

vk_cancel_command_buffer :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> bool {
	cmd := (^Vk_Cmd)(command_buffer)
	if len(cmd.presents) > 0 {
		sdl.SetError("a command buffer holding a swapchain texture cannot be cancelled")
		return false
	}
	_ = vk.EndCommandBuffer(cmd.cb)
	vk_cmd_recycle(cmd)
	return true
}

vk_query_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) -> bool {
	vk_collect()
	f := (^Vk_Fence)(fence)
	return vk_serial_done(f.queue, f.serial)
}

vk_wait_for_fences :: proc(device: ^sdl.GPUDevice, wait_all: bool, fences: [^]^sdl.GPUFence, num_fences: u32) -> bool {
	if num_fences == 0 do return true
	// Each queue's submissions finish in order, so all of a queue's fences are done when its
	// latest is, and any one when its earliest is; one wait then covers both timelines.
	values: [Vk_Queue]u64
	used: [Vk_Queue]bool
	for i in 0 ..< num_fences {
		f := (^Vk_Fence)(fences[i])
		values[f.queue] = (max(values[f.queue], f.serial) if wait_all else min(values[f.queue], f.serial)) if used[f.queue] else f.serial
		used[f.queue] = true
	}
	semaphores: [2]vk.Semaphore
	wanted: [2]u64
	n: u32
	for q in Vk_Queue do if used[q] {
		semaphores[n], wanted[n] = vk_state.timeline if q == .Graphics else vk_state.compute_timeline, values[q]
		n += 1
	}
	info := vk.SemaphoreWaitInfo{sType = .SEMAPHORE_WAIT_INFO, flags = {} if wait_all else {.ANY}, semaphoreCount = n, pSemaphores = &semaphores[0], pValues = &wanted[0]}
	ok := vk.WaitSemaphores(vk_state.device, &info, max(u64)) == .SUCCESS
	vk_collect()
	return ok
}

vk_release_fence :: proc(device: ^sdl.GPUDevice, fence: ^sdl.GPUFence) {
	free((^Vk_Fence)(fence))
}

// ---- Descriptors and uniforms -------------------------------------------------------

// A set from the command buffer's pools, `variable` the element count of a texture array
// set (0 for any other). A pool made fresh that cannot hold the set fails it rather than
// making pool after pool.
@(private = "file")
vk_descriptor_set :: proc(cmd: ^Vk_Cmd, layout: vk.DescriptorSetLayout, variable: u32 = 0) -> vk.DescriptorSet {
	layout := layout
	variable := variable
	counts := vk.DescriptorSetVariableDescriptorCountAllocateInfo{sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO, descriptorSetCount = 1, pDescriptorCounts = &variable}
	for {
		fresh := cmd.pools_used == len(cmd.pools)
		if fresh {
			// Acceleration structures only where the extension is on, which a pool size of
			// that type needs.
			sizes := [?]vk.DescriptorPoolSize {
				{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1024},
				{type = .SAMPLED_IMAGE, descriptorCount = 256},
				{type = .STORAGE_IMAGE, descriptorCount = 256},
				{type = .STORAGE_BUFFER, descriptorCount = 1024},
				{type = .UNIFORM_BUFFER_DYNAMIC, descriptorCount = 1024},
				{type = .ACCELERATION_STRUCTURE_KHR, descriptorCount = 64},
			}
			info := vk.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, maxSets = 512, poolSizeCount = len(sizes) if vk_state.ray_query else len(sizes) - 1, pPoolSizes = &sizes[0]}
			pool: vk.DescriptorPool
			if vk.CreateDescriptorPool(vk_state.device, &info, nil, &pool) != .SUCCESS do return 0
			append(&cmd.pools, pool)
		}
		info := vk.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = cmd.pools[cmd.pools_used], descriptorSetCount = 1, pSetLayouts = &layout}
		if variable > 0 do info.pNext = &counts
		set: vk.DescriptorSet
		r := vk.AllocateDescriptorSets(vk_state.device, &info, &set)
		if r == .SUCCESS do return set
		if fresh || (r != .ERROR_OUT_OF_POOL_MEMORY && r != .ERROR_FRAGMENTED_POOL) do return 0
		cmd.pools_used += 1
	}
}

// Room for one more uniform block in the command buffer's arena.
@(private = "file")
vk_uniform_space :: proc(cmd: ^Vk_Cmd, size: u32) -> (^Vk_Uniform_Block, u32) {
	align := u32(vk_state.properties.limits.minUniformBufferOffsetAlignment)
	offset := (cmd.block_offset + align - 1) / align * align
	if cmd.blocks_used == 0 || offset + VK_UNIFORM_RANGE > VK_UNIFORM_BLOCK {
		if cmd.blocks_used == len(cmd.blocks) {
			block := new(Vk_Uniform_Block)
			info := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = VK_UNIFORM_BLOCK, usage = {.UNIFORM_BUFFER}, sharingMode = .EXCLUSIVE}
			if vk.CreateBuffer(vk_state.device, &info, nil, &block.buffer) != .SUCCESS {
				free(block)
				return nil, 0
			}
			reqs: vk.MemoryRequirements
			vk.GetBufferMemoryRequirements(vk_state.device, block.buffer, &reqs)
			ok: bool
			block.memory, ok = vk_allocate(reqs, {.HOST_VISIBLE, .HOST_COHERENT}, {.DEVICE_LOCAL})
			data: rawptr
			if !ok || vk.BindBufferMemory(vk_state.device, block.buffer, block.memory, 0) != .SUCCESS || vk.MapMemory(vk_state.device, block.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &data) != .SUCCESS {
				vk.DestroyBuffer(vk_state.device, block.buffer, nil)
				if block.memory != 0 do vk.FreeMemory(vk_state.device, block.memory, nil)
				free(block)
				return nil, 0
			}
			block.mapped = ([^]u8)(data)
			append(&cmd.blocks, block)
		}
		cmd.blocks_used += 1
		offset = 0
	}
	cmd.block_offset = offset + size
	return cmd.blocks[cmd.blocks_used - 1], offset
}

@(private = "file")
VK_UNIFORM_SET := [Vk_Stage]int {
	.Vertex   = 1,
	.Fragment = 3,
	.Compute  = 2,
}

@(private = "file")
vk_push_uniform :: proc(cmd: ^Vk_Cmd, stage: Vk_Stage, slot: u32, data: rawptr, length: u32) {
	if length > VK_UNIFORM_RANGE || slot >= 4 {
		log.errorf("Vulkan: a %d byte uniform block in slot %d does not fit", length, slot)
		return
	}
	block, offset := vk_uniform_space(cmd, length)
	if block == nil do return
	mem.copy(block.mapped[offset:], data, int(length))
	if cmd.uniforms[stage][slot].block != block do cmd.set_dirty[VK_UNIFORM_SET[stage]] = true
	cmd.uniforms[stage][slot] = {block, offset}
	cmd.bind_dirty = true
}

vk_push_vertex_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: u32, data: rawptr, length: u32) {
	vk_push_uniform((^Vk_Cmd)(command_buffer), .Vertex, slot_index, data, length)
}

vk_push_fragment_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: u32, data: rawptr, length: u32) {
	vk_push_uniform((^Vk_Cmd)(command_buffer), .Fragment, slot_index, data, length)
}

vk_push_compute_uniform_data :: proc(command_buffer: ^sdl.GPUCommandBuffer, slot_index: u32, data: rawptr, length: u32) {
	vk_push_uniform((^Vk_Cmd)(command_buffer), .Compute, slot_index, data, length)
}

// A descriptor set of uniform blocks for `stage`'s first `count` slots; a slot nothing was
// pushed to reads whatever its block holds, as in SDL_GPU.
@(private = "file")
vk_uniform_set :: proc(cmd: ^Vk_Cmd, layout: vk.DescriptorSetLayout, stage: Vk_Stage, count: u32) -> vk.DescriptorSet {
	set := vk_descriptor_set(cmd, layout)
	if set == 0 do return 0
	infos: [4]vk.DescriptorBufferInfo
	writes: [4]vk.WriteDescriptorSet
	for i in 0 ..< count {
		slot := &cmd.uniforms[stage][i]
		if slot.block == nil do slot.block, slot.offset = vk_uniform_space(cmd, 0)
		if slot.block == nil do return 0
		infos[i] = {buffer = slot.block.buffer, range = VK_UNIFORM_RANGE}
		writes[i] = {sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = i, descriptorCount = 1, descriptorType = .UNIFORM_BUFFER_DYNAMIC, pBufferInfo = &infos[i]}
	}
	if count > 0 do vk.UpdateDescriptorSets(vk_state.device, count, &writes[0], 0, nil)
	return set
}

Vk_Set_Writer :: struct {
	writes: [32]vk.WriteDescriptorSet,
	images: [32]vk.DescriptorImageInfo,
	buffers: [32]vk.DescriptorBufferInfo,
	n: u32,
}

@(private = "file")
vk_write_image :: proc(w: ^Vk_Set_Writer, set: vk.DescriptorSet, binding: u32, type: vk.DescriptorType, view: vk.ImageView, sampler: vk.Sampler, layout: vk.ImageLayout) {
	w.images[w.n] = {sampler = sampler, imageView = view, imageLayout = layout}
	w.writes[w.n] = {sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = binding, descriptorCount = 1, descriptorType = type, pImageInfo = &w.images[w.n]}
	w.n += 1
}

@(private = "file")
vk_write_buffer :: proc(w: ^Vk_Set_Writer, set: vk.DescriptorSet, binding: u32, buffer: vk.Buffer) {
	w.buffers[w.n] = {buffer = buffer, range = vk.DeviceSize(vk.WHOLE_SIZE)}
	w.writes[w.n] = {sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = binding, descriptorCount = 1, descriptorType = .STORAGE_BUFFER, pBufferInfo = &w.buffers[w.n]}
	w.n += 1
}

@(private = "file")
vk_write_flush :: proc(w: ^Vk_Set_Writer) {
	if w.n > 0 do vk.UpdateDescriptorSets(vk_state.device, w.n, &w.writes[0], 0, nil)
	w.n = 0
}

// Brings the bound descriptor sets up to date before a draw or a dispatch.
@(private = "file")
vk_bind_sets :: proc(cmd: ^Vk_Cmd) -> bool {
	p := cmd.pipeline
	if p == nil do return false
	if !cmd.bind_dirty && !cmd.set_dirty[0] && !cmd.set_dirty[1] && !cmd.set_dirty[2] && !cmd.set_dirty[3] do return true
	l := p.layout
	c := l.counts
	w: Vk_Set_Writer
	offsets: [8]u32
	n_offsets: u32
	if !p.compute {
		if cmd.set_dirty[0] {
			cmd.sets[0] = vk_descriptor_set(cmd, l.sets[0])
			for i in 0 ..< c[2] do vk_write_buffer(&w, cmd.sets[0], c[0] + c[1] + i, cmd.vertex_storage[i])
		}
		if cmd.set_dirty[1] do cmd.sets[1] = vk_uniform_set(cmd, l.sets[1], .Vertex, c[3])
		if cmd.set_dirty[2] {
			cmd.sets[2] = vk_descriptor_set(cmd, l.sets[2])
			for i in 0 ..< c[4] do vk_write_image(&w, cmd.sets[2], i, .COMBINED_IMAGE_SAMPLER, cmd.samplers_bound[i].view, cmd.samplers_bound[i].sampler, .SHADER_READ_ONLY_OPTIMAL)
		}
		if cmd.set_dirty[3] do cmd.sets[3] = vk_uniform_set(cmd, l.sets[3], .Fragment, c[7])
		for i in 0 ..< c[3] {
			offsets[n_offsets] = cmd.uniforms[.Vertex][i].offset
			n_offsets += 1
		}
		for i in 0 ..< c[7] {
			offsets[n_offsets] = cmd.uniforms[.Fragment][i].offset
			n_offsets += 1
		}
	} else {
		if cmd.set_dirty[0] {
			cmd.sets[0] = vk_descriptor_set(cmd, l.sets[0])
			for i in 0 ..< c[0] do vk_write_image(&w, cmd.sets[0], i, .COMBINED_IMAGE_SAMPLER, cmd.samplers_bound[i].view, cmd.samplers_bound[i].sampler, .SHADER_READ_ONLY_OPTIMAL)
			for i in 0 ..< c[2] do vk_write_buffer(&w, cmd.sets[0], c[0] + c[1] + i, cmd.compute_storage[i])
		}
		if cmd.set_dirty[1] {
			cmd.sets[1] = vk_descriptor_set(cmd, l.sets[1])
			for i in 0 ..< c[3] do vk_write_image(&w, cmd.sets[1], i, .STORAGE_IMAGE, cmd.write_textures[i], 0, .GENERAL)
			for i in 0 ..< c[4] do vk_write_buffer(&w, cmd.sets[1], c[3] + i, cmd.write_buffers[i])
		}
		if cmd.set_dirty[2] do cmd.sets[2] = vk_uniform_set(cmd, l.sets[2], .Compute, c[5])
		if cmd.set_dirty[3] && l.sets[3] != 0 {
			// A kernel with an array or an acceleration structure reads it, so a dispatch
			// with either missing is refused. The structure is binding 0, the array after it.
			array, accel := c[6] > 0, c[7] > 0
			cmd.sets[3] = 0
			if (!array || cmd.array_count > 0) && (!accel || cmd.accel != 0) do cmd.sets[3] = vk_descriptor_set(cmd, l.sets[3], cmd.array_count if array else 0)
			if cmd.sets[3] != 0 {
				writes: [2]vk.WriteDescriptorSet
				n: u32
				structure := vk.WriteDescriptorSetAccelerationStructureKHR{sType = .WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR, accelerationStructureCount = 1, pAccelerationStructures = &cmd.accel}
				if accel {
					writes[n] = {sType = .WRITE_DESCRIPTOR_SET, pNext = &structure, dstSet = cmd.sets[3], dstBinding = n, descriptorCount = 1, descriptorType = .ACCELERATION_STRUCTURE_KHR}
					n += 1
				}
				if array {
					writes[n] = {sType = .WRITE_DESCRIPTOR_SET, dstSet = cmd.sets[3], dstBinding = n, descriptorCount = cmd.array_count, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &cmd.array_images[0]}
					n += 1
				}
				vk.UpdateDescriptorSets(vk_state.device, n, &writes[0], 0, nil)
			}
		}
		for i in 0 ..< c[5] {
			offsets[n_offsets] = cmd.uniforms[.Compute][i].offset
			n_offsets += 1
		}
	}
	vk_write_flush(&w)
	set_count: u32 = 4 if !p.compute || l.sets[3] != 0 else 3
	for s in cmd.sets[:set_count] do if s == 0 {
		log.error("Vulkan: a descriptor set could not be allocated")
		return false
	}
	vk.CmdBindDescriptorSets(cmd.cb, .COMPUTE if p.compute else .GRAPHICS, l.layout, 0, set_count, &cmd.sets[0], n_offsets, &offsets[0])
	cmd.set_dirty = {}
	cmd.bind_dirty = false
	return true
}

// ---- Render passes ------------------------------------------------------------------

vk_begin_render_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, color_target_infos: [^]sdl.GPUColorTargetInfo, num_color_targets: u32, depth_stencil_target_info: Maybe(^sdl.GPUDepthStencilTargetInfo)) -> ^sdl.GPURenderPass {
	cmd := (^Vk_Cmd)(command_buffer)
	width, height := max(u32), max(u32)
	colors: [8]vk.RenderingAttachmentInfo
	vk_memory_barrier(cmd)
	for i in 0 ..< num_color_targets {
		info := color_target_infos[i]
		t := (^Vk_Texture)(info.texture)
		width, height = min(width, max(t.info.width >> info.mip_level, 1)), min(height, max(t.info.height >> info.mip_level, 1))
		img := vk_target(cmd, t, info.mip_level, info.cycle, .COLOR_ATTACHMENT_OPTIMAL)
		c := &colors[i]
		c^ = {
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = img.level_views[info.mip_level],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp      = vk_load_op(info.load_op),
			storeOp     = .STORE if info.store_op == .STORE || info.store_op == .RESOLVE_AND_STORE else .DONT_CARE,
		}
		c.clearValue.color.float32 = {info.clear_color.r, info.clear_color.g, info.clear_color.b, info.clear_color.a}
		if info.store_op == .RESOLVE || info.store_op == .RESOLVE_AND_STORE {
			rt := (^Vk_Texture)(info.resolve_texture)
			resolve := vk_target(cmd, rt, info.resolve_mip_level, info.cycle_resolve_texture, .COLOR_ATTACHMENT_OPTIMAL)
			c.resolveMode = {.AVERAGE}
			c.resolveImageView = resolve.level_views[info.resolve_mip_level]
			c.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
		}
	}
	depth: vk.RenderingAttachmentInfo
	stencil: vk.RenderingAttachmentInfo
	has_depth, has_stencil := false, false
	if d, ok := depth_stencil_target_info.?; ok && d != nil {
		t := (^Vk_Texture)(d.texture)
		level := u32(d.mip_level)
		width, height = min(width, max(t.info.width >> level, 1)), min(height, max(t.info.height >> level, 1))
		img := vk_target(cmd, t, level, d.cycle, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		depth = {
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = img.level_views[level],
			imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
			loadOp      = vk_load_op(d.load_op),
			storeOp     = .STORE if d.store_op == .STORE else .DONT_CARE,
		}
		depth.clearValue.depthStencil = {depth = d.clear_depth, stencil = u32(d.clear_stencil)}
		has_depth = true
		if .STENCIL in t.aspect {
			stencil = depth
			stencil.loadOp = vk_load_op(d.stencil_load_op)
			stencil.storeOp = .STORE if d.stencil_store_op == .STORE else .DONT_CARE
			has_stencil = true
		}
	}
	info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = {extent = {width, height}},
		layerCount           = 1,
		colorAttachmentCount = num_color_targets,
		pColorAttachments    = &colors[0],
		pDepthAttachment     = &depth if has_depth else nil,
		pStencilAttachment   = &stencil if has_stencil else nil,
	}
	vk.CmdBeginRendering(cmd.cb, &info)
	// SDL_GPU flips the viewport so clip space points up, as on its other backends.
	viewport := vk.Viewport{x = 0, y = f32(height), width = f32(width), height = -f32(height), minDepth = 0, maxDepth = 1}
	vk.CmdSetViewport(cmd.cb, 0, 1, &viewport)
	scissor := vk.Rect2D{extent = {width, height}}
	vk.CmdSetScissor(cmd.cb, 0, 1, &scissor)
	cmd.pass = .Render
	cmd.pipeline = nil
	cmd.vertex_storage = {}
	cmd.samplers_bound = {}
	return (^sdl.GPURenderPass)(cmd)
}

@(private = "file")
vk_load_op :: proc(op: sdl.GPULoadOp) -> vk.AttachmentLoadOp {
	switch op {
	case .LOAD:      return .LOAD
	case .CLEAR:     return .CLEAR
	case .DONT_CARE: return .DONT_CARE
	}
	return .LOAD
}

vk_end_render_pass :: proc(render_pass: ^sdl.GPURenderPass) {
	cmd := (^Vk_Cmd)(render_pass)
	vk.CmdEndRendering(cmd.cb)
	vk_targets_restore(cmd)
	vk_memory_barrier(cmd)
	cmd.pass = .None
	cmd.pipeline = nil
}

vk_bind_graphics_pipeline :: proc(render_pass: ^sdl.GPURenderPass, graphics_pipeline: ^sdl.GPUGraphicsPipeline) {
	cmd := (^Vk_Cmd)(render_pass)
	p := (^Vk_Pipeline)(graphics_pipeline)
	vk.CmdBindPipeline(cmd.cb, .GRAPHICS, p.pipeline)
	vk_cmd_track_pipeline(cmd, p)
	cmd.pipeline = p
	cmd.set_dirty = {true, true, true, true}
}

vk_bind_vertex_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: u32, bindings: [^]sdl.GPUBufferBinding, num_bindings: u32) {
	cmd := (^Vk_Cmd)(render_pass)
	buffers: [16]vk.Buffer
	offsets: [16]vk.DeviceSize
	for i in 0 ..< num_bindings {
		b := (^Vk_Buffer)(bindings[i].buffer).active
		vk_cmd_track_buffer(cmd, b)
		buffers[i], offsets[i] = b.buffer, vk.DeviceSize(bindings[i].offset)
	}
	vk.CmdBindVertexBuffers(cmd.cb, first_slot, num_bindings, &buffers[0], &offsets[0])
}

vk_bind_index_buffer :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr binding: sdl.GPUBufferBinding, index_element_size: sdl.GPUIndexElementSize) {
	cmd := (^Vk_Cmd)(render_pass)
	b := (^Vk_Buffer)(binding.buffer).active
	vk_cmd_track_buffer(cmd, b)
	vk.CmdBindIndexBuffer(cmd.cb, b.buffer, vk.DeviceSize(binding.offset), .UINT32 if index_element_size == ._32BIT else .UINT16)
}

vk_bind_vertex_storage_buffers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: u32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: u32) {
	cmd := (^Vk_Cmd)(render_pass)
	for i in 0 ..< num_bindings {
		b := (^Vk_Buffer)(storage_buffers[i]).active
		vk_cmd_track_buffer(cmd, b)
		cmd.vertex_storage[first_slot + i] = b.buffer
	}
	cmd.set_dirty[0] = true
}

@(private = "file")
vk_bind_samplers :: proc(cmd: ^Vk_Cmd, first_slot: u32, bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: u32) {
	for i in 0 ..< num_bindings {
		t := (^Vk_Texture)(bindings[i].texture)
		s := (^Vk_Sampler)(bindings[i].sampler)
		vk_cmd_track_image(cmd, t.active)
		vk_cmd_track_sampler(cmd, s)
		cmd.samplers_bound[first_slot + i] = {t.active.view, s.sampler}
	}
}

vk_bind_fragment_samplers :: proc(render_pass: ^sdl.GPURenderPass, first_slot: u32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: u32) {
	cmd := (^Vk_Cmd)(render_pass)
	vk_bind_samplers(cmd, first_slot, texture_sampler_bindings, num_bindings)
	cmd.set_dirty[2] = true
}

vk_set_scissor :: proc(render_pass: ^sdl.GPURenderPass, #by_ptr scissor: sdl.Rect) {
	cmd := (^Vk_Cmd)(render_pass)
	rect := vk.Rect2D{offset = {scissor.x, scissor.y}, extent = {u32(max(scissor.w, 0)), u32(max(scissor.h, 0))}}
	vk.CmdSetScissor(cmd.cb, 0, 1, &rect)
}

vk_draw_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_vertices, num_instances, first_vertex, first_instance: u32) {
	cmd := (^Vk_Cmd)(render_pass)
	if !vk_bind_sets(cmd) do return
	vk.CmdDraw(cmd.cb, num_vertices, num_instances, first_vertex, first_instance)
}

vk_draw_indexed_primitives :: proc(render_pass: ^sdl.GPURenderPass, num_indices, num_instances, first_index: u32, vertex_offset: i32, first_instance: u32) {
	cmd := (^Vk_Cmd)(render_pass)
	if !vk_bind_sets(cmd) do return
	vk.CmdDrawIndexed(cmd.cb, num_indices, num_instances, first_index, vertex_offset, first_instance)
}

vk_draw_indexed_primitives_indirect :: proc(render_pass: ^sdl.GPURenderPass, buffer: ^sdl.GPUBuffer, offset: u32, draw_count: u32) {
	cmd := (^Vk_Cmd)(render_pass)
	if !vk_bind_sets(cmd) do return
	b := (^Vk_Buffer)(buffer).active
	vk_cmd_track_buffer(cmd, b)
	stride :: u32(size_of(sdl.GPUIndexedIndirectDrawCommand))
	if vk_state.multi_draw || draw_count <= 1 {
		vk.CmdDrawIndexedIndirect(cmd.cb, b.buffer, vk.DeviceSize(offset), draw_count, stride)
	} else {
		for i in 0 ..< draw_count do vk.CmdDrawIndexedIndirect(cmd.cb, b.buffer, vk.DeviceSize(offset + i * stride), 1, stride)
	}
}

// Draws up to `max_draws` commands from `offset`, as many as the u32 at `count_offset` of
// `count_buffer` says when the GPU runs it (vk_state.indirect_count).
vk_draw_indexed_primitives_indirect_count :: proc(render_pass: ^sdl.GPURenderPass, buffer: ^sdl.GPUBuffer, offset: u32, count_buffer: ^sdl.GPUBuffer, count_offset: u32, max_draws: u32) {
	cmd := (^Vk_Cmd)(render_pass)
	if !vk_bind_sets(cmd) do return
	b, n := (^Vk_Buffer)(buffer).active, (^Vk_Buffer)(count_buffer).active
	vk_cmd_track_buffer(cmd, b)
	vk_cmd_track_buffer(cmd, n)
	vk.CmdDrawIndexedIndirectCount(cmd.cb, b.buffer, vk.DeviceSize(offset), n.buffer, vk.DeviceSize(count_offset), max_draws, size_of(sdl.GPUIndexedIndirectDrawCommand))
}

// ---- Compute passes -----------------------------------------------------------------

vk_begin_compute_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer, storage_texture_bindings: [^]sdl.GPUStorageTextureReadWriteBinding, num_storage_texture_bindings: u32, storage_buffer_bindings: [^]sdl.GPUStorageBufferReadWriteBinding, num_storage_buffer_bindings: u32) -> ^sdl.GPUComputePass {
	cmd := (^Vk_Cmd)(command_buffer)
	vk_memory_barrier(cmd)
	cmd.write_textures = {}
	cmd.write_buffers = {}
	for i in 0 ..< num_storage_texture_bindings {
		binding := storage_texture_bindings[i]
		img := vk_target(cmd, (^Vk_Texture)(binding.texture), binding.mip_level, binding.cycle, .GENERAL)
		cmd.write_textures[i] = img.level_views[binding.mip_level]
		if cmd.queue == .Compute do append(&cmd.written_images, img)
	}
	for i in 0 ..< num_storage_buffer_bindings {
		binding := storage_buffer_bindings[i]
		b := (^Vk_Buffer)(binding.buffer)
		if binding.cycle && b.active.refs > 0 do vk_buffer_cycle(b)
		vk_cmd_track_buffer(cmd, b.active)
		cmd.write_buffers[i] = b.active.buffer
		if cmd.queue == .Compute do append(&cmd.written_buffers, b.active)
	}
	cmd.pass = .Compute
	cmd.pipeline = nil
	cmd.samplers_bound = {}
	cmd.compute_storage = {}
	// A render pass leaves its fragment uniforms in sets[3], which a kernel with an array
	// must never take for its own.
	cmd.sets[3], cmd.array_count, cmd.accel = 0, 0, 0
	return (^sdl.GPUComputePass)(cmd)
}

vk_bind_compute_pipeline :: proc(compute_pass: ^sdl.GPUComputePass, compute_pipeline: ^sdl.GPUComputePipeline) {
	cmd := (^Vk_Cmd)(compute_pass)
	p := (^Vk_Pipeline)(compute_pipeline)
	vk.CmdBindPipeline(cmd.cb, .COMPUTE, p.pipeline)
	vk_cmd_track_pipeline(cmd, p)
	cmd.pipeline = p
	cmd.set_dirty = {true, true, true, p.layout.sets[3] != 0}
}

vk_bind_compute_samplers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: u32, texture_sampler_bindings: [^]sdl.GPUTextureSamplerBinding, num_bindings: u32) {
	cmd := (^Vk_Cmd)(compute_pass)
	vk_bind_samplers(cmd, first_slot, texture_sampler_bindings, num_bindings)
	cmd.set_dirty[0] = true
}

// The textures a kernel's array holds this dispatch on, in order; the count is the set's.
vk_bind_compute_texture_array :: proc(compute_pass: ^sdl.GPUComputePass, bindings: []sdl.GPUTextureSamplerBinding) {
	cmd := (^Vk_Cmd)(compute_pass)
	n := min(len(bindings), VK_TEXTURE_ARRAY_MAX)
	for b, i in bindings[:n] {
		t := (^Vk_Texture)(b.texture)
		s := (^Vk_Sampler)(b.sampler)
		vk_cmd_track_image(cmd, t.active)
		vk_cmd_track_sampler(cmd, s)
		cmd.array_images[i] = {sampler = s.sampler, imageView = t.active.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	}
	cmd.array_count = u32(n)
	cmd.set_dirty[3] = true
}

vk_bind_compute_storage_buffers :: proc(compute_pass: ^sdl.GPUComputePass, first_slot: u32, storage_buffers: [^]^sdl.GPUBuffer, num_bindings: u32) {
	cmd := (^Vk_Cmd)(compute_pass)
	for i in 0 ..< num_bindings {
		b := (^Vk_Buffer)(storage_buffers[i]).active
		vk_cmd_track_buffer(cmd, b)
		cmd.compute_storage[first_slot + i] = b.buffer
	}
	cmd.set_dirty[0] = true
}

vk_dispatch_compute :: proc(compute_pass: ^sdl.GPUComputePass, groupcount_x, groupcount_y, groupcount_z: u32) {
	cmd := (^Vk_Cmd)(compute_pass)
	if !vk_bind_sets(cmd) do return
	vk.CmdDispatch(cmd.cb, groupcount_x, groupcount_y, groupcount_z)
	// Each dispatch sees what the one before wrote.
	vk_memory_barrier(cmd)
}

vk_end_compute_pass :: proc(compute_pass: ^sdl.GPUComputePass) {
	cmd := (^Vk_Cmd)(compute_pass)
	vk_targets_restore(cmd)
	vk_memory_barrier(cmd)
	cmd.pass = .None
	cmd.pipeline = nil
}

// ---- Copy passes --------------------------------------------------------------------

vk_begin_copy_pass :: proc(command_buffer: ^sdl.GPUCommandBuffer) -> ^sdl.GPUCopyPass {
	cmd := (^Vk_Cmd)(command_buffer)
	cmd.pass = .Copy
	return (^sdl.GPUCopyPass)(cmd)
}

vk_end_copy_pass :: proc(copy_pass: ^sdl.GPUCopyPass) {
	cmd := (^Vk_Cmd)(copy_pass)
	cmd.pass = .None
}

@(private = "file")
vk_subresource :: proc(t: ^Vk_Texture, level: u32) -> vk.ImageSubresourceLayers {
	return {aspectMask = t.aspect, mipLevel = level, baseArrayLayer = 0, layerCount = 1}
}

vk_upload_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureTransferInfo, #by_ptr destination: sdl.GPUTextureRegion, cycle: bool) {
	cmd := (^Vk_Cmd)(copy_pass)
	src := (^Vk_Buffer)(source.transfer_buffer).active
	t := (^Vk_Texture)(destination.texture)
	vk_cmd_track_buffer(cmd, src)
	vk_memory_barrier(cmd)
	img := vk_target(cmd, t, destination.mip_level, cycle, .TRANSFER_DST_OPTIMAL)
	region := vk.BufferImageCopy {
		bufferOffset      = vk.DeviceSize(source.offset),
		bufferRowLength   = source.pixels_per_row,
		bufferImageHeight = source.rows_per_layer,
		imageSubresource  = vk_subresource(t, destination.mip_level),
		imageOffset       = {i32(destination.x), i32(destination.y), i32(destination.z)},
		imageExtent       = {destination.w, destination.h, max(destination.d, 1)},
	}
	vk.CmdCopyBufferToImage(cmd.cb, src.buffer, img.image, .TRANSFER_DST_OPTIMAL, 1, &region)
	vk_targets_restore(cmd)
}

vk_upload_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTransferBufferLocation, #by_ptr destination: sdl.GPUBufferRegion, cycle: bool) {
	cmd := (^Vk_Cmd)(copy_pass)
	src := (^Vk_Buffer)(source.transfer_buffer).active
	dst := (^Vk_Buffer)(destination.buffer)
	if cycle && dst.active.refs > 0 do vk_buffer_cycle(dst)
	vk_cmd_track_buffer(cmd, src)
	vk_cmd_track_buffer(cmd, dst.active)
	vk_memory_barrier(cmd)
	region := vk.BufferCopy{srcOffset = vk.DeviceSize(source.offset), dstOffset = vk.DeviceSize(destination.offset), size = vk.DeviceSize(destination.size)}
	vk.CmdCopyBuffer(cmd.cb, src.buffer, dst.active.buffer, 1, &region)
	vk_memory_barrier(cmd)
}

vk_copy_buffer_to_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferLocation, #by_ptr destination: sdl.GPUBufferLocation, size: u32, cycle: bool) {
	cmd := (^Vk_Cmd)(copy_pass)
	src := (^Vk_Buffer)(source.buffer).active
	dst := (^Vk_Buffer)(destination.buffer)
	if cycle && dst.active.refs > 0 do vk_buffer_cycle(dst)
	vk_cmd_track_buffer(cmd, src)
	vk_cmd_track_buffer(cmd, dst.active)
	vk_memory_barrier(cmd)
	region := vk.BufferCopy{srcOffset = vk.DeviceSize(source.offset), dstOffset = vk.DeviceSize(destination.offset), size = vk.DeviceSize(size)}
	vk.CmdCopyBuffer(cmd.cb, src.buffer, dst.active.buffer, 1, &region)
	vk_memory_barrier(cmd)
}

vk_copy_texture_to_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureLocation, #by_ptr destination: sdl.GPUTextureLocation, w, h, d: u32, cycle: bool) {
	cmd := (^Vk_Cmd)(copy_pass)
	st := (^Vk_Texture)(source.texture)
	dt := (^Vk_Texture)(destination.texture)
	vk_memory_barrier(cmd)
	src := vk_target(cmd, st, source.mip_level, false, .TRANSFER_SRC_OPTIMAL)
	dst := vk_target(cmd, dt, destination.mip_level, cycle, .TRANSFER_DST_OPTIMAL)
	region := vk.ImageCopy {
		srcSubresource = vk_subresource(st, source.mip_level),
		srcOffset      = {i32(source.x), i32(source.y), i32(source.z)},
		dstSubresource = vk_subresource(dt, destination.mip_level),
		dstOffset      = {i32(destination.x), i32(destination.y), i32(destination.z)},
		extent         = {w, h, max(d, 1)},
	}
	vk.CmdCopyImage(cmd.cb, src.image, .TRANSFER_SRC_OPTIMAL, dst.image, .TRANSFER_DST_OPTIMAL, 1, &region)
	vk_targets_restore(cmd)
}

vk_download_from_texture :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUTextureRegion, #by_ptr destination: sdl.GPUTextureTransferInfo) {
	cmd := (^Vk_Cmd)(copy_pass)
	t := (^Vk_Texture)(source.texture)
	dst := (^Vk_Buffer)(destination.transfer_buffer).active
	vk_cmd_track_buffer(cmd, dst)
	vk_memory_barrier(cmd)
	img := vk_target(cmd, t, source.mip_level, false, .TRANSFER_SRC_OPTIMAL)
	region := vk.BufferImageCopy {
		bufferOffset      = vk.DeviceSize(destination.offset),
		bufferRowLength   = destination.pixels_per_row,
		bufferImageHeight = destination.rows_per_layer,
		imageSubresource  = vk_subresource(t, source.mip_level),
		imageOffset       = {i32(source.x), i32(source.y), i32(source.z)},
		imageExtent       = {source.w, source.h, max(source.d, 1)},
	}
	vk.CmdCopyImageToBuffer(cmd.cb, img.image, .TRANSFER_SRC_OPTIMAL, dst.buffer, 1, &region)
	vk_targets_restore(cmd)
	vk_memory_barrier(cmd)
}

vk_download_from_buffer :: proc(copy_pass: ^sdl.GPUCopyPass, #by_ptr source: sdl.GPUBufferRegion, #by_ptr destination: sdl.GPUTransferBufferLocation) {
	cmd := (^Vk_Cmd)(copy_pass)
	src := (^Vk_Buffer)(source.buffer).active
	dst := (^Vk_Buffer)(destination.transfer_buffer).active
	vk_cmd_track_buffer(cmd, src)
	vk_cmd_track_buffer(cmd, dst)
	vk_memory_barrier(cmd)
	region := vk.BufferCopy{srcOffset = vk.DeviceSize(source.offset), dstOffset = vk.DeviceSize(destination.offset), size = vk.DeviceSize(source.size)}
	vk.CmdCopyBuffer(cmd.cb, src.buffer, dst.buffer, 1, &region)
	vk_memory_barrier(cmd)
}

// Fills each level from the one above with a linear blit, as SDL_GPU does.
vk_generate_mipmaps_for_texture :: proc(command_buffer: ^sdl.GPUCommandBuffer, texture: ^sdl.GPUTexture) {
	cmd := (^Vk_Cmd)(command_buffer)
	t := (^Vk_Texture)(texture)
	img := t.active
	vk_cmd_track_image(cmd, img)
	for level in 1 ..< t.info.num_levels {
		vk_image_barrier(cmd, img, t.default_layout, .TRANSFER_SRC_OPTIMAL, level - 1, 1)
		vk_image_barrier(cmd, img, t.default_layout, .TRANSFER_DST_OPTIMAL, level, 1)
		blit := vk.ImageBlit {
			srcSubresource = vk_subresource(t, level - 1),
			srcOffsets     = {{0, 0, 0}, {i32(max(t.info.width >> (level - 1), 1)), i32(max(t.info.height >> (level - 1), 1)), 1}},
			dstSubresource = vk_subresource(t, level),
			dstOffsets     = {{0, 0, 0}, {i32(max(t.info.width >> level, 1)), i32(max(t.info.height >> level, 1)), 1}},
		}
		vk.CmdBlitImage(cmd.cb, img.image, .TRANSFER_SRC_OPTIMAL, img.image, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)
		vk_image_barrier(cmd, img, .TRANSFER_SRC_OPTIMAL, t.default_layout, level - 1, 1)
		vk_image_barrier(cmd, img, .TRANSFER_DST_OPTIMAL, t.default_layout, level, 1)
	}
}

// A named group of commands for capture tools, closed by vk_pop_debug_group in the same
// command buffer.
vk_push_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer, name: cstring) {
	if !vk_state.labels || vk.CmdBeginDebugUtilsLabelEXT == nil do return
	label := vk.DebugUtilsLabelEXT{sType = .DEBUG_UTILS_LABEL_EXT, pLabelName = name}
	vk.CmdBeginDebugUtilsLabelEXT((^Vk_Cmd)(command_buffer).cb, &label)
}

vk_pop_debug_group :: proc(command_buffer: ^sdl.GPUCommandBuffer) {
	if !vk_state.labels || vk.CmdEndDebugUtilsLabelEXT == nil do return
	vk.CmdEndDebugUtilsLabelEXT((^Vk_Cmd)(command_buffer).cb)
}
