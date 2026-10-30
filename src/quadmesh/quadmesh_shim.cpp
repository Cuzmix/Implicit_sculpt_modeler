// The C boundary to AutoRemesher's core (quadmesh_shim.h): copies the caller's triangles
// into AutoRemesher's own types, runs it with the progress handler below, and hands the
// polygons back as plain arrays. Built with the core's sources by
// scripts/build_autoremesher.py, with shim/tbb in place of TBB.
//
// Cancel: AutoRemesher has no cancel of its own, so the handler throws Qm_Cancel when the
// caller's progress proc says stop, and qm_remesh catches it. The throw happens only on
// the thread that called qm_remesh, which the shim's parallel_for never uses for a body
// while workers run, so the unwinding passes only AutoRemesher's own frames at a phase
// boundary or in a serial loop; its scratch is RAII (vectors, unique_ptrs, and the
// half-edge mesh's and bounding-box tree's nodes, deleted by their owners' destructors),
// so nothing of its is left behind. One catch (...) round an island's parameterization
// (autoremesher.cpp, "parameterization failed") swallows the first throw and skips the
// island; the cancel is sticky, so the next progress call throws again and ends the
// remesh. Workers only report.
//
// Console: the core writes a phase report, and an island's failure, to std::cerr. The
// first remesh points std::cerr at the sink below for the rest of the process (nothing
// else in the app writes to it), which keeps the last line as the reason when the core
// fails without naming one; the sink locks, since the test runner remeshes on several
// threads at once.
#include "quadmesh_shim.h"

#include <AutoRemesher/AutoRemesher>
#include <tbb/parallel_for.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <iostream>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

struct Qm_Result {
    std::vector<AutoRemesher::Vector3> vertices;
    std::vector<std::vector<size_t>> faces;
};

namespace {

struct Qm_Cancel {};

// What the progress handler needs: the caller's proc, which thread may cancel, and the
// last stage named, which is AutoRemesher's reason when it fails.
struct Handler {
    Qm_Progress progress;
    void* tag;
    std::thread::id caller;
    std::mutex lock;
    std::string last;
};

void on_progress(void* tag, float fraction, const char* stage)
{
    Handler* h = static_cast<Handler*>(tag);
    const char* text = stage ? stage : "";
    // The core names a reason for giving up with a progress of 1 (an empty mesh, a zero
    // target); every other text is the stage about to run.
    if (*text && fraction >= 1.0f) {
        std::lock_guard<std::mutex> guard(h->lock);
        h->last = text;
    }
    const bool go = h->progress ? h->progress(h->tag, fraction, text) != 0 : true;
    if (!go && std::this_thread::get_id() == h->caller) throw Qm_Cancel{};
}

void say(char* error, size_t size, const char* text)
{
    if (!error || size == 0) return;
    std::strncpy(error, text, size - 1);
    error[size - 1] = '\0';
}

// Where std::cerr goes once a remesh has run: every line is dropped but the last whole
// one, under a lock. No put area, so every write comes through these two.
struct Sink : std::streambuf {
    std::mutex lock;
    std::string line, last;
    void take(char c)
    {
        if (c == '\n') {
            if (!line.empty()) last.swap(line);
            line.clear();
        } else if (c != '\r') {
            line += c;
        }
    }
    int_type overflow(int_type c) override
    {
        if (c != traits_type::eof()) {
            std::lock_guard<std::mutex> guard(lock);
            take(char(c));
        }
        return c;
    }
    std::streamsize xsputn(const char* s, std::streamsize n) override
    {
        std::lock_guard<std::mutex> guard(lock);
        for (std::streamsize i = 0; i < n; ++i) take(s[i]);
        return n;
    }
    std::string last_line()
    {
        std::lock_guard<std::mutex> guard(lock);
        return last;
    }
};

// Made once and never freed: std::cerr keeps pointing at it through the process's exit,
// after this library's statics would be gone.
Sink& sink()
{
    static Sink* s = [] {
        Sink* made = new Sink;
        std::cerr.rdbuf(made);
        return made;
    }();
    return *s;
}

}

extern "C" int qm_remesh(const float* positions, uint32_t vertex_count, const uint32_t* triangles, uint32_t triangle_count,
    const Qm_Params* params, Qm_Progress progress, void* tag, Qm_Result** out, char* error, size_t error_size)
{
    *out = nullptr;
    say(error, error_size, "");
    Handler handler{progress, tag, std::this_thread::get_id(), {}, {}};
    Sink& console = sink();
    try {
        std::vector<AutoRemesher::Vector3> vertices;
        vertices.reserve(vertex_count);
        for (uint32_t v = 0; v < vertex_count; ++v)
            vertices.emplace_back(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]);
        std::vector<std::vector<size_t>> faces(triangle_count, std::vector<size_t>(3));
        for (uint32_t t = 0; t < triangle_count; ++t)
            for (size_t k = 0; k < 3; ++k) faces[t][k] = triangles[3 * t + k];

        quadmesh_threads = std::max(1u, std::min(params->threads, 16u));
        AutoRemesher::AutoRemesher remesher(vertices, faces);
        remesher.setTargetTriangleCount(size_t(params->quads) * 2);
        if (params->scaling > 0) remesher.setScaling(params->scaling);
        remesher.setGradientAdaptivity(params->adaptivity);
        remesher.setSharpEdgeDegrees(params->sharp_degrees);
        if (params->anisotropy > 0) remesher.setAnisotropy(params->anisotropy);
        remesher.setTag(&handler);
        remesher.setProgressHandler(on_progress);
        if (!remesher.remesh()) {
            std::lock_guard<std::mutex> guard(handler.lock);
            const std::string why = !handler.last.empty() ? handler.last : console.last_line();
            say(error, error_size, why.empty() ? "AutoRemesher failed" : why.c_str());
            return QM_FAILED;
        }
        Qm_Result* r = new Qm_Result;
        r->vertices = remesher.remeshedVertices();
        r->faces = remesher.remeshedQuads();
        *out = r;
        return QM_OK;
    } catch (const Qm_Cancel&) {
        say(error, error_size, "cancelled");
        return QM_CANCELLED;
    } catch (const std::bad_alloc&) {
        say(error, error_size, "out of memory");
        return QM_OUT_OF_MEMORY;
    } catch (const std::exception& e) {
        say(error, error_size, e.what());
        return QM_FAILED;
    } catch (...) {
        say(error, error_size, "AutoRemesher failed");
        return QM_FAILED;
    }
}

extern "C" void qm_counts(const Qm_Result* r, uint32_t* vertices, uint32_t* faces, uint32_t* corners)
{
    size_t c = 0;
    for (const auto& f : r->faces) c += f.size();
    *vertices = uint32_t(r->vertices.size());
    *faces = uint32_t(r->faces.size());
    *corners = uint32_t(c);
}

extern "C" void qm_copy(const Qm_Result* r, float* positions, uint32_t* first, uint32_t* corners)
{
    for (size_t v = 0; v < r->vertices.size(); ++v) {
        positions[3 * v] = float(r->vertices[v].x());
        positions[3 * v + 1] = float(r->vertices[v].y());
        positions[3 * v + 2] = float(r->vertices[v].z());
    }
    uint32_t n = 0;
    for (size_t f = 0; f < r->faces.size(); ++f) {
        first[f] = n;
        for (size_t i : r->faces[f]) corners[n++] = uint32_t(i);
    }
    first[r->faces.size()] = n;
}

extern "C" void qm_free(Qm_Result* r)
{
    delete r;
}
