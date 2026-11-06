extends Node
## Plays the level's waves against set strategies with no waiting and no drawing, then prints who won.
## Run with: -- --balance=all, or the name of one strategy.
##
## Each strategy is a list of steps: terrain to place, then as many towers as the money allows.
## Towers are bought in rounds. Each round picks the spot and aim that cover the most of the routes
## the enemies will really take, within the area that strategy allows.

const SIM_STEP := 1.0 / 30.0
const MAX_WAVE_SECONDS := 900.0
const GRID_STEP := 9.0
const GameConfig = preload("res://scripts/game_config.gd")
## A thoughtless player: the nearest spot to the zone centre that covers any route at all, not the best one.
var naive := false
## Upgrades from the first wave: fewer towers, each taken along the plan before the next is built.
var upgrade_first := false
const STRATEGIES := {
	"a_no_terrain_split": {"goal": "any", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true},
	"b_block_west": {"goal": "win", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, 10.0, 75.0]], "late_zones": [[-85.0, 85.0, 40.0]]},
	"c_seal_both": {"goal": "lose", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}, {"preset": "ridge", "x": 112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, -50.0, 50.0], [-112.0, -50.0, 50.0]], "alternate": true},
	"c2_seal_both_guard_mountain": {"goal": "lose", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}, {"preset": "ridge", "x": 112.0, "z": -15.0, "yaw": 0.0}], "zones": [[0.0, -75.0, 45.0], [0.0, 75.0, 40.0]]},
	"d_tunnel": {"goal": "win", "terrain": [{"tunnel": [16.0, -108.0, 0.0, 88.0]}], "zones": [[0.0, 82.0, 30.0]]},
	"e_towers_one_road": {"goal": "lose", "terrain": [], "zones": [[112.0, 0.0, 70.0]]},
	"f_towers_at_home": {"goal": "lose", "terrain": [], "zones": [[0.0, 90.0, 50.0]]},
	"g_towers_at_spur": {"goal": "lose", "terrain": [], "zones": [[0.0, -112.0, 30.0]]},
	# The same two tests with every tower taken to one final form: splitting must still lose, walling off one road must still win.
	"h_split_fan": {"goal": "any", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "plan": ["scatter", "fan"]},
	"h_split_blaze": {"goal": "any", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "plan": ["scatter", "blaze"]},
	"h_split_lofty": {"goal": "any", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "plan": ["heavy", "lofty"]},
	"h_split_quake": {"goal": "any", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "plan": ["heavy", "quake"]},
	"i_block_fan": {"goal": "win", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, 10.0, 75.0]], "late_zones": [[-85.0, 85.0, 40.0]], "plan": ["scatter", "fan"]},
	"i_block_blaze": {"goal": "win", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, 10.0, 75.0]], "late_zones": [[-85.0, 85.0, 40.0]], "plan": ["scatter", "blaze"]},
	"i_block_lofty": {"goal": "win", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, 10.0, 75.0]], "late_zones": [[-85.0, 85.0, 40.0]], "plan": ["heavy", "lofty"]},
	"i_block_quake": {"goal": "win", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, 10.0, 75.0]], "late_zones": [[-85.0, 85.0, 40.0]], "plan": ["heavy", "quake"]},
	# The other tower types alone. Splitting must still lose with them, as with the cannon.
	"j_split_catapult": {"goal": "any", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "tower": "catapult"},
	"j_split_sniper": {"goal": "any", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "tower": "sniper"},
	# The sniper only hits one at a time, so packing enemies together does not help it: on its own it is meant to lose.
	"k_block_catapult": {"goal": "win", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, 10.0, 75.0]], "late_zones": [[-85.0, 85.0, 40.0]], "tower": "catapult"},
	"k_block_sniper": {"goal": "lose", "terrain": [{"preset": "ridge", "x": -112.0, "z": -15.0, "yaw": 0.0}], "zones": [[112.0, 10.0, 75.0]], "late_zones": [[-85.0, 85.0, 40.0]], "tower": "sniper"},
	# Thoughtless placement: each tower on the nearest free spot to the middle of a road, alternating
	# roads, with the automatic aim. This must lose with every tower type. Split towers placed for the
	# most coverage (a_, h_, j_) may win or lose: a well-judged split is allowed to win.
	"n_naive_cannon": {"goal": "lose", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "naive": true},
	"n_naive_catapult": {"goal": "lose", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "naive": true, "tower": "catapult"},
	"n_naive_sniper": {"goal": "lose", "terrain": [], "zones": [[-112.0, 0.0, 70.0], [112.0, 0.0, 70.0]], "alternate": true, "naive": true, "tower": "sniper"},
}

