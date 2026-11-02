@tool
extends RefCounted
class_name UVIslandMaterialBuilder

## v0.6 - material preservation.
##
## Instead of replacing the user's material with a prototype shader, we keep
## the material's own shader and only PREPEND a tiny UV transform to its
## vertex() function:
##
##   * BaseMaterial3D / StandardMaterial3D / ORMMaterial3D: the shader Godot
##     generates for that exact material is fetched from the RenderingServer
##     (this is what the editor's "Convert to ShaderMaterial" does), every
##     texture/parameter is carried over, then vertex() is patched.
##   * ShaderMaterial (text shader): the user's code is patched as-is, all
##     parameters are kept.
##
## The transform runs at the START of vertex(), i.e. on the raw mesh UV, so the
## material's own uv1_scale/offset (tiling) still applies afterwards.
## The original resources are never modified; the patched material is a copy.

const MAX_ISLANDS := 256
const MARKER_META := "uvi_patched"
const SOURCE_META := "uvi_source"
const PARAM_M := "uvi_m"
const PARAM_T := "uvi_t"
## Flip to true if your engine build only accepts PackedColorArray for vec4[].
const USE_COLOR_ARRAY := false

# ------------------------------------------------------------------ public

## Returns { "material": ShaderMaterial or null, "mode": String,
##           "warnings": PackedStringArray, "error": String }
static func build_patched(source: Material, uv_channel: int) -> Dictionary:
    var warnings := PackedStringArray()
    var src := source
    if src == null:
        src = StandardMaterial3D.new()
        warnings.append("Surface had no material; a default StandardMaterial3D was used.")

    if src is ShaderMaterial:
        return _from_shader_material(src as ShaderMaterial, uv_channel, warnings)
    if src is BaseMaterial3D:
        return _from_base_material(src as BaseMaterial3D, uv_channel, warnings)
    return {"material": null, "mode": "unsupported", "warnings": warnings,
            "error": "Unsupported material type '%s'." % src.get_class()}

static func is_patched(material: Material) -> bool:
    return material != null and material.has_meta(MARKER_META)

static func make_default_arrays() -> Array:
    var m := PackedVector4Array()
    var t := PackedVector4Array()
    m.resize(MAX_ISLANDS)
    t.resize(MAX_ISLANDS)
    return [m, t]

static func push_arrays(material: ShaderMaterial, m: PackedVector4Array, t: PackedVector4Array) -> void:
    if USE_COLOR_ARRAY:
        var mc := PackedColorArray()
        var tc := PackedColorArray()
        for v in m:
            mc.append(Color(v.x, v.y, v.z, v.w))
        for v in t:
            tc.append(Color(v.x, v.y, v.z, v.w))
        material.set_shader_parameter(PARAM_M, mc)
        material.set_shader_parameter(PARAM_T, tc)
    else:
        material.set_shader_parameter(PARAM_M, m)
        material.set_shader_parameter(PARAM_T, t)

## Best-effort albedo-like texture of a source material, for previews.
static func find_preview_texture(source: Material) -> Texture2D:
    if source is BaseMaterial3D:
        return (source as BaseMaterial3D).albedo_texture
    if source is ShaderMaterial and (source as ShaderMaterial).shader != null:
        var sm := source as ShaderMaterial
        var fallback: Texture2D = null
        for info in sm.shader.get_shader_uniform_list():
            var value = sm.get_shader_parameter(info["name"])
            if value is Texture2D:
                var n := String(info["name"]).to_lower()
                if n.contains("albedo") or n.contains("base") or n.contains("diffuse") or n.contains("color"):
                    return value
                if fallback == null:
                    fallback = value
        return fallback
    return null

# --------------------------------------------------------------- internals

