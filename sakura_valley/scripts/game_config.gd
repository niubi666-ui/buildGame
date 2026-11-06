extends RefCounted
## Loads the numbers in res://data. Nothing else in the game reads those files directly.

const DATA_DIR := "res://data/"

static var _cache := {}
## The level picked on the menu. Static, so it survives reloading the battle scene.
static var chosen_level := ""
## Set once the menu has been seen, so a command-line launch skips it only the first time.
static var menu_seen := false

const PROGRESS_PATH := "user://progress.cfg"
## Off for tests and checks, so automated battles never change the player's saved stars.
static var saving := true


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


## Stars for a finished battle: none for a loss, three for an untouched home, two while at least
## the share in data/levels/index.json ("two_star_health") is left, and one for any other win.
static func stars_for(hp: int, hp_max: int) -> int:
	if hp_max <= 0 or hp <= 0:
		return 0
	if hp >= hp_max:
		return 3
	var share := float(load_json("levels/index.json").get("two_star_health", 0.5))
	return 2 if float(hp) >= float(hp_max) * share - 0.001 else 1


## The most stars ever earned on this level. A clear saved before stars existed counts as one.
static func best_stars(level_id: String) -> int:
	var file := ConfigFile.new()
	if file.load(PROGRESS_PATH) != OK:
		return 0
	var stars := int(file.get_value("stars", level_id, 0))
	if stars == 0 and bool(file.get_value("cleared", level_id, false)):
		stars = 1
	return stars


static func is_cleared(level_id: String) -> bool:
	return best_stars(level_id) > 0


## Keeps the better of this result and the saved one. Returns true when this is a new best.
static func record_stars(level_id: String, stars: int) -> bool:
	if stars <= 0 or not saving:
		return false
	var file := ConfigFile.new()
	file.load(PROGRESS_PATH)
	var before := best_stars(level_id)
	file.set_value("cleared", level_id, true)
	if stars <= before:
		file.set_value("stars", level_id, before)
		file.save(PROGRESS_PATH)
		return false
	file.set_value("stars", level_id, stars)
	file.save(PROGRESS_PATH)
	return true


static func vector2(point: Array) -> Vector2:
	return Vector2(float(point[0]), float(point[1]))


static func vector3(point: Array) -> Vector3:
	return Vector3(float(point[0]), float(point[1]), float(point[2]))
