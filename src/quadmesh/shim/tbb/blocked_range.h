// A stand-in for TBB's blocked_range, the only range AutoRemesher's core uses: the
// half-open [begin, end) a parallel_for body gets (scripts/build_autoremesher.py puts
// this folder on the include path in place of TBB).
#pragma once
#include <cstddef>
namespace tbb {
template <typename T> class blocked_range {
public:
    blocked_range(T b, T e, std::size_t grain = 1) : m_begin(b), m_end(e) { (void)grain; }
    T begin() const { return m_begin; }
    T end() const { return m_end; }
    std::size_t size() const { return std::size_t(m_end - m_begin); }
private:
    T m_begin, m_end;
};
}
