extends "res://scripts/maps/map_shape.gd"
## A map built from simple landforms listed in the level file, applied one after another.
## data/README.md describes every landform and its numbers.

const WATER_LEVEL := 2.0
const MIN_HEIGHT := WATER_LEVEL - 14.0
const MAX_HEIGHT := 130.0
const MAP_HALF := 160.0
const ROAD_HALF_WIDTH := 3.2

enum Kind { MESA, RIDGE, TRENCH, RAMP, FLAT, HILL, LAKE, RING }
enum Op { MAX, MIN, SET, ADD }


## One landform, with everything it needs read out of the level file once.
class Feature:
	var kind := 0
	var op := 0
	var box := Rect2()
	var center := Vector2.ZERO
	var rx := 1.0
	var rz := 1.0
	var cos_yaw := 1.0
	var sin_yaw := 0.0
	var radius := 1.0
	var half := 1.0
	var edge := 4.0
	var rough := 0.0
	var bumps := 0.0
	var target := 0.0
	var height := 0.0
	var relative := false
	var points := PackedVector2Array()
	var levels := PackedFloat32Array()
	var gaps: Array[Vector2] = []


var ground := 6.0
var noise_amp := 1.5
var detail := 0.35
var rim_height := 0.0
var rim_width := 40.0
var rim_openings: Array[Vector3] = []
var outside_void := false
var void_floor := MIN_HEIGHT
var void_level := -1000.0
var home_point := Vector2.ZERO
var home_height := 6.4
var goal_distance := 30.0
var features: Array[Feature] = []
var roads: Array[PackedVector2Array] = []
var road_boxes: Array[Rect2] = []
var seeds: Array[Vector2] = []
var zones: Array[Vector3] = []
var clear_zones: Array[Vector3] = []
var rocks: Array[Vector3] = []
var labels: Array[Dictionary] = []

var _n_large := FastNoiseLite.new()
var _n_mid := FastNoiseLite.new()
var _n_edge := FastNoiseLite.new()


func setup(config: Dictionary) -> void:
	_n_large.seed = int(config.get("seed", 11))
	_n_large.frequency = 0.012
	_n_large.fractal_octaves = 3
	_n_mid.seed = _n_large.seed + 12
	_n_mid.frequency = 0.05
	_n_mid.fractal_octaves = 2
	_n_edge.seed = _n_large.seed + 40
	_n_edge.frequency = 0.07
	_n_edge.fractal_octaves = 3
	ground = config.get("ground", 6.0)
	noise_amp = config.get("noise", 1.5)
	detail = config.get("detail", 0.35)
	outside_void = config.get("outside", "hills") == "void"
	void_floor = config.get("void_floor", MIN_HEIGHT)
	void_level = config.get("void_level", -1000.0)
	var rim: Dictionary = config.get("rim", {})
	rim_height = rim.get("height", 0.0)
	rim_width = rim.get("width", 40.0)
	for opening: Array in rim.get("openings", []):
		rim_openings.append(Vector3(opening[0], opening[1], opening[2]))
	var home_config: Dictionary = config["home"]
	home_point = Vector2(home_config["x"], home_config["z"])
	goal_distance = home_config.get("goal_radius", 30.0)
	home_height = home_config.get("height", ground + 0.4)
	for item: Dictionary in config.get("features", []):
		features.append(_read_feature(item))
	for road: Dictionary in config.get("roads", []):
		var points := _points(road["points"])
		roads.append(points)
		road_boxes.append(_box_of(points, 24.0))
	for spot: Array in config.get("water_seeds", []):
		seeds.append(Vector2(spot[0], spot[1]))
	for zone: Dictionary in config.get("no_build_zones", []):
		zones.append(Vector3(zone["x"], zone["z"], zone["radius"]))
	clear_zones.assign(zones)
	for zone: Array in config.get("keep_clear", []):
		clear_zones.append(Vector3(zone[0], zone[1], zone[2]))
	for patch: Array in config.get("rocks", []):
		rocks.append(Vector3(patch[0], patch[1], patch[2]))
	for label: Dictionary in config.get("route_labels", []):
		labels.append(label)


