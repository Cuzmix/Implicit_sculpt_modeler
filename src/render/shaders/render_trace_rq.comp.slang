// vulkan only: render mode's kernel with nine named map samplers, tracing against the
// driver's acceleration structure (render_trace.slang with RAY_QUERY), which only the own
// Vulkan backend binds; no Metal source is made for it.
#define RAY_QUERY
#include "render_trace.slang"
