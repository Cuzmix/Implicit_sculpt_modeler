// mesh.frag.slang with a material's layers (render.Layer_Uniforms) and the area lights' loops,
// drawn for an item whose materials have layers, so the plain shaders carry none of their code.
#define AREA_LIGHTS 1
#define LAYERS 1
#include "mesh_shading.slang"
