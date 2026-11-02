@tool
extends RefCounted
class_name UVIslandValidator

## v1.0 - one place that answers "will this setup actually work?".
## Each result: { "level": "error"|"warning"|"info", "message": String }

static func validate(animator: UVIslandAnimator) -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    if animator == null:
        out.append(_r("error", "No UVIslandAnimator selected."))
        return out

    var mi := animator.get_mesh_instance()
    if mi == null:
        out.append(_r("error", "mesh_path does not point to a MeshInstance3D."))
        return out
    if mi.mesh == null:
        out.append(_r("error", "The MeshInstance3D has no mesh."))
        return out
    var mesh := mi.mesh

    # ---- islands / bake state
    if animator.islands.is_empty():
        out.append(_r("error", "No islands stored. Run detection and set up the animator."))
    if animator.islands.size() > UVIslandMaterialBuilder.MAX_ISLANDS:
        out.append(_r("error", "%d islands exceed the limit of %d." % [animator.islands.size(), UVIslandMaterialBuilder.MAX_ISLANDS]))

    if not UVIslandMeshBaker.is_baked(mesh):
        out.append(_r("error", "Mesh has no island IDs baked by v1.0 (CUSTOM0). Bake it."))
    else:
        var info := UVIslandMeshBaker.get_bake_info(mesh)
        if int(info.get("uv_channel", 0)) != animator.uv_channel:
            out.append(_r("error", "Mesh was baked for UV%d but the animator uses UV%d." % [info.get("uv_channel", 0), animator.uv_channel]))
        if int(info.get("island_count", -1)) != animator.islands.size():
            out.append(_r("warning", "Island count (%d) differs from the baked mesh (%d). Re-detect and re-bake." % [animator.islands.size(), info.get("island_count", -1)]))
        var counts: PackedInt32Array = info.get("surface_vertex_counts", PackedInt32Array())
        if counts.size() != mesh.get_surface_count():
            out.append(_r("error", "Surface count changed since baking. Re-bake."))
        else:
            for s in counts.size():
                var arrays := mesh.surface_get_arrays(s)
                var v = arrays[Mesh.ARRAY_VERTEX]
                if v != null and v.size() != counts[s]:
                    out.append(_r("error", "Surface %d vertex count changed since baking. Re-bake." % s))

    # ---- island geometry
    var uv_outside := 0
    for island in animator.islands:
        if island.surface < 0 or island.surface >= mesh.get_surface_count():
            out.append(_r("error", "%s refers to missing surface %d." % [island.name, island.surface]))
        var size := island.uv_max - island.uv_min
        if size.x <= 0.00001 or size.y <= 0.00001:
            out.append(_r("warning", "%s has a degenerate UV bounding box; atlas remapping will be unreliable for it." % island.name))
        if island.uv_min.x < -0.0001 or island.uv_min.y < -0.0001 or island.uv_max.x > 1.0001 or island.uv_max.y > 1.0001:
            uv_outside += 1
    if uv_outside > 0:
        out.append(_r("info", "%d island(s) have UVs outside 0..1 (tiling). Atlas regions assume 0..1." % uv_outside))

    # ---- materials
    var surfaces := {}
    for island in animator.islands:
        surfaces[island.surface] = true
    for s in surfaces.keys():
        if s < 0 or s >= mesh.get_surface_count():
            continue
        var mat := mi.get_surface_override_material(s)
        if mat == null or not UVIslandMaterialBuilder.is_patched(mat):
            out.append(_r("warning", "Surface %d has no patched material. Use 'Install Materials'." % s))
        else:
            var src = mat.get_meta(UVIslandMaterialBuilder.SOURCE_META, null)
            if src is BaseMaterial3D and (src.uv1_triplanar or src.uv2_triplanar):
                out.append(_r("warning", "Surface %d uses triplanar mapping; UV animation will not be visible." % s))
            if animator.uv_channel == 1 and src is BaseMaterial3D:
                out.append(_r("info", "Surface %d: UV1 (second channel) only affects maps set to use UV2 in the material." % s))

    # ---- tracks
    var seen := {}
    for t in animator.get_tracks():
        if seen.has(t.island_id):
            out.append(_r("error", "Two tracks control island %d ('%s' and '%s')." % [t.island_id, seen[t.island_id], t.name]))
        seen[t.island_id] = t.name
        if animator.get_island(t.island_id) == null:
            out.append(_r("error", "Track '%s' refers to island %d which does not exist." % [t.name, t.island_id]))
        if t.use_atlas and not t.atlas_region.is_empty():
            var atlas := t.get_effective_atlas()
            if atlas == null:
                out.append(_r("error", "Track '%s' uses region '%s' but no atlas is assigned." % [t.name, t.atlas_region]))
            elif not atlas.has_region(t.atlas_region):
                out.append(_r("error", "Track '%s': atlas has no region '%s'." % [t.name, t.atlas_region]))
    var missing := 0
    for island in animator.islands:
        if not seen.has(island.island_id):
            missing += 1
    if missing > 0:
        out.append(_r("info", "%d island(s) have no track yet." % missing))

    # ---- atlas
    if animator.atlas != null:
        for p in animator.atlas.validate():
            out.append(_r("warning", "Atlas: " + p))

    if out.is_empty():
        out.append(_r("info", "No problems found."))
    return out

## Checks AnimationPlayer animations for paths that no longer resolve.
static func validate_animation_paths(player: AnimationPlayer) -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    var root := player.get_node_or_null(player.root_node)
    if root == null:
        out.append(_r("error", "AnimationPlayer root_node is invalid."))
        return out
    for anim_name in player.get_animation_list():
        var anim := player.get_animation(anim_name)
        for i in anim.get_track_count():
            var path := anim.track_get_path(i)
            var node := root.get_node_or_null(NodePath(path.get_concatenated_names()))
            if node == null:
                out.append(_r("warning", "Animation '%s' track %d: node '%s' not found." % [anim_name, i, path.get_concatenated_names()]))
            elif node is UVIslandTrack:
                var prop := path.get_concatenated_subnames()
                if node.get(prop) == null and prop != "atlas_override":
                    out.append(_r("warning", "Animation '%s': UVIslandTrack has no property '%s'." % [anim_name, prop]))
    return out

static func _r(level: String, message: String) -> Dictionary:
    return {"level": level, "message": message}
