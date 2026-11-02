@tool
extends Resource
class_name UVAtlasRegion

## A named rectangle in UV space (0..1, origin top-left like Godot UVs).

@export var region_name: String = "":
    set(value):
        region_name = value
        emit_changed()

@export var rect: Rect2 = Rect2(0.0, 0.0, 1.0, 1.0):
    set(value):
        rect = value
        emit_changed()
