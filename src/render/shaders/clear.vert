#version 450
// Full-screen triangle at the far plane, for clearing a scissored part of the
// viewport (render passes can only clear the whole target).
void main() {
	vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
	gl_Position = vec4(p * 2.0 - 1.0, 1.0, 1.0);
}
