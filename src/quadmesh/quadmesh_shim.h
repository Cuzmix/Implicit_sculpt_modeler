// The C boundary to AutoRemesher's core (deps/autoremesher-src, built with this shim by
// scripts/build_autoremesher.py into deps/autoremesher): the quadmesh package's foreign
// block mirrors these declarations. No exception crosses it, and every pointer it
// returns is freed by qm_free.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct Qm_Params {
    uint32_t quads;        /* wanted; the quad edge is sqrt(area / quads), so the count lands within a few percent */
    float adaptivity;      /* 0 even quads, 1 smaller quads where the surface bends */
    float sharp_degrees;   /* a crease sharper than this keeps an edge */
    float anisotropy;      /* 0 for AutoRemesher's own */
    float scaling;         /* 0 for the quad edge above; else the quad edge as a multiple of the isotropic mesh's mean edge */
    uint32_t threads;      /* threads parallel_for may use, 1 to 16 */
    /* Feature edges: `feature_count` pairs of vertex indices (a polygroup border, a
     * crease) kept as quad edges whatever their angle; NULL for none. */
    const uint32_t* features;
    uint32_t feature_count;
} Qm_Params;

/* Called as the remesh advances, from the calling thread or a worker; returns whether to
 * go on. A false from the calling thread cancels. `stage` is never NULL. */
typedef int (*Qm_Progress)(void* tag, float fraction, const char* stage);

typedef struct Qm_Result Qm_Result;

/* Where a remesh's time went, in milliseconds: the stages summed over the islands (so on
 * a mesh of several islands run side by side they add up to more than the total). */
typedef struct Qm_Times {
    float decimate_ms;     /* islands far denser than the target decimated first */
    float isotropic_ms;    /* the isotropic remesh at the target edge */
    float parameterize_ms; /* frame field, singularity simplification, quad cover */
    float extract_ms;      /* quads traced from the cover and cleaned up */
    float total_ms;        /* the whole call */
} Qm_Times;

enum {
    QM_OK = 0,
    QM_FAILED = 1,        /* AutoRemesher refused or failed: `error` says why */
    QM_CANCELLED = 2,
    QM_OUT_OF_MEMORY = 3
};

/* Remeshes `triangle_count` triangles (three indices each) over `vertex_count` positions
 * (three floats each). On QM_OK, *out holds the polygons; otherwise *out is NULL and
 * `error` (error_size bytes, may be NULL) holds the reason. */
int qm_remesh(const float* positions, uint32_t vertex_count, const uint32_t* triangles, uint32_t triangle_count,
              const Qm_Params* params, Qm_Progress progress, void* tag, Qm_Result** out, char* error, size_t error_size);
/* The result's sizes: positions, polygons and corner entries in all. */
void qm_counts(const Qm_Result* r, uint32_t* vertices, uint32_t* faces, uint32_t* corners);
/* Copies the result out: `positions` 3 floats a vertex, `first` faces + 1 entries (polygon
 * p's corners are corners[first[p]..first[p + 1])), `corners` counter-clockwise seen from
 * outside, as AutoRemesher gives them. */
void qm_copy(const Qm_Result* r, float* positions, uint32_t* first, uint32_t* corners);
/* The stages' times of the remesh that made `r`. */
void qm_times(const Qm_Result* r, Qm_Times* times);
void qm_free(Qm_Result* r);

#ifdef __cplusplus
}
#endif