static func _from_shader_material(sm: ShaderMaterial, uv_channel: int, warnings: PackedStringArray) -> Dictionary:
    if sm.shader == null:
        return {"material": null, "mode": "shader", "warnings": warnings, "error": "ShaderMaterial has no shader."}
    if sm.shader is VisualShader:
        warnings.append("VisualShader was converted to a text-shader copy; edits to the original VisualShader will not carry over until you refresh.")
    var patched := patch_shader_code(sm.shader.code, uv_channel)
    if not String(patched["error"]).is_empty():
        return {"material": null, "mode": "shader", "warnings": warnings, "error": patched["error"]}
    var out := sm.duplicate() as ShaderMaterial
    var shader := Shader.new()
    shader.code = patched["code"]
    out.shader = shader
    _finish(out, sm)
    return {"material": out, "mode": "shader", "warnings": warnings, "error": ""}

static func _from_base_material(bm: BaseMaterial3D, uv_channel: int, warnings: PackedStringArray) -> Dictionary:
    var converted := _convert_base_material(bm)
    if not String(converted["error"]).is_empty():
        warnings.append("Exact conversion failed (%s). Falling back to a simplified shader that only keeps albedo, roughness, metallic, emission and alpha." % converted["error"])
        return _fallback(bm, uv_channel, warnings)
    var out: ShaderMaterial = converted["material"]
    var patched := patch_shader_code(out.shader.code, uv_channel)
    if not String(patched["error"]).is_empty():
        warnings.append("Could not patch generated shader (%s). Using simplified fallback." % patched["error"])
        return _fallback(bm, uv_channel, warnings)
    out.shader.code = patched["code"]
    _finish(out, bm)
    if bm.uv1_triplanar or bm.uv2_triplanar:
        warnings.append("Material uses triplanar mapping; triplanar ignores mesh UVs, so island animation will have no visible effect on those textures.")
    return {"material": out, "mode": "base_material_3d", "warnings": warnings, "error": ""}

static func _finish(out: ShaderMaterial, source: Material) -> void:
    out.set_meta(MARKER_META, true)
    out.set_meta(SOURCE_META, source)
    if out.resource_name.is_empty():
        out.resource_name = (source.resource_name if not source.resource_name.is_empty() else source.get_class()) + " (UV Island)"
    var arrays := make_default_arrays()
    push_arrays(out, arrays[0], arrays[1])

## Uses the same route as the editor's "Convert to ShaderMaterial".
static func _convert_base_material(bm: BaseMaterial3D) -> Dictionary:
    var fail := func(msg: String) -> Dictionary:
        return {"material": null, "error": msg}
    for method in ["material_get_shader", "shader_get_code", "get_shader_parameter_list", "material_get_param"]:
        if not RenderingServer.has_method(method):
            return fail.call("RenderingServer.%s is not available" % method)

    var mat_rid := bm.get_rid()
    var shader_rid: RID = RenderingServer.material_get_shader(mat_rid)
    if not shader_rid.is_valid():
        return fail.call("the material's shader has not been generated yet (make sure it is visible in the viewport, then retry)")
    var code: String = RenderingServer.shader_get_code(shader_rid)
    if code.strip_edges().is_empty():
        return fail.call("generated shader code is empty")

    # Texture parameters are stored as RIDs; map them back to Texture2D objects.
    var textures := {}
    for i in BaseMaterial3D.TEXTURE_MAX:
        var tex := bm.get_texture(i as BaseMaterial3D.TextureParam)
        if tex != null:
            textures[tex.get_rid()] = tex

    var out := ShaderMaterial.new()
    var shader := Shader.new()
    shader.code = code
    out.shader = shader
    for info in RenderingServer.get_shader_parameter_list(shader_rid):
        var pname := String(info["name"])
        if pname.begins_with("__"):
            continue
        var value = RenderingServer.material_get_param(mat_rid, pname)
        if value == null:
            continue
        if typeof(value) == TYPE_RID:
            if textures.has(value):
                value = textures[value]
            else:
                continue
        out.set_shader_parameter(pname, value)
    out.render_priority = bm.render_priority
    out.next_pass = bm.next_pass
    return {"material": out, "error": ""}

