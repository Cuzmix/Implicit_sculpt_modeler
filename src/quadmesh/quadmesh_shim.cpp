// The C boundary to AutoRemesher's core (quadmesh_shim.h): copies the caller's triangles
// into AutoRemesher's own types, runs its stages itself, and hands the polygons back as
// plain arrays. Built with the core's sources by scripts/build_autoremesher.py, with
// shim/tbb in place of TBB.
//
// The stages are run here rather than by AutoRemesher::remesh() because that top level
// passes its parameterizer neither a frame field (which guides and feature edges steer)
// nor a scaling field (which density steers), and sizes the quads by the isotropic mesh's
// mean edge with a scaling of one, so the count lands wherever that mean edge lands
// against its target (between 70 % and 110 % of the request). The pipeline is the core's
// own, in its order: the mesh split into islands (MeshSeparator), each island decimated
// when it is far denser than the target (meshoptimizer, as the core's decimateIfTooDense
// does), remeshed isotropically at the target edge (with the curvature target-length
// field the core's resample builds under Adaptivity), parameterized (frame field,
// singularity simplification, quad cover) and the quads extracted, then the islands
// joined. A density per vertex (Use paint, Use mask) shortens the isotropic target edge
// where it asks for more quads, rides the isotropic remesh to its vertices, and scales the
// cover per face, normalised so the count stays. A refinement per vertex shortens the
// isotropic target edge alone, so a thin part a few quads round has triangles enough
// under them for its quads to be extracted. Guide curves give the faces near them a
// direction and a weight (faceGuides) that the frame field pulls toward and the cover's
// curl correction keeps. The quad edge wanted is sqrt(area / quads) over the whole input, and each
// island's parameterizer gets it as a multiple of that island's measured mean edge, which
// is the number the cover multiplies by; the cover still lands short where the field has
// curl it cannot flatten, so its area in cells is measured and a second cover corrects
// the scaling when the first is more than 3 % off (remeshIsland says how), which lands
// the count within a few percent.
//
// Islands run on threads of their own up to the thread count asked, each island whole on
// one thread (the stand-in parallel_for runs a short range on the caller, so the core's
// island loop was serial in any case); a mesh of one island runs on the calling thread.
// Every island's result is its own, so the output is the same for any thread count.
//
// Cancel: AutoRemesher has no cancel of its own, so the progress handler throws Qm_Cancel
// when the caller's progress proc says stop, and qm_remesh catches it. On the calling
// thread the throw unwinds the core's frames at a phase boundary or in a serial loop; on
// an island thread it is caught at the island's end and thrown again on the caller once
// every island has joined (the cancel is sticky, so the other islands end at their next
// report). The core's scratch is RAII (vectors, unique_ptrs, and the half-edge mesh's and
// bounding-box tree's nodes, deleted by their owners' destructors), so nothing of its is
// left behind.
//
// Console: the core writes an island's failure to std::cerr. The first remesh points
// std::cerr at the sink below for the rest of the process (nothing else in the app writes
// to it), which keeps the last line as the reason when the core fails without naming one;
// the sink locks, since the test runner remeshes on several threads at once.
#include "quadmesh_shim.h"

#include <AutoRemesher/IsotropicRemesher>
#include <AutoRemesher/MeshSeparator>
#include <AutoRemesher/Parameterizer>
#include <AutoRemesher/QuadParameterizer>
#include <AutoRemesher/QuadExtractor>
#include <AutoRemesher/SurfaceMesh>
#include <AutoRemesher/Vector3>
#include <meshoptimizer.h>
#include <tbb/parallel_for.h>

#include <algorithm>
#include <atomic>
#include <cfloat>
#include <chrono>
#include <cmath>
#include <cstring>
#include <exception>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using AutoRemesher::Vector3;

struct Qm_Result {
    std::vector<Vector3> vertices;
    std::vector<std::vector<size_t>> faces;
    Qm_Times times;
};

namespace {

struct Qm_Cancel {};

// The core's own ratios: an island at more than `decimateTrigger` times its share of the
// target triangle count is decimated to `decimateTarget` times it first.
constexpr double decimateTrigger = 8.0;
constexpr double decimateTarget = 4.0;
// Where an island's own 0..1 progress splits across its three stages, as the core splits
// it, from the measured cost of each.
constexpr float islandResampleEnd = 0.17f;
constexpr float islandParameterizeEnd = 0.50f;
// The islands' share of the whole bar: the split and the join take the rest.
constexpr float parallelPhaseBegin = 0.03f;
constexpr float parallelPhaseEnd = 0.95f;

using Clock = std::chrono::steady_clock;

double milliseconds(Clock::time_point from, Clock::time_point to)
{
    return std::chrono::duration<double, std::milli>(to - from).count();
}

// What the progress handler needs: the caller's proc, every island's progress and weight
// (its share of the input's triangles), and the last reason an island gave for failing.
struct Handler {
    Qm_Progress progress;
    void* tag;
    std::mutex lock;
    std::vector<float> islandProgress;
    std::vector<float> islandWeight;
    std::string last;
    bool cancelled = false;

    // An island reports its own 0..1; the caller gets the weighted whole. A stop from the
    // caller throws here, on whichever thread reports, and stays stopped.
    void report(size_t island, float fraction, const char* stage)
    {
        bool go = true;
        {
            std::lock_guard<std::mutex> guard(lock);
            if (island < islandProgress.size())
                islandProgress[island] = std::max(islandProgress[island], std::min(1.0f, fraction));
            double sum = 0.0;
            for (size_t i = 0; i < islandProgress.size(); ++i)
                sum += (double)islandProgress[i] * islandWeight[i];
            const float overall = parallelPhaseBegin + (parallelPhaseEnd - parallelPhaseBegin) * (float)std::min(1.0, sum);
            if (progress && !cancelled)
                go = progress(tag, overall, stage ? stage : "") != 0;
            if (!go) cancelled = true;
            go = !cancelled;
        }
        if (!go) throw Qm_Cancel{};
    }

    void whole(float fraction, const char* stage)
    {
        bool go = true;
        {
            std::lock_guard<std::mutex> guard(lock);
            if (progress && !cancelled)
                go = progress(tag, fraction, stage) != 0;
            if (!go) cancelled = true;
            go = !cancelled;
        }
        if (!go) throw Qm_Cancel{};
    }

