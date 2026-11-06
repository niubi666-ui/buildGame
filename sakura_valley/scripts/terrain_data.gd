extends RefCounted
## The live heights of the map. Its starting shape comes from a map generator in scripts/maps.

const ValleyShape = preload("res://scripts/maps/valley_shape.gd")
const TwinRoadsShape = preload("res://scripts/maps/twin_roads_shape.gd")
const ComposedShape = preload("res://scripts/maps/composed_shape.gd")

enum { TOOL_RAISE, TOOL_LOWER, TOOL_SMOOTH, TOOL_FLATTEN, TOOL_PINCH, TOOL_SLOPE }

const SIZE := 320.0
const TOWER_LOCK_FULL := 4.5
const TOWER_LOCK_FADE := 4.0
const RES := 513
const WATER_LEVEL := 2.0
const DIG_SCALE := 14.0
const MIN_HEIGHT := WATER_LEVEL - 14.0
const MAX_HEIGHT := 130.0
## A fitted ridge's end counts as closed only where the ground is high along these lines, measured
## across the ridge in widths, so enemies cannot slip round it on a slanting hillside.
const FIT_LINES := [0.0, -0.5, 0.5]
## How far a fitted ridge's full height runs on past the point where the ground got high enough.
const FIT_OVERLAP := 3.0
## Places in the sandbox map, used by the automated tests.
const LAKE := ValleyShape.LAKE
const PIT_RADIUS := ValleyShape.PIT_RADIUS

var shape
var step := SIZE / float(RES - 1)
var heights := PackedFloat32Array()
var digs := PackedFloat32Array()
var paths := PackedFloat32Array()
var normals := PackedVector3Array()
var water_mask := PackedByteArray()
var water_cells := PackedInt32Array()
var start_water_cells := PackedInt32Array()
## When set, water only comes from the level's sources, so a river cut off by a dam dries up below it.
var flowing_water := false
var water_sources := PackedInt32Array()
## Set when an edit moves ground across the water level, so the flood must be recomputed.
var water_dirty := false

## GPU copy of the terrain, four floats per vertex: height, dig depth, normal x, normal z.
var state := PackedFloat32Array()
var state_image: Image
var state_texture: ImageTexture
var state_dirty := false
var start_heights := PackedFloat32Array()
var start_digs := PackedFloat32Array()
## 0 where the ground is locked (buildings, map edges), 1 where it can be sculpted.
var edit_mask := PackedFloat32Array()
## The mask without any tower locks.
var base_edit_mask := PackedFloat32Array()
var brush_detail := PackedFloat32Array()
## The slope that the slope tool is currently pressing the ground toward.
var brush_plane := {}
## Places holding the ground still: towers and tunnel mouths.
var ground_locks: Array[Vector2] = []
## Seconds after the latest flood began that water reaches each point. Zero means it was already there.
var flood_arrival := PackedFloat32Array()
## How fast new water spreads, in metres per second.
var flood_speed := 11.0
## True when the latest refresh of the water let in new water.
var flood_started := false
## Ground below this is open sky on floating levels.
var void_level := -1000.0

var _n_large := FastNoiseLite.new()


func _init() -> void:
	_n_large.seed = 11
	_n_large.frequency = 0.012
	_n_large.fractal_octaves = 3


## Reads a level's "map" section and picks the generator it names.
func setup(map_config: Dictionary) -> void:
	void_level = float(map_config.get("void_level", -1000.0))
	flowing_water = bool(map_config.get("flowing_water", false))
	match String(map_config.get("generator", "valley")):
		"twin_roads":
			shape = TwinRoadsShape.new()
			shape.setup(map_config)
		"composed":
			shape = ComposedShape.new()
			shape.setup(map_config)
		_:
			shape = ValleyShape.new()


func path_x(z: float) -> float:
	return shape.path_x(z)


func pit_center() -> Vector2:
	return shape.pit_center()


func home_center() -> Vector2:
	return shape.home()


## Natural ground, also used for the distant hills outside the playable area.
func base_height(x: float, z: float) -> float:
	return shape.base_height(x, z)


func build() -> void:
	var total := RES * RES
	heights.resize(total)
	digs.resize(total)
	paths.resize(total)
	normals.resize(total)
	var half := SIZE * 0.5
	for j in RES:
		var z := -half + float(j) * step
		for i in RES:
			var point: Vector3 = shape.sample(-half + float(i) * step, z)
			var index := j * RES + i
			heights[index] = point.x
			digs[index] = point.y
			paths[index] = point.z
	_compute_normals()
	var seeds := PackedInt32Array()
	for spot: Vector2 in shape.water_seeds():
		seeds.append(_index_of(spot.x, spot.y))
	_flood_water(seeds)
	water_sources = seeds
	flood_arrival.resize(total)
	flood_arrival.fill(0.0)
	start_heights = heights.duplicate()
	start_digs = digs.duplicate()
	start_water_cells = water_cells.duplicate()
	_build_edit_mask()
	_build_brush_detail()
	_build_state()


func _compute_normals() -> void:
	for j in RES:
		var j0 := maxi(j - 1, 0)
		var j1 := mini(j + 1, RES - 1)
		for i in RES:
			var i0 := maxi(i - 1, 0)
			var i1 := mini(i + 1, RES - 1)
			var dx := heights[j * RES + i1] - heights[j * RES + i0]
			var dz := heights[j1 * RES + i] - heights[j0 * RES + i]
			normals[j * RES + i] = Vector3(-dx, step * float(i1 - i0 + j1 - j0) * 0.5, -dz).normalized()


