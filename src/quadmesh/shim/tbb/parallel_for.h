// A stand-in for TBB's parallel_for. The range is cut into quadmesh_threads equal chunks,
// each run on a std::thread while the caller only waits, so the caller never runs a body
// while workers do (the cancel in quadmesh_shim.cpp relies on that). A call from a worker
// (a nested parallel_for) and a range under PARALLEL_MIN run on the caller. Every body
// AutoRemesher passes writes its own elements only, so the result is the same for any
// thread count and any cut: the sculpt modeler's determinism rule holds for the remesh.
// An exception a worker throws (std::bad_alloc, mostly) is kept and thrown again on the
// caller once every worker has joined, so it reaches qm_remesh's catch and never
// std::terminate.
#pragma once
#include "blocked_range.h"
#include <algorithm>
#include <cstddef>
#include <exception>
#include <mutex>
#include <thread>
#include <vector>
// How many threads a parallel_for uses: set by qm_remesh from the caller's wish, on the
// calling thread only, so two remeshes on two threads keep their own counts.
inline thread_local unsigned quadmesh_threads = 1;
namespace tbb {
namespace detail {
// Whether this thread is one of parallel_for's workers.
inline thread_local bool in_worker = false;
// Ranges shorter than this are not worth a thread.
constexpr std::size_t PARALLEL_MIN = 4096;
}
template <typename R, typename Body> void parallel_for(const R& range, const Body& body) {
    const std::size_t n = range.size();
    const unsigned threads = std::max(1u, std::min(quadmesh_threads, 16u));
    if (n < detail::PARALLEL_MIN || threads == 1 || detail::in_worker) {
        body(range);
        return;
    }
    std::vector<std::thread> pool;
    pool.reserve(threads);
    std::mutex failed_lock;
    std::exception_ptr failed;
    const std::size_t chunk = (n + threads - 1) / threads;
    using Index = decltype(range.begin());
    for (unsigned t = 0; t < threads; ++t) {
        const Index b = range.begin() + Index(t * chunk);
        const Index e = range.begin() + Index(std::min(n, (t + 1) * chunk));
        if (b >= e) break;
        pool.emplace_back([=, &body, &failed, &failed_lock] {
            detail::in_worker = true;
            try {
                body(R(b, e));
            } catch (...) {
                std::lock_guard<std::mutex> guard(failed_lock);
                if (!failed) failed = std::current_exception();
            }
        });
    }
    for (auto& th : pool) th.join();
    if (failed) std::rethrow_exception(failed);
}
}
