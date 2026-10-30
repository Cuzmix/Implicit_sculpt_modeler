// A stand-in for TBB's parallel_sort: std::sort, which is deterministic for the one use
// (meshseparator.cpp sorts distinct edge-face pairs).
#pragma once
#include <algorithm>
namespace tbb {
template <typename It> void parallel_sort(It b, It e) { std::sort(b, e); }
template <typename It, typename C> void parallel_sort(It b, It e, C c) { std::sort(b, e, c); }
}
