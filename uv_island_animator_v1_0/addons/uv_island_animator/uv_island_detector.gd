@tool
extends RefCounted
class_name UVIslandDetector

## Finds UV islands (connected UV shells) per surface.
##
## Two triangles belong to the same island when they share an EDGE whose two
## endpoints have the same 3D position AND the same UV. Keying on
## (position, uv) instead of raw vertex index means:
##   - vertices split for hard normals / tangents / vertex colors do not break
##     an island apart;
##   - mirrored, overlapping shells that live at different 3D positions stay
##     separate islands (v0.5 merged them).
## Runs in O(triangles) using hashing (v0.5 was O(triangles^2)).

const POS_QUANT := 10000.0
const UV_QUANT := 100000.0

static func detect(mesh: Mesh, uv_channel: int = 0) -> Array[UVIsland]:
    return detect_with_report(mesh, uv_channel)["islands"]

## Returns { "islands": Array[UVIsland], "warnings": PackedStringArray }
static func detect_with_report(mesh: Mesh, uv_channel: int = 0) -> Dictionary:
    var islands: Array[UVIsland] = []
    var warnings := PackedStringArray()
    if mesh == null:
        return {"islands": islands, "warnings": warnings}

    var next_id := 0
    for surface in mesh.get_surface_count():
        if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
            warnings.append("Surface %d is not a triangle list; skipped." % surface)
            continue

        var arrays := mesh.surface_get_arrays(surface)
        var verts = arrays[Mesh.ARRAY_VERTEX]
        var uvs = arrays[Mesh.ARRAY_TEX_UV if uv_channel == 0 else Mesh.ARRAY_TEX_UV2]
        var indices = arrays[Mesh.ARRAY_INDEX]
        if verts == null or verts.is_empty():
            warnings.append("Surface %d has no vertices; skipped." % surface)
            continue
        if uvs == null or uvs.is_empty():
            warnings.append("Surface %d has no UV%d data; skipped." % [surface, uv_channel])
            continue

        var vcount: int = verts.size()
        var has_index: bool = indices != null and not indices.is_empty()
        var corner_count: int = indices.size() if has_index else vcount
        var tri_count: int = corner_count / 3
        if tri_count <= 0:
            continue

        # 1. Give every distinct (position, uv) pair a compact id.
        var key_to_id := {}
        var vid := PackedInt32Array()
        vid.resize(vcount)
        for i in vcount:
            var p: Vector3 = verts[i]
            var t: Vector2 = uvs[i]
            var key := [
                Vector3i(roundi(p.x * POS_QUANT), roundi(p.y * POS_QUANT), roundi(p.z * POS_QUANT)),
                Vector2i(roundi(t.x * UV_QUANT), roundi(t.y * UV_QUANT)),
            ]
            if not key_to_id.has(key):
                key_to_id[key] = key_to_id.size()
            vid[i] = key_to_id[key]

        # 2. Union triangles that share an edge.
        var parent := PackedInt32Array()
        parent.resize(tri_count)
        for i in tri_count:
            parent[i] = i

        var edge_owner := {}
        for f in tri_count:
            var k := PackedInt32Array()
            for c in 3:
                var p_index := f * 3 + c
                k.append(vid[indices[p_index] if has_index else p_index])
            for e in 3:
                var a := k[e]
                var b := k[(e + 1) % 3]
                if a == b:
                    continue
                var ek: int = (mini(a, b) << 32) | maxi(a, b)
                if edge_owner.has(ek):
                    _union(parent, f, edge_owner[ek])
                else:
                    edge_owner[ek] = f

        # 3. Collect groups in order of their lowest triangle (deterministic).
        var groups := {}
        for f in tri_count:
            var r := _find(parent, f)
            if not groups.has(r):
                groups[r] = PackedInt32Array()
            groups[r].append(f)

        for faces in groups.values():
            var island := UVIsland.new()
            island.name = "Island_%d" % next_id
            island.surface = surface
            island.island_id = next_id
            island.triangle_count = faces.size()
            island.face_indices = faces

            var seen := {}
            var min_uv := Vector2(INF, INF)
            var max_uv := Vector2(-INF, -INF)
            for f in faces:
                for c in 3:
                    var p_index := f * 3 + c
                    var vi: int = indices[p_index] if has_index else p_index
                    seen[vi] = true
                    var uv: Vector2 = uvs[vi]
                    min_uv = Vector2(minf(min_uv.x, uv.x), minf(min_uv.y, uv.y))
                    max_uv = Vector2(maxf(max_uv.x, uv.x), maxf(max_uv.y, uv.y))
            island.vertex_count = seen.size()
            island.uv_min = min_uv
            island.uv_max = max_uv
            islands.append(island)
            next_id += 1

    return {"islands": islands, "warnings": warnings}

static func _find(parent: PackedInt32Array, x: int) -> int:
    var root := x
    while parent[root] != root:
        root = parent[root]
    var p := x
    while parent[p] != root:
        var nxt := parent[p]
        parent[p] = root
        p = nxt
    return root

static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
    var ra := _find(parent, a)
    var rb := _find(parent, b)
    if ra != rb:
        parent[rb] = ra
