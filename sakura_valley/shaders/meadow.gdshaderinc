// Meadow colors baked at startup, so half a million grass tufts avoid per-vertex noise.
uniform sampler2D meadow_map : filter_linear, repeat_enable;
uniform float meadow_size = 320.0;

vec3 meadow_color(vec2 p) {
	return textureLod(meadow_map, p / meadow_size + 0.5, 0.0).rgb;
}
