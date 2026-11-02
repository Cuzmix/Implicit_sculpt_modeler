#+build js wasm32, js wasm64p32
package os

// The web version's own files stand in for Odin's refusal here: core:os on js keeps its
// files in the page's memory (memfs_js.odin and the *_js.odin beside it).
