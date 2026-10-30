// vulkan only: render mode's kernel with every map slot in one array, tracing against the
// driver's acceleration structure (render_trace.slang with MAP_ARRAY and RAY_QUERY), which
// only the own Vulkan backend binds; no Metal source is made for it.
#define MAP_ARRAY
#define RAY_QUERY
#include "render_trace.slang"