## Water only fills ground connected to existing water, so the pit stays dry until a channel reaches it.
func _flood_water(seeds: PackedInt32Array) -> void:
	water_mask.resize(RES * RES)
	water_mask.fill(0)
	var stack := PackedInt32Array()
	for s in seeds:
		if heights[s] < WATER_LEVEL and water_mask[s] == 0:
			water_mask[s] = 1
			stack.append(s)
	water_cells = PackedInt32Array()
	while not stack.is_empty():
		var c := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		water_cells.append(c)
		var i := c % RES
		var j := c / RES
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var ni := i + offset.x
			var nj := j + offset.y
			if ni < 0 or nj < 0 or ni >= RES or nj >= RES:
				continue
			var n := nj * RES + ni
			if water_mask[n] == 0 and heights[n] < WATER_LEVEL:
				water_mask[n] = 1
				stack.append(n)


## The water mask as the route planner reads it: 1 for water, and 2 for mud, where water
## stood at the start but has drained away while the ground is still below the water line.
func route_water_mask() -> PackedByteArray:
	var mask := water_mask.duplicate()
	for c in start_water_cells:
		if mask[c] == 0 and heights[c] < WATER_LEVEL:
			mask[c] = 2
	return mask


## The original lake is the only water source, so a basin cut off from it dries up.
func refresh_water() -> void:
	var before := water_mask.duplicate()
	_flood_water(water_sources if flowing_water else start_water_cells)
	_time_the_flood(before)
	water_dirty = false


## Works outward from the old shoreline, so new water visibly spreads instead of appearing at once.
func _time_the_flood(before: PackedByteArray) -> void:
	flood_arrival.fill(0.0)
	flood_started = false
	var front := PackedInt32Array()
	var neighbors: Array[int] = [1, -1, RES, -RES]
	for c in water_cells:
		if before[c] != 0:
			continue
		flood_started = true
		flood_arrival[c] = -1.0
		for offset in neighbors:
			var n := c + offset
			if n >= 0 and n < before.size() and before[n] != 0:
				flood_arrival[c] = 0.01
				front.append(c)
				break
	var per_cell := step / maxf(flood_speed, 0.1)
	var head := 0
	while head < front.size():
		var c := front[head]
		head += 1
		for offset in neighbors:
			var n := c + offset
			if n >= 0 and n < flood_arrival.size() and flood_arrival[n] < 0.0:
				flood_arrival[n] = flood_arrival[c] + per_cell
				front.append(n)
	# New water with no link to the old shore cannot really happen, but must not stay hidden.
	for c in water_cells:
		if flood_arrival[c] < 0.0:
			flood_arrival[c] = 0.01


func _build_edit_mask() -> void:
	edit_mask.resize(RES * RES)
	var half := SIZE * 0.5
	var home := home_center()
	var zones: Array[Vector3] = shape.no_build_zones()
	var areas: Array[Dictionary] = shape.no_build_areas()
	for j in RES:
		var z := -half + float(j) * step
		for i in RES:
			var x := -half + float(i) * step
			var edge := half - maxf(absf(x), absf(z))
			var mask := smoothstep(5.0, 14.0, edge)
			mask = minf(mask, smoothstep(38.0, 50.0, Vector2(x - home.x, (z - home.y) * 0.9).length()))
			for zone in zones:
				mask = minf(mask, smoothstep(zone.z, zone.z + 8.0, Vector2(x - zone.x, z - zone.y).length()))
			for area: Dictionary in areas:
				mask = minf(mask, smoothstep(0.0, 8.0, _outside(area["rect"], Vector2(x, z))))
			edit_mask[j * RES + i] = mask
	base_edit_mask = edit_mask.duplicate()


## How far a point lies outside a rectangle, 0 inside it.
static func _outside(rect: Rect2, p: Vector2) -> float:
	var dx := maxf(maxf(rect.position.x - p.x, p.x - rect.end.x), 0.0)
	var dz := maxf(maxf(rect.position.y - p.y, p.y - rect.end.y), 0.0)
	return Vector2(dx, dz).length()


## Why nothing can be built at a point inside a no-build rectangle, or "" if no rectangle explains it.
func no_build_reason(x: float, z: float) -> String:
	for area: Dictionary in shape.no_build_areas():
		if _outside(area["rect"], Vector2(x, z)) < 8.0:
			return area["reason"]
	return ""


## Fits a flat plane to the ground around a spot: height = c + a * dx + b * dz.
## Samples follow the slope, so the area measured stays the same size even on a steep face.
## Roughness is the largest gap between the ground and the plane, measured across the plane.
func fit_ground_plane(x: float, z: float, radius: float) -> Dictionary:
	var probe := 1.5
	var a := (height_at(x + probe, z) - height_at(x - probe, z)) / (2.0 * probe)
	var b := (height_at(x, z + probe) - height_at(x, z - probe)) / (2.0 * probe)
	var c := height_at(x, z)
	var samples := PackedVector3Array()
	var rings: Array[float] = [radius * 0.34, radius * 0.67, radius]
	for pass_index in 3:
		var slope := Vector2(a, b)
		var steepness := slope.length()
		var along := slope / steepness if steepness > 0.001 else Vector2(1.0, 0.0)
		var across := Vector2(-along.y, along.x)
		var squeeze := maxf(1.0 / sqrt(1.0 + steepness * steepness), 0.12)
		samples.clear()
		samples.append(Vector3(0.0, height_at(x, z), 0.0))
		for ring in rings:
			for n in 12:
				var angle := TAU * float(n) / 12.0
				var u := cos(angle) * ring * squeeze
				var v := sin(angle) * ring
				var dx := along.x * u + across.x * v
				var dz := along.y * u + across.y * v
				samples.append(Vector3(dx, height_at(x + dx, z + dz), dz))
		var sum_h := 0.0
		var sum_xx := 0.0
		var sum_xz := 0.0
		var sum_zz := 0.0
		var sum_xh := 0.0
		var sum_zh := 0.0
		for s in samples:
			sum_h += s.y
			sum_xx += s.x * s.x
			sum_xz += s.x * s.z
			sum_zz += s.z * s.z
			sum_xh += s.x * s.y
			sum_zh += s.z * s.y
		var det := sum_xx * sum_zz - sum_xz * sum_xz
		if absf(det) < 0.0001:
			break
		a = (sum_xh * sum_zz - sum_zh * sum_xz) / det
		b = (sum_zh * sum_xx - sum_xh * sum_xz) / det
		c = sum_h / float(samples.size())
	var scale_y := 1.0 / sqrt(1.0 + a * a + b * b)
	var roughness := 0.0
	var lowest := INF
	for s in samples:
		roughness = maxf(roughness, absf(s.y - (c + a * s.x + b * s.z)) * scale_y)
		lowest = minf(lowest, s.y)
	return {
		"x": x, "z": z, "a": a, "b": b, "c": c, "samples": samples, "lowest": lowest,
		"roughness": roughness, "normal": Vector3(-a, 1.0, -b).normalized(), "center": Vector3(x, c, z),
	}


