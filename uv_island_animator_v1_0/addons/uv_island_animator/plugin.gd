@tool
extends EditorPlugin

const DockScript = preload("res://addons/uv_island_animator/uv_island_dock.gd")

var dock
var picker_dialog: UVAtlasPickerDialog
var inspector_plugin: UVIslandInspectorPlugin

func _enter_tree() -> void:
    picker_dialog = UVAtlasPickerDialog.new()
    EditorInterface.get_base_control().add_child(picker_dialog)

    dock = DockScript.new()
    dock.undo_redo = get_undo_redo()
    dock.picker_dialog = picker_dialog
    add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

    inspector_plugin = UVIslandInspectorPlugin.new()
    inspector_plugin.dialog = picker_dialog
    inspector_plugin.undo_redo = get_undo_redo()
    add_inspector_plugin(inspector_plugin)

func _exit_tree() -> void:
    if inspector_plugin != null:
        remove_inspector_plugin(inspector_plugin)
        inspector_plugin = null
    if is_instance_valid(dock):
        remove_control_from_docks(dock)
        dock.queue_free()
    if is_instance_valid(picker_dialog):
        picker_dialog.queue_free()