    void failed(const std::string& why)
    {
        std::lock_guard<std::mutex> guard(lock);
        last = why;
    }
};

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

double meshArea(const std::vector<Vector3>& vertices, const std::vector<std::vector<size_t>>& triangles)
{
    double area = 0.0;
    for (const auto& t : triangles)
        area += Vector3::area(vertices[t[0]], vertices[t[1]], vertices[t[2]]);
    return area;
}

// Whether the triangle a b c lies on one of the caller's cap planes (Qm_Params.cap_axes):
// every corner within `within` of it and the triangle square to its axis. The isotropic
// remesh leaves a cap's vertices a hair off the plane where it projects them near the rim,
// so its triangles are judged within a share of the target edge; the surface beside a cap
// meets it at an angle, so the facing keeps those triangles out.
bool onCap(const Qm_Params& params, const Vector3& a, const Vector3& b, const Vector3& c, double within)
{
    if (0 == params.cap_axes) return false;
    const Vector3 normal = Vector3::crossProduct(b - a, c - a).normalized();
    for (size_t k = 0; k < 3; ++k) {
        if (!(params.cap_axes & (1u << k))) continue;
        const double o = params.cap_center[k];
        if (std::fabs(a[k] - o) <= within && std::fabs(b[k] - o) <= within && std::fabs(c[k] - o) <= within
            && std::fabs(normal[k]) >= 0.995) return true;
    }
    return false;
}

// The triangles that count for the quads asked: all but those on a cap plane.
std::vector<std::vector<size_t>> countedTriangles(const Qm_Params& params, const std::vector<Vector3>& vertices,
    const std::vector<std::vector<size_t>>& triangles)
{
    if (0 == params.cap_axes) return triangles;
    std::vector<std::vector<size_t>> counted;
    counted.reserve(triangles.size());
    for (const auto& t : triangles)
        if (!onCap(params, vertices[t[0]], vertices[t[1]], vertices[t[2]], params.cap_snap)) counted.push_back(t);
    return counted;
}

// The area weighted by the density (Qm_Params.density, one per vertex, the mean of a
// triangle's corners on it): the area the quads are spread over as if it were even. The
// plain area when there is no density. With a refinement (Qm_Params.refine) too, each
// corner's density is divided by its refinement squared: the area the isotropic
// triangles are spread over, which the decimation keeps enough triangles for.
double densityArea(const std::vector<Vector3>& vertices, const std::vector<std::vector<size_t>>& triangles,
    const std::vector<double>& density, const std::vector<double>& refine = {})
{
    const bool dense = density.size() == vertices.size(), refined = refine.size() == vertices.size();
    if (!dense && !refined) return meshArea(vertices, triangles);
    const auto weight = [&](size_t v) {
        const double d = dense ? density[v] : 1.0, r = refined ? refine[v] : 1.0;
        return d / (r * r);
    };
    double area = 0.0;
    for (const auto& t : triangles)
        area += Vector3::area(vertices[t[0]], vertices[t[1]], vertices[t[2]]) * (weight(t[0]) + weight(t[1]) + weight(t[2])) / 3.0;
    return area;
}

// The vertices on an edge sharper than `sharpRadians`, marked for meshoptimizer to keep
// (the core's markSharpEdgeVertices, serial).
void markSharpVertices(const std::vector<Vector3>& vertices, const std::vector<unsigned int>& indices,
    double sharpRadians, std::vector<unsigned char>& lock)
{
    const size_t faces = indices.size() / 3;
    std::vector<Vector3> normals(faces);
    for (size_t f = 0; f < faces; ++f)
        normals[f] = Vector3::normal(vertices[indices[3 * f]], vertices[indices[3 * f + 1]], vertices[indices[3 * f + 2]]);
    std::vector<std::pair<uint64_t, unsigned int>> edges(3 * faces);
    for (size_t f = 0; f < faces; ++f)
        for (size_t k = 0; k < 3; ++k) {
            unsigned int a = indices[3 * f + k], b = indices[3 * f + (k + 1) % 3];
            if (a > b) std::swap(a, b);
            edges[3 * f + k] = { ((uint64_t)a << 32) | b, (unsigned int)f };
        }
    std::sort(edges.begin(), edges.end());
    for (size_t i = 0; i + 1 < edges.size(); ++i) {
        if (edges[i].first != edges[i + 1].first) continue;
        if (Vector3::angle(normals[edges[i].second], normals[edges[i + 1].second]) < sharpRadians) continue;
        lock[(size_t)(edges[i].first >> 32)] |= meshopt_SimplifyVertex_Priority;
        lock[(size_t)(edges[i].first & 0xffffffffu)] |= meshopt_SimplifyVertex_Priority;
    }
}

// An island far denser than its share of the target is decimated to `decimateTarget`
// times that share first (the core's decimateIfTooDense): meshoptimizer welds, then
// simplifies with sharp vertices and the feature edges' vertices kept, and the feature
// edges renumbered (one whose edge the simplification took out is dropped). False when
// nothing was done.
bool decimateIfDense(std::vector<Vector3>& vertices, std::vector<std::vector<size_t>>& triangles,
    std::vector<std::pair<size_t, size_t>>& features, std::vector<double>& density, std::vector<double>& refine,
    double voxelSize, double sharpDegrees)
{
    if (vertices.empty() || triangles.empty() || voxelSize <= 0.0) return false;
    if (vertices.size() > (size_t)std::numeric_limits<unsigned int>::max()) return false;
    const double targetArea = voxelSize * voxelSize * 0.86602540378 * 0.5;
    // Where the density asks for smaller quads, or the refinement for finer triangles, the
    // isotropic remesh wants smaller triangles, so the triangles kept follow the weighted
    // area.
    const double wanted = densityArea(vertices, triangles, density, refine) / targetArea;
    if (wanted < 1.0 || (double)triangles.size() < wanted * decimateTrigger) return false;
    const size_t goal = (size_t)(wanted * decimateTarget);

    std::vector<unsigned int> indices;
    indices.reserve(3 * triangles.size());
    for (const auto& t : triangles) {
        if (t.size() != 3) return false;
        for (size_t k = 0; k < 3; ++k) indices.push_back((unsigned int)t[k]);
    }
    Vector3 lo = vertices.front(), hi = vertices.front();
    for (const auto& p : vertices)
        for (size_t k = 0; k < 3; ++k) {
            lo[k] = std::min(lo[k], p[k]);
            hi[k] = std::max(hi[k], p[k]);
        }
    const Vector3 centre = (lo + hi) * 0.5;
    std::vector<float> positions;
    positions.reserve(3 * vertices.size());
    for (const auto& p : vertices)
        for (size_t k = 0; k < 3; ++k) positions.push_back((float)(p[k] - centre[k]));

    std::vector<unsigned int> remap(vertices.size());
    const size_t welded = meshopt_generateVertexRemap(remap.data(), indices.data(), indices.size(), positions.data(), vertices.size(), sizeof(float) * 3);
    std::vector<Vector3> weldedVertices(welded);
    std::vector<float> weldedPositions(3 * welded);
    meshopt_remapIndexBuffer(indices.data(), indices.data(), indices.size(), remap.data());
    meshopt_remapVertexBuffer(weldedPositions.data(), positions.data(), vertices.size(), sizeof(float) * 3, remap.data());
    for (size_t v = 0; v < vertices.size(); ++v)
        if (~0u != remap[v]) weldedVertices[remap[v]] = vertices[v];
    // The values per vertex ride the weld and the simplification with their vertices.
    const auto weld = [&](const std::vector<double>& values) {
        std::vector<double> out;
        if (values.size() != vertices.size()) return out;
        out.assign(welded, 1.0);
        for (size_t v = 0; v < vertices.size(); ++v)
            if (~0u != remap[v]) out[remap[v]] = values[v];
        return out;
    };
    const std::vector<double> weldedDensity = weld(density), weldedRefine = weld(refine);

    std::vector<unsigned char> lock;
    if (sharpDegrees > 0.0) {
        lock.assign(welded, 0);
        markSharpVertices(weldedVertices, indices, sharpDegrees * (M_PI / 180.0), lock);
    }
    if (!features.empty()) {
        if (lock.empty()) lock.assign(welded, 0);
        for (const auto& edge : features)
            for (size_t v : { edge.first, edge.second })
                if (v < remap.size() && ~0u != remap[v]) lock[remap[v]] = 1;
    }
    std::vector<unsigned int> decimated(indices.size());
    float error = 0.0f;
    decimated.resize(meshopt_simplifyWithAttributes(decimated.data(), indices.data(), indices.size(),
        weldedPositions.data(), welded, sizeof(float) * 3, nullptr, 0, nullptr, 0,
        lock.empty() ? nullptr : lock.data(), goal * 3, FLT_MAX, meshopt_SimplifyRegularize, &error));
    if (decimated.size() < 3 || decimated.size() >= indices.size()) return false;

    std::vector<size_t> outputOf(welded, std::numeric_limits<size_t>::max());
    std::vector<Vector3> outVertices;
    std::vector<double> outDensity, outRefine;
    std::vector<std::vector<size_t>> outTriangles;
    outTriangles.reserve(decimated.size() / 3);
    for (size_t i = 0; i + 2 < decimated.size(); i += 3) {
        std::vector<size_t> t(3);
        for (size_t k = 0; k < 3; ++k) {
            const unsigned int w = decimated[i + k];
            if (outputOf[w] == std::numeric_limits<size_t>::max()) {
                outputOf[w] = outVertices.size();
                outVertices.push_back(weldedVertices[w]);
                if (!weldedDensity.empty()) outDensity.push_back(weldedDensity[w]);
                if (!weldedRefine.empty()) outRefine.push_back(weldedRefine[w]);
            }
            t[k] = outputOf[w];
        }
        outTriangles.push_back(std::move(t));
    }
    if (!features.empty()) {
        std::unordered_set<uint64_t> kept;
        kept.reserve(3 * outTriangles.size());
        for (const auto& t : outTriangles)
            for (size_t k = 0; k < 3; ++k) {
                const size_t a = t[k], b = t[(k + 1) % 3];
                kept.insert(((uint64_t)std::min(a, b) << 32) | (uint64_t)std::max(a, b));
            }
        std::vector<std::pair<size_t, size_t>> renumbered;
        renumbered.reserve(features.size());
        for (const auto& edge : features) {
            if (edge.first >= remap.size() || edge.second >= remap.size()) continue;
            const unsigned int wa = remap[edge.first], wb = remap[edge.second];
            if (~0u == wa || ~0u == wb) continue;
            const size_t a = outputOf[wa], b = outputOf[wb];
            if (a == std::numeric_limits<size_t>::max() || b == std::numeric_limits<size_t>::max() || a == b) continue;
            if (!kept.count(((uint64_t)std::min(a, b) << 32) | (uint64_t)std::max(a, b))) continue;
            renumbered.push_back({ a, b });
        }
        features = std::move(renumbered);
    }
    vertices = std::move(outVertices);
    triangles = std::move(outTriangles);
    if (!weldedDensity.empty()) density = std::move(outDensity);
    if (!weldedRefine.empty()) refine = std::move(outRefine);
    return true;
}

// A vertex two fans of faces meet at and share no edge round (a pinch: a thin spike whose
// sides the decimation brought together, two parts touching at a point) gets a vertex of
// its own for each fan past its first, with its values (`density`, `refine`) copied. The
// isotropic remesher's half-edge mesh walks round a vertex from one halfedge and assumes
// a single fan: on a pinch it collapsed edges into folds and then walked round a broken
// ring forever (a creature's horn tips under Keep symmetry). The fans are the corners at
// a vertex joined across the edges they share; the faces stay as they are, in order, so
// the result is the same every run. Returns how many vertices were added.
size_t unpinch(std::vector<Vector3>& vertices, std::vector<std::vector<size_t>>& triangles,
    std::vector<double>& density, std::vector<double>& refine)
{
    const size_t corners = 3 * triangles.size();
    // Each directed edge (a to b) at the corner it starts from; an edge two faces run the
    // same way (a flipped face, or more than two faces on it) joins nothing.
    std::unordered_map<uint64_t, size_t> edgeCorner;
    edgeCorner.reserve(corners);
    std::unordered_set<uint64_t> doubled;
    const auto key = [](size_t a, size_t b) { return ((uint64_t)a << 32) | (uint64_t)b; };
    for (size_t f = 0; f < triangles.size(); ++f)
        for (size_t k = 0; k < 3; ++k) {
            const uint64_t e = key(triangles[f][k], triangles[f][(k + 1) % 3]);
            if (!edgeCorner.emplace(e, 3 * f + k).second) doubled.insert(e);
        }
    std::vector<size_t> parent(corners);
    for (size_t c = 0; c < corners; ++c) parent[c] = c;
    const auto find = [&parent](size_t c) {
        while (parent[c] != c) c = parent[c] = parent[parent[c]];
        return c;
    };
    // Corner c (face f, at vertex v) leaves v along f's edge v to next; the face across
    // runs next to v, and its corner at v is the one after the corner it starts from.
    for (size_t c = 0; c < corners; ++c) {
        const size_t f = c / 3, k = c % 3;
        const size_t v = triangles[f][k], next = triangles[f][(k + 1) % 3];
        if (doubled.count(key(v, next)) || doubled.count(key(next, v))) continue;
        const auto across = edgeCorner.find(key(next, v));
        if (across == edgeCorner.end()) continue;
        const size_t other = 3 * (across->second / 3) + (across->second % 3 + 1) % 3;
        const size_t a = find(c), b = find(other);
        if (a != b) parent[std::max(a, b)] = std::min(a, b);
    }
    // The first fan met at a vertex keeps it; each other fan's corners move to a new one.
    const size_t none = std::numeric_limits<size_t>::max();
    std::vector<size_t> fanOf(vertices.size(), none);
    std::unordered_map<size_t, size_t> fanVertex;
    const size_t before = vertices.size();
    for (size_t c = 0; c < corners; ++c) {
        size_t& corner = triangles[c / 3][c % 3];
        const size_t fan = find(c);
        if (fanOf[corner] == none || fanOf[corner] == fan) {
            fanOf[corner] = fan;
            continue;
        }
        const auto made = fanVertex.find(fan);
        if (made != fanVertex.end()) {
            corner = made->second;
            continue;
        }
        const size_t v = corner, copy = vertices.size();
        const Vector3 position = vertices[v];
        vertices.push_back(position);
        if (density.size() == copy) density.push_back(density[v]);
        if (refine.size() == copy) refine.push_back(refine[v]);
        fanOf.push_back(fan);
        fanVertex.emplace(fan, copy);
        corner = copy;
    }
    return vertices.size() - before;
}

// Adaptivity's target edge length per vertex (the core's resample): shorter where the
// normals turn faster than at three quarters of the vertices, longer where flatter, with
// the integral of area / h² kept, so the budget moves rather than grows. Empty for none.
std::vector<double> adaptiveTargetLengths(const std::vector<Vector3>& vertices,
    const std::vector<std::vector<size_t>>& triangles, double voxelSize, double adaptivity)
{
    std::vector<double> lengths;
    if (adaptivity <= 0.0 || vertices.empty()) return lengths;
    const double minRatio = 0.35, maxRatio = 3.0, epsilon = 1e-12;
    std::vector<Vector3> faceNormals(triangles.size());
    std::vector<double> faceAreas(triangles.size(), 0.0);
    for (size_t i = 0; i < triangles.size(); ++i) {
        const auto& t = triangles[i];
        faceAreas[i] = Vector3::area(vertices[t[0]], vertices[t[1]], vertices[t[2]]);
        if (faceAreas[i] > epsilon) faceNormals[i] = Vector3::normal(vertices[t[0]], vertices[t[1]], vertices[t[2]]);
    }
    std::vector<Vector3> normals(vertices.size());
    std::vector<std::vector<size_t>> neighbours(vertices.size());
    for (size_t i = 0; i < triangles.size(); ++i) {
        if (faceAreas[i] <= epsilon) continue;
        const auto& t = triangles[i];
        const Vector3 weighted = faceNormals[i] * faceAreas[i];
        for (size_t k = 0; k < 3; ++k) {
            normals[t[k]] += weighted;
            neighbours[t[k]].push_back(t[(k + 1) % 3]);
            neighbours[t[k]].push_back(t[(k + 2) % 3]);
        }
    }
    for (size_t v = 0; v < vertices.size(); ++v) {
        normals[v].normalize();
        auto& ring = neighbours[v];
        std::sort(ring.begin(), ring.end());
        ring.erase(std::unique(ring.begin(), ring.end()), ring.end());
    }
    std::vector<double> curvature(vertices.size(), 0.0);
    for (size_t v = 0; v < vertices.size(); ++v) {
        const auto& ring = neighbours[v];
        if (ring.empty() || normals[v].lengthSquared() <= epsilon) continue;
        double turned = 0.0, length = 0.0;
        for (const auto u : ring) {
            const double d = (vertices[u] - vertices[v]).length();
            if (d <= epsilon || normals[u].lengthSquared() <= epsilon) continue;
            turned += std::acos(std::max(-1.0, std::min(1.0, Vector3::dotProduct(normals[v], normals[u]))));
            length += d;
        }
        if (length > epsilon) curvature[v] = turned / length;
    }
    std::vector<double> nonZero;
    nonZero.reserve(curvature.size());
    for (const double c : curvature)
        if (c > epsilon) nonZero.push_back(c);
    if (nonZero.empty()) return lengths;
    const size_t reference = (nonZero.size() - 1) * 3 / 4;
    std::nth_element(nonZero.begin(), nonZero.begin() + reference, nonZero.end());
    const double curvatureReference = nonZero[reference];
    std::vector<double> importance(vertices.size(), 1.0);
    const double strength = std::min(adaptivity, 2.0) * 7.0;
    for (size_t v = 0; v < vertices.size(); ++v) {
        const double normalized = std::min(4.0, curvature[v] / std::max(curvatureReference, epsilon));
        importance[v] += strength * normalized * normalized;
    }
    double totalArea = 0.0, weightedImportance = 0.0;
    for (size_t i = 0; i < triangles.size(); ++i) {
        const auto& t = triangles[i];
        totalArea += faceAreas[i];
        weightedImportance += faceAreas[i] * (importance[t[0]] + importance[t[1]] + importance[t[2]]) / 3.0;
    }
    if (totalArea <= epsilon) return lengths;
    const double average = weightedImportance / totalArea;
    lengths.resize(vertices.size());
    for (size_t v = 0; v < vertices.size(); ++v)
        lengths[v] = voxelSize * std::max(minRatio, std::min(maxRatio, std::sqrt(average / importance[v])));
    return lengths;
}

// The quad size per vertex blurred in the log over `rounds` rounds of half toward the
// ring's mean: the field the size steers turns across the band a change is spread over,
// and a step one triangle wide asks it to turn on the spot, which it cannot, so a few
// pentagons come out there. Four rounds (about two quads wide at the isotropic mesh's
// half-quad edge) left none on the test spheres and kept most of the contrast.
std::vector<double> blurredScale(const std::vector<double>& scale, const std::vector<std::vector<size_t>>& triangles, int rounds)
{
    std::vector<std::vector<size_t>> ring(scale.size());
    for (const auto& t : triangles)
        for (size_t k = 0; k < 3; ++k) {
            ring[t[k]].push_back(t[(k + 1) % 3]);
            ring[t[k]].push_back(t[(k + 2) % 3]);
        }
    std::vector<double> logs(scale.size()), next(scale.size());
    for (size_t v = 0; v < logs.size(); ++v) logs[v] = std::log(std::max(1e-6, scale[v]));
    for (int r = 0; r < rounds; ++r) {
        for (size_t v = 0; v < logs.size(); ++v) {
            double sum = 0.0;
            for (const size_t u : ring[v]) sum += logs[u];
            next[v] = ring[v].empty() ? logs[v] : 0.5 * logs[v] + 0.5 * sum / (double)ring[v].size();
        }
        logs.swap(next);
    }
    std::vector<double> out(scale.size());
    for (size_t v = 0; v < out.size(); ++v) out[v] = std::exp(logs[v]);
    return out;
}

// Drops the feature chains too short to follow: a chain (edges joined end to end, apart
// from the rest at junctions and loose ends) shorter than two quad edges would give the
// quads nothing to run along, only a kink; a tiny group's border is such a chain.
void dropShortFeatureChains(const std::vector<Vector3>& vertices, std::vector<std::pair<size_t, size_t>>& features, double quadEdge)
{
    if (features.empty()) return;
    std::vector<size_t> degree(vertices.size(), 0);
    for (const auto& edge : features) {
        ++degree[edge.first];
        ++degree[edge.second];
    }
    // A chain is a connected run of edges through vertices of degree two; edges meet at
    // a junction (degree three or more) without joining chains, so each chain is a set
    // of edges united through the degree-two vertices only.
    std::vector<size_t> parent(features.size());
    for (size_t e = 0; e < features.size(); ++e) parent[e] = e;
    const auto find = [&](size_t e) {
        while (parent[e] != e) {
            parent[e] = parent[parent[e]];
            e = parent[e];
        }
        return e;
    };
    std::vector<size_t> through(vertices.size(), std::numeric_limits<size_t>::max());
    for (size_t e = 0; e < features.size(); ++e)
        for (size_t v : { features[e].first, features[e].second }) {
            if (degree[v] != 2) continue;
            if (through[v] == std::numeric_limits<size_t>::max()) through[v] = e;
            else parent[find(through[v])] = find(e);
        }
    std::vector<double> length(features.size(), 0.0);
    for (size_t e = 0; e < features.size(); ++e)
        length[find(e)] += (vertices[features[e].first] - vertices[features[e].second]).length();
    std::vector<std::pair<size_t, size_t>> kept;
    kept.reserve(features.size());
    for (size_t e = 0; e < features.size(); ++e)
        if (length[find(e)] >= 2.0 * quadEdge) kept.push_back(features[e]);
    features = std::move(kept);
}

// Where the feature polylines run, per vertex: the vertices, with those inside a chain
// (two feature edges) eased toward their chain neighbours a few times, each moved at most
// its own edges' length, so a border jagged at the triangles' scale (a polygroup's, which
// follows triangle edges) reads as the curve it draws rather than as teeth the quads
// would have to follow, as ZRemesher's SmoothGroups eases a group's border. A junction,
// a loose end and every other vertex stay as they are.
std::vector<Vector3> smoothedFeaturePositions(const std::vector<Vector3>& vertices,
    const std::vector<std::pair<size_t, size_t>>& features)
{
    std::vector<Vector3> positions = vertices;
    std::vector<std::vector<size_t>> chain(vertices.size());
    for (const auto& edge : features) {
        if (edge.first >= vertices.size() || edge.second >= vertices.size()) continue;
        chain[edge.first].push_back(edge.second);
        chain[edge.second].push_back(edge.first);
    }
    std::vector<double> reach(vertices.size(), 0.0);
    for (size_t v = 0; v < vertices.size(); ++v)
        if (chain[v].size() == 2)
            reach[v] = 0.5 * ((vertices[chain[v][0]] - vertices[v]).length() + (vertices[chain[v][1]] - vertices[v]).length());
    const int rounds = 4;
    for (int round = 0; round < rounds; ++round) {
        std::vector<Vector3> eased = positions;
        for (size_t v = 0; v < vertices.size(); ++v) {
            if (chain[v].size() != 2) continue;
            const Vector3 middle = (positions[chain[v][0]] + positions[chain[v][1]]) * 0.5;
            Vector3 moved = positions[v] + (middle - positions[v]) * 0.5;
            const Vector3 away = moved - vertices[v];
            const double distance = away.length();
            if (distance > reach[v] && distance > 0.0) moved = vertices[v] + away * (reach[v] / distance);
            eased[v] = moved;
        }
        positions = std::move(eased);
    }
    return positions;
}

// One island of the input, remeshed on its own: its vertices and triangles (compacted),
// the isotropic mesh they become, and the quads extracted from it.
struct Island {
    std::vector<Vector3> vertices;
    std::vector<std::vector<size_t>> triangles;
    std::vector<std::pair<size_t, size_t>> features; // feature edges, in the island's vertex numbers
    std::vector<double> density; // per vertex, quads per area relative to the mean (Qm_Params.density); empty for none
    std::vector<double> refine; // per vertex, the isotropic edge's share (Qm_Params.refine); empty for none
    std::vector<Vector3> outVertices;
    std::vector<std::vector<size_t>> outFaces;
};

struct Stages {
    std::atomic<long long> decimateUs { 0 }, isotropicUs { 0 }, parameterizeUs { 0 }, extractUs { 0 };
    std::atomic<long long> isotropicTriangles { 0 }, covers { 0 };
};

// The guide curves (Qm_Params.guides) as segments, shared by every island: no segment is
// longer than `cell`, so each lies in the cells its ends do and their neighbours, and a
// face looks in the 27 cells round its middle for the segments within `cell` of it.
struct Guides {
    std::vector<std::pair<Vector3, Vector3>> segments;
    std::unordered_map<uint64_t, std::vector<size_t>> cells;
    double cell = 0.0;
    double weight = 0.0;