## Pulls the ground onto the plane under a tower, blending out to the surrounding terrain.
## Returns the changes, so removing the tower can put the ground back.
func shape_tower_pad(plane: Dictionary, inner: float, outer: float) -> Dictionary:
	var half := SIZE * 0.5
	var x: float = plane["x"]
	var z: float = plane["z"]
	var a: float = plane["a"]
	var b: float = plane["b"]
	var c: float = plane["c"]
	var i0 := maxi(int((x - outer + half) / step), 1)
	var i1 := mini(int((x + outer + half) / step) + 1, RES - 2)
	var j0 := maxi(int((z - outer + half) / step), 1)
	var j1 := mini(int((z + outer + half) / step) + 1, RES - 2)
	var indices := PackedInt32Array()
	var deltas := PackedFloat32Array()
	var starts := PackedFloat32Array()
	for j in range(j0, j1 + 1):
		var dz := -half + float(j) * step - z
		for i in range(i0, i1 + 1):
			var dx := -half + float(i) * step - x
			var rise := a * dx + b * dz
			var distance := sqrt(dx * dx + dz * dz + rise * rise)
			if distance >= outer:
				continue
			var index := j * RES + i
			var weight := (1.0 - smoothstep(inner, outer, distance)) * edit_mask[index]
			if weight <= 0.0:
				continue
			var before := heights[index]
			var after := clampf(lerpf(before, c + rise, weight), MIN_HEIGHT, MAX_HEIGHT)
			heights[index] = after
			if heights[index] == before:
				continue
			indices.append(index)
			starts.append(before)
			deltas.append(heights[index] - before)
			if (before < WATER_LEVEL) != (heights[index] < WATER_LEVEL):
				water_dirty = true
	_refresh_rect(maxi(i0 - 1, 0), maxi(j0 - 1, 0), mini(i1 + 1, RES - 1), mini(j1 + 1, RES - 1))
	return {"indices": indices, "starts": starts, "deltas": deltas, "rect": Rect2i(i0, j0, i1 - i0 + 1, j1 - j0 + 1)}


## How far a preset moves the ground at one point. Rise is positive, digging negative.
static func preset_change(preset: Dictionary, u: float, v: float) -> float:
	match String(preset["shape"]):
		"bell":
			var d := sqrt(u * u + v * v) / float(preset["radius"])
			if d >= 1.0:
				return 0.0
			var bell := 1.0 - d * d
			return float(preset["height"]) * bell * bell
		"ridge":
			var width: float = preset["width"]
			var along := maxf(absf(u) - (float(preset["length"]) * 0.5 - width), 0.0)
			var d := sqrt(along * along + v * v) / width
			if d >= 1.0:
				return 0.0
			var bell := 1.0 - d * d
			return float(preset["height"]) * bell * bell
		"box_pit":
			var margin := 4.0
			var qx := absf(u) - float(preset["length"]) * 0.5 + margin
			var qz := absf(v) - float(preset["width"]) * 0.5 + margin
			var outside := sqrt(maxf(qx, 0.0) * maxf(qx, 0.0) + maxf(qz, 0.0) * maxf(qz, 0.0))
			var distance := outside + minf(maxf(qx, qz), 0.0)
			return -float(preset["depth"]) * (1.0 - smoothstep(-1.5, margin, distance))
	return 0.0


static func preset_reach(preset: Dictionary) -> float:
	match String(preset["shape"]):
		"bell":
			return float(preset["radius"])
		"ridge":
			return float(preset["length"]) * 0.5 + 1.0
	return Vector2(preset["length"], preset["width"]).length() * 0.5 + 2.0


