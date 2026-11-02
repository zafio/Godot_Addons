@tool
extends RefCounted
class_name UVIslandKeyBuilder

## v0.9 - builds AnimationPlayer tracks/keys for an island in one step.
##
## A "plan" is a list of key dictionaries:
##   { "path": NodePath, "time": float, "value": Variant, "discrete": bool }
## apply_plan() writes it into an Animation and records what it did inside the
## plan so revert_plan() can undo it exactly (used by the dock's UndoRedo).

enum Template { SCROLL, PULSE, ROTATE, FLIPBOOK, SNAPSHOT }

const TEMPLATE_NAMES := ["Scroll (offset loop)", "Pulse (scale)", "Rotate", "Atlas flipbook", "Snapshot current values"]

## Path of a property on the track, relative to the AnimationPlayer's root node.
static func property_path(player: AnimationPlayer, track: UVIslandTrack, property: String) -> NodePath:
    var root := player.get_node_or_null(player.root_node)
    if root == null:
        return NodePath()
    return NodePath("%s:%s" % [root.get_path_to(track), property])

## params (all optional):
##   length: float = 1.0       direction: Vector2 = (1,0)   amount: float = 1.0
##   fps: float = 12.0         regions: PackedStringArray   time: float (snapshot)
static func build_plan(template: int, player: AnimationPlayer, track: UVIslandTrack, params: Dictionary = {}) -> Array[Dictionary]:
    var plan: Array[Dictionary] = []
    var length: float = maxf(float(params.get("length", 1.0)), 0.01)
    var amount: float = float(params.get("amount", 1.0))
    var direction: Vector2 = params.get("direction", Vector2.RIGHT)

    match template:
        Template.SCROLL:
            var p := property_path(player, track, "offset")
            plan.append(_key(p, 0.0, track.offset, false))
            plan.append(_key(p, length, track.offset + direction * amount, false))
        Template.PULSE:
            var p := property_path(player, track, "scale")
            plan.append(_key(p, 0.0, track.scale, false))
            plan.append(_key(p, length * 0.5, track.scale * amount, false))
            plan.append(_key(p, length, track.scale, false))
        Template.ROTATE:
            var p := property_path(player, track, "rotation_degrees")
            plan.append(_key(p, 0.0, track.rotation_degrees, false))
            plan.append(_key(p, length, track.rotation_degrees + 360.0 * signf(amount if amount != 0.0 else 1.0), false))
        Template.FLIPBOOK:
            var names: PackedStringArray = params.get("regions", PackedStringArray())
            if names.is_empty():
                var atlas := track.get_effective_atlas()
                if atlas != null:
                    names = atlas.get_region_names()
            var fps: float = maxf(float(params.get("fps", 12.0)), 0.1)
            if not names.is_empty():
                plan.append(_key(property_path(player, track, "use_atlas"), 0.0, true, true))
                var p := property_path(player, track, "atlas_region")
                for i in names.size():
                    plan.append(_key(p, float(i) / fps, names[i], true))
        Template.SNAPSHOT:
            var t: float = float(params.get("time", 0.0))
            plan.append(_key(property_path(player, track, "offset"), t, track.offset, false))
            plan.append(_key(property_path(player, track, "scale"), t, track.scale, false))
            plan.append(_key(property_path(player, track, "rotation_degrees"), t, track.rotation_degrees, false))
            if track.use_atlas:
                plan.append(_key(property_path(player, track, "use_atlas"), t, true, true))
                if not track.atlas_region.is_empty():
                    plan.append(_key(property_path(player, track, "atlas_region"), t, track.atlas_region, true))
    return plan

## Length the animation needs to contain the plan (last key + one frame for flipbooks).
static func plan_length(plan: Array[Dictionary], template: int, fps: float = 12.0) -> float:
    var last := 0.0
    for k in plan:
        last = maxf(last, float(k["time"]))
    if template == Template.FLIPBOOK:
        last += 1.0 / maxf(fps, 0.1)
    return last

## Returns { "animation": Animation, "created": bool, "library": AnimationLibrary }
static func ensure_animation(player: AnimationPlayer, anim_name: String) -> Dictionary:
    var lib: AnimationLibrary = player.get_animation_library("")
    if lib == null:
        lib = AnimationLibrary.new()
        player.add_animation_library("", lib)
    if lib.has_animation(anim_name):
        return {"animation": lib.get_animation(anim_name), "created": false, "library": lib}
    var anim := Animation.new()
    lib.add_animation(anim_name, anim)
    return {"animation": anim, "created": true, "library": lib}

static func apply_plan(anim: Animation, plan: Array[Dictionary]) -> void:
    for k in plan:
        var path: NodePath = k["path"]
        var idx := anim.find_track(path, Animation.TYPE_VALUE)
        k["created_track"] = false
        if idx == -1:
            idx = anim.add_track(Animation.TYPE_VALUE)
            anim.track_set_path(idx, path)
            k["created_track"] = true
            if k["discrete"]:
                anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_NEAREST)
                anim.value_track_set_update_mode(idx, Animation.UPDATE_DISCRETE)
            else:
                anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_LINEAR)
        var existing := anim.track_find_key(idx, k["time"], Animation.FIND_MODE_APPROX)
        k["had_key"] = existing != -1
        if existing != -1:
            k["prev_value"] = anim.track_get_key_value(idx, existing)
            anim.track_set_key_value(idx, existing, k["value"])
        else:
            anim.track_insert_key(idx, k["time"], k["value"])

static func revert_plan(anim: Animation, plan: Array[Dictionary]) -> void:
    for i in range(plan.size() - 1, -1, -1):
        var k := plan[i]
        var idx := anim.find_track(k["path"], Animation.TYPE_VALUE)
        if idx == -1:
            continue
        var key_idx := anim.track_find_key(idx, k["time"], Animation.FIND_MODE_APPROX)
        if key_idx != -1:
            if k.get("had_key", false):
                anim.track_set_key_value(idx, key_idx, k["prev_value"])
            else:
                anim.track_remove_key(idx, key_idx)
        if k.get("created_track", false) and anim.track_get_key_count(idx) == 0:
            anim.remove_track(idx)

static func _key(path: NodePath, time: float, value: Variant, discrete: bool) -> Dictionary:
    return {"path": path, "time": time, "value": value, "discrete": discrete}
