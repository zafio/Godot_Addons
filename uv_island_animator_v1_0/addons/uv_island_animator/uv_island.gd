@tool
extends Resource
class_name UVIsland

## One connected UV shell of a mesh surface.
## Only lightweight data is saved with the scene. face_indices is deliberately
## NOT exported: it is only needed while baking and would bloat scenes.

@export var name: String = ""
@export var surface: int = 0
@export var island_id: int = 0
@export var triangle_count: int = 0
@export var vertex_count: int = 0
@export var uv_min: Vector2 = Vector2.ZERO
@export var uv_max: Vector2 = Vector2.ONE

var face_indices: PackedInt32Array = PackedInt32Array()

func get_uv_rect() -> Rect2:
    return Rect2(uv_min, uv_max - uv_min)

func get_uv_center() -> Vector2:
    return (uv_min + uv_max) * 0.5

func contains_uv(uv: Vector2) -> bool:
    return uv.x >= uv_min.x and uv.x <= uv_max.x and uv.y >= uv_min.y and uv.y <= uv_max.y