## Stretches a ridge along its length until each end reaches natural ground at least as high as its
## top, so it closes a valley even when it is dropped a little off centre. An end that finds no such
## ground keeps the preset's own length and is listed in "open", because enemies can walk round it.
## Gives the fitted preset, where its middle goes, and the open ends as world points.
## Without stretch the ridge keeps the length the player chose, centred on the spot, and only the
## open ends are worked out, so the player can leave a gap on purpose and still see where it is.
func fit_ridge(preset: Dictionary, cx: float, cz: float, yaw: float, stretch := true) -> Dictionary:
	var width: float = preset["width"]
	var axis := Vector2(cos(yaw), sin(yaw))
	var across := Vector2(-axis.y, axis.x)
	var center := Vector2(cx, cz)
	var crest := height_at(cx, cz) + float(preset["height"])
	var own_reach := float(preset["length"]) * 0.5 - width
	var max_reach := float(preset.get("max_length", preset["length"])) * 0.5 - width
	var search := max_reach if stretch else maxf(own_reach, 0.0)
	var reaches: Array[float] = []
	var open: Array[Vector2] = []
	for side: float in [1.0, -1.0]:
		var reach := -1.0
		var limit := search + width * 0.5
		var s := 0.0
		while s <= search:
			var middle := center + axis * (s * side)
			if base_edit_mask[_index_of(middle.x, middle.y)] < 0.5:
				limit = s
				break
			var high := true
			for offset: float in FIT_LINES:
				var p := middle + across * (offset * width)
				if height_at(p.x, p.y) < crest:
					high = false
					break
			if high:
				reach = s
				break
			s += step * 2.0
		if reach < 0.0:
			reach = own_reach
			open.append(center + axis * (side * minf(reach + width * 0.5, limit)))
		reaches.append(reach + FIT_OVERLAP)
	if not stretch:
		return {"preset": preset, "at": center, "open": open}
	var full_half := maxf((reaches[0] + reaches[1]) * 0.5, float(preset.get("min_length", 0.0)) * 0.5 - width)
	var fitted := preset.duplicate()
	fitted["length"] = (full_half + width) * 2.0
	var middle := center + axis * ((reaches[0] - reaches[1]) * 0.5)
	return {"preset": fitted, "at": middle, "open": open}


## A coarse look at what a preset would do here. Four floats per grid point: x, new height, z, change.
## Also gives the volume of earth moved, which sets its price.
func preview_preset(preset: Dictionary, cx: float, cz: float, yaw: float) -> Dictionary:
	var reach := preset_reach(preset)
	var spacing := step * 4.0
	var side := int(reach * 2.0 / spacing) + 2
	var points := PackedFloat32Array()
	points.resize(side * side * 4)
	var cos_yaw := cos(yaw)
	var sin_yaw := sin(yaw)
	var volume := 0.0
	var o := 0
	for j in side:
		var dz := -reach + float(j) * spacing
		for i in side:
			var dx := -reach + float(i) * spacing
			var u := dx * cos_yaw + dz * sin_yaw
			var v := -dx * sin_yaw + dz * cos_yaw
			var x := cx + dx
			var z := cz + dz
			var h := height_at(x, z)
			var change := preset_change(preset, u, v) * edit_mask[_index_of(x, z)]
			var after := clampf(h + change, MIN_HEIGHT, MAX_HEIGHT)
			volume += absf(after - h)
			points[o] = x
			points[o + 1] = after
			points[o + 2] = z
			points[o + 3] = after - h
			o += 4
	return {"points": points, "side": side, "volume": volume * spacing * spacing}


## Works out a preset's change at every grid point, without applying it yet.
func make_preset_patch(preset: Dictionary, cx: float, cz: float, yaw: float) -> Dictionary:
	var half := SIZE * 0.5
	var reach := preset_reach(preset)
	var cos_yaw := cos(yaw)
	var sin_yaw := sin(yaw)
	var i0 := maxi(int((cx - reach + half) / step), 1)
	var i1 := mini(int((cx + reach + half) / step) + 1, RES - 2)
	var j0 := maxi(int((cz - reach + half) / step), 1)
	var j1 := mini(int((cz + reach + half) / step) + 1, RES - 2)
	var indices := PackedInt32Array()
	var deltas := PackedFloat32Array()
	var starts := PackedFloat32Array()
	for j in range(j0, j1 + 1):
		var dz := -half + float(j) * step - cz
		for i in range(i0, i1 + 1):
			var dx := -half + float(i) * step - cx
			var u := dx * cos_yaw + dz * sin_yaw
			var v := -dx * sin_yaw + dz * cos_yaw
			var index := j * RES + i
			var change := preset_change(preset, u, v) * edit_mask[index]
			if absf(change) < 0.001:
				continue
			# Raised ground gets a little of the brush's unevenness, so presets do not look stamped.
			if change > 0.0:
				change *= lerpf(1.0, brush_detail[index], 0.35)
			var before := heights[index]
			var delta := clampf(before + change, MIN_HEIGHT, MAX_HEIGHT) - before
			if delta == 0.0:
				continue
			indices.append(index)
			starts.append(before)
			deltas.append(delta)
	return {"indices": indices, "starts": starts, "deltas": deltas, "rect": Rect2i(i0, j0, i1 - i0 + 1, j1 - j0 + 1)}


## Moves a patch's ground to a fraction of its full change, so hills can rise over time.
func set_patch_progress(patch: Dictionary, progress: float) -> void:
	var indices: PackedInt32Array = patch["indices"]
	var starts: PackedFloat32Array = patch["starts"]
	var deltas: PackedFloat32Array = patch["deltas"]
	for n in indices.size():
		heights[indices[n]] = starts[n] + deltas[n] * progress
	var rect: Rect2i = patch["rect"]
	_refresh_rect(maxi(rect.position.x - 1, 0), maxi(rect.position.y - 1, 0), mini(rect.end.x, RES - 1), mini(rect.end.y, RES - 1))
	if progress >= 1.0:
		for n in indices.size():
			if (starts[n] < WATER_LEVEL) != (heights[indices[n]] < WATER_LEVEL):
				water_dirty = true
				break


