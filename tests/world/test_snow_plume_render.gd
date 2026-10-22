extends TestCase
## SnowPlumeRender (SNW-3, контракт SNW-К3): пул, переназначение по id, AABB, плотность, uniforms.

const RENDER := preload("res://scripts/world/snow_plume/snow_plume_render.gd")


func _em(id: int, x: float, inten: float = 0.75, n: int = 6) -> Dictionary:
	var path := PackedVector3Array()
	var vel := PackedVector3Array()
	for i in n:
		path.append(Vector3(x + 120.0 * i, 3500.0 - 10.0 * i, 5.0 * i))
		vel.append(Vector3(15.0, -1.2, 0.6))
	return {
		"id": id, "pos": Vector3(x, 3498.0, 0.0), "dir": Vector3(1.0, 0.0, 0.0), "u10": 15.0, "u_t": 9.0,
		"intensity": inten, "snow": 1.0, "width_m": 150.0, "path": path, "vel": vel, "path_dt": 8.0,
	}


func _slot(r: Node, pos: Vector3) -> GPUParticles3D:
	for c in r.get_children():
		if c is GPUParticles3D and (c as GPUParticles3D).position == pos and (c as GPUParticles3D).emitting:
			return c
	return null


func test_same_id_same_node_no_restart() -> void:
	var r: Node3D = RENDER.new({"max_emitters": 4})
	r.set_emitters([_em(1, 0.0), _em(2, 500.0)])
	var a := _slot(r, Vector3(0.0, 3498.0, 0.0))
	check(a != null, "излучатель стоит в pos источника")
	var e1 := _em(1, 0.0, 0.4)
	r.set_emitters([_em(2, 500.0), e1])
	check(_slot(r, Vector3(0.0, 3498.0, 0.0)) == a, "тот же id — тот же узел")
	check(a.emitting, "не остановлен")
	approx(a.amount_ratio, 0.4, 1e-4, "intensity обновилась")
	r.free()


func test_aabb_contains_path() -> void:
	var r: Node3D = RENDER.new()
	var e := _em(1, 0.0)
	r.set_emitters([e])
	var p := _slot(r, e["pos"])
	for pt: Vector3 in e["path"]:
		check(p.visibility_aabb.has_point(pt - e["pos"]), "точка path внутри visibility_aabb")
	r.free()


func test_amount_ratio_proportional() -> void:
	var r: Node3D = RENDER.new()
	r.set_emitters([_em(1, 0.0, 0.25), _em(2, 500.0, 1.0)])
	var a := _slot(r, Vector3(0.0, 3498.0, 0.0))
	var b := _slot(r, Vector3(500.0, 3498.0, 0.0))
	approx(a.amount_ratio, 0.25, 1e-4, "amount_ratio a")
	approx(b.amount_ratio, 1.0, 1e-4, "amount_ratio b")
	approx(a.amount_ratio / b.amount_ratio, 0.25, 1e-4, "отношение = отношению intensity")
	r.free()


func test_uniforms() -> void:
	var r: Node3D = RENDER.new()
	var e := _em(1, 0.0, 0.5, 5)
	r.set_emitters([e])
	var m := _slot(r, e["pos"]).process_material as ShaderMaterial
	check(int(m.get_shader_parameter(&"path_n")) == 5, "path_n")
	var pa: PackedVector3Array = m.get_shader_parameter(&"path")
	var va: PackedVector3Array = m.get_shader_parameter(&"vel")
	check(pa.size() == 8 and va.size() == 8, "массивы по 8")
	check(pa[3] == (e["path"] as PackedVector3Array)[3] and va[2] == (e["vel"] as PackedVector3Array)[2], "значения")
	check(pa[7] == (e["path"] as PackedVector3Array)[4], "хвост добит последней точкой")
	approx(float(m.get_shader_parameter(&"path_dt")), 8.0, 1e-4, "path_dt")
	approx(_slot(r, e["pos"]).lifetime, 32.0, 1e-3, "lifetime = path_dt·(n−1)")
	r.free()


func test_short_path_does_not_break() -> void:
	var r: Node3D = RENDER.new({"max_emitters": 3})
	var bad := _em(7, 0.0, 0.5, 1)
	var empty := _em(8, 100.0)
	empty["path"] = PackedVector3Array()
	empty["vel"] = PackedVector3Array()
	r.set_emitters([bad, empty, _em(9, 200.0)])
	check(_slot(r, Vector3(200.0, 3498.0, 0.0)) != null, "нормальный источник рисуется")
	check(_slot(r, bad["pos"]) == null and _slot(r, empty["pos"]) == null, "короткие не рисуются")
	r.set_emitters([])
	check(r.active_count() == 0, "пусто")
	r.free()


func test_shaders_load() -> void:
	check(RENDER.PARTICLES_SHADER is Shader and RENDER.FLAKE_SHADER is Shader, "шейдеры загружены")
