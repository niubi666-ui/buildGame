extends SceneTree
## Run with --headless --path . --script res://scripts/pause_test.gd

const GameConfig = preload("res://scripts/game_config.gd")
const TOWER_SPOT := Vector2(84, -40)

var world: Node
var paths: Node
var checks := 0
var failures := 0
var deadline := 0


func _initialize() -> void:
	deadline = Time.get_ticks_msec() + 120000
	_run.call_deferred()


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() > deadline:
		printerr("PAUSE TEST timed out")
		quit(1)
	return false


func _run() -> void:
	GameConfig.chosen_level = "level_01"
	change_scene_to_file("res://main.tscn")
	await scene_changed
	world = current_scene
	paths = world.paths
	_scenario()
	unload_current_scene()
	await process_frame
	await process_frame
	print("PAUSE TEST: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(ok: bool, description: String) -> bool:
	checks += 1
	if not ok:
		failures += 1
		printerr("PAUSE FAIL: ", description)
	return ok


func _key(code: Key, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.echo = echo
	event.pressed = true
	root.push_input(event)


func _scenario() -> void:
	var brush: Node = world.brush
	var towers: Node = world.towers
	var ui: Node = world.ui
	# The second walker spawns after the first walker has entered tower range.
	paths.level = paths.level.duplicate(true)
	paths.level["waves"][0]["groups"] = [{"type": "walker", "gate": "east", "count": 2, "delay": 0, "interval": 60}]
	paths.replan()
	_key(KEY_SPACE)
	ui._sync_phase()
	_check(not paths.battle_paused and not ui.pause_button.visible, "pause is unavailable during preparation")

	_key(KEY_3)
	_key(KEY_B)
	ui._sync_phase()
	if not _check(ui.pause_button.visible and paths.phase == paths.Phase.BATTLE and paths.speed == 2.0, "start a wave at double speed"):
		return
	ui.pause_button.pressed.emit()
	_key(KEY_SPACE, true)
	ui._sync_phase()
	_check(paths.battle_paused and ui.pause_button.text == "继续", "button pauses and key repeat leaves it paused")
	var time_before: float = paths.sim_time
	paths._process(1.0)
	_check(paths.sim_time == time_before and not paused, "only combat time is paused")
	brush.begin_stroke()
	_check(brush.locked and not brush.painting and not brush.history.enabled, "terrain and undo keep their battle rules")

	var gold: float = brush.money
	_key(KEY_T)
	brush.has_hit = true
	brush.hit = Vector3(TOWER_SPOT.x, world.terrain.height_at(TOWER_SPOT.x, TOWER_SPOT.y), TOWER_SPOT.y)
	var click := InputEventMouseButton.new()
	click.position = root.get_visible_rect().get_center()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	root.push_input(click, true)
	if not _check(towers.towers.size() == 1 and not towers.selected.is_empty(), "build and select a tower while paused"):
		return
	var tower: Dictionary = towers.selected
	_check(brush.money == gold - tower["paid"], "construction charges its normal price")
	var old_paid: int = tower["paid"]
	var row: Dictionary = ui.upgrade_rows.front()
	row["button"].pressed.emit()
	_check(tower["path"] == [row["id"]] and tower["paid"] == old_paid + row["cost"] and brush.money == gold - tower["paid"], "upgrade button applies and charges while paused")
	brush.undo()
	_check(brush.history.count() == 0 and not tower["path"].is_empty(), "paused battle purchase cannot be undone")
	var aim: PackedFloat32Array = paths.core.tower_best_aim(tower["id"])
	if not _check(aim.size() == 3, "paused tower can aim at the east road"):
		return
	towers.aim_selected_degrees(rad_to_deg(atan2(aim[0], aim[2])), rad_to_deg(asin(aim[1])))
	_key(KEY_SPACE)
	paths._process(0.05)
	_check(not paths.battle_paused and is_equal_approx(paths.sim_time - time_before, 0.1), "Space resumes the original double speed")

	# MultiMesh slots hold 20 floats; the alpha at offset 15 is nonzero for visible objects.
	for frame in 1200:
		if paths.core.shots()[15] > 0.0:
			break
		paths._process(0.025)
	var shots: PackedFloat32Array = paths.core.shots()
	if not _check(shots[15] > 0.0, "the tower built during pause fires after resuming"):
		return
	_key(KEY_SPACE)
	# At zero delta the native core exports transforms without advancing the simulation.
	var enemies: PackedFloat32Array = paths.core.step(0.0)
	_check(enemies[15] > 0.0 and enemies[35] == 0.0, "one walker is moving and the next has yet to spawn")
	var hp: int = paths.home_hp
	var timer: float = paths.core.tower_timer(tower["id"])
	var fx_time: float = paths.fx.clock
	var balance: float = brush.money
	time_before = paths.sim_time
	paths._process(125.0)
	_check(paths.core.step(0.0) == enemies and paths.core.shots() == shots, "pause freezes movement, projectiles and the delayed spawn")
	_check(paths.core.tower_timer(tower["id"]) == timer and paths.fx.clock == fx_time, "combat cooldown and effects stop")
	_check(paths.sim_time == time_before and paths.home_hp == hp and brush.money == balance, "pause freezes wave time, home health and rewards")
	_key(KEY_4)
	_check(paths.battle_paused and paths.speed == 4.0, "changing speed during pause selects the next playback speed")
	var refund: float = floorf(tower["paid"] * towers.refund_rate)
	ui.sell_button.pressed.emit()
	_check(towers.towers.is_empty() and brush.money == balance + refund and paths.battle_paused, "sell button removes tower and credits the usual refund during pause")
	ui.pause_button.pressed.emit()
	paths._process(0.01)
	_check(not paths.battle_paused and is_equal_approx(paths.sim_time - time_before, 0.04) and paths.core.shots() != shots, "button resumes the projectile at the selected speed")
	for second in 200:
		if paths.phase != paths.Phase.BATTLE:
			break
		paths._process(1.0)
	ui._sync_phase()
	_check(paths.phase == paths.Phase.BUILD and paths.outcome == "" and not ui.pause_button.visible, "wave reaches next preparation")
	_key(KEY_B)
	_check(paths.wave == 2 and not paths.battle_paused and paths.phase == paths.Phase.BATTLE, "the next wave starts running")