## Works out where a tunnel between two clicks would run. Its doors sit where the hillside has
## risen high enough to hold them, so the player only needs to click near the foot of the hill.
func plan_tunnel(a: Vector2, b: Vector2, rules: Dictionary) -> Dictionary:
	var straight := a.distance_to(b)
	if straight < 1.0:
		return {"ok": false, "reason": "请点山的另一侧"}
	var level_a := height_at(a.x, a.y)
	var level_b := height_at(b.x, b.y)
	var rise_needed := 8.0
	var axis := (b - a) / straight
	var door_a := Vector2.INF
	var door_b := Vector2.INF
	var along := 0.0
	while along < straight:
		var p := a + axis * along
		if height_at(p.x, p.y) >= level_a + rise_needed:
			door_a = p
			break
		along += 1.0
	along = 0.0
	while along < straight:
		var p := b - axis * along
		if height_at(p.x, p.y) >= level_b + rise_needed:
			door_b = p
			break
		along += 1.0
	if door_a == Vector2.INF or door_b == Vector2.INF or (door_b - door_a).dot(axis) < float(rules["min_length"]):
		return {"ok": false, "reason": "这条线没有穿过山体，不需要隧道"}
	var length := door_a.distance_to(door_b)
	if length > float(rules["max_length"]):
		return {"ok": false, "reason": "隧道太长：%d 米，上限 %d 米" % [int(length), int(rules["max_length"])]}
	if absf(level_b - level_a) / length > float(rules["max_slope"]):
		return {"ok": false, "reason": "两个入口高差太大：%.0f 米" % absf(level_b - level_a)}
	# Most of the way, there must be solid hill above the tunnel's roof.
	var covered := 0
	var samples := 0
	var distance := 0.0
	while distance <= length:
		var p := door_a + axis * distance
		var line := lerpf(level_a, level_b, distance / length)
		if height_at(p.x, p.y) - line >= float(rules["min_cover"]):
			covered += 1
		samples += 1
		distance += 2.0
	if float(covered) / float(samples) < 0.7:
		return {"ok": false, "reason": "山体不够厚，隧道会露出来"}
	for spot: Vector2 in [a, b]:
		if water_mask[_index_of(spot.x, spot.y)] != 0:
			return {"ok": false, "reason": "入口不能在水里"}
		if base_edit_mask[_index_of(spot.x, spot.y)] <= 0.0:
			return {"ok": false, "reason": "这里不能建造"}
	return {
		"ok": true, "start": a, "finish": b, "door_a": door_a, "door_b": door_b, "level_a": level_a, "level_b": level_b,
		"axis": axis, "length": length,
		"cost": int(float(rules["portal_cost"]) * 2.0 + length * float(rules["cost_per_metre"])),
	}


## Digs the approach to a tunnel door: a level cutting from where the player clicked into the hill.
func cut_tunnel_mouth(mouth: Vector2, door: Vector2, level: float, half_width: float) -> Dictionary:
	var half := SIZE * 0.5
	var run := door - mouth
	var length := run.length()
	var axis := run / maxf(length, 0.01)
	# Bound the cutting and its end and side fades so a long approach refreshes only its strip.
	var reach := run.abs() * 0.5 + Vector2.ONE * (half_width + 3.5 + 6.0)
	var center := (mouth + door) * 0.5
	var i0 := maxi(int((center.x - reach.x + half) / step), 1)
	var i1 := mini(int((center.x + reach.x + half) / step) + 1, RES - 2)
	var j0 := maxi(int((center.y - reach.y + half) / step), 1)
	var j1 := mini(int((center.y + reach.y + half) / step) + 1, RES - 2)
	var indices := PackedInt32Array()
	var deltas := PackedFloat32Array()
	var starts := PackedFloat32Array()
	for j in range(j0, j1 + 1):
		var dz := -half + float(j) * step - mouth.y
		for i in range(i0, i1 + 1):
			var dx := -half + float(i) * step - mouth.x
			var along := dx * axis.x + dz * axis.y
			if along < -6.0 or along > length + 3.0:
				continue
			var across := absf(-dx * axis.y + dz * axis.x)
			var weight := (1.0 - smoothstep(half_width, half_width + 3.5, across)) * (1.0 - smoothstep(length, length + 3.0, along)) * smoothstep(-6.0, 0.0, along)
			if weight <= 0.0:
				continue
			var index := j * RES + i
			var before := heights[index]
			var after := lerpf(before, minf(before, level), weight)
			if after >= before - 0.001:
				continue
			heights[index] = after
			indices.append(index)
			starts.append(before)
			deltas.append(heights[index] - before)
			if (before < WATER_LEVEL) != (heights[index] < WATER_LEVEL):
				water_dirty = true
	_refresh_rect(maxi(i0 - 1, 0), maxi(j0 - 1, 0), mini(i1 + 1, RES - 1), mini(j1 + 1, RES - 1))
	return {"indices": indices, "starts": starts, "deltas": deltas, "rect": Rect2i(i0, j0, i1 - i0 + 1, j1 - j0 + 1)}


## Undoes shape_tower_pad. Changes are subtracted, so other edits nearby are kept.
func remove_tower_pad(patch: Dictionary) -> void:
	apply_ground_patch(patch, -1.0)


## Adds or removes a structure's own height changes, preserving edits made around it since placement.
func apply_ground_patch(patch: Dictionary, direction: float) -> void:
	var indices: PackedInt32Array = patch["indices"]
	var deltas: PackedFloat32Array = patch["deltas"]
	for n in indices.size():
		var before := heights[indices[n]]
		heights[indices[n]] = before + direction * deltas[n]
		if (before < WATER_LEVEL) != (heights[indices[n]] < WATER_LEVEL):
			water_dirty = true
	var rect: Rect2i = patch["rect"]
	_refresh_rect(maxi(rect.position.x - 1, 0), maxi(rect.position.y - 1, 0), mini(rect.end.x, RES - 1), mini(rect.end.y, RES - 1))


func capture_patch_heights(patch: Dictionary) -> PackedFloat32Array:
	var indices: PackedInt32Array = patch["indices"]
	var values := PackedFloat32Array()
	values.resize(indices.size())
	for n in indices.size():
		values[n] = heights[indices[n]]
	return values


