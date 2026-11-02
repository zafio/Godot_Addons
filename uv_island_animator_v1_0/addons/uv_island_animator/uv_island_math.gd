@tool
extends RefCounted
class_name UVIslandMath

## Pure math, no engine state, so it can be unit-tested headless.
##
## Everything a track does to an island's UVs is folded into ONE 2D affine
## transform that is evaluated per vertex in the vertex shader. Offset, scale,
## rotation and atlas remapping are all affine, so per-vertex evaluation with
## linear interpolation is exactly equal to per-pixel evaluation.

const EPS := 1e-6

## Order of operations (applied to the ORIGINAL mesh UV):
##   1. optional: remap the island's UV bounding box onto an atlas region
##   2. scale + rotate about the pivot
##   3. add offset
## Rotation sign and scale semantics match v0.5 (scale multiplies sample
## coordinates, so scale 2 = texture appears half size).
static func compose(
        island_rect: Rect2,
        offset: Vector2,
        scale: Vector2,
        rotation_degrees: float,
        pivot_is_uv_center: bool,
        use_region: bool,
        region: Rect2) -> Transform2D:
    var xf := Transform2D.IDENTITY
    var current := island_rect
    if use_region:
        var k := Vector2(
            region.size.x / maxf(island_rect.size.x, EPS),
            region.size.y / maxf(island_rect.size.y, EPS))
        xf = Transform2D(Vector2(k.x, 0.0), Vector2(0.0, k.y), region.position - island_rect.position * k)
        current = region
    var pivot := Vector2(0.5, 0.5) if pivot_is_uv_center else current.get_center()
    var lin := Transform2D(-deg_to_rad(rotation_degrees), scale, 0.0, Vector2.ZERO)
    xf = Transform2D(0.0, pivot) * lin * Transform2D(0.0, -pivot) * xf
    xf = Transform2D(0.0, offset) * xf
    return xf

## Packed as deltas from identity so an all-zero uniform array == "no change".
## m = (x.x - 1, y.x, x.y, y.y - 1), t = (origin.x, origin.y, 0, 0)
static func pack(xf: Transform2D) -> Array[Vector4]:
    return [
        Vector4(xf.x.x - 1.0, xf.y.x, xf.x.y, xf.y.y - 1.0),
        Vector4(xf.origin.x, xf.origin.y, 0.0, 0.0),
    ]

## CPU reference of what the vertex shader does (used by the tests).
static func apply_packed(m: Vector4, t: Vector4, uv: Vector2) -> Vector2:
    var mm := m + Vector4(1.0, 0.0, 0.0, 1.0)
    return Vector2(mm.x * uv.x + mm.y * uv.y, mm.z * uv.x + mm.w * uv.y) + Vector2(t.x, t.y)
