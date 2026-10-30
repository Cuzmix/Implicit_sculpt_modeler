// vulkan only: the traced studio's kernel over the driver's acceleration structure
// (studio_trace.comp.slang with RAY_QUERY), which only the own Vulkan backend binds; no
// Metal source is made for it.
#define RAY_QUERY
#include "studio_trace.comp.slang"