    static uint64_t key(int64_t x, int64_t y, int64_t z)
    {
        const auto part = [](int64_t a) { return (uint64_t)(a + (1 << 20)) & 0x1fffff; };
        return (part(x) << 42) | (part(y) << 21) | part(z);
    }
    void cellOf(const Vector3& p, int64_t* c) const
    {
        for (int k = 0; k < 3; ++k) c[k] = (int64_t)std::floor(p[k] / cell);
    }
};

// The guides cut to pieces no longer than `cell` and filed by cell; `strength` 0..1 becomes
// the frame field's weight s / (1 - s + 0.01): about 1 at a half, as strong as the
// curvature's strongest pull, and 100 at full, where the field follows the guide nearly
// exactly. Empty for no guides or no strength.
Guides makeGuides(const Qm_Params& params, double cell)
{
    Guides g;
    const double s = std::isfinite(params.guide_strength) ? std::max(0.0, std::min(1.0, (double)params.guide_strength)) : 0.0;
    if (nullptr == params.guides || 0 == params.guide_count || s <= 0.0 || !(cell > 0.0)) return g;
    g.cell = cell;
    g.weight = s / (1.0 - s + 0.01);
    for (uint32_t i = 0; i < params.guide_count; ++i) {
        const float* q = params.guides + 6 * (size_t)i;
        const Vector3 a(q[0], q[1], q[2]), b(q[3], q[4], q[5]);
        if (!std::isfinite(a.x() + a.y() + a.z() + b.x() + b.y() + b.z())) continue;
        const double length = (b - a).length();
        if (!(length > 1e-12)) continue;
        const size_t pieces = std::min<size_t>(1 << 16, (size_t)std::ceil(length / cell));
        for (size_t k = 0; k < pieces; ++k)
            g.segments.push_back({ a + (b - a) * ((double)k / pieces), a + (b - a) * ((double)(k + 1) / pieces) });
    }
    for (size_t i = 0; i < g.segments.size(); ++i) {
        int64_t c[3];
        g.cellOf((g.segments[i].first + g.segments[i].second) * 0.5, c);
        g.cells[Guides::key(c[0], c[1], c[2])].push_back(i);
    }
    return g;
}

// Per face of the isotropic mesh, the direction the guides ask its quads' edges to take
// (the nearest segment's, in the face's plane) times the weight, falling off to nothing
// at `reach` quad edges from the segment (each face's quad edge is `quadEdge` times its
// corners' mean vertexScale); zero for a face no guide comes near. Empty when no face is.
std::vector<Vector3> faceGuides(const Guides& guides, const std::vector<Vector3>& vertices,
    const std::vector<std::vector<size_t>>& triangles, const std::vector<double>& vertexScale, double quadEdge)
{
    constexpr double reach = 0.75;
    std::vector<Vector3> out;
    if (guides.segments.empty()) return out;
    out.assign(triangles.size(), Vector3());
    bool any = false;
    for (size_t f = 0; f < triangles.size(); ++f) {
        const auto& t = triangles[f];
        const Vector3 &p0 = vertices[t[0]], &p1 = vertices[t[1]], &p2 = vertices[t[2]];
        const Vector3 middle = (p0 + p1 + p2) / 3.0;
        const double s = vertexScale.size() == vertices.size() ? (vertexScale[t[0]] + vertexScale[t[1]] + vertexScale[t[2]]) / 3.0 : 1.0;
        const double within = std::min(reach * quadEdge * s, guides.cell);
        int64_t c[3];
        guides.cellOf(middle, c);
        double best = within;
        size_t nearest = std::numeric_limits<size_t>::max();
        for (int64_t dx = -1; dx <= 1; ++dx)
            for (int64_t dy = -1; dy <= 1; ++dy)
                for (int64_t dz = -1; dz <= 1; ++dz) {
                    const auto found = guides.cells.find(Guides::key(c[0] + dx, c[1] + dy, c[2] + dz));
                    if (found == guides.cells.end()) continue;
                    for (const size_t i : found->second) {
                        const Vector3 &a = guides.segments[i].first, &b = guides.segments[i].second;
                        const Vector3 ab = b - a;
                        const double along = std::max(0.0, std::min(1.0, Vector3::dotProduct(middle - a, ab) / ab.lengthSquared()));
                        const double d = (a + ab * along - middle).length();
                        if (d < best || (d == best && i < nearest)) {
                            best = d;
                            nearest = i;
                        }
                    }
                }
        if (nearest == std::numeric_limits<size_t>::max()) continue;
        const Vector3 normal = Vector3::crossProduct(p1 - p0, p2 - p0).normalized();
        Vector3 direction = guides.segments[nearest].second - guides.segments[nearest].first;
        direction = direction - normal * Vector3::dotProduct(direction, normal);
        if (!(direction.length() > 1e-12)) continue;
        out[f] = direction.normalized() * (guides.weight * (1.0 - best / within));
        any = true;
    }
    if (!any) out.clear();
    return out;
}

// An island's first stage: feature chains too short to follow dropped, the island
// decimated when it is far denser than the target, and pinched vertices split. Returns
// whether it was decimated; `added` is how many vertices the unpinch made.
bool thinIsland(Island& island, double voxelSize, double quadEdge, double sharpDegrees, size_t* added)
{
    dropShortFeatureChains(island.vertices, island.features, quadEdge);
    const bool decimated = decimateIfDense(island.vertices, island.triangles, island.features, island.density, island.refine, voxelSize, sharpDegrees);
    const size_t made = unpinch(island.vertices, island.triangles, island.density, island.refine);
    if (added) *added = made;
    return decimated;
}

// An island's second stage: the isotropic remesh at the target edge, which replaces the
// island's vertices and triangles. `vertexScale` gets the quad size per vertex the density
// asks (blurred; empty for none) and `cornerFeature` the remeshed feature edges as flags on
// the corners (empty for none).
void isotropicIsland(Island& island, double voxelSize, double adaptivity, double sharpDegrees,
    const AutoRemesher::ProgressHandler& progress, std::vector<double>& vertexScale, std::vector<char>& cornerFeature)
{
    auto& vertices = island.vertices;
    auto& triangles = island.triangles;
    vertexScale.clear();
    cornerFeature.clear();
    std::vector<double> targetLengths = adaptiveTargetLengths(vertices, triangles, voxelSize, adaptivity);
    // The density shortens the edges where it asks for more quads: a quad's edge goes as
    // 1 / sqrt(density). The isotropic remesh carries that factor to its vertices (its
    // payload), and the cover's scaling takes it per face from there.
    const bool dense = island.density.size() == vertices.size();
    std::vector<double> edgeFactor;
    if (dense) {
        edgeFactor.resize(vertices.size());
        for (size_t v = 0; v < vertices.size(); ++v) edgeFactor[v] = 1.0 / std::sqrt(island.density[v]);
        if (targetLengths.empty()) targetLengths.assign(vertices.size(), voxelSize);
        for (size_t v = 0; v < vertices.size(); ++v) targetLengths[v] *= edgeFactor[v];
    }
    // The refinement shortens the isotropic edges alone: the payload (the quads' size)
    // does not see it.
    if (island.refine.size() == vertices.size()) {
        if (targetLengths.empty()) targetLengths.assign(vertices.size(), voxelSize);
        for (size_t v = 0; v < vertices.size(); ++v) targetLengths[v] *= island.refine[v];
    }
    AutoRemesher::IsotropicRemesher isotropic(vertices, triangles);
    isotropic.setProgressHandler(progress);
    isotropic.setTargetEdgeLength(voxelSize);
    if (!targetLengths.empty()) isotropic.setVertexTargetEdgeLengths(&targetLengths);
    isotropic.setSharpEdgeDegrees(sharpDegrees);
    isotropic.setSmoothNormalDegrees(0.0);
    if (dense) isotropic.setVertexPayloads(&edgeFactor);
    std::vector<Vector3> featurePositions;
    if (!island.features.empty()) {
        featurePositions = smoothedFeaturePositions(vertices, island.features);
        isotropic.setFeatureEdges(&island.features);
        isotropic.setFeaturePositions(&featurePositions);
    }
    isotropic.remesh();
    vertices = isotropic.remeshedVertices();
    triangles = isotropic.remeshedTriangles();
    if (dense && isotropic.remeshedVertexPayloads().size() == vertices.size())
        vertexScale = blurredScale(isotropic.remeshedVertexPayloads(), triangles, 4);
    // The remeshed mesh's feature edges (the caller's, carried through, and the edges
    // sharp by angle), as flags on the corners the parameterizer judges.
    if (!island.features.empty()) {
        std::unordered_set<uint64_t> featured;
        for (const auto& edge : isotropic.remeshedFeatureEdges())
            featured.insert(((uint64_t)std::min(edge.first, edge.second) << 32) | (uint64_t)std::max(edge.first, edge.second));
        cornerFeature.assign(3 * triangles.size(), 0);
        for (size_t f = 0; f < triangles.size(); ++f)
            for (size_t k = 0; k < 3; ++k) {
                const size_t a = triangles[f][k], b = triangles[f][(k + 1) % 3];
                if (featured.count(((uint64_t)std::min(a, b) << 32) | (uint64_t)std::max(a, b))) cornerFeature[3 * f + k] = 1;
            }
    }
}

// What one quad cover gives: a UV per triangle corner (the same twice, as the extractor
// takes them) and the field's singular vertices.
struct Cover {
    std::unique_ptr<std::vector<std::vector<AutoRemesher::Vector2>>> uvs;
    std::vector<std::vector<AutoRemesher::Vector2>> originalUvs;
    std::vector<size_t> singular;
};

// An island's third stage, once: the frame field, the singularity simplification and the
// quad cover at `scaling`. False when it fails, with `failure` saying why ("" when the core
// gave no reason of its own but its console line); a cancel passes through.
bool coverIsland(const std::vector<Vector3>& vertices, const std::vector<std::vector<size_t>>& triangles,
    double scaling, double adaptivity, double anisotropy, double sharpDegrees,
    const std::vector<char>& cornerFeature, const std::vector<double>& vertexScale, const std::vector<Vector3>& guided,
    const AutoRemesher::ProgressHandler& progress, Cover& out, std::string& failure)
{
    AutoRemesher::Parameterizer parameterizer(&vertices, &triangles, nullptr);
    parameterizer.setProgressHandler(progress);
    parameterizer.setScaling(scaling);
    parameterizer.setGradientAdaptivity(adaptivity);
    parameterizer.setAnisotropy(anisotropy);
    parameterizer.setSharpEdgeDegrees(sharpDegrees);
    if (!cornerFeature.empty()) parameterizer.setCornerFeatures(&cornerFeature);
    if (!vertexScale.empty()) parameterizer.setVertexScaling(&vertexScale);
    if (!guided.empty()) parameterizer.setFaceGuides(&guided);
    bool parameterized = true;
    failure.clear();
    try {
        parameterized = parameterizer.parameterize();
    } catch (const Qm_Cancel&) {
        throw;
    } catch (const std::exception& e) {
        parameterized = false;
        failure = std::string("parameterization failed: ") + e.what();
    } catch (...) {
        parameterized = false;
        failure = "parameterization failed";
    }
    if (!parameterized) return false;
    out.uvs = parameterizer.takeTriangleUvs();
    out.originalUvs = parameterizer.originalTriangleUvs();
    out.singular = parameterizer.singularVertexIndices();
    return true;
}

// The cover's area in cells over the triangles not on a cap.
double coverCells(const std::vector<std::vector<AutoRemesher::Vector2>>& uvs, const std::vector<char>& capFace)
{
    double cells = 0.0;
    for (size_t f = 0; f < uvs.size(); ++f) {
        const auto& t = uvs[f];
        if (t.size() != 3 || (f < capFace.size() && capFace[f])) continue;
        cells += 0.5 * std::fabs((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1]));
    }
    return cells;
}