## Level 1 uses the strategies above. Other levels bring their own in data/levels/<id>_balance.json.
var strategies: Dictionary = STRATEGIES
var main: Node3D
var paths: Node
var towers: Node
var tools: Node
var brush: Node
var terrain


func run(main_node: Node3D, which: String) -> void:
	main = main_node
	paths = main.paths
	towers = main.towers
	tools = main.tools
	brush = main.brush
	terrain = main.terrain
	paths.set_process(false)
	towers.set_process(false)
	var own := "levels/%s_balance.json" % main.level_id
	if FileAccess.file_exists(GameConfig.DATA_DIR + own):
		strategies = GameConfig.load_json(own)["strategies"]
	await get_tree().process_frame
	var names: Array = strategies.keys()
	if which != "" and which != "all":
		names = [which]
	var heights: PackedFloat32Array = terrain.heights.duplicate()
	var water: PackedByteArray = terrain.water_mask.duplicate()
	# --gold=N tries another starting purse without editing the level file.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gold="):
			brush.money = float(arg.trim_prefix("--gold="))
	var start_money: float = brush.money
	var correct := 0
	for strategy_name: String in names:
		var result: Dictionary = await _play(strategy_name, strategies[strategy_name], start_money)
		var want := _wanted_stars(strategies[strategy_name])
		var stars := GameConfig.stars_for(int(result["home"]), paths.home_hp_max) if result["outcome"] == "win" else 0
		var ok: bool = stars >= want.x and stars <= want.y
		var expected := ("%d" % want.x if want.x == want.y else "%d-%d" % [want.x, want.y]) + " stars"
		correct += 1 if ok else 0
		var spots: PackedStringArray = []
		for tower: Dictionary in towers.towers:
			var apex: Vector3 = tower["apex"]
			spots.append("%d,%d,%d" % [int(apex.x), int(apex.z), int(apex.y)])
		print("BALANCE %s towers at %s" % [strategy_name, " ".join(spots)])
		print("BALANCE %s %s: %s, %d stars (want %s); towers %d; home %d/%d; left gold %d; route %s; %s" % [
			"ok  " if ok else "MISS", strategy_name, result["outcome"], stars, expected, result["towers"], result["home"], paths.home_hp_max, result["gold"], result["route"], result["waves"],
		])
		_reset(heights, water, start_money)
	print("BALANCE %d of %d strategies end as designed" % [correct, names.size()])
	get_tree().quit()


## The stars a strategy should end with, as (lowest, highest). "stars" is a number or [low, high];
## without it, "goal" decides: "lose" is none, "win" is one to three, "any" is anything.
func _wanted_stars(strategy: Dictionary) -> Vector2i:
	if strategy.has("stars"):
		var stars = strategy["stars"]
		if stars is Array:
			return Vector2i(int(stars[0]), int(stars[1]))
		return Vector2i(int(stars), int(stars))
	match String(strategy.get("goal", "any")):
		"lose":
			return Vector2i(0, 0)
		"win":
			return Vector2i(1, 3)
	return Vector2i(0, 3)


func _reset(heights: PackedFloat32Array, water: PackedByteArray, money: float) -> void:
	for tower: Dictionary in towers.towers.duplicate():
		paths.core.remove_tower(tower["id"])
		tower["node"].queue_free()
		towers.towers.erase(tower)
	for tunnel: Dictionary in tools.tunnels.duplicate():
		tools._remove_tunnel(tunnel)
	terrain.heights = heights.duplicate()
	terrain.water_mask = water.duplicate()
	terrain._refresh_rect(0, 0, terrain.RES - 1, terrain.RES - 1)
	terrain.refresh_water()
	brush.money = money
	brush.locked = false
	towers.place_type = "normal"
	paths.home_hp = paths.home_hp_max
	paths.wave = 0
	paths.planned_wave = -1
	paths.outcome = ""
	paths.phase = paths.Phase.BUILD
	paths.core.forget_bridges()
	paths.replan()


