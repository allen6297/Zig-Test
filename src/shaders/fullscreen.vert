#version 450

// A single oversized triangle that covers the whole screen, generated from
// gl_VertexIndex with no vertex buffer (draw 3 vertices, no inputs). The
// fragment shaders derive their UV from gl_FragCoord / resolution, so nothing
// needs to be passed down here.
//
// Vertices: (-1,-1), (3,-1), (-1,3) — the triangle's interior exactly covers
// the [-1,1] clip square, the excess is clipped away.

void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
