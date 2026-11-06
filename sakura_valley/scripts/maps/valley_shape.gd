extends "res://scripts/maps/map_shape.gd"
## The original sakura valley, with its lake, dug pit and terraces. Used by the sandbox level.

const WATER_LEVEL := 2.0
const LAKE := Vector2(47.0, -6.0)
const PIT := Vector2(0.0, -40.0)
const PIT_RADIUS := 19.0
const HOME_Z := 118.0
## Each terrace: center x, center z, radius x, radius z.
const TERRACES: Array[Vector4] = [
	Vector4(-88.0, 8.0, 15.0, 11.0),
	Vector4(-100.0, -74.0, 13.0, 10.0),
	Vector4(96.0, -82.0, 13.0, 10.0),
]

## Flat height of each terrace, taken from the natural ground so cuts stay modest.
var terrace_levels: Array[float] = []

var _n_large := FastNoiseLite.new()
var _n_mid := FastNoiseLite.new()
var _n_ridge := FastNoiseLite.new()
var _n_edge := FastNoiseLite.new()


func _init() -> void:
	_n_large.seed = 11
	_n_large.frequency = 0.012
	_n_large.fractal_octaves = 3
	_n_mid.seed = 23
	_n_mid.frequency = 0.05
	_n_mid.fractal_octaves = 2
	_n_ridge.seed = 37
	_n_ridge.frequency = 0.016
	_n_ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_n_ridge.fractal_octaves = 4
	_n_edge.seed = 51
	_n_edge.frequency = 0.09
	_n_edge.fractal_octaves = 3
	for spot in TERRACES:
		terrace_levels.append(base_height(spot.x, spot.y) + 0.5)


func path_x(z: float) -> float:
	return 18.0 * sin(z * 0.018) + 8.0 * sin(z * 0.047 + 1.0)


func stream_x(z: float) -> float:
	return 58.0 + 10.0 * sin(z * 0.035) + z * 0.06


func pit_center() -> Vector2:
	return Vector2(path_x(PIT.y), PIT.y)


func home() -> Vector2:
	return Vector2(path_x(HOME_Z), HOME_Z)


func base_height(x: float, z: float) -> float:
	var center := path_x(z) * 0.6
	var d := absf(x - center)
	var r := smoothstep(60.0, 158.0, d)
	var side := 100.0 if x > center else -100.0
	var ridge_h := 64.0 + 22.0 * _n_large.get_noise_2d(side, z * 0.8)
	var h := 5.2 + pow(r, 1.3) * ridge_h
	h += _n_large.get_noise_2d(x, z) * (1.8 + r * 16.0)
	h += _n_mid.get_noise_2d(x, z) * (0.42 + r * 2.6)
	h += (_n_ridge.get_noise_2d(x, z) + 0.2) * r * r * 7.0
	return maxf(h, 3.2)


func sample(x: float, z: float) -> Vector3:
	var h := base_height(x, z)
	var cut := 0.0
	var edge := _n_edge.get_noise_2d(x, z)

	# A hill raised by the player.
	var hill_d := Vector2(x - 34.0, z + 112.0).length()
	if hill_d < 50.0:
		h += 25.0 * exp(-hill_d * hill_d / 430.0) * (1.0 + edge * 0.1)

	# Terraces flattened into the slopes.
	for t in TERRACES.size():
		var tr := TERRACES[t]
		var ex := (x - tr.x) / tr.z
		var ez := (z - tr.y) / tr.w
		var e := sqrt(sqrt(ex * ex * ex * ex + ez * ez * ez * ez))
		if e < 1.7:
			var w := 1.0 - smoothstep(0.92, 1.5 + edge * 0.1, e)
			var before := h
			h = lerpf(h, terrace_levels[t], w)
			# Only the cut face shows earth layers: the flat top stays grassy.
			cut = maxf(cut, (before - h) * smoothstep(0.86, 0.98, e))

	# Flat ground around home.
	var home_c := home()
	var home_d := Vector2(x - home_c.x, (z - home_c.y) * 0.9).length()
	if home_d < 44.0:
		h = lerpf(h, 5.6, 1.0 - smoothstep(24.0, 44.0, home_d))

	# Lake and the stream flowing out of it.
	var lx := (x - LAKE.x) / 38.0
	var lz := (z - LAKE.y) / 31.0
	var le := sqrt(lx * lx + lz * lz) + edge * 0.1 + _n_large.get_noise_2d(x * 1.6, z * 1.6) * 0.24
	if le < 1.4:
		var w := 1.0 - smoothstep(0.42, 1.28, le)
		h = lerpf(h, WATER_LEVEL - 5.5, w)
	if z > 15.0:
		var sd := absf(x - stream_x(z)) + edge * 1.5
		if sd < 15.0:
			var w := (1.0 - smoothstep(3.0, 11.0, sd)) * smoothstep(15.0, 32.0, z)
			h = lerpf(h, WATER_LEVEL - 2.0, w)

	# Winding dirt path.
	var path := 0.0
	if z < HOME_Z:
		path = 1.0 - smoothstep(2.0, 4.3, absf(x - path_x(z)) + edge * 1.4)
		h -= path * 0.16

	# Pit dug through the path.
	var pit_c := pit_center()
	var pd := Vector2(x - pit_c.x, z - pit_c.y).length() / (PIT_RADIUS * (1.0 + edge * 0.16))
	var dig := 0.0
	if pd < 1.05:
		var pit_w := 1.0 - smoothstep(0.66, 1.0, pd)
		dig = pit_w * 11.5 + edge * 1.2 * pit_w
		h -= dig
	return Vector3(h, maxf(maxf(dig, cut), 0.0), path)


func water_seeds() -> Array[Vector2]:
	return [LAKE]


func road_distance(x: float, z: float) -> float:
	return absf(x - path_x(z)) if z < HOME_Z + 12.0 else INF


func keep_clear() -> Array[Vector3]:
	var pit := pit_center()
	var zones: Array[Vector3] = [Vector3(pit.x, pit.y, PIT_RADIUS + 9.0)]
	for t in TERRACES:
		zones.append(Vector3(t.x, t.y, maxf(t.z, t.w) + 8.0))
	return zones


func rock_patches() -> Array[Vector3]:
	var pit := pit_center()
	return [Vector3(pit.x, pit.y, PIT_RADIUS * 0.74)]


func lantern_spots() -> Array[Vector2]:
	return [
		Vector2(path_x(70.0) + 4.6, 70.0), Vector2(path_x(40.0) - 4.6, 40.0), Vector2(path_x(8.0) + 4.6, 8.0),
	]
