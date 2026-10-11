class_name EggBarCharm
extends EasterEgg
## Брелок-чайка на правом углу трапеции (docs/contracts/easter-eggs.md → К16, модель — К15).
## Физический затухающий маятник: точечная масса на нерастяжимой нити; точка подвеса — маркер
## UprightBottomR визуала крыла игрока (только чтение), ускорение берём конечной разностью её
## мирового положения. В системе подвеса действует g − a: крен, перегрузка и болтанка качают сами.
## Шаг считает advance(); _process ставит узел после CameraRig (process_priority выше) — без
## отставания на кадр. Тесты вызывают advance() напрямую, без игры.

const MODEL := "res://assets/easter_eggs/bar_charm/gull_charm.glb"

var length_m := 0.09
var damping_per_s := 2.0
var substep_s := 1.0 / 240.0
var max_accel_ms2 := 30.0
var accel_tau_s := 0.07  ## постоянная времени фильтра нижних частот ускорения
var teleport_m := 30.0
var hang_offset := Vector3(0.0, -0.02, 0.0)
var cord_radius_m := 0.00075
var gravity_ms2 := 9.81

## Единичный вектор от точки подвеса к чайке (мир) и его скорость, 1/с.
var dir := Vector3.DOWN
var dir_vel := Vector3.ZERO
var hang_pos := Vector3.ZERO  ## точка подвеса, мир (последний advance)

var _game: Game
var _charm: MeshInstance3D
var _cord: MeshInstance3D
var _prev_pos := Vector3.ZERO
var _prev_vel := Vector3.ZERO
var _have_pos := false
var _have_vel := false
var _accel := Vector3.ZERO  ## сглаженное ускорение точки подвеса


func begin(_ctx: EggContext, cfg: Dictionary, _rng: RandomNumberGenerator, _t0: float) -> void:
	length_m = float(cfg.get("cord_length_m", length_m))
	damping_per_s = float(cfg.get("damping_per_s", damping_per_s))
	substep_s = float(cfg.get("substep_s", substep_s))
	max_accel_ms2 = float(cfg.get("max_accel_ms2", max_accel_ms2))
	accel_tau_s = float(cfg.get("accel_tau_s", accel_tau_s))
	teleport_m = float(cfg.get("teleport_m", teleport_m))
	cord_radius_m = float(cfg.get("cord_radius_m", cord_radius_m))
	var o: Array = cfg.get("hang_offset_m", [hang_offset.x, hang_offset.y, hang_offset.z])
	hang_offset = Vector3(float(o[0]), float(o[1]), float(o[2]))
	top_level = true
	process_priority = int(cfg.get("process_priority", 20))
	_game = get_parent().get_parent() as Game if get_parent() != null else null
	_build()


func update(_ctx: EggContext) -> bool:
	return true


func _build() -> void:
	var mesh: Mesh = null
	var scene := load(MODEL) as PackedScene
	if scene != null:
		var root := scene.instantiate()
		var mi := _first_mesh(root)
		if mi != null:
			mesh = mi.mesh
		root.free()
	_charm = MeshInstance3D.new()
	_charm.mesh = mesh if mesh != null else SphereMesh.new()
	_charm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_charm)
	var cyl := CylinderMesh.new()
	cyl.top_radius = cord_radius_m
	cyl.bottom_radius = cord_radius_m
	cyl.height = 1.0
	cyl.radial_segments = 4
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.12)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	cyl.material = mat
	_cord = MeshInstance3D.new()
	_cord.mesh = cyl
	_cord.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cord)
	_charm.visible = false
	_cord.visible = false


static func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _first_mesh(c)
		if r != null:
			return r
	return null


func _process(dt: float) -> void:
	if _game == null or _game.glider == null or _game.glider.visual == null:
		return
	if _game.is_paused() or dt <= 0.0:
		return
	var vis := _game.glider.visual
	var m := vis.get_marker("UprightBottomR")
	if m == null:
		return
	var xf := vis.global_transform
	var fwd := -xf.basis.z
	advance(m.global_transform.origin + xf.basis * hang_offset, fwd, dt)


## Один кадр: точка подвеса hang (мир), курс крыла forward (мир), шаг dt, с.
func advance(hang: Vector3, forward: Vector3, dt: float) -> void:
	if _have_pos and hang.distance_to(_prev_pos) > teleport_m:
		_have_vel = false
		_have_pos = false
	if _have_pos:
		var v := (hang - _prev_pos) / dt
		if _have_vel:
			var raw := ((v - _prev_vel) / dt).limit_length(max_accel_ms2)
			_accel = _accel.lerp(raw, 1.0 - exp(-dt / maxf(accel_tau_s, 1e-4)))
		_prev_vel = v
		_have_vel = true
	else:
		_accel = Vector3.ZERO
	_prev_pos = hang
	_have_pos = true
	hang_pos = hang
	_integrate(_accel, dt)
	_place(forward)


## Шаги маятника под постоянным ускорением точки подвеса a (мир) на время dt.
func _integrate(a: Vector3, dt: float) -> void:
	var g_eff := Vector3(0.0, -gravity_ms2, 0.0) - a
	var n := maxi(int(ceil(dt / substep_s)), 1)
	var h := dt / float(n)
	var damp := maxf(1.0 - damping_per_s * h, 0.0)
	for i in n:
		# сферический маятник: u'' = (g − (g·u)u)/L − |u'|² u, затухание — по скорости
		var acc := (g_eff - dir * g_eff.dot(dir)) / length_m - dir * dir_vel.length_squared()
		dir_vel = (dir_vel + acc * h) * damp
		dir = (dir + dir_vel * h).normalized()
		dir_vel -= dir * dir_vel.dot(dir)


## Узел egg стоит в нуле мира (top_level), поэтому transform детей = мировой.
func _place(forward: Vector3) -> void:
	if _charm == null:
		return
	var y := -dir
	var f := forward - y * forward.dot(y)
	if f.length_squared() < 1e-6:
		f = Vector3.FORWARD - y * Vector3.FORWARD.dot(y)
	var z := -f.normalized()
	var x := y.cross(z)
	var ring := hang_pos + dir * length_m
	_charm.transform = Transform3D(Basis(x, y, z), ring)
	var cy := dir
	var cx := cy.cross(Vector3.RIGHT if absf(cy.x) < 0.9 else Vector3.UP).normalized()
	var cz := cx.cross(cy)
	_cord.transform = Transform3D(
		Basis(cx, cy * length_m, cz), hang_pos + dir * (length_m * 0.5)
	)
	_charm.visible = true
	_cord.visible = true
