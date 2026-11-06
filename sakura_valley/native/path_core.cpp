#include "path_core.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <queue>
#include <utility>

namespace pathcore {

namespace {
const float INFINITE_COST = std::numeric_limits<float>::infinity();
const int STEP_I[8] = { 1, -1, 0, 0, 1, 1, -1, -1 };
const int STEP_J[8] = { 0, 0, 1, -1, 1, -1, 1, -1 };
const float UNIT_HALF_HEIGHT = 0.85f;
const int MAX_SHOTS = 200;
const size_t MAX_IMPACT_FLOATS = 600;
const size_t MAX_LAUNCH_FLOATS = 700;
const size_t MAX_DEATH_FLOATS = 800;
const float SHOT_SPEED = 70.0f;
const float MAX_TICK = 1.0f / 30.0f;
const float TARGET_LIFT = 1.1f; // arrows aim at the chest
const float GUN_LENGTH = 6.0f; // arrows leave from the tip of the gun
const float SIGHT_START = 4.0f; // the tower's own footing never counts as cover
const float SPLASH_HEIGHT = 5.0f; // a blast does not reach far above or below itself
const float KNOCK_STUN = 1.0f; // seconds a climber lies at the foot of the wall after being knocked off
const float LOB_LIFT = 2.0f; // stones leave from the throwing arm, a little above the pivot
const float LOB_MIN_FLIGHT = 0.8f; // seconds, so even a short throw has a visible arc
const float LOB_ARC_BASE = 6.0f; // metres the arc rises above the straight line, plus a share of the distance
const float LOB_ARC_PER_METRE = 0.3f;
const size_t MAX_FIRES = 48;
} // namespace

void World::set_type(int index, const UnitType &type) {
	if (index >= static_cast<int>(types_.size())) {
		types_.resize(index + 1);
		fields_.resize(index + 1);
	}
	types_[index] = type;
}

void World::set_active_types(const std::vector<int> &types) {
	active_types_ = types;
}

void World::set_gates(const std::vector<float> &gates) {
	gates_ = gates;
}

void World::set_terrain(const float *heights, const uint8_t *water, int src_res, float size, float water_level) {
	res_ = (src_res - 1) / 2 + 1;
	cell_ = size / static_cast<float>(res_ - 1);
	half_ = size * 0.5f;
	water_level_ = water_level;
	const int total = res_ * res_;
	height_.resize(total);
	wet_.resize(total);
	for (int j = 0; j < res_; j++) {
		for (int i = 0; i < res_; i++) {
			const int source = (j * 2) * src_res + i * 2;
			height_[j * res_ + i] = heights[source];
			wet_[j * res_ + i] = water[source] != 0 ? 1 : 0;
		}
	}
	find_bridges();
}

int World::cell_at(float x, float z) const {
	const int i = std::clamp(static_cast<int>(std::lround((x + half_) / cell_)), 0, res_ - 1);
	const int j = std::clamp(static_cast<int>(std::lround((z + half_) / cell_)), 0, res_ - 1);
	return j * res_ + i;
}

float World::surface(int cell) const {
	return wet_[cell] ? water_level_ : height_[cell];
}

// Time in seconds to go from a to its neighbor b.
float World::edge_cost(const UnitType &type, int a, int b, float flat_distance, uint8_t &mode) const {
	if (wet_[b]) {
		mode = MODE_BOAT;
		const float sail = flat_distance / type.boat_speed;
		return wet_[a] ? sail : sail + type.embark_time;
	}
	if (wet_[a]) {
		mode = MODE_BOAT;
		return flat_distance / type.walk_speed + type.embark_time * 0.25f;
	}
	if (height_[a] < settings.void_level || height_[b] < settings.void_level) {
		mode = MODE_WALK;
		return INFINITE_COST;
	}
	const float rise = height_[b] - height_[a];
	const float slope = rise / flat_distance;
	const float length = std::sqrt(flat_distance * flat_distance + rise * rise);
	float speed;
	if (slope > type.climb_slope) {
		mode = MODE_CLIMB;
		speed = type.climb_speed;
	} else if (slope < -type.climb_slope * 1.4f) {
		mode = MODE_CLIMB;
		speed = type.climb_speed * 1.6f;
	} else {
		mode = MODE_WALK;
		speed = slope > 0.0f ? type.walk_speed / (1.0f + type.uphill_penalty * slope) : type.walk_speed / (1.0f - 0.6f * slope);
	}
	return length / speed;
}

float World::bridge_cost(const UnitType &type, const Bridge &bridge) const {
	const float cross = bridge.span / type.walk_speed;
	if (bridge.built) {
		return cross;
	}
	return cross + bridge.span * type.bridge_time * (1.0f - bridge.progress);
}

float World::tunnel_time(const UnitType &type, const Tunnel &tunnel) const {
	return tunnel.length / (type.walk_speed * settings.tunnel_speed);
}

// A bridge candidate runs in a straight line from the rim of a gap to the far rim at a similar height.
void World::find_bridges() {
	std::vector<Bridge> kept;
	for (const Bridge &old : bridges_) {
		const bool intact = old.a < static_cast<int>(height_.size()) && old.b < static_cast<int>(height_.size()) &&
				std::fabs(height_[old.a] - old.height_a) < 1.0f && std::fabs(height_[old.b] - old.height_b) < 1.0f;
		if (old.built && intact) {
			kept.push_back(old);
		}
	}
	bridges_ = std::move(kept);

	const int dir_i[4] = { 1, 0, 1, 1 };
	const int dir_j[4] = { 0, 1, 1, -1 };
	const float max_steps = settings.max_span / cell_;
	for (int d = 0; d < 4; d++) {
		const int di = dir_i[d];
		const int dj = dir_j[d];
		const float step_length = cell_ * ((di != 0 && dj != 0) ? 1.41421356f : 1.0f);
		const int limit = static_cast<int>(max_steps / ((di != 0 && dj != 0) ? 1.41421356f : 1.0f));
		for (int j = 1; j < res_ - 1; j++) {
			for (int i = 1; i < res_ - 1; i++) {
				const int a = j * res_ + i;
				if (wet_[a]) {
					continue;
				}
				const float start = height_[a];
				const int behind = (j - dj) * res_ + (i - di);
				const int ahead = (j + dj) * res_ + (i + di);
				// Only the true edge of a drop can hold a bridge end.
				if (surface(behind) < start - 0.4f || surface(ahead) >= start - 0.25f) {
					continue;
				}
				float deepest = start - surface(ahead);
				for (int n = 2; n <= limit; n++) {
					const int ci = i + di * n;
					const int cj = j + dj * n;
					if (ci < 1 || cj < 1 || ci >= res_ - 1 || cj >= res_ - 1) {
						break;
					}
					const int c = cj * res_ + ci;
					const float level = surface(c);
					if (wet_[c] || level < start - 0.6f) {
						deepest = std::max(deepest, start - level);
						continue;
					}
					const float span = static_cast<float>(n) * step_length;
					const int past = (cj + dj) * res_ + (ci + di);
					const bool level_ends = std::fabs(level - start) <= std::max(1.2f, span * 0.12f);
					if (deepest >= settings.min_gap_depth && level_ends && surface(past) >= level - 0.6f) {
						Bridge bridge;
						bridge.a = a;
						bridge.b = c;
						bridge.height_a = start;
						bridge.height_b = level;
						bridge.span = span;
						bridges_.push_back(bridge);
					}
					break;
				}
			}
		}
	}
	build_links();
}

// Groups crossings by destination, which is what the backward search needs.
void World::build_links() {
	if (res_ == 0) {
		return;
	}
	const int total = res_ * res_;
	link_start_.assign(total + 1, 0);
	for (const Bridge &bridge : bridges_) {
		link_start_[bridge.a + 1]++;
		link_start_[bridge.b + 1]++;
	}
	for (const Tunnel &tunnel : tunnels_) {
		link_start_[tunnel.a + 1]++;
		link_start_[tunnel.b + 1]++;
	}
	for (int c = 0; c < total; c++) {
		link_start_[c + 1] += link_start_[c];
	}
	links_.resize(bridges_.size() * 2 + tunnels_.size() * 2);
	std::vector<int> fill(link_start_.begin(), link_start_.end() - 1);
	for (int index = 0; index < static_cast<int>(bridges_.size()); index++) {
		const Bridge &bridge = bridges_[index];
		links_[fill[bridge.b]++] = { bridge.a, index };
		links_[fill[bridge.a]++] = { bridge.b, index };
	}
	for (int index = 0; index < static_cast<int>(tunnels_.size()); index++) {
		const Tunnel &tunnel = tunnels_[index];
		links_[fill[tunnel.b]++] = { tunnel.a, -2 - index };
		links_[fill[tunnel.a]++] = { tunnel.b, -2 - index };
	}
}

// Searches outward from home. Each cell ends up knowing its best next step and how long the trip takes.
void World::search(const UnitType &type, int allow, Field &field) {
	const int total = res_ * res_;
	field.cost.assign(total, INFINITE_COST);
	field.next.assign(total, -1);
	field.via.assign(total, -1);
	field.mode.assign(total, MODE_WALK);
	using Entry = std::pair<float, int>;
	std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> open;
	for (int cell = 0; cell < total; cell++) {
		if (goal_mask_[cell]) {
			field.cost[cell] = 0.0f;
			field.mode[cell] = MODE_GOAL;
			open.push({ 0.0f, cell });
		}
	}
	while (!open.empty()) {
		const Entry top = open.top();
		open.pop();
		const int b = top.second;
		if (top.first > field.cost[b]) {
			continue;
		}
		const int bi = b % res_;
		const int bj = b / res_;
		for (int n = 0; n < 8; n++) {
			const int ai = bi + STEP_I[n];
			const int aj = bj + STEP_J[n];
			if (ai < 0 || aj < 0 || ai >= res_ || aj >= res_) {
				continue;
			}
			const int a = aj * res_ + ai;
			uint8_t mode;
			const float distance = cell_ * (n >= 4 ? 1.41421356f : 1.0f);
			const float time = edge_cost(type, a, b, distance, mode);
			if ((mode == MODE_CLIMB && !(allow & ALLOW_CLIMB)) || (mode == MODE_BOAT && !(allow & ALLOW_BOAT))) {
				continue;
			}
			const float candidate = top.first + time;
			if (candidate < field.cost[a]) {
				field.cost[a] = candidate;
				field.next[a] = b;
				field.mode[a] = mode;
				field.via[a] = -1;
				open.push({ candidate, a });
			}
		}
		for (int l = link_start_[b]; l < link_start_[b + 1]; l++) {
			const Link &link = links_[l];
			float time;
			uint8_t mode;
			if (link.via >= 0) {
				const Bridge &bridge = bridges_[link.via];
				if (!bridge.built && !(allow & ALLOW_BRIDGE)) {
					continue;
				}
				time = bridge_cost(type, bridge);
				mode = MODE_BRIDGE;
			} else {
				time = tunnel_time(type, tunnels_[-2 - link.via]);
				mode = MODE_TUNNEL;
			}
			const float candidate = top.first + time;
			if (candidate < field.cost[link.from]) {
				field.cost[link.from] = candidate;
				field.next[link.from] = b;
				field.mode[link.from] = mode;
				field.via[link.from] = link.via;
				open.push({ candidate, link.from });
			}
		}
	}
}

void World::solve_active() {
	for (const int type : active_types_) {
		search(types_[type], ALLOW_ALL, fields_[type]);
	}
}

void World::solve(float goal_x, float goal_z, float goal_radius) {
	goal_x_ = goal_x;
	goal_z_ = goal_z;
	goal_radius_ = goal_radius;
	const int total = res_ * res_;
	goal_mask_.assign(total, 0);
	goal_mask_[cell_at(goal_x, goal_z)] = 1;
	if (goal_radius > 0.0f) {
		for (int cell = 0; cell < total; cell++) {
			const float dx = world_x(cell) - goal_x;
			const float dz = world_z(cell) - goal_z;
			if (dx * dx + dz * dz <= goal_radius * goal_radius) {
				goal_mask_[cell] = 1;
			}
		}
	}
	solve_active();
}

float World::cost_at(int type, float x, float z) const {
	const Field &field = fields_[type];
	return field.cost.empty() ? -1.0f : field.cost[cell_at(x, z)];
}

std::vector<float> World::option_costs(int type, int allow) {
	std::vector<float> out;
	search(types_[type], allow, scratch_);
	for (size_t g = 0; g + 1 < gates_.size(); g += 2) {
		const float cost = scratch_.cost[cell_at(gates_[g], gates_[g + 1])];
		out.push_back(cost == INFINITE_COST ? -1.0f : cost);
	}
	return out;
}

std::vector<float> World::via_costs(int type, float x, float z) {
	std::vector<float> out;
	const int point = cell_at(x, z);
	const float onward = fields_[type].cost[point];
	// A search from the point itself gives the time to reach it from anywhere.
	std::vector<uint8_t> real_goal(res_ * res_, 0);
	real_goal.swap(goal_mask_);
	goal_mask_[point] = 1;
	search(types_[type], ALLOW_ALL, scratch_);
	real_goal.swap(goal_mask_);
	for (size_t g = 0; g + 1 < gates_.size(); g += 2) {
		const float cost = scratch_.cost[cell_at(gates_[g], gates_[g + 1])];
		out.push_back(cost == INFINITE_COST || onward == INFINITE_COST ? -1.0f : cost + onward);
	}
	return out;
}

std::vector<float> World::trace(int type, float x, float z) const {
	std::vector<float> points;
	const Field &field = fields_[type];
	if (field.cost.empty()) {
		return points;
	}
	int cell = cell_at(x, z);
	const int total = res_ * res_;
	for (int guard = 0; guard < total && cell >= 0; guard++) {
		uint8_t mode = field.mode[cell];
		if (mode == MODE_BRIDGE && bridges_[field.via[cell]].built) {
			mode = MODE_BUILT_BRIDGE;
		}
		points.push_back(world_x(cell));
		points.push_back(surface(cell));
		points.push_back(world_z(cell));
		points.push_back(static_cast<float>(mode));
		if (is_goal(cell)) {
			break;
		}
		cell = field.next[cell];
	}
	return points;
}

int World::add_tunnel(float ax, float az, float bx, float bz) {
	Tunnel tunnel;
	tunnel.id = next_tunnel_id_++;
	tunnel.a = cell_at(ax, az);
	tunnel.b = cell_at(bx, bz);
	const float dx = ax - bx;
	const float dz = az - bz;
	tunnel.length = std::sqrt(dx * dx + dz * dz);
	tunnels_.push_back(tunnel);
	build_links();
	return tunnel.id;
}

void World::remove_tunnel(int id) {
	tunnels_.erase(std::remove_if(tunnels_.begin(), tunnels_.end(), [id](const Tunnel &t) { return t.id == id; }), tunnels_.end());
	build_links();
}

void World::begin_wave() {
	units_.clear();
	shots_.clear();
	impacts_.clear();
	launches_.clear();
	deaths_.clear();
	fires_.clear();
	arrived_ = 0;
	kills_ = 0;
	earned_ = 0.0f;
	seed_ = 12345u;
}

void World::add_group(int type, float x, float z, int count, float interval, float delay) {
	const int cell = cell_at(x, z);
	const auto random_offset = [this]() {
		seed_ = seed_ * 1664525u + 1013904223u;
		return static_cast<float>((seed_ >> 16) & 0xFFFF) / 65535.0f * 3.2f - 1.6f;
	};
	for (int n = 0; n < count; n++) {
		Unit unit;
		unit.type = type;
		unit.cell = cell;
		unit.delay = delay + static_cast<float>(n) * interval;
		unit.offset_x = random_offset();
		unit.offset_z = random_offset();
		unit.hp = types_[type].hp;
		unit.max_hp = types_[type].hp;
		units_.push_back(unit);
	}
}

void World::finish_wave() {
	// A type with no route yet must get one before anyone sets out.
	bool missing = false;
	for (const Unit &unit : units_) {
		if (std::find(active_types_.begin(), active_types_.end(), unit.type) == active_types_.end()) {
			active_types_.push_back(unit.type);
			missing = true;
		}
	}
	if (missing) {
		solve_active();
	}
	active_ = static_cast<int>(units_.size());
	figure_buffer_.assign(units_.size() * 20, 0.0f);
	boat_buffer_.assign(units_.size() * 20, 0.0f);
	shot_buffer_.assign(static_cast<size_t>(MAX_SHOTS) * 20, 0.0f);
	stone_buffer_.assign(static_cast<size_t>(MAX_SHOTS) * 20, 0.0f);
}

void World::pick_edge(Unit &unit) {
	if (is_goal(unit.cell)) {
		unit.done = true;
		unit.to = -1;
		arrived_++;
		return;
	}
	const Field &field = fields_[unit.type];
	const UnitType &type = types_[unit.type];
	const int to = field.next[unit.cell];
	unit.waiting = false;
	if (to < 0) {
		unit.to = unit.cell;
		unit.edge_time = 1.0f;
		return;
	}
	unit.to = to;
	unit.mode = field.mode[unit.cell];
	unit.via = field.via[unit.cell];
	if (unit.mode == MODE_CLIMB) {
		if (unit.climb_from < 0) {
			unit.climb_from = unit.cell;
		}
	} else {
		unit.climb_from = -1;
	}
	if (unit.mode == MODE_BRIDGE) {
		const Bridge &bridge = bridges_[unit.via];
		unit.waiting = !bridge.built;
		unit.edge_time = bridge.span / type.walk_speed;
		return;
	}
	if (unit.mode == MODE_TUNNEL) {
		unit.edge_time = std::max(tunnel_time(type, tunnels_[-2 - unit.via]), 0.01f);
		return;
	}
	const bool diagonal = (to % res_) != (unit.cell % res_) && (to / res_) != (unit.cell / res_);
	uint8_t mode;
	unit.edge_time = std::max(edge_cost(type, unit.cell, to, cell_ * (diagonal ? 1.41421356f : 1.0f), mode), 0.01f);
}

// High game speeds are split into small ticks, so results match normal speed.
void World::step(float dt) {
	if (units_.empty()) {
		return;
	}
	while (dt > 0.0f) {
		const float slice = std::min(dt, MAX_TICK);
		tick(slice);
		dt -= slice;
	}
	write_buffers();
}

void World::tick(float dt) {
	std::vector<float> work;
	std::vector<float> fastest;
	active_ = 0;
	for (Unit &unit : units_) {
		if (unit.done) {
			continue;
		}
		unit.flash = std::max(unit.flash - dt, 0.0f);
		if (unit.delay > 0.0f) {
			unit.delay -= dt;
			active_++;
			continue;
		}
		active_++;
		if (unit.stun > 0.0f) {
			unit.stun -= dt;
			continue;
		}
		float pace = 1.0f;
		if (unit.slow_left > 0.0f) {
			unit.slow_left -= dt;
			pace = 1.0f - unit.slow;
			if (unit.slow_left <= 0.0f) {
				unit.slow = 0.0f;
			}
		}
		if (unit.to < 0 || unit.waiting) {
			pick_edge(unit);
		}
		if (unit.done) {
			active_--;
			continue;
		}
		if (unit.waiting) {
			Bridge &site = bridges_[unit.via];
			if (site.progress <= 0.0f) {
				site.from_b = unit.cell == site.b;
			}
			if (work.empty()) {
				work.assign(bridges_.size(), 0.0f);
				fastest.assign(bridges_.size(), 0.0f);
			}
			const UnitType &type = types_[unit.type];
			work[unit.via] += 1.0f / (type.crew * type.bridge_time);
			fastest[unit.via] = std::max(fastest[unit.via], 1.0f / type.bridge_time);
			continue;
		}
		unit.t += dt * pace / unit.edge_time;
		while (unit.t >= 1.0f && !unit.done && !unit.waiting) {
			unit.t -= 1.0f;
			unit.cell = unit.to;
			pick_edge(unit);
		}
		if (unit.done) {
			active_--;
		}
		if (unit.waiting) {
			unit.t = 0.0f;
		}
	}
	// A bridge comes up at full speed once a full crew has gathered.
	bool finished_one = false;
	for (size_t b = 0; b < work.size(); b++) {
		if (work[b] <= 0.0f) {
			continue;
		}
		Bridge &bridge = bridges_[b];
		bridge.progress += dt * std::min(work[b], fastest[b]) / bridge.span;
		if (bridge.progress >= 1.0f) {
			bridge.progress = 1.0f;
			bridge.built = true;
			finished_one = true;
		}
	}
	if (finished_one) {
		solve_active();
	}
	tick_towers(dt);
	tick_shots(dt);
	tick_fires(dt);
}

void World::unit_position(const Unit &unit, float &px, float &y, float &pz, float &dx, float &dz, bool &on_water) const {
	const int to = unit.to >= 0 ? unit.to : unit.cell;
	const float ax = world_x(unit.cell);
	const float az = world_z(unit.cell);
	const float bx = world_x(to);
	const float bz = world_z(to);
	const float t = unit.waiting ? 0.0f : std::min(unit.t, 1.0f);
	on_water = unit.mode == MODE_BOAT && (wet_[unit.cell] != 0 || wet_[to] != 0);
	if (unit.mode == MODE_BRIDGE && !unit.waiting && unit.via >= 0) {
		const Bridge &bridge = bridges_[unit.via];
		y = unit.cell == bridge.a ? bridge.height_a + (bridge.height_b - bridge.height_a) * t
								  : bridge.height_b + (bridge.height_a - bridge.height_b) * t;
	} else {
		y = surface(unit.cell) + (surface(to) - surface(unit.cell)) * t;
	}
	dx = bx - ax;
	dz = bz - az;
	const float length = std::sqrt(dx * dx + dz * dz);
	if (length > 0.0001f) {
		dx /= length;
		dz /= length;
	} else {
		dx = 0.0f;
		dz = 1.0f;
	}
	px = ax + (bx - ax) * t + unit.offset_x;
	pz = az + (bz - az) * t + unit.offset_z;
}

float World::ground_height(float x, float z) const {
	const float fx = std::clamp((x + half_) / cell_, 0.0f, static_cast<float>(res_ - 1) - 0.001f);
	const float fz = std::clamp((z + half_) / cell_, 0.0f, static_cast<float>(res_ - 1) - 0.001f);
	const int i = static_cast<int>(fx);
	const int j = static_cast<int>(fz);
	const float tx = fx - static_cast<float>(i);
	const float tz = fz - static_cast<float>(j);
	const float *row0 = &height_[j * res_ + i];
	const float *row1 = row0 + res_;
	const float a = row0[0] + (row0[1] - row0[0]) * tx;
	const float b = row1[0] + (row1[1] - row1[0]) * tx;
	return a + (b - a) * tz;
}

bool World::in_cone(const Cone &cone, float x, float y, float z) const {
	const float ox = x - cone.x;
	const float oy = y - cone.y;
	const float oz = z - cone.z;
	if (!cone.in_reach(ox, oy, oz, y)) {
		return false;
	}
	return ox * cone.dx + oy * cone.dy + oz * cone.dz >= cone.cos_half * std::sqrt(ox * ox + oy * oy + oz * oz);
}

// Follows the shot's line and checks whether the ground rises above it. A lobbed stone flies over everything.
bool World::clear_sight(const Cone &cone, float x, float y, float z) const {
	if (cone.lob) {
		return true;
	}
	const float dx = x - cone.x;
	const float dy = y - cone.y;
	const float dz = z - cone.z;
	const float length = std::sqrt(dx * dx + dy * dy + dz * dz);
	const float spacing = cell_ * 0.5f;
	// The ground right at the target never counts as cover either.
	for (float d = SIGHT_START; d < length - 1.5f; d += spacing) {
		const float t = d / length;
		if (cone.y + dy * t < ground_height(cone.x + dx * t, cone.z + dz * t)) {
			return false;
		}
	}
	return true;
}

int World::add_tower(const Cone &cone, float damage, float cooldown, float splash, int splash_targets) {
	Tower tower;
	tower.id = next_tower_id_++;
	tower.cone = cone;
	tower.damage = damage;
	tower.cooldown = cooldown;
	tower.splash = splash;
	tower.splash_targets = splash_targets;
	towers_.push_back(tower);
	return tower.id;
}

void World::remove_tower(int id) {
	for (auto *list : { &towers_, &parked_towers_ }) {
		list->erase(std::remove_if(list->begin(), list->end(), [id](const Tower &t) { return t.id == id; }), list->end());
	}
}

void World::set_tower_parked(int id, bool parked) {
	auto &from = parked ? towers_ : parked_towers_;
	auto &to = parked ? parked_towers_ : towers_;
	auto item = std::find_if(from.begin(), from.end(), [id](const Tower &tower) { return tower.id == id; });
	if (item == from.end()) {
		return;
	}
	// Towers normally fire in creation order, including after undoing a sale.
	auto destination = std::lower_bound(to.begin(), to.end(), id, [](const Tower &tower, int key) { return tower.id < key; });
	to.insert(destination, *item);
	from.erase(item);
}

float World::tower_timer(int id) const {
	const Tower *tower = find_tower(id);
	return tower ? tower->timer : 0.0f;
}

void World::restore_tower_timer(int id, float timer) {
	for (Tower &tower : towers_) {
		if (tower.id == id) {
			tower.timer = timer;
			return;
		}
	}
}

void World::set_tower_aim(int id, float dx, float dy, float dz) {
	for (Tower &tower : towers_) {
		if (tower.id == id) {
			tower.cone.dx = dx;
			tower.cone.dy = dy;
			tower.cone.dz = dz;
		}
	}
}

int World::tower_kills(int id) const {
	for (const Tower &tower : towers_) {
		if (tower.id == id) {
			return tower.kills;
		}
	}
	return 0;
}

std::vector<uint8_t> World::visibility_map(const Cone &cone) const {
	std::vector<uint8_t> out(static_cast<size_t>(res_) * res_, 0);
	if (height_.empty()) {
		return out;
	}
	// Slightly wider than the real cone, so blending at the cone's edge has real values to use.
	Cone wide = cone;
	wide.range = cone.range + 3.0f;
	wide.min_range = std::max(cone.min_range - 3.0f, 0.0f);
	const float half = std::acos(std::clamp(cone.cos_half, -1.0f, 1.0f));
	wide.cos_half = std::cos(std::min(half + 0.12f, 3.14159f));
	const int reach = static_cast<int>((wide.range + wide.height_reach_max) / cell_) + 1;
	const int ci = static_cast<int>((cone.x + half_) / cell_);
	const int cj = static_cast<int>((cone.z + half_) / cell_);
	for (int j = std::max(cj - reach, 0); j <= std::min(cj + reach, res_ - 1); j++) {
		for (int i = std::max(ci - reach, 0); i <= std::min(ci + reach, res_ - 1); i++) {
			const int cell = j * res_ + i;
			const float x = world_x(cell);
			const float z = world_z(cell);
			const float y = surface(cell) + TARGET_LIFT;
			if (in_cone(wide, x, y, z) && clear_sight(cone, x, y, z)) {
				out[cell] = 255;
			}
		}
	}
	return out;
}

// Every cell on the routes from all gates, each counted once.
void World::route_stops(std::vector<int> &cells) const {
	const Field &field = fields_[display_type()];
	if (field.cost.empty()) {
		return;
	}
	std::vector<uint8_t> seen(static_cast<size_t>(res_) * res_, 0);
	const int limit = res_ * res_;
	for (size_t g = 0; g + 1 < gates_.size(); g += 2) {
		int cell = cell_at(gates_[g], gates_[g + 1]);
		for (int guard = 0; guard < limit && !is_goal(cell) && field.next[cell] >= 0; guard++) {
			if (seen[cell]) {
				break;
			}
			seen[cell] = 1;
			// Nobody can be shot inside a tunnel, so that stretch is not route a tower can cover.
			if (field.mode[cell] != MODE_TUNNEL) {
				cells.push_back(cell);
			}
			cell = field.next[cell];
		}
	}
}

std::vector<float> World::best_aim(const Cone &cone) const {
	struct Stop {
		float nx;
		float ny;
		float nz;
		float length;
	};
	std::vector<Stop> stops;
	std::vector<float> result;
	std::vector<int> cells;
	route_stops(cells);
	const Field &field = fields_[display_type()];
	for (const int cell : cells) {
		const float x = world_x(cell);
		const float y = surface(cell) + TARGET_LIFT;
		const float z = world_z(cell);
		const float ox = x - cone.x;
		const float oy = y - cone.y;
		const float oz = z - cone.z;
		const float distance = std::sqrt(ox * ox + oy * oy + oz * oz);
		if (cone.in_reach(ox, oy, oz, y) && clear_sight(cone, x, y, z)) {
			const int to = field.next[cell];
			const float sx = world_x(to) - x;
			const float sz = world_z(to) - z;
			stops.push_back({ ox / distance, oy / distance, oz / distance, std::sqrt(sx * sx + sz * sz) });
		}
	}
	if (stops.empty()) {
		return result;
	}
	// Try aiming at each visible stretch, then centre the cone on what the best one covers.
	float best = -1.0f;
	float ax = 0.0f;
	float ay = 0.0f;
	float az = 1.0f;
	for (const Stop &candidate : stops) {
		float covered = 0.0f;
		float sx = 0.0f;
		float sy = 0.0f;
		float sz = 0.0f;
		for (const Stop &stop : stops) {
			if (stop.nx * candidate.nx + stop.ny * candidate.ny + stop.nz * candidate.nz >= cone.cos_half) {
				covered += stop.length;
				sx += stop.nx * stop.length;
				sy += stop.ny * stop.length;
				sz += stop.nz * stop.length;
			}
		}
		if (covered > best) {
			best = covered;
			const float size = std::sqrt(sx * sx + sy * sy + sz * sz);
			if (size > 0.0001f) {
				ax = sx / size;
				ay = sy / size;
				az = sz / size;
			}
		}
	}
	result = { ax, ay, az };
	return result;
}

float World::covered_length(const Cone &cone) const {
	float total = 0.0f;
	std::vector<int> cells;
	route_stops(cells);
	const Field &field = fields_[display_type()];
	for (const int cell : cells) {
		const float x = world_x(cell);
		const float z = world_z(cell);
		const float y = surface(cell) + TARGET_LIFT;
		if (in_cone(cone, x, y, z) && clear_sight(cone, x, y, z)) {
			const int to = field.next[cell];
			const float dx = world_x(to) - x;
			const float dz = world_z(to) - z;
			total += std::sqrt(dx * dx + dz * dz);
		}
	}
	return total;
}

// Each tower shoots the enemy closest to home that it can actually see.
void World::tick_towers(float dt) {
	std::vector<std::pair<float, int>> candidates;
	for (Tower &tower : towers_) {
		tower.timer -= dt;
		if (tower.timer > 0.0f || static_cast<int>(shots_.size()) >= MAX_SHOTS) {
			continue;
		}
		candidates.clear();
		for (int n = 0; n < static_cast<int>(units_.size()); n++) {
			const Unit &unit = units_[n];
			if (unit.done || unit.delay > 0.0f || is_hidden(unit)) {
				continue;
			}
			float x, y, z, dx, dz;
			bool on_water;
			unit_position(unit, x, y, z, dx, dz, on_water);
			if (in_cone(tower.cone, x, y + TARGET_LIFT, z)) {
				candidates.push_back({ fields_[unit.type].cost[unit.cell], n });
			}
		}
		std::sort(candidates.begin(), candidates.end());
		int target = -1;
		float tx = 0.0f;
		float ty = 0.0f;
		float tz = 0.0f;
		for (size_t c = 0; c < candidates.size() && c < 12; c++) {
			const Unit &unit = units_[candidates[c].second];
			float x, y, z, dx, dz;
			bool on_water;
			unit_position(unit, x, y, z, dx, dz, on_water);
			if (clear_sight(tower.cone, x, y + TARGET_LIFT, z)) {
				target = candidates[c].second;
				tx = x;
				ty = y + TARGET_LIFT;
				tz = z;
				break;
			}
		}
		if (target < 0) {
			tower.timer = 0.1f; // nothing to shoot, so check again shortly
			continue;
		}
		Shot shot;
		shot.tx = tx;
		shot.ty = ty;
		shot.tz = tz;
		shot.speed = tower.shot_speed;
		if (tower.cone.lob) {
			// Thrown up from the arm on top of the tower, landing after a flight that grows with distance.
			shot.lob = true;
			shot.x = shot.sx = tower.cone.x;
			shot.y = shot.sy = tower.cone.y + LOB_LIFT;
			shot.z = shot.sz = tower.cone.z;
			const float flat = std::sqrt((tx - shot.x) * (tx - shot.x) + (tz - shot.z) * (tz - shot.z));
			shot.flight = std::max(flat / tower.shot_speed, LOB_MIN_FLIGHT);
			shot.arc = LOB_ARC_BASE + flat * LOB_ARC_PER_METRE;
			shot.dx = 0.0f;
			shot.dy = 1.0f;
			shot.dz = 0.0f;
		} else {
			shot.x = tower.cone.x + tower.cone.dx * GUN_LENGTH;
			shot.y = tower.cone.y + tower.cone.dy * GUN_LENGTH;
			shot.z = tower.cone.z + tower.cone.dz * GUN_LENGTH;
			shot.dx = tower.cone.dx;
			shot.dy = tower.cone.dy;
			shot.dz = tower.cone.dz;
		}
		// A shot from high above the target lands harder, measured when it is fired.
		const float drop = tower.cone.y - ty;
		shot.damage = tower.damage + std::clamp(drop * tower.height_damage, 0.0f, tower.height_damage_max);
		shot.splash = tower.splash;
		shot.splash_targets = tower.splash_targets;
		shot.effects = tower.effects;
		shot.target = target;
		shot.tower_id = tower.id;
		shots_.push_back(shot);
		if (launches_.size() < MAX_LAUNCH_FLOATS) {
			launches_.insert(launches_.end(), { static_cast<float>(tower.id), shot.x, shot.y, shot.z, tx, ty, tz });
		}
		tower.timer = tower.cooldown;
	}
}

void World::damage_unit(Unit &unit, float damage, int tower_id, bool flash) {
	unit.hp -= damage;
	if (flash) {
		unit.flash = 0.12f;
	}
	if (unit.hp > 0.0f) {
		return;
	}
	unit.done = true;
	kills_++;
	if (deaths_.size() < MAX_DEATH_FLOATS) {
		float x, y, z, dx, dz;
		bool on_water;
		unit_position(unit, x, y, z, dx, dz, on_water);
		deaths_.insert(deaths_.end(), { x, y, z, static_cast<float>(unit.type) });
	}
	earned_ += types_[unit.type].reward;
	for (Tower &tower : towers_) {
		if (tower.id == tower_id) {
			tower.kills++;
		}
	}
}

// Everyone near the impact is hurt, less toward the edge, so dense groups take the most damage.
void World::explode(const Shot &shot) {
	Unit &target = units_[shot.target];
	if (!target.done && !is_hidden(target)) {
		damage_unit(target, shot.damage, shot.tower_id);
		apply_effects(target, shot.effects);
	}
	if (shot.effects.fire_time > 0.0f && fires_.size() < MAX_FIRES) {
		Fire fire;
		fire.x = shot.x;
		fire.y = shot.y - TARGET_LIFT;
		fire.z = shot.z;
		fire.radius = shot.effects.fire_radius;
		fire.dps = shot.effects.fire_dps;
		fire.left = shot.effects.fire_time;
		fire.total = shot.effects.fire_time;
		fire.tower_id = shot.tower_id;
		fires_.push_back(fire);
	}
	if (impacts_.size() < MAX_IMPACT_FLOATS) {
		const float flags = (shot.effects.fire_time > 0.0f ? 1.0f : 0.0f) + (shot.effects.slow > 0.0f ? 2.0f : 0.0f) + (shot.lob ? 4.0f : 0.0f);
		impacts_.insert(impacts_.end(), { shot.x, shot.y, shot.z, shot.splash, static_cast<float>(shot.tower_id), flags });
	}
	if (shot.splash <= 0.0f) {
		return;
	}
	blast_hits_.clear();
	for (int n = 0; n < static_cast<int>(units_.size()); n++) {
		const Unit &unit = units_[n];
		if (n == shot.target || unit.done || unit.delay > 0.0f || is_hidden(unit)) {
			continue;
		}
		float x, y, z, dx, dz;
		bool on_water;
		unit_position(unit, x, y, z, dx, dz, on_water);
		const float ox = x - shot.x;
		const float oz = z - shot.z;
		const float distance = std::sqrt(ox * ox + oz * oz);
		if (distance <= shot.splash && std::fabs(y + TARGET_LIFT - shot.y) <= SPLASH_HEIGHT) {
			blast_hits_.push_back({ distance, n });
		}
	}
	// A blast only reaches so many bodies, so slowing enemies into a crush cannot make it endlessly stronger.
	const size_t others = static_cast<size_t>(std::max(shot.splash_targets - 1, 0));
	if (blast_hits_.size() > others) {
		std::partial_sort(blast_hits_.begin(), blast_hits_.begin() + others, blast_hits_.end());
		blast_hits_.resize(others);
	}
	for (const std::pair<float, int> &hit : blast_hits_) {
		Unit &unit = units_[hit.second];
		damage_unit(unit, shot.damage * (1.0f - 0.5f * hit.first / shot.splash), shot.tower_id);
		if (!unit.done) {
			apply_effects(unit, shot.effects);
		}
	}
}

// Slows take the stronger of the old and new, and run for the longer of the two times.
void World::apply_effects(Unit &unit, const Effects &effects) {
	if (effects.slow > 0.0f && effects.slow_time > 0.0f) {
		unit.slow = std::max(unit.slow, effects.slow);
		unit.slow_left = std::max(unit.slow_left, effects.slow_time);
	}
	// Someone halfway up a wall falls back to where the climb began and lies there a moment.
	if (effects.knock_climbers && unit.mode == MODE_CLIMB && unit.climb_from >= 0 && !unit.waiting) {
		unit.cell = unit.climb_from;
		unit.to = -1;
		unit.t = 0.0f;
		unit.climb_from = -1;
		unit.stun = KNOCK_STUN;
	}
}

// Burning ground hurts everyone standing in it, without the bright hit flash, every tick.
// Overlapping patches do not add up: each enemy burns only from the hottest patch it stands in,
// or a gun that keeps firing into one spot would stack fire without limit.
void World::tick_fires(float dt) {
	for (size_t f = 0; f < fires_.size();) {
		fires_[f].left -= dt;
		if (fires_[f].left <= 0.0f) {
			fires_[f] = fires_.back();
			fires_.pop_back();
			continue;
		}
		f++;
	}
	if (fires_.empty()) {
		return;
	}
	for (Unit &unit : units_) {
		if (unit.done || unit.delay > 0.0f || is_hidden(unit)) {
			continue;
		}
		float x, y, z, dx, dz;
		bool on_water;
		unit_position(unit, x, y, z, dx, dz, on_water);
		if (on_water) {
			continue;
		}
		const Fire *hottest = nullptr;
		for (const Fire &fire : fires_) {
			const float ox = x - fire.x;
			const float oz = z - fire.z;
			if (ox * ox + oz * oz <= fire.radius * fire.radius && std::fabs(y - fire.y) <= SPLASH_HEIGHT && (!hottest || fire.dps > hottest->dps)) {
				hottest = &fire;
			}
		}
		if (hottest) {
			damage_unit(unit, hottest->dps * dt, hottest->tower_id, false);
		}
	}
}

std::vector<float> World::fires() const {
	std::vector<float> out;
	out.reserve(fires_.size() * 5);
	for (const Fire &fire : fires_) {
		out.insert(out.end(), { fire.x, fire.y, fire.z, fire.radius, fire.left / fire.total });
	}
	return out;
}

const Tower *World::find_tower(int id) const {
	for (const Tower &tower : towers_) {
		if (tower.id == id) {
			return &tower;
		}
	}
	return nullptr;
}

// Copies a stats list, laid out as set_tower_stats describes, onto a tower. Its apex and aim stay.
static void apply_stats(Tower &tower, const std::vector<float> &stats) {
	tower.cone.cos_half = std::cos(stats[0]);
	tower.cone.range = stats[1];
	tower.damage = stats[2];
	tower.cooldown = stats[3];
	tower.splash = stats[4];
	tower.splash_targets = static_cast<int>(stats[5]);
	tower.cone.height_reach = stats[6];
	tower.cone.height_reach_max = stats[7];
	tower.effects.slow = stats[8];
	tower.effects.slow_time = stats[9];
	tower.effects.knock_climbers = stats[10] > 0.5f;
	tower.effects.fire_time = stats[11];
	tower.effects.fire_radius = stats[12];
	tower.effects.fire_dps = stats[13];
	tower.cone.min_range = stats[14];
	tower.cone.lob = stats[15] > 0.5f;
	tower.height_damage = stats[16];
	tower.height_damage_max = stats[17];
	tower.shot_speed = stats[18] > 1.0f ? stats[18] : SHOT_SPEED;
}

void World::set_tower_stats(int id, const std::vector<float> &stats) {
	if (static_cast<int>(stats.size()) < STAT_COUNT) {
		return;
	}
	for (Tower &tower : towers_) {
		if (tower.id != id) {
			continue;
		}
		apply_stats(tower, stats);
		// An upgrade fires at once rather than waiting out the old, slower cooldown.
		tower.timer = std::min(tower.timer, tower.cooldown);
	}
}

// A cone with the apex and aim of at and the reach and shape a stats list gives.
static bool cone_for(const Cone &at, const std::vector<float> &stats, Cone &out) {
	if (static_cast<int>(stats.size()) < World::STAT_COUNT) {
		return false;
	}
	Tower probe;
	probe.cone = at;
	apply_stats(probe, stats);
	out = probe.cone;
	return true;
}

std::vector<uint8_t> World::stats_visibility(const Cone &at, const std::vector<float> &stats) const {
	Cone cone;
	return cone_for(at, stats, cone) ? visibility_map(cone) : std::vector<uint8_t>(static_cast<size_t>(res_) * res_, 0);
}

float World::stats_covered(const Cone &at, const std::vector<float> &stats) const {
	Cone cone;
	return cone_for(at, stats, cone) ? covered_length(cone) : 0.0f;
}

std::vector<float> World::stats_best_aim(const Cone &at, const std::vector<float> &stats) const {
	Cone cone;
	return cone_for(at, stats, cone) ? best_aim(cone) : std::vector<float>();
}

std::vector<uint8_t> World::tower_visibility(int id) const {
	const Tower *tower = find_tower(id);
	return tower ? visibility_map(tower->cone) : std::vector<uint8_t>(static_cast<size_t>(res_) * res_, 0);
}

float World::tower_covered(int id) const {
	const Tower *tower = find_tower(id);
	return tower ? covered_length(tower->cone) : 0.0f;
}

std::vector<float> World::tower_best_aim(int id) const {
	const Tower *tower = find_tower(id);
	return tower ? best_aim(tower->cone) : std::vector<float>();
}

// Arrows curve to follow their target. If it dies first they still land where it last was.
void World::tick_shots(float dt) {
	for (size_t s = 0; s < shots_.size();) {
		Shot &shot = shots_[s];
		const Unit &unit = units_[shot.target];
		if (!unit.done && !is_hidden(unit)) {
			float x, y, z, dx, dz;
			bool on_water;
			unit_position(unit, x, y, z, dx, dz, on_water);
			shot.tx = x;
			shot.ty = y + TARGET_LIFT;
			shot.tz = z;
		}
		if (shot.lob) {
			// The stone follows its target along the ground while rising and falling on a fixed arc.
			shot.age += dt;
			const float p = std::min(shot.age / shot.flight, 1.0f);
			const float nx = shot.sx + (shot.tx - shot.sx) * p;
			const float ny = shot.sy + (shot.ty - shot.sy) * p + shot.arc * 4.0f * p * (1.0f - p);
			const float nz = shot.sz + (shot.tz - shot.sz) * p;
			const float mx = nx - shot.x;
			const float my = ny - shot.y;
			const float mz = nz - shot.z;
			const float moved = std::sqrt(mx * mx + my * my + mz * mz);
			if (moved > 0.0001f) {
				shot.dx = mx / moved;
				shot.dy = my / moved;
				shot.dz = mz / moved;
			}
			shot.x = nx;
			shot.y = ny;
			shot.z = nz;
			if (p >= 1.0f) {
				const Shot landed = shot;
				shots_[s] = shots_.back();
				shots_.pop_back();
				explode(landed);
				continue;
			}
			s++;
			continue;
		}
		const float ox = shot.tx - shot.x;
		const float oy = shot.ty - shot.y;
		const float oz = shot.tz - shot.z;
		const float distance = std::sqrt(ox * ox + oy * oy + oz * oz);
		const float travel = shot.speed * dt;
		if (travel >= distance) {
			shot.x = shot.tx;
			shot.y = shot.ty;
			shot.z = shot.tz;
			const Shot landed = shot;
			shots_[s] = shots_.back();
			shots_.pop_back();
			explode(landed);
			continue;
		}
		shot.dx = ox / distance;
		shot.dy = oy / distance;
		shot.dz = oz / distance;
		shot.x += shot.dx * travel;
		shot.y += shot.dy * travel;
		shot.z += shot.dz * travel;
		s++;
	}
}

std::vector<float> World::take_impacts() {
	std::vector<float> out;
	out.swap(impacts_);
	return out;
}

std::vector<float> World::take_launches() {
	std::vector<float> out;
	out.swap(launches_);
	return out;
}

std::vector<float> World::take_deaths() {
	std::vector<float> out;
	out.swap(deaths_);
	return out;
}

void World::write_buffers() {
	std::fill(figure_buffer_.begin(), figure_buffer_.end(), 0.0f);
	std::fill(boat_buffer_.begin(), boat_buffer_.end(), 0.0f);
	std::fill(shot_buffer_.begin(), shot_buffer_.end(), 0.0f);
	std::fill(stone_buffer_.begin(), stone_buffer_.end(), 0.0f);
	for (size_t s = 0; s < shots_.size(); s++) {
		const Shot &shot = shots_[s];
		// The arrow's long axis follows its flight. Side axes only need to be perpendicular.
		const float flat = std::sqrt(shot.dx * shot.dx + shot.dz * shot.dz);
		const float sx = flat > 0.001f ? shot.dz / flat : 1.0f;
		const float sz = flat > 0.001f ? -shot.dx / flat : 0.0f;
		const float ux = shot.dy * sz;
		const float uy = shot.dz * sx - shot.dx * sz;
		const float uz = shot.dy * sx * -1.0f;
		// Stones go to their own buffer, so they can be drawn as rocks instead of arrows.
		float *arrow = shot.lob ? &stone_buffer_[s * 20] : &shot_buffer_[s * 20];
		arrow[0] = sx;
		arrow[1] = ux;
		arrow[2] = shot.dx;
		arrow[3] = shot.x;
		arrow[5] = uy;
		arrow[6] = shot.dy;
		arrow[7] = shot.y;
		arrow[8] = sz;
		arrow[9] = uz;
		arrow[10] = shot.dz;
		arrow[11] = shot.z;
		arrow[12] = arrow[13] = arrow[14] = arrow[15] = 1.0f;
		// The custom slot names the tower, so effects can trail each shot in its tower's style.
		arrow[16] = static_cast<float>(shot.tower_id);
	}
	for (size_t n = 0; n < units_.size(); n++) {
		const Unit &unit = units_[n];
		if (unit.done || unit.delay > 0.0f || is_hidden(unit)) {
			continue;
		}
		const UnitType &type = types_[unit.type];
		float px, y, pz, dx, dz;
		bool on_water;
		unit_position(unit, px, y, pz, dx, dz, on_water);
		float *figure = &figure_buffer_[n * 20];
		figure[0] = dz * type.scale;
		figure[2] = dx * type.scale;
		figure[3] = px;
		figure[5] = type.scale;
		figure[7] = y + UNIT_HALF_HEIGHT * type.scale + (on_water ? 0.25f : 0.0f);
		figure[8] = -dx * type.scale;
		figure[10] = dz * type.scale;
		figure[11] = pz;
		// Wounded enemies darken, and a hit flashes bright for an instant.
		const float health = 0.35f + 0.65f * unit.hp / unit.max_hp;
		const float shade = unit.flash > 0.0f ? 3.0f : health;
		// Slowed or stunned enemies take on a cool tint, so the effect can be seen from far away.
		const float cool = unit.slow_left > 0.0f || unit.stun > 0.0f ? 1.0f : 0.0f;
		figure[12] = type.r * shade * (1.0f - 0.35f * cool);
		figure[13] = type.g * shade * (1.0f - 0.1f * cool);
		figure[14] = type.b * shade * (1.0f + 0.5f * cool) + 0.12f * cool;
		figure[15] = 1.0f;
		if (on_water) {
			float *boat = &boat_buffer_[n * 20];
			boat[0] = dz;
			boat[2] = dx;
			boat[3] = px;
			boat[5] = 1.0f;
			boat[7] = water_level_ + 0.15f;
			boat[8] = -dx;
			boat[10] = dz;
			boat[11] = pz;
			boat[12] = boat[13] = boat[14] = boat[15] = 1.0f;
		}
	}
}

std::vector<float> World::bridge_state() const {
	std::vector<float> out;
	for (const Bridge &bridge : bridges_) {
		if (bridge.progress <= 0.0f) {
			continue;
		}
		// Planks grow from the first point, which is the side the crew arrived on.
		const int first = bridge.from_b ? bridge.b : bridge.a;
		const int second = bridge.from_b ? bridge.a : bridge.b;
		out.push_back(world_x(first));
		out.push_back(bridge.from_b ? bridge.height_b : bridge.height_a);
		out.push_back(world_z(first));
		out.push_back(world_x(second));
		out.push_back(bridge.from_b ? bridge.height_a : bridge.height_b);
		out.push_back(world_z(second));
		out.push_back(bridge.progress);
	}
	return out;
}

void World::forget_bridges() {
	bridges_.clear();
	if (res_ > 0) {
		find_bridges();
	}
}

} // namespace pathcore