func _read_feature(item: Dictionary) -> Feature:
	var f := Feature.new()
	f.kind = Kind.get(String(item["type"]).to_upper(), Kind.MESA)
	var default_op := {Kind.TRENCH: Op.MIN, Kind.LAKE: Op.MIN, Kind.RAMP: Op.SET, Kind.FLAT: Op.SET, Kind.HILL: Op.ADD}
	f.op = Op.get(String(item.get("op", "")).to_upper(), default_op.get(f.kind, Op.MAX))
	f.edge = maxf(float(item.get("edge", 6.0)), 0.5)
	f.rough = item.get("rough", 0.0)
	f.bumps = item.get("bumps", 0.0)
	f.relative = not item.has("top") and not item.has("bottom") and f.kind != Kind.RAMP
	f.target = float(item.get("top", item.get("bottom", 0.0)))
	f.height = item.get("height", item.get("depth", 0.0))
	if item.has("x"):
		f.center = Vector2(item["x"], item["z"])
	f.radius = item.get("radius", 10.0)
	f.rx = item.get("rx", f.radius)
	f.rz = item.get("rz", f.radius)
	var yaw := deg_to_rad(float(item.get("yaw", 0.0)))
	f.cos_yaw = cos(yaw)
	f.sin_yaw = sin(yaw)
	f.half = float(item.get("width", 10.0)) * 0.5
	var reach := f.edge + f.rough + 2.0
	match f.kind:
		Kind.RIDGE, Kind.TRENCH, Kind.RAMP:
			f.points = _points(item["points"])
			for level in item.get("levels", []):
				f.levels.append(float(level))
			f.box = _box_of(f.points, f.half + reach)
		Kind.RING:
			for gap: Array in item.get("gaps", []):
				f.gaps.append(Vector2(deg_to_rad(float(gap[0])), float(gap[1])))
			var outer := f.radius + f.half + reach
			f.box = Rect2(f.center - Vector2.ONE * outer, Vector2.ONE * outer * 2.0)
		_:
			var outer := maxf(f.rx, f.rz) + reach
			f.box = Rect2(f.center - Vector2.ONE * outer, Vector2.ONE * outer * 2.0)
	if f.kind == Kind.LAKE or (f.kind == Kind.TRENCH and item.get("water", false)):
		seeds.append(f.center if f.kind == Kind.LAKE else f.points[0])
	return f


