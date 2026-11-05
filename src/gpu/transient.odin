package gpu

// Used only by debug builds.
@(require) import "core:fmt"


// Transient textures (create_texture_transient) hold their contents only inside the
// one render pass that clears and uses them: a tile GPU then never gives them memory.
// Debug builds keep the set of them and check, at the seam and so under every backend,
// that no pass loads or stores one and that nothing samples, copies or downloads one.

when ODIN_DEBUG {
	@(private = "file")
	transient_textures: map[Texture]bool
}

transient_note :: proc(texture: Texture) {
	when ODIN_DEBUG do if texture != 0 do transient_textures[texture] = true
}

transient_forget :: proc(texture: Texture) {
	when ODIN_DEBUG {
		delete_key(&transient_textures, texture)
		// Let go of the map once empty, so a clean exit leaves nothing allocated.
		if len(transient_textures) == 0 && cap(transient_textures) > 0 {
			delete(transient_textures)
			transient_textures = nil
		}
	}
}

// Panics when `texture` is transient: it is being used outside its pass.
transient_check_use :: proc(texture: Texture, use: string) {
	when ODIN_DEBUG do if texture != 0 && texture in transient_textures do fmt.panicf("a transient texture was %s", use)
}

// Panics when a pass loads or stores a transient attachment.
transient_check_pass :: proc(colors: [^]Color_Target, count: u32, depth: Maybe(^Depth_Target)) {
	when ODIN_DEBUG {
		if len(transient_textures) == 0 do return
		for c in colors[:count] {
			if c.texture in transient_textures && (c.load_op == .Load || c.store_op == .Store || c.store_op == .Resolve_And_Store) do fmt.panicf("a pass loads or stores a transient colour target (%v, %v)", c.load_op, c.store_op)
			transient_check_use(c.resolve_texture, "a resolve target")
		}
		if d, ok := depth.?; ok && d != nil && d.texture in transient_textures {
			if d.load_op == .Load || d.store_op != .Dont_Care || d.stencil_load_op == .Load || d.stencil_store_op != .Dont_Care do fmt.panicf("a pass loads or stores a transient depth target (%v, %v)", d.load_op, d.store_op)
		}
	}
}