// An island's last stage: the quads traced from the cover and cleaned up. False when the
// extractor gave none.
bool extractIsland(const std::vector<Vector3>& vertices, const std::vector<std::vector<size_t>>& triangles,
    const Cover& cover, const std::vector<char>& cornerFeature, const AutoRemesher::ProgressHandler& progress,
    std::vector<Vector3>& outVertices, std::vector<std::vector<size_t>>& outFaces)
{
    AutoRemesher::QuadExtractor extractor(&vertices, &triangles, cover.uvs.get());
    extractor.setOriginalTriangleUvs(&cover.originalUvs);
    // The feature edges as segments, so the extractor's smoothing keeps a quad vertex on
    // them where the cover put it.
    std::vector<std::pair<Vector3, Vector3>> featureSegments;
    if (!cornerFeature.empty()) {
        for (size_t c = 0; c < cornerFeature.size(); ++c)
            if (cornerFeature[c]) {
                const size_t a = triangles[c / 3][c % 3], b = triangles[c / 3][(c % 3 + 1) % 3];
                if (a < b) featureSegments.push_back({ vertices[a], vertices[b] });
            }
        extractor.setFeatureSegments(&featureSegments);
    }
    extractor.setSingularVertices(&cover.singular);
    extractor.setProgressHandler(progress);
    if (!extractor.extract()) return false;
    outVertices = extractor.remeshedVertices();
    outFaces = extractor.remeshedQuads();
    return true;
}

