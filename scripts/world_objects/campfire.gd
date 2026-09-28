class_name Campfire
extends Node3D
## Костёр в лагере пилотов (docs/world_objects.md → «Костёр»): кольцо камней, поленья, язычки
## пламени (GPUParticles3D), дешёвый мерцающий свет и дым (GPUParticles3D,
## smoke_particles.gdshader).
## Дым сносит ЛОКАЛЬНЫЙ ветер модели (Atmosphere.air_velocity_at у костра, у земли и выше):
## родитель (WorldObjects) раз в update_s зовёт update_wind(air_low, air_high). В штиль дым
## поднимается почти столбом, порывы его колышут, сильный ветер прижимает к земле.
## Горит всегда. Параметры — configs/world_objects.json → campfire.
##   var pos := Campfire.plan(camp, start, heading_deg, cfg.campfire, cfg.tents, env)
##   var fire := Campfire.new(); add_child(fire); fire.position = pos; fire.setup(cfg.campfire)

const SMOKE_SHADER := preload("res://scripts/world_objects/smoke_particles.gdshader")
const PUFF_SHADER := preload("res://scripts/world_objects/smoke_puff.gdshader")
const FLAME_SHADER := preload("res://scripts/world_objects/flame_puff.gdshader")

## Кольцо камней и поленья — один меш на все костры.
static var _ring_mesh: ArrayMesh = null

var smoke: GPUParticles3D
var flame: GPUParticles3D
var light: OmniLight3D
var smoke_material: ShaderMaterial
## Последний ветер у костра (у земли), м/с — для тестов и отладки.
var wind_low := Vector3.ZERO
var wind_high := Vector3.ZERO

var _cfg: Dictionary = {}
var _light_energy := 1.0
var _t := 0.0


## Место костра: у центра лагеря, чуть по ветру (дым — мимо палаток), не ближе clear_m к
## палаткам, на ровном свободном месте (те же запреты, что у палаток: TentCamp). Нет места —
## Vector3(INF, …). camp — TentCamp.plan(); env — как у TentCamp.plan.
static func plan(
	camp: Array,
	start: Vector3,
	heading_deg: float,
	cfg: Dictionary,
	tent_cfg: Dictionary,
	env: Dictionary
) -> Vector3:
	var none := Vector3(INF, INF, INF)
	if camp.is_empty():
		return none
	var c := Vector2.ZERO
	for t: Dictionary in camp:
		c += Vector2(t.position.x, t.position.z)
	c /= camp.size()
	var ctx := TentCamp._Ctx.new(start, heading_deg, tent_cfg, env)
	var points_fn: Callable = env.get("points_fn", Callable())
	var reach := float(cfg.get("search_radius_m", 18.0))
	if points_fn.is_valid():
		ctx.points = ctx.points + points_fn.call(c, reach + 3.0)
	# ветер у старта дует в склон (из курса разбега): подветренная сторона лагеря — −fwd
	var want := c - ctx.fwd * float(cfg.get("downwind_offset_m", 5.0))
	var clear_m := float(cfg.get("clear_of_tents_m", 3.0))
	var r := float(cfg.get("ring_radius_m", 0.55)) + 0.5
	var max_slope := float(cfg.get("max_slope_deg", 10.0))
	var best := none
	var best_d := INF
	var step := 1.5
	var n := ceili(reach / step)
	for iz in range(-n, n + 1):
		for ix in range(-n, n + 1):
			var p := c + Vector2(ix, iz) * step
			if p.distance_to(c) > reach:
				continue
			var d := p.distance_to(want)
			if d >= best_d:
				continue
			var ok := true
			for t: Dictionary in camp:
				var tp := Vector2(t.position.x, t.position.z)
				if p.distance_to(tp) < float(t.radius) + clear_m:
					ok = false
					break
			if not ok or not ctx.is_free(p, r) or ctx.slope_deg(p, r + 0.5) > max_slope:
				continue
			best_d = d
			best = Vector3(p.x, float(ctx.height_fn.call(p.x, p.y)), p.y)
	return best