## Locks the ground at a tower or tunnel mouth, fading back to editable just past its footing.
func add_ground_lock(x: float, z: float) -> void:
	ground_locks.append(Vector2(x, z))
	_stamp_lock(x, z)


func _stamp_lock(x: float, z: float) -> void:
	var half := SIZE * 0.5
	var reach := TOWER_LOCK_FULL + TOWER_LOCK_FADE + 1.0
	for j in range(maxi(int((z - reach + half) / step), 0), mini(int((z + reach + half) / step) + 1, RES)):
		var pz := -half + float(j) * step
		for i in range(maxi(int((x - reach + half) / step), 0), mini(int((x + reach + half) / step) + 1, RES)):
			var d := Vector2(-half + float(i) * step - x, pz - z).length()
			var index := j * RES + i
			edit_mask[index] = minf(edit_mask[index], smoothstep(TOWER_LOCK_FULL, TOWER_LOCK_FULL + TOWER_LOCK_FADE, d))


## Lifts one lock. Any other lock overlapping that ground stays in force.
func remove_ground_lock(x: float, z: float) -> void:
	ground_locks.erase(Vector2(x, z))
	var half := SIZE * 0.5
	var reach := TOWER_LOCK_FULL + TOWER_LOCK_FADE + 1.0
	for j in range(maxi(int((z - reach + half) / step), 0), mini(int((z + reach + half) / step) + 1, RES)):
		for i in range(maxi(int((x - reach + half) / step), 0), mini(int((x + reach + half) / step) + 1, RES)):
			edit_mask[j * RES + i] = base_edit_mask[j * RES + i]
	for spot in ground_locks:
		if spot.distance_to(Vector2(x, z)) < reach * 2.0:
			_stamp_lock(spot.x, spot.y)


## Uneven brush strength, so raised ground forms ridges rather than a smooth cone.
func _build_brush_detail() -> void:
	brush_detail.resize(RES * RES)
	var half := SIZE * 0.5
	var ridges := FastNoiseLite.new()
	ridges.seed = 71
	ridges.frequency = 0.035
	ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridges.fractal_octaves = 4
	for j in RES:
		var z := -half + float(j) * step
		for i in RES:
			var x := -half + float(i) * step
			brush_detail[j * RES + i] = clampf(1.0 + ridges.get_noise_2d(x, z) * 0.9, 0.35, 1.7)


func _build_state() -> void:
	state.resize(RES * RES * 4)
	_refresh_rect(0, 0, RES - 1, RES - 1)
	state_image = Image.create_from_data(RES, RES, false, Image.FORMAT_RGBAF, state.to_byte_array())
	state_texture = ImageTexture.create_from_image(state_image)
	state_dirty = false


## Gives a material the live terrain texture.
func bind_state(material: ShaderMaterial) -> void:
	material.set_shader_parameter("terrain_state", state_texture)
	material.set_shader_parameter("terrain_size_res", Vector2(SIZE, float(RES)))


func upload_state() -> void:
	if not state_dirty:
		return
	state_image.set_data(RES, RES, false, Image.FORMAT_RGBAF, state.to_byte_array())
	state_texture.update(state_image)
	state_dirty = false


## Recomputes normals, dig depth and the GPU copy for one rectangle of vertices.
func _refresh_rect(i0: int, j0: int, i1: int, j1: int) -> void:
	for j in range(j0, j1 + 1):
		var jm := maxi(j - 1, 0)
		var jp := mini(j + 1, RES - 1)
		for i in range(i0, i1 + 1):
			var im := maxi(i - 1, 0)
			var ip := mini(i + 1, RES - 1)
			var index := j * RES + i
			var dx := heights[j * RES + ip] - heights[j * RES + im]
			var dz := heights[jp * RES + i] - heights[jm * RES + i]
			var ny := step * float(ip - im + jp - jm) * 0.5
			var length := sqrt(dx * dx + dz * dz + ny * ny)
			var nx := -dx / length
			var nz := -dz / length
			var h := heights[index]
			var dig := start_digs[index] + start_heights[index] - h
			if dig < 0.02:
				dig = 0.0
			digs[index] = dig
			normals[index] = Vector3(nx, ny / length, nz)
			var o := index * 4
			state[o] = h
			state[o + 1] = dig
			state[o + 2] = nx
			state[o + 3] = nz
	state_dirty = true