// Runs the stages on one island; progress reported as the island's share. An island whose
// parameterization fails is left without quads, with the reason kept for the report, as
// the core does; a cancel passes through. The Odin driver (quadmesh/driver.odin) runs the
// same stages one call at a time and must give the same result bit for bit.
void remeshIsland(size_t index, Island& island, const Qm_Params& params, double voxelSize, double quadEdge,
    const Guides& guides, Handler& handler, Stages& stages)
{
    auto& vertices = island.vertices;
    auto& triangles = island.triangles;
    const auto stageProgress = [&handler, index](float begin, float end) {
        return AutoRemesher::ProgressHandler([&handler, index, begin, end](float fraction, const char* name) {
            handler.report(index, begin + (end - begin) * fraction, name);
        });
    };

    handler.report(index, 0.0f, "Remeshing uniformly");
    const auto t0 = Clock::now();
    thinIsland(island, voxelSize, quadEdge, params.sharp_degrees, nullptr);
    const auto t1 = Clock::now();
    stages.decimateUs += (long long)(1000.0 * milliseconds(t0, t1));
    std::vector<double> vertexScale;
    std::vector<char> cornerFeature;
    isotropicIsland(island, voxelSize, params.adaptivity, params.sharp_degrees, stageProgress(0.0f, islandResampleEnd), vertexScale, cornerFeature);
    const auto t2 = Clock::now();
    stages.isotropicUs += (long long)(1000.0 * milliseconds(t1, t2));
    stages.isotropicTriangles += (long long)triangles.size();
    handler.report(index, islandResampleEnd, nullptr);
    if (vertices.empty() || triangles.empty()) {
        handler.report(index, 1.0f, nullptr);
        return;
    }

    // The cover multiplies its scaling by the isotropic mesh's mean edge (the same mean
    // SurfaceMesh gives here), so the quad edge wanted divided by that mean asks for it.
    // The cover's least squares then lands under the ask where the field has curl it
    // cannot flatten (a sphere's cover comes out a tenth short, a bumpy one a third), and
    // the quad extraction keeps the cover's cells, so the cover's own area in cells says
    // how far off the count will be before any quad exists: a second cover with the
    // scaling corrected by that measure lands within a few percent, and the few islands
    // that land at once skip it. Where the second still misses (a cap's rim or a feature
    // edge holds whole rows of cells, so the count moves in steps), a third cover corrects
    // it again, and the cover nearest the ask is kept. A count that `Params.scaling` fixed
    // is left alone.
    const bool landing = params.scaling <= 0.0;
    double scaling = params.scaling;
    if (landing) {
        const AutoRemesher::SurfaceMesh measured(vertices, triangles);
        const double mean = measured.averageEdgeLength();
        scaling = mean > 0.0 ? quadEdge / mean : 1.0;
    }
    // A face whose quads are s times the size (the mean of its corners' vertexScale) covers
    // 1 / s² as many cells; a face on a cap plane (Qm_Params.cap_axes) counts for none, here
    // and in the cells measured below.
    std::vector<char> capFace(triangles.size(), 0);
    for (size_t f = 0; f < triangles.size(); ++f)
        capFace[f] = onCap(params, vertices[triangles[f][0]], vertices[triangles[f][1]], vertices[triangles[f][2]], std::max((double)params.cap_snap, 0.05 * voxelSize));
    double scaledArea = 0.0;
    for (size_t f = 0; f < triangles.size(); ++f) {
        if (capFace[f]) continue;
        const double a = Vector3::area(vertices[triangles[f][0]], vertices[triangles[f][1]], vertices[triangles[f][2]]);
        const auto& t = triangles[f];
        const double s = vertexScale.size() == vertices.size() ? (vertexScale[t[0]] + vertexScale[t[1]] + vertexScale[t[2]]) / 3.0 : 1.0;
        scaledArea += a / (s * s);
    }
    const double cellsWanted = scaledArea / (quadEdge * quadEdge);
    const std::vector<Vector3> guided = faceGuides(guides, vertices, triangles, vertexScale, quadEdge);
    Cover cover;
    const float coverSpan = islandParameterizeEnd - islandResampleEnd;
    // The cover nearest the ask so far, and the nearest scalings measured under and over it
    // (their cells off the caps; 0 for none yet).
    Cover best;
    double bestMiss = 0.0, underScaling = 0.0, underCells = 0.0, overScaling = 0.0, overCells = 0.0;
    for (int pass = 0; pass < 3; ++pass) {
        // The first cover takes the whole parameterize share of the bar; a later one takes
        // the last third of it again, so the bar steps back a little rather than stalling.
        const float begin = pass == 0 ? islandResampleEnd : islandResampleEnd + coverSpan * 0.67f;
        ++stages.covers;
        std::string failure;
        if (!coverIsland(vertices, triangles, scaling, params.adaptivity, params.anisotropy > 0.0f ? params.anisotropy : 1.0,
                params.sharp_degrees, cornerFeature, vertexScale, guided, stageProgress(begin, islandParameterizeEnd), cover, failure)) {
            if (!failure.empty()) handler.failed(failure);
            const auto tFailed = Clock::now();
            stages.parameterizeUs += (long long)(1000.0 * milliseconds(t2, tFailed));
            handler.report(index, 1.0f, nullptr);
            return;
        }
        if (!landing || !cover.uvs) break;
        const double cells = coverCells(*cover.uvs, capFace);
        if (cells <= 0.0 || cellsWanted <= 0.0) break;
        const double miss = std::fabs(cells / cellsWanted - 1.0);
        if (pass == 0 || miss < bestMiss) {
            best = std::move(cover);
            cover = Cover();
            bestMiss = miss;
        }
        if (bestMiss <= 0.03 || pass == 2) break;
        // A cover a quarter of the ask or less, or four times it, came out folded up (a
        // creature's half gave a tenth of its cells at one scaling and about the ask at two
        // thirds of it), and says nothing of how the cells go with the scaling, so it bounds
        // no bracket: interpolating towards it put the next cover where the last had been.
        const bool folded = cells * 4.0 <= cellsWanted || cells >= 4.0 * cellsWanted;
        if (!folded && cells < cellsWanted && cells > underCells) underScaling = scaling, underCells = cells;
        if (!folded && cells > cellsWanted && (overCells == 0.0 || cells < overCells)) overScaling = scaling, overCells = cells;
        // Between a cover under the ask and one over it, the scaling is found between theirs
        // as the cells go; otherwise the cells go as the scaling squared, inversely, a step
        // held within a factor of 1.5 either way, so a folded cover moves it by no more.
        if (underCells > 0.0 && overCells > 0.0)
            scaling = underScaling * std::pow(overScaling / underScaling, std::log(cellsWanted / underCells) / std::log(overCells / underCells));
        else
            scaling *= std::max(1.0 / 1.5, std::min(1.5, std::sqrt(cells / cellsWanted)));
    }
    if (best.uvs) cover = std::move(best);
    const auto t3 = Clock::now();
    stages.parameterizeUs += (long long)(1000.0 * milliseconds(t2, t3));
    handler.report(index, islandParameterizeEnd, nullptr);
    extractIsland(vertices, triangles, cover, cornerFeature, stageProgress(islandParameterizeEnd, 1.0f), island.outVertices, island.outFaces);
    const auto t4 = Clock::now();
    stages.extractUs += (long long)(1000.0 * milliseconds(t3, t4));
    handler.report(index, 1.0f, nullptr);
}

