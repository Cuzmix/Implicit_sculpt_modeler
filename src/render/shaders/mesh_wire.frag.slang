// barycentric: mesh.frag.slang with the wireframe drawn over the triangles' edges in the
// same pass
// (wire_over in mesh_shading.slang), for devices whose fragment stage reads where it lies
// between the triangle's corners (render.Gpu_Caps.barycentric); the rest draw the edges
// as lines in a second pass.
#define WIRE_BARY 1
#include "mesh_shading.slang"
