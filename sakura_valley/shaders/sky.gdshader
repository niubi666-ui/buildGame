shader_type sky;

#include "res://shaders/common.gdshaderinc"

uniform vec3 top_color : source_color = vec3(0.26, 0.55, 0.82);
uniform vec3 horizon_color : source_color = vec3(0.73, 0.86, 0.93);
uniform vec3 ground_color : source_color = vec3(0.6, 0.66, 0.6);
uniform vec3 cloud_light : source_color = vec3(1.0, 0.99, 0.96);
uniform vec3 cloud_shadow : source_color = vec3(0.68, 0.78, 0.9);
uniform vec3 sun_color : source_color = vec3(1.0, 0.92, 0.75);
uniform float cloud_amount = 0.5;
uniform float sun_glow = 0.25;

float billow(vec2 p) {
	float a = 0.5;
	float v = 0.0;
	for (int i = 0; i < 5; i++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.05 + vec2(11.3, 7.7);
		a *= 0.5;
	}
	return v;
}

float cloud_density(vec2 p) {
	float shape = fbm(p * 0.42 + 4.0);
	float detail = billow(p * 1.15);
	return smoothstep(1.0 - cloud_amount, 1.16 - cloud_amount, shape + (detail - 0.5) * 0.24);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float up = max(d.y, 0.0);
	vec3 color = mix(horizon_color, top_color, pow(up, 0.55));
	if (d.y < 0.0) {
		color = mix(horizon_color, ground_color, smoothstep(0.0, 0.14, -d.y));
	}

	vec3 sun_dir = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION) : vec3(0.0, 1.0, 0.0);
	float sun_dot = max(dot(d, sun_dir), 0.0);
	color += sun_color * (pow(sun_dot, 8.0) * sun_glow + pow(sun_dot, 900.0) * 3.0);

	if (d.y > 0.012) {
		vec2 p = d.xz / (d.y + 0.16) * 2.2;
		float density = cloud_density(p);
		if (density > 0.001) {
			vec2 to_sun = normalize(sun_dir.xz + vec2(0.0001)) * 0.16;
			float lit = 1.0 - cloud_density(p + to_sun) * 0.82;
			vec3 cloud = mix(cloud_shadow, cloud_light, clamp(lit + 0.2, 0.0, 1.0));
			cloud += sun_color * pow(sun_dot, 3.0) * sun_glow * 0.8;
			color = mix(color, cloud, density * smoothstep(0.012, 0.08, d.y) * 0.97);
		}
	}
	COLOR = color;
}
