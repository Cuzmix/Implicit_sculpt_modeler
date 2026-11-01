#+build !js
package geom

// The picture formats image.load_from_bytes reads (mesh_look_paint's textures): each
// subpackage registers its reader when imported.
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/png"
import _ "core:image/qoi"
import _ "core:image/tga"