static func _points(list: Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	for p: Array in list:
		points.append(Vector2(p[0], p[1]))
	return points


static func _box_of(points: PackedVector2Array, margin: float) -> Rect2:
	var box := Rect2(points[0], Vector2.ZERO)
	for p in points:
		box = box.expand(p)
	return box.grow(margin)


## Distance to a polyline, and where along it the nearest point lies: segment index plus the share of it.
static func _polyline(points: PackedVector2Array, p: Vector2) -> Vector2:
	var best := INF
	var along := 0.0
	for n in points.size() - 1:
		var a := points[n]
		var ab := points[n + 1] - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var d := p.distance_squared_to(a + ab * t)
		if d < best:
			best = d
			along = float(n) + t
	return Vector2(sqrt(best), along)


## How strongly a landform applies at a point (0 to 1), and the height it pulls toward.
func _apply(f: Feature, x: float, z: float, h: float) -> float:
	var p := Vector2(x, z)
	var wobble := _n_edge.get_noise_2d(x, z) * f.rough if f.rough > 0.0 else 0.0
	var w := 0.0
	var target := f.target
	match f.kind:
		Kind.MESA, Kind.LAKE:
			var d := p - f.center
			var lx := (d.x * f.cos_yaw - d.y * f.sin_yaw) / f.rx
			var lz := (d.x * f.sin_yaw + d.y * f.cos_yaw) / f.rz
			var inside := (1.0 - sqrt(lx * lx + lz * lz)) * minf(f.rx, f.rz) + wobble
			w = smoothstep(0.0, f.edge, inside)
		Kind.FLAT:
			w = 1.0 - smoothstep(f.radius, f.radius + f.edge, p.distance_to(f.center) - wobble)
		Kind.HILL:
			var r := p.distance_to(f.center) / f.radius - wobble / f.radius
			return h + f.height * pow(1.0 - smoothstep(0.0, 1.0, r), 1.4)
		Kind.RIDGE, Kind.TRENCH:
			var hit := _polyline(f.points, p)
			w = 1.0 - smoothstep(f.half, f.half + f.edge, hit.x - wobble)
		Kind.RAMP:
			var hit := _polyline(f.points, p)
			w = 1.0 - smoothstep(f.half, f.half + f.edge, hit.x - wobble)
			var n := mini(int(hit.y), f.levels.size() - 2)
			target = lerpf(f.levels[n], f.levels[n + 1], hit.y - float(n))
		Kind.RING:
			var d := p - f.center
			var across := absf(d.length() - f.radius)
			w = 1.0 - smoothstep(f.half, f.half + f.edge, across - wobble)
			var angle := atan2(d.y, d.x)
			for gap in f.gaps:
				var arc := absf(angle_difference(angle, gap.x)) * f.radius
				w *= smoothstep(gap.y, gap.y + f.edge, arc)
	if w <= 0.0:
		return h
	if f.relative:
		target = ground + f.height if f.op != Op.MIN else ground - f.height
	if f.bumps > 0.0:
		target += _n_mid.get_noise_2d(x * 0.7, z * 0.7) * f.bumps
	var v := lerpf(h, target, w)
	match f.op:
		Op.MAX:
			return maxf(h, v)
		Op.MIN:
			return minf(h, v)
		Op.ADD:
			return h + (target - ground) * w
	return v


func base_height(x: float, z: float) -> float:
	var h: float
	if outside_void:
		h = void_floor + _n_large.get_noise_2d(x, z) * 0.8
	else:
		h = ground + _n_large.get_noise_2d(x, z) * noise_amp
	if rim_height > 0.0:
		var inset := maxf(absf(x), absf(z)) - (MAP_HALF - rim_width)
		var rise := smoothstep(0.0, rim_width, inset + _n_edge.get_noise_2d(x, z) * 6.0)
		for opening in rim_openings:
			rise *= smoothstep(opening.z, opening.z + 18.0, Vector2(x - opening.x, z - opening.y).length())
		h = maxf(h, h + rim_height * rise * (1.0 + _n_large.get_noise_2d(x * 0.5, z * 0.5) * 0.4))
	var p := Vector2(x, z)
	for f in features:
		if f.box.has_point(p):
			h = _apply(f, x, z, h)
	return h


func road_distance_raw(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var best := INF
	for n in roads.size():
		if road_boxes[n].has_point(p):
			best = minf(best, _polyline(roads[n], p).x)
	return best


func sample(x: float, z: float) -> Vector3:
	var h := base_height(x, z)
	var edge := _n_edge.get_noise_2d(x, z)
	if h > void_floor + 3.0 or not outside_void:
		h += _n_mid.get_noise_2d(x, z) * detail
	# Flat ground around home, so the village sits level. It never builds land out over open sky.
	var home_d := Vector2(x - home_point.x, (z - home_point.y) * 0.9).length()
	if home_d < 56.0 and h > void_level + 4.0:
		h = lerpf(h, home_height, 1.0 - smoothstep(34.0, 54.0, home_d))
	var path := 0.0
	var road := road_distance_raw(x, z)
	if road < 12.0:
		path = 1.0 - smoothstep(ROAD_HALF_WIDTH * 0.6, ROAD_HALF_WIDTH * 1.35, road + edge * 1.4)
		h -= path * 0.16
	return Vector3(clampf(h, MIN_HEIGHT, MAX_HEIGHT), 0.0, path)


func path_x(_z: float) -> float:
	return 0.0


func pit_center() -> Vector2:
	return home_point


func home() -> Vector2:
	return home_point


func goal_radius() -> float:
	return goal_distance


func water_seeds() -> Array[Vector2]:
	return seeds


func road_distance(x: float, z: float) -> float:
	return road_distance_raw(x, z)


func keep_clear() -> Array[Vector3]:
	return clear_zones


func no_build_zones() -> Array[Vector3]:
	return zones


func rock_patches() -> Array[Vector3]:
	return rocks


func lantern_spots() -> Array[Vector2]:
	var spots: Array[Vector2] = []
	for road in roads:
		var walked := 0.0
		for n in road.size() - 1:
			var a := road[n]
			var b := road[n + 1]
			var length := a.distance_to(b)
			var t := 70.0 - walked
			while t < length:
				var at := a.lerp(b, t / length)
				var side := (b - a).normalized().orthogonal() * 5.0
				if maxf(absf(at.x), absf(at.y)) < MAP_HALF - 20.0 and at.distance_to(home_point) > 60.0:
					spots.append(at + side)
				t += 70.0
			walked = fmod(walked + length, 70.0)
	return spots


## The first label from the level file whose circle the route passes through.
func describe_route(points: PackedFloat32Array) -> String:
	var boat := 0
	var bridge := 0
	for n in range(0, points.size(), 4):
		var mode := int(points[n + 3])
		if mode == 6:
			return "穿隧道"
		if mode == 2:
			boat += 1
		if mode == 3 or mode == 5:
			bridge += 1
	for label in labels:
		var at := Vector2(label["x"], label["z"])
		var reach: float = label.get("radius", 30.0)
		for n in range(0, points.size(), 4):
			if Vector2(points[n], points[n + 2]).distance_to(at) < reach:
				return label["label"]
	if bridge > 0:
		return "搭桥"
	return "坐船" if boat > 4 else ""
