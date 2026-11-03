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
// cover per face, normalised so the count stays. The quad edge wanted is sqrt(area / quads) over the whole input, and each
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

// The area weighted by the density (Qm_Params.density, one per vertex, the mean of a
// triangle's corners on it): the area the quads are spread over as if it were even. The
// plain area when there is no density.
double densityArea(const std::vector<Vector3>& vertices, const std::vector<std::vector<size_t>>& triangles,
    const std::vector<double>& density)
{
    if (density.size() != vertices.size()) return meshArea(vertices, triangles);
    double area = 0.0;
    for (const auto& t : triangles)
        area += Vector3::area(vertices[t[0]], vertices[t[1]], vertices[t[2]]) * (density[t[0]] + density[t[1]] + density[t[2]]) / 3.0;
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
    std::vector<std::pair<size_t, size_t>>& features, std::vector<double>& density, double voxelSize, double sharpDegrees)
{
    if (vertices.empty() || triangles.empty() || voxelSize <= 0.0) return false;
    if (vertices.size() > (size_t)std::numeric_limits<unsigned int>::max()) return false;
    const double targetArea = voxelSize * voxelSize * 0.86602540378 * 0.5;
    // Where the density asks for smaller quads the isotropic remesh wants smaller
    // triangles, so the triangles kept follow the density-weighted area.
    const double wanted = densityArea(vertices, triangles, density) / targetArea;
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
    std::vector<double> weldedDensity;
    if (density.size() == vertices.size()) {
        weldedDensity.assign(welded, 1.0);
        for (size_t v = 0; v < vertices.size(); ++v)
            if (~0u != remap[v]) weldedDensity[remap[v]] = density[v];
    }

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
    std::vector<double> outDensity;
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
    return true;
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
    std::vector<Vector3> outVertices;
    std::vector<std::vector<size_t>> outFaces;
};

struct Stages {
    std::atomic<long long> decimateUs { 0 }, isotropicUs { 0 }, parameterizeUs { 0 }, extractUs { 0 };
};

