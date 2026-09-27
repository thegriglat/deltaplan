class_name LandingSite
extends Node3D
## Посадочная площадка (VR-12): скошенное поле с полосами покоса по рельефу, лесополосы и забор
## по сторонам (с коллизией в ObstacleIndex).
## Ветроуказатель ставит WorldObjects в windsock_position().
## Данные — configs/world_objects.json → landing.sites.<id локации>.

const DRAPED_SHADER := preload("res://scripts/world_objects/draped.gdshader")
const SIDES := {
	"north": Vector3.FORWARD, "south": Vector3.BACK, "east": Vector3.RIGHT, "west": Vector3.LEFT
}

var site_id: String = ""
var site_name: String = ""
## Центр поля на земле, мир.
var center: Vector3 = Vector3.ZERO
## Единичные векторы: вдоль длинной оси (курс axis_deg) и вправо от неё.
var axis: Vector3 = Vector3.FORWARD
var right: Vector3 = Vector3.RIGHT
var length_m: float = 0.0
var width_m: float = 0.0
var axis_deg: float = 0.0

var _site: Dictionary = {}
var _cfg: Dictionary = {}
var _height_fn: Callable


## site — запись площадки, cfg — раздел landing, pos — центр (x, z) в мире.
func setup(
	site: Dictionary, cfg: Dictionary, pos: Vector2, height_fn: Callable, obstacles: ObstacleIndex
) -> void:
	_site = site
	_cfg = cfg
	_height_fn = height_fn
	site_id = String(site.id)
	site_name = String(site.get("name", site_id))
	length_m = float(site.length_m)
	width_m = float(site.width_m)
	center = Vector3(pos.x, float(height_fn.call(pos.x, pos.y)), pos.y)
	axis_deg = float(site.axis_deg) if site.get("axis_deg") != null else _contour_heading()
	axis = TerrainGeo.heading_vector(axis_deg)
	right = axis.cross(Vector3.UP)
	_build_field()
	for t in site.get("trees", []):
		_build_trees(t, obstacles)
	for side in site.get("fences", []):
		_build_fence(String(side), obstacles)


## Описание для игры (тренировка точности посадки, FR-36).
func info() -> Dictionary:
	return {
		"id": site_id,
		"name": site_name,
		"position": center,
		"axis_deg": axis_deg,
		"length_m": length_m,
		"width_m": width_m,
	}


## Точка мачты ветроуказателя на земле (windsock_at — доли длины и ширины от центра).
func windsock_position() -> Vector3:
	var f: Array = _site.get("windsock_at", [0.45, 0.4])
	return _ground(center + axis * float(f[0]) * length_m + right * float(f[1]) * width_m)


## Точка внутри поля? (a — вдоль оси, b — поперёк от центра, м)
func contains(p: Vector3) -> bool:
	var d := p - center
	return absf(d.dot(axis)) <= length_m * 0.5 and absf(d.dot(right)) <= width_m * 0.5


## Курс вдоль горизонтали склона (поле длинной стороной поперёк уклона), град.
func _contour_heading() -> float:
	var e := 25.0
	var gx := (
		float(_height_fn.call(center.x + e, center.z))
		- float(_height_fn.call(center.x - e, center.z))
	)
	var gz := (
		float(_height_fn.call(center.x, center.z + e))
		- float(_height_fn.call(center.x, center.z - e))
	)
	if Vector2(gx, gz).length() < 1.0e-3:
		return 0.0
	# Горизонталь ⟂ градиенту: (−gz, gx) в (x, z); курс = atan2(x, −z).
	return fposmod(rad_to_deg(atan2(-gz, -gx)), 180.0)


func _ground(p: Vector3) -> Vector3:
	return Vector3(p.x, float(_height_fn.call(p.x, p.z)), p.z)


func _build_field() -> void:
	var cell := float(_cfg.grass_cell_m)
	var fade := float(_cfg.edge_fade_m)
	var lift := float(_cfg.grass_lift_m)
	var ha := length_m * 0.5 + fade
	var hb := width_m * 0.5 + fade
	var na := ceili(2.0 * ha / cell)
	var nb := ceili(2.0 * hb / cell)
	var col := WorldTiles.linear_color(_site.get("grass_color", _cfg.grass_color))
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in na + 1:
		for j in nb + 1:
			var a := -ha + 2.0 * ha * i / na
			var b := -hb + 2.0 * hb * j / nb
			var p := center + axis * a + right * b
			var y := float(_height_fn.call(p.x, p.z)) + lift
			v.append(Vector3(p.x - center.x, y - center.y, p.z - center.z))
			n.append(Vector3.UP)
			var edge := minf(ha - absf(a), hb - absf(b))
			c.append(Color(col.r, col.g, col.b, clampf(edge / maxf(fade, 0.01), 0.0, 1.0)))
			uv.append(Vector2(0.5, 0.0))
	for i in na:
		for j in nb:
			var q := i * (nb + 1) + j
			idx.append_array(
				PackedInt32Array([q, q + nb + 1, q + 1, q + 1, q + nb + 1, q + nb + 2])
			)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_COLOR] = c
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = DRAPED_SHADER
	mat.set_shader_parameter(&"edge_darken", 0.0)
	mat.set_shader_parameter(&"depth_bias_m", lift * 4.0)
	mat.set_shader_parameter(&"stripe_axis", Vector2(right.x, right.z))
	mat.set_shader_parameter(&"stripe_width_m", float(_cfg.stripe_width_m))
	mat.set_shader_parameter(&"stripe_contrast", float(_cfg.stripe_contrast))
	var mi := MeshInstance3D.new()
	mi.name = "MowedGrass"
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = center
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = float(_cfg.visibility_m)
	add_child(mi)