func _play(strategy_name: String, strategy: Dictionary, start_money: float) -> Dictionary:
	naive = strategy.get("naive", false)
	upgrade_first = strategy.get("upgrade_first", false)
	towers.place_type = strategy.get("tower", "normal")
	for step: Dictionary in strategy["terrain"]:
		_apply_terrain(step, strategy_name)
	paths.replan()
	var waves_text: PackedStringArray = []
	var alternate: bool = strategy.get("alternate", false)
	var route_text := _route_text()
	while paths.outcome == "":
		# Climbers do not care about walls, so by the last wave a careful player guards their way too.
		var late: bool = strategy.has("late_zones") and paths.wave + 1 >= paths.total_waves()
		if late:
			_watch_type("climber")
		_buy_towers(strategy["late_zones"] if late else strategy["zones"], alternate, strategy.get("plan", []))
		var numbers := _run_wave()
		waves_text.append("w%d kills %d arrived %d%s" % [paths.wave, numbers["kills"], numbers["arrived"], numbers["who"]])
		if paths.home_hp <= 0:
			paths.outcome = "lost"
		elif paths.next_wave().is_empty():
			paths.outcome = "won"
		else:
			paths.phase = paths.Phase.BUILD
			brush.locked = false
			paths.replan()
	return {
		"outcome": "win" if paths.outcome == "won" else "lose", "towers": towers.towers.size(), "home": paths.home_hp,
		"gold": int(brush.money), "route": route_text, "waves": " | ".join(waves_text),
	}


func _route_text() -> String:
	var parts: PackedStringArray = []
	for plan: Dictionary in paths.gate_plans:
		parts.append("%s %s %d" % [plan["name"], plan["label"], int(plan["time"])])
	return ", ".join(parts)


func _apply_terrain(step: Dictionary, strategy_name: String) -> void:
	if step.has("dig") or step.has("raise"):
		_reshape(step, strategy_name)
		return
	if step.has("tunnel"):
		var ends: Array = step["tunnel"]
		var built: bool = tools.build_tunnel(Vector2(ends[0], ends[1]), Vector2(ends[2], ends[3]))
		if not built:
			var why: Dictionary = terrain.plan_tunnel(Vector2(ends[0], ends[1]), Vector2(ends[2], ends[3]), tools.config["tunnel"])
			print("BALANCE %s: tunnel refused: %s" % [strategy_name, why])
		return
	var preset: Dictionary = {}
	for entry: Dictionary in tools.presets:
		if entry["id"] == step["preset"]:
			preset = entry
	# The same fitting the player gets, so a ridge stretches to the hillsides here too.
	var fit: Dictionary = tools.fit_preset(preset, Vector2(step["x"], step["z"]), step["yaw"], true)
	var shape: Dictionary = fit["preset"]
	var at: Vector2 = fit["at"]
	var preview: Dictionary = terrain.preview_preset(shape, at.x, at.y, fit["yaw"])
	var cost: float = float(preview["volume"]) * float(tools.cost_per_cubic_metre)
	if brush.money < cost:
		print("BALANCE %s: cannot afford %s (%d)" % [strategy_name, step["preset"], int(cost)])
		return
	brush.money -= cost
	var patch: Dictionary = terrain.make_preset_patch(shape, at.x, at.y, fit["yaw"])
	terrain.set_patch_progress(patch, 1.0)
	# A ridge across a river is a dam, so the water below it must drain as it does for the player.
	if terrain.water_dirty:
		terrain.refresh_water()
	print("BALANCE %s: %s at (%d, %d) costs %d" % [strategy_name, step["preset"], int(at.x), int(at.y), int(cost)])


