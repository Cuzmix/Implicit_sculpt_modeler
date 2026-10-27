#version 450
// The full-screen triangle clear.vert draws, passing each pixel its place in normalized
// device coordinates, which the floor grid's fragment stage unprojects into a ray.
layout(location = 0) out vec2 out_ndc;

void main() {
	vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
	out_ndc = p;
	gl_Position = vec4(p, 1.0, 1.0);
}