static func _fallback(bm: BaseMaterial3D, uv_channel: int, warnings: PackedStringArray) -> Dictionary:
    var code := "\n".join([
        "shader_type spatial;",
        "uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;",
        "uniform vec4 albedo_color : source_color = vec4(1.0);",
        "uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);",
        "uniform float roughness = 1.0;",
        "uniform float metallic = 0.0;",
        "void fragment() {",
        "    vec4 t = texture(albedo_texture, UV) * albedo_color;",
        "    ALBEDO = t.rgb;",
        "    ALPHA = t.a;",
        "    ROUGHNESS = roughness;",
        "    METALLIC = metallic;",
        "    EMISSION = emission_color.rgb;",
        "}",
    ])
    var patched := patch_shader_code(code, uv_channel)
    if not String(patched["error"]).is_empty():
        return {"material": null, "mode": "fallback", "warnings": warnings, "error": patched["error"]}
    var out := ShaderMaterial.new()
    var shader := Shader.new()
    shader.code = patched["code"]
    out.shader = shader
    out.set_shader_parameter("albedo_color", bm.albedo_color)
    if bm.albedo_texture != null:
        out.set_shader_parameter("albedo_texture", bm.albedo_texture)
    if bm.emission_enabled:
        out.set_shader_parameter("emission_color", bm.emission)
    out.set_shader_parameter("roughness", bm.roughness)
    out.set_shader_parameter("metallic", bm.metallic)
    out.render_priority = bm.render_priority
    out.next_pass = bm.next_pass
    _finish(out, bm)
    return {"material": out, "mode": "fallback", "warnings": warnings, "error": ""}

# ------------------------------------------------------------ shader patch

## Inserts the uniforms + a UV transform at the start of vertex().
## Returns { "code": String, "error": String }
static func patch_shader_code(code: String, uv_channel: int) -> Dictionary:
    var masked := _mask_comments(code)
    var shader_type_re := RegEx.create_from_string("shader_type\\s+(\\w+)")
    var type_match := shader_type_re.search(masked)
    if type_match == null or type_match.get_string(1) != "spatial":
        return {"code": code, "error": "only spatial shaders are supported"}
    if masked.contains(PARAM_M):
        return {"code": code, "error": "shader already contains %s (already patched?)" % PARAM_M}

    var uv_name := "UV" if uv_channel == 0 else "UV2"
    var decl := "uniform vec4 %s[%d];\nuniform vec4 %s[%d];\n" % [PARAM_M, MAX_ISLANDS, PARAM_T, MAX_ISLANDS]
    var snippet := "\n".join([
        "    { // UV Island Animator",
        "        int uvi_i = int(floor(CUSTOM0.r + 0.5));",
        "        if (uvi_i >= 0 && uvi_i < %d) {" % MAX_ISLANDS,
        "            vec4 uvi_mm = %s[uvi_i] + vec4(1.0, 0.0, 0.0, 1.0);" % PARAM_M,
        "            %s = vec2(dot(uvi_mm.xy, %s), dot(uvi_mm.zw, %s)) + %s[uvi_i].xy;" % [uv_name, uv_name, uv_name, PARAM_T],
        "        }",
        "    }",
        "",
    ])

    var vertex_re := RegEx.create_from_string("void\\s+vertex\\s*\\(\\s*\\)\\s*\\{")
    var m := vertex_re.search(masked)
    var out := code
    if m != null:
        # Insert later index first so earlier indices stay valid.
        out = out.insert(m.get_end(), "\n" + snippet)
        out = out.insert(m.get_start(), decl)
    else:
        out += "\n" + decl + "void vertex() {\n" + snippet + "}\n"
    return {"code": out, "error": ""}

## Replaces comment characters with spaces (same length) so regex hits map 1:1
## onto the original string.
static func _mask_comments(code: String) -> String:
    var out := PackedStringArray()
    var i := 0
    var n := code.length()
    while i < n:
        var c := code[i]
        if c == "/" and i + 1 < n and code[i + 1] == "/":
            while i < n and code[i] != "\n":
                out.append(" ")
                i += 1
        elif c == "/" and i + 1 < n and code[i + 1] == "*":
            out.append("  ")
            i += 2
            while i < n and not (code[i] == "*" and i + 1 < n and code[i + 1] == "/"):
                out.append("\n" if code[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("  ")
                i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)