// Runs `body` over the islands: on the caller when there is one island or one thread,
// else on up to `threads` threads of its own, each taking the next island; the first
// exception thrown on a thread is thrown again here once every thread has joined.
template <typename Body>
void overIslands(size_t count, unsigned threads, const Body& body)
{
    if (count <= 1 || threads <= 1) {
        for (size_t i = 0; i < count; ++i) body(i);
        return;
    }
    std::atomic<size_t> next { 0 };
    std::mutex failedLock;
    std::exception_ptr failed;
    std::vector<std::thread> pool;
    pool.reserve(std::min<size_t>(threads, count));
    for (unsigned t = 0; t < threads && t < count; ++t)
        pool.emplace_back([&] {
            // The stages' own parallel loops stay on this thread: the islands are the
            // parallelism, and the result is the same either way.
            tbb::detail::in_worker = true;
            for (;;) {
                const size_t i = next.fetch_add(1);
                if (i >= count) break;
                try {
                    body(i);
                } catch (...) {
                    std::lock_guard<std::mutex> guard(failedLock);
                    if (!failed) failed = std::current_exception();
                }
            }
        });
    for (auto& th : pool) th.join();
    if (failed) std::rethrow_exception(failed);
}

}

extern "C" int qm_remesh(const float* positions, uint32_t vertex_count, const uint32_t* triangles, uint32_t triangle_count,
    const Qm_Params* params, Qm_Progress progress, void* tag, Qm_Result** out, char* error, size_t error_size)
{
    *out = nullptr;
    say(error, error_size, "");
    Handler handler { progress, tag, {}, {}, {}, {}, false };
    Sink& console = sink();
    const auto start = Clock::now();
    try {
        if (vertex_count == 0 || triangle_count == 0) {
            say(error, error_size, "the mesh is empty");
            return QM_FAILED;
        }
        if (params->quads == 0) {
            say(error, error_size, "no quads asked for");
            return QM_FAILED;
        }
        std::vector<Vector3> vertices;
        vertices.reserve(vertex_count);
        for (uint32_t v = 0; v < vertex_count; ++v)
            vertices.emplace_back(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]);
        std::vector<std::vector<size_t>> faces(triangle_count, std::vector<size_t>(3));
        for (uint32_t t = 0; t < triangle_count; ++t)
            for (size_t k = 0; k < 3; ++k) faces[t][k] = triangles[3 * t + k];

        const unsigned threads = std::max(1u, std::min(params->threads, 16u));
        quadmesh_threads = threads;
        handler.whole(0.0f, "Computing voxel size");
        // The core's isotropic target: a triangle of the area that twice the quads
        // asked would give, as an equilateral; the quad edge wanted is the plain one.
        // Under Keep symmetry the caps' area takes no quads: the count asked is the rest's.
        const double area = meshArea(vertices, countedTriangles(*params, vertices, faces));
        const double voxelSize = std::sqrt((area / (2.0 * params->quads)) / (0.86602540378 * 0.5));
        const double quadEdge = std::sqrt(area / params->quads);
        if (!(voxelSize > 0.0) || !(quadEdge > 0.0)) {
            say(error, error_size, "the mesh has no area");
            return QM_FAILED;
        }

        handler.whole(0.01f, "Splitting mesh into islands");
        std::vector<std::vector<std::vector<size_t>>> islandFaces;
        AutoRemesher::MeshSeparator::splitToIslands(faces, islandFaces);
        if (islandFaces.empty()) {
            say(error, error_size, "the mesh is empty");
            return QM_FAILED;
        }
        std::vector<Island> islands(islandFaces.size());
        handler.islandProgress.assign(islands.size(), 0.0f);
        handler.islandWeight.assign(islands.size(), 1.0f);
        // A vertex belongs to one island (they are the connected pieces), so a feature
        // edge goes to the island of its ends, in that island's vertex numbers.
        const size_t none = std::numeric_limits<size_t>::max();
        std::vector<size_t> islandOf(vertices.size(), none), localOf(vertices.size(), none);
        for (size_t i = 0; i < islands.size(); ++i) {
            Island& island = islands[i];
            island.triangles.reserve(islandFaces[i].size());
            for (const auto& face : islandFaces[i]) {
                std::vector<size_t> t(3);
                for (size_t k = 0; k < 3; ++k) {
                    const size_t v = face[k];
                    if (localOf[v] == none || islandOf[v] != i) {
                        islandOf[v] = i;
                        localOf[v] = island.vertices.size();
                        island.vertices.push_back(vertices[v]);
                    }
                    t[k] = localOf[v];
                }
                island.triangles.push_back(std::move(t));
            }
            handler.islandWeight[i] = (float)((double)islandFaces[i].size() / (double)faces.size());
        }
        // The density, relative to its mean over the area, so the count stays what was
        // asked wherever the quads go; then each island takes its vertices' share.
        if (nullptr != params->density && params->density_count == vertex_count) {
            std::vector<double> density(vertex_count);
            for (uint32_t v = 0; v < vertex_count; ++v) {
                const double d = params->density[v];
                density[v] = std::isfinite(d) ? std::max(1.0 / 16.0, std::min(16.0, d)) : 1.0;
            }
            const double mean = densityArea(vertices, countedTriangles(*params, vertices, faces), density) / area;
            if (mean > 0.0)
                for (double& d : density) d /= mean;
            // An even density is none: the remesh then runs exactly as without it (the
            // scaled field turns off the singularity simplification).
            const auto [least, most] = std::minmax_element(density.begin(), density.end());
            if (*most - *least < 1e-3) density.clear();
            for (size_t v = 0; v < density.size(); ++v)
                if (islandOf[v] != none) {
                    auto& local = islands[islandOf[v]].density;
                    if (local.size() != islands[islandOf[v]].vertices.size()) local.assign(islands[islandOf[v]].vertices.size(), 1.0);
                    local[localOf[v]] = density[v];
                }
        }
        // The refinement as given (clamped), each island its vertices' share; none when
        // nothing is refined.
        if (nullptr != params->refine && params->refine_count == vertex_count) {
            std::vector<double> refine(vertex_count);
            bool any = false;
            for (uint32_t v = 0; v < vertex_count; ++v) {
                const double r = params->refine[v];
                refine[v] = std::isfinite(r) ? std::max(0.25, std::min(1.0, r)) : 1.0;
                any = any || refine[v] < 1.0;
            }
            if (any)
                for (size_t v = 0; v < refine.size(); ++v)
                    if (islandOf[v] != none) {
                        auto& local = islands[islandOf[v]].refine;
                        if (local.size() != islands[islandOf[v]].vertices.size()) local.assign(islands[islandOf[v]].vertices.size(), 1.0);
                        local[localOf[v]] = refine[v];
                    }
        }
        if (nullptr != params->features)
            for (uint32_t e = 0; e < params->feature_count; ++e) {
                const uint32_t a = params->features[2 * e], b = params->features[2 * e + 1];
                if (a >= vertices.size() || b >= vertices.size() || a == b) continue;
                if (islandOf[a] == none || islandOf[a] != islandOf[b]) continue;
                islands[islandOf[a]].features.push_back({ localOf[a], localOf[b] });
            }
        islandFaces.clear();
        islandFaces.shrink_to_fit();

        // The guides reach a face within three quarters of its quad edge, at most four
        // times the plain one where the density makes the quads larger.
        const Guides guides = makeGuides(*params, 4.0 * 0.75 * quadEdge);
        Stages stages;
        handler.whole(parallelPhaseBegin, "Remeshing uniformly");
        overIslands(islands.size(), threads, [&](size_t i) {
            remeshIsland(i, islands[i], *params, voxelSize, quadEdge, guides, handler, stages);
        });

        handler.whole(parallelPhaseEnd, "Merging mesh islands");
        std::unique_ptr<Qm_Result> r(new Qm_Result);
        for (const Island& island : islands) {
            if (island.outFaces.empty()) continue;
            const size_t base = r->vertices.size();
            r->vertices.insert(r->vertices.end(), island.outVertices.begin(), island.outVertices.end());
            for (const auto& f : island.outFaces) {
                std::vector<size_t> polygon;
                polygon.reserve(f.size());
                for (const size_t v : f) polygon.push_back(base + v);
                r->faces.push_back(std::move(polygon));
            }
        }
        if (r->faces.empty()) {
            std::string why;
            {
                std::lock_guard<std::mutex> guard(handler.lock);
                why = handler.last;
            }
            if (why.empty()) why = console.last_line();
            say(error, error_size, why.empty() ? "AutoRemesher gave no polygons" : why.c_str());
            return QM_FAILED;
        }
        r->times.decimate_ms = (float)(stages.decimateUs.load() / 1000.0);
        r->times.isotropic_ms = (float)(stages.isotropicUs.load() / 1000.0);
        r->times.parameterize_ms = (float)(stages.parameterizeUs.load() / 1000.0);
        r->times.extract_ms = (float)(stages.extractUs.load() / 1000.0);
        r->times.total_ms = (float)milliseconds(start, Clock::now());
        r->times.isotropic_triangles = (uint32_t)std::min<long long>(stages.isotropicTriangles.load(), 0xffffffffll);
        r->times.covers = (uint32_t)stages.covers.load();
        handler.whole(1.0f, "Done");
        *out = r.release();
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

extern "C" void qm_times(const Qm_Result* r, Qm_Times* times)
{
    *times = r->times;
}

extern "C" void qm_free(Qm_Result* r)
{
    delete r;
}

// ---- Stage calls (quadmesh_shim.h) --------------------------------------------------

struct Qm_Stage {
    std::vector<double> positions;
    std::vector<uint32_t> triangles, features;
    std::vector<double> density, refine, vertexScale, faceGuides, uvs;
    std::vector<uint8_t> cornerFeature;
    std::vector<uint32_t> singular, first, corners;
    std::vector<double> faceField, faceSizes;
    double meanEdge = 0.0;
    uint32_t added = 0, singularSolved = 0, singularAfter = 0;
    int decimated = 0;
};

namespace {

// A stage's run: the thread count its loops may use and whether it stays on this thread
// (one island of several), set on this thread for the call and put back after, and the
// caller's progress as the core's handler, whose stop throws Qm_Cancel.
struct StageRun {
    unsigned threads;
    bool wasWorker;
    explicit StageRun(const Qm_Stage_Run* run)
        : threads(quadmesh_threads)
        , wasWorker(tbb::detail::in_worker)
    {
        sink();
        if (run) {
            quadmesh_threads = std::max(1u, std::min(run->threads, 16u));
            if (run->serial) tbb::detail::in_worker = true;
        }
    }
    ~StageRun()
    {
        quadmesh_threads = threads;
        tbb::detail::in_worker = wasWorker;
    }
};

AutoRemesher::ProgressHandler stageHandler(const Qm_Stage_Run* run)
{
    if (!run || !run->progress) return AutoRemesher::ProgressHandler();
    const Qm_Progress progress = run->progress;
    void* tag = run->tag;
    return AutoRemesher::ProgressHandler([progress, tag](float fraction, const char* name) {
        if (!progress(tag, fraction, name ? name : "")) throw Qm_Cancel{};
    });
}

// The caller's mesh in the core's types.
void meshIn(const Qm_Mesh& mesh, std::vector<Vector3>& vertices, std::vector<std::vector<size_t>>& triangles)
{
    vertices.clear();
    vertices.reserve(mesh.vertex_count);
    for (uint32_t v = 0; v < mesh.vertex_count; ++v)
        vertices.emplace_back(mesh.positions[3 * v], mesh.positions[3 * v + 1], mesh.positions[3 * v + 2]);
    triangles.assign(mesh.triangle_count, std::vector<size_t>(3));
    for (uint32_t t = 0; t < mesh.triangle_count; ++t)
        for (size_t k = 0; k < 3; ++k) triangles[t][k] = mesh.triangles[3 * t + k];
}

std::vector<double> valuesIn(const double* values, size_t count)
{
    return values ? std::vector<double>(values, values + count) : std::vector<double>();
}

void meshOut(const std::vector<Vector3>& vertices, const std::vector<std::vector<size_t>>& triangles, Qm_Stage& out)
{
    out.positions.resize(3 * vertices.size());
    for (size_t v = 0; v < vertices.size(); ++v)
        for (size_t k = 0; k < 3; ++k) out.positions[3 * v + k] = vertices[v][k];
    out.triangles.resize(3 * triangles.size());
    for (size_t t = 0; t < triangles.size(); ++t)
        for (size_t k = 0; k < 3; ++k) out.triangles[3 * t + k] = (uint32_t)triangles[t][k];
}

// Runs `body` with the boundary's catches: a cancel, memory, or the core's own failure.
template <typename Body>
int guarded(char* error, size_t errorSize, const Body& body)
{
    say(error, errorSize, "");
    try {
        return body();
    } catch (const Qm_Cancel&) {
        say(error, errorSize, "cancelled");
        return QM_CANCELLED;
    } catch (const std::bad_alloc&) {
        say(error, errorSize, "out of memory");
        return QM_OUT_OF_MEMORY;
    } catch (const std::exception& e) {
        say(error, errorSize, e.what());
        return QM_FAILED;
    } catch (...) {
        say(error, errorSize, "AutoRemesher failed");
        return QM_FAILED;
    }
}

}

extern "C" int qm_stage_thin(const Qm_Mesh* mesh, double voxel_size, double quad_edge, double sharp_degrees,
    Qm_Stage** out, char* error, size_t error_size)
{
    *out = nullptr;
    return guarded(error, error_size, [&] {
        const StageRun scope(nullptr);
        Island island;
        meshIn(*mesh, island.vertices, island.triangles);
        if (mesh->features)
            for (uint32_t e = 0; e < mesh->feature_count; ++e)
                island.features.push_back({ mesh->features[2 * e], mesh->features[2 * e + 1] });
        island.density = valuesIn(mesh->density, mesh->vertex_count);
        island.refine = valuesIn(mesh->refine, mesh->vertex_count);
        size_t added = 0;
        std::unique_ptr<Qm_Stage> r(new Qm_Stage);
        r->decimated = thinIsland(island, voxel_size, quad_edge, sharp_degrees, &added) ? 1 : 0;
        r->added = (uint32_t)added;
        meshOut(island.vertices, island.triangles, *r);
        for (const auto& edge : island.features) {
            r->features.push_back((uint32_t)edge.first);
            r->features.push_back((uint32_t)edge.second);
        }
        r->density = std::move(island.density);
        r->refine = std::move(island.refine);
        *out = r.release();
        return QM_OK;
    });
}

extern "C" int qm_stage_isotropic(const Qm_Mesh* mesh, double voxel_size, double adaptivity, double sharp_degrees,
    const Qm_Stage_Run* run, Qm_Stage** out, char* error, size_t error_size)
{
    *out = nullptr;
    return guarded(error, error_size, [&] {
        const StageRun scope(run);
        Island island;
        meshIn(*mesh, island.vertices, island.triangles);
        if (mesh->features)
            for (uint32_t e = 0; e < mesh->feature_count; ++e)
                island.features.push_back({ mesh->features[2 * e], mesh->features[2 * e + 1] });
        island.density = valuesIn(mesh->density, mesh->vertex_count);
        island.refine = valuesIn(mesh->refine, mesh->vertex_count);
        std::vector<double> vertexScale;
        std::vector<char> cornerFeature;
        isotropicIsland(island, voxel_size, adaptivity, sharp_degrees, stageHandler(run), vertexScale, cornerFeature);
        std::unique_ptr<Qm_Stage> r(new Qm_Stage);
        meshOut(island.vertices, island.triangles, *r);
        r->vertexScale = std::move(vertexScale);
        r->cornerFeature.assign(cornerFeature.begin(), cornerFeature.end());
        // The mean edge the cover's scaling is measured against, as the landing takes it.
        if (!island.vertices.empty() && !island.triangles.empty())
            r->meanEdge = AutoRemesher::SurfaceMesh(island.vertices, island.triangles).averageEdgeLength();
        *out = r.release();
        return QM_OK;
    });
}

extern "C" int qm_stage_face_guides(const Qm_Mesh* mesh, double quad_edge, const float* guides, uint32_t guide_count,
    float guide_strength, Qm_Stage** out, char* error, size_t error_size)
{
    *out = nullptr;
    return guarded(error, error_size, [&] {
        const StageRun scope(nullptr);
        std::vector<Vector3> vertices;
        std::vector<std::vector<size_t>> triangles;
        meshIn(*mesh, vertices, triangles);
        Qm_Params params {};
        params.guides = guides;
        params.guide_count = guide_count;
        params.guide_strength = guide_strength;
        // As qm_remesh files them: within three quarters of a quad edge, at most four
        // times the plain one where the density makes the quads larger.
        const Guides filed = makeGuides(params, 4.0 * 0.75 * quad_edge);
        const std::vector<double> vertexScale = valuesIn(mesh->vertex_scale, mesh->vertex_count);
        const std::vector<Vector3> guided = faceGuides(filed, vertices, triangles, vertexScale, quad_edge);
        std::unique_ptr<Qm_Stage> r(new Qm_Stage);
        r->faceGuides.resize(3 * guided.size());
        for (size_t f = 0; f < guided.size(); ++f)
            for (size_t k = 0; k < 3; ++k) r->faceGuides[3 * f + k] = guided[f][k];
        *out = r.release();
        return QM_OK;
    });
}

extern "C" int qm_stage_field(const Qm_Mesh* mesh, double adaptivity, double anisotropy, double sharp_degrees,
    const Qm_Stage_Run* run, Qm_Stage** out, char* error, size_t error_size)
{
    *out = nullptr;
    return guarded(error, error_size, [&] {
        const StageRun scope(run);
        std::vector<Vector3> vertices;
        std::vector<std::vector<size_t>> triangles;
        meshIn(*mesh, vertices, triangles);
        const std::vector<double> vertexScale = valuesIn(mesh->vertex_scale, mesh->vertex_count);
        std::vector<char> cornerFeature;
        if (mesh->corner_feature) cornerFeature.assign(mesh->corner_feature, mesh->corner_feature + 3 * (size_t)mesh->triangle_count);
        std::vector<Vector3> guided;
        if (mesh->face_guides)
            for (uint32_t f = 0; f < mesh->triangle_count; ++f)
                guided.emplace_back(mesh->face_guides[3 * f], mesh->face_guides[3 * f + 1], mesh->face_guides[3 * f + 2]);
        AutoRemesher::Parameterizer parameterizer(&vertices, &triangles, nullptr);
        parameterizer.setProgressHandler(stageHandler(run));
        parameterizer.setGradientAdaptivity(adaptivity);
        parameterizer.setAnisotropy(anisotropy);
        parameterizer.setSharpEdgeDegrees(sharp_degrees);
        if (!cornerFeature.empty()) parameterizer.setCornerFeatures(&cornerFeature);
        if (!vertexScale.empty()) parameterizer.setVertexScaling(&vertexScale);
        if (!guided.empty()) parameterizer.setFaceGuides(&guided);
        AutoRemesher::Parameterizer::FieldStage field;
        parameterizer.setFieldStageOnly(&field);
        if (!parameterizer.parameterize()) {
            say(error, error_size, "frame field solve failed");
            return QM_FAILED;
        }
        std::unique_ptr<Qm_Stage> r(new Qm_Stage);
        r->faceField.resize(3 * field.field.size());
        r->faceSizes.resize(3 * field.field.size());
        for (size_t f = 0; f < field.field.size(); ++f)
            for (size_t k = 0; k < 3; ++k) r->faceField[3 * f + k] = field.field[f][k];
        for (size_t f = 0; f < field.faceScaling.size() && f < field.field.size(); ++f) {
            r->faceSizes[3 * f] = field.faceScaling[f];
            r->faceSizes[3 * f + 1] = field.faceScalingU[f];
            r->faceSizes[3 * f + 2] = field.faceScalingV[f];
        }
        r->singularSolved = (uint32_t)field.singularBefore;
        r->singularAfter = (uint32_t)field.singularAfter;
        *out = r.release();
        return QM_OK;
    });
}

// The cover alone on a field worked out elsewhere (the Odin field, field.odin): what
// Parameterizer::parameterize does once it has its field and sizes. False, with the reason
// in `failure`, when the core gave up.
static bool coverOnField(const std::vector<Vector3>& vertices, const std::vector<std::vector<size_t>>& triangles,
    const Qm_Mesh& mesh, double scaling, double sharpDegrees, const std::vector<char>& cornerFeature,
    const std::vector<Vector3>& guided, const AutoRemesher::ProgressHandler& progress, Cover& out, std::string& failure)
{
    const size_t faces = triangles.size();
    std::vector<Vector3> field(faces);
    std::vector<double> faceScaling(faces), faceScalingU(faces), faceScalingV(faces);
    for (size_t f = 0; f < faces; ++f) {
        field[f] = Vector3(mesh.face_field[3 * f], mesh.face_field[3 * f + 1], mesh.face_field[3 * f + 2]);
        faceScaling[f] = mesh.face_sizes[3 * f];
        faceScalingU[f] = mesh.face_sizes[3 * f + 1];
        faceScalingV[f] = mesh.face_sizes[3 * f + 2];
    }
    // A guided face keeps its direction through the cover's curl correction as firmly as
    // the guide pulled the field there (Parameterizer::parameterize's).
    std::vector<double> faceTurnWeight;
    if (guided.size() == faces) {
        faceTurnWeight.resize(faces);
        for (size_t f = 0; f < faces; ++f) faceTurnWeight[f] = guided[f].length();
    }
    AutoRemesher::QuadParameterizer::Result cover;
    failure.clear();
    try {
        if (!AutoRemesher::QuadParameterizer::parameterize(vertices, triangles, &field, scaling, sharpDegrees, &cover,
                &faceScaling, &faceScalingU, &faceScalingV, progress ? &progress : nullptr,
                cornerFeature.empty() ? nullptr : &cornerFeature, faceTurnWeight.empty() ? nullptr : &faceTurnWeight)) {
            failure = "Quad cover solve failed";
            return false;
        }
    } catch (const Qm_Cancel&) {
        throw;
    } catch (const std::exception& e) {
        failure = std::string("parameterization failed: ") + e.what();
        return false;
    } catch (...) {
        failure = "parameterization failed";
        return false;
    }
    out.uvs = std::make_unique<std::vector<std::vector<AutoRemesher::Vector2>>>(cover.triangleUvs);
    out.originalUvs = cover.triangleUvs;
    out.singular.clear();
    for (const size_t v : cover.singularVertices)
        if (v < vertices.size()) out.singular.push_back(v);
    return true;
}

extern "C" int qm_stage_cover(const Qm_Mesh* mesh, double scaling, double adaptivity, double anisotropy, double sharp_degrees,
    const Qm_Stage_Run* run, Qm_Stage** out, char* error, size_t error_size)
{
    *out = nullptr;
    return guarded(error, error_size, [&] {
        const StageRun scope(run);
        std::vector<Vector3> vertices;
        std::vector<std::vector<size_t>> triangles;
        meshIn(*mesh, vertices, triangles);
        const std::vector<double> vertexScale = valuesIn(mesh->vertex_scale, mesh->vertex_count);
        std::vector<char> cornerFeature;
        if (mesh->corner_feature) cornerFeature.assign(mesh->corner_feature, mesh->corner_feature + 3 * (size_t)mesh->triangle_count);
        std::vector<Vector3> guided;
        if (mesh->face_guides)
            for (uint32_t f = 0; f < mesh->triangle_count; ++f)
                guided.emplace_back(mesh->face_guides[3 * f], mesh->face_guides[3 * f + 1], mesh->face_guides[3 * f + 2]);
        Cover cover;
        std::string failure;
        const bool covered = mesh->face_field && mesh->face_sizes
            ? coverOnField(vertices, triangles, *mesh, scaling, sharp_degrees, cornerFeature, guided, stageHandler(run), cover, failure)
            : coverIsland(vertices, triangles, scaling, adaptivity, anisotropy, sharp_degrees, cornerFeature, vertexScale, guided,
                  stageHandler(run), cover, failure);
        if (!covered) {
            say(error, error_size, failure.c_str());
            return QM_FAILED;
        }
        std::unique_ptr<Qm_Stage> r(new Qm_Stage);
        if (cover.uvs) {
            r->uvs.resize(6 * cover.uvs->size());
            for (size_t f = 0; f < cover.uvs->size(); ++f)
                for (size_t k = 0; k < 3 && k < (*cover.uvs)[f].size(); ++k) {
                    r->uvs[6 * f + 2 * k] = (*cover.uvs)[f][k][0];
                    r->uvs[6 * f + 2 * k + 1] = (*cover.uvs)[f][k][1];
                }
        }
        for (const size_t v : cover.singular) r->singular.push_back((uint32_t)v);
        *out = r.release();
        return QM_OK;
    });
}

extern "C" int qm_stage_extract(const Qm_Mesh* mesh, const Qm_Stage_Run* run, Qm_Stage** out, char* error, size_t error_size)
{
    *out = nullptr;
    return guarded(error, error_size, [&] {
        const StageRun scope(run);
        std::vector<Vector3> vertices;
        std::vector<std::vector<size_t>> triangles;
        meshIn(*mesh, vertices, triangles);
        std::vector<char> cornerFeature;
        if (mesh->corner_feature) cornerFeature.assign(mesh->corner_feature, mesh->corner_feature + 3 * (size_t)mesh->triangle_count);
        Cover cover;
        cover.uvs = std::make_unique<std::vector<std::vector<AutoRemesher::Vector2>>>(mesh->triangle_count, std::vector<AutoRemesher::Vector2>(3));
        for (uint32_t f = 0; f < mesh->triangle_count; ++f)
            for (size_t k = 0; k < 3; ++k)
                (*cover.uvs)[f][k] = AutoRemesher::Vector2(mesh->uvs[6 * f + 2 * k], mesh->uvs[6 * f + 2 * k + 1]);
        cover.originalUvs = *cover.uvs;
        if (mesh->singular) cover.singular.assign(mesh->singular, mesh->singular + mesh->singular_count);
        std::vector<Vector3> outVertices;
        std::vector<std::vector<size_t>> outFaces;
        std::unique_ptr<Qm_Stage> r(new Qm_Stage);
        if (extractIsland(vertices, triangles, cover, cornerFeature, stageHandler(run), outVertices, outFaces)) {
            r->positions.resize(3 * outVertices.size());
            for (size_t v = 0; v < outVertices.size(); ++v)
                for (size_t k = 0; k < 3; ++k) r->positions[3 * v + k] = outVertices[v][k];
            r->first.reserve(outFaces.size() + 1);
            for (const auto& f : outFaces) {
                r->first.push_back((uint32_t)r->corners.size());
                for (const size_t v : f) r->corners.push_back((uint32_t)v);
            }
            r->first.push_back((uint32_t)r->corners.size());
        }
        *out = r.release();
        return QM_OK;
    });
}

extern "C" void qm_stage_view(const Qm_Stage* s, Qm_Stage_View* view)
{
    *view = Qm_Stage_View {};
    const auto ptr = [](const auto& v) { return v.empty() ? nullptr : v.data(); };
    view->positions = ptr(s->positions);
    view->vertex_count = (uint32_t)(s->positions.size() / 3);
    view->triangles = ptr(s->triangles);
    view->triangle_count = (uint32_t)(s->triangles.size() / 3);
    view->features = ptr(s->features);
    view->feature_count = (uint32_t)(s->features.size() / 2);
    view->density = ptr(s->density);
    view->refine = ptr(s->refine);
    view->vertex_scale = ptr(s->vertexScale);
    view->corner_feature = ptr(s->cornerFeature);
    view->mean_edge = s->meanEdge;
    view->face_guides = ptr(s->faceGuides);
    view->uvs = ptr(s->uvs);
    view->singular = ptr(s->singular);
    view->singular_count = (uint32_t)s->singular.size();
    view->first = ptr(s->first);
    view->corners = ptr(s->corners);
    view->face_count = s->first.empty() ? 0 : (uint32_t)(s->first.size() - 1);
    view->added = s->added;
    view->decimated = s->decimated;
    view->face_field = ptr(s->faceField);
    view->face_sizes = ptr(s->faceSizes);
    view->singular_solved = s->singularSolved;
    view->singular_after = s->singularAfter;
}

extern "C" void qm_stage_free(Qm_Stage* s)
{
    delete s;
}

extern "C" void qm_console_line(char* text, size_t size)
{
    say(text, size, sink().last_line().c_str());
}
