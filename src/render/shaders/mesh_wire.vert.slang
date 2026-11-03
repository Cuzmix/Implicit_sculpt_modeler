// barycentric: mesh.vert.slang handing mesh_wire.frag.slang the number of the draw's
// first triangle (its first instance), so the fragment stage finds which of its
// triangle's edges are polygon edges.
#define WIRE_BARY 1
#include "mesh.vert.slang"
