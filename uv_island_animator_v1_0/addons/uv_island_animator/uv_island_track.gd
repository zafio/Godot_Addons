@tool
extends Node
class_name UVIslandTrack

## Animatable handle for one UV island. Key these properties with an
## AnimationPlayer (or use the dock's "Animate" tab to create keys in one click).

enum PivotMode { ISLAND_CENTER, UV_CENTER }

@export var island_id: int = 0:
    set(value):
        island_id = value
        _touch()

@export var offset: Vector2 = Vector2.ZERO:
    set(value):
        offset = value
        _touch()

@export var scale: Vector2 = Vector2.ONE:
    set(value):
        scale = value
        _touch()

@export_range(-360.0, 360.0, 0.1, "or_less", "or_greater") var rotation_degrees: float = 0.0:
    set(value):
        rotation_degrees = value
        _touch()

## Where scale/rotation pivot. ISLAND_CENTER is what you normally want;
## UV_CENTER reproduces v0.5 (pivot at 0.5, 0.5 of the whole texture).
@export var pivot_mode: PivotMode = PivotMode.ISLAND_CENTER:
    set(value):
        pivot_mode = value
        _touch()

@export_group("Atlas")
## Master switch. With an atlas region selected, the island's UV bounding box is
## remapped onto that region (the island keeps its shape, its content changes).
@export var use_atlas: bool = false:
    set(value):
        use_atlas = value
        _touch()

## Optional per-track atlas. If empty, the animator's shared atlas is used.
@export var atlas_override: UVAtlasPreset:
    set(value):
        if atlas_override != null and atlas_override.changed.is_connected(_on_atlas_changed):
            atlas_override.changed.disconnect(_on_atlas_changed)
        atlas_override = value
        if atlas_override != null:
            atlas_override.changed.connect(_on_atlas_changed)
        notify_property_list_changed()
        _touch()

## Name of a region in the effective atlas. Keyable (discrete) in animations.
@export var atlas_region: String = "":
    set(value):
        atlas_region = value
        _touch()

## Used only when NO region name is set (raw rectangle, v0.5 behaviour).
@export var atlas_min: Vector2 = Vector2.ZERO:
    set(value):
        atlas_min = value
        _touch()
@export var atlas_max: Vector2 = Vector2.ONE:
    set(value):
        atlas_max = value
        _touch()

func _enter_tree() -> void:
    _touch()

func _validate_property(property: Dictionary) -> void:
    if property.name == "atlas_region":
        var preset := get_effective_atlas()
        if preset != null and not preset.regions.is_empty():
            property.hint = PROPERTY_HINT_ENUM
            property.hint_string = ",".join(preset.get_region_names())

func get_animator() -> UVIslandAnimator:
    var p := get_parent()
    return p as UVIslandAnimator

func get_effective_atlas() -> UVAtlasPreset:
    if atlas_override != null:
        return atlas_override
    var a := get_animator()
    return a.atlas if a != null else null

## Returns { "use": bool, "rect": Rect2 } describing the atlas rect currently selected.
func get_atlas_rect() -> Dictionary:
    if not use_atlas:
        return {"use": false, "rect": Rect2()}
    if not atlas_region.is_empty():
        var preset := get_effective_atlas()
        if preset != null and preset.has_region(atlas_region):
            return {"use": true, "rect": preset.get_region_rect(atlas_region)}
        return {"use": false, "rect": Rect2()}   # unknown region: leave UVs alone
    return {"use": true, "rect": Rect2(atlas_min, atlas_max - atlas_min)}

func compute_transform(island: UVIsland) -> Transform2D:
    var atlas := get_atlas_rect()
    return UVIslandMath.compose(
        island.get_uv_rect(), offset, scale, rotation_degrees,
        pivot_mode == PivotMode.UV_CENTER, atlas["use"], atlas["rect"])

func _on_atlas_changed() -> void:
    notify_property_list_changed()
    _touch()

func _touch() -> void:
    if not is_inside_tree():
        return
    var a := get_animator()
    if a != null:
        a.queue_track_update(self)
