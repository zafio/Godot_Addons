@tool
extends Node3D
class_name UVIslandAnimator

## Owns the link between a MeshInstance3D, its detected islands, the patched
## materials, and the UVIslandTrack children.
##
## v1.0: islands and patched materials are PERSISTED in the scene, so it works
## after reloading the scene and at runtime (v0.5 lost everything on reload).

signal islands_changed

@export_node_path("MeshInstance3D") var mesh_path: NodePath
@export_range(0, 1, 1) var uv_channel: int = 0
## Shared atlas for all tracks (a track can override it).
@export var atlas: UVAtlasPreset:
    set(value):
        if atlas != null and atlas.changed.is_connected(_on_atlas_changed):
            atlas.changed.disconnect(_on_atlas_changed)
        atlas = value
        if atlas != null:
            atlas.changed.connect(_on_atlas_changed)
        _on_atlas_changed()
## Saved with the scene (lightweight: no face lists).
@export var islands: Array[UVIsland] = []:
    set(value):
        islands = value
        islands_changed.emit()

const META_RESTORE := "uvi_restore"

var last_warnings: PackedStringArray = PackedStringArray()

var _mesh_instance: MeshInstance3D
var _patched: Dictionary = {}       # surface -> ShaderMaterial
var _arrays: Dictionary = {}        # surface -> [PackedVector4Array m, PackedVector4Array t]
var _dirty: Dictionary = {}         # island_id -> true
var _flush_queued := false

func _ready() -> void:
    refresh_runtime()

## Re-resolves mesh + patched materials and pushes every track. Cheap.
func refresh_runtime() -> void:
    _mesh_instance = get_node_or_null(mesh_path) as MeshInstance3D
    _patched.clear()
    _arrays.clear()
    if _mesh_instance == null or _mesh_instance.mesh == null:
        return
    for s in _mesh_instance.mesh.get_surface_count():
        var mat := _mesh_instance.get_surface_override_material(s)
        if mat is ShaderMaterial and UVIslandMaterialBuilder.is_patched(mat):
            _patched[s] = mat
            _arrays[s] = UVIslandMaterialBuilder.make_default_arrays()
    for track in get_tracks():
        _write_track(track)
    _push_all()

# ------------------------------------------------------------------ lookup

func set_mesh_instance(node: MeshInstance3D) -> void:
    mesh_path = get_path_to(node)
    _mesh_instance = node

func get_mesh_instance() -> MeshInstance3D:
    if _mesh_instance == null:
        _mesh_instance = get_node_or_null(mesh_path) as MeshInstance3D
    return _mesh_instance

func get_island(id: int) -> UVIsland:
    for island in islands:
        if island != null and island.island_id == id:
            return island
    return null

func get_tracks() -> Array[UVIslandTrack]:
    var out: Array[UVIslandTrack] = []
    for c in get_children():
        if c is UVIslandTrack:
            out.append(c)
    return out

func get_track(id: int) -> UVIslandTrack:
    for t in get_tracks():
        if t.island_id == id:
            return t
    return null

func is_mesh_baked() -> bool:
    var mi := get_mesh_instance()
    return mi != null and UVIslandMeshBaker.is_baked(mi.mesh)

func get_preview_texture(surface: int) -> Texture2D:
    var mi := get_mesh_instance()
    if mi == null or mi.mesh == null:
        return null
    var mat := mi.get_surface_override_material(surface)
    if mat != null and mat.has_meta(UVIslandMaterialBuilder.SOURCE_META):
        var t := UVIslandMaterialBuilder.find_preview_texture(mat.get_meta(UVIslandMaterialBuilder.SOURCE_META))
        if t != null:
            return t
    return UVIslandMaterialBuilder.find_preview_texture(mi.get_active_material(surface))

# ------------------------------------------------------------------ tracks

## Non-destructive: returns NEW, unparented tracks for islands that have none.
## The caller adds them (the dock does so through UndoRedo).
func make_missing_tracks(for_islands: Array[UVIsland] = []) -> Array[UVIslandTrack]:
    var source := for_islands if not for_islands.is_empty() else islands
    var existing := {}
    for t in get_tracks():
        existing[t.island_id] = true
    var out: Array[UVIslandTrack] = []
    for island in source:
        if not existing.has(island.island_id):
            var track := UVIslandTrack.new()
            track.name = island.name
            track.island_id = island.island_id
            out.append(track)
    return out

func queue_track_update(track: UVIslandTrack) -> void:
    _dirty[track.island_id] = true
    if not _flush_queued:
        _flush_queued = true
        call_deferred("_flush")

func _on_atlas_changed() -> void:
    for t in get_tracks():
        _dirty[t.island_id] = true
        t.notify_property_list_changed()
    if is_inside_tree() and not _flush_queued:
        _flush_queued = true
        call_deferred("_flush")

func _flush() -> void:
    _flush_queued = false
    var touched := {}
    for id in _dirty.keys():
        var t := get_track(id)
        if t != null:
            var s := _write_track(t)
            if s >= 0:
                touched[s] = true
    _dirty.clear()
    for s in touched.keys():
        _push(s)