func setup(cfg: Dictionary) -> void:
	_cfg = cfg
	name = "Campfire"
	var vis := float(cfg.get("visibility_m", 250.0))
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	ring.mesh = ring_mesh(cfg)
	ring.visibility_range_end = vis
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	flame = _make_flame(cfg)
	flame.visibility_range_end = vis
	add_child(flame)
	smoke = _make_smoke(cfg)
	add_child(smoke)
	if bool(cfg.get("light", true)):
		light = OmniLight3D.new()
		light.name = "Light"
		light.position.y = 0.5
		light.light_color = Color(1.0, 0.55, 0.25)
		_light_energy = float(cfg.get("light_energy", 1.0))
		light.light_energy = _light_energy
		light.omni_range = float(cfg.get("light_range_m", 5.0))
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = float(cfg.get("light_fade_m", 60.0))
		light.distance_fade_length = 20.0
		add_child(light)
	else:
		set_process(false)


## Где спрашивать ветер: у земли и в верхней части шлейфа, мир.
func sample_points() -> Array[Vector3]:
	var p := global_position if is_inside_tree() else position
	return [
		p + Vector3.UP * float(_cfg.get("sample_low_m", 3.0)),
		p + Vector3.UP * float(_cfg.get("sample_high_m", 30.0)),
	]


## Локальный воздух у костра (у земли и на высоте sample_high_m), м/с.
func update_wind(air_low: Vector3, air_high: Vector3) -> void:
	var up_max := float(_cfg.get("updraft_max_ms", 2.0))
	wind_low = Vector3(air_low.x, clampf(air_low.y, -up_max, up_max), air_low.z)
	wind_high = Vector3(air_high.x, clampf(air_high.y, -up_max, up_max), air_high.z)
	smoke_material.set_shader_parameter(&"wind_low", wind_low)
	smoke_material.set_shader_parameter(&"wind_high", wind_high)
	smoke_material.set_shader_parameter(&"fire_y", global_position.y if is_inside_tree() else 0.0)
	# рамка видимости дыма — по сносу за время жизни клуба (частицы в мировых координатах)
	var life := smoke.lifetime
	var drift := Vector3(wind_high.x, 0.0, wind_high.z) * life
	if drift.length() > 400.0:
		drift = drift.normalized() * 400.0
	var size := float(_cfg.get("size_end_m", 9.0))
	var top := float(_cfg.get("rise_speed", 2.5)) * float(_cfg.get("rise_decay_s", 8.0)) + 40.0
	var box := AABB(Vector3(-size, -2.0, -size), Vector3(size * 2.0, top, size * 2.0))
	smoke.visibility_aabb = box.merge(AABB(box.position + drift, box.size))


## Куда снесёт клуб дыма за t секунд при ветре wind (оценка по той же модели, что в шейдере,
## без турбулентности): смещение от костра, м. Для тестов и настройки.
func drift_estimate(t: float, wind: Vector3) -> Vector3:
	var p := Vector3.ZERO
	var v := Vector3(0.0, float(_cfg.get("rise_speed", 2.5)), 0.0) + wind * 0.5
	var dt := 0.1
	var follow := maxf(float(_cfg.get("follow_s", 1.2)), 0.01)
	for i in ceili(t / dt):
		var age := i * dt
		var rise := (
			(
				float(_cfg.get("rise_min", 0.3))
				+ (
					float(_cfg.get("rise_speed", 2.5))
					* exp(-age / float(_cfg.get("rise_decay_s", 8.0)))
				)
			)
			/ (1.0 + float(_cfg.get("wind_damp", 0.25)) * Vector2(wind.x, wind.z).length())
		)
		v = v.lerp(wind + Vector3.UP * rise, 1.0 - exp(-dt / follow))
		p += v * dt
	return p


func _process(delta: float) -> void:
	_t += delta
	if light != null:
		light.light_energy = (
			_light_energy
			* (0.8 + 0.12 * sin(_t * 13.0) + 0.08 * sin(_t * 7.3 + 1.0) + 0.05 * sin(_t * 23.0))
		)


