#+build js
package geom

// The web build registers no picture readers yet: Odin's PNG reader (through its zlib)
// crashes the compiler for js_wasm64p32, so an imported texture counts as unread there
// and the mesh keeps its material colours. The browser's own decoder can fill this in.
import _ "core:image/bmp"
import _ "core:image/qoi"
import _ "core:image/tga"
