@tool
extends EditorPlugin

const ScrubInput := preload("res://addons/super_scrubber/scrub_input.gd")

var _input_node: Node


func _enter_tree() -> void:
	_input_node = ScrubInput.new()
	_input_node.name = "SuperScrubberInput"
	_input_node.plugin = self
	add_child(_input_node)


func _exit_tree() -> void:
	if is_instance_valid(_input_node):
		_input_node.shutdown()
		_input_node.queue_free()
	_input_node = null
