class_name TrackRibbon
extends MeshInstance3D
## Полоса трека в мире (GL-К6, docs/contracts/goals.md): весь FlightTrack одной полупрозрачной лентой
## постоянной экранной ширины, цвет по вертикальной скорости. Настройки — configs/goals/track.json.
## Один меш, одна поверхность, один draw call; лента разворачивается к камере в track_ribbon.gdshader.

const SHADER := preload("res://scripts/goals/track_ribbon.gdshader")
const CONFIG := "goals/track"

## Последние построенные точки (после прореживания): мировые позиции и цвет (sRGB, альфа) — для тестов.
var points := PackedVector3Array()
var point_colors := PackedColorArray()
## Индексы исходного трека, оставшиеся после прореживания.
var kept := PackedInt32Array()

var _cfg: Dictionary = {}


## Строит меш один раз. latlon_fn: Callable(lat, lon) -> Vector2(x, z); позиция точки = (x, alt_m, z).
func set_track(track: FlightTrack, latlon_fn: Callable) -> void:
	_cfg = Config.get_config(CONFIG)
	points = PackedVector3Array()
	point_colors = PackedColorArray()
	kept = PackedInt32Array()
	mesh = null
	if track == null or track.size() < 2:
		return
	var n := track.size()
	var all := PackedVector3Array()
	all.resize(n)
	for i in n:
		var xz: Vector2 = latlon_fn.call(track.lat[i], track.lon[i])
		all[i] = Vector3(xz.x, track.alt_m[i], xz.y)
	kept = simplify(all, int(_cfg.get("max_points", 2000)), float(_cfg.get("simplify_min_m", 1.0)))
	var window := float(_cfg.get("vs_window_s", 5.0))
	for i in kept:
		points.append(all[i])
		point_colors.append(vs_color(track.vertical_speed_ms(i, window), _cfg))
	_build_mesh()


## Цвет участка по вертикальной скорости w, м/с (sRGB + непрозрачность), правила GL-К6.
static func vs_color(w: float, cfg: Dictionary) -> Color:
	var dead := float(cfg.get("dead_band_ms", 0.5))
	var full := float(cfg.get("climb_full_ms", 3.5)) if w >= 0.0 else float(cfg.get("sink_full_ms", 3.5))
	var target := _color(cfg.get("color_climb" if w >= 0.0 else "color_sink", []),
			Color(0.95, 0.12, 0.08, 0.85) if w >= 0.0 else Color(0.1, 0.35, 0.95, 0.85))
	var zero := _color(cfg.get("color_zero", []), Color(0.9, 0.9, 0.9))
	zero.a = float(cfg.get("alpha_zero", 0.12))
	var f := clampf((absf(w) - dead) / maxf(full - dead, 1e-3), 0.0, 1.0)
	return zero.lerp(target, f)


## Прореживание Дугласа—Пекера: каждой точке — значимость (отклонение при разбиении, не больше
## значимости родителя, поэтому отбор лучших совпадает с ДП при некотором допуске). Оставляются концы
## и точки со значимостью > min_tol_m; больше max_points — max_points самых значимых.
static func simplify(pts: PackedVector3Array, max_points: int, min_tol_m: float) -> PackedInt32Array:
	var n := pts.size()
	var out := PackedInt32Array()
	if n <= 2:
		for i in n:
			out.append(i)
		return out
	var sig := PackedFloat32Array()
	sig.resize(n)
	sig[0] = INF
	sig[n - 1] = INF
	var order := PackedInt32Array()
	order.resize(n)
	var step := 0
	var stack: Array[Vector3i] = [Vector3i(0, n - 1, 0)]
	var parent_sig: Array[float] = [INF]
	while not stack.is_empty():
		var seg: Vector3i = stack.pop_back()
		var ps: float = parent_sig.pop_back()
		var a := seg.x
		var b := seg.y
		if b - a < 2:
			continue
		var pa := pts[a]
		var ab := pts[b] - pa
		var ab2 := ab.length_squared()
		var best := -1.0
		var k := a + 1
		for j in range(a + 1, b):
			var ap := pts[j] - pa
			var d2: float
			if ab2 < 1e-9:
				d2 = ap.length_squared()
			else:
				d2 = (ap - ab * clampf(ap.dot(ab) / ab2, 0.0, 1.0)).length_squared()
			if d2 > best:
				best = d2
				k = j
		var s := minf(sqrt(best), ps)
		sig[k] = s
		step += 1
		order[k] = step
		stack.append(Vector3i(a, k, 0))
		parent_sig.append(s)
		stack.append(Vector3i(k, b, 0))
		parent_sig.append(s)
	var cand: Array[int] = []
	for i in n:
		if sig[i] > min_tol_m:
			cand.append(i)
	if cand.size() > maxi(max_points, 2):
		# Больше лимита — самые значимые; при равенстве — раньше выбранные ДП (родитель прежде потомка).
		cand.sort_custom(func(x: int, y: int) -> bool:
			return sig[x] > sig[y] or (sig[x] == sig[y] and order[x] < order[y]))
		cand.resize(maxi(max_points, 2))
		cand.sort()
	for i in cand:
		out.append(i)
	return out


func _build_mesh() -> void:
	var m := points.size()
	if m < 2:
		return
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	verts.resize(m * 2)
	normals.resize(m * 2)
	uvs.resize(m * 2)
	colors.resize(m * 2)
	for i in m:
		var t := points[mini(i + 1, m - 1)] - points[maxi(i - 1, 0)]
		t = t.normalized() if t.length_squared() > 1e-12 else Vector3.RIGHT
		var c := point_colors[i].srgb_to_linear()
		c.a = point_colors[i].a
		for s in 2:
			var v := i * 2 + s
			verts[v] = points[i]
			normals[v] = t
			uvs[v] = Vector2(-1.0 if s == 0 else 1.0, 0.0)
			colors[v] = c
		if i + 1 < m:
			var a := i * 2
			idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("width_px", float(_cfg.get("width_px", 4.0)))
	mat.set_shader_parameter("depth_pull_m", float(_cfg.get("depth_pull_m", 1.5)))
	mat.set_shader_parameter("depth_pull_frac", float(_cfg.get("depth_pull_frac", 0.002)))
	am.surface_set_material(0, mat)
	mesh = am
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = float(_cfg.get("cull_margin_m", 100.0))


static func _color(v: Variant, fallback: Color) -> Color:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return fallback