// Runs the stages on one island; progress reported as the island's share. An island whose
// parameterization fails is left without quads, with the reason kept for the report, as
// the core does; a cancel passes through.
void remeshIsland(size_t index, Island& island, const Qm_Params& params, double voxelSize, double quadEdge,
    Handler& handler, Stages& stages)
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
    dropShortFeatureChains(vertices, island.features, quadEdge);
    decimateIfDense(vertices, triangles, island.features, island.density, voxelSize, params.sharp_degrees);
    const auto t1 = Clock::now();
    stages.decimateUs += (long long)(1000.0 * milliseconds(t0, t1));
    std::vector<double> targetLengths = adaptiveTargetLengths(vertices, triangles, voxelSize, params.adaptivity);
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
    std::vector<double> vertexScale;
    std::vector<char> cornerFeature;
    {
        AutoRemesher::IsotropicRemesher isotropic(vertices, triangles);
        isotropic.setProgressHandler(stageProgress(0.0f, islandResampleEnd));
        isotropic.setTargetEdgeLength(voxelSize);
        if (!targetLengths.empty()) isotropic.setVertexTargetEdgeLengths(&targetLengths);
        isotropic.setSharpEdgeDegrees(params.sharp_degrees);
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
        // The remeshed mesh's feature edges (the caller's, carried through, and the
        // edges sharp by angle), as flags on the corners the parameterizer judges.
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
    const auto t2 = Clock::now();
    stages.isotropicUs += (long long)(1000.0 * milliseconds(t1, t2));
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
    // that land at once skip it. A count that `Params.scaling` fixed is left alone.
    const bool landing = params.scaling <= 0.0;
    double scaling = params.scaling;
    if (landing) {
        const AutoRemesher::SurfaceMesh measured(vertices, triangles);
        const double mean = measured.averageEdgeLength();
        scaling = mean > 0.0 ? quadEdge / mean : 1.0;
    }
    // A face whose quads are s times the size (the mean of its corners' vertexScale) covers
    // 1 / s² as many cells.
    double scaledArea = 0.0;
    for (size_t f = 0; f < triangles.size(); ++f) {
        const double a = Vector3::area(vertices[triangles[f][0]], vertices[triangles[f][1]], vertices[triangles[f][2]]);
        const auto& t = triangles[f];
        const double s = vertexScale.size() == vertices.size() ? (vertexScale[t[0]] + vertexScale[t[1]] + vertexScale[t[2]]) / 3.0 : 1.0;
        scaledArea += a / (s * s);
    }
    const double cellsWanted = scaledArea / (quadEdge * quadEdge);
    std::unique_ptr<std::vector<std::vector<AutoRemesher::Vector2>>> uvs;
    std::vector<std::vector<AutoRemesher::Vector2>> originalUvs;
    std::vector<size_t> singular;
    const float coverSpan = islandParameterizeEnd - islandResampleEnd;
    for (int pass = 0; pass < 2; ++pass) {
        // The first cover takes the whole parameterize share of the bar; a second takes
        // the last third of it again, so the bar steps back a little rather than stalling.
        const float begin = pass == 0 ? islandResampleEnd : islandResampleEnd + coverSpan * 0.67f;
        AutoRemesher::Parameterizer parameterizer(&vertices, &triangles, nullptr);
        parameterizer.setProgressHandler(stageProgress(begin, islandParameterizeEnd));
        parameterizer.setScaling(scaling);
        parameterizer.setGradientAdaptivity(params.adaptivity);
        parameterizer.setAnisotropy(params.anisotropy > 0.0f ? params.anisotropy : 1.0);
        parameterizer.setSharpEdgeDegrees(params.sharp_degrees);
        if (!cornerFeature.empty()) parameterizer.setCornerFeatures(&cornerFeature);
        if (!vertexScale.empty()) parameterizer.setVertexScaling(&vertexScale);
        bool parameterized = true;
        try {
            parameterized = parameterizer.parameterize();
        } catch (const Qm_Cancel&) {
            throw;
        } catch (const std::exception& e) {
            parameterized = false;
            handler.failed(std::string("parameterization failed: ") + e.what());
        } catch (...) {
            parameterized = false;
            handler.failed("parameterization failed");
        }
        if (!parameterized) {
            const auto tFailed = Clock::now();
            stages.parameterizeUs += (long long)(1000.0 * milliseconds(t2, tFailed));
            handler.report(index, 1.0f, nullptr);
            return;
        }
        uvs = parameterizer.takeTriangleUvs();
        originalUvs = parameterizer.originalTriangleUvs();
        singular = parameterizer.singularVertexIndices();
        if (!landing || pass == 1 || !uvs) break;
        double cells = 0.0;
        for (const auto& t : *uvs) {
            if (t.size() != 3) continue;
            cells += 0.5 * std::fabs((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1]));
        }
        if (cells <= 0.0 || cellsWanted <= 0.0 || std::fabs(cells / cellsWanted - 1.0) <= 0.03) break;
        scaling *= std::sqrt(cells / cellsWanted);
    }
    const auto t3 = Clock::now();
    stages.parameterizeUs += (long long)(1000.0 * milliseconds(t2, t3));
    handler.report(index, islandParameterizeEnd, nullptr);
    AutoRemesher::QuadExtractor extractor(&vertices, &triangles, uvs.get());
    extractor.setOriginalTriangleUvs(&originalUvs);
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
    extractor.setSingularVertices(&singular);
    extractor.setProgressHandler(stageProgress(islandParameterizeEnd, 1.0f));
    if (extractor.extract()) {
        island.outVertices = extractor.remeshedVertices();
        island.outFaces = extractor.remeshedQuads();
    }
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
        const double area = meshArea(vertices, faces);
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
            const double mean = densityArea(vertices, faces, density) / area;
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
        if (nullptr != params->features)
            for (uint32_t e = 0; e < params->feature_count; ++e) {
                const uint32_t a = params->features[2 * e], b = params->features[2 * e + 1];
                if (a >= vertices.size() || b >= vertices.size() || a == b) continue;
                if (islandOf[a] == none || islandOf[a] != islandOf[b]) continue;
                islands[islandOf[a]].features.push_back({ localOf[a], localOf[b] });
            }
        islandFaces.clear();
        islandFaces.shrink_to_fit();

        Stages stages;
        handler.whole(parallelPhaseBegin, "Remeshing uniformly");
        overIslands(islands.size(), threads, [&](size_t i) {
            remeshIsland(i, islands[i], *params, voxelSize, quadEdge, handler, stages);
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
