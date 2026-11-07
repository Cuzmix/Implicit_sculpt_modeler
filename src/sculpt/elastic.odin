package sculpt

import "../geom"

// The Elastic brush (Blender's Elastic Deform) weighs Grab's moves by a regularized
// Kelvinlet, how an elastic solid moves when pulled at one point (geom/kelvinlet.odin, which
// voxel's Elastic shares). It reaches ELASTIC_REACH brush radii.
ELASTIC_REACH :: geom.KELVINLET_REACH