func _make_smoke(cfg: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Smoke"
	p.amount = int(cfg.get("smoke_amount", 44))
	p.lifetime = float(cfg.get("smoke_lifetime_s", 22.0))
	p.preprocess = p.lifetime
	p.local_coords = false
	p.fixed_fps = 20
	p.interpolate = true
	p.randomness = 0.2
	p.visibility_range_end = float(cfg.get("smoke_visibility_m", 3000.0))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	smoke_material = ShaderMaterial.new()
	smoke_material.shader = SMOKE_SHADER
	for k: String in [
		"rise_speed",
		"rise_decay_s",
		"rise_min",
		"wind_damp",
		"follow_s",
		"turbulence",
	]:
		if cfg.has(k):
			smoke_material.set_shader_parameter(k, float(cfg[k]))
	smoke_material.set_shader_parameter(&"size_start", float(cfg.get("size_start_m", 0.5)))
	smoke_material.set_shader_parameter(&"size_end", float(cfg.get("size_end_m", 9.0)))
	smoke_material.set_shader_parameter(
		&"wind_high_m", float(cfg.get("sample_high_m", 30.0)) - float(cfg.get("sample_low_m", 3.0))
	)
	p.process_material = smoke_material
	var quad := QuadMesh.new()
	var mat := ShaderMaterial.new()
	mat.shader = PUFF_SHADER
	var tint: Array = cfg.get("smoke_tint", [0.74, 0.74, 0.76])
	mat.set_shader_parameter(&"tint", Color(float(tint[0]), float(tint[1]), float(tint[2])))
	mat.set_shader_parameter(&"density", float(cfg.get("smoke_density", 0.4)))
	quad.material = mat
	p.draw_pass_1 = quad
	return p


func _make_flame(cfg: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Flame"
	p.amount = int(cfg.get("flame_amount", 14))
	p.lifetime = 0.6
	p.randomness = 0.4
	p.fixed_fps = 30
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-1, -0.2, -1), Vector3(2, 2.5, 2))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.15
	m.direction = Vector3.UP
	m.spread = 12.0
	m.initial_velocity_min = 0.4
	m.initial_velocity_max = 0.9
	m.gravity = Vector3(0, 1.2, 0)
	var h := float(cfg.get("flame_size_m", 0.45))
	m.scale_min = h * 0.6
	m.scale_max = h
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.7))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1.0, 0.2))
	var ct := CurveTexture.new()
	ct.curve = curve
	m.scale_curve = ct
	p.process_material = m
	p.position.y = 0.1
	var quad := QuadMesh.new()
	var mat := ShaderMaterial.new()
	mat.shader = FLAME_SHADER
	quad.material = mat
	p.draw_pass_1 = quad
	return p


## Кольцо камней + поленья «шалашом» + угли: один ArrayMesh (2 поверхности), общий для всех.
static func ring_mesh(cfg: Dictionary) -> ArrayMesh:
	if _ring_mesh != null:
		return _ring_mesh
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var stone := SphereMesh.new()
	stone.radial_segments = 6
	stone.rings = 3
	stone.radius = 0.5
	stone.height = 1.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring_r := float(cfg.get("ring_radius_m", 0.55))
	var n := int(cfg.get("stones", 9))
	for i in n:
		var a := TAU * i / n + rng.randf_range(-0.15, 0.15)
		var s := Vector3(
			rng.randf_range(0.2, 0.3), rng.randf_range(0.12, 0.2), rng.randf_range(0.18, 0.26)
		)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(s)
		st.append_from(
			stone, 0, Transform3D(b, Vector3(cos(a) * ring_r, s.y * 0.3, sin(a) * ring_r))
		)
	st.generate_normals()
	var mesh := st.commit()
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.42, 0.4, 0.37)
	sm.roughness = 0.95
	mesh.surface_set_material(0, sm)
	var log_mesh := CylinderMesh.new()
	log_mesh.radial_segments = 6
	log_mesh.rings = 1
	var wood := SurfaceTool.new()
	wood.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 4:
		var a := TAU * i / 4.0 + 0.4
		log_mesh.top_radius = rng.randf_range(0.04, 0.06)
		log_mesh.bottom_radius = log_mesh.top_radius
		log_mesh.height = rng.randf_range(0.6, 0.75)
		# поленья сходятся шалашом к центру: низ снаружи, верх над углями
		var tilt := Basis(Vector3(-sin(a), 0, cos(a)), deg_to_rad(55.0))
		var outp := Vector3(cos(a), 0, sin(a)) * 0.22
		var xf := Transform3D(tilt, outp + Vector3.UP * 0.12)
		wood.append_from(log_mesh, 0, xf)
	var embers := CylinderMesh.new()
	embers.top_radius = 0.3
	embers.bottom_radius = 0.34
	embers.height = 0.04
	embers.radial_segments = 8
	embers.rings = 1
	wood.append_from(embers, 0, Transform3D(Basis(), Vector3.UP * 0.01))
	wood.generate_normals()
	wood.commit(mesh)
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.16, 0.11, 0.08)
	wm.roughness = 1.0
	mesh.surface_set_material(1, wm)
	_ring_mesh = mesh
	return mesh