## Applies one frame of a brush. Amount depends on the tool: metres for raise and lower,
## 0-1 blend for smooth and flatten, metres of sideways push for pinch (negative stretches).
## Returns the volume of ground moved, in cubic metres, and the changed rectangle.
func apply_brush(tool: int, cx: float, cz: float, radius: float, amount: float, target_height: float, originals: Variant = null) -> Dictionary:
	var half := SIZE * 0.5
	var ci := (cx + half) / step
	var cj := (cz + half) / step
	var reach := radius / step
	var i0 := maxi(int(ci - reach) - 1, 1)
	var i1 := mini(int(ci + reach) + 2, RES - 2)
	var j0 := maxi(int(cj - reach) - 1, 1)
	var j1 := mini(int(cj + reach) + 2, RES - 2)
	if i0 > i1 or j0 > j1:
		return {"volume": 0.0, "rect": Rect2i()}
	var width := i1 - i0 + 1
	var old := PackedFloat32Array()
	var needs_copy := tool == TOOL_SMOOTH or tool == TOOL_PINCH
	if needs_copy:
		old.resize(width * (j1 - j0 + 1))
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				old[(j - j0) * width + (i - i0)] = heights[j * RES + i]
	var moved := 0.0
	var height_span := j1 - j0
	var plane_a := 0.0
	var plane_b := 0.0
	var plane_c := 0.0
	var plane_x := 0.0
	var plane_z := 0.0
	if tool == TOOL_SLOPE:
		plane_a = brush_plane["a"]
		plane_b = brush_plane["b"]
		plane_c = brush_plane["c"]
		plane_x = brush_plane["x"]
		plane_z = brush_plane["z"]
	for j in range(j0, j1 + 1):
		var dz := float(j) - cj
		for i in range(i0, i1 + 1):
			var dx := float(i) - ci
			var distance := sqrt(dx * dx + dz * dz) / reach
			if distance >= 1.0:
				continue
			var index := j * RES + i
			# A bell shape: raised ground rounds into a peak instead of a flat-topped cone.
			var bell := 1.0 - distance * distance
			var falloff := bell * bell * edit_mask[index]
			if falloff <= 0.0:
				continue
			var before := heights[index]
			var after := before
			match tool:
				TOOL_RAISE, TOOL_LOWER:
					after = before + amount * falloff * brush_detail[index]
				TOOL_FLATTEN:
					after = lerpf(before, target_height, minf(amount * falloff, 1.0))
				TOOL_SLOPE:
					var on_plane := plane_c + plane_a * (-half + float(i) * step - plane_x) + plane_b * (-half + float(j) * step - plane_z)
					after = lerpf(before, on_plane, minf(amount * falloff, 1.0))
				TOOL_SMOOTH:
					var oi := i - i0
					var oj := j - j0
					var left := old[oj * width + maxi(oi - 1, 0)]
					var right := old[oj * width + mini(oi + 1, width - 1)]
					var up := old[maxi(oj - 1, 0) * width + oi]
					var down := old[mini(oj + 1, height_span) * width + oi]
					after = lerpf(before, (left + right + up + down) * 0.25, minf(amount * falloff, 1.0))
				TOOL_PINCH:
					var push := amount * falloff / step / maxf(distance * reach, 1.0)
					var sx := clampf(float(i - i0) + dx * push, 0.0, float(width - 1) - 0.001)
					var sz := clampf(float(j - j0) + dz * push, 0.0, float(height_span) - 0.001)
					var bx := int(sx)
					var bz := int(sz)
					var tx := sx - float(bx)
					var tz := sz - float(bz)
					var row0 := bz * width + bx
					var row1 := row0 + width
					after = lerpf(lerpf(old[row0], old[row0 + 1], tx), lerpf(old[row1], old[row1 + 1], tx), tz)
			after = clampf(after, MIN_HEIGHT, MAX_HEIGHT)
			heights[index] = after
			after = heights[index]
			if after == before:
				continue
			if originals != null and not originals.has(index):
				originals[index] = before
			moved += absf(after - before)
			if (before < WATER_LEVEL) != (after < WATER_LEVEL):
				water_dirty = true
	var rect := Rect2i(maxi(i0 - 1, 0), maxi(j0 - 1, 0), width + 2, height_span + 3)
	_refresh_rect(rect.position.x, rect.position.y, mini(rect.end.x - 1, RES - 1), mini(rect.end.y - 1, RES - 1))
	return {"volume": moved * step * step, "rect": rect}


## Restores only the edited cells. A one-cell border supplies neighbouring normals.
func restore_cells(indices: PackedInt32Array, previous: PackedFloat32Array, rect: Rect2i) -> void:
	for n in indices.size():
		heights[indices[n]] = previous[n]
	var bounds := rect.grow(1).intersection(Rect2i(0, 0, RES, RES))
	if bounds.has_area():
		_refresh_rect(bounds.position.x, bounds.position.y, bounds.end.x - 1, bounds.end.y - 1)
	water_dirty = true


## Restores a whole saved map for the terrain tests.
func restore_heights(saved: PackedFloat32Array, rect: Rect2i) -> void:
	heights = saved.duplicate()
	_refresh_rect(rect.position.x, rect.position.y, mini(rect.end.x - 1, RES - 1), mini(rect.end.y - 1, RES - 1))
	water_dirty = true


## Follows the mouse ray down to the ground. Returns false when it misses the terrain.
func raycast(origin: Vector3, direction: Vector3) -> Variant:
	var half := SIZE * 0.5
	var distance := 0.0
	var step_size := 1.0
	var previous := origin
	while distance < 900.0:
		distance += step_size
		var p := origin + direction * distance
		if absf(p.x) < half and absf(p.z) < half and p.y <= height_at(p.x, p.z):
			# Refine between the last two samples.
			var low := previous
			var high := p
			for n in 8:
				var mid := low.lerp(high, 0.5)
				if mid.y <= height_at(mid.x, mid.z):
					high = mid
				else:
					low = mid
			return high
		previous = p
	return null


func _index_of(x: float, z: float) -> int:
	var half := SIZE * 0.5
	var i := clampi(int(round((x + half) / step)), 0, RES - 1)
	var j := clampi(int(round((z + half) / step)), 0, RES - 1)
	return j * RES + i


