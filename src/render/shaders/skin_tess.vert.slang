// A mesh with a detail skin, near the camera: its triangles drawn as the skin's grid of
// small ones at the points the skin shows, so its outline carries the skin's detail
// (mesh.vert.slang, SKIN_TESS), shaded by mesh.frag.slang with the samples' normals.
#define SKIN_TESS 1
#include "mesh.vert.slang"
