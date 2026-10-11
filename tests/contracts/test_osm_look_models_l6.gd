extends TestCase
## Контракт L6 v1 (docs/contracts/osm-look.md): модели ветряка и кабинки канатки — файлы, оси/начало,
## высота ступицы, габариты, точки зацепа, бюджет треугольников/материалов/текстур.

const TOWER := "res://assets/models/osm/wind_tower.glb"
const ROTOR := "res://assets/models/osm/wind_rotor.glb"
const CABIN := "res://assets/models/osm/cable_cabin.glb"
const MAX_TRIS := 600
const MAX_MATS := 2
const MAX_TEX := 1024


func _inst(path: String) -> Node:
	var ps := load(path) as PackedScene
	return ps.instantiate() if ps != null else null


func _tris(mi: MeshInstance3D) -> int:
	return mi.mesh.get_faces().size() / 3


func _budget(mi: MeshInstance3D, name: String) -> void:
	check(_tris(mi) <= MAX_TRIS, "%s: %d треугольников > %d" % [name, _tris(mi), MAX_TRIS])
	check(mi.mesh.get_surface_count() <= MAX_MATS, "%s: материалов %d > %d" % [name, mi.mesh.get_surface_count(), MAX_MATS])
	for s in mi.mesh.get_surface_count():
		var m := mi.mesh.surface_get_material(s) as BaseMaterial3D
		if m != null and m.albedo_texture != null:
			var sz := m.albedo_texture.get_size()
			check(sz.x <= MAX_TEX and sz.y <= MAX_TEX, "%s: текстура %s > %d" % [name, str(sz), MAX_TEX])


func test_files_exist() -> void:
	for p: String in [TOWER, ROTOR, CABIN]:
		check(ResourceLoader.exists(p), "L6: есть " + p)


func test_wind_tower() -> void:
	var r := _inst(TOWER)
	check(r != null, "башня грузится")
	if r == null:
		return
	var tower := r.find_child("Tower", true, false) as MeshInstance3D
	var nac := r.find_child("Nacelle", true, false) as MeshInstance3D
	var hub := r.find_child("Hub", true, false) as Node3D
	check(tower != null and nac != null and hub != null, "ноды Tower, Nacelle, Hub")
	if tower == null or nac == null or hub == null:
		r.free()
		return
	var cfg: Dictionary = Config.get_config("world_objects")
	var rad := float(cfg.osm_pilot.verticals.radius_m.wind)
	var ab := tower.mesh.get_aabb()
	approx(ab.position.y, 0.0, 0.05, "начало — основание на земле")
	approx(ab.position.x + ab.size.x * 0.5, 0.0, 0.05, "центр основания по X")
	approx(ab.position.z + ab.size.z * 0.5, 0.0, 0.05, "центр основания по Z")
	check(ab.size.x * 0.5 <= rad + 0.1, "след башни %.2f не шире radius_m %.2f" % [ab.size.x * 0.5, rad])
	var hub_h := nac.position.y + hub.position.y
	var ref_h := float(cfg.osm_pilot.verticals.default_h_m.wind)
	approx(hub_h, ref_h, ref_h * 0.02, "высота ступицы эталона = default_h_m.wind ±2 %")
	check(hub.position.x > 0.0, "ступица впереди оси рыскания (нос по +X)")
	var nab := nac.mesh.get_aabb()
	check(nab.position.x < 0.0 and nab.end.x > 0.0, "гондола вокруг оси рыскания, нос по +X")
	_budget(tower, "Tower")
	_budget(nac, "Nacelle")
	check(_tris(tower) + _tris(nac) <= MAX_TRIS, "башня+гондола ≤ %d треугольников: %d" % [MAX_TRIS, _tris(tower) + _tris(nac)])
	r.free()


func test_wind_rotor() -> void:
	var r := _inst(ROTOR)
	check(r != null, "ротор грузится")
	if r == null:
		return
	var ro := r.find_child("Rotor", true, false) as MeshInstance3D
	check(ro != null, "нода Rotor")
	if ro == null:
		r.free()
		return
	var ab := ro.mesh.get_aabb()
	var c := ab.get_center()
	var rr := ab.size.y * 0.5
	check(rr > 25.0 and rr < 60.0, "радиус ротора %.1f м правдоподобен" % rr)
	# три лопасти: ступица в начале координат — центр по X, симметрия плоскости XY
	check(absf(ab.position.x + ab.end.x) < 0.5 * rr, "ротор вокруг ступицы по X")
	check(ab.end.y > 0.95 * rr and ab.position.y < -0.4 * rr, "лопасть вверх, две вниз")
	check(ab.end.z > absf(ab.position.z), "обтекатель смотрит в +Z (ось вращения)")
	check(ab.size.z < 0.2 * rr, "ротор плоский вдоль оси Z")
	check(absf(c.z) < 3.0, "плоскость ротора около начала")
	_budget(ro, "Rotor")
	r.free()


func test_cable_cabin() -> void:
	var r := _inst(CABIN)
	check(r != null, "кабинка грузится")
	if r == null:
		return
	var cb := r.find_child("Cabin", true, false) as MeshInstance3D
	check(cb != null, "нода Cabin")
	if cb == null:
		r.free()
		return
	var ab := cb.mesh.get_aabb()
	check(ab.end.y <= 0.35 and ab.end.y > 0.0, "зажим у начала (точка зацепа): верх %.2f" % ab.end.y)
	check(ab.position.y < -3.0 and ab.position.y > -5.0, "кабина ниже зацепа на %.1f м" % -ab.position.y)
	check(ab.size.x > 1.5 and ab.size.x < 3.0, "ширина кабины %.2f" % ab.size.x)
	check(ab.size.z > 1.5 and ab.size.z < 3.5, "длина вдоль троса (Z) %.2f" % ab.size.z)
	approx(ab.position.x + ab.size.x * 0.5, 0.0, 0.05, "по центру троса X")
	approx(ab.position.z + ab.size.z * 0.5, 0.0, 0.05, "по центру Z")
	_budget(cb, "Cabin")
	r.free()
