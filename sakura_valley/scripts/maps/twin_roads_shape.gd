extends "res://scripts/maps/map_shape.gd"
## A great mountain in the middle, with one road around each side of it. Every number is in the level file.

const WATER_LEVEL := 2.0
const ROAD_HALF_WIDTH := 3.2
const TABLE_MIN_Z := -240.0
const TABLE_STEP := 2.0
const SIDEWAYS_SLOPE := 0.6
const SEARCH_REACH := 30.0
const SEARCH_STEP := 5.0

var ground := 5.2
var mountain: Dictionary
var spur: Dictionary
var corridor_half := 26.0
var ridge_width := 55.0
var ridge_height := 58.0
var home_point := Vector2.ZERO
var goal_distance := 0.0
var road_end_z := 124.0
var pond := {}
var zones: Array[Vector3] = []
var road_table := PackedFloat32Array()

var _n_large := FastNoiseLite.new()
var _n_mid := FastNoiseLite.new()
var _n_ridge := FastNoiseLite.new()
var _n_edge := FastNoiseLite.new()


func setup(config: Dictionary) -> void:
	_n_large.seed = 11
	_n_large.frequency = 0.012
	_n_large.fractal_octaves = 3
	_n_mid.seed = 23
	_n_mid.frequency = 0.05
	_n_mid.fractal_octaves = 2
	_n_ridge.seed = 37
	_n_ridge.frequency = 0.02
	_n_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_n_ridge.fractal_octaves = 4
	_n_edge.seed = 51
	_n_edge.frequency = 0.09
	_n_edge.fractal_octaves = 3
	ground = config["ground_height"]
	mountain = config["mountain"]
	spur = config["spur"]
	corridor_half = config["corridor_half_width"]
	ridge_width = config["outer_ridge"]["width"]
	ridge_height = config["outer_ridge"]["height"]
	home_point = Vector2(config["home"]["x"], config["home"]["z"])
	goal_distance = config["home"]["goal_radius"]
	road_end_z = config["road_end_z"]
	pond = config.get("pond", {})
	for zone: Dictionary in config.get("no_build_zones", []):
		zones.append(Vector3(zone["x"], zone["z"], zone["radius"]))
	_build_road_table(config["road_points"])


## The road's distance from the middle of the map, looked up by z. Both roads mirror each other.
func _build_road_table(points: Array) -> void:
	var count := int((-2.0 * TABLE_MIN_Z) / TABLE_STEP) + 1
	road_table.resize(count)
	var curve := Curve2D.new()
	for n in points.size():
		var p := Vector2(points[n][0], points[n][1])
		var handle := Vector2.ZERO
		if n > 0 and n < points.size() - 1:
			handle = (Vector2(points[n + 1][0], points[n + 1][1]) - Vector2(points[n - 1][0], points[n - 1][1])) * 0.18
		curve.add_point(p, -handle, handle)
	var baked := curve.get_baked_points()
	var index := 0
	for t in count:
		var z := TABLE_MIN_Z + float(t) * TABLE_STEP
		while index < baked.size() - 2 and baked[index + 1].y < z:
			index += 1
		var a := baked[index]
		var b := baked[index + 1]
		var along := clampf((z - a.y) / maxf(b.y - a.y, 0.001), 0.0, 1.0)
		road_table[t] = lerpf(a.x, b.x, along)


func road_x(z: float) -> float:
	var f := clampf((z - TABLE_MIN_Z) / TABLE_STEP, 0.0, float(road_table.size()) - 1.001)
	var i := int(f)
	return lerpf(road_table[i], road_table[i + 1], f - float(i))


func base_height(x: float, z: float) -> float:
	var ax := absf(x)
	var road := road_x(z)
	var outer := smoothstep(0.0, ridge_width, ax - road - corridor_half)
	var h := ground
	h += _n_large.get_noise_2d(x, z) * (1.0 + outer * 12.0)
	h += _n_mid.get_noise_2d(x, z) * (0.3 + outer * 2.2)
	h += pow(outer, 1.3) * ridge_height * (1.0 + _n_large.get_noise_2d(x * 0.5, z * 0.5) * 0.4)

	# The mountain: wide skirts, steep shoulders and a broken summit.
	var mx := (x - float(mountain["x"])) / float(mountain["radius_x"])
	var mz := (z - float(mountain["z"])) / float(mountain["radius_z"])
	var wobble := _n_large.get_noise_2d(x * 1.7, z * 1.7) * 0.16
	var reach := sqrt(mx * mx + mz * mz) + wobble
	if reach < 1.2:
		var body := 1.0 - smoothstep(0.2, 1.15, reach)
		h += pow(body, 1.15) * float(mountain["height"])
		h += (_n_ridge.get_noise_2d(x, z) + 0.15) * body * 13.0
		h += _n_mid.get_noise_2d(x, z) * body * 2.5

	# A low spur between the two gates, so no single spot looks down both roads.
	if z < float(spur["from_z"]) + 30.0 and z > float(spur["to_z"]) - 25.0:
		var along := clampf(z, float(spur["to_z"]), float(spur["from_z"]))
		var d := Vector2(x, z - along).length() + _n_edge.get_noise_2d(x, z) * 3.0
		var half: float = spur["half_width"]
		var w := 1.0 - smoothstep(half * 0.4, half * 2.2, d)
		h = maxf(h, ground + float(spur["height"]) * w * smoothstep(float(spur["to_z"]) - 20.0, float(spur["to_z"]) + 5.0, z))

	# The floor of each corridor stays close to level, so roads stay walkable.
	var near := 1.0 - smoothstep(9.0, 22.0, road_distance_raw(ax, z))
	h = lerpf(h, ground + (h - ground) * 0.08, near)
	return maxf(h, ground - 2.0)


