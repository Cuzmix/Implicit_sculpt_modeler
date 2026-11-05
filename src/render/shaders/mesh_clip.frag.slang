// mesh.frag.slang clipped at the live stack's mirror planes (render.Draw_Item.clip): drawn
// only for an item that has them, since a shader that may discard loses the early depth
// test (and Apple's hidden surface removal) for everything drawn with it.
#define CLIP 1
#include "mesh_shading.slang"
