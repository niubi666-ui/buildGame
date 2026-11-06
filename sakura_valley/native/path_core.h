// Enemy route planning, movement and combat. Independent of Godot, so it could move to another engine.
#pragma once
#include <cstdint>
#include <utility>
#include <vector>

namespace pathcore {

enum Mode : uint8_t { MODE_WALK = 0, MODE_CLIMB = 1, MODE_BOAT = 2, MODE_BRIDGE = 3, MODE_GOAL = 4, MODE_BUILT_BRIDGE = 5, MODE_TUNNEL = 6 };

// How a type crosses water. Boats ride on the surface, swimmers wade with their heads above it,
// and divers stay under it, where no tower can see them.
enum WaterStyle : uint8_t { WATER_BOAT = 0, WATER_SWIM = 1, WATER_DIVE = 2 };

// What a route may use beyond walking and finished bridges and tunnels.
enum Allow : int { ALLOW_CLIMB = 1, ALLOW_BOAT = 2, ALLOW_BRIDGE = 4, ALLOW_ALL = 7 };

struct Settings {
	float min_gap_depth = 2.5f; // shallower gaps are never bridged
	float max_span = 45.0f;
	float tunnel_speed = 1.15f; // tunnels are smooth, so everyone walks a little faster
	// Dry ground below this is open sky: nobody can walk or climb there, though a bridge can span it.
	float void_level = -1000.0f;
	// Walking and climbing speed on a drained riverbed, as a share of normal.
	float mud_speed = 1.0f;
};

struct UnitType {
	float walk_speed = 3.5f; // metres per second on flat ground
	float uphill_penalty = 2.5f; // how much a walkable slope slows them
	float climb_speed = 0.8f; // on slopes too steep to walk
	float climb_slope = 0.75f; // rise over run where walking becomes climbing
	float boat_speed = 2.0f;
	float embark_time = 7.0f; // seconds to launch boats
	float bridge_time = 1.6f; // seconds per metre for a full crew
	float crew = 8.0f; // workers who make up a full crew
	float hp = 100.0f;
	float reward = 15.0f;
	float r = 1.0f;
	float g = 0.0f;
	float b = 0.0f;
	float scale = 1.35f;
	uint8_t water_style = WATER_BOAT;
};

struct Bridge {
	int a = 0;
	int b = 0;
	float height_a = 0.0f;
	float height_b = 0.0f;
	float span = 0.0f;
	float progress = 0.0f;
	bool built = false;
	bool from_b = false; // construction started at end b
};

struct Tunnel {
	int id = 0;
	int a = 0;
	int b = 0;
	float length = 0.0f;
};

// A tower's firing cone: apex at the pivot of its gun, axis along where the gun points.
struct Cone {
	float x = 0.0f;
	float y = 0.0f;
	float z = 0.0f;
	float dx = 0.0f;
	float dy = 0.0f;
	float dz = 1.0f;
	float cos_half = 0.8f;
	float range = 60.0f;
	// Extra range for each metre the apex stands above the target, and the most it can add.
	float height_reach = 0.0f;
	float height_reach_max = 0.0f;
	// Nothing closer than this can be hit.
	float min_range = 0.0f;
	// A lobbed shot: distance is measured flat along the ground and hills do not block it.
	bool lob = false;
	// How far this cone reaches toward a target at height y.
	float reach_to(float y) const {
		const float bonus = (this->y - y) * height_reach;
		return range + (bonus > height_reach_max ? height_reach_max : (bonus > 0.0f ? bonus : 0.0f));
	}
	// Whether a target this far from the apex (ox, oy, oz) and at height ty is neither too far nor too close.
	bool in_reach(float ox, float oy, float oz, float ty) const {
		const float distance_sq = lob ? ox * ox + oz * oz : ox * ox + oy * oy + oz * oz;
		const float reach = reach_to(ty);
		const float nearest = min_range > 1.0f ? min_range : 1.0f;
		return distance_sq <= reach * reach && distance_sq >= nearest * nearest;
	}
};

// What a hit does besides damage. Copied from the tower onto each shot it fires.
struct Effects {
	float slow = 0.0f; // fraction of speed taken away
	float slow_time = 0.0f;
	bool knock_climbers = false; // sends anyone climbing back to the foot of the climb
	float fire_time = 0.0f; // seconds the ground burns where the shot lands
	float fire_radius = 0.0f;
	float fire_dps = 0.0f;
};

// A patch of burning ground left by a shot.
struct Fire {
	float x = 0.0f;
	float y = 0.0f;
	float z = 0.0f;
	float radius = 0.0f;
	float dps = 0.0f;
	float left = 0.0f;
	float total = 1.0f;
	int tower_id = 0;
};

struct Tower {
	int id = 0;
	Cone cone;
	float damage = 20.0f;
	float cooldown = 0.6f;
	float splash = 0.0f;
	int splash_targets = 0;
	float timer = 0.0f;
	int kills = 0;
	Effects effects;
	// Extra damage for each metre the tower stands above its target, and the most it can add.
	float height_damage = 0.0f;
	float height_damage_max = 0.0f;
	float shot_speed = 70.0f;
};

struct Shot {
	float x = 0.0f;
	float y = 0.0f;
	float z = 0.0f;
	float dx = 0.0f;
	float dy = 0.0f;
	float dz = 1.0f;
	float tx = 0.0f; // the last place the target was seen
	float ty = 0.0f;
	float tz = 0.0f;
	float damage = 0.0f;
	float splash = 0.0f;
	int splash_targets = 0;
	int target = 0;
	int tower_id = 0;
	Effects effects;
	float speed = 70.0f;
	// A lobbed stone flies an arc from where it was thrown, over flight seconds, peaking arc metres up.
	bool lob = false;
	float sx = 0.0f;
	float sy = 0.0f;
	float sz = 0.0f;
	float age = 0.0f;
	float flight = 1.0f;
	float arc = 0.0f;
};

class World {
public:
	Settings settings;

