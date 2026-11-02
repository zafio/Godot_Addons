@tool
extends EditorInspectorPlugin
class_name UVIslandInspectorPlugin

## Adds a "Pick Atlas Region..." button to UVIslandTrack in the Inspector.

var dialog: UVAtlasPickerDialog
var undo_redo: EditorUndoRedoManager

var _track: UVIslandTrack

func _can_handle(object: Object) -> bool:
    return object is UVIslandTrack

func _parse_begin(object: Object) -> void:
    var b := Button.new()
    b.text = "Pick Atlas Region..."
    b.tooltip_text = "Choose the atlas region for this island visually."
    b.pressed.connect(_open.bind(object))
    add_custom_control(b)

func _open(track: UVIslandTrack) -> void:
    if dialog == null or track == null:
        return
    var animator := track.get_animator()
    if animator == null:
        return
    var island := animator.get_island(track.island_id)
    var preset := track.get_effective_atlas()
    if preset == null:
        preset = UVAtlasPreset.new()
        preset.preset_name = "Atlas"
        undo_redo.create_action("Create atlas preset", UndoRedo.MERGE_DISABLE, animator)
        undo_redo.add_do_property(animator, "atlas", preset)
        undo_redo.add_undo_property(animator, "atlas", null)
        undo_redo.commit_action()

    var texture: Texture2D = null
    if island != null:
        texture = animator.get_preview_texture(island.surface)

    _track = track
    dialog.undo_redo = undo_redo
    dialog.history_context = animator
    if dialog.region_chosen.is_connected(_on_chosen):
        dialog.region_chosen.disconnect(_on_chosen)
    dialog.region_chosen.connect(_on_chosen)
    dialog.open_for(preset, texture,
        island.get_uv_rect() if island != null else Rect2(),
        island != null, track.atlas_region)

func _on_chosen(region_name: String) -> void:
    if _track == null or not is_instance_valid(_track):
        return
    undo_redo.create_action("Set atlas region", UndoRedo.MERGE_DISABLE, _track)
    undo_redo.add_do_property(_track, "atlas_region", region_name)
    undo_redo.add_do_property(_track, "use_atlas", true)
    undo_redo.add_undo_property(_track, "atlas_region", _track.atlas_region)
    undo_redo.add_undo_property(_track, "use_atlas", _track.use_atlas)
    undo_redo.commit_action()
