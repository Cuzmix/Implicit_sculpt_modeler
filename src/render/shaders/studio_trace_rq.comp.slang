// ray query: the traced studio's kernel over the driver's acceleration structure
// (studio_trace.comp.slang with RAY_QUERY), which the own Vulkan and Metal backends bind;
// its Metal source comes from slangc's Metal target (scripts/shaders_msl.py).
#define RAY_QUERY
#include "studio_trace.comp.slang"