	void set_type(int index, const UnitType &type);
	// Types being planned for. The first is the one shown in previews and tower coverage.
	void set_active_types(const std::vector<int> &types);
	// Where enemies set out from, used by previews and tower coverage. Two floats per gate: x, z.
	void set_gates(const std::vector<float> &gates);
	// Heights and the water mask are square grids of src_res values per side. Uses every second one.
	// In the water mask, 1 is water and 2 is mud: a riverbed that has been drained.
	void set_terrain(const float *heights, const uint8_t *water, int src_res, float size, float water_level);
	// Works out the fastest way home from every cell, for each active type.
	void solve(float goal_x, float goal_z, float goal_radius);
	float cost_at(int type, float x, float z) const;
	// Fastest time from each gate using only what the mask allows. Negative means no way through.
	std::vector<float> option_costs(int type, int allow);
	// Fastest time from each gate if the route must pass through this point. Negative means it cannot.
	std::vector<float> via_costs(int type, float x, float z);
	// Four floats per point: x, y, z, and the mode used to leave that point.
	std::vector<float> trace(int type, float x, float z) const;

	int add_tunnel(float ax, float az, float bx, float bz);
	void remove_tunnel(int id);

	void begin_wave();
	void add_group(int type, float x, float z, int count, float interval, float delay);
	void finish_wave();
	void step(float dt);
	// Each returned buffer holds 20 floats per item, in MultiMesh order. Unused slots are all zero.
	const std::vector<float> &figures() const { return figure_buffer_; }
	const std::vector<float> &boats() const { return boat_buffer_; }
	const std::vector<float> &shots() const { return shot_buffer_; }
	// Lobbed stones, which are drawn with their own mesh.
	const std::vector<float> &stones() const { return stone_buffer_; }
	// Six floats per impact since the last call: x, y, z, radius, tower id, flags (1 fire, 2 slow, 4 lobbed).
	std::vector<float> take_impacts();
	// Seven floats per shot fired since the last call: tower id, start x, y, z, target x, y, z.
	std::vector<float> take_launches();
	// Four floats per enemy killed since the last call: x, y, z, type.
	std::vector<float> take_deaths();
	int kills() const { return kills_; }
	float earned() const { return earned_; }

	int add_tower(const Cone &cone, float damage, float cooldown, float splash, int splash_targets);
	void remove_tower(int id);
	// Sold during preparation. Keep the original tower until the sale is undone or committed.
	void set_tower_parked(int id, bool parked);
	float tower_timer(int id) const;
	void restore_tower_timer(int id, float timer);
	void set_tower_aim(int id, float dx, float dy, float dz);
	int tower_kills(int id) const;
	// STAT_COUNT floats: half angle in radians, range, damage, cooldown, splash radius, splash targets,
	// range per metre of height, most range from height, slow, slow seconds, knock climbers (0 or 1),
	// fire seconds, fire radius, fire damage per second, min range, lob (0 or 1),
	// damage per metre of height, most damage from height, shot speed.
	static const int STAT_COUNT = 19;
	void set_tower_stats(int id, const std::vector<float> &stats);
	// The cone versions below for a tower not built yet: the apex and aim of at, with every stat of a spec.
	std::vector<uint8_t> stats_visibility(const Cone &at, const std::vector<float> &stats) const;
	float stats_covered(const Cone &at, const std::vector<float> &stats) const;
	std::vector<float> stats_best_aim(const Cone &at, const std::vector<float> &stats) const;
	// The same as the cone versions below, using the tower's own cone with all its upgrades.
	std::vector<uint8_t> tower_visibility(int id) const;
	float tower_covered(int id) const;
	std::vector<float> tower_best_aim(int id) const;
	// Five floats per burning patch: x, y, z, radius, and how much of its time is left (1 to 0).
	std::vector<float> fires() const;
	// One byte per grid cell: 255 where the gun has a clear line to that cell, else 0.
	// Covers slightly more than the cone, so the display blends cleanly at its edge.
	std::vector<uint8_t> visibility_map(const Cone &cone) const;
	// Metres of the routes from all gates that this cone can hit.
	float covered_length(const Cone &cone) const;
	// The direction that covers the most route from this apex, or empty if none can be seen.
	std::vector<float> best_aim(const Cone &cone) const;
	// Seven floats per started or finished bridge: start xyz, end xyz, progress.
	std::vector<float> bridge_state() const;
	void forget_bridges();
	int arrived() const { return arrived_; }
	/// How many of each type reached home this wave, indexed by type.
	const std::vector<float> &arrived_types() const { return arrived_types_; }
	int active() const { return active_; }
	int bridge_candidates() const { return static_cast<int>(bridges_.size()); }

private:
	struct Link {
		int from;
		int via; // bridge index, or -2 - tunnel index
	};
	struct Field {
		std::vector<float> cost;
		std::vector<int> next;
		std::vector<int> via;
		std::vector<uint8_t> mode;
	};
	struct Unit {
		int type = 0;
		int cell = 0;
		int to = -1;
		int via = -1;
		float t = 0.0f;
		float edge_time = 1.0f;
		float delay = 0.0f;
		float offset_x = 0.0f;
		float offset_z = 0.0f;
		float hp = 100.0f;
		float max_hp = 100.0f;
		float flash = 0.0f;
		uint8_t mode = MODE_WALK;
		float slow = 0.0f;
		float slow_left = 0.0f;
		float stun = 0.0f; // seconds left lying stunned after being knocked off a climb
		int climb_from = -1; // the cell where the current climb began
		bool waiting = false;
		bool done = false;
	};