## Returns the surface index written to, or -1.
func _write_track(track: UVIslandTrack) -> int:
    var island := get_island(track.island_id)
    if island == null or not _arrays.has(island.surface):
        return -1
    if island.island_id < 0 or island.island_id >= UVIslandMaterialBuilder.MAX_ISLANDS:
        return -1
    var packed := UVIslandMath.pack(track.compute_transform(island))
    var arrs: Array = _arrays[island.surface]
    var m: PackedVector4Array = arrs[0]
    var t: PackedVector4Array = arrs[1]
    m[island.island_id] = packed[0]
    t[island.island_id] = packed[1]
    arrs[0] = m
    arrs[1] = t
    return island.surface

func _push(surface: int) -> void:
    var mat: ShaderMaterial = _patched.get(surface)
    if mat == null or not _arrays.has(surface):
        return
    var arrs: Array = _arrays[surface]
    UVIslandMaterialBuilder.push_arrays(mat, arrs[0], arrs[1])

func _push_all() -> void:
    for s in _patched.keys():
        _push(s)

# --------------------------------------------------------------- materials

## Builds patched copies of each affected surface's CURRENT material and puts
## them in the MeshInstance3D's surface override slots. The mesh's own
## materials and any user-made overrides are remembered and restorable.
## Returns warnings; last_warnings is also updated.
func install_materials() -> PackedStringArray:
    var warnings := PackedStringArray()
    var mi := get_mesh_instance()
    if mi == null or mi.mesh == null:
        warnings.append("No mesh assigned.")
        last_warnings = warnings
        return warnings
    if not UVIslandMeshBaker.is_baked(mi.mesh):
        warnings.append("Mesh has no baked island IDs. Bake first (materials were NOT changed).")
        last_warnings = warnings
        return warnings
    if islands.size() > UVIslandMaterialBuilder.MAX_ISLANDS:
        warnings.append("More than %d islands; materials were NOT changed." % UVIslandMaterialBuilder.MAX_ISLANDS)
        last_warnings = warnings
        return warnings

    var surfaces_with_islands := {}
    for island in islands:
        surfaces_with_islands[island.surface] = true

    var restore: Dictionary = {}
    if mi.has_meta(META_RESTORE):
        restore = (mi.get_meta(META_RESTORE) as Dictionary).duplicate()

    _patched.clear()
    _arrays.clear()
    for s in mi.mesh.get_surface_count():
        if not surfaces_with_islands.has(s):
            continue
        var current := mi.get_surface_override_material(s)
        var source: Material
        if current != null and UVIslandMaterialBuilder.is_patched(current):
            source = restore.get(s, null)
            if source == null:
                source = mi.mesh.surface_get_material(s)
        else:
            restore[s] = current
            source = current if current != null else mi.mesh.surface_get_material(s)

        var built := UVIslandMaterialBuilder.build_patched(source, uv_channel)
        for w in built["warnings"]:
            warnings.append("Surface %d: %s" % [s, w])
        if built["material"] == null:
            warnings.append("Surface %d: %s (left unchanged)" % [s, built["error"]])
            continue
        mi.set_surface_override_material(s, built["material"])
        _patched[s] = built["material"]
        _arrays[s] = UVIslandMaterialBuilder.make_default_arrays()

    mi.set_meta(META_RESTORE, restore)
    for track in get_tracks():
        _write_track(track)
    _push_all()
    last_warnings = warnings
    return warnings

## Puts back whatever override each surface had before install_materials().
func restore_materials() -> void:
    var mi := get_mesh_instance()
    if mi == null or mi.mesh == null:
        return
    var restore: Dictionary = {}
    if mi.has_meta(META_RESTORE):
        restore = mi.get_meta(META_RESTORE)
    for s in mi.mesh.get_surface_count():
        var current := mi.get_surface_override_material(s)
        if current != null and UVIslandMaterialBuilder.is_patched(current):
            mi.set_surface_override_material(s, restore.get(s, null))
    mi.remove_meta(META_RESTORE)
    _patched.clear()
    _arrays.clear()

func refresh_materials() -> PackedStringArray:
    return install_materials()

# ------------------------------------------------- v0.5-compatible helpers

func set_island_offset(id: int, value: Vector2) -> void:
    var t := get_track(id)
    if t != null:
        t.offset = value

func set_island_scale(id: int, value: Vector2) -> void:
    var t := get_track(id)
    if t != null:
        t.scale = value

func set_island_rotation(id: int, degrees: float) -> void:
    var t := get_track(id)
    if t != null:
        t.rotation_degrees = degrees

func set_island_atlas(id: int, atlas_min: Vector2, atlas_max: Vector2) -> void:
    var t := get_track(id)
    if t != null:
        t.atlas_region = ""
        t.atlas_min = atlas_min
        t.atlas_max = atlas_max
        t.use_atlas = true

func set_island_atlas_region(id: int, region_name: String) -> void:
    var t := get_track(id)
    if t != null:
        t.atlas_region = region_name
        t.use_atlas = true
