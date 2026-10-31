// ray query: render mode's kernel with nine named map samplers, tracing against the
// driver's acceleration structure (render_trace.slang with RAY_QUERY), which the own Vulkan
// and Metal backends bind; its Metal source comes from slangc's Metal target
// (scripts/shaders_msl.py).
#define RAY_QUERY
#include "render_trace.slang"