## Сторона прямоугольника, наружная нормаль которой ближе всего к стороне света.
func _side(side_name: String) -> Dictionary:
	var want: Vector3 = SIDES.get(side_name, Vector3.FORWARD)
	var best := {}
	var best_dot := -INF
	for s in [
		{"n": axis, "along": right, "half": length_m * 0.5, "len": width_m},
		{"n": -axis, "along": right, "half": length_m * 0.5, "len": width_m},
		{"n": right, "along": axis, "half": width_m * 0.5, "len": length_m},
		{"n": -right, "along": axis, "half": width_m * 0.5, "len": length_m},
	]:
		var d := (s.n as Vector3).dot(want)
		if d > best_dot:
			best_dot = d
			best = s
	return best


func _build_trees(spec: Dictionary, obstacles: ObstacleIndex) -> void:
	var s := _side(String(spec.get("side", "north")))
	var count := int(spec.get("count", 10))
	var kind := String(spec.get("kind", "birch"))
	var path := String(_cfg.pine_scene_path if kind == "pine" else _cfg.tree_scene_path)
	var mesh := WorldTiles.load_mesh(path, _tree_placeholder(), String(_cfg.tree_mesh_name))
	var model_h := maxf(mesh.get_aabb().end.y, 0.01)
	var hr: Array = _cfg.tree_height_m
	var rad_k := float(_cfg.tree_radius_m) / float(hr[1])
	var seed_base := hash(site_id + String(spec.get("side", "")))
	var xf: Array[Transform3D] = []
	for i in count:
		var r1 := WorldTiles.hash01(seed_base + i * 3)
		var r2 := WorldTiles.hash01(seed_base + i * 3 + 1)
		var r3 := WorldTiles.hash01(seed_base + i * 3 + 2)
		var t := (float(i) + 0.2 + 0.6 * r1) / count - 0.5
		var off := float(spec.get("offset_m", 10.0)) * (0.7 + 0.6 * r2)
		var p := _ground(center + s.n * (s.half + off) + s.along * t * float(s.len))
		var h := lerpf(float(hr[0]), float(hr[1]), r3)
		xf.append(Transform3D(Basis(Vector3.UP, r1 * TAU).scaled(Vector3.ONE * h / model_h), p))
		obstacles.add_cylinder(p.x, p.z, h * rad_k, p.y - 1.0, p.y + h, "tree")
	var node := WorldTiles.multimesh_node(
		mesh,
		xf,
		PackedColorArray(),
		center,
		float(_cfg.visibility_objects_m),
		bool(_cfg.cast_shadows)
	)
	node.name = "Trees_" + String(spec.get("side", ""))
	add_child(node)


func _build_fence(side_name: String, obstacles: ObstacleIndex) -> void:
	var s := _side(side_name)
	var span := float(_cfg.fence_span_m)
	var total := float(s.len)
	var n := ceili(total / span)
	var dir: Vector3 = s.along
	var yaw := atan2(-dir.z, dir.x)
	var mesh := WorldTiles.load_mesh(String(_cfg.fence_scene_path), _fence_placeholder(span))
	var xf: Array[Transform3D] = []
	var start: Vector3 = center + s.n * (s.half + 1.0) - dir * total * 0.5
	var fh := float(_cfg.fence_height_m)
	for i in n:
		var p := _ground(start + dir * span * i)
		xf.append(Transform3D(Basis(Vector3.UP, yaw), p))
		var m := _ground(p + dir * span * 0.5)
		obstacles.add_box(
			m.x, m.z, span * 0.5, 0.1, atan2(dir.z, dir.x), p.y - 1.0, m.y + fh, "fence"
		)
	var node := WorldTiles.multimesh_node(
		mesh,
		xf,
		PackedColorArray(),
		center,
		float(_cfg.visibility_objects_m),
		bool(_cfg.cast_shadows)
	)
	node.name = "Fence_" + side_name
	add_child(node)


static func _tree_placeholder() -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.0
	m.bottom_radius = 0.2
	m.height = 1.0
	return m


static func _fence_placeholder(span: float) -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(span, 1.2, 0.05)
	return m