	int res_ = 0;
	float cell_ = 1.0f;
	float half_ = 0.0f;
	float water_level_ = 0.0f;
	float goal_x_ = 0.0f;
	float goal_z_ = 0.0f;
	float goal_radius_ = 0.0f;
	std::vector<uint8_t> goal_mask_;
	std::vector<float> height_;
	std::vector<uint8_t> wet_;
	std::vector<uint8_t> mud_;
	std::vector<UnitType> types_;
	std::vector<int> active_types_;
	std::vector<Field> fields_;
	Field scratch_;
	std::vector<float> gates_;
	std::vector<Bridge> bridges_;
	std::vector<Tunnel> tunnels_;
	int next_tunnel_id_ = 1;
	std::vector<int> link_start_;
	std::vector<Link> links_;
	std::vector<Unit> units_;
	std::vector<float> figure_buffer_;
	std::vector<float> boat_buffer_;
	std::vector<float> shot_buffer_;
	std::vector<float> stone_buffer_;
	std::vector<float> impacts_;
	std::vector<float> launches_;
	std::vector<float> deaths_;
	std::vector<std::pair<float, int>> blast_hits_;
	std::vector<Tower> towers_;
	std::vector<Tower> parked_towers_;
	std::vector<Shot> shots_;
	std::vector<Fire> fires_;
	int next_tower_id_ = 1;
	int arrived_ = 0;
	std::vector<float> arrived_types_;
	int active_ = 0;
	int kills_ = 0;
	float earned_ = 0.0f;
	uint32_t seed_ = 12345u;

	int cell_at(float x, float z) const;
	float world_x(int cell) const { return -half_ + static_cast<float>(cell % res_) * cell_; }
	float world_z(int cell) const { return -half_ + static_cast<float>(cell / res_) * cell_; }
	float surface(int cell) const;
	bool is_goal(int cell) const { return goal_mask_[cell] != 0; }
	int display_type() const { return active_types_.empty() ? 0 : active_types_[0]; }
	float edge_cost(const UnitType &type, int a, int b, float flat_distance, uint8_t &mode) const;
	float bridge_cost(const UnitType &type, const Bridge &bridge) const;
	float tunnel_time(const UnitType &type, const Tunnel &tunnel) const;
	void search(const UnitType &type, int allow, Field &field);
	void solve_active();
	void find_bridges();
	void build_links();
	void pick_edge(Unit &unit);
	void tick(float dt);
	void tick_towers(float dt);
	void tick_shots(float dt);
	void explode(const Shot &shot);
	void tick_fires(float dt);
	void damage_unit(Unit &unit, float damage, int tower_id, bool flash = true);
	void apply_effects(Unit &unit, const Effects &effects);
	const Tower *find_tower(int id) const;
	bool in_tunnel(const Unit &unit) const { return unit.mode == MODE_TUNNEL && !unit.waiting && unit.via <= -2; }
	// Under water from one wet cell to the next, so only the step in or out shows above the surface.
	bool submerged(const Unit &unit) const;
	// Out of every tower's reach: inside a tunnel, or a diver under water.
	bool is_hidden(const Unit &unit) const { return in_tunnel(unit) || submerged(unit); }
	void unit_position(const Unit &unit, float &x, float &y, float &z, float &dx, float &dz, bool &on_water) const;
	float ground_height(float x, float z) const;
	bool in_cone(const Cone &cone, float x, float y, float z) const;
	bool clear_sight(const Cone &cone, float x, float y, float z) const;
	void route_stops(std::vector<int> &cells) const;
	void write_buffers();
};

} // namespace pathcore
