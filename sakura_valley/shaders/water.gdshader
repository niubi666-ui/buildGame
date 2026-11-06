shader_type spatial;
render_mode cull_back, diffuse_burley;

#include "res://shaders/common.gdshaderinc"
#include "res://shaders/sun_light.gdshaderinc"
#include "res://shaders/range_overlay.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

// How much of each colour the water swallows per metre. Red goes first, so the bed turns turquoise, then blue.
uniform vec3 absorption = vec3(0.42, 0.13, 0.075);
// The colour that light scattered inside the water gives it, from turquoise shallows to deep blue.
uniform vec3 shallow_glow : source_color = vec3(0.36, 0.86, 0.84);
uniform vec3 deep_color : source_color = vec3(0.035, 0.2, 0.44);
// Depth in metres over which the scattered colour turns from shallow_glow to deep_color.
uniform float glow_depth = 5.5;
uniform vec3 sky_color : source_color = vec3(0.62, 0.8, 0.86);
uniform vec3 foam_color : source_color = vec3(1.0, 0.99, 0.95);
// Bright web of sunlight focused onto the bed by the ripples.
uniform vec3 caustic_color : source_color = vec3(1.0, 0.98, 0.86);
uniform float caustic_strength = 2.0;
uniform float caustic_scale = 0.3;
// Metres below which the caustics have faded to half.
uniform float caustic_fade = 4.0;
uniform float refraction = 0.035;
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

// World position of whatever opaque surface the screen shows at uv.
vec3 bed_at(vec2 uv, mat4 inv_proj, mat4 inv_view) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	v.xyz /= v.w;
	return (inv_view * vec4(v.xyz, 1.0)).xyz;
}

vec2 hash22(vec2 p) {
	float a = hash21(p);
	return vec2(a, hash21(p + a + 11.7));
}

// Gap between the nearest and second nearest drifting points: near zero along the cell borders.
float cell_edges(vec2 p, float t) {
	vec2 cell = floor(p);
	vec2 local = fract(p);
	float first = 8.0;
	float second = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 offset = vec2(float(x), float(y));
			vec2 seed = hash22(cell + offset);
			vec2 point = offset + 0.5 + 0.38 * sin(seed * 6.283 + t * (0.6 + seed.yx * 0.5));
			float d = length(point - local);
			if (d < first) {
				second = first;
				first = d;
			} else if (d < second) {
				second = d;
			}
		}
	}
	return second - first;
}

// The bright net of light on a sunlit bed. Two drifting layers, so the net keeps changing shape.
float caustics(vec2 p, float t) {
	p *= caustic_scale;
	p += vec2(sin(p.y * 1.3 + t * 0.4), cos(p.x * 1.1 - t * 0.35)) * 0.22;
	float a = 1.0 - smoothstep(0.0, 0.11, cell_edges(p, t));
	float b = 1.0 - smoothstep(0.0, 0.14, cell_edges(p * 1.37 + vec2(3.7, 1.9), t * 1.2));
	return a * 0.7 + b * 0.45 + a * b * 0.9;
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

	// Look through the surface, bent a little by the ripples. Anything above the water stays unbent.
	vec3 straight_bed = bed_at(SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	float depth = world_pos.y - straight_bed.y;
	vec2 refr_uv = SCREEN_UV + n.xz * refraction * clamp(depth * 0.5, 0.0, 1.0);
	vec3 bed_pos = bed_at(refr_uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	if (world_pos.y - bed_pos.y < 0.0) {
		refr_uv = SCREEN_UV;
		bed_pos = straight_bed;
	}
	float bed_depth = max(world_pos.y - bed_pos.y, 0.0);
	vec3 bed = textureLod(screen_tex, refr_uv, 0.0).rgb;

	// Sunlight focused by the ripples, strongest in the shallows and fading with depth.
	float sun = sun_light_at(world_pos, TIME);
	vec2 sun_shift = -SUN_DIR.xz / SUN_DIR.y * bed_depth;
	float net = caustics(bed_pos.xz + sun_shift, TIME);
	float caustic_amount = caustic_strength * net * smoothstep(0.05, 0.5, bed_depth) * exp2(-bed_depth / caustic_fade);
	bed += bed * caustic_color * caustic_amount * smoothstep(0.6, 1.0, sun);

	// Light goes down to the bed and back up to the eye, losing red first, then green.
	float path = bed_depth + min(distance(bed_pos, world_pos), bed_depth * 4.0 + 2.0);
	vec3 through = exp(-absorption * path);
	float patches = fbm(world_pos.xz * 0.05 + vec2(TIME * 0.008, 0.0));
	vec3 glow = mix(shallow_glow, deep_color, smoothstep(0.0, glow_depth * mix(0.75, 1.3, patches), bed_depth));
	vec3 water = bed * through + glow * (1.0 - through) * sun;

	// Pale sky on the far side of each ripple and at low angles; mostly clear looking straight down.
	float cos_v = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - cos_v, 5.0);
	float ripple_light = smoothstep(0.03, 0.22, h - hx + (h - hz) * 0.6);
	water = mix(water, sky_color * mix(0.8, 1.05, sun), clamp(fresnel * 0.85 + ripple_light * 0.06, 0.0, 0.6));

	// A thin white line where the water meets the shore, and a faint broken band just beyond it.
	float grain = fbm(world_pos.xz * 0.9 + TIME * 0.03);
	float shore_line = 1.0 - smoothstep(0.0, 0.12 + grain * 0.14, depth);
	float wave_at = 0.45 + 0.12 * sin(TIME * 0.55 + grain * 5.0);
	float shore_band = 1.0 - smoothstep(0.0, 0.18, abs(depth - wave_at));
	float dots = foam_dots(world_pos.xz * 1.8, TIME);
	float lace = 1.0 - smoothstep(0.16, 0.3, dots);
	float foam = clamp(shore_line * 0.85 * step(0.32, grain + dots) + shore_band * lace * 0.4, 0.0, 1.0);

	float flecks = sun_flecks(world_pos.xz * 0.95, TIME) + sun_flecks(world_pos.xz * 1.6 + 7.0, TIME * 1.3);
	flecks *= smoothstep(0.8, 2.5, bed_depth) * smoothstep(0.7, 1.05, sun) * 0.25;

	water = mix(water, foam_color * sun, foam);
	if (range_on > 0.5) {
		vec4 overlay = range_overlay(world_pos);
		water = mix(water, overlay.rgb, overlay.a);
	}
	// The bed in the screen image is already lit, so the water adds no lighting of its own beyond a glint.
	ALBEDO = water * 0.06;
	EMISSION = water * 0.92 + foam_color * flecks * 2.4;
	ROUGHNESS = 0.34;
	SPECULAR = 0.07;
	ALPHA = 1.0;
}
