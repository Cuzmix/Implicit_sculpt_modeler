package gpu

import "core:sync"
import "core:thread"

// A compute pipeline built off the frame. A kernel with specialization constants takes a
// driver a good part of a second to compile, too long for a frame to wait, so
// compute_build_start does on the calling (main) thread what touches the backend's own state
// (checks, layouts, modules, slot tables), and leaves only the driver's compile, which
// Vulkan and Metal allow on any thread, to a thread of its own. compute_build_finish then
// makes the backend's object and its handle on the main thread again, so no state of ours
// is shared with the thread. WebGPU has no threads of ours and builds at once.

// How a kernel binds, as create_compute_pipeline, create_compute_pipeline_array and
// create_compute_pipeline_traced make it.
Compute_Kind :: enum u8 {
	Plain,
	Array,
	Traced,
}

when METAL {
	Compute_Build_Backend :: Mtl_Compute_Build
} else when WEBGPU {
	Compute_Build_Backend :: struct {
		pipeline: rawptr,
	}
} else {
	Compute_Build_Backend :: Vk_Compute_Build
}

Compute_Build :: struct {
	// The constants the compile reads, kept here so the caller's may go.
	constants: [COMPUTE_CONSTANTS_MAX]u32,
	thread:    ^thread.Thread,
	done:      bool, // set by the thread when the compile is over
	backend:   Compute_Build_Backend,
}

// Starts building `desc`'s pipeline of `kind` (with `capacity` as the matching create proc
// takes it); with `wait`, or where there is no thread to build on, it is built before this
// returns. Nil with last_error when it cannot be made; otherwise compute_build_finish takes
// it. `desc.code` and `desc.entrypoint` must outlive the build, as the generated
// descriptions' do.
@(require_results)
compute_build_start :: proc(desc: Compute_Pipeline_Desc, kind: Compute_Kind, capacity: u32, wait: bool) -> ^Compute_Build {
	if len(desc.constants) > COMPUTE_CONSTANTS_MAX {
		fail(.Unsupported, "a kernel takes at most %d specialization constants", COMPUTE_CONSTANTS_MAX)
		return nil
	}
	b := new(Compute_Build)
	info := desc
	copy(b.constants[:], desc.constants)
	info.constants = b.constants[:len(desc.constants)]
	when WEBGPU {
		if kind != .Plain {
			fail(.Unsupported, "WebGPU builds plain kernels only")
			free(b)
			return nil
		}
		b.backend.pipeline = wgpu_create_compute_pipeline(info)
		if b.backend.pipeline == nil {
			free(b)
			return nil
		}
		b.done = true
		return b
	} else {
		when METAL do ok := mtl_compute_prepare(info, kind, capacity, false, &b.backend)
		else do ok := vk_compute_prepare(info, kind, capacity, &b.backend)
		if !ok {
			free(b)
			return nil
		}
		if wait {
			compute_build_compile(b)
			return b
		}
		// The thread allocates nothing and reports nothing, so it needs no context of its own.
		b.thread = thread.create_and_start_with_data(b, proc(data: rawptr) {
			compute_build_compile((^Compute_Build)(data))
		}, context, .Low, name = "kernel build")
		return b
	}
}

@(private = "file")
compute_build_compile :: proc(b: ^Compute_Build) {
	when METAL do mtl_compute_compile(&b.backend)
	else when VULKAN do vk_compute_compile(&b.backend)
	sync.atomic_store(&b.done, true)
}

// Whether the build is over, so that compute_build_finish will not wait.
@(require_results)
compute_build_ready :: proc(b: ^Compute_Build) -> bool {
	return b != nil && sync.atomic_load(&b.done)
}

// The built pipeline, waiting for the compile if it is still running, and the build freed;
// 0 with last_error when the driver refused it. The caller releases the pipeline.
@(require_results)
compute_build_finish :: proc(b: ^Compute_Build) -> Compute_Pipeline {
	if b == nil do return 0
	if b.thread != nil {
		thread.join(b.thread)
		thread.destroy(b.thread)
	}
	when METAL do pipeline := mtl_compute_wrap(&b.backend)
	else when WEBGPU do pipeline := b.backend.pipeline
	else do pipeline := vk_compute_wrap(&b.backend)
	free(b)
	if pipeline == nil do return 0
	return Compute_Pipeline(pool_add(&pools.compute_pipelines, pipeline))
}