## Spends all the money, one tower at a time, on the best spot left in the allowed areas.
## With an upgrade plan, from the second wave on every tower first takes the whole plan before another
## is built, and the money is saved up for the next step rather than spent on a new tower.
func _buy_towers(zones: Array, alternate: bool, plan: Array = []) -> void:
	# Like a player, the first wave is spent on towers. Upgrades come out of what later waves earn.
	if paths.wave == 0 and not upgrade_first:
		plan = []
	if not _buy_upgrades(plan):
		return
	var spec: Dictionary = towers.place_spec()
	var cost: float = spec["cost"]
	var zone_index := 0
	while brush.money >= cost:
		var zone_list: Array = [zones[zone_index % zones.size()]] if alternate else zones
		zone_index += 1
		var best := _best_spot(zone_list)
		# An area no enemy passes any more gives nothing, so the money goes to the others.
		if best.is_empty() and alternate:
			best = _best_spot(zones)
		if best.is_empty():
			return
		var id: int = towers.add_core_tower(best["apex"], best["aim"], spec)
		towers.towers.append({"id": id, "type": spec["type"], "node": Node.new(), "center": best["center"], "apex": best["apex"], "path": [], "stars": 0, "paid": best["cost"]})
		brush.money -= float(best["cost"])
		if not _buy_upgrades(plan):
			return


## Takes each tower along the plan, in the order they were built. Plan steps are branch ids or "star".
## Returns true once every tower has the whole plan, false if the money ran out first.
func _buy_upgrades(plan: Array) -> bool:
	for tower: Dictionary in towers.towers:
		while int(tower["path"].size()) + int(tower["stars"]) < plan.size():
			var wanted: String = plan[tower["path"].size() + tower["stars"]]
			var option := {}
			for entry: Dictionary in towers.next_upgrades(tower):
				if entry["id"] == wanted:
					option = entry
			if option.is_empty():
				break
			if brush.money < float(option["cost"]):
				return false
			brush.money -= float(option["cost"])
			if wanted == "star":
				tower["stars"] = int(tower["stars"]) + 1
			else:
				tower["path"].append(wanted)
			var stats: PackedFloat32Array = towers.stats_for(towers.spec_for(tower["path"], tower["stars"], tower.get("type", "normal")))
			paths.core.set_tower_stats(tower["id"], stats, stats.size())
			# A new cone angle or reach may cover more from another direction.
			var aim: PackedFloat32Array = paths.core.tower_best_aim(tower["id"])
			if aim.size() == 3:
				paths.core.set_tower_aim(tower["id"], aim[0], aim[1], aim[2])
	return true


## The spot in the zones whose tower covers the most route. A tower that hits harder from above also
## counts how far it stands over the lowest ground in the zone, which is roughly where the road runs.
func _best_spot(zones: Array) -> Dictionary:
	var best := {}
	var best_score := 0.0
	var spec: Dictionary = towers.place_spec()
	var stats: PackedFloat32Array = towers.stats_for(spec)
	for zone: Array in zones:
		var low := _lowest_ground(zone)
		var radius: float = zone[2]
		var z: float = zone[1] - radius
		while z <= zone[1] + radius:
			var x: float = zone[0] - radius
			while x <= zone[0] + radius:
				if Vector2(x - zone[0], z - zone[1]).length() <= radius:
					var spot: Dictionary = towers.check_spot(x, z)
					if spot["ok"] and brush.money >= float(spot["cost"]):
						var apex: Vector3 = spot["apex"]
						var aim: PackedFloat32Array = paths.core.stats_best_aim(apex.x, apex.y, apex.z, 0.0, 0.0, 1.0, stats, stats.size())
						if aim.size() == 3:
							var direction := Vector3(aim[0], aim[1], aim[2])
							var covered: float = paths.core.stats_covered(apex.x, apex.y, apex.z, direction.x, direction.y, direction.z, stats, stats.size())
							var hit: float = float(spec["damage"]) + clampf((apex.y - low) * float(spec.get("height_damage", 0.0)), 0.0, float(spec.get("height_damage_max", 0.0)))
							var score := covered * hit
							if naive:
								score = 1.0 / (1.0 + Vector2(x - zone[0], z - zone[1]).length()) if covered > 0.0 else 0.0
							if score > best_score:
								best_score = score
								best = {"center": spot["center"], "apex": apex, "aim": direction, "cost": spot["cost"]}
				x += GRID_STEP
			z += GRID_STEP
	return best