func road_distance_raw(ax: float, z: float) -> float:
	var slope := (road_x(z + 2.0) - road_x(z - 2.0)) / 4.0
	if absf(slope) < SIDEWAYS_SLOPE:
		return absf(ax - road_x(z)) / sqrt(1.0 + slope * slope)
	# Where the road runs sideways the quick estimate is far too small, so measure along the road itself.
	var best := INF
	var from := Vector2(road_x(z - SEARCH_REACH), -SEARCH_REACH)
	var dz := -SEARCH_REACH + SEARCH_STEP
	while dz <= SEARCH_REACH:
		var to := Vector2(road_x(z + dz), dz)
		var along := to - from
		var t := clampf((Vector2(ax, 0.0) - from).dot(along) / along.length_squared(), 0.0, 1.0)
		best = minf(best, Vector2(ax, 0.0).distance_squared_to(from + along * t))
		from = to
		dz += SEARCH_STEP
	return sqrt(best)


func sample(x: float, z: float) -> Vector3:
	var h := base_height(x, z)
	var edge := _n_edge.get_noise_2d(x, z)

	# Flat ground around home.
	var home_d := Vector2(x - home_point.x, (z - home_point.y) * 0.9).length()
	if home_d < 56.0:
		h = lerpf(h, ground + 0.4, 1.0 - smoothstep(36.0, 56.0, home_d))

	if not pond.is_empty():
		var lx := (x - float(pond["x"])) / float(pond["radius_x"])
		var lz := (z - float(pond["z"])) / float(pond["radius_z"])
		var le := sqrt(lx * lx + lz * lz) + edge * 0.12
		if le < 1.5:
			h = lerpf(h, WATER_LEVEL - 5.0, 1.0 - smoothstep(0.45, 1.3, le))

	var path := 0.0
	if z < road_end_z:
		path = 1.0 - smoothstep(ROAD_HALF_WIDTH * 0.6, ROAD_HALF_WIDTH * 1.35, road_distance_raw(absf(x), z) + edge * 1.4)
		path *= smoothstep(0.0, 6.0, road_end_z - z)
		h -= path * 0.16
	return Vector3(h, 0.0, path)


func home() -> Vector2:
	return home_point


func goal_radius() -> float:
	return goal_distance


func water_seeds() -> Array[Vector2]:
	if pond.is_empty():
		return []
	return [Vector2(pond["x"], pond["z"])]


func road_distance(x: float, z: float) -> float:
	return road_distance_raw(absf(x), z) if z < road_end_z + 6.0 else INF


func keep_clear() -> Array[Vector3]:
	return zones


func no_build_zones() -> Array[Vector3]:
	return zones


func rock_patches() -> Array[Vector3]:
	return [Vector3(0.0, -5.0, 60.0)]


func lantern_spots() -> Array[Vector2]:
	var spots: Array[Vector2] = []
	for z: float in [-60.0, 20.0, 80.0]:
		spots.append(Vector2(road_x(z) + 5.0, z))
		spots.append(Vector2(-road_x(z) - 5.0, z))
	return spots


func describe_route(points: PackedFloat32Array) -> String:
	var total := 0.0
	var count := 0
	for n in range(0, points.size(), 4):
		if int(points[n + 3]) == 6:
			return "穿隧道"
		if absf(points[n + 2] - float(mountain["z"])) < 40.0:
			total += points[n]
			count += 1
	if count == 0:
		return ""
	var average := total / float(count)
	if average < -float(mountain["radius_x"]) * 0.8:
		return "走西路"
	if average > float(mountain["radius_x"]) * 0.8:
		return "走东路"
	return "翻山"
