@tool
extends Resource
class_name UVAtlasPreset

## Reusable atlas description: a list of named UV regions.
## Save it as a .tres and share it between characters that use the same layout.
##
## Regions live in the UV space of the mesh's texture (the same texture the
## material already uses), so normal/ORM/emission maps stay in sync.

@export var preset_name: String = ""
## Only used for previews in the picker. Falls back to the material's albedo.
@export var reference_texture: Texture2D
## Shrinks every region by this much (in UV units) when sampling, to avoid
## bleeding from neighbouring cells with filtering/mipmaps.
@export_range(0.0, 0.05, 0.0001) var inset: float = 0.0:
    set(value):
        inset = value
        emit_changed()
@export var regions: Array[UVAtlasRegion] = []

# ---------------------------------------------------------------- queries

func get_region_names() -> PackedStringArray:
    var out := PackedStringArray()
    for r in regions:
        if r != null:
            out.append(r.region_name)
    return out

func has_region(region_name: String) -> bool:
    return get_region(region_name) != null

func get_region(region_name: String) -> UVAtlasRegion:
    for r in regions:
        if r != null and r.region_name == region_name:
            return r
    return null

## Returns a zero-size Rect2 if the region does not exist.
func get_region_rect(region_name: String, apply_inset: bool = true) -> Rect2:
    var r := get_region(region_name)
    if r == null:
        return Rect2()
    var rect := r.rect
    if apply_inset and inset > 0.0:
        var i := minf(inset, minf(rect.size.x, rect.size.y) * 0.5)
        rect = rect.grow(-i)
    return rect

## Smallest region containing uv (so nested regions win over big ones).
func find_region_at(uv: Vector2) -> String:
    var best := ""
    var best_area := INF
    for r in regions:
        if r != null and r.rect.has_point(uv):
            var a := r.rect.get_area()
            if a < best_area:
                best_area = a
                best = r.region_name
    return best

# -------------------------------------------------------------- mutation

func make_unique_name(base: String) -> String:
    var b := base if not base.is_empty() else "region"
    if not has_region(b):
        return b
    var i := 2
    while has_region("%s_%d" % [b, i]):
        i += 1
    return "%s_%d" % [b, i]

func add_region(region_name: String, rect: Rect2) -> UVAtlasRegion:
    var r := UVAtlasRegion.new()
    r.region_name = make_unique_name(region_name)
    r.rect = rect
    regions.append(r)
    emit_changed()
    return r

func remove_region(region_name: String) -> bool:
    for i in regions.size():
        if regions[i] != null and regions[i].region_name == region_name:
            regions.remove_at(i)
            emit_changed()
            return true
    return false

func rename_region(old_name: String, new_name: String) -> bool:
    if new_name.is_empty() or has_region(new_name):
        return false
    var r := get_region(old_name)
    if r == null:
        return false
    r.region_name = new_name
    emit_changed()
    return true

func set_region_rect(region_name: String, rect: Rect2) -> bool:
    var r := get_region(region_name)
    if r == null:
        return false
    r.rect = rect
    emit_changed()
    return true

## pattern tokens: {col} {row} {index}. Row 0 is the TOP row (Godot UV space).
func generate_grid(cols: int, rows: int, pattern: String = "cell_{col}_{row}", clear_existing: bool = true) -> void:
    cols = maxi(cols, 1)
    rows = maxi(rows, 1)
    if clear_existing:
        regions.clear()
    var cw := 1.0 / float(cols)
    var ch := 1.0 / float(rows)
    var index := 0
    for row in rows:
        for col in cols:
            var n := pattern.replace("{col}", str(col)).replace("{row}", str(row)).replace("{index}", str(index))
            add_region(n, Rect2(col * cw, row * ch, cw, ch))
            index += 1
    emit_changed()

static func rect_from_pixels(pixel_rect: Rect2i, texture_size: Vector2i) -> Rect2:
    var s := Vector2(maxi(texture_size.x, 1), maxi(texture_size.y, 1))
    return Rect2(Vector2(pixel_rect.position) / s, Vector2(pixel_rect.size) / s)

# ------------------------------------------------------- undo helpers

func snapshot() -> Dictionary:
    var list: Array = []
    for r in regions:
        if r != null:
            list.append([r.region_name, r.rect])
    return {"regions": list, "inset": inset}

func restore(data: Dictionary) -> void:
    regions.clear()
    for entry in data.get("regions", []):
        var r := UVAtlasRegion.new()
        r.region_name = entry[0]
        r.rect = entry[1]
        regions.append(r)
    inset = data.get("inset", 0.0)
    emit_changed()

# ------------------------------------------------------------ validation

func validate() -> PackedStringArray:
    var problems := PackedStringArray()
    var seen := {}
    for r in regions:
        if r == null:
            problems.append("Atlas contains an empty region slot.")
            continue
        if r.region_name.is_empty():
            problems.append("A region has no name.")
        elif seen.has(r.region_name):
            problems.append("Duplicate region name '%s'." % r.region_name)
        seen[r.region_name] = true
        if r.rect.size.x <= 0.0 or r.rect.size.y <= 0.0:
            problems.append("Region '%s' has zero or negative size." % r.region_name)
        var eps := 0.0001
        if r.rect.position.x < -eps or r.rect.position.y < -eps \
                or r.rect.end.x > 1.0 + eps or r.rect.end.y > 1.0 + eps:
            problems.append("Region '%s' extends outside 0..1 UV space." % r.region_name)
    return problems