func _run_wave() -> Dictionary:
	var spec: Dictionary = paths.next_wave()
	paths.wave += 1
	paths.phase = paths.Phase.BATTLE
	var core = paths.core
	core.begin_wave()
	for group: Dictionary in spec["groups"]:
		var point: Vector2 = paths._gate_point(group["gate"])
		core.add_group(paths.type_index[group["type"]], point.x, point.y, group["count"], group["interval"], group["delay"])
	core.finish_wave()
	var elapsed := 0.0
	while elapsed < MAX_WAVE_SECONDS:
		core.step(SIM_STEP)
		elapsed += SIM_STEP
		if core.active() == 0:
			break
	var kills: int = core.kills()
	var arrived: int = core.arrived()
	brush.money += core.earned()
	paths.home_hp = maxi(paths.home_hp - arrived, 0)
	# Which types got through, so a strategy that fails shows what beat it.
	var by_type: PackedFloat32Array = core.arrived_types()
	var who: PackedStringArray = []
	for id: String in paths.type_index:
		var index: int = paths.type_index[id]
		if index < by_type.size() and by_type[index] > 0.0:
			who.append("%s %d" % [id, int(by_type[index])])
	return {"kills": kills, "arrived": arrived, "who": " (%s)" % ", ".join(who) if not who.is_empty() else ""}


## Makes tower aiming follow this type's route instead of the most common type's.
func _watch_type(id: String) -> void:
	var types := PackedFloat32Array([float(paths.type_index[id])])
	for type in paths.wave_types:
		if type != paths.type_index[id]:
			types.append(float(type))
	paths.core.set_active_types(types, types.size())
	paths.core.solve(paths.home.x, paths.home.y, paths.goal_radius)


func _lowest_ground(zone: Array) -> float:
	var low := INF
	var radius: float = zone[2]
	var z: float = zone[1] - radius
	while z <= zone[1] + radius:
		var x: float = zone[0] - radius
		while x <= zone[0] + radius:
			low = minf(low, terrain.height_at(x, z))
			x += GRID_STEP
		z += GRID_STEP
	return low


## A round patch dug down to a height ("dig": [x, z, radius, height]) or built up to one ("raise"),
## with a soft rim, at the player's price per cubic metre. Locked ground is left alone.
func _reshape(step: Dictionary, strategy_name: String) -> void:
	var lower := step.has("dig")
	var spec: Array = step["dig"] if lower else step["raise"]
	var at := Vector2(spec[0], spec[1])
	var radius: float = spec[2]
	var level: float = spec[3]
	var half: float = terrain.SIZE * 0.5
	var reach := radius + 4.0
	var i0 := maxi(int((at.x - reach + half) / terrain.step), 0)
	var i1 := mini(int((at.x + reach + half) / terrain.step) + 1, terrain.RES - 1)
	var j0 := maxi(int((at.y - reach + half) / terrain.step), 0)
	var j1 := mini(int((at.y + reach + half) / terrain.step) + 1, terrain.RES - 1)
	var changes := {}
	var volume := 0.0
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var index: int = j * terrain.RES + i
			var p := Vector2(-half + float(i) * terrain.step, -half + float(j) * terrain.step)
			var w: float = (1.0 - smoothstep(radius, reach, p.distance_to(at))) * terrain.edit_mask[index]
			var h: float = terrain.heights[index]
			var target := lerpf(h, level, w)
			var after := minf(h, target) if lower else maxf(h, target)
			if after != h:
				changes[index] = after
				volume += absf(after - h) * terrain.step * terrain.step
	var cost := volume * float(tools.cost_per_cubic_metre)
	if brush.money < cost:
		print("BALANCE %s: cannot afford %s at %s (%d)" % [strategy_name, "dig" if lower else "raise", at, int(cost)])
		return
	brush.money -= cost
	for index: int in changes:
		terrain.heights[index] = changes[index]
	terrain._refresh_rect(i0, j0, i1, j1)
	terrain.refresh_water()
	print("BALANCE %s: %s at %s cost %d" % [strategy_name, "dig" if lower else "raise", at, int(cost)])
