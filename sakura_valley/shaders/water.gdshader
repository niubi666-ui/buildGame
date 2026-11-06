shader_type spatial;
render_mode cull_back, diffuse_burley;

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/sun_light.gdshaderinc"
#include "res://shaders/range_overlay.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

uniform vec3 shallow_tint : source_color = vec3(0.62, 0.9, 0.84);
uniform vec3 mid_color : source_color = vec3(0.12, 0.56, 0.6);
uniform vec3 deep_color : source_color = vec3(0.04, 0.24, 0.42);
uniform vec3 sky_color : source_color = vec3(0.56, 0.78, 0.84);
uniform vec3 foam_color : source_color = vec3(1.0, 0.99, 0.95);
// Seconds since new water began to flow. UV.x says when it reaches each point, UV.y how far it must rise.
uniform float flood_clock = 10000.0;
uniform float flood_fill_seconds = 1.4;

varying vec3 world_pos;
varying float flood_lead;

float water_height(vec2 p, float t) {
	// Warping bends the wave fronts, so no straight bands appear.
	p += vec2(sin(p.y * 0.21 + t * 0.1) + sin(p.y * 0.53), cos(p.x * 0.17 - t * 0.08) + sin(p.x * 0.47)) * 1.7;
	float h = 0.0;
	h += sin(dot(p, vec2(0.62, 0.31)) + t * 0.55) * 0.34;
	h += sin(dot(p, vec2(-0.41, 0.83)) + t * 0.72) * 0.26;
	h += sin(dot(p, vec2(1.33, -0.72)) - t * 0.94) * 0.16;
	h += sin(dot(p, vec2(-1.91, -1.27)) + t * 1.2) * 0.1;
	h += sin(dot(p, vec2(3.1, 1.9)) - t * 1.55) * 0.06;
	return h;
}

float water_depth_at(vec2 uv, mat4 inv_proj, mat4 inv_view) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	v.xyz /= v.w;
	vec3 w = (inv_view * vec4(v.xyz, 1.0)).xyz;
	return world_pos.y - w.y;
}

vec2 hash22(vec2 p) {
	float a = hash21(p);
	return vec2(a, hash21(p + a + 11.7));
}

// Distance to the nearest drifting point, for the foam's broken dots.
float foam_dots(vec2 p, float t) {
	vec2 cell = floor(p);
	vec2 local = fract(p);
	float best = 2.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 offset = vec2(float(x), float(y));
			vec2 seed = hash22(cell + offset);
			vec2 point = offset + 0.5 + 0.42 * sin(seed * 6.283 + t * 0.5);
			best = min(best, length(point - local));
		}
	}
	return best;
}

// Short bright flecks of sun that twinkle on the surface.
float sun_flecks(vec2 p, float t) {
	vec2 cell = floor(p);
	vec2 local = fract(p) - 0.5;
	vec2 seed = hash22(cell);
	vec2 d = local - (seed - 0.5) * 0.7;
	float dash = (1.0 - smoothstep(0.06, 0.2, abs(d.x))) * (1.0 - smoothstep(0.02, 0.06, abs(d.y)));
	float twinkle = pow(max(sin(t * (0.7 + seed.x * 1.6) + seed.y * 6.283), 0.0), 12.0);
	return dash * twinkle * step(0.35, fract(seed.x * 7.3 + seed.y * 3.1));
}

void vertex() {
	float risen = smoothstep(UV.x, UV.x + flood_fill_seconds, flood_clock);
	VERTEX.y -= UV.y * (1.0 - risen);
	flood_lead = flood_clock - UV.x;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (flood_lead < 0.0) {
		discard;
	}
	float e = 0.14;
	float h = water_height(world_pos.xz, TIME);
	float hx = water_height(world_pos.xz + vec2(e, 0.0), TIME);
	float hz = water_height(world_pos.xz + vec2(0.0, e), TIME);
	vec3 n = normalize(vec3((h - hx) / e * 0.075, 1.0, (h - hz) / e * 0.075));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	float depth = water_depth_at(SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	vec2 refr_uv = SCREEN_UV + n.xz * 0.04 * clamp(depth, 0.0, 1.0);
	float refr_depth = water_depth_at(refr_uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	if (refr_depth < 0.0) {
		refr_uv = SCREEN_UV;
		refr_depth = depth;
	}
	vec3 bed = textureLod(screen_tex, refr_uv, 0.0).rgb;

	// Clear over the shallows, turquoise further out, then deep blue with soft painted patches.
	float patches = fbm(world_pos.xz * 0.055 + vec2(TIME * 0.008, 0.0));
	float to_mid = 1.0 - exp(-max(refr_depth, 0.0) * 1.05);
	float to_deep = 1.0 - exp(-max(refr_depth, 0.0) * 0.3);
	vec3 water = mix(bed * shallow_tint, mid_color, to_mid);
	water = mix(water, deep_color, to_deep * mix(0.55, 1.0, patches));

	// Soft bands of pale sky on the ripple slopes.
	float cos_v = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - cos_v, 4.0);
	float ripple_light = smoothstep(0.02, 0.2, h - hx + (h - hz) * 0.6);
	water = mix(water, sky_color, clamp(fresnel + ripple_light * 0.1, 0.0, 0.7));

	float sun = sun_light_at(world_pos, TIME);
	water *= sun;

	// White lace along the shore, in a tight line plus a looser band that breathes in and out.
	float grain = fbm(world_pos.xz * 0.9 + TIME * 0.03);
	float shore_line = 1.0 - smoothstep(0.0, 0.28 + grain * 0.22, depth);
	float wave_at = 0.62 + 0.16 * sin(TIME * 0.55 + grain * 5.0);
	float shore_band = 1.0 - smoothstep(0.0, 0.26, abs(depth - wave_at));
	float dots = foam_dots(world_pos.xz * 1.5, TIME);
	float lace = (1.0 - smoothstep(0.2, 0.36, dots));
	float foam = clamp(shore_line * 0.9 * step(0.3, grain + dots) + shore_band * lace * 0.85, 0.0, 1.0);

	float flecks = sun_flecks(world_pos.xz * 0.95, TIME) + sun_flecks(world_pos.xz * 1.6 + 7.0, TIME * 1.3);
	flecks *= smoothstep(0.35, 1.5, refr_depth) * smoothstep(0.7, 1.05, sun);

	water = mix(water, foam_color * sun, foam);
	if (range_on > 0.5) {
		vec4 overlay = range_overlay(world_pos);
		water = mix(water, overlay.rgb, overlay.a);
	}
	ALBEDO = water * 0.14;
	EMISSION = water * 0.82 + foam_color * flecks * 2.4;
	ROUGHNESS = 0.3;
	SPECULAR = 0.25;
	ALPHA = 1.0;
}
