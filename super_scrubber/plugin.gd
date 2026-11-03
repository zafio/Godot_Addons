@tool
extends EditorPlugin

const ScrubInput := preload("res://addons/super_scrubber/scrub_input.gd")

var _input_node: Node


func _enter_tree() -> void:
	if not EditorInterface.get_editor_settings().has_method("add_shortcut"):
		push_error("SuperScrubber needs Godot 4.6 or newer.")
		return
	_input_node = ScrubInput.new()
	_input_node.name = "SuperScrubberInput"
	_input_node.plugin = self
	add_child(_input_node)


func _apply_changes() -> void:
	if is_instance_valid(_input_node):
		_input_node.release_fps_player()


func _exit_tree() -> void:
	if is_instance_valid(_input_node):
		_input_node.shutdown()
		_input_node.queue_free()
	_input_node = null
