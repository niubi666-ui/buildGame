extends Node
## One undo history for the current preparation phase. The owner of each action
## supplies its inverse and, if needed, a way to release objects held for undo.

signal before_undo
signal before_commit

var limit := 20
var enabled := true:
	set(value):
		if enabled == value:
			return
		if not value:
			before_commit.emit()
		enabled = value
		if not enabled:
			clear()

var _entries: Array[Dictionary] = []
var _undoing := false


func record(label: String, revert: Callable, discard := Callable()) -> void:
	if not enabled or _undoing or limit <= 0:
		if discard.is_valid():
			discard.call()
		return
	_entries.append({"label": label, "revert": revert, "discard": discard})
	if _entries.size() > limit:
		_discard(_entries.pop_front())


func count() -> int:
	return _entries.size()


func last_label() -> String:
	return "" if _entries.is_empty() else _entries.back()["label"]


func undo() -> void:
	if not enabled or _undoing:
		return
	_undoing = true
	before_undo.emit()
	if not _entries.is_empty():
		var action: Dictionary = _entries.pop_back()
		action["revert"].call()
	_undoing = false


func clear() -> void:
	while not _entries.is_empty():
		_discard(_entries.pop_front())


func _discard(action: Dictionary) -> void:
	var release: Callable = action["discard"]
	if release.is_valid():
		release.call()


func _exit_tree() -> void:
	clear()
