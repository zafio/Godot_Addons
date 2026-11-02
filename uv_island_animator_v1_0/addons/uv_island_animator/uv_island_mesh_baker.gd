@tool
extends RefCounted
class_name UVIslandMeshBaker

## Writes each vertex's island id into Mesh.ARRAY_CUSTOM0 (R_FLOAT).
## v1.0 changes:
##   - the id is stored as a plain float integer (no /255), -1 = "no island";
##   - vertices shared by two islands are SPLIT (duplicated) instead of
##     refusing to bake;
##   - all other arrays, blend shapes, bone weights (4 or 8), surface names,
##     materials and custom_aabb are preserved;
##   - the baked mesh is tagged with metadata so the rest of the addon can
##     tell a v1 bake from foreign CUSTOM0 data.
## NOTE: mesh LODs are not carried over (they would be invalid after a split).

const META_KEY := "uv_island_animator"
const FORMAT_VERSION := 2
# ARRAY_CUSTOM_R_FLOAT is an ArrayCustomFormat value; it is shifted into the
# format bits of custom channel 0. (v0.5 used a constant that does not exist.)
const CUSTOM0_FORMAT := Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT

const _VERTEX_STREAMS := [
    Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR,
    Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2,
    Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3,
    Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS,
]

static func is_baked(mesh: Mesh) -> bool:
    if mesh == null or not mesh.has_meta(META_KEY):
        return false
    var d = mesh.get_meta(META_KEY)
    return d is Dictionary and int(d.get("version", 0)) >= FORMAT_VERSION

static func get_bake_info(mesh: Mesh) -> Dictionary:
    if is_baked(mesh):
        return mesh.get_meta(META_KEY)
    return {}

## True if some surface already has CUSTOM0 data that was not written by us.
static func has_foreign_custom0(mesh: Mesh) -> bool:
    if mesh == null or is_baked(mesh):
        return false
    for s in mesh.get_surface_count():
        if mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_CUSTOM0 != 0:
            return true
    return false

## Returns { "mesh": ArrayMesh or null, "errors": PackedStringArray,
##           "split_vertices": int }
static func bake(mesh: Mesh, islands: Array[UVIsland], uv_channel: int = 0, overwrite_custom0: bool = false) -> Dictionary:
    var errors := PackedStringArray()
    var result := {"mesh": null, "errors": errors, "split_vertices": 0}
    if mesh == null:
        errors.append("No mesh.")
        return result
    if islands.is_empty():
        errors.append("No islands detected. Run detection first.")
        return result
    if has_foreign_custom0(mesh) and not overwrite_custom0:
        errors.append("The mesh already has CUSTOM0 data that this addon did not write. Enable 'Overwrite existing CUSTOM0' to replace it.")
        return result

    var src_am := mesh as ArrayMesh
    var out := ArrayMesh.new()
    out.resource_name = mesh.resource_name
    var blend_count := 0
    if src_am != null:
        blend_count = src_am.get_blend_shape_count()
        for i in blend_count:
            out.add_blend_shape(src_am.get_blend_shape_name(i))
        out.blend_shape_mode = src_am.blend_shape_mode
        out.custom_aabb = src_am.custom_aabb

    var split_total := 0
    var vertex_counts := PackedInt32Array()

    for surface in mesh.get_surface_count():
        var arrays: Array = mesh.surface_get_arrays(surface)
        var format := mesh.surface_get_format(surface)
        var verts = arrays[Mesh.ARRAY_VERTEX]
        if verts == null or verts.is_empty():
            errors.append("Surface %d has no vertices." % surface)
            return result
        var vcount: int = verts.size()

        var indices = arrays[Mesh.ARRAY_INDEX]
        var has_index: bool = indices != null and not indices.is_empty()
        var new_indices := PackedInt32Array()
        if has_index:
            new_indices = indices.duplicate()

        var owner := PackedInt32Array()
        owner.resize(vcount)
        owner.fill(-1)
        var extra_src := PackedInt32Array()
        var extra_owner := PackedInt32Array()
        var copy_map := {}

        for island in islands:
            if island.surface != surface:
                continue
            for face in island.face_indices:
                for c in 3:
                    var p: int = face * 3 + c
                    var vi: int = new_indices[p] if has_index else p
                    if vi < 0 or vi >= vcount:
                        errors.append("Island %d references a vertex outside surface %d. Mesh changed since detection? Re-run detection." % [island.island_id, surface])
                        return result
                    if owner[vi] == -1:
                        owner[vi] = island.island_id
                    elif owner[vi] != island.island_id:
                        var key := Vector2i(vi, island.island_id)
                        if not copy_map.has(key):
                            copy_map[key] = vcount + extra_src.size()
                            extra_src.append(vi)
                            extra_owner.append(island.island_id)
                        new_indices[p] = copy_map[key]

        # Duplicate vertex data for split vertices (stride-generic).
        var extra := extra_src.size()
        if extra > 0:
            for stream in _VERTEX_STREAMS:
                _append_copies(arrays, stream, vcount, extra_src)
            if has_index:
                arrays[Mesh.ARRAY_INDEX] = new_indices
        split_total += extra

        var custom := PackedFloat32Array()
        custom.resize(vcount + extra)
        for i in vcount:
            custom[i] = float(owner[i])
        for i in extra:
            custom[vcount + i] = float(extra_owner[i])
        arrays[Mesh.ARRAY_CUSTOM0] = custom

        var blend_arrays: Array = []
        if blend_count > 0:
            blend_arrays = mesh.surface_get_blend_shape_arrays(surface)
            if extra > 0:
                for bs in blend_arrays:
                    for stream in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT]:
                        _append_copies(bs, stream, vcount, extra_src)

        var flags := CUSTOM0_FORMAT
        flags |= format & (Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS | Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
        for shift in [Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT, Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT]:
            flags |= format & (Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift)

        out.add_surface_from_arrays(mesh.surface_get_primitive_type(surface), arrays, blend_arrays, {}, flags)
        var out_index := out.get_surface_count() - 1
        out.surface_set_material(out_index, mesh.surface_get_material(surface))
        if src_am != null:
            out.surface_set_name(out_index, src_am.surface_get_name(surface))
        vertex_counts.append(vcount + extra)

    out.set_meta(META_KEY, {
        "version": FORMAT_VERSION,
        "uv_channel": uv_channel,
        "island_count": islands.size(),
        "surface_vertex_counts": vertex_counts,
    })
    result["mesh"] = out
    result["split_vertices"] = split_total
    return result

static func _append_copies(arrays: Array, stream: int, vcount: int, sources: PackedInt32Array) -> void:
    if stream >= arrays.size():
        return
    var arr = arrays[stream]
    if arr == null or arr.is_empty() or vcount <= 0:
        return
    var stride: int = arr.size() / vcount
    if stride <= 0:
        return
    for src in sources:
        arr.append_array(arr.slice(src * stride, (src + 1) * stride))
    arrays[stream] = arr
