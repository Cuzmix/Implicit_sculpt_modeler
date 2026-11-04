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
    /* Density per vertex: quads per area relative to the rest (1 as usual, 4 four times as
     * many, 0.25 a quarter), clamped to 1/16..16 and taken relative to its mean over the
     * area, so the count stays what was asked; NULL, or a count other than the vertices',
     * for none. */
    const float* density;
    uint32_t density_count;
    /* Refinement per vertex: the isotropic mesh's edge there as a share of what the quad
     * size alone gives (1 as usual, 0.5 twice as fine), clamped to 0.25..1. The quads keep
     * their size; a part only a few quads round (a thin tube) needs the finer triangles
     * for its quads to be extracted at all. NULL, or a count other than the vertices', for
     * none. */
    const float* refine;
    uint32_t refine_count;
    /* Guide curves: `guide_count` segments, each two points of x, y and z (six floats),
     * near the surface; the quads' edges are pulled to run along them, by
     * `guide_strength` (0 not at all, 1 as closely as the field can follow). NULL for none. */
    const float* guides;
    uint32_t guide_count;
    float guide_strength;
    /* Planes the caller drops the result's polygons on (Keep symmetry's caps): bit a of
     * `cap_axes` for the plane through `cap_center` square to axis a. A triangle with
     * every corner within `cap_snap` of one counts for none of the quads asked, which go
     * to the rest; 0 for none. */
    uint32_t cap_axes;
    float cap_center[3];
    float cap_snap;
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
    uint32_t isotropic_triangles; /* the isotropic meshes' triangles, over the islands */
    uint32_t covers;              /* the quad covers solved, over the islands (up to three each) */
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

/* ---- Stage calls ----------------------------------------------------------------------
 * qm_remesh's stages one at a time, for the Odin driver (src/quadmesh/driver.odin), which
 * runs the same pipeline itself so any stage can be swapped for an Odin one and checked
 * against this one. Each call takes arrays the caller owns, returns QM_OK, QM_CANCELLED,
 * QM_OUT_OF_MEMORY or QM_FAILED (with `error` saying why), and on QM_OK sets *out to its
 * output, read through qm_stage_view and freed by qm_stage_free. Positions are doubles, as
 * the core keeps them, so one stage's output goes into the next unchanged. */

typedef struct Qm_Stage Qm_Stage;

/* How a stage runs: its own loops may use `threads` threads, unless `serial` (a thread
 * running one island of several, as qm_remesh's island threads keep their loops), and it
 * reports its own 0..1 to `progress` (may be NULL), whose 0 cancels. */
typedef struct Qm_Stage_Run {
    uint32_t threads;
    int serial;
    Qm_Progress progress;
    void* tag;
} Qm_Stage_Run;

/* A stage's input: a triangle mesh and what rides on it, each array NULL for none. */
typedef struct Qm_Mesh {
    const double* positions;       /* 3 a vertex */
    uint32_t vertex_count;
    const uint32_t* triangles;     /* 3 a triangle */
    uint32_t triangle_count;
    const uint32_t* features;      /* 2 a feature edge (thin, isotropic) */
    uint32_t feature_count;
    const double* density;         /* 1 a vertex (thin, isotropic) */
    const double* refine;          /* 1 a vertex (thin, isotropic) */
    const double* vertex_scale;    /* 1 a vertex: the quad size the density asks (face guides, cover) */
    const uint8_t* corner_feature; /* 1 a triangle corner: its edge is a feature edge (cover, extract) */
    const double* face_guides;     /* 3 a triangle: the direction a guide asks, times its weight (cover) */
    const double* uvs;             /* 6 a triangle: the cover's UV at each corner (extract) */
    const uint32_t* singular;      /* the field's singular vertices (extract) */
    uint32_t singular_count;
} Qm_Mesh;

/* A stage's output, valid until qm_stage_free; each array NULL when the stage gave none. */
typedef struct Qm_Stage_View {
    const double* positions;       /* thin, isotropic, extract */
    uint32_t vertex_count;
    const uint32_t* triangles;     /* thin, isotropic */
    uint32_t triangle_count;
    const uint32_t* features;      /* thin */
    uint32_t feature_count;
    const double* density;         /* thin */
    const double* refine;          /* thin */
    const double* vertex_scale;    /* isotropic */
    const uint8_t* corner_feature; /* isotropic */
    double mean_edge;              /* isotropic: the mean edge the cover's scaling multiplies */
    const double* face_guides;     /* face guides */
    const double* uvs;             /* cover */
    const uint32_t* singular;      /* cover */
    uint32_t singular_count;
    const uint32_t* first;         /* extract: face_count + 1 entries into corners */
    const uint32_t* corners;       /* extract */
    uint32_t face_count;
    uint32_t added;                /* thin: vertices the unpinch made */
    int decimated;                 /* thin: whether the island was decimated */
} Qm_Stage_View;

/* Feature chains under two quad edges dropped, an island far denser than its target
 * decimated (meshoptimizer), pinched vertices split. */
int qm_stage_thin(const Qm_Mesh* mesh, double voxel_size, double quad_edge, double sharp_degrees,
                  Qm_Stage** out, char* error, size_t error_size);
/* The isotropic remesh at `voxel_size`, with Adaptivity's target lengths, the density's
 * edge factor and the refinement. */
int qm_stage_isotropic(const Qm_Mesh* mesh, double voxel_size, double adaptivity, double sharp_degrees,
                       const Qm_Stage_Run* run, Qm_Stage** out, char* error, size_t error_size);
/* The guide curves as a direction per triangle (none when no guide comes near). */
int qm_stage_face_guides(const Qm_Mesh* mesh, double quad_edge, const float* guides, uint32_t guide_count,
                         float guide_strength, Qm_Stage** out, char* error, size_t error_size);
/* One quad cover at `scaling`: frame field, singularity simplification, cover. QM_FAILED
 * with an empty `error` when the core gave up without an exception (qm_console_line then
 * holds its own line). */
int qm_stage_cover(const Qm_Mesh* mesh, double scaling, double adaptivity, double anisotropy, double sharp_degrees,
                   const Qm_Stage_Run* run, Qm_Stage** out, char* error, size_t error_size);
/* The quads traced from the cover and cleaned up; none when the extractor gave none. */
int qm_stage_extract(const Qm_Mesh* mesh, const Qm_Stage_Run* run, Qm_Stage** out, char* error, size_t error_size);
void qm_stage_view(const Qm_Stage* stage, Qm_Stage_View* view);
void qm_stage_free(Qm_Stage* stage);
/* The last whole line the core wrote to its console, the reason it gave for a failure. */
void qm_console_line(char* text, size_t size);

#ifdef __cplusplus
}
#endif