func height_at(x: float, z: float) -> float:
	var half := SIZE * 0.5
	var fx := clampf((x + half) / step, 0.0, float(RES) - 1.001)
	var fz := clampf((z + half) / step, 0.0, float(RES) - 1.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - float(i)
	var tz := fz - float(j)
	var a := lerpf(heights[j * RES + i], heights[j * RES + i + 1], tx)
	var b := lerpf(heights[(j + 1) * RES + i], heights[(j + 1) * RES + i + 1], tx)
	return lerpf(a, b, tz)


func normal_at(x: float, z: float) -> Vector3:
	return normals[_index_of(x, z)]


func dig_at(x: float, z: float) -> float:
	return digs[_index_of(x, z)]


func path_at(x: float, z: float) -> float:
	return paths[_index_of(x, z)]


func build_mesh() -> ArrayMesh:
	var total := RES * RES
	var half := SIZE * 0.5
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(total)
	colors.resize(total)
	for j in RES:
		var z := -half + float(j) * step
		for i in RES:
			var index := j * RES + i
			verts[index] = Vector3(-half + float(i) * step, heights[index], z)
			colors[index] = Color(clampf(digs[index] / DIG_SCALE, 0.0, 1.0), paths[index], 0.0, 1.0)
	var indices := PackedInt32Array()
	indices.resize((RES - 1) * (RES - 1) * 6)
	var k := 0
	for j in RES - 1:
		for i in RES - 1:
			var a := j * RES + i
			var b := a + 1
			var c := a + RES
			var d := c + 1
			indices[k] = a
			indices[k + 1] = b
			indices[k + 2] = c
			indices[k + 3] = b
			indices[k + 4] = d
			indices[k + 5] = c
			k += 6
	return _arrays_to_mesh(verts, normals, colors, indices)


## Low-detail surroundings so the valley sits inside a landscape, not on a slab.
func build_outer_mesh() -> ArrayMesh:
	var extent := 1400.0
	var cell := 14.0
	var count := int(extent * 2.0 / cell) + 1
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var norms := PackedVector3Array()
	verts.resize(count * count)
	colors.resize(count * count)
	norms.resize(count * count)
	for j in count:
		var z := -extent + float(j) * cell
		for i in count:
			var x := -extent + float(i) * cell
			var inside := maxf(absf(x), absf(z))
			# A soft ring of mountains closes the valley far away.
			var ring := smoothstep(520.0, 1300.0, inside)
			var h := base_height(x, z) + ring * (210.0 + _n_large.get_noise_2d(x * 0.28, z * 0.28) * 190.0)
			# Only just below the playable land at its edge, so no step shows, and well below it further in.
			h -= (1.0 - smoothstep(158.0, 176.0, inside)) * 2.5 + (1.0 - smoothstep(128.0, 156.0, inside)) * 40.0
			verts[j * count + i] = Vector3(x, h, z)
			colors[j * count + i] = Color(0.0, 0.0, 0.0, 1.0)
	for j in count:
		var j0 := maxi(j - 1, 0)
		var j1 := mini(j + 1, count - 1)
		for i in count:
			var i0 := maxi(i - 1, 0)
			var i1 := mini(i + 1, count - 1)
			var dx := verts[j * count + i1].y - verts[j * count + i0].y
			var dz := verts[j1 * count + i].y - verts[j0 * count + i].y
			norms[j * count + i] = Vector3(-dx, cell * 2.0, -dz).normalized()
	var indices := PackedInt32Array()
	for j in count - 1:
		for i in count - 1:
			var a := j * count + i
			indices.append_array(PackedInt32Array([a, a + 1, a + count, a + 1, a + count + 1, a + count]))
	return _arrays_to_mesh(verts, norms, colors, indices)


func build_meadow_map() -> ImageTexture:
	var size := 256
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBF)
	var fresh := Color(0.3, 0.46, 0.2).srgb_to_linear()
	var yellow := Color(0.44, 0.54, 0.22).srgb_to_linear()
	var straw := Color(0.58, 0.58, 0.3).srgb_to_linear()
	var patches := FastNoiseLite.new()
	patches.seed = 61
	patches.frequency = 0.05
	patches.fractal_octaves = 3
	for j in size:
		var z := (float(j) / float(size) - 0.5) * SIZE
		for i in size:
			var x := (float(i) / float(size) - 0.5) * SIZE
			var large := smoothstep(-0.3, 0.32, _n_large.get_noise_2d(x * 1.3, z * 1.3))
			var small := smoothstep(0.1, 0.45, patches.get_noise_2d(x, z))
			image.set_pixel(i, j, fresh.lerp(yellow, large).lerp(straw, small * 0.45))
	return ImageTexture.create_from_image(image)


func build_water_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if water_cells.is_empty():
		return mesh
	# Grow the water a little under the shore, so the terrain cuts the visible waterline.
	# Each corner keeps the soonest arrival among the water cells it touches.
	var wet := PackedByteArray()
	wet.resize(RES * RES)
	wet.fill(0)
	var arrive := PackedFloat32Array()
	arrive.resize(RES * RES)
	arrive.fill(INF)
	var quads := PackedInt32Array()
	for c in water_cells:
		var i := c % RES
		var j := c / RES
		var when := flood_arrival[c]
		for dj in range(-2, 3):
			var nj := j + dj
			if nj < 0 or nj >= RES - 1:
				continue
			for di in range(-2, 3):
				var ni := i + di
				if ni < 0 or ni >= RES - 1:
					continue
				var n := nj * RES + ni
				if when < arrive[n]:
					arrive[n] = when
				if wet[n] == 0:
					wet[n] = 1
					quads.append(n)
	var half := SIZE * 0.5
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(quads.size() * 6)
	uvs.resize(quads.size() * 6)
	var k := 0
	var corners: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1)]
	for q in quads:
		var qi := q % RES
		var qj := q / RES
		for corner in corners:
			var ci := qi + corner.x
			var cj := qj + corner.y
			var index := cj * RES + ci
			var when: float = arrive[index]
			if when == INF:
				when = arrive[q]
			verts[k] = Vector3(-half + float(ci) * step, WATER_LEVEL, -half + float(cj) * step)
			# New water starts on the ground and rises. Water that was already here has no depth to climb.
			uvs[k] = Vector2(when, maxf(WATER_LEVEL - heights[index], 0.0) if when > 0.0 else 0.0)
			k += 1
	var norms := PackedVector3Array()
	norms.resize(verts.size())
	norms.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _arrays_to_mesh(verts: PackedVector3Array, norms: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
