extends RefCounted
## Loads the numbers in res://data. Nothing else in the game reads those files directly.

const DATA_DIR := "res://data/"

static var _cache := {}
## The level picked on the menu. Static, so it survives reloading the battle scene.
static var chosen_level := ""
## Set once the menu has been seen, so a command-line launch skips it only the first time.
static var menu_seen := false

const PROGRESS_PATH := "user://progress.cfg"


static func load_json(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var text := FileAccess.get_file_as_string(DATA_DIR + path)
	if text.is_empty():
		push_error("Config file is missing or empty: %s%s" % [DATA_DIR, path])
		return {}
	var parser := JSON.new()
	if parser.parse(text) != OK:
		push_error("Config file %s has an error on line %d: %s" % [path, parser.get_error_line(), parser.get_error_message()])
		return {}
	var data: Dictionary = parser.data
	_cache[path] = data
	return data


static func enemies() -> Dictionary:
	return load_json("enemies.json")


static func towers() -> Dictionary:
	return load_json("towers.json")


static func tools() -> Dictionary:
	return load_json("terrain_tools.json")


static func level(level_id: String) -> Dictionary:
	return load_json("levels/%s.json" % level_id)


## Level ids in menu order, from data/levels/index.json.
static func level_order() -> Array:
	return load_json("levels/index.json").get("levels", [])


## The level after this one on the menu, or "" for the last.
static func next_level(level_id: String) -> String:
	var order := level_order()
	var at := order.find(level_id)
	return String(order[at + 1]) if at >= 0 and at + 1 < order.size() else ""


static func is_cleared(level_id: String) -> bool:
	var file := ConfigFile.new()
	if file.load(PROGRESS_PATH) != OK:
		return false
	return bool(file.get_value("cleared", level_id, false))


static func mark_cleared(level_id: String) -> void:
	var file := ConfigFile.new()
	file.load(PROGRESS_PATH)
	file.set_value("cleared", level_id, true)
	file.save(PROGRESS_PATH)


static func vector2(point: Array) -> Vector2:
	return Vector2(float(point[0]), float(point[1]))


static func vector3(point: Array) -> Vector3:
	return Vector3(float(point[0]), float(point[1]), float(point[2]))
