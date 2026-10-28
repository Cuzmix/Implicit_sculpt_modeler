#version 450
#extension GL_GOOGLE_include_directive : require
// Render mode's samples as exposed linear light, for the finishing stack.
#define LINEAR_OUT
#include "render_display.glsl"
