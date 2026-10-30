// vulkan only: render mode's kernel with every map slot in one array (render_trace.slang),
// which only the own Vulkan backend binds; no Metal source is made for it.
#define MAP_ARRAY
#include "render_trace.slang"
