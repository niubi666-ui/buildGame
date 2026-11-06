extends SceneTree
## Run with --headless --fixed-fps 60 --path . --script res://scripts/undo_test.gd

const GameConfig = preload("res://scripts/game_config.gd")
const Terrain = preload("res://scripts/terrain_data.gd")
const TOWER_SPOT := Vector2(84, -40)
const RIDGE_SPOT := Vector2(-112, -15)

var world: Node
var brush: Node
var towers: Node
var tools: Node
var paths: Node
var failures := 0
var checks := 0
var deadline := 0
var completed := 0


func _initialize() -> void:
	deadline = Time.get_ticks_msec() + 120000
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() > deadline:
		printerr("UNDO TEST timed out")
		quit(1)
	return false


func _run() -> void:
	GameConfig.chosen_level = "level_01"
	change_scene_to_file("res://main.tscn")
	await scene_changed
	world = current_scene
	if not _check(world.get("brush") != null and world.get("paths") != null, "game scene initialized"):
		quit(1)
		return
	brush = world.brush
	towers = world.towers
	tools = world.tools
	paths = world.paths
	await _tower_and_ridge()
	if failures == 0:
		_tunnel()
	if failures == 0:
		_brush_stroke()
	if failures == 0:
		_history_limit()
	if failures == 0:
		_wave_boundary()
	_check(completed == 5, "all five scenarios reached their final assertion")
	unload_current_scene()
	await process_frame
	await process_frame
	print("UNDO TEST: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _check(ok: bool, description: String) -> bool:
	checks += 1
	if not ok:
		failures += 1
		printerr("UNDO FAIL: ", description)
	return ok


func _tower_and_ridge() -> void:
	var starting_gold: float = brush.money
	var initial_heights: PackedFloat32Array = world.terrain.heights.duplicate()
	var initial_mask: PackedFloat32Array = world.terrain.edit_mask.duplicate()
	var initial_trees: int = brush.hides_on_bare_ground.size()
	if not _check(towers.place_at(TOWER_SPOT.x, TOWER_SPOT.y, 0.37, -0.2, false), "place tower"):
		return
	var tower: Dictionary = towers.selected
	var tower_id: int = tower["id"]
	var base_price: int = tower["paid"]
	var after_build: float = brush.money
	var with_tower: PackedFloat32Array = world.terrain.heights.duplicate()
	_check(with_tower != initial_heights and world.terrain.edit_mask != initial_mask, "test site changes both foundation heights and locks")
	towers.deselect()
	var ridge: Dictionary = {}
	for preset: Dictionary in tools.presets:
		if preset["id"] == "ridge":
			ridge = preset
	if not _check(tools.place_preset(ridge, RIDGE_SPOT, 0.0), "place ridge"):
		return
	var after_ridge: float = brush.money
	brush.undo()
	_check(brush.ground_busy and brush.money == after_ridge, "unfinished terrain work blocks undo")
	while brush.ground_busy:
		await process_frame
	_check(paths.gate_plans[0]["label"] == "走东路", "ridge redirects the west gate")
	var with_ridge: PackedFloat32Array = world.terrain.heights.duplicate()
	towers.select(tower)
	for id in ["scatter", "blaze", "star"]:
		if not _check(towers.upgrade_selected(id), "buy " + id):
			return
	var upgraded_price: int = tower["paid"]
	var after_upgrades: float = brush.money
	_check(not towers.upgrade_selected("invalid") and brush.history.count() == 5, "invalid purchase takes no slot")
	towers.sell_selected()
	_check(towers.towers.is_empty() and brush.money == after_upgrades + floorf(upgraded_price * towers.refund_rate), "sale credits actual proceeds")
	world.ui._sync_tools()
	_check(not world.ui.undo_button.disabled, "toolbar offers undo after a sale")
	world.ui.undo_button.pressed.emit()
	if not _check(towers.towers.size() == 1, "undo sale restores one tower"):
		return
	tower = towers.towers.front()
	_check(tower["id"] == tower_id and tower["path"] == ["scatter", "blaze"] and tower["stars"] == 1, "same tower and upgrade tree after sale undo")
	_check(is_equal_approx(tower["yaw"], 0.37) and is_equal_approx(tower["pitch"], -0.2), "restored tower keeps its aim")
	_check(brush.money == after_upgrades and tower["paid"] == upgraded_price and world.terrain.heights == with_ridge, "sale undo restores payment and foundation")
	var shortcut := InputEventKey.new()
	shortcut.keycode = KEY_Z
	shortcut.physical_keycode = KEY_Z
	shortcut.ctrl_pressed = true
	shortcut.pressed = true
	root.push_input(shortcut)
	_check(tower["stars"] == 0 and tower["path"] == ["scatter", "blaze"], "undo star leaves final branch")
	brush.undo()
	_check(tower["path"] == ["scatter"], "undo final upgrade leaves first branch")
	brush.undo()
	_check(tower["path"].is_empty() and tower["paid"] == base_price and brush.money == after_ridge, "original tower and balance after undoing upgrades")
	brush.undo()
	_check(brush.money == after_build and world.terrain.heights == with_tower and paths.gate_plans[0]["label"] == "走西路", "ridge undo restores only its terrain, route and cost")
	brush.undo()
	_check(towers.towers.is_empty() and world.terrain.heights == initial_heights, "build undo removes tower and foundation")
	_check(world.terrain.edit_mask == initial_mask and brush.hides_on_bare_ground.size() == initial_trees, "build undo restores ground locks and trees")
	brush.undo()
	_check(brush.money == starting_gold and brush.history.count() == 0, "empty undo cannot issue another refund")
	world.ui._sync_tools()
	_check(world.ui.undo_button.disabled, "toolbar disables undo with an empty history")
	completed += 1


func _tunnel() -> void:
	var gold: float = brush.money
	var initial_heights: PackedFloat32Array = world.terrain.heights.duplicate()
	var initial_mask: PackedFloat32Array = world.terrain.edit_mask.duplicate()
	if not _check(tools.build_tunnel(Vector2(16, -108), Vector2(0, 88)), "dig tunnel"):
		return
	var open_gold: float = brush.money
	var open_heights: PackedFloat32Array = world.terrain.heights.duplicate()
	var open_mask: PackedFloat32Array = world.terrain.edit_mask.duplicate()
	var portal: Node3D = tools.tunnels.front()["nodes"][0]
	tools.select_tunnel(tools.tunnels.front())
	var refund: int = tools.tunnel_refund()
	tools.remove_selected_tunnel()
	_check(brush.money == open_gold + refund and tools.tunnels.is_empty() and not portal.is_visible_in_tree(), "manual fill hides the entrance and returns partial cost")
	brush.undo()
	if not _check(tools.tunnels.size() == 1 and brush.money == open_gold, "undo fill reinstates tunnel and charges exact proceeds"):
		return
	_check(tools.tunnels.front()["nodes"][0] == portal and portal.is_visible_in_tree(), "undo fill restores the same visible portal")
	_check(paths.gate_plans[0]["label"] == "穿隧道" and world.terrain.heights == open_heights and world.terrain.edit_mask == open_mask, "restored portal cuts, locks and native route")
	brush.undo()
	_check(tools.tunnels.is_empty() and brush.money == gold and brush.history.count() == 0, "earlier dig undo still identifies restored tunnel")
	_check(portal.is_queued_for_deletion(), "undone tunnel releases its portal")
	_check(paths.gate_plans[0]["label"] == "走西路" and world.terrain.heights == initial_heights and world.terrain.edit_mask == initial_mask, "tunnel undo restores original map")
	completed += 1


func _brush_stroke() -> void:
	var gold: float = brush.money
	var original: PackedFloat32Array = world.terrain.heights.duplicate()
	brush.money = 1.25
	brush.has_hit = true
	brush.hit = Vector3(RIDGE_SPOT.x, world.terrain.height_at(RIDGE_SPOT.x, RIDGE_SPOT.y), RIDGE_SPOT.y)
	brush.begin_stroke()
	brush.paint(Terrain.TOOL_RAISE, RIDGE_SPOT.x, RIDGE_SPOT.y, 10.0, 1.0, 0.001)
	brush.paint(Terrain.TOOL_RAISE, RIDGE_SPOT.x + 2.0, RIDGE_SPOT.y, 10.0, 1.0, 1.0)
	brush.end_stroke()
	_check(brush.money == 0.0 and brush.history.count() == 1, "overlapping dabs and a clipped final charge make one entry")
	brush.undo()
	_check(is_equal_approx(brush.money, 1.25) and world.terrain.heights == original, "stroke restores original heights and actual spend")
	brush.money = gold
	completed += 1


func _history_limit() -> void:
	if not _check(towers.place_at(TOWER_SPOT.x, TOWER_SPOT.y, 0.0, 0.0, false), "place tower for history eviction"):
		return
	var parked_node: Node3D = towers.selected["node"]
	towers.begin_slider_aim()
	towers.aim_selected_degrees(10.0, 2.0)
	towers.aim_selected_degrees(25.0, 5.0)
	towers.end_slider_aim(true)
	_check(brush.history.count() == 2, "dragging the aim slider records one adjustment")
	brush.undo()
	_check(is_zero_approx(towers.selected["yaw"]) and is_zero_approx(towers.selected["pitch"]), "aim undo restores both angles")
	towers.sell_selected()
	_check(not parked_node.is_visible_in_tree() and not parked_node.is_queued_for_deletion(), "recoverable sale keeps its hidden tower")
	var reverted: Array[int] = []
	var discarded: Array[int] = []
	var limit: int = GameConfig.tools()["brush"]["max_undo"]
	for i in limit + 1:
		brush.history.record("test", reverted.append.bind(i), discarded.append.bind(i))
	_check(brush.history.count() == limit and discarded == [0], "oldest action is released at the configured cap")
	_check(parked_node.is_queued_for_deletion(), "evicting an old sale releases its tower")
	for i in limit:
		brush.undo()
	var expected := range(limit, 0, -1)
	_check(reverted == expected and brush.history.count() == 0, "retained actions undo exactly once, newest first")
	completed += 1


func _wave_boundary() -> void:
	# One east-gate enemy with 1 HP makes the combat record deterministic and keeps the test short.
	var walker: Dictionary = paths.enemy_specs["walker"].duplicate()
	walker["hp"] = 1.0
	paths.core.set_type(paths.type_index["walker"], paths._type_numbers(walker))
	paths.level = paths.level.duplicate(true)
	paths.level["waves"][0]["groups"] = [{"type": "walker", "gate": "east", "count": 1, "delay": 0, "interval": 1}]
	paths.replan()
	if not _check(towers.place_at(TOWER_SPOT.x, TOWER_SPOT.y, 0.0, -0.2, false), "place tower before battle"):
		return
	var tower_id: int = towers.selected["id"]
	var aim: PackedFloat32Array = paths.core.tower_best_aim(tower_id)
	if not _check(aim.size() == 3, "tower can cover east gate route"):
		return
	towers.aim_selected_degrees(rad_to_deg(atan2(aim[0], aim[2])), rad_to_deg(asin(aim[1])))
	paths.start_battle()
	_check(paths.phase == paths.Phase.BATTLE and brush.history.count() == 0, "battle commits preparation")
	_check(towers.upgrade_selected("scatter") and brush.history.count() == 0, "battle upgrade applies without recording")
	brush.undo()
	_check(towers.selected["path"] == ["scatter"], "battle undo cannot reverse a committed upgrade")
	for second in 200:
		if paths.phase != paths.Phase.BATTLE:
			break
		paths._process(1.0)
	if not _check(paths.phase == paths.Phase.BUILD and paths.outcome == "" and brush.history.count() == 0, "next preparation starts with empty history"):
		return
	var kills: int = paths.core.tower_kills(tower_id)
	_check(kills == 1, "tower earned a kill in the previous wave")
	towers.sell_selected()
	brush.undo()
	_check(towers.towers.size() == 1 and towers.towers[0]["id"] == tower_id and paths.core.tower_kills(tower_id) == kills, "undo sale preserves a veteran tower's kills")
	completed += 1
